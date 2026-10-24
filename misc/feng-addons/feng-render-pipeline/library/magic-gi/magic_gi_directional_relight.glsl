#[compute]
#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, std430) readonly buffer Transfer { float values[]; } transport;
layout(set = 0, binding = 1, std430) readonly buffer Sky { float values[]; } sky;
layout(set = 0, binding = 2, std430) readonly buffer Emission { float values[]; } emission;
layout(set = 0, binding = 3, std430) readonly buffer Sources { float values[]; } sources;
layout(set = 0, binding = 4, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid;
	vec4 control;
	vec4 lighting_sh[7];
	vec4 sky_lighting_sh[7];
} params;
layout(set = 0, binding = 5, std430) writeonly buffer Lighting { vec4 values[]; } lighting;
layout(set = 0, binding = 6, std430) readonly buffer Normals { vec4 values[]; } normals;
layout(set = 0, binding = 7, std430) readonly buffer SurfaceReference { vec4 values[]; } reference;
// Optional normal-independent SH sidecar for layout14. Binding 5 remains the
// calibrated 20-vec4 production buffer and is byte-for-byte unchanged.
layout(set = 0, binding = 8, std430) writeonly buffer RawDirectional { vec4 values[]; } raw_directional;
#include "magic_gi_sh.glslinc"
layout(push_constant, std430) uniform Configuration { int probes; int emitters; int write_raw_sidecar; } config;

vec3 coefficient(vec4 blocks[7], int k) {
	int i = k * 3;
	return vec3(blocks[i / 4][i % 4], blocks[(i + 1) / 4][(i + 1) % 4], blocks[(i + 2) / 4][(i + 2) % 4]);
}

void main() {
	int index = int(gl_GlobalInvocationID.x);
	int probe = index;
	if (probe >= config.probes) { return; }
	float normal_basis[9]; diffuse_basis(normals.values[probe].xyz, normal_basis);
	vec3 surface_secondary = vec3(0.0);
	vec3 surface_primary = vec3(0.0);
	vec3 constant_secondary = vec3(0.0);
	vec3 constant_primary = vec3(0.0);
	for (int outgoing = 0; outgoing < 9; outgoing++) {
		vec3 secondary = vec3(0.0);
		vec3 primary = vec3(0.0);
		for (int incoming = 0; incoming < 9; incoming++) {
			int base = probe * 243 + outgoing * 27 + incoming * 3;
			secondary += vec3(transport.values[base], transport.values[base + 1], transport.values[base + 2]) * coefficient(params.lighting_sh, incoming);
			primary += sky.values[probe * 81 + outgoing * 9 + incoming] * coefficient(params.sky_lighting_sh, incoming);
		}
		for (int emitter = 0; emitter < config.emitters; emitter++) {
			int base = (emitter * config.probes + probe) * 54 + outgoing * 6;
			for (int c = 0; c < 3; c++) {
				secondary[c] += emission.values[base + c] * sources.values[emitter * 6 + c]
						+ emission.values[base + 3 + c] * sources.values[emitter * 6 + 3 + c];
			}
		}
		if (config.write_raw_sidecar != 0) {
			// Capture the raw normal-independent outgoing SH before the exact
			// surface-reference calibration below rewrites coefficient zero.
			raw_directional.values[probe * 18 + outgoing] = vec4(secondary, 0.0);
			raw_directional.values[probe * 18 + 9 + outgoing] = vec4(primary, 0.0);
		}
		if (outgoing == 0) { constant_secondary = secondary; constant_primary = primary; }
		// Signed SH coefficients are retained. Clamp only after cosine convolution.
		lighting.values[probe * 20 + outgoing] = vec4(secondary, 0.0);
		lighting.values[probe * 20 + 9 + outgoing] = vec4(primary, 0.0);
		surface_secondary += secondary * normal_basis[outgoing];
		surface_primary += primary * normal_basis[outgoing];
	}
	// Low-order SH leaks a bright grazing/behind-surface emitter into the receiving
	// hemisphere. Preserve angular variation but calibrate its constant term to
	// the unbiased surface estimator traced alongside the spherical transport.
	vec3 exact_secondary = reference.values[probe * 2].rgb;
	vec3 exact_primary = reference.values[probe * 2 + 1].rgb;
	lighting.values[probe * 20] = vec4(constant_secondary + (exact_secondary - surface_secondary) / normal_basis[0], 0.0);
	lighting.values[probe * 20 + 9] = vec4(constant_primary + (exact_primary - surface_primary) / normal_basis[0], 0.0);
	lighting.values[probe * 20 + 18] = vec4(exact_secondary, 0.0);
	lighting.values[probe * 20 + 19] = vec4(exact_primary, 0.0);
}
