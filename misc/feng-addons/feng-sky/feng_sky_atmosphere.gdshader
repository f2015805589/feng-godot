shader_type sky;

// Scene-linear spherical atmosphere: RGB Rayleigh/Mie, ozone absorption and
// cached isotropic multiple scattering. Distances and
// extinction coefficients use kilometres and inverse kilometres respectively.
// The source is intentionally not multiplied by camera exposure or pre-exposure.

uniform float planet_radius_km = 6360.0;
uniform float atmosphere_height_km = 60.0;
uniform float rayleigh_scale_height_km = 8.0;
uniform float mie_scale_height_km = 1.2;
uniform vec3 rayleigh_scattering_per_km = vec3(0.005802, 0.013558, 0.0331);
// Legacy scalar parameters remain accepted by existing material diagnostics.
uniform float mie_scattering_per_km = 0.003996;
uniform float mie_extinction_per_km = 0.00444;
uniform vec3 mie_scattering_coefficients = vec3(0.003996);
uniform vec3 mie_extinction_coefficients = vec3(0.00444);
uniform vec3 absorption_extinction_per_km = vec3(0.000650, 0.001881, 0.000085);
uniform float absorption_density_layer_width_km = 25.0;
uniform float absorption_layer0_linear_term = 0.0666666667;
uniform float absorption_layer0_constant_term = -0.6666666667;
uniform float absorption_layer1_linear_term = -0.0666666667;
uniform float absorption_layer1_constant_term = 2.6666666667;
uniform float multi_scattering_factor = 1.0;
uniform vec3 sky_luminance_factor = vec3(1.0);
uniform vec3 sky_only_luminance_factor = vec3(1.0);
uniform float trace_sample_count_scale = 1.0;
uniform float mie_asymmetry = 0.8;
uniform vec3 planet_center_m = vec3(0.0, -6360000.0, 0.0);
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_color_linear = vec3(1.0);
uniform float sun_irradiance = 0.0;
uniform float sun_angular_radius_deg = 0.26785;
uniform vec3 sun_disk_color_scale = vec3(1.0);
uniform vec3 secondary_sun_direction = vec3(0.0, -1.0, 0.0);
uniform vec3 secondary_sun_color_linear = vec3(1.0);
uniform float secondary_sun_irradiance = 0.0;
uniform float secondary_sun_angular_radius_deg = 0.26785;
uniform vec3 secondary_sun_disk_color_scale = vec3(1.0);
// FRP applies Environment.background_energy_multiplier after sampling the sky.
// The component lowers this ceiling so the final value stays below RGBA16F max.
uniform float sky_radiance_limit = 60000.0;
// Ground albedo is used when building the multiple-scattering table only.
uniform vec3 ground_albedo = vec3(0.4);

const int VIEW_SAMPLES = 8;
const int MAX_VIEW_SAMPLES = 64;
// Rayleigh, Mie and ozone density columns in km. The finite, non-ground-intersecting
// sun-ray domain maps to texel centers; planet shadow is evaluated analytically.
uniform sampler2D optical_column_lut : filter_linear, repeat_disable;
uniform bool use_optical_column_lut = false;
uniform sampler2D multi_scattering_lut : filter_linear, repeat_disable;
uniform bool use_multi_scattering_lut = false;
const float INV_PI = 0.3183098861837907;

vec3 safe_normalize_direction(vec3 value, vec3 fallback) {
	if (!(abs(value.x) < 1.0e30) || !(abs(value.y) < 1.0e30) || !(abs(value.z) < 1.0e30)) {
		return fallback;
	}
	float scale = max(abs(value.x), max(abs(value.y), abs(value.z)));
	if (!(scale > 0.000000000001)) {
		return fallback;
	}
	vec3 scaled = value / scale;
	float length_squared = dot(scaled, scaled);
	if (!(length_squared > 0.0)) {
		return fallback;
	}
	return scaled * inversesqrt(length_squared);
}

float effective_sky_radiance_limit() {
	if (!(sky_radiance_limit > 0.0)) {
		return 0.0;
	}
	return min(sky_radiance_limit, 65504.0);
}

float safe_radiance_component(float value, float limit) {
	if (!(value > 0.0)) {
		return 0.0;
	}
	if (value > limit) {
		return limit;
	}
	return value;
}

