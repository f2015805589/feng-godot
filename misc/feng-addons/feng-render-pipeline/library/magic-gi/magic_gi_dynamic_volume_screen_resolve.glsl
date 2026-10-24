#[compute]
#version 450
#extension GL_GOOGLE_include_directive : require

// Dynamic free-space CLV screen cache. Each invocation owns one 2x2 full-
// resolution receiver quad and writes exactly one half-resolution texel plus
// the four corresponding full-resolution edge texels. The live CLV query is
// shared with native PBR through magic_gi_dynamic_volume_sample.glslinc.
//
// Coherent quads perform one exact CLV query at their reconstructed centroid.
// Discontinuous quads perform one exact query per valid receiver and publish
// an edge result (including an explicit negative miss) for each full pixel.
// This is a temporal-free, current-frame cache of live TransferMatrix relight;
// it does not bake lighting or modify material response.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_buffer;
layout(set = 0, binding = 1) uniform sampler2D normal_roughness;
layout(rgba32f, set = 0, binding = 2) uniform writeonly image2D half_incident_output;
layout(rgba32f, set = 0, binding = 3) uniform writeonly image2D half_guide_output;
layout(rgba32f, set = 0, binding = 4) uniform writeonly image2D full_edge_output;
layout(set = 0, binding = 5, std140) uniform ScreenFrameParameters {
	mat4 inverse_projection; // offset 0
	mat4 world_to_grid_reserved; // offset 64; identity for this screen-only pass.
	mat4 view_to_world; // offset 128
	vec4 grid; // offset 192
	vec4 control; // offset 208
	vec4 lighting_sh[7]; // offset 224; reserved/zero for this path.
	vec4 sky_lighting_sh[7]; // offset 336; reserved/zero for this path.
} frame;
layout(set = 0, binding = 6, std430) buffer ScreenResolveDiagnostics {
	uint words[];
} diagnostics;

// The shared sampler declares set 1 bindings 69/76/77/87/88/89 and uses this
// explicit linear sampler for response and moment atlas hardware filtering.
layout(set = 1, binding = 62) uniform sampler screen_linear_sampler;
#define FRP_MAGIC_GI_DYNAMIC_VOLUME_LINEAR_SAMPLER screen_linear_sampler
#include "magic_gi_sh9_tensor.glslinc"
#include "magic_gi_dynamic_volume_sample.glslinc"

layout(push_constant, std430) uniform ScreenResolvePush {
	ivec2 full_size;
	ivec2 half_size;
	int diagnostic_enabled;
	int view_index;
} pc;

const uint SCREEN_DIAG_TILE_COUNT = 0u;
const uint SCREEN_DIAG_COHERENT_TILES = 1u;
const uint SCREEN_DIAG_EDGE_TILES = 2u;
const uint SCREEN_DIAG_VALID_RECEIVERS = 3u;
const uint SCREEN_DIAG_INVALID_RECEIVERS = 4u;
const uint SCREEN_DIAG_SAMPLE_CALLS = 5u;
const uint SCREEN_DIAG_SAMPLE_MISSES = 6u;

const float SCREEN_NORMAL_LENGTH_EPSILON = 1e-10;
const float SCREEN_NEIGHBOR_DEPTH_ABS_EPSILON = 0.025;
const float SCREEN_NEIGHBOR_DEPTH_REL_EPSILON = 0.025;
const float SCREEN_COHERENT_NORMAL_DOT = 0.995;
const float SCREEN_COHERENT_SHADING_DOT = 0.99;

struct ScreenReceiver {
	vec3 view_position;
	vec3 world_position;
	vec3 shading_normal;
	float linear_depth;
	bool valid;
};

bool screen_finite_float(float value) {
	return !isnan(value) && !isinf(value);
}

