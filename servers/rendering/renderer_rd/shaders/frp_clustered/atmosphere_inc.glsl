// Keep this file byte-identical to the addon height-fog transport include.
// ATMO_PARAMS is sixteen vec4s; texture macros resolve to sampler2D values.
const float FRP_ATMO_PI = 3.141592653589793;

float frp_atmo_absorption_density(float h) {
	return h < ATMO_PARAMS[5].x
			? clamp(ATMO_PARAMS[5].y * h + ATMO_PARAMS[5].z, 0.0, 1.0)
			: clamp(ATMO_PARAMS[5].w * h + ATMO_PARAMS[6].x, 0.0, 1.0);
}

vec3 frp_atmo_density(float h) {
	return vec3(exp(-h / ATMO_PARAMS[1].w), exp(-h / ATMO_PARAMS[2].w), frp_atmo_absorption_density(h));
}

bool frp_atmo_ground_hit(vec3 p, vec3 direction) {
	float b = dot(p, direction);
	float r = length(p);
	float R = ATMO_PARAMS[0].w;
	return b < 0.0 && b * b - (r - R) * (r + R) >= 0.0;
}

vec3 frp_atmo_transmittance(vec3 p, vec3 direction) {
	if (frp_atmo_ground_hit(p, direction)) {
		return vec3(0.0);
	}
	float radius = length(p);
	float bottom = ATMO_PARAMS[0].w;
	float top = bottom + ATMO_PARAMS[4].w;
	float b = dot(p, direction);
	float discriminant = b * b - (radius - top) * (radius + top);
	if (discriminant < 0.0 || -b + sqrt(discriminant) <= 0.0) {
		return vec3(1.0);
	}
	float entry = radius > top ? max(-b - sqrt(discriminant), 0.0) : 0.0;
	float path = max(-b + sqrt(discriminant) - entry, 0.0);
	p += direction * entry;
	radius = length(p);
	vec3 columns = vec3(0.0);
	#ifndef ATMO_DIRECT_ONLY
	if (ATMO_PARAMS[12].x > 0.5) {
		float rho = sqrt(max((radius - bottom) * (radius + bottom), 0.0));
		float horizon = sqrt(ATMO_PARAMS[4].w * (2.0 * bottom + ATMO_PARAMS[4].w));
		float minimum = max(top - radius, 0.0);
		vec2 uv = clamp(vec2((path - minimum) / max(rho + horizon - minimum, 0.000001), rho / horizon), vec2(0.0), vec2(1.0));
		uv.x = 1.0 - sqrt(1.0 - uv.x);
		vec2 size = vec2(textureSize(ATMO_OPTICAL, 0));
		uv = (vec2(0.5) + uv * (size - vec2(1.0))) / size;
		columns = textureLod(ATMO_OPTICAL, uv, 0.0).rgb;
	} else
	#endif
	{
		for (int i = 0; i < 6; i++) {
			float a = float(i) / 6.0;
			float z = float(i + 1) / 6.0;
			a *= a;
			z *= z;
			float h = max(length(p + direction * ((a + z) * 0.5 * path)) - bottom, 0.0);
			columns += frp_atmo_density(h) * ((z - a) * path);
		}
	}
	return exp(-(ATMO_PARAMS[1].xyz * columns.x + ATMO_PARAMS[3].xyz * columns.y + ATMO_PARAMS[4].xyz * columns.z));
}

vec3 frp_atmo_surface_transmittance(vec3 camera_to_receiver_m, int slot) {
	vec3 p = ATMO_PARAMS[0].xyz + camera_to_receiver_m * 0.001;
	float radius = length(p);
	vec3 up = radius > 0.00001 ? p / radius : vec3(0.0, 1.0, 0.0);
	p = up * max(radius, ATMO_PARAMS[0].w + 0.001);
	vec3 light = ATMO_PARAMS[8 + slot * 2].xyz;
	float min_elevation = sin(ATMO_PARAMS[9].w * FRP_ATMO_PI / 180.0);
	float elevation = dot(up, light);
	if (elevation < min_elevation) {
		vec3 tangent = light - up * elevation;
		if (dot(tangent, tangent) < 0.000001) {
			tangent = vec3(1.0, 0.0, 0.0) - up * up.x;
			if (dot(tangent, tangent) < 0.000001) {
				tangent = vec3(0.0, 0.0, 1.0) - up * up.z;
			}
		}
		light = up * min_elevation + normalize(tangent) * sqrt(max(1.0 - min_elevation * min_elevation, 0.0));
	}
	return frp_atmo_transmittance(p, light);
}

