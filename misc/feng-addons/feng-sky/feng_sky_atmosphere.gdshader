shader_type sky;

// Earth-like, scene-linear, single-scattering atmosphere. Distances and
// extinction coefficients use kilometres and inverse kilometres respectively.
// The source is intentionally not multiplied by camera exposure or pre-exposure.

uniform float planet_radius_km = 6360.0;
uniform float atmosphere_height_km = 60.0;
uniform float rayleigh_scale_height_km = 8.0;
uniform float mie_scale_height_km = 1.2;
uniform vec3 rayleigh_scattering_per_km = vec3(0.005802, 0.013558, 0.0331);
uniform float mie_scattering_per_km = 0.003996;
uniform float mie_extinction_per_km = 0.00444;
uniform float mie_asymmetry = 0.8;
uniform vec3 planet_center_m = vec3(0.0, -6360000.0, 0.0);
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_color_linear = vec3(1.0);
uniform float sun_irradiance = 0.0;
uniform float sun_angular_radius_deg = 0.2666;
// FRP applies Environment.background_energy_multiplier after sampling the sky.
// The component lowers this ceiling so the final value stays below RGBA16F max.
uniform float sky_radiance_limit = 60000.0;
uniform vec3 ground_albedo = vec3(0.1);

const int VIEW_SAMPLES = 8;
// Rayleigh and Mie density columns in km. The finite, non-ground-intersecting
// sun-ray domain maps to texel centers; planet shadow is evaluated analytically.
uniform sampler2D optical_column_lut : filter_linear, repeat_disable;
uniform bool use_optical_column_lut = false;
const float INV_PI = 0.3183098861837907;

float ray_sphere_exit(vec3 origin, vec3 direction, float radius) {
	float b = dot(origin, direction);
	float c = dot(origin, origin) - radius * radius;
	float discriminant = b * b - c;
	if (discriminant < 0.0) {
		return -1.0;
	}
	return max(-b + sqrt(discriminant), 0.0);
}

