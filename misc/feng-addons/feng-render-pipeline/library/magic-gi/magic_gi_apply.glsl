#[compute]
#version 450

// FMagicGI apply: adds a baked SH probe field's diffuse irradiance onto the
// resolved scene color. One baked volume is active at a time; its SH table is a
// one-row RGBA32F atlas, 7 texels per probe (9 coefficients x RGB).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_roughness;
layout(set = 0, binding = 3) uniform sampler2D gbuffer_albedo;
layout(set = 0, binding = 4) uniform sampler2D sh_atlas;
// Dense probe index -> atlas slot (-1 = culled). dims.x wide, dims.y*dims.z
// tall so probe p is texel (p % dims.x, p / dims.x).
layout(set = 0, binding = 6) uniform usampler2D index_map;

layout(push_constant, std430) uniform Params {
	vec4 extra; // x = authored strength multiplier (the .tres' parameters)
} pc;

layout(set = 0, binding = 5, std140) uniform GIParams {
	mat4 inv_view_proj;   // clip -> world (z is the raw depth value)
	mat4 world_to_grid;   // world -> probe-grid index space
	vec4 grid;            // xyz = dims, w = probe_count
	vec4 control;         // x = gi_strength
} params;

// Y_l,m in the same order the baker projects (l<=2):
// Y0, Y1-1(y), Y10(z), Y11(x), Y2-2(xy), Y2-1(yz), Y20(3z2-1), Y21(xz), Y22(x2-y2).
// Multiplied by the cosine-convolution band weights pi, 2pi/3, pi/4 so the sum
// below evaluates diffuse irradiance E(n) directly.
vec3 irradiance_of_probe(int probe, vec3 n) {
	// Texel packing (coeff-major, 27 floats): t0=(c0,c1.r) t1=(c1.gb,c2.rg)
	// t2=(c2.b,c3) t3=(c4,c5.r) t4=(c5.gb,c6.rg) t5=(c6.b,c7) t6=(c8,-).
	vec4 t0 = texelFetch(sh_atlas, ivec2(probe * 7 + 0, 0), 0);
	vec4 t1 = texelFetch(sh_atlas, ivec2(probe * 7 + 1, 0), 0);
	vec4 t2 = texelFetch(sh_atlas, ivec2(probe * 7 + 2, 0), 0);
	vec4 t3 = texelFetch(sh_atlas, ivec2(probe * 7 + 3, 0), 0);
	vec4 t4 = texelFetch(sh_atlas, ivec2(probe * 7 + 4, 0), 0);
	vec4 t5 = texelFetch(sh_atlas, ivec2(probe * 7 + 5, 0), 0);
	vec4 t6 = texelFetch(sh_atlas, ivec2(probe * 7 + 6, 0), 0);
	vec3 c0 = t0.rgb;
	vec3 c1 = vec3(t0.a, t1.rg);   // * 0.488603 * n.y
	vec3 c2 = vec3(t1.ba, t2.r);   // * 0.488603 * n.z
	vec3 c3 = t2.gba;              // * 0.488603 * n.x
	vec3 c4 = t3.rgb;              // * 1.092548 * n.x*n.y
	vec3 c5 = vec3(t3.a, t4.rg);   // * 1.092548 * n.y*n.z
	vec3 c6 = vec3(t4.ba, t5.r);   // * 0.315392 * (3z^2-1)
	vec3 c7 = t5.gba;              // * 1.092548 * n.x*n.z
	vec3 c8 = t6.rgb;              // * 0.546274 * (x^2-y^2)
	vec3 e = c0 * 0.8862269255;    // pi * 0.282095
	e += (c1 * n.y + c2 * n.z + c3 * n.x) * 1.0233267079;   // 2pi/3 * 0.488603
	e += (c4 * (n.x * n.y) + c5 * (n.y * n.z) + c7 * (n.x * n.z)) * 0.8580862330; // pi/4 * 1.092548
	e += c6 * (3.0 * n.z * n.z - 1.0) * 0.2477075583;       // pi/4 * 0.315392
	e += c8 * (n.x * n.x - n.y * n.y) * 0.4290428065;       // pi/4 * 0.546274
	return e;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, imageSize(color_image)))) {
		return;
	}
	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(imageSize(color_image));
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (depth <= 0.0) {
		return; // sky: no surface to light.
	}
	vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 world4 = params.inv_view_proj * clip;
	vec3 world = world4.xyz / world4.w;
	vec3 normal = normalize(texelFetch(normal_roughness, pixel, 0).xyz * 2.0 - 1.0);
	vec3 albedo = texelFetch(gbuffer_albedo, pixel, 0).rgb;

	// Grid coordinates and the border fade (half a cell outside the volume;
	// single-probe axes have no border).
	vec3 g = (params.world_to_grid * vec4(world, 1.0)).xyz;
	vec3 dims = params.grid.xyz;
	vec3 edge = min(g + vec3(0.5), dims - vec3(0.5) - g);
	edge = max(edge, step(dims, vec3(1.0)));
	float weight = clamp(min(edge.x, min(edge.y, edge.z)), 0.0, 1.0);
	if (weight <= 0.0) {
		return;
	}
	// The normal is a direction: transform it with the grid basis (uniform-scale
	// safe) and normalize; the SH itself was baked in this same local frame.
	vec3 n_local = normalize(mat3(params.world_to_grid) * normal);

	// Trilinear blend of the irradiance evaluated at the 8 surrounding probes.
	// Culled probes (-1 slot) contribute nothing; the surviving weights are
	// renormalized so surface cells keep full-strength light.
	vec3 base = clamp(floor(g), vec3(0.0), max(dims - vec3(2.0), vec3(0.0)));
	vec3 f = clamp(g - base, vec3(0.0), vec3(1.0));
	ivec3 i0 = ivec3(base);
	vec3 irradiance = vec3(0.0);
	float weight_sum = 0.0;
	for (int dz = 0; dz <= 1; dz++) {
		for (int dy = 0; dy <= 1; dy++) {
			for (int dx = 0; dx <= 1; dx++) {
				ivec3 cell = i0 + ivec3(dx, dy, dz);
				cell = clamp(cell, ivec3(0), ivec3(dims) - 1);
				int probe = cell.x + cell.y * int(dims.x) + cell.z * int(dims.x * dims.y);
				int slot = int(texelFetch(index_map,
						ivec2(cell.x, cell.y + cell.z * int(dims.y)), 0).x);
				if (slot < 0) {
					continue;
				}
				vec3 e = irradiance_of_probe(slot, n_local);
				float w = ((dx == 0) ? (1.0 - f.x) : f.x)
						* ((dy == 0) ? (1.0 - f.y) : f.y)
						* ((dz == 0) ? (1.0 - f.z) : f.z);
				irradiance += e * w;
				weight_sum += w;
			}
		}
	}
	if (weight_sum > 0.0) {
		irradiance /= weight_sum;
	}

	vec4 color = imageLoad(color_image, pixel);
	imageStore(color_image, pixel,
			vec4(color.rgb + albedo * irradiance * params.control.x * pc.extra.x * weight, color.a));
}
