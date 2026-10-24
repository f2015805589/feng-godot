#include <algorithm>
#include <array>
#include <atomic>
#include <thread>
#include <cmath>
#include <cstdint>
#include <limits>
#include <numeric>
#include <string>
#include <utility>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

using namespace godot;

namespace {

constexpr double kPi = 3.141592653589793238462643383279502884;

struct V2 {
	double x = 0.0;
	double y = 0.0;
};

struct V3 {
	double x = 0.0;
	double y = 0.0;
	double z = 0.0;
};

V2 operator+(V2 a, V2 b) { return {a.x + b.x, a.y + b.y}; }
V2 operator-(V2 a, V2 b) { return {a.x - b.x, a.y - b.y}; }
V2 operator*(V2 a, double b) { return {a.x * b, a.y * b}; }
V3 operator+(V3 a, V3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
V3 operator-(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
V3 operator-(V3 a) { return {-a.x, -a.y, -a.z}; }
V3 operator*(V3 a, double b) { return {a.x * b, a.y * b, a.z * b}; }
V3 operator*(V3 a, V3 b) { return {a.x * b.x, a.y * b.y, a.z * b.z}; }
V3 operator/(V3 a, double b) { return {a.x / b, a.y / b, a.z / b}; }

double dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
V3 cross(V3 a, V3 b) {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double length_squared(V3 v) { return dot(v, v); }
double length(V3 v) { return std::sqrt(length_squared(v)); }
V3 normalized(V3 v) {
	const double len = length(v);
	return len > 0.0 ? v / len : V3{};
}
double cross2(V2 a, V2 b) { return a.x * b.y - a.y * b.x; }
double luminance(V3 v) { return 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z; }
double max_component(V3 v) { return std::max(v.x, std::max(v.y, v.z)); }
V3 max_zero(V3 v) { return {std::max(0.0, v.x), std::max(0.0, v.y), std::max(0.0, v.z)}; }
bool finite(V3 v) { return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z); }

V3 to_v3(Vector3 v) { return {v.x, v.y, v.z}; }
V2 to_v2(Vector2 v) { return {v.x, v.y}; }
V3 to_v3(Color c) { return {c.r, c.g, c.b}; }

struct Ray {
	V3 origin;
	V3 direction;
};

struct Triangle {
	V3 v[3];
	V2 uv[3];
	V3 normal;
	V3 shading_normal[3];
	double roughness = 1.0;
	double metallic = 0.0;
	double specular = 0.0;
	uint8_t diffuse_mode = 0;
	V3 albedo;
	V3 emission;
	V3 bounds_min;
	V3 bounds_max;
	V3 centroid;
	double area = 0.0;
	double light_weight = 0.0;
	double light_probability = 0.0;
	int32_t mesh_id = -1;
	uint8_t flags = 0;
};

struct Hit {
	double distance = std::numeric_limits<double>::infinity();
	double bary_u = 0.0;
	double bary_v = 0.0;
	int32_t triangle_id = -1;
	bool front_face = true;
};

struct BvhNode {
	V3 lo;
	V3 hi;
	int32_t left = -1;
	int32_t right = -1;
	int32_t first = 0;
	int32_t count = 0;
};

struct UvPiece {
	int32_t triangle_id = -1;
	std::vector<V2> polygon;
	double area = 0.0;
};

struct Pixel {
	std::vector<UvPiece> pieces;
	double area = 0.0;
};

class Random {
	uint64_t state;

public:
	explicit Random(uint64_t p_seed) : state(p_seed ? p_seed : 0x9e3779b97f4a7c15ULL) {}

	uint32_t next_u32() {
		state = state * 6364136223846793005ULL + 1442695040888963407ULL;
	uint32_t xorshifted = static_cast<uint32_t>(((state >> 18U) ^ state) >> 27U);
		uint32_t rot = static_cast<uint32_t>(state >> 59U);
		return (xorshifted >> rot) | (xorshifted << ((-rot) & 31));
	}

	double uniform() { return (static_cast<double>(next_u32()) + 0.5) / 4294967296.0; }
};

V3 mix(V3 a, V3 b, double t) { return a * (1.0 - t) + b * t; }

double signed_area(const std::vector<V2> &p_polygon) {
    if (p_polygon.size() < 3) return 0.0;
    // Translate to a polygon vertex before summing. Global-coordinate shoelace
    // cancellation loses the entire area of narrow fragments near UV (1,1).
    const V2 origin = p_polygon[0];
    double area2 = 0.0;
    for (size_t i = 1; i + 1 < p_polygon.size(); ++i) {
        area2 += cross2(p_polygon[i]-origin,p_polygon[i+1]-origin);
    }
    return area2*0.5;
}

bool triangle_uv_interiors_disjoint(const Triangle &a, const Triangle &b) {
    // Test original input triangles, not independently clipped fragments.
    // A shared chart edge can pick up different last-bit intersection values
    // when clipped into each texel. A separating original edge proves zero
    // interior overlap, even if those derived fragments acquire a tiny sliver.
    // This is a geometric proof, not an increased overlap-area tolerance.
    auto separates = [](const Triangle &first,const Triangle &second) {
        const double orientation = cross2(first.uv[1]-first.uv[0],first.uv[2]-first.uv[0]) > 0.0 ? 1.0 : -1.0;
        for (int edge=0; edge<3; ++edge) {
            const V2 origin = first.uv[edge];
            const V2 direction = first.uv[(edge+1)%3]-origin;
            bool all_outside_or_on_edge = true;
            for (int vertex=0; vertex<3; ++vertex) {
                if (orientation*cross2(direction,second.uv[vertex]-origin) > 0.0) {
                    all_outside_or_on_edge = false;
                    break;
                }
            }
            if (all_outside_or_on_edge) return true;
        }
        return false;
    };
    return separates(a,b) || separates(b,a);
}

std::vector<V2> clip_axis(const std::vector<V2> &p_polygon, int p_axis, double p_boundary, bool p_keep_greater) {
	std::vector<V2> out;
	if (p_polygon.empty()) {
		return out;
	}
	auto coord = [p_axis](V2 p) { return p_axis == 0 ? p.x : p.y; };
	auto inside = [&](V2 p) { return p_keep_greater ? coord(p) >= p_boundary : coord(p) <= p_boundary; };
	V2 previous = p_polygon.back();
	bool previous_inside = inside(previous);
	for (V2 current : p_polygon) {
		const bool current_inside = inside(current);
		if (current_inside != previous_inside) {
			const double a = coord(previous);
			const double b = coord(current);
			const double denom = b - a;
			if (denom != 0.0) {
				const double t = (p_boundary - a) / denom;
				out.push_back(previous + (current - previous) * t);
			}
		}
		if (current_inside) {
			out.push_back(current);
		}
		previous = current;
		previous_inside = current_inside;
	}
	return out;
}

std::vector<V2> clip_to_cell(std::vector<V2> p_polygon, double p_x0, double p_y0, double p_x1, double p_y1) {
	p_polygon = clip_axis(p_polygon, 0, p_x0, true);
	p_polygon = clip_axis(p_polygon, 0, p_x1, false);
	p_polygon = clip_axis(p_polygon, 1, p_y0, true);
	p_polygon = clip_axis(p_polygon, 1, p_y1, false);
	return p_polygon;
}

std::vector<V2> clip_to_convex(const std::vector<V2> &p_subject, const std::vector<V2> &p_clip) {
	std::vector<V2> out = p_subject;
	if (out.empty() || p_clip.size() < 3) {
		return {};
	}
	const double orientation = signed_area(p_clip) >= 0.0 ? 1.0 : -1.0;
	for (size_t edge = 0; edge < p_clip.size() && !out.empty(); ++edge) {
		const V2 a = p_clip[edge];
		const V2 b = p_clip[(edge + 1) % p_clip.size()];
		auto side = [&](V2 p) { return orientation * cross2(b - a, p - a); };
		std::vector<V2> next;
		V2 previous = out.back();
		double previous_side = side(previous);
		bool previous_inside = previous_side >= 0.0;
		for (V2 current : out) {
			const double current_side = side(current);
			const bool current_inside = current_side >= 0.0;
			if (current_inside != previous_inside) {
				const double denominator = previous_side - current_side;
				if (denominator != 0.0) {
					const double t = previous_side / denominator;
					next.push_back(previous + (current - previous) * t);
				}
			}
			if (current_inside) {
				next.push_back(current);
			}
			previous = current;
			previous_side = current_side;
			previous_inside = current_inside;
		}
		out = std::move(next);
	}
	return out;
}

V2 sample_polygon(const std::vector<V2> &p_polygon, Random &p_rng) {
	const V2 origin = p_polygon[0];
	double total_area = 0.0;
	for (size_t i = 1; i + 1 < p_polygon.size(); ++i) {
		total_area += std::abs(cross2(p_polygon[i] - origin, p_polygon[i + 1] - origin)) * 0.5;
	}
	if (!(total_area > 0.0)) {
		return origin;
	}
	double choice = p_rng.uniform() * total_area;
	V2 a = p_polygon[1];
	V2 b = p_polygon[2];
	for (size_t i = 1; i + 1 < p_polygon.size(); ++i) {
		a = p_polygon[i];
		b = p_polygon[i + 1];
		const double area = std::abs(cross2(a - origin, b - origin)) * 0.5;
		if (choice <= area || i + 2 == p_polygon.size()) {
			break;
		}
		choice -= area;
	}
	const double r1 = std::sqrt(p_rng.uniform());
	const double r2 = p_rng.uniform();
	return origin * (1.0 - r1) + a * (r1 * (1.0 - r2)) + b * (r1 * r2);
}

V3 sample_triangle(V3 p_a, V3 p_b, V3 p_c, Random &p_rng) {
	const double r1 = std::sqrt(p_rng.uniform());
	const double r2 = p_rng.uniform();
	return p_a * (1.0 - r1) + p_b * (r1 * (1.0 - r2)) + p_c * (r1 * r2);
}

V3 cosine_sample(V3 p_normal, Random &p_rng) {
	const double r1 = p_rng.uniform();
	const double r2 = p_rng.uniform();
	const double radius = std::sqrt(r1);
	const double phi = 2.0 * kPi * r2;
	const double x = radius * std::cos(phi);
	const double y = radius * std::sin(phi);
	const double z = std::sqrt(std::max(0.0, 1.0 - r1));
	V3 tangent;
	if (std::abs(p_normal.z) < 0.999) {
		tangent = normalized(cross({0.0, 0.0, 1.0}, p_normal));
	} else {
		tangent = normalized(cross({0.0, 1.0, 0.0}, p_normal));
	}
	const V3 bitangent = cross(p_normal, tangent);
	return normalized(tangent * x + bitangent * y + p_normal * z);
}

uint64_t mix_seed(uint64_t x) {
	x += 0x9e3779b97f4a7c15ULL;
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
	x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
	return x ^ (x >> 31);
}


struct DirectionalLight {
    V3 direction;
    V3 radiance;
    double cone_one_minus_cos = 0.0;
    double indirect_energy = 1.0;
    bool direct_enabled = false;

    V3 sample_direction(Random &rng) const {
        if (cone_one_minus_cos == 0.0) return direction;
        // Uniform solid-angle sampling of the authored angular diameter. Use
        // 1-cos(theta) directly to retain small solar disks in double precision.
        const double z_drop = cone_one_minus_cos * rng.uniform();
        const double radial = std::sqrt(z_drop * (2.0-z_drop));
        const double phi = 2.0*kPi*rng.uniform();
        const V3 tangent = normalized(cross(std::abs(direction.z) < 0.999 ? V3{0,0,1} : V3{0,1,0},direction));
        return direction*(1.0-z_drop) + tangent*(radial*std::cos(phi)) + cross(direction,tangent)*(radial*std::sin(phi));
    }

    double radiance_over_pdf_scale() const {
        // `radiance` retains the delta source's perpendicular-plane illuminance.
        // A uniform disk has L=E/(pi*sin(theta)^2), pdf=1/(2*pi*(1-cos(theta))).
        // Their ratio is E*2/(1+cos(theta)); this also has a stable delta limit.
        return 2.0/(2.0-cone_one_minus_cos);
    }
};


struct AreaLight {
    V3 center;
    V3 axis_u;
    V3 axis_v;
    V3 normal;
    V3 radiance;
    double area = 0.0;
    double range = 1.0;
    double attenuation = 2.0;
    double indirect_energy = 1.0;
    bool direct_enabled = false;

    double distance_factor(V3 position) const {
        const V3 from_center = position - center;
        const double u = std::clamp(dot(from_center,axis_u)/length_squared(axis_u),-0.5,0.5);
        const double v = std::clamp(dot(from_center,axis_v)/length_squared(axis_v),-0.5,0.5);
        const double distance = length(from_center-axis_u*u-axis_v*v);
        const double normalized_distance = distance/range;
        const double window = std::max(1.0-std::pow(normalized_distance,4.0),0.0);
        // Godot's finite-range rectangle model applies this modulation to its
        // solid-angle integral. It is not an infinite physical area emitter.
        return window*window * std::pow(std::max(distance,0.0001),-attenuation) * distance*distance;
    }
};

struct Environment {
    V3 constant;
    int width = 0;
    int height = 0;
    std::vector<V3> pixels;
    std::vector<double> cdf;
    std::vector<double> solid_angles;
    double weight_sum = 0.0;
    V3 world_to_source[3] = {{1,0,0},{0,1,0},{0,0,1}}; // Matrix columns.

    V3 to_source(V3 d) const {
        return world_to_source[0] * d.x + world_to_source[1] * d.y + world_to_source[2] * d.z;
    }
    V3 to_world(V3 d) const {
        return {dot(world_to_source[0], d), dot(world_to_source[1], d), dot(world_to_source[2], d)};
    }
    size_t index(V3 direction) const {
        const V3 d = to_source(direction);
        double u = std::atan2(-d.x, -d.z) / (2.0 * kPi);
        if (u < 0.0) u += 1.0;
        const double v = std::acos(std::clamp(d.y, -1.0, 1.0)) / kPi;
        const int x = std::clamp(static_cast<int>(u * width), 0, width - 1);
        const int y = std::clamp(static_cast<int>(v * height), 0, height - 1);
        return static_cast<size_t>(y) * width + x;
    }
    V3 radiance(V3 d) const { return pixels.empty() ? constant : pixels[index(d)]; }
    double pdf(V3 d, V3 normal) const {
        if (pixels.empty()) return luminance(constant) > 0.0 ? std::max(0.0, dot(d, normal)) / kPi : 0.0;
        if (!(weight_sum > 0.0)) return 0.0;
        return luminance(pixels[index(d)]) / weight_sum;
    }
    V3 sample(V3 normal, Random &rng) const {
        if (pixels.empty()) return cosine_sample(normal, rng);
        if (!(weight_sum > 0.0)) return normal;
        const double pick = rng.uniform() * weight_sum;
        const size_t cell = std::min(static_cast<size_t>(std::lower_bound(cdf.begin(), cdf.end(), pick) - cdf.begin()), pixels.size() - 1);
        const int x = static_cast<int>(cell % width);
        const int y = static_cast<int>(cell / width);
        const double phi = 2.0 * kPi * (x + rng.uniform()) / width;
        const double cos_a = std::cos(kPi * y / height);
        const double cos_b = std::cos(kPi * (y + 1) / height);
        const double cos_theta = cos_a + (cos_b - cos_a) * rng.uniform();
        const double sin_theta = std::sqrt(std::max(0.0, 1.0 - cos_theta * cos_theta));
        return to_world({-std::sin(phi) * sin_theta, cos_theta, -std::cos(phi) * sin_theta});
    }
    bool has_light() const { return pixels.empty() ? luminance(constant) > 0.0 : weight_sum > 0.0; }
};

struct Scattering {
    V3 normal;
    V3 geometric;
    V3 outgoing;
    V3 diffuse;
    V3 f0;
    double alpha = 1.0;
    double roughness = 1.0;
    double f90 = 0.0;
    double specular_probability = 0.0;
    uint8_t diffuse_mode = 0;

    double distribution(double no_h) const {
        const double a2 = alpha * alpha;
        const double den = (1.0 - no_h) * (1.0 + no_h) + a2 * no_h * no_h;
        return a2 / (kPi * den * den);
    }
    double lambda(double no_x) const {
        const double cos2 = std::min(1.0, no_x * no_x);
        return 0.5 * (std::sqrt(1.0 + alpha * alpha * (1.0 - cos2) / cos2) - 1.0);
    }
    V3 value(V3 wi) const {
        const double no_l = dot(normal, wi);
        const double no_v = dot(normal, outgoing);
        if (no_l <= 0.0 || no_v <= 0.0 || dot(geometric, wi) <= 0.0 || dot(geometric, outgoing) <= 0.0) return {};
        const V3 h = normalized(wi + outgoing);
        const double no_h = std::clamp(dot(normal, h), 0.0, 1.0);
        const double vo_h = std::clamp(dot(outgoing, h), 0.0, 1.0);
        double fd = 1.0;
        if (diffuse_mode == 1) {
            const double fd90_minus_1 = 2.0 * roughness * vo_h * vo_h - 0.5;
            fd = (1.0 + fd90_minus_1 * std::pow(1.0 - no_l, 5.0)) * (1.0 + fd90_minus_1 * std::pow(1.0 - no_v, 5.0));
        }
        V3 result = diffuse * (fd / kPi);
        if (max_component(f0) > 0.0 && no_h > 0.0) {
            const V3 fresnel = f0 + (V3{f90,f90,f90} - f0) * std::pow(1.0 - vo_h, 5.0);
            const double g = 1.0 / (1.0 + lambda(no_l) + lambda(no_v));
            result = result + fresnel * (distribution(no_h) * g / (4.0 * no_l * no_v));
        }
        return result;
    }
    double pdf(V3 wi) const {
        const double no_l = dot(normal, wi);
        const V3 h = normalized(wi + outgoing);
        const double no_h = std::clamp(dot(normal, h), 0.0, 1.0);
        const double vo_h = dot(outgoing, h);
        // Invalid microfacet reflection directions are zero-contribution samples,
        // never resampled: this preserves the unconditioned proposal density.
        const double spec_pdf = specular_probability > 0.0 && no_h > 0.0 && vo_h > 0.0 ? distribution(no_h) * no_h / (4.0 * vo_h) : 0.0;
        return (1.0 - specular_probability) * std::max(0.0, no_l) / kPi + specular_probability * spec_pdf;
    }
    V3 sample(Random &rng) const {
        if (!(specular_probability > 0.0) || rng.uniform() >= specular_probability) return cosine_sample(normal, rng);
        const double u = rng.uniform();
        const double cos_theta = std::sqrt((1.0 - u) / ((1.0 - u) + alpha * alpha * u));
        const double sin_theta = std::sqrt(std::max(0.0, 1.0 - cos_theta * cos_theta));
        const double phi = 2.0 * kPi * rng.uniform();
        const V3 tangent = normalized(cross(std::abs(normal.z) < 0.999 ? V3{0,0,1} : V3{0,1,0}, normal));
        const V3 h = tangent * (sin_theta * std::cos(phi)) + cross(normal, tangent) * (sin_theta * std::sin(phi)) + normal * cos_theta;
        return normalized(h * (2.0 * dot(outgoing, h)) - outgoing);
    }
};

V3 interpolated_normal(const Triangle &tri, double u, double v, bool front) {
    V3 n = normalized(tri.shading_normal[0] * (1.0 - u - v) + tri.shading_normal[1] * u + tri.shading_normal[2] * v);
    return front ? n : -n;
}

class Scene {
public:
	std::vector<Triangle> triangles;
	std::vector<int32_t> order;
	std::vector<BvhNode> nodes;
	std::vector<int32_t> emitters;
	double emitter_weight_sum = 0.0;
	Environment environment;
	std::vector<DirectionalLight> directional_lights;
    std::vector<AreaLight> area_lights;
	const std::atomic<bool> *cancel_requested = nullptr;

	static V3 min_v(V3 a, V3 b) { return {std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)}; }
	static V3 max_v(V3 a, V3 b) { return {std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)}; }

	int32_t build_node(int32_t first, int32_t count) {
		BvhNode node;
		node.lo = {std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity()};
		node.hi = {-std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity()};
		V3 centroid_lo = node.lo;
		V3 centroid_hi = node.hi;
		for (int32_t i = first; i < first + count; ++i) {
			const Triangle &tri = triangles[order[i]];
			node.lo = min_v(node.lo, tri.bounds_min);
			node.hi = max_v(node.hi, tri.bounds_max);
			centroid_lo = min_v(centroid_lo, tri.centroid);
			centroid_hi = max_v(centroid_hi, tri.centroid);
		}
		const int32_t node_index = static_cast<int32_t>(nodes.size());
		nodes.push_back(node);
		if (count <= 4) {
			nodes[node_index].first = first;
			nodes[node_index].count = count;
			return node_index;
		}
		const V3 extent = centroid_hi - centroid_lo;
		int axis = extent.y > extent.x ? 1 : 0;
		if ((axis == 0 ? extent.x : extent.y) < extent.z) {
			axis = 2;
		}
		const int32_t middle = first + count / 2;
		std::nth_element(order.begin() + first, order.begin() + middle, order.begin() + first + count,
				[&](int32_t a, int32_t b) {
					const V3 ca = triangles[a].centroid;
					const V3 cb = triangles[b].centroid;
					return axis == 0 ? ca.x < cb.x : (axis == 1 ? ca.y < cb.y : ca.z < cb.z);
				});
		const int32_t left = build_node(first, middle - first);
		const int32_t right = build_node(middle, first + count - middle);
		nodes[node_index].left = left;
		nodes[node_index].right = right;
		return node_index;
	}

	bool hit_bounds(const Ray &p_ray, const BvhNode &p_node, double p_max_t) const {
		double t_min = 0.0;
		double t_max = p_max_t;
		for (int axis = 0; axis < 3; ++axis) {
			const double origin = axis == 0 ? p_ray.origin.x : (axis == 1 ? p_ray.origin.y : p_ray.origin.z);
			const double direction = axis == 0 ? p_ray.direction.x : (axis == 1 ? p_ray.direction.y : p_ray.direction.z);
			const double lo = axis == 0 ? p_node.lo.x : (axis == 1 ? p_node.lo.y : p_node.lo.z);
			const double hi = axis == 0 ? p_node.hi.x : (axis == 1 ? p_node.hi.y : p_node.hi.z);
			if (direction == 0.0) {
				if (origin < lo || origin > hi) {
					return false;
				}
				continue;
			}
			const double inv = 1.0 / direction;
			double t0 = (lo - origin) * inv;
			double t1 = (hi - origin) * inv;
			if (t0 > t1) {
				std::swap(t0, t1);
			}
			t_min = std::max(t_min, t0);
			t_max = std::min(t_max, t1);
			if (t_max < t_min) {
				return false;
			}
		}
		return t_max > 0.0;
	}

	bool intersect_triangle(const Ray &p_ray, int32_t p_id, int32_t p_source_id, double p_max_t, Hit &r_hit) const {
		if (p_id == p_source_id) {
			return false;
		}
		const Triangle &tri = triangles[p_id];
		if ((tri.flags & 1U) == 0U && dot(p_ray.direction, tri.normal) >= 0.0) {
			return false;
		}
		const V3 e1 = tri.v[1] - tri.v[0];
		const V3 e2 = tri.v[2] - tri.v[0];
		const V3 p = cross(p_ray.direction, e2);
		const double det = dot(e1, p);
		if (det == 0.0) {
			return false;
		}
		const double inv_det = 1.0 / det;
		const V3 tvec = p_ray.origin - tri.v[0];
		const double u = dot(tvec, p) * inv_det;
		if (u < 0.0 || u > 1.0) {
			return false;
		}
		const V3 q = cross(tvec, e1);
		const double v = dot(p_ray.direction, q) * inv_det;
		if (v < 0.0 || u + v > 1.0) {
			return false;
		}
		const double distance = dot(e2, q) * inv_det;
		if (!(distance > 0.0 && distance < p_max_t)) {
			return false;
		}
		r_hit.distance = distance;
		r_hit.bary_u = u;
		r_hit.bary_v = v;
		r_hit.triangle_id = p_id;
		r_hit.front_face = dot(p_ray.direction, tri.normal) < 0.0;
		return true;
	}

	bool intersect(const Ray &p_ray, int32_t p_source_id, double p_max_t, int32_t p_target_id, Hit &r_hit) const {
		if (nodes.empty()) {
			return false;
		}
		bool found = false;
		std::array<int32_t, 128> stack{};
		int32_t stack_size = 0;
		stack[stack_size++] = 0;
		while (stack_size > 0) {
			const BvhNode &node = nodes[stack[--stack_size]];
			if (!hit_bounds(p_ray, node, found ? r_hit.distance : p_max_t)) {
				continue;
			}
			if (node.count > 0) {
				for (int32_t i = node.first; i < node.first + node.count; ++i) {
					const int32_t triangle_id = order[i];
					if (triangle_id == p_target_id) {
						continue;
					}
					Hit candidate;
					if (intersect_triangle(p_ray, triangle_id, p_source_id, found ? r_hit.distance : p_max_t, candidate)) {
						r_hit = candidate;
						found = true;
					}
				}
			} else {
				if (stack_size + 2 >= static_cast<int32_t>(stack.size())) {
					return found;
				}
				stack[stack_size++] = node.left;
				stack[stack_size++] = node.right;
			}
		}
		return found;
	}


    V3 estimate(V3 p_position, int32_t p_surface_id, V3 p_shading_normal, Random &p_rng, int64_t &r_bounces, int64_t &r_rr_survivals) const {
        // Primary output is incoming diffuse irradiance / pi. Material diffuse
        // and self emission are applied by the renderer, not duplicated here.
        V3 result{};
        V3 beta{1,1,1};
        V3 position = p_position;
        V3 normal = p_shading_normal;
        V3 geometric = triangles[p_surface_id].normal;
        V3 outgoing = normal;
        int32_t current_id = p_surface_id;
        int64_t depth = 0;
        for (;;) {
            if (cancel_requested && cancel_requested->load(std::memory_order_relaxed)) return {};
            const bool primary = depth == 0;
            const Triangle &current = triangles[current_id];
            Scattering bsdf;
            bsdf.normal = normal;
            bsdf.geometric = geometric;
            bsdf.outgoing = outgoing;
            bsdf.diffuse = primary ? V3{1,1,1} : current.albedo * (1.0 - current.metallic);
            if (!primary) {
                const double dielectric = 0.16 * current.specular * current.specular;
                bsdf.f0 = mix({dielectric,dielectric,dielectric}, current.albedo, current.metallic);
                bsdf.f90 = std::clamp((bsdf.f0.x + bsdf.f0.y + bsdf.f0.z) * (50.0 * 0.33), current.metallic, 1.0);
                bsdf.alpha = current.roughness * current.roughness;
                bsdf.roughness = current.roughness;
                bsdf.diffuse_mode = current.diffuse_mode;
                const double diffuse_weight = luminance(bsdf.diffuse);
                const double specular_weight = luminance(bsdf.f0);
                const double sum = diffuse_weight + specular_weight;
                bsdf.specular_probability = sum > 0.0 ? specular_weight / sum : 0.0;
            }
            if (!(max_component(bsdf.diffuse) > 0.0 || max_component(bsdf.f0) > 0.0)) return result;
            // Roulette is decided from the vertex, before selecting direction.
            // Its mass is in BOTH competing MIS densities, including NEE.
            const double survival = depth >= 2 ? 0.8 : 1.0;
            if (environment.has_light()) {
                const V3 direction = environment.sample(normal, p_rng);
                const double p_light = environment.pdf(direction, normal);
                const V3 f = bsdf.value(direction);
                const double cosine = std::max(0.0, dot(normal, direction));
                if (p_light > 0.0 && max_component(f) > 0.0 && cosine > 0.0) {
                    Hit blocker;
                    if (!intersect({position,direction}, current_id, std::numeric_limits<double>::infinity(), -1, blocker)) {
                        const double mis = p_light / (p_light + bsdf.pdf(direction) * survival);
                        result = result + beta * f * environment.radiance(direction) * (cosine * mis / p_light);
                    }
                }
            }
            for (const DirectionalLight &light : directional_lights) {
                if (primary && !light.direct_enabled) continue;
                const V3 direction = light.sample_direction(p_rng);
                const V3 f = bsdf.value(direction);
                const double cosine = std::max(0.0, dot(normal, direction));
                if (cosine > 0.0 && max_component(f) > 0.0) {
                    Hit blocker;
                    if (!intersect({position,direction}, current_id, std::numeric_limits<double>::infinity(), -1, blocker)) {
                        // Analytic sun emission is evaluated by this strategy
                        // only (not on an environment miss), including finite
                        // disks. There is no competing BSDF source term to MIS.
                        result = result + beta * f * light.radiance * (cosine * light.radiance_over_pdf_scale() * (primary ? 1.0 : light.indirect_energy));
                    }
                }
            }

            for (const AreaLight &light : area_lights) {
                if (primary && !light.direct_enabled) continue;
                if (dot(position-light.center,light.normal) <= 0.0) continue;
                const double distance_factor = light.distance_factor(position);
                if (!(distance_factor > 0.0)) continue;
                const V3 target = light.center + light.axis_u*(p_rng.uniform()-0.5) + light.axis_v*(p_rng.uniform()-0.5);
                const V3 delta = target-position;
                const double distance2 = length_squared(delta);
                if (!(distance2 > 0.0)) continue;
                const double distance = std::sqrt(distance2);
                const V3 direction = delta/distance;
                const double cosine = std::max(0.0,dot(normal,direction));
                const double emitter_cosine = std::max(0.0,dot(light.normal,-direction));
                const V3 f = bsdf.value(direction);
                if (cosine > 0.0 && emitter_cosine > 0.0 && max_component(f) > 0.0) {
                    Hit blocker;
                    if (!intersect({position,direction},current_id,distance,-1,blocker)) {
                        // Engine analytic lights have no ray-intersectable
                        // surface. Only this strategy generates their source
                        // term, so applying an emitter/BSDF MIS weight here
                        // would incorrectly suppress energy. Authored emissive
                        // mesh geometry remains a separate transport source.
                        const double factor = cosine*emitter_cosine*light.area/distance2 * distance_factor * (primary ? 1.0 : light.indirect_energy);
                        result = result + beta * f * light.radiance * factor;
                    }
                }
            }
            if (emitter_weight_sum > 0.0) {
                const double pick = p_rng.uniform() * emitter_weight_sum;
                double cumulative = 0.0;
                int32_t emitter_id = emitters.back();
                for (int32_t candidate : emitters) {
                    cumulative += triangles[candidate].light_weight;
                    if (pick <= cumulative) { emitter_id = candidate; break; }
                }
                const Triangle &emitter = triangles[emitter_id];
                const V3 target = sample_triangle(emitter.v[0], emitter.v[1], emitter.v[2], p_rng);
                const V3 delta = target - position;
                const double distance2 = length_squared(delta);
                if (distance2 > 0.0) {
                    const double distance = std::sqrt(distance2);
                    const V3 direction = delta / distance;
                    const double cosine = std::max(0.0, dot(normal,direction));
                    double cos_emitter = dot(emitter.normal,-direction);
                    if ((emitter.flags & 2U) != 0U) cos_emitter = std::abs(cos_emitter);
                    const V3 f = bsdf.value(direction);
                    if (cosine > 0.0 && cos_emitter > 0.0 && max_component(f) > 0.0) {
                        const double p_light = emitter.light_probability * distance2 / (emitter.area * cos_emitter);
                        Hit blocker;
                        if (p_light > 0.0 && !intersect({position,direction},current_id,distance,emitter_id,blocker)) {
                            const double mis = p_light / (p_light + bsdf.pdf(direction) * survival);
                            result = result + beta * f * emitter.emission * (cosine * mis / p_light);
                        }
                    }
                }
            }
            const V3 direction = bsdf.sample(p_rng);
            const double pdf = bsdf.pdf(direction);
            const V3 f = bsdf.value(direction);
            const double cosine = std::max(0.0, dot(normal,direction));
            if (!(pdf > 0.0) || max_component(f) <= 0.0 || cosine <= 0.0) return result;
            ++r_bounces;
            if (survival < 1.0) {
                if (p_rng.uniform() >= survival) return result;
                ++r_rr_survivals;
            }
            beta = beta * f * (cosine / (pdf * survival));
            const double path_pdf = pdf * survival;
            Hit hit;
            if (!intersect({position,direction},current_id,std::numeric_limits<double>::infinity(),-1,hit)) {
                const double light_pdf = environment.pdf(direction,normal);
                const double mis = path_pdf / (path_pdf + light_pdf);
                result = result + beta * environment.radiance(direction) * mis;
                return result;
            }
            const Triangle &next = triangles[hit.triangle_id];
            double cosine_emitter = dot(next.normal,-direction);
            if ((next.flags & 2U) != 0U) cosine_emitter = std::abs(cosine_emitter);
            if (luminance(next.emission) > 0.0 && cosine_emitter > 0.0) {
                const double light_pdf = next.light_probability * hit.distance * hit.distance / (next.area * cosine_emitter);
                const double mis = path_pdf / (path_pdf + light_pdf);
                result = result + beta * next.emission * mis;
            }
            position = position + direction * hit.distance;
            current_id = hit.triangle_id;
            normal = interpolated_normal(next,hit.bary_u,hit.bary_v,hit.front_face);
            geometric = hit.front_face ? next.normal : -next.normal;
            outgoing = -direction;
            ++depth;
        }
    }

};

} // namespace

