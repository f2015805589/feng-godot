#[compute]
#version 450
// Layout 12 consumes complete CPU-built receiver-chart records. BVH reads here
// are only the existing PRT gather/visibility path, never per-cell chart search.
layout(local_size_x = 64) in;
layout(set = 0, binding = 0) uniform sampler2D geometry_atlas;
layout(set = 0, binding = 1) uniform isampler2D index_map;
layout(set = 0, binding = 2, std430) readonly buffer VisibilityNodes { vec4 nodes[]; } visibility_bvh;
layout(set = 0, binding = 3, std430) readonly buffer VisibilityTriangles { vec4 triangles[]; } visibility_geometry;
layout(set = 0, binding = 4, std430) readonly buffer Lighting { vec4 values[]; } directional_lighting;
layout(set = 0, binding = 5, std430) readonly buffer Jobs { ivec4 cells[]; } jobs;
layout(rgba32f, set = 0, binding = 6) uniform image3D cache_image;
layout(rgba32i, set = 0, binding = 7) uniform iimage3D cache_tags;
layout(set = 0, binding = 8, std140) uniform GIParams {
	mat4 inverse_projection; mat4 world_to_grid; mat4 view_to_world;
	vec4 grid; vec4 control; vec4 lighting_sh[7]; vec4 sky_lighting_sh[7];
} params;
layout(r32ui, set = 0, binding = 11) uniform uimage3D support_image;

struct BlockChartRecord {
	vec4 anchor_triangle; // anchor.xyz, exact bake triangle + 1
	vec4 normal_patch;    // unit geometric normal.xyz, patch identifier
	vec4 domain;          // effective R, effective H, normal dot minimum, stable component id
};
struct BlockChartJob {
	uvec4 header; // operation flags, chart count, summary word, layout version
	BlockChartRecord chart0;
	BlockChartRecord chart1;
	BlockChartRecord chart2;
	vec4 summary_normal_patch;      // nbar.xyz, common patch identifier
	vec4 summary_center_component;  // cylinder center.xyz, stable component id
	vec4 summary_domain;             // Rfast, Hfast, max normal deviation, exact float uint16 slot map
};
layout(set = 0, binding = 13, std430) readonly buffer ChartGeometryJobs {
	BlockChartJob records[];
} chart_geometry;
layout(push_constant, std430) uniform FillParameters {
	int jobs; int resolution; int epoch; float base_spacing;
} config;

#include "magic_gi_visibility.glslinc"
#include "magic_gi_clv_layout.glslinc"
#define MAGIC_INDEX_BINDING 9
#define MAGIC_CLUSTER_BINDING 10
#include "magic_gi_index.glslinc"
#include "magic_gi_probe_clusters.glslinc"
#define LOOKUP_CELL_RADIUS 2
#define probe_lighting directional_lighting
vec2 sample_visibility_moments(int probe, vec3 direction) { return vec2(0.0); }
float chebyshev_visibility(vec2 moments, float distance, float variance) { return 0.0; }
#include "magic_gi_sh.glslinc"
#include "magic_gi_clv_stencil.glslinc"
#include "magic_gi_gather.glslinc"

const int B12_CHART_COLUMNS = 23;
const int B12_RADIANCE_COLUMNS = 18;
const int B12_SECONDARY_DIFFUSE = 18;
const int B12_PRIMARY_DIFFUSE = 19;
const int B12_METADATA = 20;
const int B12_ANCHOR = 21;
const int B12_DOMAIN = 22;
const int B12_SUMMARY_NORMAL_PATCH = 69;
const int B12_SUMMARY_CENTER_COMPONENT = 70;
const int B12_SUMMARY_DOMAIN = 71;
const uint B12_OP_MASK = CLV_BLOCK12_JOB_WRITE_CHARTS
		| CLV_BLOCK12_JOB_WRITE_SUMMARY | CLV_BLOCK12_JOB_RELIGHT_CACHED;
const uint B12_SUMMARY_VALID = 1u;
const uint B12_CORNER_MASK_SHIFT = 8u; // job-record mask
const uint B12_SUPPORT_CORNER_MASK_SHIFT = 9u;
const float B12_CELL_DOMAIN_HALF_EXTENT_STEPS = 1.75;

