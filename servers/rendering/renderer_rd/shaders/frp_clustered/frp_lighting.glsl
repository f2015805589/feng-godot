#[vertex]

// CLV transfer layout 5: hardware interpolation of HDR-scaled current relit SH tensors.

#version 450

#VERSION_DEFINES

#if defined(USE_MULTIVIEW)
#extension GL_EXT_multiview : enable
#define ViewIndex gl_ViewIndex
#endif // USE_MULTIVIEW

#ifdef USE_MULTIVIEW
layout(location = 0) out vec3 uv_interp;
#else // USE_MULTIVIEW
layout(location = 0) out vec2 uv_interp;
#endif //USE_MULTIVIEW

void main() {
	vec2 base_arr[3] = vec2[](vec2(-1.0, -1.0), vec2(-1.0, 3.0), vec2(3.0, -1.0));
	gl_Position = vec4(base_arr[gl_VertexIndex], 0.0, 1.0);
	uv_interp.xy = clamp(gl_Position.xy, vec2(0.0, 0.0), vec2(1.0, 1.0)) * 2.0; // saturate(x) * 2.0
#ifdef USE_MULTIVIEW
	uv_interp.z = ViewIndex;
#endif
}

#[fragment]

#version 450

#VERSION_DEFINES

#define SHADER_IS_SRGB false
#define SHADER_SPACE_FAR 0.0

// Enables the G-buffer texture declarations in scene_frp_clustered_inc.glsl.
#define MODE_FRP_LIGHTING

#ifdef USE_MULTIVIEW
#define OUTPUT_IS_MULTIVIEW true
#else
#define OUTPUT_IS_MULTIVIEW false
#endif

// Include order is significant: scene declarations supply shared constants.
/* clang-format off */
#include "../half_inc.glsl"
#include "scene_frp_clustered_inc.glsl"
#include "frp_cloud_inc.glsl"
#ifdef MODE_MAGIC_GI_BAKED_SH
// The layout-15 baked-SH mode is disjoint from the legacy layout-9 PRT path.
#include "frp_magic_gi_baked_sh.glslinc"
#endif
#ifdef MODE_MAGIC_GI_SCREEN_CACHE
// Receiver-cache lighting is a separate, compact specialization; it must not
// pull the full per-pixel CLV traversal into the PBR variant.
#include "frp_magic_gi_screen_cache.glslinc"
#endif
#ifdef MODE_MAGIC_GI_DYNAMIC_SCREEN_CACHE
// Live TransferMatrix reconstruction is computed after the current GBuffer.
// This compact specialization samples only the screen cache plus owner UBO;
// it intentionally excludes the dynamic-volume/CLV query implementation.
#include "frp_magic_gi_dynamic_screen_cache.glslinc"
#endif
#ifdef MODE_MAGIC_GI_DYNAMIC_VOLUME
// Live free-space TransferMatrix tensor sampling is a small, independent mode.
// It must remain disjoint from the surface-chart and legacy baked-SH helpers.
// DYNAMIC_VOLUME_CLIPMAP_ABI4_CAMERA_CENTERED_16_CELLS_THREE_LODS_20261023
// DYNAMIC_VOLUME_VALID_COVERAGE_WITH_ZERO_VISIBLE_RADIANCE_20261023
// DYNAMIC_VOLUME_GEOMETRIC_RECEIVER_HEMISPHERE_20261023
// DYNAMIC_VOLUME_HEMISPHERE_DOES_NOT_SHRINK_SPATIAL_COVERAGE_20261023
// DYNAMIC_VOLUME_NORMALIZED_SUPPORT_FULL_SKY_OWNERSHIP_20261023
#include "frp_magic_gi_dynamic_volume.glslinc"
// Dynamic-volume real-moment no-side QA revision 20261023-6.
// Dynamic-volume QA revision 6: isolate per-corner receiver-moment visibility.
#endif
#ifdef MODE_MAGIC_GI_CLV
// Compile the certified native PRT CLV sampler into this deferred lighting variant.
// Keep sampler construction at fetch sites for the separate image/sampler layout.
#include "frp_magic_gi_clv.glslinc"
#ifdef MODE_MAGIC_GI_CLV_GENERAL_QUEUE
// This optional single-view/single-sample variant reuses the add-on's exact
// general CLV and baked visibility source through repo-relative build includes.
#include "frp_magic_gi_general.glslinc"
#endif
#endif

#ifndef MODE_RENDER_DEPTH
#define ATMO_PARAMS implementation_data.atmosphere_parameters
#define ATMO_OPTICAL sampler2D(atmosphere_optical_texture, SAMPLER_LINEAR_CLAMP)
#define ATMO_MULTIPLE sampler2D(atmosphere_multiple_texture, SAMPLER_LINEAR_CLAMP)
#include "atmosphere_inc.glsl"
#undef ATMO_PARAMS
#undef ATMO_OPTICAL
#undef ATMO_MULTIPLE
vec3 frp_atmospheric_light_factor(uint index, vec3 camera_to_receiver_m) {
	if (implementation_data.atmosphere_enabled == 0u) {
		return vec3(1.0);
	}
	if (index == implementation_data.atmosphere_light_index0) {
		return frp_atmo_surface_transmittance(camera_to_receiver_m, 0);
	}
	if (index == implementation_data.atmosphere_light_index1) {
		return frp_atmo_surface_transmittance(camera_to_receiver_m, 1);
	}
	return vec3(1.0);
}
#endif