class FengLightmapMCIntegrator : public RefCounted {
	GDCLASS(FengLightmapMCIntegrator, RefCounted);
	static constexpr int32_t BACKEND_CONTRACT_VERSION = 4;
    std::atomic<bool> cancel_requested{false};
    std::atomic<bool> running{false};
    std::atomic<int64_t> completed_texels{0};
    std::atomic<int64_t> total_texels{0};

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("bake_atlases", "vertices", "uv2", "albedo", "emission", "material_flags", "mesh_ids", "mesh_count", "resolution", "samples_per_texel", "seed", "environment_radiance"), &FengLightmapMCIntegrator::bake_atlases);
		ClassDB::bind_method(D_METHOD("bake_scene_atlases", "scene", "options"), &FengLightmapMCIntegrator::bake_scene_atlases);
        ClassDB::bind_method(D_METHOD("request_cancel"), &FengLightmapMCIntegrator::request_cancel);
        ClassDB::bind_method(D_METHOD("get_progress"), &FengLightmapMCIntegrator::get_progress);
        ClassDB::bind_method(D_METHOD("get_backend_contract_version"), &FengLightmapMCIntegrator::get_backend_contract_version);
	}

public:
	int32_t get_backend_contract_version() const { return BACKEND_CONTRACT_VERSION; }


    void request_cancel() { cancel_requested.store(true, std::memory_order_relaxed); }
    Dictionary get_progress() const {
        Dictionary progress;
        const int64_t done = completed_texels.load(std::memory_order_relaxed);
        const int64_t total = total_texels.load(std::memory_order_relaxed);
        progress["completed_texels"] = done;
        progress["total_texels"] = total;
        progress["fraction"] = total > 0 ? static_cast<double>(done) / total : 0.0;
        progress["running"] = running.load(std::memory_order_relaxed);
        progress["cancel_requested"] = cancel_requested.load(std::memory_order_relaxed);
        return progress;
    }
    Dictionary bake_atlases(const PackedVector3Array &p_vertices, const PackedVector2Array &p_uv2,
            const PackedColorArray &p_albedo, const PackedColorArray &p_emission,
            const PackedByteArray &p_material_flags, const PackedInt32Array &p_mesh_ids,
            int32_t p_mesh_count, int32_t p_resolution, int32_t p_samples_per_texel,
            int64_t p_seed, Color p_environment_radiance) {
        return bake_impl(p_vertices, p_uv2, p_albedo, p_emission, p_material_flags, p_mesh_ids,
                p_mesh_count, p_resolution, p_samples_per_texel, p_seed, p_environment_radiance, Dictionary(), 1);
    }
    Dictionary bake_scene_atlases(const Dictionary &p_scene, const Dictionary &p_options) {
        return bake_impl(p_scene.get("vertices",PackedVector3Array()), p_scene.get("uv2",PackedVector2Array()),
                p_scene.get("albedo",PackedColorArray()), p_scene.get("emission",PackedColorArray()),
                p_scene.get("material_flags",PackedByteArray()), p_scene.get("mesh_ids",PackedInt32Array()),
                p_options.get("mesh_count",0), p_options.get("resolution",64), p_options.get("samples_per_texel",64),
                p_options.get("seed",1), p_scene.get("environment_radiance",Color(0,0,0)), p_scene,
                p_options.get("worker_count",0));
    }