float safe_disk_radiance_component(float irradiance, float light_color, float disk_tint, float solid_angle, float limit) {
	if (!(irradiance > 0.0) || !(light_color > 0.0) || !(disk_tint > 0.0) || !(solid_angle > 0.0) || !(limit > 0.0)) {
		return 0.0;
	}
	float maximum_irradiance = limit * solid_angle / light_color / disk_tint;
	if (irradiance >= maximum_irradiance) {
		return limit;
	}
	float smaller_scale = min(light_color, disk_tint);
	float larger_scale = max(light_color, disk_tint);
	float value = (irradiance * smaller_scale) * larger_scale / solid_angle;
	return safe_radiance_component(value, limit);
}

float solar_disk_solid_angle(float angular_radius) {
	if (!(angular_radius > 0.0) || !(angular_radius < PI)) {
		return 0.0;
	}
	float sine_half_angle = sin(angular_radius * 0.5);
	return 4.0 * PI * sine_half_angle * sine_half_angle;
}

float safe_sun_radius(float radius_degrees) {
	if (!(radius_degrees > 0.0)) {
		return 0.0;
	}
	return radians(min(radius_degrees, 2.5));
}

float ray_sphere_exit(vec3 origin, vec3 direction, float radius) {
	float b = dot(origin, direction);
	float origin_radius = length(origin);
	float c = (origin_radius - radius) * (origin_radius + radius);
	float discriminant = b * b - c;
	if (!(discriminant >= 0.0)) {
		return -1.0;
	}
	return max(-b + sqrt(max(discriminant, 0.0)), 0.0);
}

bool ray_hits_ground(vec3 point, vec3 direction) {
	float b = dot(point, direction);
	float point_radius = length(point);
	float c = (point_radius - planet_radius_km) * (point_radius + planet_radius_km);
	float discriminant = b * b - c;
	return b < 0.0 && discriminant >= 0.0;
}

vec3 view_segment_factor(vec3 extinction, float step_length, vec3 segment_transmittance) {
	vec3 factor = vec3(step_length);
	if (extinction.x > 0.0000001) {
		factor.x = (1.0 - segment_transmittance.x) / extinction.x;
	}
	if (extinction.y > 0.0000001) {
		factor.y = (1.0 - segment_transmittance.y) / extinction.y;
	}
	if (extinction.z > 0.0000001) {
		factor.z = (1.0 - segment_transmittance.z) / extinction.z;
	}
	return factor;
}

float absorption_density(float altitude) {
	float density = altitude < absorption_density_layer_width_km
		? absorption_layer0_linear_term * altitude + absorption_layer0_constant_term
		: absorption_layer1_linear_term * altitude + absorption_layer1_constant_term;
	return clamp(density, 0.0, 1.0);
}

vec3 multiple_scattered_radiance(vec3 point, vec3 light_direction) {
	if (!use_multi_scattering_lut || multi_scattering_factor <= 0.0) {
		return vec3(0.0);
	}
	float altitude = max(length(point) - planet_radius_km, 0.0);
	float sun_cosine = clamp(dot(normalize(point), light_direction), -1.0, 1.0);
	vec2 unit_uv = vec2(sign(sun_cosine) * sqrt(abs(sun_cosine)) * 0.5 + 0.5,
		sqrt(clamp(altitude / atmosphere_height_km, 0.0, 1.0)));
	vec2 lut_size = vec2(textureSize(multi_scattering_lut, 0));
	vec2 uv = (vec2(0.5) + clamp(unit_uv, vec2(0.0), vec2(1.0)) * (lut_size - vec2(1.0))) / lut_size;
	return textureLod(multi_scattering_lut, uv, 0.0).rgb * multi_scattering_factor;
}

vec3 direct_optical_columns(vec3 point, vec3 direction, float path_length) {
	vec3 columns = vec3(0.0);
	for (int i = 0; i < 6; i++) {
		float sample_start = float(i) / 6.0;
		float sample_end = float(i + 1) / 6.0;
		sample_start *= sample_start;
		sample_end *= sample_end;
		float segment_length = (sample_end - sample_start) * path_length;
		vec3 sample_point = point + direction * ((sample_start + sample_end) * 0.5 * path_length);
		float altitude = max(length(sample_point) - planet_radius_km, 0.0);
		columns += vec3(exp(-altitude / rayleigh_scale_height_km), exp(-altitude / mie_scale_height_km), absorption_density(altitude)) * segment_length;
	}
	return columns;
}