bool screen_finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool screen_finite_vec4(vec4 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool screen_in_bounds(ivec2 p, ivec2 extent) {
	return p.x >= 0 && p.y >= 0 && p.x < extent.x && p.y < extent.y;
}

void screen_diag_add(uint counter, uint amount) {
	if (pc.diagnostic_enabled == 0 || diagnostics.words.length() < 7) { return; }
	atomicAdd(diagnostics.words[counter], amount);
}

bool screen_reconstruct_position(ivec2 pixel, out vec3 view_position,
		out vec3 world_position, out float linear_depth) {
	view_position = vec3(0.0);
	world_position = vec3(0.0);
	linear_depth = 0.0;
	ivec2 depth_extent = textureSize(depth_buffer, 0);
	if (!screen_in_bounds(pixel, pc.full_size) || !screen_in_bounds(pixel, depth_extent)) {
		return false;
	}
	float device_depth = texelFetch(depth_buffer, pixel, 0).r;
	if (!(device_depth > 0.0) || device_depth > 1.0
			|| !screen_finite_float(device_depth)) { return false; }
	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(pc.full_size);
	vec4 view_h = frame.inverse_projection * vec4(uv * 2.0 - 1.0, device_depth, 1.0);
	if (!(abs(view_h.w) > 1e-8) || !screen_finite_float(view_h.w)) { return false; }
	view_position = view_h.xyz / view_h.w;
	vec4 world_h = frame.view_to_world * vec4(view_position, 1.0);
	if (!screen_finite_vec4(world_h) || !(abs(world_h.w) > 1e-8)) { return false; }
	world_position = world_h.xyz / world_h.w;
	linear_depth = -view_position.z;
	return screen_finite_vec3(view_position) && screen_finite_vec3(world_position)
		&& screen_finite_float(linear_depth) && linear_depth > 0.0;
}

bool screen_decode_shading_normal(ivec2 pixel, out vec3 world_normal) {
	world_normal = vec3(0.0);
	ivec2 normal_extent = textureSize(normal_roughness, 0);
	if (!screen_in_bounds(pixel, pc.full_size) || !screen_in_bounds(pixel, normal_extent)) {
		return false;
	}
	vec3 encoded = texelFetch(normal_roughness, pixel, 0).xyz;
	if (!screen_finite_vec3(encoded)) { return false; }
	vec3 view_normal = encoded * 2.0 - 1.0;
	float view_length_squared = dot(view_normal, view_normal);
	if (!(view_length_squared > SCREEN_NORMAL_LENGTH_EPSILON)
			|| !screen_finite_float(view_length_squared)) { return false; }
	view_normal *= inversesqrt(view_length_squared);
	world_normal = mat3(frame.view_to_world) * view_normal;
	float world_length_squared = dot(world_normal, world_normal);
	if (!(world_length_squared > SCREEN_NORMAL_LENGTH_EPSILON)
			|| !screen_finite_float(world_length_squared)) {
		world_normal = vec3(0.0);
		return false;
	}
	world_normal *= inversesqrt(world_length_squared);
	return screen_finite_vec3(world_normal);
}

bool screen_load_receiver(ivec2 pixel, out ScreenReceiver receiver) {
	receiver.view_position = vec3(0.0);
	receiver.world_position = vec3(0.0);
	receiver.shading_normal = vec3(0.0);
	receiver.linear_depth = 0.0;
	receiver.valid = false;
	if (!screen_reconstruct_position(pixel, receiver.view_position,
			receiver.world_position, receiver.linear_depth)) { return false; }
	if (!screen_decode_shading_normal(pixel, receiver.shading_normal)) { return false; }
	receiver.valid = true;
	return true;
}

vec3 screen_orient_geometric_normal(vec3 normal, vec3 view_position,
		vec3 world_position) {
	float length_squared = dot(normal, normal);
	if (!(length_squared > SCREEN_NORMAL_LENGTH_EPSILON)
			|| !screen_finite_float(length_squared) || !screen_finite_vec3(normal)) {
		return vec3(0.0);
	}
	normal *= inversesqrt(length_squared);
	vec3 camera_world = frame.view_to_world[3].xyz;
	vec3 to_camera = camera_world - world_position;
	float camera_length_squared = dot(to_camera, to_camera);
	if (!(camera_length_squared > SCREEN_NORMAL_LENGTH_EPSILON)
			|| !screen_finite_float(camera_length_squared)) {
		to_camera = mat3(frame.view_to_world) * normalize(-view_position);
		camera_length_squared = dot(to_camera, to_camera);
	}
	if (!(camera_length_squared > SCREEN_NORMAL_LENGTH_EPSILON)
			|| !screen_finite_float(camera_length_squared)) { return vec3(0.0); }
	to_camera *= inversesqrt(camera_length_squared);
	if (dot(normal, to_camera) < 0.0) { normal = -normal; }
	return normal;
}

vec3 screen_quad_geometric_normal(ScreenReceiver q[4], int corner) {
	vec3 dx;
	vec3 dy;
	if (corner == 0) {
		dx = q[1].world_position - q[0].world_position;
		dy = q[2].world_position - q[0].world_position;
	} else if (corner == 1) {
		dx = q[1].world_position - q[0].world_position;
		dy = q[3].world_position - q[1].world_position;
	} else if (corner == 2) {
		dx = q[3].world_position - q[2].world_position;
		dy = q[2].world_position - q[0].world_position;
	} else {
		dx = q[3].world_position - q[2].world_position;
		dy = q[3].world_position - q[1].world_position;
	}
	vec3 center = (q[0].world_position + q[1].world_position
			+ q[2].world_position + q[3].world_position) * 0.25;
	vec3 center_view = (q[0].view_position + q[1].view_position
			+ q[2].view_position + q[3].view_position) * 0.25;
	return screen_orient_geometric_normal(cross(dx, dy), center_view, center);
}

bool screen_neighbor_position(ivec2 pixel, float center_depth,
		out vec3 world_position, out float linear_depth) {
	vec3 unused_view;
	if (!screen_reconstruct_position(pixel, unused_view, world_position, linear_depth)) {
		return false;
	}
	float tolerance = max(SCREEN_NEIGHBOR_DEPTH_ABS_EPSILON,
			center_depth * SCREEN_NEIGHBOR_DEPTH_REL_EPSILON);
	return abs(linear_depth - center_depth) <= tolerance;
}

bool screen_single_pixel_geometric_normal(ivec2 pixel, ScreenReceiver receiver,
		out vec3 geometric_normal) {
	vec3 left_world; vec3 right_world; vec3 up_world; vec3 down_world;
	float left_depth; float right_depth; float up_depth; float down_depth;
	bool have_left = screen_neighbor_position(pixel - ivec2(1, 0), receiver.linear_depth,
			left_world, left_depth);
	bool have_right = screen_neighbor_position(pixel + ivec2(1, 0), receiver.linear_depth,
			right_world, right_depth);
	bool have_up = screen_neighbor_position(pixel - ivec2(0, 1), receiver.linear_depth,
			up_world, up_depth);
	bool have_down = screen_neighbor_position(pixel + ivec2(0, 1), receiver.linear_depth,
			down_world, down_depth);
	vec3 dx = have_left && have_right ? right_world - left_world
			: (have_right ? right_world - receiver.world_position
			: (have_left ? receiver.world_position - left_world : vec3(0.0)));
	vec3 dy = have_up && have_down ? down_world - up_world
			: (have_down ? down_world - receiver.world_position
			: (have_up ? receiver.world_position - up_world : vec3(0.0)));
	if (!(dot(dx, dx) > 1e-12) || !(dot(dy, dy) > 1e-12)) {
		geometric_normal = vec3(0.0);
		return false;
	}
	geometric_normal = screen_orient_geometric_normal(cross(dx, dy),
		receiver.view_position, receiver.world_position);
	return screen_finite_vec3(geometric_normal)
		&& dot(geometric_normal, geometric_normal) > 0.99;
}

bool screen_owner_contains(vec3 world) {
	vec4 owner_size = frp_magic_gi_dynamic_volume_owner_size(0);
	if (!(owner_size.w > 0.5) || !screen_finite_vec4(owner_size)) { return false; }
	vec3 local_position = (frp_magic_gi_dynamic_volume_world_to_local(0)
			* vec4(world, 1.0)).xyz;
	return screen_finite_vec3(local_position)
		&& abs(local_position.x) <= owner_size.x * 0.5
		&& abs(local_position.y) <= owner_size.y * 0.5
		&& abs(local_position.z) <= owner_size.z * 0.5;
}

bool screen_source_domain_contains(vec3 world) {
	ivec4 angular_layout = frp_magic_gi_dynamic_volume_angular_layout(0);
	int resolution = angular_layout.w;
	int lod_count = angular_layout.z;
	if (resolution <= 0 || lod_count <= 0 || lod_count > 4) { return false; }
	for (int lod = 0; lod < lod_count; lod++) {
		vec4 origin_spacing = frp_magic_gi_dynamic_volume_origin_spacing(0, lod);
		if (!(origin_spacing.w > 0.0) || !screen_finite_vec4(origin_spacing)) { continue; }
		vec3 grid = (world - origin_spacing.xyz) / origin_spacing.w;
		if (screen_finite_vec3(grid)
				&& grid.x >= -0.5 && grid.x <= float(resolution) - 0.5
				&& grid.y >= -0.5 && grid.y <= float(resolution) - 0.5
				&& grid.z >= -0.5 && grid.z <= float(resolution) - 0.5) {
			return true;
		}
	}
	return false;
}

bool screen_try_sample(vec3 world, vec3 geometric_normal, vec3 shading_normal,
		out vec3 incident, out float coverage) {
	incident = vec3(0.0);
	coverage = 0.0;
	if (!screen_finite_vec3(world) || !screen_finite_vec3(geometric_normal)
			|| !screen_finite_vec3(shading_normal)
			|| !screen_owner_contains(world) || !screen_source_domain_contains(world)) {
		return false;
	}
	if (pc.diagnostic_enabled != 0) { screen_diag_add(SCREEN_DIAG_SAMPLE_CALLS, 1u); }
	bool sampled = frp_magic_gi_dynamic_volume_sample(world, geometric_normal,
			shading_normal, 0, incident, coverage);
	if (!sampled && pc.diagnostic_enabled != 0) {
		screen_diag_add(SCREEN_DIAG_SAMPLE_MISSES, 1u);
	}
	return sampled && screen_finite_vec3(incident)
		&& screen_finite_float(coverage) && coverage > 0.0;
}

bool screen_try_make_coherent(ScreenReceiver q[4],
		out vec3 center_world, out float center_depth,
		out vec3 geometric_normal, out vec3 shading_normal) {
	center_world = vec3(0.0);
	center_depth = 0.0;
	geometric_normal = vec3(0.0);
	shading_normal = vec3(0.0);
	float minimum_depth = 3.402823e38;
	float maximum_depth = 0.0;
	for (int i = 0; i < 4; i++) {
		if (!q[i].valid || !screen_owner_contains(q[i].world_position)
				|| !screen_source_domain_contains(q[i].world_position)) { return false; }
		center_world += q[i].world_position * 0.25;
		center_depth += q[i].linear_depth * 0.25;
		minimum_depth = min(minimum_depth, q[i].linear_depth);
		maximum_depth = max(maximum_depth, q[i].linear_depth);
		shading_normal += q[i].shading_normal;
	}
	// Coplanarity alone cannot distinguish a slanted depth discontinuity whose
	// four perspective-reconstructed points happen to lie on one plane. Bound
	// the local depth span using the same conservative tolerance as the existing
	// depth-neighbor surface test. Steeper legitimate planes route to exact
	// per-pixel samples; they are not rejected from the GI field.
	float depth_tolerance = max(SCREEN_NEIGHBOR_DEPTH_ABS_EPSILON,
			center_depth * SCREEN_NEIGHBOR_DEPTH_REL_EPSILON);
	if (!screen_finite_float(center_depth)
			|| maximum_depth - minimum_depth > depth_tolerance) { return false; }
	float shading_length_squared = dot(shading_normal, shading_normal);
	if (!(shading_length_squared > SCREEN_NORMAL_LENGTH_EPSILON)
			|| !screen_finite_float(shading_length_squared)) { return false; }
	shading_normal *= inversesqrt(shading_length_squared);
	vec3 normals[4];
	for (int i = 0; i < 4; i++) {
		normals[i] = screen_quad_geometric_normal(q, i);
		if (!screen_finite_vec3(normals[i]) || dot(normals[i], normals[i]) < 0.99) {
			return false;
		}
		geometric_normal += normals[i];
	}
	float geometric_length_squared = dot(geometric_normal, geometric_normal);
	if (!(geometric_length_squared > SCREEN_NORMAL_LENGTH_EPSILON)
			|| !screen_finite_float(geometric_length_squared)) { return false; }
	geometric_normal *= inversesqrt(geometric_length_squared);
	for (int i = 0; i < 4; i++) {
		if (dot(normals[i], geometric_normal) < SCREEN_COHERENT_NORMAL_DOT) { return false; }
		for (int j = i + 1; j < 4; j++) {
			if (dot(q[i].shading_normal, q[j].shading_normal)
					< SCREEN_COHERENT_SHADING_DOT) { return false; }
		}
	}
	float residual = 0.0;
	for (int i = 0; i < 4; i++) {
		residual = max(residual, abs(dot(q[i].world_position - center_world,
				geometric_normal)));
	}
	float plane_tolerance = max(0.002, center_depth * 0.0001);
	if (!screen_finite_float(residual) || residual > plane_tolerance) { return false; }
	return true;
}

void screen_write_default_outputs(ivec2 half_pixel, ivec2 half_actual,
		ivec2 full_actual, bool fail_closed) {
	if (screen_in_bounds(half_pixel, half_actual)) {
		imageStore(half_incident_output, half_pixel, vec4(0.0));
		imageStore(half_guide_output, half_pixel, vec4(0.0));
	}
	float edge_alpha = fail_closed ? -1.0 : 0.0;
	for (int q = 0; q < 4; q++) {
		ivec2 full_pixel = half_pixel * 2 + ivec2(q & 1, q >> 1);
		if (screen_in_bounds(full_pixel, full_actual)) {
			imageStore(full_edge_output, full_pixel, vec4(0.0, 0.0, 0.0, edge_alpha));
		}
	}
}

void main() {
	ivec2 half_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 actual_half = imageSize(half_incident_output);
	ivec2 actual_guide = imageSize(half_guide_output);
	ivec2 actual_full = imageSize(full_edge_output);
	bool can_write_half = actual_half.x > 0 && actual_half.y > 0
			&& actual_guide.x > 0 && actual_guide.y > 0;
	ivec2 depth_size = textureSize(depth_buffer, 0);
	ivec2 normal_size = textureSize(normal_roughness, 0);
	bool dimensions_valid = pc.full_size.x > 0 && pc.full_size.y > 0
			&& pc.half_size.x > 0 && pc.half_size.y > 0
			&& pc.full_size.x == actual_full.x && pc.full_size.y == actual_full.y
			&& pc.full_size.x == depth_size.x && pc.full_size.y == depth_size.y
			&& pc.full_size.x == normal_size.x && pc.full_size.y == normal_size.y
			&& pc.half_size.x == actual_half.x && pc.half_size.y == actual_half.y
			&& pc.half_size.x == actual_guide.x && pc.half_size.y == actual_guide.y
			&& pc.half_size.x == (pc.full_size.x + 1) / 2
			&& pc.half_size.y == (pc.full_size.y + 1) / 2;
	if (!dimensions_valid || pc.view_index != 0 || !screen_in_bounds(half_pixel, pc.half_size)) {
		if (can_write_half && screen_in_bounds(half_pixel, actual_half)
				&& screen_in_bounds(half_pixel, actual_guide)) {
			screen_write_default_outputs(half_pixel, actual_half, actual_full, true);
		}
		return;
	}
	if (pc.diagnostic_enabled != 0) { screen_diag_add(SCREEN_DIAG_TILE_COUNT, 1u); }
	// QA4 is the explicit dynamic-GI-off control. Keep output resources fresh
	// and fail closed without reading G-buffer data or issuing CLV queries; the
	// native PBR dynamic-volume path also bypasses sampling for this QA mode.
	if (abs(frp_magic_gi_dynamic_volume_owner_control(0).w - 4.0) < 0.01) {
		screen_write_default_outputs(half_pixel, actual_half, actual_full, true);
		return;
	}

	ivec2 full_pixels[4];
	ScreenReceiver receivers[4];
	int receiver_count = 0;
	for (int q = 0; q < 4; q++) {
		full_pixels[q] = half_pixel * 2 + ivec2(q & 1, q >> 1);
		bool in_full = screen_in_bounds(full_pixels[q], pc.full_size);
		if (in_full && screen_load_receiver(full_pixels[q], receivers[q])) {
			receiver_count++;
		} else {
			receivers[q].view_position = vec3(0.0);
			receivers[q].world_position = vec3(0.0);
			receivers[q].shading_normal = vec3(0.0);
			receivers[q].linear_depth = 0.0;
			receivers[q].valid = false;
			// Invalid depth/normal or an odd-size tail cannot borrow from a
			// neighboring half-resolution receiver; the final edge pass writes
			// the one fail-closed texel for each in-bounds invalid pixel.
		}
	}
	if (pc.diagnostic_enabled != 0) {
		screen_diag_add(SCREEN_DIAG_VALID_RECEIVERS, uint(receiver_count));
		screen_diag_add(SCREEN_DIAG_INVALID_RECEIVERS, uint(4 - receiver_count));
	}

	bool tile_is_coherent = receiver_count == 4;
	vec3 center_world; vec3 geometric_normal; vec3 shading_normal;
	float center_depth;
	if (tile_is_coherent) {
		tile_is_coherent = screen_try_make_coherent(receivers, center_world, center_depth,
				geometric_normal, shading_normal);
	}
	if (tile_is_coherent) {
		vec3 incident;
		float coverage;
		bool sampled = screen_try_sample(center_world, geometric_normal,
				shading_normal, incident, coverage);
		if (sampled) {
			imageStore(half_incident_output, half_pixel,
					vec4(incident, clamp(coverage, 0.0, 1.0)));
			imageStore(half_guide_output, half_pixel,
					vec4(center_depth, geometric_normal));
			for (int q = 0; q < 4; q++) {
				imageStore(full_edge_output, full_pixels[q], vec4(0.0));
			}
		} else {
			// A center miss is not a proof that the four receivers all miss;
			// route each full-resolution pixel through the exact query instead.
			tile_is_coherent = false;
		}
	}
	if (!tile_is_coherent) {
		imageStore(half_incident_output, half_pixel, vec4(0.0));
		imageStore(half_guide_output, half_pixel, vec4(0.0));
		for (int q = 0; q < 4; q++) {
			ivec2 pixel = full_pixels[q];
			if (!screen_in_bounds(pixel, pc.full_size) || !receivers[q].valid) {
				if (screen_in_bounds(pixel, actual_full)) {
					imageStore(full_edge_output, pixel, vec4(0.0, 0.0, 0.0, -1.0));
				}
				continue;
			}
			vec3 ng;
			bool have_geometric = screen_single_pixel_geometric_normal(pixel,
					receivers[q], ng);
			if (!have_geometric) {
				imageStore(full_edge_output, pixel, vec4(0.0, 0.0, 0.0, -1.0));
				continue;
			}
			vec3 incident;
			float coverage;
			bool sampled = screen_try_sample(receivers[q].world_position, ng,
					receivers[q].shading_normal, incident, coverage);
			if (sampled) {
				imageStore(full_edge_output, pixel,
						vec4(incident, clamp(coverage, 0.0, 1.0)));
			} else {
				imageStore(full_edge_output, pixel, vec4(0.0, 0.0, 0.0, -1.0));
			}
		}
	}
	if (pc.diagnostic_enabled != 0) {
		if (tile_is_coherent) { screen_diag_add(SCREEN_DIAG_COHERENT_TILES, 1u); }
		else { screen_diag_add(SCREEN_DIAG_EDGE_TILES, 1u); }
	}
}