// Keep clustered light lookup/shadows from the shared renderer include, but
// route every resolved light through FRP's own ShadingModelID/BxDF dispatcher.
void frp_light_compute(hvec3 N, hvec3 L, hvec3 V, half A, vec3 light_color, bool is_directional, half attenuation, hvec3 f0, half roughness, half metallic, half specular_amount, hvec3 albedo, inout half alpha, vec2 screen_uv, hvec3 energy_compensation, inout hvec3 diffuse_light, inout hvec3 specular_light);
#define FRP_LIGHT_COMPUTE frp_light_compute
#define FRP_LIGHT_COLOR(color) vec3(color)
#define FRP_AREA_LIGHT_COLOR(color) hvec3(vec3(color) * implementation_data.pre_exposure)
#include "../scene_forward_lights_inc.glsl"
#include "frp_shading_models_inc.glsl"
/* clang-format on */
// GI is evaluated before lighting and sampled from ambient/reflection buffers.

// Cluster helpers (defined in the scene shader inside a MODE_RENDER_DEPTH guard, so redefined here).
void cluster_get_item_range(uint p_offset, out uint item_min, out uint item_max, out uint item_from, out uint item_to) {
	uint item_min_max = cluster_buffer.data[p_offset];
	item_min = item_min_max & 0xFFFFu;
	item_max = item_min_max >> 16;

	item_from = item_min >> 5;
	item_to = (item_max == 0) ? 0 : ((item_max - 1) >> 5) + 1; //side effect of how it is stored, as item_max 0 means no elements
}

uint cluster_get_range_clip_mask(uint i, uint z_min, uint z_max) {
	int local_min = clamp(int(z_min) - int(i) * 32, 0, 31);
	int mask_width = min(int(z_max) - int(z_min), 32 - local_min);
	return bitfieldInsert(uint(0), uint(0xFFFFFFFF), local_min, mask_width);
}

#ifdef USE_MULTIVIEW
#extension GL_EXT_multiview : enable
#define ViewIndex gl_ViewIndex
#else
#define ViewIndex 0
#endif

#ifdef USE_MULTIVIEW
layout(location = 0) in vec3 uv_interp;
#else // USE_MULTIVIEW
layout(location = 0) in vec2 uv_interp;
#endif //USE_MULTIVIEW

#define scene_data scene_data_block.data

#ifdef USE_MULTIVIEW
#define projection_matrix scene_data.projection_matrix_view[ViewIndex]
#define inv_projection_matrix scene_data.inv_projection_matrix_view[ViewIndex]
#else
#define projection_matrix scene_data.projection_matrix
#define inv_projection_matrix scene_data.inv_projection_matrix
#endif

layout(location = 0) out vec4 frag_color;

#ifdef MODE_SEPARATE_SPECULAR
layout(location = 1) out vec4 specular_color;
#define FRP_HAS_SEPARATE_SPECULAR 1
#else
#define FRP_HAS_SEPARATE_SPECULAR 0
#endif

#ifdef MODE_SKY_LIGHT_DIFFUSE
#define FRP_HAS_SKY_LIGHT_DIFFUSE 1
#else
#define FRP_HAS_SKY_LIGHT_DIFFUSE 0
#endif

#ifdef MODE_INDIRECT_SPECULAR
#define FRP_HAS_INDIRECT_SPECULAR 1
#else
#define FRP_HAS_INDIRECT_SPECULAR 0
#endif

#ifdef MODE_SKY_LIGHT_DIFFUSE
#ifdef MODE_SEPARATE_SPECULAR
layout(location = 2) out vec4 sky_light_diffuse_color;
#ifdef MODE_INDIRECT_SPECULAR
layout(location = 3) out vec4 indirect_specular_color;
#endif
#else
layout(location = 1) out vec4 sky_light_diffuse_color;
#ifdef MODE_INDIRECT_SPECULAR
layout(location = 2) out vec4 indirect_specular_color;
#endif
#endif

#elif defined(MODE_INDIRECT_SPECULAR)
#ifdef MODE_SEPARATE_SPECULAR
layout(location = 2) out vec4 indirect_specular_color;
#else
layout(location = 1) out vec4 indirect_specular_color;
#endif
#endif

#ifdef MODE_REFLECTION_COMPONENTS
// Native combined indirect specular is Sky-only; alpha remains zero for additive replacement.
// This matching sidecar stores the unweighted provider/environment term in RGB and
// whether that term is a valid source in alpha.
layout(location = 1 + FRP_HAS_SEPARATE_SPECULAR + FRP_HAS_SKY_LIGHT_DIFFUSE + FRP_HAS_INDIRECT_SPECULAR) out vec4 sky_light_specular_color;
#endif

// Per-pixel BxDF state selected from ORM alpha. The shared clustered traversal
// calls frp_light_compute() for directional, omni and spot lights.
uint frp_active_shading_model_id;
FRPBRDFData frp_active_brdf;