vec3 transmittance_to_sun(vec3 point, vec3 direction) {
	if (ray_hits_ground(point, direction)) {
		return vec3(0.0);
	}
	float radius = length(point);
	float top_radius = planet_radius_km + atmosphere_height_km;
	float r_mu = dot(point, direction);
	float top_delta = max((top_radius - radius) * (top_radius + radius), 0.0);
	float path_length = max(-r_mu + sqrt(max(r_mu * r_mu + top_delta, 0.0)), 0.0);
	if (path_length <= 0.0) {
		return vec3(1.0);
	}
	if (!use_optical_column_lut) {
		vec3 columns = direct_optical_columns(point, direction, path_length);
		return exp(-(rayleigh_scattering_per_km * columns.x + mie_extinction_coefficients * columns.y + absorption_extinction_per_km * columns.z));
	}
	float rho = sqrt(max((radius - planet_radius_km) * (radius + planet_radius_km), 0.0));
	float horizon_length = sqrt(atmosphere_height_km * (2.0 * planet_radius_km + atmosphere_height_km));
	float minimum_distance = max(top_radius - radius, 0.0);
	float maximum_distance = rho + horizon_length;
	vec2 unit_uv = clamp(vec2((path_length - minimum_distance) / max(maximum_distance - minimum_distance, 0.000001),
		rho / horizon_length), vec2(0.0), vec2(1.0));
	unit_uv.x = 1.0 - sqrt(1.0 - unit_uv.x);
	vec2 lut_size = vec2(textureSize(optical_column_lut, 0));
	vec2 uv = (vec2(0.5) + unit_uv * (lut_size - vec2(1.0))) / lut_size;
	vec3 columns = textureLod(optical_column_lut, uv, 0.0).rgb;
	vec3 optical_depth = rayleigh_scattering_per_km * columns.x + mie_extinction_coefficients * columns.y + absorption_extinction_per_km * columns.z;
	return exp(-optical_depth);
}


