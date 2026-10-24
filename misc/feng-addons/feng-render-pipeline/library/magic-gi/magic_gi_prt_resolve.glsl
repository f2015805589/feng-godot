#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D raw_incident_texture;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_roughness;
layout(set = 0, binding = 3) uniform sampler2D gbuffer_albedo;
layout(set = 0, binding = 4) uniform sampler2D gbuffer_orm;
layout(set = 0, binding = 5) uniform sampler2D sky_light_diffuse_buffer;
layout(set = 0, binding = 6) uniform sampler2D diffuse_ambient_occlusion_texture;
layout(rgba16f, set = 0, binding = 7) uniform image2D color_image;
layout(rgba16f, set = 0, binding = 8) uniform writeonly image2D gi_output;
layout(set = 0, binding = 10) uniform sampler2D coarse_guide_texture;
layout(set = 0, binding = 11) uniform sampler2D cell_certificate_texture;
layout(set = 0, binding = 12) uniform sampler2D raw_incident_linear_texture;

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
	vec4 parameters; // strength, pre-exposure * scene normalization, signed gather scale, debug view.
} pc;

const uint MATERIAL_MODEL_MASK = 0x0fu;
const uint UNLIT_MATERIAL_MODEL = 0u;
const float RAW_INCIDENT_DECODE_SCALE = 16.0;

bool finite_float(float value) {
	return !isnan(value) && !isinf(value);
}

bool finite_vec3(vec3 value) {
	return all(not(isnan(value))) && all(not(isinf(value)));
}

bool read_geometry(ivec2 pixel, ivec2 full_size, out float linear_depth,
		out vec3 view_normal) {
	linear_depth = 0.0;
	view_normal = vec3(0.0, 0.0, 1.0);
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, full_size))) {
		return false;
	}
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (!finite_float(depth) || depth <= 0.0) {
		return false;
	}
	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(full_size);
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 clip = vec4(ndc, depth, 1.0);
	// Only the view-space z and homogeneous w rows are needed for bilateral depth
	// rejection; avoid a full position transform for every raw tap.
	float view_z = params.inverse_projection[0][2] * clip.x
			+ params.inverse_projection[1][2] * clip.y
			+ params.inverse_projection[2][2] * clip.z
			+ params.inverse_projection[3][2] * clip.w;
	float view_w = params.inverse_projection[0][3] * clip.x
			+ params.inverse_projection[1][3] * clip.y
			+ params.inverse_projection[2][3] * clip.z
			+ params.inverse_projection[3][3] * clip.w;
	if (!finite_float(view_w) || abs(view_w) < 1.0e-7 || !finite_float(view_z)) {
		return false;
	}
	linear_depth = -view_z / view_w;
	if (!finite_float(linear_depth) || linear_depth <= 0.0) {
		return false;
	}
	vec3 encoded_normal = texelFetch(normal_roughness, pixel, 0).xyz * 2.0 - 1.0;
	float normal_length_squared = dot(encoded_normal, encoded_normal);
	if (!finite_float(normal_length_squared) || normal_length_squared < 1.0e-8) {
		return false;
	}
	view_normal = encoded_normal * inversesqrt(normal_length_squared);
	return finite_vec3(view_normal);
}

bool read_surface(ivec2 pixel, ivec2 full_size, out float linear_depth,
		out vec3 view_normal, out uint material_model, out vec4 orm) {
	orm = vec4(0.0);
	material_model = UNLIT_MATERIAL_MODEL;
	if (!read_geometry(pixel, full_size, linear_depth, view_normal)) {
		return false;
	}
	orm = texelFetch(gbuffer_orm, pixel, 0);
	if (!finite_float(orm.a)) {
		return false;
	}
	uint metadata = uint(round(clamp(orm.a, 0.0, 1.0) * 255.0));
	material_model = metadata & MATERIAL_MODEL_MASK;
	return material_model != UNLIT_MATERIAL_MODEL;
}

bool reconstruct_view_position(ivec2 pixel, ivec2 full_size,
		out vec3 view_position) {
	view_position = vec3(0.0);
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (!finite_float(depth) || depth <= 0.0) {
		return false;
	}
	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(full_size);
	vec4 view_h = params.inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	if (any(isnan(view_h)) || any(isinf(view_h)) || abs(view_h.w) < 1.0e-7) {
		return false;
	}
	view_position = view_h.xyz / view_h.w;
	return finite_vec3(view_position) && -view_position.z > 0.0;
}

