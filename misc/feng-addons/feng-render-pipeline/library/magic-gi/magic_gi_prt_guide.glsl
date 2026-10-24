#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D raw_incident_texture;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_roughness;
layout(rgba16f, set = 0, binding = 3) uniform writeonly image2D guide_output;
layout(r16f, set = 0, binding = 4) uniform writeonly image2D cell_certificate_output;

layout(set = 0, binding = 9, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid;
	vec4 control;
	vec4 lighting_sh[7];
	vec4 sky_lighting_sh[7];
} params;

layout(push_constant, std430) uniform PassParameters {
	vec4 parameters; // strength, pre-exposure * scene normalization, positive gather scale, debug view.
} pc;

const float HALF_FLOAT_SAFE_MAX = 60000.0;

bool finite_float(float value) {
	return !isnan(value) && !isinf(value);
}

bool finite_vec3(vec3 value) {
	return all(not(isnan(value))) && all(not(isinf(value)));
}

bool read_coarse_guide(ivec2 coarse_pixel, ivec2 raw_size, ivec2 full_size,
		int gather_scale, out vec4 guide, out uint material_model,
		out vec3 view_position) {
	guide = vec4(0.0);
	material_model = 0u;
	view_position = vec3(0.0);
	if (any(lessThan(coarse_pixel, ivec2(0)))
			|| any(greaterThanEqual(coarse_pixel, raw_size))) {
		return false;
	}
	float encoded_model = texelFetch(raw_incident_texture, coarse_pixel, 0).a;
	if (!finite_float(encoded_model) || encoded_model < 2.0 || encoded_model > 16.0) {
		return false;
	}
	material_model = uint(round(encoded_model)) - 1u;
	ivec2 guide_pixel = min(coarse_pixel * gather_scale + ivec2(gather_scale / 2),
			full_size - ivec2(1));
	float raw_depth = texelFetch(depth_buffer, guide_pixel, 0).r;
	if (!finite_float(raw_depth) || raw_depth <= 0.0) {
		return false;
	}
	vec2 uv = (vec2(guide_pixel) + vec2(0.5)) / vec2(full_size);
	vec4 clip = vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	vec4 view_h = params.inverse_projection * clip;
	if (any(isnan(view_h)) || any(isinf(view_h)) || abs(view_h.w) < 1.0e-7) {
		return false;
	}
	view_position = view_h.xyz / view_h.w;
	float linear_depth = -view_position.z;
	if (!finite_float(linear_depth) || linear_depth <= 0.0
			|| linear_depth > HALF_FLOAT_SAFE_MAX || !finite_vec3(view_position)) {
		return false;
	}
	vec3 normal = texelFetch(normal_roughness, guide_pixel, 0).xyz * 2.0 - 1.0;
	float normal_length_squared = dot(normal, normal);
	if (!finite_float(normal_length_squared) || normal_length_squared < 1.0e-8) {
		return false;
	}
	normal *= inversesqrt(normal_length_squared);
	float plane_offset = dot(normal, view_position);
	if (!finite_float(plane_offset) || abs(plane_offset) > HALF_FLOAT_SAFE_MAX) {
		return false;
	}
	// RGB is the unit view normal; A is the view-space plane offset n dot p.
	guide = vec4(normal, plane_offset);
	return finite_vec3(guide.xyz);
}

float plane_residual_limit(vec3 position_a, vec3 position_b) {
	// Leave margin for the RGBA16F guide's quantization, but stop certifying
	// distant surfaces once that margin could hide a meaningful depth boundary.
	return max(0.01, max(length(position_a), length(position_b)) * 0.0006);
}

bool guides_compatible(vec4 a, uint model_a, vec3 position_a,
		vec4 b, uint model_b, vec3 position_b) {
	if (model_a == 0u || model_a != model_b) {
		return false;
	}
	float normal_dot = dot(a.xyz, b.xyz);
	float residual_a = abs(dot(a.xyz, position_b) - a.a);
	float residual_b = abs(dot(b.xyz, position_a) - b.a);
	float residual_limit = plane_residual_limit(position_a, position_b);
	return finite_float(normal_dot) && finite_float(residual_a)
			&& finite_float(residual_b) && finite_float(residual_limit)
			&& residual_limit <= 0.1 && normal_dot >= 0.9
			&& residual_a <= residual_limit && residual_b <= residual_limit;
}

void main() {
	ivec2 coarse_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 raw_size = imageSize(guide_output);
	if (any(greaterThanEqual(coarse_pixel, raw_size))
			|| any(greaterThanEqual(coarse_pixel, imageSize(cell_certificate_output)))) {
		return;
	}
	ivec2 full_size = textureSize(depth_buffer, 0);
	int gather_scale = int(round(clamp(pc.parameters.z, 1.0, 16.0)));
	vec4 guides[4];
	uint models[4];
	vec3 positions[4];
	bool all_valid = true;
	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			int index = y * 2 + x;
			ivec2 tap = coarse_pixel + ivec2(x, y);
			bool valid = read_coarse_guide(tap, raw_size, full_size,
					gather_scale, guides[index], models[index], positions[index]);
			all_valid = all_valid && valid;
		}
	}
	// A cell certificate represents the bilinear 2x2 raw footprint beginning at q.
	// It is deliberately false at the last row/column and at any invalid or mixed edge.
	imageStore(guide_output, coarse_pixel, guides[0]);
	bool certified = all_valid;
	if (certified) {
		for (int a = 0; a < 4; a++) {
			for (int b = a + 1; b < 4; b++) {
				certified = certified && guides_compatible(guides[a], models[a],
						positions[a], guides[b], models[b], positions[b]);
			}
		}
	}
	// R16F stores the certified shading-model id + 1 (matching raw alpha); zero is invalid.
	imageStore(cell_certificate_output, coarse_pixel,
			vec4(certified ? float(models[0] + 1u) : 0.0));
}
