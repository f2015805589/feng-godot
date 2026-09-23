R"(
// The #version, descriptors and std430 structs are assembled by
// terrain_3d_surface_baker.cpp.  This file is appended after idweight_r16.glsl so
// the bake path calls the exact packed-ID weighting, triplanar and selection helpers
// used by the material shader.

float surface_bake_random(vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 surface_bake_rotate(vec2 v, vec2 cs) {
	return vec2(fma(cs.x, v.x, cs.y * v.y), fma(cs.x, v.y, -cs.y * v.x));
}

// The square one tap reads from, which is the one thing about a job's *source* the ring changed. A
// page job's source is a stored rect `dims.x` texels wide with a gutter, and a tap that leaves it
// clamps - the shipped behaviour, which is what `source.x == 0` names. A clipmap job's source is a
// level of the ring: `dims.x` texels that *wrap*, because the ring stores a level rotated by its own
// ring offset - the payload and the height of logical texel `l` live at `mod(l + ring, size)` - which
// is what lets a level that turned a strip keep the texels it did not lose.
ivec2 surface_bake_source_coord(ivec2 coord) {
	ivec2 size = ivec2(int(bake_push.dims.x));
	if (bake_push.source.x == 0u) {
		return clamp(coord, ivec2(0), size - ivec2(1));
	}
	return (coord + ivec2(bake_push.source.yz)) % size;
}

uint surface_bake_read_id(ivec2 coord, uint layer) {
	float encoded = texelFetch(bake_idweights, ivec3(surface_bake_source_coord(coord), int(layer)), 0).r;
	// A page's id layer is `R16_UNORM`, so the fetch is normalised and the packed id/weight pair is
	// 65535 times it. The ring's is `FORMAT_RF` holding the pair raw - the material source writes it
	// unrescaled, because a packed pair is not a colour - and clamping that to 1.0 would read every id
	// as 65535.
	return bake_push.source.w == 0u
			? uint(round(clamp(encoded, 0.0, 1.0) * 65535.0))
			: uint(round(clamp(encoded, 0.0, 65535.0)));
}

float surface_bake_read_height(ivec2 coord, uint layer) {
	return texelFetch(bake_height, ivec3(surface_bake_source_coord(coord), int(layer)), 0).r;
}

vec3 surface_bake_normal(float left, float right, float up, float dx, float dz) {
	// The cross product of (dx, dh/dx, 0) and (0, dh/dz, dz), written without a
	// division so it remains well behaved for very small page texel sizes.
	return normalize(vec3((left - right) * dz, dx * dz, (left - up) * dx));
}

struct SurfaceBakeMaterial {
	vec4 albedo_height;
	vec4 normal_roughness;
	float normal_map_depth;
	float ao;
	float ao_affect;
	float total_weight;
};

void surface_bake_accumulate_layer(uint id, float weight, vec3 base_ddx, vec3 base_ddy,
		uint projection_axis, vec3 geometric_normal_ws, vec3 vertex,
		inout SurfaceBakeMaterial material, inout vec3 blended_normal_ws) {
	if (weight <= 0.0 || id >= bake_push.dims.z) {
		return;
	}
	MaterialParams params = bake_materials.materials[id];
	float id_scale = params.uv_detile.x;
	vec2 i_uv = idweight_get_projection_position(vertex, projection_axis) * id_scale;
	vec2 i_dd_uv = idweight_get_projection_position(base_ddx, projection_axis) * id_scale;
	vec2 i_dd_uv2 = idweight_get_projection_position(base_ddy, projection_axis) * id_scale;

	vec2 uv_center = floor(i_uv + 0.5);
	vec2 id_detile = fma(surface_bake_random(uv_center), 2.0, -1.0) * params.uv_detile.yz * TAU;
	vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
	vec2 id_uv = surface_bake_rotate(i_uv - uv_center, id_cs_angle) + uv_center + id_detile.y - 0.5;
	// Rotate the derivatives counter to the texture rotation, matching main.glsl.
	id_cs_angle = vec2(id_cs_angle.x, -id_cs_angle.y);
	i_dd_uv = surface_bake_rotate(i_dd_uv, id_cs_angle);
	i_dd_uv2 = surface_bake_rotate(i_dd_uv2, id_cs_angle);

	vec4 albedo = textureGrad(bake_albedo, vec3(id_uv, float(id)), i_dd_uv, i_dd_uv2);
	vec4 normal_sample = textureGrad(bake_normal, vec3(id_uv, float(id)), i_dd_uv, i_dd_uv2);
	albedo.rgb *= params.color.rgb;
	normal_sample.a = clamp(normal_sample.a + params.normal_ao_rough.w, 0.0, 1.0);
	vec3 normal_ps = idweight_decode_normal(normal_sample, params.normal_ao_rough.x);
	float ao = length(normal_sample.xyz) * 2.0 - 1.0;
	ao = mix(ao * ao * params.normal_ao_rough.y + 1.0 - params.normal_ao_rough.y,
			1.0, albedo.a * albedo.a);

	vec3 layer_normal_ws = idweight_projection_normal_to_world(
			normal_ps, projection_axis, geometric_normal_ws);
	float normal_damp = idweight_saturate(params.slope.z * 0.001);
	layer_normal_ws = normalize(mix(layer_normal_ws, normalize(geometric_normal_ws), normal_damp));

	material.albedo_height = fma(albedo, vec4(weight), material.albedo_height);
	material.normal_roughness = fma(normal_sample, vec4(weight), material.normal_roughness);
	material.normal_map_depth = fma(params.normal_ao_rough.x, weight, material.normal_map_depth);
	material.ao = fma(ao, weight, material.ao);
	material.ao_affect = fma(params.normal_ao_rough.z, weight, material.ao_affect);
	material.total_weight += weight;
	blended_normal_ws += layer_normal_ws * weight;
}

float surface_bake_slope_overlay_weight(uint packed, uint background_id, uint overlay_id,
		float slope_distance_blend, uint projection_axis, vec3 geometric_normal_ws,
		vec3 base_ddx, vec3 base_ddy, vec3 vertex) {
	if (overlay_id == background_id || background_id >= bake_push.dims.z || overlay_id >= bake_push.dims.z) {
		return 0.0;
	}
	MaterialParams background = bake_materials.materials[background_id];
	MaterialParams overlay = bake_materials.materials[overlay_id];
	float blend_sharpness = idweight_saturate(clamp(background.slope.x, 0.1, 1000.0) * 0.001);
	float slope_based_damp = idweight_saturate(overlay.slope.y * 0.001);
	float id_scale = overlay.uv_detile.x;
	vec2 i_uv = idweight_get_projection_position(vertex, projection_axis) * id_scale;
	vec2 i_dd_uv = idweight_get_projection_position(base_ddx, projection_axis) * id_scale;
	vec2 i_dd_uv2 = idweight_get_projection_position(base_ddy, projection_axis) * id_scale;
	vec2 uv_center = floor(i_uv + 0.5);
	vec2 id_detile = fma(surface_bake_random(uv_center), 2.0, -1.0) * overlay.uv_detile.yz * TAU;
	vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
	vec2 id_uv = surface_bake_rotate(i_uv - uv_center, id_cs_angle) + uv_center + id_detile.y - 0.5;
	id_cs_angle = vec2(id_cs_angle.x, -id_cs_angle.y);
	i_dd_uv = surface_bake_rotate(i_dd_uv, id_cs_angle);
	i_dd_uv2 = surface_bake_rotate(i_dd_uv2, id_cs_angle);
	vec4 normal_sample = textureGrad(bake_normal, vec3(id_uv, float(overlay_id)), i_dd_uv, i_dd_uv2);
	vec3 normal_ps = idweight_decode_normal(normal_sample, overlay.normal_ao_rough.x);
	vec3 combined_normal_ws = idweight_projection_normal_to_world(
			normal_ps, projection_axis, geometric_normal_ws);
	vec3 normalized_geometric_normal_ws = normalize(geometric_normal_ws);
	float vertex_up = idweight_saturate(dot(normalized_geometric_normal_ws, vec3(0.0, 1.0, 0.0)));
	vec3 flattened_vertical_normal = normalize(mix(combined_normal_ws, vec3(0.0, 1.0, 0.0), vertex_up));
	vec3 slope_normal = normalize(mix(combined_normal_ws, flattened_vertical_normal, slope_based_damp));
	return idweight_compute_slope_tangent(slope_normal,
			idweight_slope_threshold(packed), blend_sharpness);
}

void surface_bake_add_pair_vertex(uint packed, float barycentric,
		uint packed_bottom_left, uint packed_bottom_right, uint packed_top_left, uint packed_top_right,
		vec2 local, float slope_distance_blend, uint projection_axis, vec3 geometric_normal_ws,
		vec3 base_ddx, vec3 base_ddy, vec3 vertex,
		inout IdWeightContributions values, inout float interpolated_overlay_weight) {
	uint background_id = idweight_background(packed);
	uint overlay_id = idweight_overlay(packed);
	uint mode = idweight_mode(packed);
	float linear_weight = idweight_weight(packed);
	float slope_blend = 0.0;
	float slope_weight = linear_weight;
	if (mode != IDWEIGHT_MODE_SET && slope_distance_blend > 0.0) {
		float pair_coverage = idweight_bilinear_pair_coverage(
			packed_bottom_left, packed_bottom_right, packed_top_left, packed_top_right, packed, local);
		slope_blend = idweight_slope_interior_blend(pair_coverage) * slope_distance_blend;
		slope_weight = surface_bake_slope_overlay_weight(packed, background_id, overlay_id,
			slope_distance_blend, projection_axis, geometric_normal_ws, base_ddx, base_ddy, vertex);
	}
	float mode_target_weight = idweight_resolve_mode_target_weight(mode, linear_weight, slope_weight);
	float overlay_weight = mix(linear_weight, mode_target_weight, idweight_saturate(slope_blend));
	float background_weight = 1.0 - overlay_weight;
	idweight_add_contribution(background_id, barycentric * background_weight, values);
	if (overlay_id != background_id) {
		idweight_add_contribution(overlay_id, barycentric * overlay_weight, values);
	}
	interpolated_overlay_weight += barycentric * overlay_weight;
}

)"
		R"(