float plane_residual_limit(vec3 view_position) {
	// Guide alpha is an RGBA16F plane offset; account for its half-float rounding.
	return max(0.01, length(view_position) * 0.0006);
}

bool try_fast_resolve(ivec2 pixel, ivec2 full_size, ivec2 raw_size,
		ivec2 base, vec2 raw_position, uint center_model,
		vec3 center_normal, out vec3 incident) {
	incident = vec3(0.0);
	ivec2 certificate_size = textureSize(cell_certificate_texture, 0);
	if (any(lessThan(base, ivec2(0)))
			|| any(greaterThanEqual(base + ivec2(1), raw_size))
			|| any(greaterThanEqual(base, certificate_size))) {
		return false;
	}
	float certificate = texelFetch(cell_certificate_texture, base, 0).r;
	// A valid certificate carries the common model id + 1, avoiding a separate
	// nearest raw-buffer read on the full-resolution resolve path.
	if (!finite_float(certificate) || certificate < 2.0 || certificate > 16.0
			|| uint(round(certificate)) - 1u != center_model) {
		return false;
	}

	ivec2 nearest_raw = clamp(ivec2(floor(raw_position + vec2(0.5))),
			ivec2(0), raw_size - ivec2(1));
	vec4 guide = texelFetch(coarse_guide_texture, nearest_raw, 0);
	if (!finite_vec3(guide.xyz) || !finite_float(guide.a)) {
		return false;
	}
	float guide_normal_length_squared = dot(guide.xyz, guide.xyz);
	if (!finite_float(guide_normal_length_squared)
			|| guide_normal_length_squared < 1.0e-8) {
		return false;
	}
	vec3 guide_normal = guide.xyz * inversesqrt(guide_normal_length_squared);
	float normal_dot = dot(center_normal, guide_normal);
	if (!finite_float(normal_dot) || normal_dot < 0.9) {
		return false;
	}

	vec3 center_position;
	if (!reconstruct_view_position(pixel, full_size, center_position)) {
		return false;
	}
	float plane_residual = abs(dot(guide_normal, center_position) - guide.a);
	float plane_limit = plane_residual_limit(center_position);
	if (!finite_float(plane_residual) || !finite_float(plane_limit)
			|| plane_limit > 0.1 || plane_residual > plane_limit) {
		return false;
	}

	// Sampling at the corresponding texel-space coordinate reproduces the
	// coarse bilinear footprint only after its full 2x2 cell was certified.
	vec2 raw_uv = (raw_position + vec2(0.5)) / vec2(raw_size);
	vec4 filtered = textureLod(raw_incident_linear_texture, raw_uv, 0.0);
	if (!finite_float(filtered.a) || filtered.a < 2.0 || filtered.a > 16.0
			|| !finite_vec3(filtered.rgb)
			|| uint(round(filtered.a)) - 1u != center_model) {
		return false;
	}
	incident = filtered.rgb * RAW_INCIDENT_DECODE_SCALE;
	return finite_vec3(incident);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 full_size = imageSize(color_image);
	ivec2 gi_size = imageSize(gi_output);
	if (any(greaterThanEqual(pixel, full_size))
			|| any(greaterThanEqual(pixel, gi_size))) {
		return;
	}
	if (params.control.x <= 0.0 || pc.parameters.x <= 0.0 || params.grid.w <= 0.0) {
		imageStore(gi_output, pixel, vec4(0.0));
		return;
	}

	float center_depth;
	vec3 center_normal;
	uint center_model;
	vec4 orm;
	if (!read_surface(pixel, full_size, center_depth, center_normal, center_model, orm)) {
		imageStore(gi_output, pixel, vec4(0.0));
		return;
	}

	bool fast_path_requested = pc.parameters.z < 0.0;
	int gather_scale = int(round(clamp(abs(pc.parameters.z), 1.0, 16.0)));
	ivec2 raw_size = textureSize(raw_incident_texture, 0);
	vec2 raw_position = (vec2(pixel) - vec2(gather_scale / 2))
			/ float(gather_scale);
	ivec2 base = ivec2(floor(raw_position));
	vec2 fraction = fract(raw_position);
	float depth_limit = max(0.01, center_depth * 0.0125 * float(gather_scale));
	vec3 incident_sum = vec3(0.0);
	float weight_sum = 0.0;
	vec3 incident = vec3(0.0);
	bool fast_resolved = fast_path_requested && gather_scale > 1
			&& try_fast_resolve(pixel, full_size, raw_size, base, raw_position,
				center_model, center_normal, incident);
	if (!fast_resolved) {
		for (int y = 0; y < 2; y++) {
			for (int x = 0; x < 2; x++) {
				ivec2 raw_pixel = base + ivec2(x, y);
				vec2 bilinear = vec2(x == 0 ? 1.0 - fraction.x : fraction.x,
						y == 0 ? 1.0 - fraction.y : fraction.y);
				float spatial_weight = bilinear.x * bilinear.y;
				if (!(spatial_weight > 1.0e-6)) {
					continue;
				}
				if (any(lessThan(raw_pixel, ivec2(0)))
						|| any(greaterThanEqual(raw_pixel, raw_size))) {
					continue;
				}
				vec4 raw = texelFetch(raw_incident_texture, raw_pixel, 0);
				if (!finite_float(raw.a) || raw.a < 2.0 || raw.a > 16.0
						|| !finite_vec3(raw.rgb)) {
					continue;
				}

				// Match each coarse gather to the full-resolution surface at its block
				// center. Clamp only the partial final block on odd-sized viewports.
				ivec2 guide_pixel = min(raw_pixel * gather_scale
						+ ivec2(gather_scale / 2), full_size - ivec2(1));
				float guide_depth;
				vec3 guide_normal;
				uint guide_model = uint(round(raw.a)) - 1u;
				if (!read_geometry(guide_pixel, full_size, guide_depth,
						guide_normal) || guide_model != center_model) {
					continue;
				}
				float normal_dot = dot(center_normal, guide_normal);
				if (!finite_float(normal_dot) || normal_dot < 0.5) {
					continue;
				}
				float depth_delta = abs(guide_depth - center_depth);
				if (!finite_float(depth_delta) || depth_delta > depth_limit) {
					continue;
				}

				float depth_weight = 1.0 - smoothstep(0.0, depth_limit, depth_delta);
				float normal_weight = normal_dot * normal_dot;
				float weight = spatial_weight * depth_weight * normal_weight;
				if (weight > 0.0) {
					incident_sum += raw.rgb * weight;
					weight_sum += weight;
				}
			}
		}
		if (!(weight_sum > 1.0e-6)) {
			imageStore(gi_output, pixel, vec4(0.0));
			return;
		}
		incident = incident_sum / weight_sum * RAW_INCIDENT_DECODE_SCALE;
	}
	if (!finite_vec3(incident)) {
		imageStore(gi_output, pixel, vec4(0.0));
		return;
	}

	float ao = clamp(orm.r, 0.0, 1.0);
	float metallic = clamp(orm.b, 0.0, 1.0);
	float diffuse_ao = textureLod(diffuse_ambient_occlusion_texture,
			(vec2(pixel) + vec2(0.5)) / vec2(full_size), 0.0).r;
	if (!finite_float(diffuse_ao)) {
		diffuse_ao = 1.0;
	}
	vec3 albedo = texelFetch(gbuffer_albedo, pixel, 0).rgb;
	float total_strength = max(params.control.x * pc.parameters.x, 0.0);
	float ownership_weight = params.control.z > 0.5
			? clamp(total_strength, 0.0, 1.0) : 0.0;
	vec3 contribution = incident * albedo * (1.0 - metallic) * ao
			* clamp(diffuse_ao, 0.0, 1.0) * total_strength * pc.parameters.y;
	if (!finite_vec3(contribution)) {
		imageStore(gi_output, pixel, vec4(0.0));
		return;
	}
	imageStore(gi_output, pixel, vec4(contribution, ownership_weight));

	vec4 scene = imageLoad(color_image, pixel);
	if (ownership_weight > 0.0) {
		scene.rgb -= texelFetch(sky_light_diffuse_buffer, pixel, 0).rgb
				* ownership_weight;
	}
	imageStore(color_image, pixel, vec4(scene.rgb + contribution, scene.a));
}