ivec3 b12_slot(ivec4 job) {
	ivec3 slot = ((job.xyz % config.resolution) + config.resolution) % config.resolution;
	slot.z += job.w * config.resolution;
	return slot;
}
int b12_column(int chart, int local_column) {
	return chart * B12_CHART_COLUMNS + local_column;
}
vec4 b12_load(ivec3 slot, int chart, int local_column) {
	return imageLoad(cache_image,
			slot + ivec3(b12_column(chart, local_column) * config.resolution, 0, 0));
}
void b12_store(ivec3 slot, int chart, int local_column, vec4 value) {
	imageStore(cache_image,
			slot + ivec3(b12_column(chart, local_column) * config.resolution, 0, 0), value);
}
bool b12_finite_vec4(vec4 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool b12_validate_chart(BlockChartRecord record, vec3 cell_center, float step_size,
		int triangle_count, out vec3 anchor, out vec3 chart_normal, out int triangle,
		out int patch_id, out float radius, out float half_width, out float min_normal_dot,
		out int component_id) {
	anchor = record.anchor_triangle.xyz;
	chart_normal = record.normal_patch.xyz;
	triangle = -1;
	patch_id = -1;
	component_id = -1;
	float triangle_plus_one = record.anchor_triangle.w;
	float patch_value = record.normal_patch.w;
	float component_value = record.domain.w;
	radius = record.domain.x;
	half_width = record.domain.y;
	min_normal_dot = record.domain.z;
	float center_magnitude = max(step_size, max(max(abs(cell_center.x), abs(cell_center.y)), abs(cell_center.z)));
	float center_margin = max(1e-5, center_magnitude * 1.9073486328125e-6);
	float domain_half_extent = B12_CELL_DOMAIN_HALF_EXTENT_STEPS * step_size + center_margin;
	float domain_diameter = 2.0 * length(vec3(domain_half_extent));
	if (!b12_finite_vec4(record.anchor_triangle) || !b12_finite_vec4(record.normal_patch)
			|| !b12_finite_vec4(record.domain)
			|| !(triangle_plus_one >= 1.0) || floor(triangle_plus_one) != triangle_plus_one
			|| !(patch_value > 0.0) || floor(patch_value) != patch_value
			|| patch_value > float(triangle_count)
			|| !(component_value > 0.0) || floor(component_value) != component_value
			|| !(radius > 0.0) || radius > domain_diameter
			|| !(half_width > 0.0) || half_width > domain_diameter
			|| abs(min_normal_dot - CLV_BLOCK12_CONSUMER_NORMAL_DOT_MIN) > 1e-5
			|| !visibility_finite_vec3(anchor) || !visibility_finite_vec3(chart_normal)
			|| triangle_count <= 0 || component_value > float(triangle_count)
			|| triangle_count != visibility_geometry.triangles.length() / 3
			|| triangle_plus_one > float(triangle_count)) { return false; }
	float n2 = dot(chart_normal, chart_normal);
	if (!(n2 > 1e-12) || isnan(n2) || isinf(n2) || abs(n2 - 1.0) > 1e-3) { return false; }
	int triangle_id = int(triangle_plus_one) - 1;
	vec4 tri_a = visibility_geometry.triangles[triangle_id * 3];
	vec4 tri_e1 = visibility_geometry.triangles[triangle_id * 3 + 1];
	vec4 tri_e2 = visibility_geometry.triangles[triangle_id * 3 + 2];
	vec3 geometric = cross(tri_e2.xyz, tri_e1.xyz);
	float g2 = dot(geometric, geometric);
	if (!visibility_finite_vec3(tri_a.xyz) || !visibility_finite_vec3(tri_e1.xyz)
			|| !visibility_finite_vec3(tri_e2.xyz) || tri_e2.w != patch_value
			|| !visibility_finite_vec3(geometric) || !(g2 > 1e-12)
			|| isnan(g2) || isinf(g2)
			|| dot(geometric * inversesqrt(g2), chart_normal) < 0.999) { return false; }
	if (any(greaterThan(abs(anchor - cell_center), vec3(domain_half_extent)))) { return false; }
	triangle = triangle_id;
	patch_id = int(patch_value);
	component_id = int(component_value);
	chart_normal *= inversesqrt(n2);
	return true;
}

void b12_clear_chart(ivec3 slot, int chart) {
	for (int column = 0; column < B12_CHART_COLUMNS; column++) {
		b12_store(slot, chart, column, vec4(0.0));
	}
	b12_store(slot, chart, B12_METADATA, vec4(0.0, 0.0, 0.0, -1.0));
}

void b12_clear_summary(ivec3 slot) {
	imageStore(cache_image, slot + ivec3(B12_SUMMARY_NORMAL_PATCH * config.resolution, 0, 0), vec4(0.0));
	imageStore(cache_image, slot + ivec3(B12_SUMMARY_CENTER_COMPONENT * config.resolution, 0, 0), vec4(0.0));
	imageStore(cache_image, slot + ivec3(B12_SUMMARY_DOMAIN * config.resolution, 0, 0), vec4(0.0));
}

bool b13_unselected_chart_may_compete(ivec3 corner_slot, int selected_chart,
		vec3 nbar, vec3 summary_center, float summary_radius, float summary_height,
		int triangle_count, float margin) {
	float summary_bound_radius = length(vec2(summary_radius, summary_height));
	for (int other_chart = 0; other_chart < 3; other_chart++) {
		if (other_chart == selected_chart) { continue; }
		uint visible_bit = 1u << uint(other_chart * 2);
		uint certified_bit = 1u << uint(other_chart * 2 + 1);
		uint corner_support = imageLoad(support_image, corner_slot).r;
		if ((corner_support & (visible_bit | certified_bit)) != (visible_bit | certified_bit)) {
			continue;
		}
		vec4 metadata = b12_load(corner_slot, other_chart, B12_METADATA);
		vec4 anchor = b12_load(corner_slot, other_chart, B12_ANCHOR);
		vec4 domain = b12_load(corner_slot, other_chart, B12_DOMAIN);
		if (!b12_finite_vec4(metadata) || !b12_finite_vec4(anchor) || !b12_finite_vec4(domain)
				|| !(metadata.w > 0.0) || floor(metadata.w) != metadata.w
				|| metadata.w > float(triangle_count) || !(anchor.w >= 1.0)
				|| floor(anchor.w) != anchor.w || anchor.w > float(triangle_count)
				|| !(domain.x > 0.0) || !(domain.y > 0.0)
				|| abs(domain.z - CLV_BLOCK12_CONSUMER_NORMAL_DOT_MIN) > 1e-5
				|| !(domain.w > 0.0) || floor(domain.w) != domain.w
				|| domain.w > float(triangle_count)) { return true; }
		float normal_length_squared = dot(metadata.xyz, metadata.xyz);
		if (!(normal_length_squared > 1e-12) || isnan(normal_length_squared)
				|| isinf(normal_length_squared) || abs(normal_length_squared - 1.0) > 1e-3) {
			return true;
		}
		vec3 other_normal = metadata.xyz * inversesqrt(normal_length_squared);
		// Any normal admitted by the common summary cap has dot >= .95 with
		// nbar. A competing chart whose normal is below .46 cannot reach the
		// per-chart .72 gate anywhere in that cap; .46 is below the exact
		// spherical-cap intersection bound (~.4673) for conservative slack.
		if (dot(other_normal, nbar) <= 0.46) { continue; }
		float other_bound_radius = length(domain.xy);
		if (distance(anchor.xyz, summary_center)
				<= summary_bound_radius + other_bound_radius + margin) { return true; }
	}
	return false;
}

void b12_store_summary(ivec3 slot, ivec4 job, bool base_tag_current,
		BlockChartJob job_record, inout uint support) {
	uint summary_word = job_record.header.z;
	uint corner_mask = (summary_word >> B12_CORNER_MASK_SHIFT) & 0xffu;
	vec4 normal_patch = job_record.summary_normal_patch;
	vec4 center_component = job_record.summary_center_component;
	vec4 domain = job_record.summary_domain;
	uint slot_map = 0u;
	int uniform_chart = -1;
	bool slot_map_valid = clv_block13_decode_slot_map(domain.w, slot_map, uniform_chart);
	bool valid = base_tag_current && (summary_word & B12_SUMMARY_VALID) != 0u
			&& corner_mask == 0xffu
			&& (summary_word & ~(B12_SUMMARY_VALID | 0x0000ff00u)) == 0u
			&& slot_map_valid;
	int triangle_count = visibility_geometry.triangles.length() / 3;
	valid = valid && b12_finite_vec4(normal_patch) && b12_finite_vec4(center_component)
			&& b12_finite_vec4(domain) && normal_patch.w > 0.0
			&& floor(normal_patch.w) == normal_patch.w
			&& normal_patch.w <= float(triangle_count)
			&& center_component.w > 0.0
			&& floor(center_component.w) == center_component.w
			&& center_component.w <= float(triangle_count)
			&& domain.x > 0.0 && domain.y > 0.0 && domain.z >= 0.0
			&& domain.z <= 1.0 && triangle_count > 0;
	float nbar_length_squared = dot(normal_patch.xyz, normal_patch.xyz);
	valid = valid && visibility_finite_vec3(normal_patch.xyz)
			&& nbar_length_squared > 1e-12 && !isnan(nbar_length_squared)
			&& !isinf(nbar_length_squared) && abs(nbar_length_squared - 1.0) <= 1e-3;
	vec3 nbar = valid ? normal_patch.xyz * inversesqrt(nbar_length_squared) : vec3(0.0);
	float min_radius_margin = 1e30;
	float min_height_margin = 1e30;
	float max_sine = 0.0;
	float max_normal_deviation = 0.0;
	vec3 anchor_sum = vec3(0.0);
	float step_size = config.base_spacing * float(1 << job.w);
	float summary_magnitude = max(step_size, max(max(abs(center_component.x), abs(center_component.y)),
			abs(center_component.z)));
	float summary_margin = max(1e-5, summary_magnitude * 1.9073486328125e-6);
	for (int corner = 0; corner < 8 && valid; corner++) {
		int chart = int(clv_block13_slot_for_corner(slot_map, corner));
		ivec3 logical_cell = job.xyz + ivec3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
		ivec3 corner_slot = b12_slot(ivec4(logical_cell, job.w));
		ivec4 corner_tag = imageLoad(cache_tags, corner_slot);
		uint corner_support = corner == 0 ? support : imageLoad(support_image, corner_slot).r;
		uint corner_bits = 3u << uint(chart * 2);
		vec4 metadata = b12_load(corner_slot, chart, B12_METADATA);
		vec4 anchor_triangle = b12_load(corner_slot, chart, B12_ANCHOR);
		vec4 chart_domain = b12_load(corner_slot, chart, B12_DOMAIN);
		if (!all(equal(corner_tag.xyz, logical_cell)) || corner_tag.w != config.epoch
				|| (corner_support & corner_bits) != corner_bits
				|| !b12_finite_vec4(metadata) || !b12_finite_vec4(anchor_triangle)
				|| !b12_finite_vec4(chart_domain)
				|| metadata.w != normal_patch.w || chart_domain.w != center_component.w
				|| !(anchor_triangle.w >= 1.0) || floor(anchor_triangle.w) != anchor_triangle.w
				|| anchor_triangle.w > float(triangle_count)
				|| !(chart_domain.x > 0.0) || !(chart_domain.y > 0.0)
				|| abs(chart_domain.z - CLV_BLOCK12_CONSUMER_NORMAL_DOT_MIN) > 1e-5
				|| !(chart_domain.w > 0.0) || floor(chart_domain.w) != chart_domain.w
				|| chart_domain.w > float(triangle_count)) {
			valid = false;
			break;
		}
		float normal_length_squared = dot(metadata.xyz, metadata.xyz);
		if (!(normal_length_squared > 1e-12) || isnan(normal_length_squared)
				|| isinf(normal_length_squared) || abs(normal_length_squared - 1.0) > 1e-3) {
			valid = false;
			break;
		}
		vec3 chart_normal = metadata.xyz * inversesqrt(normal_length_squared);
		float normal_dot = dot(chart_normal, nbar);
		if (normal_dot < 0.99) { valid = false; break; }
		vec3 delta = center_component.xyz - anchor_triangle.xyz;
		float plane = dot(delta, chart_normal);
		float tangent = length(delta - chart_normal * plane);
		float sine = sqrt(max(0.0, 1.0 - normal_dot * normal_dot));
		min_radius_margin = min(min_radius_margin, chart_domain.x - tangent);
		min_height_margin = min(min_height_margin, chart_domain.y - abs(plane));
		max_sine = max(max_sine, sine);
		max_normal_deviation = max(max_normal_deviation, length(chart_normal - nbar));
		anchor_sum += anchor_triangle.xyz;
		// Summary readiness is a geometry-epoch certificate. Every mapped chart
		// must carry finite SH and both finite preconvolved fields; the pixel
		// consumer can then use either the uniform filter or the mixed aligned path.
		for (int column = 0; column < B12_RADIANCE_COLUMNS + 2; column++) {
			vec4 radiance = b12_load(corner_slot, chart, column);
			if (!b12_finite_vec4(radiance)
					|| (column >= B12_SECONDARY_DIFFUSE && radiance.w < 0.5)) {
				valid = false;
				break;
			}
		}
		if (!valid) {
			break;
		}
		// Uniform maps retain the layout-12 summary acceptance path. Mixed maps
		// need this extra per-corner competition guard because their slot identity
		// can change across corners.
		if (uniform_chart < 0 && b13_unselected_chart_may_compete(corner_slot, chart, nbar,
				center_component.xyz, domain.x, domain.y, triangle_count, summary_margin)) {
			valid = false;
			break;
		}
	}
	if (valid) {
		float magnitude = max(step_size, max(max(abs(center_component.x), abs(center_component.y)),
				abs(center_component.z)));
		float tolerance = max(1e-5, step_size * 1e-4)
				+ max(1e-5, magnitude * 1.9073486328125e-6);
		float denominator = 1.0 - max_sine * max_sine;
		if (!(denominator > 1e-6) || min_radius_margin <= 0.0 || min_height_margin <= 0.0) {
			valid = false;
		} else {
			float certified_radius = (min_radius_margin - max_sine * min_height_margin) / denominator;
			float certified_height = (min_height_margin - max_sine * min_radius_margin) / denominator;
			valid = certified_radius > tolerance && certified_height > tolerance
					&& domain.x <= certified_radius - tolerance
					&& domain.y <= certified_height - tolerance
					&& domain.z >= max_normal_deviation + tolerance
					&& length(center_component.xyz - anchor_sum * 0.125) <= tolerance;
		}
	}
	if (valid) {
		imageStore(cache_image, slot + ivec3(B12_SUMMARY_NORMAL_PATCH * config.resolution, 0, 0),
				normal_patch);
		imageStore(cache_image, slot + ivec3(B12_SUMMARY_CENTER_COMPONENT * config.resolution, 0, 0),
				center_component);
		imageStore(cache_image, slot + ivec3(B12_SUMMARY_DOMAIN * config.resolution, 0, 0), domain);
		support |= CLV_BLOCK12_SUPPORT_SUMMARY_READY;
		uint summary_hint = uniform_chart >= 0 ? uint(uniform_chart) : 3u;
		support = (support & ~CLV_BLOCK12_SUPPORT_SUMMARY_SLOT_MASK)
				| (summary_hint << CLV_BLOCK12_SUPPORT_SUMMARY_SLOT_SHIFT);
	} else {
		imageStore(cache_image, slot + ivec3(B12_SUMMARY_NORMAL_PATCH * config.resolution, 0, 0), vec4(0.0));
		imageStore(cache_image, slot + ivec3(B12_SUMMARY_CENTER_COMPONENT * config.resolution, 0, 0), vec4(0.0));
		imageStore(cache_image, slot + ivec3(B12_SUMMARY_DOMAIN * config.resolution, 0, 0), vec4(0.0));
		support &= ~CLV_BLOCK12_SUPPORT_SUMMARY_READY;
		support &= ~CLV_BLOCK12_SUPPORT_SUMMARY_SLOT_MASK;
	}
	support = (support & ~CLV_BLOCK12_SUPPORT_POSITIVE_CORNER_MASK)
			| ((valid ? 0xffu : 0u) << B12_SUPPORT_CORNER_MASK_SHIFT);
}

bool b12_coefficients_finite(vec4 coefficients[18]) {
	for (int i = 0; i < 18; i++) {
		if (!b12_finite_vec4(coefficients[i])) { return false; }
	}
	return true;
}
bool b12_store_radiance(ivec3 slot, int chart, vec3 normal,
		vec4 coefficients[18], bool supported) {
	vec3 secondary_diffuse = vec3(0.0);
	vec3 primary_diffuse = vec3(0.0);
	if (supported) {
		float basis[9];
		diffuse_basis(normal, basis);
		for (int i = 0; i < 9; i++) {
			secondary_diffuse += coefficients[i].rgb * basis[i];
			primary_diffuse += coefficients[i + 9].rgb * basis[i];
		}
		supported = visibility_finite_vec3(secondary_diffuse)
				&& visibility_finite_vec3(primary_diffuse);
	}
	if (!supported) {
		for (int i = 0; i < 18; i++) { coefficients[i] = vec4(0.0); }
		secondary_diffuse = vec3(0.0);
		primary_diffuse = vec3(0.0);
	}
	for (int i = 0; i < 18; i++) { b12_store(slot, chart, i, coefficients[i]); }
	b12_store(slot, chart, B12_SECONDARY_DIFFUSE,
			vec4(secondary_diffuse, supported ? 1.0 : 0.0));
	b12_store(slot, chart, B12_PRIMARY_DIFFUSE,
			vec4(primary_diffuse, supported ? 1.0 : 0.0));
	return supported;
}

void b12_gather_or_relight(ivec3 slot, int chart, vec3 anchor, vec3 normal,
		int triangle, bool try_relight, inout uint support) {
	vec4 coefficients[18];
	float candidate_weight = 0.0;
	float visible_support_weight = 0.0;
	bool relit = false;
	clv_stencil_reset(slot, chart);
	if (try_relight) {
		relit = clv_stencil_relight(coefficients, candidate_weight, visible_support_weight);
	}
	if (!relit) {
		gather_probe_field(anchor, normal, triangle, true, true, true, coefficients,
				candidate_weight, visible_support_weight, false);
		clv_stencil_publish(coefficients[0].w, candidate_weight, visible_support_weight);
	}
	bool supported = visible_support_weight > 1e-10 && b12_coefficients_finite(coefficients);
	supported = b12_store_radiance(slot, chart, normal, coefficients, supported);
	uint visible_bit = 1u << uint(chart * 2);
	if (supported) { support |= visible_bit; }
	else { support &= ~visible_bit; }
}

void main() {
	uint job_index = gl_WorkGroupID.x;
	if (config.jobs <= 0 || job_index >= uint(config.jobs) || gl_LocalInvocationIndex != 0u) { return; }
	ivec4 job = jobs.cells[job_index];
	ivec3 slot = b12_slot(job);
	BlockChartJob job_record = chart_geometry.records[job_index];
	uint operations = job_record.header.x;
	if (job_record.header.w != CLV_BLOCK13_DOMAIN_POLICY_VERSION
			|| (operations & ~B12_OP_MASK) != 0u || job_record.header.y > 3u
			|| job.w < 0 || job.w >= 3 || config.resolution <= 1 || config.epoch == 0) { return; }
	float step_size = config.base_spacing * float(1 << job.w);
	vec3 cell_center = (vec3(job.xyz) + vec3(0.5)) * step_size;
	if (!(step_size > 0.0) || isnan(step_size) || isinf(step_size)
			|| !visibility_finite_vec3(cell_center)) { return; }
	bool write_charts = (operations & CLV_BLOCK12_JOB_WRITE_CHARTS) != 0u;
	bool write_summary = (operations & CLV_BLOCK12_JOB_WRITE_SUMMARY) != 0u;
	bool relight_cached = (operations & CLV_BLOCK12_JOB_RELIGHT_CACHED) != 0u;
	if (!write_charts && !write_summary && !relight_cached) { return; }
	if (write_summary && (write_charts || relight_cached)) { return; }
	ivec4 tag = imageLoad(cache_tags, slot);
	bool tag_current = all(equal(tag.xyz, job.xyz)) && tag.w == config.epoch;
	uint support = tag_current ? imageLoad(support_image, slot).r : 0u;
	if (write_charts) {
		support = 0u;
		b12_clear_summary(slot);
	} else if (relight_cached) {
		// A relight can change visible bits; invalidate this cell's and queued
		// neighbor summaries before the next consumer dispatch.
		support &= ~CLV_BLOCK12_SUPPORT_SUMMARY_MASK;
		b12_clear_summary(slot);
	}
	if (write_charts) {
		if (job_record.header.y > 0u) {
			int triangle_count = visibility_geometry.triangles.length() / 3;
			BlockChartRecord records[3];
			records[0] = job_record.chart0;
			records[1] = job_record.chart1;
			records[2] = job_record.chart2;
			for (int chart = 0; chart < int(job_record.header.y); chart++) {
				vec3 anchor; vec3 chart_normal;
				int triangle; int patch_id; float radius; float half_width; float min_dot; int component_id;
				if (!b12_validate_chart(records[chart], cell_center, step_size, triangle_count,
						anchor, chart_normal, triangle, patch_id, radius, half_width, min_dot, component_id)) {
					imageStore(cache_tags, slot, ivec4(job.xyz, config.epoch ^ 0x7fffffff));
					return;
				}
			}
		}
		for (int chart = 0; chart < 3; chart++) {
			b12_clear_chart(slot, chart);
			if (chart < int(job_record.header.y)) {
				BlockChartRecord record;
				if (chart == 0) { record = job_record.chart0; }
				else if (chart == 1) { record = job_record.chart1; }
				else { record = job_record.chart2; }
				b12_store(slot, chart, B12_ANCHOR, record.anchor_triangle);
				b12_store(slot, chart, B12_METADATA, record.normal_patch);
				b12_store(slot, chart, B12_DOMAIN, record.domain);
				support |= 1u << uint(chart * 2 + 1);
			}
		}
		tag_current = true;
		imageStore(cache_tags, slot, ivec4(job.xyz, config.epoch));
	}
	if (write_charts || relight_cached) {
		if (!tag_current) { return; }
		for (int chart = 0; chart < 3; chart++) {
			uint cert_bit = 1u << uint(chart * 2 + 1);
			if ((support & cert_bit) == 0u) { continue; }
			BlockChartRecord record;
			record.anchor_triangle = b12_load(slot, chart, B12_ANCHOR);
			record.normal_patch = b12_load(slot, chart, B12_METADATA);
			record.domain = b12_load(slot, chart, B12_DOMAIN);
			vec3 anchor; vec3 chart_normal;
			int triangle; int patch_id; float radius; float half_width; float min_dot; int component_id;
			if (!b12_validate_chart(record, cell_center, step_size,
					visibility_geometry.triangles.length() / 3, anchor, chart_normal, triangle,
					patch_id, radius, half_width, min_dot, component_id)) {
				support &= ~((1u << uint(chart * 2)) | cert_bit);
				b12_clear_chart(slot, chart);
				continue;
			}
			b12_gather_or_relight(slot, chart, anchor, chart_normal, triangle,
					relight_cached && !write_charts, support);
		}
		imageStore(cache_tags, slot, ivec4(job.xyz, config.epoch));
	}
	if (write_summary) { b12_store_summary(slot, job, tag_current, job_record, support); }
	imageStore(support_image, slot, uvec4(support));
}