// A split of its own, for the reason `main.glsl` has one (MSVC truncates a string literal past 16 kB):
// the entry point below is a section rather than an addition to a literal that is already at the limit.

void surface_bake_invalidate(ivec3 output_coord) {
	imageStore(bake_output_albedo, output_coord, vec4(0.0));
	imageStore(bake_output_normal, output_coord, vec4(0.0));
	imageStore(bake_output_params, output_coord, vec4(0.0));
}

void main() {
	ivec3 gid = ivec3(gl_GlobalInvocationID);
	// The dispatch covers `output.zw` texels - the rect this job fills - not the whole layer, which is
	// what lets a ring's job cover a strip of a level while `dims.x` still names the level's own size
	// for the source reads below.
	if (uint(gid.x) >= bake_push.dest.z || uint(gid.y) >= bake_push.dest.w || uint(gid.z) >= bake_push.dims.y) {
		return;
	}
	BakeJob job = bake_jobs.jobs[gid.z];
	// The output texel is `dest.xy` inside the output layer plus the invocation's own texel. Those
	// layers are indexed by the *stored* texel either way: a page's job covers a rect of the page's own
	// grid (its origin is zero), and a ring's covers a rect of a level in the order the level's stored
	// content is - the order the ring's own payload layer is in, and the one that keeps naming the same
	// world position as the level turns. A reader of these layers - the material arm - therefore samples
	// a ring level with the payload's own addressing, ring offset and all.
	ivec3 output_coord = ivec3(gid.xy + ivec2(bake_push.dest.xy), int(job.indices.y));
	if (job.indices.z == 0u || bake_push.dims.z == 0u) {
		surface_bake_invalidate(output_coord);
		return;
	}

	uint source_layer = job.indices.x;
	// The height is read from its own layer, which is a *different* array of the same layer count,
	// not necessarily the layer the payload came from. A page holds both at one index, so its job
	// sets the two equal; a ring's material channel keeps its payload and its height in two layers
	// of one array, so its job names both. One field, because both readers are the same fetch.
	uint height_layer = job.indices.w;
	int border = int(job.page.w + 0.5);
	vec2 local = vec2(gid.xy) - vec2(float(border)) + vec2(0.5);
	vec2 world_xz;
	if (bake_push.source.x != 0u) {
		// A ring level: the invocation's texel is a *stored* one, and the world position it stands for
		// is its *logical* texel's - the stored index turned back by the level's ring. `policy.yz` is
		// the level's world origin and `policy.w` its texel, so the mapping below is the same affine one
		// a page's job uses, and the tap it names is the *logical* texel - which is what
		// `surface_bake_source_coord()` turns into the stored one the payload and height layers hold.
		ivec2 stored_size = ivec2(int(bake_push.dims.x));
		ivec2 stored = ivec2(bake_push.dest.xy) + gid.xy;
		ivec2 logical = (stored - ivec2(bake_push.source.yz) + stored_size) % stored_size;
		world_xz = job.policy.yz + (vec2(logical) + vec2(0.5)) * job.page.xy;
	} else {
		world_xz = job.world_rect.xy + local * job.page.xy;
	}
	bool source_grid = job.policy.w > 0.0;
	vec2 source_position = source_grid ? (world_xz - job.policy.yz) / job.policy.w : local + vec2(border);
	ivec2 cell = ivec2(floor(source_position));
	vec2 cell_local = fract(source_position);
	uint packed_bottom_left = surface_bake_read_id(cell, source_layer);
	uint packed_bottom_right = surface_bake_read_id(cell + ivec2(1, 0), source_layer);
	uint packed_top_left = surface_bake_read_id(cell + ivec2(0, 1), source_layer);
	uint packed_top_right = surface_bake_read_id(cell + ivec2(1, 1), source_layer);

	float h00 = surface_bake_read_height(cell, height_layer);
	float h10 = surface_bake_read_height(cell + ivec2(1, 0), height_layer);
	float h01 = surface_bake_read_height(cell + ivec2(0, 1), height_layer);
	float h11 = surface_bake_read_height(cell + ivec2(1, 1), height_layer);
	float h20 = surface_bake_read_height(cell + ivec2(2, 0), height_layer);
	float h02 = surface_bake_read_height(cell + ivec2(0, 2), height_layer);
	float h21 = surface_bake_read_height(cell + ivec2(2, 1), height_layer);
	float h12 = surface_bake_read_height(cell + ivec2(1, 2), height_layer);
	float dx = max(source_grid ? job.policy.w : abs(job.page.x), 1e-5);
	float dz = max(source_grid ? job.policy.w : abs(job.page.y), 1e-5);
	vec3 normal_bottom_left = surface_bake_normal(h00, h10, h01, dx, dz);
	vec3 normal_bottom_right = surface_bake_normal(h10, h20, h11, dx, dz);
	vec3 normal_top_left = surface_bake_normal(h01, h11, h02, dx, dz);
	vec3 normal_top_right = surface_bake_normal(h11, h21, h12, dx, dz);
	vec3 normal_ws = normalize(
			normal_bottom_left * ((1.0 - cell_local.x) * (1.0 - cell_local.y)) +
			normal_bottom_right * (cell_local.x * (1.0 - cell_local.y)) +
			normal_top_left * ((1.0 - cell_local.x) * cell_local.y) +
			normal_top_right * (cell_local.x * cell_local.y));
	float height = mix(mix(h00, h10, cell_local.x), mix(h01, h11, cell_local.x), cell_local.y);
	// The vertex the material is evaluated at is the world position the tap above named, which for a
	// ring job is reached through the level's grid rather than through `world_rect`: the whole of what
	// the evaluation (the texture uv, the detile, the macro noise, the triplanar axis) sees is this
	// point, so a stored rect whose vertex ignored the ring would evaluate the right payload at the
	// wrong world position.
	vec3 vertex = vec3(world_xz.x, height, world_xz.y);
	vec3 base_ddx = vec3(job.page.x, 0.0, 0.0);
	vec3 base_ddy = vec3(0.0, 0.0, job.page.y);

	vec2 surface_local = cell_local;
	bool is_lower_left = surface_local.x > surface_local.y;
	uint p0 = packed_bottom_left;
	uint p1 = is_lower_left ? packed_bottom_right : packed_top_left;
	uint p2 = packed_top_right;
	float w0;
	float w1;
	float w2;
	if (is_lower_left) {
		w0 = 1.0 - surface_local.x;
		w1 = surface_local.x - surface_local.y;
		w2 = surface_local.y;
	} else {
		w0 = 1.0 - surface_local.y;
		w1 = surface_local.y - surface_local.x;
		w2 = surface_local.x;
	}

	float residual_selector = idweight_stochastic_coverage01_with_salt(vertex, 0x68bc21ebu);
	uvec3 material_ids;
	vec3 material_weights;
	uint material_count;

	float triplanar_factor = idweight_get_triplanar_factor(normal_ws);
	vec3 triplanar_weights = idweight_get_triplanar_weights(normal_ws);
	uint projection_axis = 1u;
	if (triplanar_factor > 0.0) {
		vec3 projection_weights = mix(vec3(0.0, 1.0, 0.0), triplanar_weights, triplanar_factor);
		projection_axis = idweight_select_stochastic_coverage_axis(vertex, projection_weights);
	}

	float slope_distance_blend = clamp(job.policy.x, 0.0, 1.0);
	IdWeightContributions pair_values = IdWeightContributions(
			0u, 0u, 0u, 0u, 0u, 0u, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0u);
	float overlay_weight = 0.0;
	surface_bake_add_pair_vertex(p0, w0, packed_bottom_left, packed_bottom_right,
			packed_top_left, packed_top_right, surface_local, slope_distance_blend,
			projection_axis, normal_ws, base_ddx, base_ddy, vertex, pair_values, overlay_weight);
	surface_bake_add_pair_vertex(p1, w1, packed_bottom_left, packed_bottom_right,
			packed_top_left, packed_top_right, surface_local, slope_distance_blend,
			projection_axis, normal_ws, base_ddx, base_ddy, vertex, pair_values, overlay_weight);
	surface_bake_add_pair_vertex(p2, w2, packed_bottom_left, packed_bottom_right,
			packed_top_left, packed_top_right, surface_local, slope_distance_blend,
			projection_axis, normal_ws, base_ddx, base_ddy, vertex, pair_values, overlay_weight);
	idweight_select_budgeted_3(pair_values, residual_selector, material_ids, material_weights, material_count);

	SurfaceBakeMaterial material = SurfaceBakeMaterial(vec4(0.0), vec4(0.0), 0.0, 0.0, 0.0, 0.0);
	vec3 blended_normal_ws = vec3(0.0);
	for (int layer = 0; layer < IDWEIGHT_MAX_LAYERS; layer++) {
		if (uint(layer) >= material_count) {
			break;
		}
		surface_bake_accumulate_layer(material_ids[layer], material_weights[layer], base_ddx,
				base_ddy, projection_axis, normal_ws, vertex, material, blended_normal_ws);
	}
	if (material.total_weight <= 1e-8) {
		surface_bake_invalidate(output_coord);
		return;
	}

	float weight_inv = 1.0 / material.total_weight;
	material.albedo_height *= weight_inv;
	material.normal_roughness *= weight_inv;
	material.normal_map_depth *= weight_inv;
	material.ao *= weight_inv;
	material.ao_affect *= weight_inv;
	vec3 output_normal = normalize(blended_normal_ws + vec3(0.0, 0.0001, 0.0));
	imageStore(bake_output_albedo, output_coord, material.albedo_height);
	imageStore(bake_output_normal, output_coord, vec4(output_normal, material.normal_roughness.a));
	imageStore(bake_output_params, output_coord,
			vec4(material.normal_map_depth, material.ao, material.ao_affect, 1.0));
}
)"