vec3 integrate_atmosphere_for_light(vec3 origin, vec3 view_direction, vec3 light_direction, vec3 light_color, float light_irradiance, bool include_multiple_scattering, out vec3 view_transmittance, out float ground_distance, out float atmosphere_entry_distance) {
	float atmosphere_radius = planet_radius_km + max(atmosphere_height_km, 0.001);
	vec3 ray_origin = origin;
	atmosphere_entry_distance = 0.0;
	float atmosphere_distance = 0.0;
	if (length(origin) > atmosphere_radius) {
		float b = dot(origin, view_direction);
		float origin_radius = length(origin);
		float discriminant = b * b - (origin_radius - atmosphere_radius) * (origin_radius + atmosphere_radius);
		if (!(discriminant >= 0.0)) {
			view_transmittance = vec3(1.0);
			ground_distance = -1.0;
			return vec3(0.0);
		}
		float root = sqrt(max(discriminant, 0.0));
		float entry = -b - root;
		float exit = -b + root;
		if (exit <= 0.0) {
			view_transmittance = vec3(1.0);
			ground_distance = -1.0;
			return vec3(0.0);
		}
		atmosphere_entry_distance = max(entry, 0.0);
		ray_origin = origin + view_direction * atmosphere_entry_distance;
		atmosphere_distance = max(exit - atmosphere_entry_distance, 0.0);
	} else {
		atmosphere_distance = ray_sphere_exit(ray_origin, view_direction, atmosphere_radius);
	}
	if (atmosphere_distance <= 0.0) {
		view_transmittance = vec3(1.0);
		ground_distance = -1.0;
		return vec3(0.0);
	}

	float ray_origin_radius = length(ray_origin);
	float ground_discriminant = dot(ray_origin, view_direction) * dot(ray_origin, view_direction)
		- (ray_origin_radius - planet_radius_km) * (ray_origin_radius + planet_radius_km);
	ground_distance = -1.0;
	if (ground_discriminant >= 0.0) {
		float near_ground = -dot(ray_origin, view_direction) - sqrt(max(ground_discriminant, 0.0));
		if (near_ground >= 0.0 && near_ground < atmosphere_distance) {
			ground_distance = near_ground;
			atmosphere_distance = near_ground;
		}
	}

	vec3 sun_dir = safe_normalize_direction(light_direction, vec3(0.0, 1.0, 0.0));
	float cosine_angle = clamp(dot(view_direction, sun_dir), -1.0, 1.0);
	float rayleigh_phase = 3.0 * (1.0 + cosine_angle * cosine_angle) / (16.0 * PI);
	float g = clamp(mie_asymmetry, 0.0, 0.999);
	float mie_denom = max((1.0 - g) * (1.0 - g) + 2.0 * g * (1.0 - cosine_angle), 0.000001);
	float mie_phase = (1.0 - g * g) / (4.0 * PI * pow(mie_denom, 1.5));

	vec3 accumulated_transmittance = vec3(1.0);
	vec3 radiance = vec3(0.0);
	float radial_dot = dot(normalize(ray_origin), view_direction);
	int view_samples = int(clamp(floor(float(VIEW_SAMPLES) * trace_sample_count_scale + 0.5), 2.0, float(MAX_VIEW_SAMPLES)));
	for (int i = 0; i < MAX_VIEW_SAMPLES; i++) {
		if (i >= view_samples) { break; }
		float sample_start = pow(float(i) / float(view_samples), 2.0);
		float sample_end = pow(float(i + 1) / float(view_samples), 2.0);
		if (radial_dot < 0.0) {
			sample_start = 1.0 - pow(1.0 - float(i) / float(view_samples), 2.0);
			sample_end = 1.0 - pow(1.0 - float(i + 1) / float(view_samples), 2.0);
		}
		float segment_length = (sample_end - sample_start) * atmosphere_distance;
		float distance_along_ray = (sample_start + sample_end) * 0.5 * atmosphere_distance;
		vec3 sample_point = ray_origin + view_direction * distance_along_ray;
		float altitude = max(length(sample_point) - planet_radius_km, 0.0);
		vec3 sun_trans = transmittance_to_sun(sample_point, sun_dir);
		float rayleigh_density = exp(-altitude / rayleigh_scale_height_km);
		float mie_density = exp(-altitude / mie_scale_height_km);
		vec3 rayleigh = rayleigh_scattering_per_km * rayleigh_density;
		vec3 mie_scattering = mie_scattering_coefficients * mie_density;
		vec3 source = (rayleigh * rayleigh_phase + mie_scattering * mie_phase) * sun_trans;
		if (include_multiple_scattering) {
			source += (rayleigh + mie_scattering) * multiple_scattered_radiance(sample_point, sun_dir);
		}
		vec3 extinction = rayleigh + mie_extinction_coefficients * mie_density + absorption_extinction_per_km * absorption_density(altitude);
		vec3 segment_transmittance = exp(-extinction * segment_length);
		radiance += accumulated_transmittance * source * view_segment_factor(extinction, segment_length, segment_transmittance);
		accumulated_transmittance *= segment_transmittance;
	}
	view_transmittance = accumulated_transmittance;
	return radiance * max(light_irradiance, 0.0) * max(light_color, vec3(0.0))
		* max(sky_luminance_factor, vec3(0.0)) * max(sky_only_luminance_factor, vec3(0.0));
}

// Compatibility entry point for probes and older custom sky materials.
vec3 integrate_atmosphere(vec3 origin, vec3 view_direction, out vec3 view_transmittance, out float ground_distance, out float atmosphere_entry_distance) {
	return integrate_atmosphere_for_light(origin, view_direction, sun_direction, sun_color_linear, sun_irradiance, true,
		view_transmittance, ground_distance, atmosphere_entry_distance);
}

float solar_disk_weight(vec3 view_direction, vec3 sun_dir, float angular_radius) {
	if (!(angular_radius > 0.0)) {
		return 0.0;
	}
	// For small authored disks, both cos(radius * edge) values round to 1.0
	// in float32 (including the valid 0.01/0.02 degree settings). smoothstep
	// then has equal edges and its result is undefined. Squared chord length
	// is 2 * (1 - cos(angle)), but stays precise at small angles. This is the
	// same angular profile without subtracting nearly equal cosine values.
	vec2 edge_chords = 2.0 * sin(angular_radius * vec2(0.425, 0.575));
	vec2 edge_squared = edge_chords * edge_chords;
	vec3 chord = view_direction - sun_dir;
	return 1.0 - smoothstep(edge_squared.x, edge_squared.y, dot(chord, chord));
}

