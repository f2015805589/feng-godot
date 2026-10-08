// Production bodies come from methods.inc; these are value/API boundary doubles.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <vector>

using real_t = float;
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define CLAMP(v, lo, hi) MIN(MAX(v, lo), hi)
#define LOG(...)
struct Vector2i {
	int x = 0, y = 0;
	Vector2i() = default;
	Vector2i(int px, int py) : x(px), y(py) {}
	Vector2i operator/(int divisor) const { return {x / divisor, y / divisor}; }
	bool operator!=(Vector2i other) const { return x != other.x || y != other.y; }
};
struct Rect2i {
	Vector2i position, size;
	Rect2i(Vector2i p_position, Vector2i p_size) : position(p_position), size(p_size) {}
	Vector2i get_position() const { return position; }
	Vector2i get_size() const { return size; }
	bool has_point(Vector2i p) const { return p.x >= position.x && p.y >= position.y && p.x < position.x + size.x && p.y < position.y + size.y; }
};
struct Dictionary {
	std::map<std::pair<int, int>, int> values;
	int &operator[](Vector2i p) { return values[{p.x, p.y}]; }
	bool has(Vector2i p) const { return values.count({p.x, p.y}); }
};
constexpr int CELL_SIZE = 32;
struct Vector3 {
	float x = 0, y = 0, z = 0;
	Vector3() = default;
	Vector3(float px, float py, float pz) : x(px), y(py), z(pz) {}
};
struct AABB {
	float height = 0;
	bool operator!=(AABB other) const { return height != other.height; }
	bool operator==(AABB other) const { return !(*this != other); }
};
struct Transform3D {
	struct Basis { void scale(Vector3) {} } basis;
	Vector3 origin;
	Transform3D affine_inverse() const { return {}; }
	AABB xform(AABB bounds) const { return bounds; }
};
struct RID {
	int id = 0;
	bool is_valid() const { return id != 0; }
};
struct PackedFloat32Array {
	std::vector<float> data;
	int64_t size() const { return int64_t(data.size()); }
	void resize(int64_t size) { data.resize(size); }
	const float *ptr() const { return data.data(); }
	float *ptrw() { return data.data(); }
	bool operator!=(const PackedFloat32Array &other) const { return data != other.data; }
};
struct RenderingServer { enum { MULTIMESH_TRANSFORM_3D }; };
struct Server {
	int next = 1, releases = 0, uploads = 0, bounds_updates = 0;
	std::map<int, bool> live;
	RID multimesh_create() { live[next] = true; return {next++}; }
	RID instance_create2(RID, RID) { return multimesh_create(); }
	void free_rid(RID rid) { if (!live.erase(rid.id)) { throw std::runtime_error("RID released twice"); } ++releases; }
	void multimesh_allocate_data(RID, int, int, bool, bool) {}
	void multimesh_set_mesh(RID, RID) {}
	void multimesh_instance_set_transform(RID, int, Transform3D) {}
	void instance_set_transform(RID, Transform3D) {}
	void instance_set_custom_aabb(RID, AABB) { ++bounds_updates; }
	void multimesh_set_buffer(RID, const PackedFloat32Array &) { ++uploads; }
	void multimesh_set_visible_instances(RID, int) {}
	void multimesh_set_custom_aabb(RID, AABB) { ++bounds_updates; }
} server;
#define RS (&server)
struct World { RID get_scenario() const { return {}; } } world;
struct Terrain3D { World *get_world_3d() { return &world; } } terrain;
struct Time {
	static Time *get_singleton() { static Time time; return &time; }
	uint64_t get_ticks_usec() const { return 0; }
};
struct TerrainProfileZone { explicit TerrainProfileZone(const char *) {} };
uint32_t next_power_of_2(uint32_t count) { uint32_t power = 1; while (power < count) { power *= 2; } return power; }
class Terrain3DCDLOD {
public:
	struct Batch {
		RID multimesh, instance;
		std::vector<RID> region_instances, region_draws;
		int capacity = 0;
		PackedFloat32Array previous, staging;
		std::vector<float> previous_instances;
		AABB bounds;
	};
	using Lists = std::array<std::vector<float>, 2>;
	using Bounds = std::array<AABB, 2>;
	Terrain3D *_terrain = &terrain;
	RID _mesh;
	bool _adaptive = true;
	double _upload_ms = 0;
	std::array<Batch, 2> _batches;
	void _upload(Batch &, PackedFloat32Array &, const AABB &);
	void submit(const Lists &, const Bounds &);
};
struct Color {
	float r = 0, g = 0, b = 0, a = 1;
	float operator[](int index) const { return std::array<float, 4>{r, g, b, a}.at(index); }
};
template <class T> struct Ref : std::shared_ptr<T> {
	using std::shared_ptr<T>::shared_ptr;
	bool is_valid() const { return bool(*this); }
};
struct Image {
	enum { FORMAT_RGBA8, FORMAT_RGB8 };
	std::vector<Color> pixels;
	static Ref<Image> create_empty(int width, int height, bool, int) {
		Ref<Image> image(new Image);
		image->pixels.resize(width * height);
		return image;
	}
	int get_width() const { return int(pixels.size()); }
	int get_height() const { return 1; }
	Vector2i get_size() const { return {get_width(), 1}; }
	bool is_empty() const { return pixels.empty(); }
	Color get_pixel(int x, int) const { return pixels.at(x); }
	void set_pixel(int x, int, Color color) { pixels.at(x) = color; }
};
struct Terrain3DUtil {
	static Ref<Image> pack_image(const Ref<Image> &, const Ref<Image> &, const Ref<Image> &, bool, bool, bool, int, int);
	static Ref<Image> luminance_to_height(const Ref<Image> &);
};
#include "methods.inc"