void frp_light_compute(hvec3 N, hvec3 L, hvec3 V, half A, vec3 light_color, bool is_directional, half attenuation, hvec3 f0, half roughness, half metallic, half specular_amount, hvec3 albedo, inout half alpha, vec2 screen_uv, hvec3 energy_compensation, inout hvec3 diffuse_light, inout hvec3 specular_light) {
	FRPDirectLighting lighting = frp_integrate_bxdf(frp_active_shading_model_id, frp_active_brdf, vec3(N), vec3(V), vec3(L), float(A), vec3(light_color) * implementation_data.pre_exposure, float(attenuation), float(specular_amount));
	diffuse_light += hvec3(lighting.diffuse + lighting.transmission);
	specular_light += hvec3(lighting.specular);
}

void main() {
	vec2 screen_uv = uv_interp.xy;

	// Reconstruct the view-space position from the depth buffer.
#ifdef USE_MULTIVIEW
	float depth = textureLod(sampler2DArray(depth_buffer, SAMPLER_NEAREST_CLAMP), vec3(screen_uv, ViewIndex), 0.0).r;
#else
	float depth = textureLod(sampler2D(depth_buffer, SAMPLER_NEAREST_CLAMP), screen_uv, 0.0).r;
#endif
	if (depth <= 0.0) {
		// Sky pixels are drawn by the sky pass afterwards.
		discard;
	}

	vec4 ndc = vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_pos = inv_projection_matrix * ndc;
	view_pos /= view_pos.w;
	vec3 vertex = view_pos.xyz;
	bool cloud_sun0_active = implementation_data.cloud_sun_light_indices_flags.z > 0.5 && implementation_data.cloud_projection_parameters[27].x > 0.5;
	bool cloud_sun1_active = implementation_data.cloud_sun_light_indices_flags.w > 0.5 && implementation_data.cloud_projection_parameters[27].y > 0.5;
	bool cloud_sky_ao_active = (implementation_data.sky_lighting_enabled != 0u || implementation_data.sky_lighting_pad0 != 0u) && implementation_data.cloud_projection_parameters[27].z > 0.5;
	vec3 cloud_world_position = vec3(0.0);
	if (cloud_sun0_active || cloud_sun1_active || cloud_sky_ao_active) {
		cloud_world_position = frp_cloud_world_position(vertex, scene_data);
	}

	vec3 view = projection_matrix[3][3] == 1.0 ? vec3(0.0, 0.0, 1.0) : -normalize(vertex);

	// Read the G-buffer.
#ifdef USE_MULTIVIEW
	vec4 normal_roughness = textureLod(sampler2DArray(normal_roughness_buffer, SAMPLER_NEAREST_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
#else
	vec4 normal_roughness = textureLod(sampler2D(normal_roughness_buffer, SAMPLER_NEAREST_CLAMP), screen_uv, 0.0);
#endif
	// The normal is the only thing the lighting pass needs from this target.
	// Roughness is deliberately read from orm.g; normal_roughness.a is reserved
	// for the dynamic/static instance marker and is not a roughness channel.
	vec3 normal = normalize(normal_roughness.xyz * 2.0 - 1.0);

#ifdef USE_MULTIVIEW
	vec4 albedo_alpha = textureLod(sampler2DArray(gbuffer_albedo_buffer, SAMPLER_NEAREST_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
#else
	vec4 albedo_alpha = textureLod(sampler2D(gbuffer_albedo_buffer, SAMPLER_NEAREST_CLAMP), screen_uv, 0.0);
#endif
	vec3 albedo = albedo_alpha.rgb;
	float alpha = albedo_alpha.a;

#ifdef USE_MULTIVIEW
	vec4 orm = textureLod(sampler2DArray(gbuffer_orm_buffer, SAMPLER_NEAREST_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
#else
	vec4 orm = textureLod(sampler2D(gbuffer_orm_buffer, SAMPLER_NEAREST_CLAMP), screen_uv, 0.0);
#endif
	float ao = orm.r;
	float roughness = orm.g;
	float metallic = orm.b;
	float sss_strength = 0.0;

#ifdef USE_MULTIVIEW
	vec4 emission_alpha = textureLod(sampler2DArray(gbuffer_emission_buffer, SAMPLER_NEAREST_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
#else
	vec4 emission_alpha = textureLod(sampler2D(gbuffer_emission_buffer, SAMPLER_NEAREST_CLAMP), screen_uv, 0.0);
#endif
	vec3 emission = emission_alpha.rgb;
	// ORM alpha packs ShadingModelID in the low nibble and AO_LIGHT_AFFECT in
	// the high nibble; the shared decoder keeps this aligned with the G-buffer pass.
	uint shading_model_id = frp_normalize_shading_model(frp_decode_shading_model(orm.a));
	float ao_light_affect = frp_decode_ao_light_affect(orm.a);
	// The G-buffer carries the material specular in the emission target's alpha
	// (see the MODE_RENDER_GBUFFER branch in scene_frp_clustered.glsl). Feeding
	// it to F0() replaces the hardcoded dielectric 0.5, matching Unreal's
	// GBufferB, which keeps specular as its own channel.
	float material_specular = emission_alpha.a;

	// Cluster position for light lookups.
	uvec2 cluster_pos = uvec2(gl_FragCoord.xy) >> implementation_data.cluster_shift;
	uint cluster_offset = (implementation_data.cluster_width * cluster_pos.y + cluster_pos.x) * (implementation_data.max_cluster_element_count_div_32 + 32);
	uint cluster_z = uint(clamp((-vertex.z / scene_data.z_far) * 32.0, 0.0, 31.0));

	vec3 vertex_ddx = dFdx(vertex);
	vec3 vertex_ddy = dFdy(vertex);
#if defined(MODE_MAGIC_GI_BAKED_SH) || defined(MODE_MAGIC_GI_CLV) || defined(MODE_MAGIC_GI_SCREEN_CACHE) || defined(MODE_MAGIC_GI_DYNAMIC_VOLUME) || defined(MODE_MAGIC_GI_DYNAMIC_SCREEN_CACHE)
	// Evaluate position derivatives before AO/owner-dependent lighting branches.
	// CLV domain certificates are receiver-geometry contracts, so the native
	// sampler always needs this geometric normal. Baked-SH keeps the derivative
	// work limited to its explicit QA offset modes.
	vec3 magic_gi_geometric_normal_world = vec3(0.0);
	#ifdef MODE_MAGIC_GI_SCREEN_CACHE
	vec4 magic_gi_early_owner_control = frp_magic_gi_screen_owner.control;
	#elif defined(MODE_MAGIC_GI_DYNAMIC_SCREEN_CACHE)
	vec4 magic_gi_early_owner_control = frp_magic_gi_dynamic_screen_owner.control;
	#elif defined(MODE_MAGIC_GI_CLV)
	vec4 magic_gi_early_owner_control = frp_magic_gi_clv_owner_control(ViewIndex);
	#elif defined(MODE_MAGIC_GI_DYNAMIC_VOLUME)
	vec4 magic_gi_early_owner_control = frp_magic_gi_dynamic_volume_owner_control(ViewIndex);
	#else
	vec4 magic_gi_early_owner_control = frp_magic_gi_baked_sh_owner_control(ViewIndex);
	#endif
	bool magic_gi_need_geometric_normal =
			abs(magic_gi_early_owner_control.w - 1.0) < 0.01 ||
			abs(magic_gi_early_owner_control.w - 2.0) < 0.01;
#ifdef MODE_MAGIC_GI_CLV
	// QA mode 4 bypasses all sampling and is the matched zero-contribution
	// baseline, so do not charge it for the receiver-normal derivatives.
	magic_gi_need_geometric_normal = abs(magic_gi_early_owner_control.w - 4.0) >= 0.01;
#endif
#ifdef MODE_MAGIC_GI_SCREEN_CACHE
	// The compact lighting specialization uses geometry normals to reject cache
	// taps across depth/normal discontinuities. It still has no CLV descriptors.
	magic_gi_need_geometric_normal = true;
#endif
#ifdef MODE_MAGIC_GI_DYNAMIC_SCREEN_CACHE
	// The screen result was resolved with geometric receiver normals. Keep a
	// geometric normal here for owner-domain checks and bilateral upsampling.
	magic_gi_need_geometric_normal = true;
#endif
#ifdef MODE_MAGIC_GI_DYNAMIC_VOLUME
	// The free-space probe visibility gate uses the receiver's geometric
	// hemisphere. Keep normal maps for SH response evaluation only.
	#ifdef MAGIC_GI_PREINTERPOLATED_ONLY
	// Geometry-conditioned linear operators were prepared by the baker.
	magic_gi_need_geometric_normal = false;
	#else
	magic_gi_need_geometric_normal = abs(magic_gi_early_owner_control.w - 4.0) >= 0.01;
	#endif
#endif
	if (magic_gi_need_geometric_normal) {
		vec3 magic_gi_view_to_camera_world = transpose(mat3(scene_data.inv_view_matrix)) * view;
		float magic_gi_view_to_camera_length_squared = dot(magic_gi_view_to_camera_world,
				magic_gi_view_to_camera_world);
		if (magic_gi_view_to_camera_length_squared > 1e-12
				&& !isnan(magic_gi_view_to_camera_length_squared)
				&& !isinf(magic_gi_view_to_camera_length_squared)) {
			magic_gi_view_to_camera_world *= inversesqrt(magic_gi_view_to_camera_length_squared);
		} else {
			magic_gi_view_to_camera_world = vec3(0.0);
		}
		vec3 world_ddx = transpose(mat3(scene_data.inv_view_matrix)) * vertex_ddx;
		vec3 world_ddy = transpose(mat3(scene_data.inv_view_matrix)) * vertex_ddy;
		vec3 derivative_normal = cross(world_ddx, world_ddy);
		float derivative_length_squared = dot(derivative_normal, derivative_normal);
		if (derivative_length_squared > 1e-12 && !isnan(derivative_length_squared) &&
				!isinf(derivative_length_squared) && !any(isnan(derivative_normal)) &&
				!any(isinf(derivative_normal))) {
			magic_gi_geometric_normal_world = derivative_normal * inversesqrt(derivative_length_squared);
			// Screen-space derivative order can reverse the sign. Orient the geometric
			// receiver normal toward the visible front face, independent of normal maps.
			if (dot(magic_gi_geometric_normal_world, magic_gi_view_to_camera_world) < 0.0) {
				magic_gi_geometric_normal_world = -magic_gi_geometric_normal_world;
			}
		}
	}
#endif

	// Energy conservation.
	FRPBRDFData brdf = frp_make_brdf_data(albedo, alpha, ao, roughness, metallic, material_specular, sss_strength, emission, normal, view);
	frp_active_shading_model_id = shading_model_id;
	frp_active_brdf = brdf;
	vec3 f0 = brdf.f0;
	vec3 energy_compensation = brdf.energy_compensation;

	vec3 direct_specular_light = vec3(0.0, 0.0, 0.0);
	vec3 indirect_specular_light = vec3(0.0, 0.0, 0.0);
	vec3 diffuse_light = vec3(0.0, 0.0, 0.0);
	vec3 ambient_light = vec3(0.0, 0.0, 0.0);
	vec3 global_sky_light_diffuse = vec3(0.0);
	vec3 global_sky_light_specular = vec3(0.0);
	bool global_sky_specular_valid = false;
#if !defined(MODE_RENDER_DEPTH)
	bool use_frp_sky_lighting = implementation_data.sky_lighting_enabled != 0u;
	mat3 frp_radiance_inverse_xform = use_frp_sky_lighting ? implementation_data.sky_lighting_inverse_xform : scene_data.radiance_inverse_xform;
	float frp_radiance_pixel_size = use_frp_sky_lighting ? implementation_data.sky_lighting_parameters.z : scene_data_block.data.radiance_pixel_size;
	float frp_radiance_border_size = use_frp_sky_lighting ? implementation_data.sky_lighting_parameters.w : scene_data_block.data.radiance_border_size;
	float frp_ibl_exposure_normalization = use_frp_sky_lighting ? implementation_data.sky_lighting_parameters.y : scene_data.IBL_exposure_normalization;
	float frp_ibl_energy = use_frp_sky_lighting ? implementation_data.sky_lighting_parameters.x : scene_data.ambient_light_color_energy.a;
#endif

	// Native deferred lighting resolves ambient/SkyLight diffuse and Sky-only specular.
	// FRP library GI, AO and reflection candidates consume their scheduled inputs.
	if (bool(scene_data.flags & SCENE_DATA_FLAGS_USE_AMBIENT_LIGHT)) {
		ambient_light = scene_data.ambient_light_color_energy.rgb;

		if (bool(scene_data.flags & SCENE_DATA_FLAGS_USE_REFLECTION_CUBEMAP)) {
			vec3 ref_vec = reflect(-view, normal);
			ref_vec = mix(ref_vec, normal, roughness * roughness);

			float horizon = min(1.0 + dot(ref_vec, normal), 1.0);
			ref_vec = frp_radiance_inverse_xform * ref_vec;

			float roughness_lod = sqrt(roughness) * MAX_ROUGHNESS_LOD;
#ifdef USE_RADIANCE_OCTMAP_ARRAY
			float array_roughness_lod, blend;
			blend = modf(sqrt(roughness) * MAX_ROUGHNESS_LOD, array_roughness_lod);
			float ref_lod = vec3_to_oct_lod(dFdx(ref_vec), dFdy(ref_vec), frp_radiance_pixel_size);
			vec2 ref_uv = vec3_to_oct_with_border(ref_vec, vec2(frp_radiance_border_size, 1.0 - frp_radiance_border_size * 2.0));
			vec3 indirect_sample_a = textureLod(sampler2DArray(radiance_octmap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec3(ref_uv, array_roughness_lod), ref_lod).rgb;
			vec3 indirect_sample_b = textureLod(sampler2DArray(radiance_octmap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec3(ref_uv, array_roughness_lod + 1.0), ref_lod).rgb;
			indirect_specular_light = mix(indirect_sample_a, indirect_sample_b, blend);
#else
			vec2 ref_uv = vec3_to_oct_with_border(ref_vec, vec2(frp_radiance_border_size, 1.0 - frp_radiance_border_size * 2.0));
			indirect_specular_light = textureLod(sampler2D(radiance_octmap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), ref_uv, roughness_lod).rgb;
#endif

			indirect_specular_light *= frp_ibl_exposure_normalization;
			indirect_specular_light *= horizon * horizon;
			indirect_specular_light *= frp_ibl_energy;
		}

		if (bool(scene_data.flags & SCENE_DATA_FLAGS_USE_AMBIENT_CUBEMAP)) {
			vec3 ambient_dir = frp_radiance_inverse_xform * normal;
#ifdef USE_RADIANCE_OCTMAP_ARRAY
			float ambient_lod = vec3_to_oct_lod(dFdx(ambient_dir), dFdy(ambient_dir), frp_radiance_pixel_size);
			vec2 ambient_uv = vec3_to_oct_with_border(ambient_dir, vec2(frp_radiance_border_size, 1.0 - frp_radiance_border_size * 2.0));
			vec3 cubemap_ambient = textureLod(sampler2DArray(radiance_octmap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec3(ambient_uv, MAX_ROUGHNESS_LOD), ambient_lod).rgb;
#else
			vec2 ambient_uv = vec3_to_oct_with_border(ambient_dir, vec2(frp_radiance_border_size, 1.0 - frp_radiance_border_size * 2.0));
			vec3 cubemap_ambient = textureLod(sampler2D(radiance_octmap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), ambient_uv, MAX_ROUGHNESS_LOD).rgb;
#endif
			if (use_frp_sky_lighting) {
				ambient_light = cubemap_ambient * frp_ibl_exposure_normalization * frp_ibl_energy;
			} else {
				cubemap_ambient *= frp_ibl_exposure_normalization;
				ambient_light = mix(ambient_light, cubemap_ambient * frp_ibl_energy, scene_data.ambient_color_sky_mix);
			}
		}
		if (cloud_sky_ao_active) {
			// The cloud AO filter has already applied its configured strength.
			// Attenuate only the FengSkyLight provider term.
			ambient_light *= frp_cloud_provider_ao_visibility(cloud_world_position);
		}

		// The native mirror baseline is SkyLight-only. FRP reflection candidates,
		// including FengReflectProbe, are resolved by scheduled addon passes.
		global_sky_light_specular = indirect_specular_light;
		global_sky_specular_valid = bool(scene_data.flags & SCENE_DATA_FLAGS_USE_REFLECTION_CUBEMAP) &&
				frp_normalize_shading_model(shading_model_id) != FRP_SHADING_MODEL_UNLIT;
		if (use_frp_sky_lighting && frp_normalize_shading_model(shading_model_id) != FRP_SHADING_MODEL_UNLIT) {
			global_sky_light_diffuse = ambient_light;
		}

		// Finalize ambient.
		float frp_diffuse_ao = 1.0;
#ifdef USE_MULTIVIEW
		frp_diffuse_ao = textureLod(sampler2DArray(frp_diffuse_ambient_occlusion_texture, SAMPLER_LINEAR_CLAMP), vec3(screen_uv, ViewIndex), 0.0).r;
#else
		frp_diffuse_ao = textureLod(sampler2D(frp_diffuse_ambient_occlusion_texture, SAMPLER_LINEAR_CLAMP), screen_uv, 0.0).r;
#endif
		frp_diffuse_ao = (isnan(frp_diffuse_ao) || isinf(frp_diffuse_ao)) ? 1.0 : clamp(frp_diffuse_ao, 0.0, 1.0);
		ambient_light *= ao * frp_diffuse_ao;
		ambient_light *= albedo.rgb;
		global_sky_light_diffuse *= ao * frp_diffuse_ao;
		global_sky_light_diffuse *= albedo.rgb;
		// Certified PRT CLV cells are sampled as part of deferred diffuse lighting.
		// The addon compute pass after lighting remains responsible only for complete
		// fallback work where the CLV certificate rejects this receiver.
#ifdef MODE_MAGIC_GI_CLV
		if (frp_normalize_shading_model(shading_model_id) != FRP_SHADING_MODEL_UNLIT) {
			vec3 magic_gi_world = frp_cloud_world_position(vertex, scene_data);
			// SceneData packs inverse view as transposed 3x4 rows. Restore its
			// rotation just as frp_cloud_world_position does for positions.
			bool magic_gi_consumer_bypassed =
					abs(magic_gi_early_owner_control.w - 4.0) < 0.01;
			vec3 magic_gi_normal = magic_gi_consumer_bypassed ? vec3(0.0)
					: normalize(transpose(mat3(scene_data.inv_view_matrix)) * normal);
			vec3 magic_gi_geometric_normal = magic_gi_geometric_normal_world;
			float magic_gi_geometric_length_squared = dot(magic_gi_geometric_normal,
					magic_gi_geometric_normal);
			if (magic_gi_geometric_length_squared > 1e-12
					&& !isnan(magic_gi_geometric_length_squared)
					&& !isinf(magic_gi_geometric_length_squared)) {
				magic_gi_geometric_normal *= inversesqrt(magic_gi_geometric_length_squared);
			}
			bool magic_gi_native_hit = frp_magic_gi_apply_certified(magic_gi_world,
					magic_gi_geometric_normal, magic_gi_normal, albedo.rgb,
					ao, frp_diffuse_ao, ViewIndex, ambient_light,
					global_sky_light_diffuse);
#ifdef MODE_MAGIC_GI_CLV_GENERAL_QUEUE
			if (!magic_gi_native_hit) {
				frp_magic_gi_apply_general(magic_gi_world, vertex, depth, magic_gi_normal,
						albedo.rgb, ao, frp_diffuse_ao, screen_uv, ViewIndex,
						ambient_light, global_sky_light_diffuse);
			}
#endif
		}
#endif
#ifdef MODE_MAGIC_GI_BAKED_SH
		if (frp_normalize_shading_model(shading_model_id) != FRP_SHADING_MODEL_UNLIT) {
			vec3 magic_gi_world = frp_cloud_world_position(vertex, scene_data);
			// Using the packed rows as columns rotates the normal a second time
			// when the camera turns, selecting the wrong side of boundary tensors.
			vec3 magic_gi_normal_world = normalize(transpose(mat3(scene_data.inv_view_matrix)) * normal);
			frp_magic_gi_apply_baked_sh(magic_gi_world, magic_gi_normal_world,
					albedo.rgb, magic_gi_geometric_normal_world, ao,
					frp_diffuse_ao, ViewIndex, ambient_light,
					global_sky_light_diffuse);
		}
#endif

#ifdef MODE_MAGIC_GI_SCREEN_CACHE
		if (frp_normalize_shading_model(shading_model_id) != FRP_SHADING_MODEL_UNLIT) {
			vec3 magic_gi_screen_world = frp_cloud_world_position(vertex, scene_data);
			frp_magic_gi_screen_sample(magic_gi_screen_world, screen_uv, gl_FragCoord.xy, -vertex.z,
					magic_gi_geometric_normal_world, albedo.rgb, ao, frp_diffuse_ao,
					ViewIndex, ambient_light, global_sky_light_diffuse);
		}
#endif

#ifdef MODE_MAGIC_GI_DYNAMIC_VOLUME
		if (frp_normalize_shading_model(shading_model_id) != FRP_SHADING_MODEL_UNLIT) {
			vec3 magic_gi_world = frp_cloud_world_position(vertex, scene_data);
			vec3 magic_gi_normal_world = normalize(transpose(mat3(scene_data.inv_view_matrix)) * normal);
			frp_magic_gi_dynamic_volume_apply(magic_gi_world,
					magic_gi_geometric_normal_world, magic_gi_normal_world,
					albedo.rgb, ao, frp_diffuse_ao, ViewIndex, ambient_light,
					global_sky_light_diffuse);
		}
#endif

#ifdef MODE_MAGIC_GI_DYNAMIC_SCREEN_CACHE
		if (frp_normalize_shading_model(shading_model_id) != FRP_SHADING_MODEL_UNLIT) {
			vec3 magic_gi_world = frp_cloud_world_position(vertex, scene_data);
			frp_magic_gi_dynamic_screen_apply(magic_gi_world, gl_FragCoord.xy,
					-vertex.z, magic_gi_geometric_normal_world,
					albedo.rgb, ao, frp_diffuse_ao, ambient_light,
					global_sky_light_diffuse);
		}
#endif

		// Apply energy compensation and DFG to the indirect specular. The BxDF
		// constructor computes the same DFG sample for energy compensation, but it
		// intentionally stores only the derived BRDF data, so sample it here too.
		float NdotV = clamp(dot(normal, view), 0.0001, 1.0);
		vec2 env_brdf = prefiltered_dfg(roughness, NdotV).xy;
		float f90 = clamp(50.0 * f0.g, metallic, 1.0);
		vec3 indirect_specular_brdf = energy_compensation * ((f90 - f0) * env_brdf.x + f0 * env_brdf.y);
		indirect_specular_light *= indirect_specular_brdf;
		global_sky_light_specular *= indirect_specular_brdf;
	}

	// Direct lighting.
	{
		// Directional light.
		uint shadow0 = 0;
		uint shadow1 = 0;

		for (uint i = 0; i < 8; i++) {
			if (i >= scene_data.directional_light_count) {
				break;
			}

			float shadow = 1.0;

			if (directional_lights.data[i].shadow_opacity > 0.001) {
				shadow = sample_directional_csm_and_object_shadow(directional_shadow_atlas, directional_lights.data[i], vertex, normal, scene_data.directional_shadow_pixel_size, scene_data.taa_frame_count);
				shadow = mix(shadow, 1.0, smoothstep(directional_lights.data[i].fade_from, directional_lights.data[i].fade_to, vertex.z));
			}

			shadow = mix(1.0, shadow, directional_lights.data[i].shadow_opacity);
			shadow *= frp_cloud_directional_shadow_visibility(cloud_world_position, i);

			float size_A = sc_use_directional_soft_shadows() ? directional_lights.data[i].size : 0.0;

			frp_light_compute(normal, directional_lights.data[i].direction, view, size_A,
					directional_lights.data[i].color * directional_lights.data[i].energy * frp_atmospheric_light_factor(i, mat3(scene_data.inv_view_matrix) * vertex),
					true, shadow, f0, roughness, metallic, directional_lights.data[i].specular, albedo, alpha, screen_uv, energy_compensation,
					diffuse_light,
					direct_specular_light);
		}

		// Omni lights.
		{
			uint cluster_omni_offset = cluster_offset;

			uint item_min;
			uint item_max;
			uint item_from;
			uint item_to;

			cluster_get_item_range(cluster_omni_offset + implementation_data.max_cluster_element_count_div_32 + cluster_z, item_min, item_max, item_from, item_to);

			item_from = subgroupBroadcastFirst(subgroupMin(item_from));
			item_to = subgroupBroadcastFirst(subgroupMax(item_to));

			for (uint i = item_from; i < item_to; i++) {
				uint mask = cluster_buffer.data[cluster_omni_offset + i];
				mask &= cluster_get_range_clip_mask(i, item_min, item_max);

				uint merged_mask = subgroupBroadcastFirst(subgroupOr(mask));
				while (merged_mask != 0) {
					uint bit = findMSB(merged_mask);
					merged_mask &= ~(1u << bit);

					if (((1u << bit) & mask) == 0) { //do not process if not originally here
						continue;
					}

					uint light_index = 32 * i + bit;

					light_process_omni(light_index, vertex, view, normal, vertex_ddx, vertex_ddy, f0, roughness, metallic, scene_data.taa_frame_count, albedo, alpha, screen_uv, energy_compensation,
							diffuse_light, direct_specular_light);
				}
			}
		}

		// Spot lights.
		{
			uint cluster_spot_offset = cluster_offset + implementation_data.cluster_type_size;

			uint item_min;
			uint item_max;
			uint item_from;
			uint item_to;

			cluster_get_item_range(cluster_spot_offset + implementation_data.max_cluster_element_count_div_32 + cluster_z, item_min, item_max, item_from, item_to);

			item_from = subgroupBroadcastFirst(subgroupMin(item_from));
			item_to = subgroupBroadcastFirst(subgroupMax(item_to));

			for (uint i = item_from; i < item_to; i++) {
				uint mask = cluster_buffer.data[cluster_spot_offset + i];
				mask &= cluster_get_range_clip_mask(i, item_min, item_max);

				uint merged_mask = subgroupBroadcastFirst(subgroupOr(mask));
				while (merged_mask != 0) {
					uint bit = findMSB(merged_mask);
					merged_mask &= ~(1u << bit);

					if (((1u << bit) & mask) == 0) { //do not process if not originally here
						continue;
					}

					uint light_index = 32 * i + bit;

					light_process_spot(light_index, vertex, view, normal, vertex_ddx, vertex_ddy, f0, roughness, metallic, scene_data.taa_frame_count, albedo, alpha, screen_uv, energy_compensation,
							diffuse_light, direct_specular_light);
				}
			}
		}

		// Area lights.
		if (sc_cluster_has_area_light()) {
			uint cluster_area_offset = cluster_offset + implementation_data.cluster_type_size * 2;

			uint item_min;
			uint item_max;
			uint item_from;
			uint item_to;

			cluster_get_item_range(cluster_area_offset + implementation_data.max_cluster_element_count_div_32 + cluster_z, item_min, item_max, item_from, item_to);

			item_from = subgroupBroadcastFirst(subgroupMin(item_from));
			item_to = subgroupBroadcastFirst(subgroupMax(item_to));

			for (uint i = item_from; i < item_to; i++) {
				uint mask = cluster_buffer.data[cluster_area_offset + i];
				mask &= cluster_get_range_clip_mask(i, item_min, item_max);

				uint merged_mask = subgroupBroadcastFirst(subgroupOr(mask));
				while (merged_mask != 0) {
					uint bit = findMSB(merged_mask);
					merged_mask &= ~(1u << bit);

					if (((1u << bit) & mask) == 0) { //do not process if not originally here
						continue;
					}

					uint light_index = 32 * i + bit;

					light_process_area(light_index, vertex, view, normal, vertex_ddx, vertex_ddy, f0, roughness, metallic, scene_data.taa_frame_count, albedo, alpha, screen_uv, energy_compensation,
							diffuse_light, direct_specular_light);
				}
			}
		}
	}

	// Combine.
	diffuse_light *= albedo;
	float direct_ao = mix(1.0, ao, ao_light_affect);
	diffuse_light *= direct_ao;
	direct_specular_light *= direct_ao;
	diffuse_light *= 1.0 - metallic;
	ambient_light *= 1.0 - metallic;
	global_sky_light_diffuse *= 1.0 - metallic;
	ambient_light *= implementation_data.pre_exposure;
	global_sky_light_diffuse *= implementation_data.pre_exposure;
	indirect_specular_light *= implementation_data.pre_exposure;
	global_sky_light_specular *= implementation_data.pre_exposure;

	vec3 color = frp_compose_bxdf(shading_model_id, brdf, ambient_light, diffuse_light, direct_specular_light, indirect_specular_light);

#ifdef MODE_SEPARATE_SPECULAR
	frag_color = vec4(color - (direct_specular_light + indirect_specular_light), sss_strength);
	specular_color = vec4(direct_specular_light + indirect_specular_light, metallic);
#else
	frag_color = vec4(color, alpha);
#endif

#ifdef MODE_SKY_LIGHT_DIFFUSE
	sky_light_diffuse_color = vec4(global_sky_light_diffuse, 0.0);
#endif
#ifdef MODE_INDIRECT_SPECULAR
	indirect_specular_color = frp_normalize_shading_model(shading_model_id) == FRP_SHADING_MODEL_UNLIT ? vec4(0.0) : vec4(indirect_specular_light, 0.0);
#endif
#ifdef MODE_REFLECTION_COMPONENTS
	sky_light_specular_color = global_sky_specular_valid ? vec4(global_sky_light_specular, 1.0) : vec4(0.0);
#endif
}