void sky() {
	vec3 origin_offset_m = POSITION - planet_center_m;
	if (!(planet_radius_km > 0.0) || !(planet_radius_km < 1000000.0)
			|| !(atmosphere_height_km > 0.0) || !(atmosphere_height_km < 1000000.0)
			|| !(rayleigh_scale_height_km > 0.0) || !(rayleigh_scale_height_km < 1000000.0)
			|| !(mie_scale_height_km > 0.0) || !(mie_scale_height_km < 1000000.0)
			|| !(abs(origin_offset_m.x) < 1.0e13) || !(abs(origin_offset_m.y) < 1.0e13)
			|| !(abs(origin_offset_m.z) < 1.0e13)) {
		COLOR = vec3(0.0);
	} else {
	vec3 view_direction = safe_normalize_direction(EYEDIR, vec3(0.0, 1.0, 0.0));
	vec3 origin = origin_offset_m / 1000.0;
	float camera_radius = length(origin);
	vec3 radial_up = camera_radius > 0.0001 ? origin / camera_radius : vec3(0.0, 1.0, 0.0);
	// A 1 m surface epsilon makes downward rays produce a positive ground hit,
	// including the common case where POSITION starts exactly at sea level.
	origin = radial_up * max(camera_radius, planet_radius_km + 0.001);

	vec3 view_transmittance;
	float ground_distance;
	float atmosphere_entry_distance;
	vec3 radiance = integrate_atmosphere(origin, view_direction, view_transmittance, ground_distance, atmosphere_entry_distance);

	// The virtual ground blocks rays; its albedo contributes through the MS LUT,
	// never by painting an artificial planet underneath the horizon.
	if (secondary_sun_irradiance > 0.0) {
		vec3 secondary_transmittance;
		float secondary_ground;
		float secondary_entry;
		radiance += integrate_atmosphere_for_light(origin, view_direction, secondary_sun_direction,
			secondary_sun_color_linear, secondary_sun_irradiance, false, secondary_transmittance, secondary_ground, secondary_entry);
	}

	float sun_radius = safe_sun_radius(sun_angular_radius_deg);
	vec3 primary_sun_direction = safe_normalize_direction(sun_direction, vec3(0.0, 1.0, 0.0));
	float sun_edge = solar_disk_weight(view_direction, primary_sun_direction, sun_radius);
	if (ground_distance < 0.0 && sun_edge > 0.0) {
		float sun_solid_angle = max(solar_disk_solid_angle(sun_radius), 0.000000000001);
		float radiance_limit = effective_sky_radiance_limit();
		vec3 sun_radiance = vec3(
			safe_disk_radiance_component(sun_irradiance, sun_color_linear.r, sun_disk_color_scale.r, sun_solid_angle, radiance_limit),
			safe_disk_radiance_component(sun_irradiance, sun_color_linear.g, sun_disk_color_scale.g, sun_solid_angle, radiance_limit),
			safe_disk_radiance_component(sun_irradiance, sun_color_linear.b, sun_disk_color_scale.b, sun_solid_angle, radiance_limit)
		);
		radiance += sun_radiance * view_transmittance * sun_edge;
	}

	float secondary_radius = safe_sun_radius(secondary_sun_angular_radius_deg);
	if (ground_distance < 0.0 && secondary_sun_irradiance > 0.0 && secondary_radius > 0.0) {
		vec3 secondary_direction = safe_normalize_direction(secondary_sun_direction, vec3(0.0, -1.0, 0.0));
		float secondary_edge = solar_disk_weight(view_direction, secondary_direction, secondary_radius);
		float secondary_solid_angle = max(solar_disk_solid_angle(secondary_radius), 0.000000000001);
		float radiance_limit = effective_sky_radiance_limit();
		vec3 secondary_radiance = vec3(
			safe_disk_radiance_component(secondary_sun_irradiance, secondary_sun_color_linear.r, secondary_sun_disk_color_scale.r, secondary_solid_angle, radiance_limit),
			safe_disk_radiance_component(secondary_sun_irradiance, secondary_sun_color_linear.g, secondary_sun_disk_color_scale.g, secondary_solid_angle, radiance_limit),
			safe_disk_radiance_component(secondary_sun_irradiance, secondary_sun_color_linear.b, secondary_sun_disk_color_scale.b, secondary_solid_angle, radiance_limit)
		);
		radiance += secondary_radiance * view_transmittance * secondary_edge;
	}

	float radiance_limit = effective_sky_radiance_limit();
	COLOR = vec3(
		safe_radiance_component(radiance.r, radiance_limit),
		safe_radiance_component(radiance.g, radiance_limit),
		safe_radiance_component(radiance.b, radiance_limit)
	);
	}
}