static void require(bool condition, const char *message) {
	if (!condition) { throw std::runtime_error(message); }
}
static std::vector<float> record() {
	std::vector<float> result(16, 0);
	result[0] = result[5] = result[10] = result[15] = 1;
	return result;
}
static void cdlod_bounds() {
	server = {};
	Terrain3DCDLOD cdlod;
	Terrain3DCDLOD::Lists lists{record(), {}};
	cdlod.submit(lists, {{{1}, {0}}});
	const int uploads = server.uploads;
	cdlod.submit(lists, {{{9}, {0}}});
	require(cdlod._batches[0].bounds.height == 9, "same-transform bounds must refresh");
	require(server.uploads == uploads, "bounds-only refresh must not upload instance data");
	const int updates = server.bounds_updates;
	cdlod.submit(lists, {{{9}, {0}}});
	require(server.bounds_updates == updates && server.uploads == uploads, "unchanged batch must do no server work");
}
static void regular_release() {
	server = {};
	Terrain3DCDLOD cdlod;
	cdlod._adaptive = false;
	Terrain3DCDLOD::Lists lists{record(), record()};
	cdlod.submit(lists, {{{1}, {1}}});
	require(server.live.size() == 4, "two regular patches own four RIDs");
	lists[0].clear();
	cdlod.submit(lists, {{{0}, {1}}});
	require(server.live.size() == 2 && cdlod._batches[0].region_instances.empty(), "empty main batch must release its region RIDs");
	lists[1].clear();
	cdlod.submit(lists, {});
	require(server.live.empty() && server.releases == 4, "empty shadow batch must release remaining RIDs");
	cdlod.submit(lists, {});
	require(server.releases == 4, "repeated empty pass must not release twice");
	cdlod.submit({record(), {}}, {{{2}, {0}}});
	require(server.live.size() == 2, "region may reload after emptying");
}
static Ref<Image> gray(std::initializer_list<float> values) {
	auto image = Image::create_empty(int(values.size()), 1, false, 0);
	int x = 0;
	for (float value : values) { image->set_pixel(x++, 0, {value, value, value, value}); }
	return image;
}
static void normalization(bool luminance) {
	for (auto image : {gray({0.2f, 0.8f}), gray({0.5f, 0.5f}), gray({0.f, 0.f})}) {
		auto output = luminance ? Terrain3DUtil::luminance_to_height(image) :
				Terrain3DUtil::pack_image(image, image, {}, false, false, true, 0, 0);
		const float first = luminance ? output->get_pixel(0, 0).r : output->get_pixel(0, 0).a;
		const float last = luminance ? output->get_pixel(1, 0).r : output->get_pixel(1, 0).a;
		const bool constant = image->get_pixel(0, 0).r == image->get_pixel(1, 0).r;
		require(std::isfinite(first) && std::abs(first) < 1e-5f, "nonzero minimum/constant range must normalize to zero");
		require(std::isfinite(last) && std::abs(last - (constant ? 0.f : 1.f)) < 1e-5f, "normalized endpoint must retain finite full range");
	}
}
static void cell_bounds() {
	for (Vector2i origin : {Vector2i{-64, -32}, Vector2i{32, 64}, Vector2i{-63, -31}}) {
		for (Vector2i size : {Vector2i{64, 96}, Vector2i{0, 32}, Vector2i{31, 31}}) {
			const Rect2i rect{origin, size};
			const Vector2i first = origin / CELL_SIZE, count = size / CELL_SIZE;
			for (int y = -4; y < 8; ++y) {
				for (int x = -4; x < 8; ++x) {
					const bool expected = x >= first.x && y >= first.y && x < first.x + count.x && y < first.y + count.y;
					require(copied_cell(rect, {x, y}) == expected, "cell copy must retain truncated-coordinate half-open bounds");
				}
			}
		}
	}
}
int main() {
	int failures = 0;
	const std::pair<const char *, void (*)()> tests[] = {
		{"CDLOD bounds", cdlod_bounds}, {"region RID release", regular_release},
		{"alpha normalization", [] { normalization(false); }},
		{"luminance normalization", [] { normalization(true); }}, {"cell copy bounds", cell_bounds}};
	for (const auto &[name, test] : tests) {
		try { test(); std::cout << "PASS " << name << '\n'; }
		catch (const std::exception &error) { ++failures; std::cerr << "FAIL " << name << ": " << error.what() << '\n'; }
	}
	return failures ? 1 : 0;
}