private:
    Dictionary bake_impl(const PackedVector3Array &p_vertices, const PackedVector2Array &p_uv2,
            const PackedColorArray &p_albedo, const PackedColorArray &p_emission,
            const PackedByteArray &p_material_flags, const PackedInt32Array &p_mesh_ids,
            int32_t p_mesh_count, int32_t p_resolution, int32_t p_samples_per_texel,
            int64_t p_seed, Color p_environment_radiance, const Dictionary &p_scene, int32_t p_workers) {

		Dictionary result;
		result["ok"] = false;
        if (running.exchange(true)) {
            result["error"] = "This integrator is already baking.";
            return result;
        }
        struct RunningGuard { std::atomic<bool> &flag; ~RunningGuard() { flag.store(false); } } running_guard{running};
        if (cancel_requested.load()) {
            result["error"] = "Bake cancelled before entry; use a fresh integrator to start another bake.";
            result["cancelled"] = true;
            return result;
        }
        completed_texels.store(0);
        total_texels.store(0);
		if (p_resolution < 4 || p_resolution > 2048 || p_samples_per_texel < 1 || p_mesh_count < 1) {
			result["error"] = "Resolution must be 4..2048, samples_per_texel must be positive, and at least one mesh is required.";
			return result;
		}
		if (p_vertices.size() == 0 || p_vertices.size() % 3 != 0 || p_uv2.size() != p_vertices.size()) {
			result["error"] = "Surface inputs must contain one complete UV2 triangle per three vertices.";
			return result;
		}
		const int64_t triangle_count = p_vertices.size() / 3;
		if (p_albedo.size() != triangle_count || p_emission.size() != triangle_count ||
				p_material_flags.size() != triangle_count || p_mesh_ids.size() != triangle_count) {
			result["error"] = "Material flags and mesh IDs must contain one entry per triangle.";
			return result;
		}
		if (!std::isfinite(p_environment_radiance.r) || !std::isfinite(p_environment_radiance.g) ||
				!std::isfinite(p_environment_radiance.b) || p_environment_radiance.r < 0.0 ||
				p_environment_radiance.g < 0.0 || p_environment_radiance.b < 0.0) {
			result["error"] = "Environment radiance must be finite and nonnegative.";
			return result;
		}


        const bool extended = !p_scene.is_empty();
        const PackedVector3Array normals = p_scene.get("normals",PackedVector3Array());
        const PackedFloat32Array roughness = p_scene.get("roughness",PackedFloat32Array());
        const PackedFloat32Array metallic = p_scene.get("metallic",PackedFloat32Array());
        const PackedFloat32Array specular = p_scene.get("specular",PackedFloat32Array());
        const PackedByteArray diffuse_modes = p_scene.get("diffuse_modes",PackedByteArray());
        if (extended && (normals.size() != p_vertices.size() || roughness.size() != triangle_count ||
                metallic.size() != triangle_count || specular.size() != triangle_count || diffuse_modes.size() != triangle_count)) {
            result["error"] = "v3 requires one shading normal per vertex and roughness/metallic/specular/diffuse_mode per triangle.";
            return result;
        }
        Scene scene;
        scene.cancel_requested = &cancel_requested;
        scene.environment.constant = to_v3(p_environment_radiance);
        scene.environment.width = p_scene.get("environment_width",0);
        scene.environment.height = p_scene.get("environment_height",0);
        const PackedColorArray environment_pixels = p_scene.get("environment_pixels",PackedColorArray());
        const Basis environment_transform = p_scene.get("environment_transform",Basis());
        for (int axis = 0; axis < 3; ++axis) scene.environment.world_to_source[axis] = to_v3(environment_transform.get_column(axis));
        const V3 *axes = scene.environment.world_to_source;
        if (!finite(axes[0]) || !finite(axes[1]) || !finite(axes[2]) ||
                std::abs(length_squared(axes[0])-1.0) > 1e-5 || std::abs(length_squared(axes[1])-1.0) > 1e-5 ||
                std::abs(length_squared(axes[2])-1.0) > 1e-5 || std::abs(dot(axes[0],axes[1])) > 1e-5 ||
                std::abs(dot(axes[0],axes[2])) > 1e-5 || std::abs(dot(axes[1],axes[2])) > 1e-5) {
            result["error"] = "Environment transform must be an orthonormal world-to-source basis.";
            return result;
        }
        if (scene.environment.width != 0 || scene.environment.height != 0 || !environment_pixels.is_empty()) {
            const int w = scene.environment.width;
            const int h = scene.environment.height;
            if (w < 1 || h < 1 || w > 16384 || h > 8192 || environment_pixels.size() != static_cast<int64_t>(w)*h) {
                result["error"] = "Environment panorama dimensions do not match the HDR pixel array.";
                return result;
            }
            scene.environment.pixels.reserve(environment_pixels.size());
            scene.environment.cdf.reserve(environment_pixels.size());
            scene.environment.solid_angles.reserve(environment_pixels.size());
            for (int y = 0; y < h; ++y) {
                const double solid_angle = 2.0*kPi/w * (std::cos(kPi*y/h)-std::cos(kPi*(y+1)/h));
                for (int x = 0; x < w; ++x) {
                    const V3 color = to_v3(environment_pixels[static_cast<int64_t>(y)*w+x]);
                    if (!finite(color) || color.x < 0.0 || color.y < 0.0 || color.z < 0.0) {
                        result["error"] = "Environment pixels must contain finite nonnegative scene-linear radiance.";
                        return result;
                    }
                    scene.environment.pixels.push_back(color);
                    scene.environment.solid_angles.push_back(solid_angle);
                    scene.environment.weight_sum += luminance(color)*solid_angle;
                    scene.environment.cdf.push_back(scene.environment.weight_sum);
                }
            }
            if (!std::isfinite(scene.environment.weight_sum)) {
                result["error"] = "Environment importance distribution overflowed.";
                return result;
            }
        }
        const Array directional_lights = p_scene.get("directional_lights",Array());
        for (int64_t i = 0; i < directional_lights.size(); ++i) {
            const Dictionary entry = directional_lights[i];
            DirectionalLight light;
            light.direction = to_v3(static_cast<Vector3>(entry.get("direction_to_light",Vector3())));
            light.radiance = to_v3(static_cast<Color>(entry.get("radiance",Color(0,0,0))));
            light.indirect_energy = entry.get("indirect_energy",1.0);
            light.direct_enabled = entry.get("direct_enabled",false);
            const double angular_distance = entry.get("angular_distance",0.0);
            if (!finite(light.direction) || length_squared(light.direction) <= 0.0 || !finite(light.radiance) ||
                    light.radiance.x < 0.0 || light.radiance.y < 0.0 || light.radiance.z < 0.0 ||
                    !std::isfinite(light.indirect_energy) || light.indirect_energy < 0.0 || !std::isfinite(angular_distance) || angular_distance < 0.0 || angular_distance >= 180.0) {
                result["error"] = "Directional lights require finite nonnegative radiance/indirect energy, a nonzero direction and angular diameter in [0,180) degrees.";
                return result;
            }
            light.direction = normalized(light.direction);
            const double half_radius_sine = std::sin(angular_distance*kPi/720.0);
            light.cone_one_minus_cos = 2.0*half_radius_sine*half_radius_sine;
            scene.directional_lights.push_back(light);
        }

        const Array area_lights = p_scene.get("area_lights",Array());
        for (int64_t i = 0; i < area_lights.size(); ++i) {
            const Dictionary entry = area_lights[i];
            AreaLight light;
            light.center = to_v3(static_cast<Vector3>(entry.get("center",Vector3())));
            light.axis_u = to_v3(static_cast<Vector3>(entry.get("axis_u",Vector3())));
            light.axis_v = to_v3(static_cast<Vector3>(entry.get("axis_v",Vector3())));
            light.normal = to_v3(static_cast<Vector3>(entry.get("normal",Vector3())));
            light.radiance = to_v3(static_cast<Color>(entry.get("radiance",Color(0,0,0))));
            light.range = entry.get("range",0.0);
            light.attenuation = entry.get("attenuation",2.0);
            light.indirect_energy = entry.get("indirect_energy",1.0);
            light.direct_enabled = entry.get("direct_enabled",false);
            const double u_length = length(light.axis_u);
            const double v_length = length(light.axis_v);
            if (!finite(light.center) || !finite(light.axis_u) || !finite(light.axis_v) || !finite(light.normal) ||
                    !finite(light.radiance) || light.radiance.x < 0.0 || light.radiance.y < 0.0 || light.radiance.z < 0.0 ||
                    !(u_length > 0.0) || !(v_length > 0.0) || std::abs(length_squared(light.normal)-1.0) > 1e-5 ||
                    std::abs(dot(light.axis_u,light.axis_v)) > 1e-5*u_length*v_length ||
                    std::abs(dot(light.axis_u,light.normal)) > 1e-5*u_length || std::abs(dot(light.axis_v,light.normal)) > 1e-5*v_length ||
                    !std::isfinite(light.range) || light.range <= 0.0 || !std::isfinite(light.attenuation) || light.attenuation < 0.0 ||
                    !std::isfinite(light.indirect_energy) || light.indirect_energy < 0.0 || entry.has("texture")) {
                result["error"] = "Area lights require an untextured orthogonal rectangle, unit normal, positive range, and finite nonnegative radiance/attenuation/indirect energy.";
                return result;
            }
            light.area = u_length*v_length;
            scene.area_lights.push_back(light);
        }
        scene.triangles.reserve(static_cast<size_t>(triangle_count));
        for (int64_t i = 0; i < triangle_count; ++i) {
            if (cancel_requested.load(std::memory_order_relaxed)) {
                result["error"] = "Bake cancelled during scene preparation.";
                result["cancelled"] = true;
                return result;
            }
			Triangle tri;
			tri.mesh_id = p_mesh_ids[i];
			if (tri.mesh_id < -1 || tri.mesh_id >= p_mesh_count) {
				result["error"] = "Triangle mesh ID must be -1 (transport-only) or reference an output receiver atlas.";
				return result;
			}
			for (int vertex = 0; vertex < 3; ++vertex) {
				tri.v[vertex] = to_v3(p_vertices[i * 3 + vertex]);
				tri.uv[vertex] = to_v2(p_uv2[i * 3 + vertex]);
				if (!finite(tri.v[vertex]) || !std::isfinite(tri.uv[vertex].x) || !std::isfinite(tri.uv[vertex].y)) {
					result["error"] = "Triangle contains a non-finite position or UV2 value.";
					return result;
				}
				if (tri.mesh_id >= 0 && (tri.uv[vertex].x < 0.0 || tri.uv[vertex].x > 1.0 || tri.uv[vertex].y < 0.0 || tri.uv[vertex].y > 1.0)) {
					result["error"] = "Receiver UV2 coordinates must be inside [0,1] for this atlas backend.";
					return result;
				}
			}
			tri.albedo = to_v3(p_albedo[i]);
			tri.emission = to_v3(p_emission[i]);
			tri.flags = p_material_flags[i];
			if (!finite(tri.albedo) || !finite(tri.emission) || tri.albedo.x < 0.0 || tri.albedo.y < 0.0 || tri.albedo.z < 0.0 ||
					tri.emission.x < 0.0 || tri.emission.y < 0.0 || tri.emission.z < 0.0 || max_component(tri.albedo) > 1.0 + 1e-6) {
				result["error"] = "Diffuse reflectance must be finite and within [0,1]; emission must be finite.";
				return result;
			}
			const V3 edge_a = tri.v[1] - tri.v[0];
			const V3 edge_b = tri.v[2] - tri.v[0];
			const V3 area_vector = cross(edge_a, edge_b);
			const double area2 = length(area_vector);
			const double uv_area2 = cross2(tri.uv[1] - tri.uv[0], tri.uv[2] - tri.uv[0]);
			if (!(area2 > 0.0)) {
				result["error"] = "Geometry contains a zero-area triangle.";
                result["error_kind"] = "zero_area_geometry";
                result["mesh_id"] = tri.mesh_id;
                result["triangle_id"] = i;
				return result;
			}
			if (tri.mesh_id >= 0 && uv_area2 == 0.0) {
				result["error"] = "Receiver geometry contains a triangle with degenerate UV2 area.";
                result["error_kind"] = "degenerate_uv2";
                result["mesh_id"] = tri.mesh_id;
                result["triangle_id"] = i;
				return result;
			}
			tri.area = area2 * 0.5;

            tri.normal = area_vector / area2;
            for (int v = 0; v < 3; ++v) {
                tri.shading_normal[v] = extended ? to_v3(normals[i*3+v]) : tri.normal;
                if (!finite(tri.shading_normal[v]) || length_squared(tri.shading_normal[v]) <= 0.0 || dot(tri.shading_normal[v],tri.normal) <= 0.0) {
                    result["error"] = "Shading normals must be finite, nonzero and in the geometric front hemisphere.";
                    return result;
                }
                tri.shading_normal[v] = normalized(tri.shading_normal[v]);
            }
            if (extended) {
                tri.roughness = roughness[i];
                tri.metallic = metallic[i];
                tri.specular = specular[i];
                tri.diffuse_mode = diffuse_modes[i];
                if (!std::isfinite(tri.roughness) || !std::isfinite(tri.metallic) || !std::isfinite(tri.specular) ||
                        tri.roughness < 0.0 || tri.roughness > 1.0 || tri.metallic < 0.0 || tri.metallic > 1.0 ||
                        tri.specular < 0.0 || tri.specular > 1.0 || tri.diffuse_mode > 1 ||
                        (tri.roughness == 0.0 && (tri.specular > 0.0 || tri.metallic > 0.0))) {
                    result["error"] = "v3 supports Lambert(0)/Burley(1), unit-range parameters and positive roughness for reflective GGX; delta mirrors are unsupported.";
                    return result;
                }
            }
            if ((tri.flags & ~3U) != 0U || ((tri.flags & 2U) != 0U && (tri.flags & 1U) == 0U)) {
                result["error"] = "Unknown or inconsistent material flags: two-sided emission requires two-sided geometry.";
                return result;
            }
			tri.bounds_min = Scene::min_v(tri.v[0], Scene::min_v(tri.v[1], tri.v[2]));
			tri.bounds_max = Scene::max_v(tri.v[0], Scene::max_v(tri.v[1], tri.v[2]));
			tri.centroid = (tri.v[0] + tri.v[1] + tri.v[2]) / 3.0;
			tri.light_weight = tri.area * luminance(tri.emission);
			if (tri.light_weight > 0.0) {
				scene.emitters.push_back(static_cast<int32_t>(scene.triangles.size()));
				scene.emitter_weight_sum += tri.light_weight;
			}
			scene.triangles.push_back(tri);
		}
		for (int32_t emitter_id : scene.emitters) {
			scene.triangles[emitter_id].light_probability = scene.triangles[emitter_id].light_weight / scene.emitter_weight_sum;
		}
		scene.order.resize(scene.triangles.size());
		std::iota(scene.order.begin(), scene.order.end(), 0);
		scene.nodes.reserve(scene.triangles.size() * 2);
		scene.build_node(0, static_cast<int32_t>(scene.order.size()));

		const size_t pixels_per_mesh = static_cast<size_t>(p_resolution) * static_cast<size_t>(p_resolution);
		if (pixels_per_mesh > 4'194'304U || pixels_per_mesh * static_cast<size_t>(p_mesh_count) > 67'108'864U) {
			result["error"] = "Requested atlas allocation exceeds the safe CPU memory limit.";
			return result;
		}
		std::vector<std::vector<Pixel>> atlases(static_cast<size_t>(p_mesh_count), std::vector<Pixel>(pixels_per_mesh));
		const double pixel_area = 1.0 / (static_cast<double>(p_resolution) * p_resolution);
        for (int32_t triangle_id = 0; triangle_id < static_cast<int32_t>(scene.triangles.size()); ++triangle_id) {
            if (cancel_requested.load(std::memory_order_relaxed)) {
                result["error"] = "Bake cancelled during atlas rasterization.";
                result["cancelled"] = true;
                return result;
            }
			const Triangle &tri = scene.triangles[triangle_id];
			if (tri.mesh_id < 0) {
				continue; // Source-only triangles still participate in BVH hits, emission and transport.
			}
			const double min_u = std::min(tri.uv[0].x, std::min(tri.uv[1].x, tri.uv[2].x));
			const double max_u = std::max(tri.uv[0].x, std::max(tri.uv[1].x, tri.uv[2].x));
			const double min_v = std::min(tri.uv[0].y, std::min(tri.uv[1].y, tri.uv[2].y));
			const double max_v = std::max(tri.uv[0].y, std::max(tri.uv[1].y, tri.uv[2].y));
			const int x0 = std::clamp(static_cast<int>(std::floor(min_u * p_resolution)), 0, p_resolution - 1);
			const int x1 = std::clamp(static_cast<int>(std::floor(max_u * p_resolution)), 0, p_resolution - 1);
			const int y0 = std::clamp(static_cast<int>(std::floor(min_v * p_resolution)), 0, p_resolution - 1);
			const int y1 = std::clamp(static_cast<int>(std::floor(max_v * p_resolution)), 0, p_resolution - 1);
			for (int y = y0; y <= y1; ++y) {
				for (int x = x0; x <= x1; ++x) {
					const double cell_x0 = static_cast<double>(x) / p_resolution;
					const double cell_y0 = static_cast<double>(y) / p_resolution;
					std::vector<V2> polygon{tri.uv[0], tri.uv[1], tri.uv[2]};
					polygon = clip_to_cell(std::move(polygon), cell_x0, cell_y0,
							static_cast<double>(x + 1) / p_resolution, static_cast<double>(y + 1) / p_resolution);
					const double area = std::abs(signed_area(polygon));
					if (!(area > 0.0)) {
						continue;
					}
					Pixel &pixel = atlases[tri.mesh_id][static_cast<size_t>(y) * p_resolution + x];
                    for (const UvPiece &existing : pixel.pieces) {
                        if (triangle_uv_interiors_disjoint(tri,scene.triangles[existing.triangle_id])) continue;
                        const double overlap = std::abs(signed_area(clip_to_convex(polygon, existing.polygon)));
						if (overlap > pixel_area * 1e-12) {
							result["error"] = String("UV2 charts overlap: mesh ") + String::num_int64(tri.mesh_id) +
                                    ", triangle " + String::num_int64(triangle_id) + " versus " + String::num_int64(existing.triangle_id) +
                                    ", texel (" + String::num_int64(x) + ", " + String::num_int64(y) + "), overlap area " + String::num_scientific(overlap) + ".";
                            result["error_kind"] = "uv2_overlap";
                            result["mesh_id"] = tri.mesh_id;
                            result["triangle_id"] = triangle_id;
                            result["other_triangle_id"] = existing.triangle_id;
                            result["texel_x"] = x;
                            result["texel_y"] = y;
                            result["overlap_area"] = overlap;
							return result;
						}
					}
					pixel.area += area;
					if (pixel.area > pixel_area * (1.0 + 1e-12)) {
						result["error"] = String("UV2 chart coverage exceeds one texel: mesh ") + String::num_int64(tri.mesh_id) +
                                ", triangle " + String::num_int64(triangle_id) + ", texel (" + String::num_int64(x) + ", " + String::num_int64(y) + ").";
                        result["error_kind"] = "uv2_coverage_overflow";
                        result["mesh_id"] = tri.mesh_id;
                        result["triangle_id"] = triangle_id;
                        result["texel_x"] = x;
                        result["texel_y"] = y;
                        result["coverage_area"] = pixel.area;
                        result["pixel_area"] = pixel_area;
						return result;
					}
					pixel.pieces.push_back({triangle_id, std::move(polygon), area});
				}
			}
		}


        // Workers write disjoint preallocated numeric arrays only. Godot Variant
        // construction and publication remain on the caller thread. Each texel's
        // seed is independent of scheduling, so worker count cannot change data.
        const unsigned available = std::max(1U,std::thread::hardware_concurrency());
        const int workers = p_workers == 0 ? static_cast<int>(std::min(available,16U)) : p_workers;
        if (workers < 1 || workers > 64) {
            result["error"] = "worker_count must be 0 (automatic) or 1..64.";
            return result;
        }
        Array layers;
        int64_t covered_texels_total = 0;
        int64_t path_count_total = 0;
        int64_t bounce_count_total = 0;
        int64_t rr_survivals_total = 0;
        int64_t covered_count = 0;
        for (const auto &atlas : atlases) for (const Pixel &pixel : atlas) if (!pixel.pieces.empty()) ++covered_count;
        total_texels.store(covered_count);
        for (int32_t mesh_id = 0; mesh_id < p_mesh_count; ++mesh_id) {
            const std::vector<Pixel> &atlas = atlases[mesh_id];
            PackedFloat32Array radiance;
            PackedFloat32Array variance;
            PackedByteArray coverage;
            radiance.resize(static_cast<int64_t>(pixels_per_mesh)*4);
            variance.resize(pixels_per_mesh);
            coverage.resize(pixels_per_mesh);
            auto radiance_w = radiance.ptrw();
            auto variance_w = variance.ptrw();
            auto coverage_w = coverage.ptrw();
            std::fill(radiance_w,radiance_w+pixels_per_mesh*4,0.0f);
            std::fill(variance_w,variance_w+pixels_per_mesh,0.0f);
            std::fill(coverage_w,coverage_w+pixels_per_mesh,0);
            std::vector<size_t> covered;
            for (size_t index = 0; index < pixels_per_mesh; ++index) if (!atlas[index].pieces.empty()) covered.push_back(index);
            std::atomic<size_t> next_pixel{0};
            std::atomic<bool> overflow{false};
            struct Counts { int64_t paths=0; int64_t bounces=0; int64_t survivals=0; };
            std::vector<Counts> counts(static_cast<size_t>(workers));
            auto worker = [&](int worker_id) {
                Counts &stats = counts[worker_id];
                for (;;) {
                    if (cancel_requested.load(std::memory_order_relaxed) || overflow.load(std::memory_order_relaxed)) return;
                    const size_t work_index = next_pixel.fetch_add(1,std::memory_order_relaxed);
                    if (work_index >= covered.size()) return;
                    const size_t pixel_index = covered[work_index];
                    const Pixel &pixel = atlas[pixel_index];
                    const size_t out_offset = pixel_index*4;
                    V3 mean{};
                    double luminance_mean = 0.0;
                    double luminance_m2 = 0.0;
                    Random rng(mix_seed(static_cast<uint64_t>(p_seed) ^ (static_cast<uint64_t>(mesh_id)<<40U) ^ pixel_index));
                    for (int32_t sample = 0; sample < p_samples_per_texel; ++sample) {
                        if (cancel_requested.load(std::memory_order_relaxed)) return;
                        double choice = rng.uniform()*pixel.area;
                        const UvPiece *piece = &pixel.pieces.back();
                        for (const UvPiece &candidate : pixel.pieces) {
                            if (choice <= candidate.area) { piece = &candidate; break; }
                            choice -= candidate.area;
                        }
                        const V2 uv = sample_polygon(piece->polygon,rng);
                        const Triangle &tri = scene.triangles[piece->triangle_id];
                        const V2 ab = tri.uv[1]-tri.uv[0];
                        const V2 ac = tri.uv[2]-tri.uv[0];
                        const V2 ap = uv-tri.uv[0];
                        const double denominator = cross2(ab,ac);
                        const double bary_u = cross2(ap,ac)/denominator;
                        const double bary_v = cross2(ab,ap)/denominator;
                        const V3 position = tri.v[0]*(1.0-bary_u-bary_v)+tri.v[1]*bary_u+tri.v[2]*bary_v;
                        const V3 normal = interpolated_normal(tri,bary_u,bary_v,true);
                        int64_t path_bounces = 0;
                        int64_t rr_survivals = 0;
                        const V3 value = scene.estimate(position,piece->triangle_id,normal,rng,path_bounces,rr_survivals);
                        if (!finite(value) || std::max({std::abs(value.x),std::abs(value.y),std::abs(value.z)}) > std::numeric_limits<float>::max()) {
                            overflow.store(true); return;
                        }
                        mean = mean+value;
                        const double sample_luma = luminance(value);
                        const double delta = sample_luma-luminance_mean;
                        luminance_mean += delta/(sample+1.0);
                        luminance_m2 += delta*(sample_luma-luminance_mean);
                        stats.bounces += path_bounces;
                        stats.survivals += rr_survivals;
                        ++stats.paths;
                    }
                    mean = mean/static_cast<double>(p_samples_per_texel);
                    const double sample_variance = p_samples_per_texel>1 ? luminance_m2/(p_samples_per_texel-1.0) : -1.0;
                    if (!finite(mean) || std::max({std::abs(mean.x),std::abs(mean.y),std::abs(mean.z),std::abs(sample_variance)}) > std::numeric_limits<float>::max() || !std::isfinite(sample_variance)) {
                        overflow.store(true); return;
                    }
                    radiance_w[out_offset+0] = static_cast<float>(mean.x);
                    radiance_w[out_offset+1] = static_cast<float>(mean.y);
                    radiance_w[out_offset+2] = static_cast<float>(mean.z);
                    radiance_w[out_offset+3] = 1.0f;
                    variance_w[pixel_index] = static_cast<float>(sample_variance);
                    coverage_w[pixel_index] = 255;
                    completed_texels.fetch_add(1,std::memory_order_relaxed);
                }
            };
            std::vector<std::thread> threads;
            // If the OS refuses a worker allocation, complete the same jobs on
            // already-started workers/caller instead of changing the estimator.
            try {
                for (int id=1; id<workers; ++id) threads.emplace_back(worker,id);
            } catch (const std::system_error &) { }
            worker(0);
            for (std::thread &thread : threads) thread.join();
            if (cancel_requested.load()) {
                result["error"] = "Bake cancelled; no partial atlas is published.";
                result["cancelled"] = true;
                return result;
            }
            if (overflow.load()) {
                result["error"] = "Path estimate or sample variance exceeded finite RGBAF range; no radiance clamp was applied.";
                return result;
            }
            for (const Counts &stats : counts) {
                path_count_total += stats.paths;
                bounce_count_total += stats.bounces;
                rr_survivals_total += stats.survivals;
            }
            const int64_t covered_texels = static_cast<int64_t>(covered.size());
            covered_texels_total += covered_texels;
            Dictionary layer;
            layer["mesh_id"] = mesh_id;
            layer["rgba"] = radiance;
            layer["variance"] = variance;
            layer["coverage"] = coverage;
            layer["covered_texels"] = covered_texels;
            layers.push_back(layer);
        }

		result["ok"] = true;
		result["layers"] = layers;
		result["triangle_count"] = static_cast<int64_t>(scene.triangles.size());
		result["emitter_triangle_count"] = static_cast<int64_t>(scene.emitters.size());
		result["covered_texels"] = covered_texels_total;
		result["path_count"] = path_count_total;
		result["bounce_count"] = bounce_count_total;
		result["rr_survivals"] = rr_survivals_total;
		result["average_path_bounces"] = path_count_total > 0 ? static_cast<double>(bounce_count_total) / path_count_total : 0.0;
		result["environment_radiance"] = p_environment_radiance;
		result["resolution"] = p_resolution;

        result["samples_per_texel"] = p_samples_per_texel;
        result["backend_contract_version"] = BACKEND_CONTRACT_VERSION;
        result["worker_count"] = workers;
        result["transport_model"] = "lambert_or_burley_smith_ggx_schlick_geometric_hemisphere_v3";
        result["environment_model"] = scene.environment.pixels.empty() ? "constant_radiance" : "piecewise_constant_hdr_latlong_solid_angle";
        result["directional_light_count"] = static_cast<int64_t>(scene.directional_lights.size());
        result["area_light_count"] = static_cast<int64_t>(scene.area_lights.size());
        result["area_light_model"] = "non_intersectable_rectangle_nee_engine_closest_distance_range";
        result["hard_bounce_limit"] = false;
        result["radiance_clamp"] = false;
        result["denoising"] = false;
		return result;
	}
};

void initialize_feng_lightmap_mc(ModuleInitializationLevel p_level) {
	if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		ClassDB::register_class<FengLightmapMCIntegrator>();
	}
}

void uninitialize_feng_lightmap_mc(ModuleInitializationLevel p_level) {
	if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT feng_lightmap_mc_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_feng_lightmap_mc);
	init_obj.register_terminator(uninitialize_feng_lightmap_mc);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
