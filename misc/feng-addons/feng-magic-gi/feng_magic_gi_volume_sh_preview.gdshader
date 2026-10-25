shader_type spatial;
render_mode unshaded, fog_disabled;

uniform bool preview_unit_transport = false;
uniform bool preview_layout_stale = false;
uniform vec4 preview_camera_origin[4];
uniform vec4 preview_camera_right[4];
uniform vec4 preview_camera_up[4];
uniform vec4 preview_camera_back[4];
uniform vec4 preview_camera_projection[4];
uniform vec4 preview_camera_size[4];
uniform vec4 preview_eye_scale;

// Coefficient-major RGB live incident radiance. This free-space PRT preview
// accepts only the prepared runtime's four L0+L1 coefficients.
// This data texture is linear radiance, never an sRGB color texture.
uniform sampler2D response_sh : filter_nearest, repeat_disable;
uniform int response_coefficient_count = 4;
uniform float response_strength = 1.0;
varying flat int preview_response_row;
varying vec3 preview_world_direction;
varying float preview_marker_compensate;

vec3 evaluate_response(vec3 n) {
	if (response_coefficient_count != 4) {
		return vec3(0.0);
	}
	float basis[4];
	basis[0] = 0.2820947918;
	basis[1] = 0.325735007933 * n.y;
	basis[2] = 0.325735007933 * n.z;
	basis[3] = 0.325735007933 * n.x;
	vec3 response = vec3(0.0);
	for (int k = 0; k < 4; k++) {
		response += texelFetch(response_sh, ivec2(k, preview_response_row), 0).rgb * basis[k];
	}
    return max(response * response_strength, vec3(0.0));
}

void vertex() {
	preview_marker_compensate = INSTANCE_CUSTOM.x;
    preview_response_row = int(round(INSTANCE_CUSTOM.y));
    preview_world_direction = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

float matching_eye_compensation(vec3 live_origin, vec3 live_right, vec3 live_up,
		vec3 live_back, vec2 live_projection, float live_aspect,
		bool live_orthogonal, vec2 live_size) {
	float best_score = 1e20;
	float second_score = 1e20;
	float best_scale = 1.0;
	float second_scale = 1.0;
	for (int i = 0; i < 4; i++) {
		vec4 projection = preview_camera_projection[i];
		if (projection.x <= 0.0 || projection.y <= 0.0) {
			continue;
		}
		vec3 origin = preview_camera_origin[i].xyz;
		float position_error = distance(live_origin, origin);
		float right_error = 1.0 - dot(live_right, normalize(preview_camera_right[i].xyz));
		float up_error = 1.0 - dot(live_up, normalize(preview_camera_up[i].xyz));
		float back_error = 1.0 - dot(live_back, normalize(preview_camera_back[i].xyz));
		float orientation_error = max(max(right_error, up_error), back_error);
		float projection_error = max(
				abs(live_projection.x - projection.x) / max(projection.x, 1e-5),
				abs(live_projection.y - projection.y) / max(projection.y, 1e-5));
		float aspect_error = abs(live_aspect - projection.w) / max(projection.w, 0.1);
		bool camera_type_matches = live_orthogonal == (projection.z > 0.5);
		if (position_error > 0.5 || orientation_error > 0.04
				|| projection_error > 0.08 || aspect_error > 0.08 || !camera_type_matches) {
			continue;
		}
		vec2 saved_size = preview_camera_size[i].xy;
		vec2 size_error = abs(live_size - saved_size) / max(saved_size, vec2(1.0));
		float size_score = max(size_error.x, size_error.y);
		float score = position_error / 0.15 + orientation_error / 0.01
				+ projection_error / 0.02 + aspect_error / 0.02 + size_score;
		if (score < best_score) {
			second_score = best_score;
			second_scale = best_scale;
			best_score = score;
			best_scale = preview_eye_scale[i];
		} else if (score < second_score) {
			second_score = score;
			second_scale = preview_eye_scale[i];
		}
	}
	if (best_score >= 1e19) {
		return 1.0;
	}
	if (second_score - best_score < 0.2
			&& abs(second_scale - best_scale) > max(0.001, abs(best_scale) * 0.01)) {
		return 1.0;
	}
	return min(1.0 / max(best_scale, 1e-8), 1e8);
}

void fragment() {
	float debug_compensation = 1.0;
	if (preview_unit_transport || preview_marker_compensate > 0.5) {
		vec3 live_origin = INV_VIEW_MATRIX[3].xyz;
		vec3 live_right = normalize(INV_VIEW_MATRIX[0].xyz);
		vec3 live_up = normalize(INV_VIEW_MATRIX[1].xyz);
		vec3 live_back = normalize(INV_VIEW_MATRIX[2].xyz);
		vec2 live_projection = abs(vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]));
		float live_aspect = VIEWPORT_SIZE.x / max(VIEWPORT_SIZE.y, 1.0);
		bool live_orthogonal = PROJECTION_MATRIX[3][3] == 1.0;
		debug_compensation = matching_eye_compensation(live_origin, live_right,
				live_up, live_back, live_projection, live_aspect,
				live_orthogonal, VIEWPORT_SIZE);
	}
	float exposure_builtin = EXPOSURE;
	if (isnan(exposure_builtin) || isinf(exposure_builtin) || exposure_builtin <= 0.0) {
		exposure_builtin = 1.0;
	}
	exposure_builtin = clamp(exposure_builtin, 1e-8, 1e8);
	float static_camera_compensation = 1.0;
	if (!preview_unit_transport && preview_marker_compensate <= 0.5) {
		static_camera_compensation = 1.0 / exposure_builtin;
	}
	vec3 input_rgb = evaluate_response(normalize(preview_world_direction));
	if (any(isnan(input_rgb)) || any(isinf(input_rgb))) {
		input_rgb = vec3(0.0);
	}
	vec3 output_color = input_rgb * debug_compensation * static_camera_compensation;
	if (preview_layout_stale) {
		output_color = mix(output_color, vec3(1.0, 0.38, 0.035), 0.72);
	}
	if (any(isnan(output_color)) || any(isinf(output_color))) {
		output_color = vec3(0.0);
	}
	ALBEDO = clamp(output_color, vec3(-65504.0), vec3(65504.0));
}