bool ray_hits_ground(vec3 point, vec3 direction) {
	float b = dot(point, direction);
	float c = dot(point, point) - planet_radius_km * planet_radius_km;
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

vec2 direct_optical_columns(vec3 point, vec3 direction, float path_length) {
	vec2 columns = vec2(0.0);
	for (int i = 0; i < 6; i++) {
		float sample_start = float(i) / 6.0;
		float sample_end = float(i + 1) / 6.0;
		sample_start *= sample_start;
		sample_end *= sample_end;
		float segment_length = (sample_end - sample_start) * path_length;
		vec3 sample_point = point + direction * ((sample_start + sample_end) * 0.5 * path_length);
		float altitude = max(length(sample_point) - planet_radius_km, 0.0);
		columns += exp(-altitude / vec2(rayleigh_scale_height_km, mie_scale_height_km)) * segment_length;
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
		vec2 columns = direct_optical_columns(point, direction, path_length);
		return exp(-(rayleigh_scattering_per_km * columns.x + vec3(mie_extinction_per_km * columns.y)));
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
	vec2 columns = textureLod(optical_column_lut, uv, 0.0).rg;
	vec3 optical_depth = rayleigh_scattering_per_km * columns.x + vec3(mie_extinction_per_km * columns.y);
	return exp(-optical_depth);
}


vec3 integrate_atmosphere(vec3 origin, vec3 view_direction, out vec3 view_transmittance, out float ground_distance, out float atmosphere_entry_distance) {
	float atmosphere_radius = planet_radius_km + max(atmosphere_height_km, 0.001);
	vec3 ray_origin = origin;
	atmosphere_entry_distance = 0.0;
	float atmosphere_distance = 0.0;
	if (length(origin) > atmosphere_radius) {
		float b = dot(origin, view_direction);
		float discriminant = b * b - (dot(origin, origin) - atmosphere_radius * atmosphere_radius);
		if (discriminant < 0.0) {
			view_transmittance = vec3(1.0);
			ground_distance = -1.0;
			return vec3(0.0);
		}
		float root = sqrt(discriminant);
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

	float ground_discriminant = dot(ray_origin, view_direction) * dot(ray_origin, view_direction)
		- (dot(ray_origin, ray_origin) - planet_radius_km * planet_radius_km);
	ground_distance = -1.0;
	if (ground_discriminant >= 0.0) {
		float near_ground = -dot(ray_origin, view_direction) - sqrt(ground_discriminant);
		if (near_ground >= 0.0 && near_ground < atmosphere_distance) {
			ground_distance = near_ground;
			atmosphere_distance = near_ground;
		}
	}

	vec3 sun_dir = normalize(sun_direction);
	float cosine_angle = clamp(dot(view_direction, sun_dir), -1.0, 1.0);
	float rayleigh_phase = 3.0 * (1.0 + cosine_angle * cosine_angle) / (16.0 * PI);
	float g = clamp(mie_asymmetry, -0.95, 0.95);
	float mie_denom = max(1.0 + g * g - 2.0 * g * cosine_angle, 0.0001);
	float mie_phase = (1.0 - g * g) / (4.0 * PI * pow(mie_denom, 1.5));

	vec3 accumulated_transmittance = vec3(1.0);
	vec3 radiance = vec3(0.0);
	float radial_dot = dot(normalize(ray_origin), view_direction);
	for (int i = 0; i < VIEW_SAMPLES; i++) {
		float sample_start = pow(float(i) / float(VIEW_SAMPLES), 2.0);
		float sample_end = pow(float(i + 1) / float(VIEW_SAMPLES), 2.0);
		if (radial_dot < 0.0) {
			sample_start = 1.0 - pow(1.0 - float(i) / float(VIEW_SAMPLES), 2.0);
			sample_end = 1.0 - pow(1.0 - float(i + 1) / float(VIEW_SAMPLES), 2.0);
		}
		float segment_length = (sample_end - sample_start) * atmosphere_distance;
		float distance_along_ray = (sample_start + sample_end) * 0.5 * atmosphere_distance;
		vec3 sample_point = ray_origin + view_direction * distance_along_ray;
		float altitude = max(length(sample_point) - planet_radius_km, 0.0);
		vec3 sun_trans = transmittance_to_sun(sample_point, sun_dir);
		float rayleigh_density = exp(-altitude / rayleigh_scale_height_km);
		float mie_density = exp(-altitude / mie_scale_height_km);
		vec3 rayleigh = rayleigh_scattering_per_km * rayleigh_density;
		vec3 source = (rayleigh * rayleigh_phase + vec3(mie_scattering_per_km * mie_density * mie_phase)) * sun_trans;
		vec3 extinction = rayleigh + vec3(mie_extinction_per_km * mie_density);
		vec3 segment_transmittance = exp(-extinction * segment_length);
		radiance += accumulated_transmittance * source * view_segment_factor(extinction, segment_length, segment_transmittance);
		accumulated_transmittance *= segment_transmittance;
	}
	view_transmittance = accumulated_transmittance;
	return radiance * max(sun_irradiance, 0.0) * max(sun_color_linear, vec3(0.0));
}

float solar_disk_weight(vec3 view_direction, vec3 sun_dir, float angular_radius) {
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
	vec3 view_direction = normalize(EYEDIR);
	vec3 origin = (POSITION - planet_center_m) / 1000.0;
	float camera_radius = length(origin);
	vec3 radial_up = camera_radius > 0.0001 ? origin / camera_radius : vec3(0.0, 1.0, 0.0);
	// A 1 m surface epsilon makes downward rays produce a positive ground hit,
	// including the common case where POSITION starts exactly at sea level.
	origin = radial_up * max(camera_radius, planet_radius_km + 0.001);

	vec3 view_transmittance;
	float ground_distance;
	float atmosphere_entry_distance;
	vec3 radiance = integrate_atmosphere(origin, view_direction, view_transmittance, ground_distance, atmosphere_entry_distance);

	if (ground_distance >= 0.0 && max(sun_irradiance, 0.0) > 0.0) {
		vec3 ground_point = origin + view_direction * (atmosphere_entry_distance + ground_distance);
		vec3 ground_normal = normalize(ground_point);
		float sun_cosine = max(dot(ground_normal, normalize(sun_direction)), 0.0);
		vec3 ground_sun_transmittance = transmittance_to_sun(ground_point, normalize(sun_direction));
		vec3 ground_radiance = max(ground_albedo, vec3(0.0)) * max(sun_color_linear, vec3(0.0))
			* (max(sun_irradiance, 0.0) * sun_cosine * INV_PI)
			* ground_sun_transmittance;
		radiance += view_transmittance * ground_radiance;
	}

	float sun_radius = max(radians(sun_angular_radius_deg), 0.00001);
	float sun_edge = solar_disk_weight(view_direction, normalize(sun_direction), sun_radius);
	if (ground_distance < 0.0 && sun_edge > 0.0) {
		float sun_solid_angle = PI * sin(sun_radius) * sin(sun_radius);
		vec3 sun_radiance = min(
			max(sun_color_linear, vec3(0.0)) * max(sun_irradiance, 0.0) / max(sun_solid_angle, 0.0000001),
			vec3(max(sky_radiance_limit, 0.0))
		);
		radiance += sun_radiance * view_transmittance * sun_edge;
	}

	COLOR = clamp(radiance, vec3(0.0), vec3(max(sky_radiance_limit, 0.0)));
}