#ifndef ATMO_DIRECT_ONLY
vec3 frp_atmo_multiple(vec3 p, vec3 light) {
	float h = max(length(p) - ATMO_PARAMS[0].w, 0.0);
	float mu = clamp(dot(normalize(p), light), -1.0, 1.0);
	vec2 uv = clamp(vec2(0.5 + 0.5 * sign(mu) * sqrt(abs(mu)), sqrt(h / ATMO_PARAMS[4].w)), vec2(0.0), vec2(1.0));
	vec2 size = vec2(textureSize(ATMO_MULTIPLE, 0));
	return textureLod(ATMO_MULTIPLE, (vec2(0.5) + uv * (size - vec2(1.0))) / size, 0.0).rgb;
}

void frp_atmo_aerial(vec3 camera_to_receiver_m, vec3 eye_offset_m, out vec3 radiance, out vec3 transmission) {
	radiance = vec3(0.0);
	transmission = vec3(1.0);
	float receiver_distance = length(camera_to_receiver_m) * 0.001 * ATMO_PARAMS[6].w;
	if (receiver_distance <= ATMO_PARAMS[6].z || receiver_distance <= 0.000001) {
		return;
	}
	vec3 direction = normalize(camera_to_receiver_m);
	vec3 origin = ATMO_PARAMS[0].xyz + eye_offset_m * 0.001;
	float bottom = ATMO_PARAMS[0].w;
	float radius = length(origin);
	origin = (radius > 0.00001 ? origin / radius : vec3(0.0, 1.0, 0.0)) * max(radius, bottom + 0.001);
	radius = length(origin);
	float top = bottom + ATMO_PARAMS[4].w;
	float b = dot(origin, direction);
	float discriminant = b * b - (radius - top) * (radius + top);
	if (discriminant < 0.0) {
		return;
	}
	float begin = max(ATMO_PARAMS[6].z, -b - sqrt(discriminant));
	float end = min(receiver_distance, -b + sqrt(discriminant));
	float ground_discriminant = b * b - (radius - bottom) * (radius + bottom);
	if (ground_discriminant >= 0.0 && b < 0.0) {
		end = min(end, -b - sqrt(ground_discriminant));
	}
	if (end <= begin) {
		return;
	}
	int samples = int(clamp(ATMO_PARAMS[7].w, 2.0, 64.0));
	float g = ATMO_PARAMS[3].w;
	vec3 ray_origin = origin + direction * begin;
	float path = end - begin;
	bool downward = dot(ray_origin, direction) < 0.0;
	for (int i = 0; i < 64; i++) {
		if (i >= samples) {
			break;
		}
		float a = float(i) / float(samples);
		float z = float(i + 1) / float(samples);
		a = downward ? 1.0 - (1.0 - a) * (1.0 - a) : a * a;
		z = downward ? 1.0 - (1.0 - z) * (1.0 - z) : z * z;
		float ds = (z - a) * path;
		vec3 p = ray_origin + direction * ((a + z) * 0.5 * path);
		vec3 density = frp_atmo_density(max(length(p) - bottom, 0.0));
		vec3 rayleigh = ATMO_PARAMS[1].xyz * density.x;
		vec3 mie = ATMO_PARAMS[2].xyz * density.y;
		vec3 extinction = rayleigh + ATMO_PARAMS[3].xyz * density.y + ATMO_PARAMS[4].xyz * density.z;
		vec3 source = vec3(0.0);
		for (int slot = 0; slot < 2; slot++) {
			vec4 light = ATMO_PARAMS[8 + slot * 2];
			if (light.w <= 0.0) {
				continue;
			}
			float mu = clamp(dot(direction, light.xyz), -1.0, 1.0);
			float rayleigh_phase = 3.0 * (1.0 + mu * mu) / (16.0 * FRP_ATMO_PI);
			float denom = max(1.0 + g * g - 2.0 * g * mu, 0.0001);
			float mie_phase = 3.0 * (1.0 - g * g) * (1.0 + mu * mu) / (8.0 * FRP_ATMO_PI * (2.0 + g * g) * pow(denom, 1.5));
			vec3 unit_source = (rayleigh * rayleigh_phase + mie * mie_phase) * frp_atmo_transmittance(p, light.xyz);
			// UE 5.8 overview documents multiple scattering for the primary light only.
			if (slot == 0 && ATMO_PARAMS[12].y > 0.5 && ATMO_PARAMS[6].y > 0.0) {
				unit_source += (rayleigh + mie) * frp_atmo_multiple(p, light.xyz) * ATMO_PARAMS[6].y;
			}
			source += unit_source * light.w * ATMO_PARAMS[9 + slot * 2].xyz;
		}
		vec3 segment_transmission = exp(-extinction * ds);
		vec3 factor = vec3(ds);
		for (int channel = 0; channel < 3; channel++) {
			if (extinction[channel] > 0.0000001) {
				factor[channel] = (1.0 - segment_transmission[channel]) / extinction[channel];
			}
		}
		radiance += transmission * source * factor;
		transmission *= segment_transmission;
	}
	radiance = clamp(radiance * ATMO_PARAMS[7].xyz, vec3(0.0), vec3(60000.0));
}

#endif // ATMO_DIRECT_ONLY
