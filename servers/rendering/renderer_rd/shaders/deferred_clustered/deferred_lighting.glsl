#[vertex]

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

// Enables the G-buffer texture declarations in scene_deferred_clustered_inc.glsl.
#define MODE_DEFERRED_LIGHTING

#ifdef USE_MULTIVIEW
#define OUTPUT_IS_MULTIVIEW true
#else
#define OUTPUT_IS_MULTIVIEW false
#endif

/* Include half precision types. */
#include "../half_inc.glsl"

#include "scene_deferred_clustered_inc.glsl"

#include "../scene_data_inc.glsl"
#include "../light_data_inc.glsl"
#include "../cluster_data_inc.glsl"
#include "../decal_data_inc.glsl"
#include "../oct_inc.glsl"

#include "../scene_forward_lights_inc.glsl"
#include "../scene_forward_gi_inc.glsl"

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
#endif

void main() {
	vec2 screen_uv = uv_interp.xy;

	// Reconstruct the view-space position from the depth buffer.
#ifdef USE_MULTIVIEW
	float depth = textureLod(sampler2DArray(depth_buffer, SAMPLER_NEAREST_CLAMP), vec3(screen_uv, ViewIndex), 0.0).r;
#else
	float depth = textureLod(sampler2D(depth_buffer, SAMPLER_NEAREST_CLAMP), screen_uv, 0.0).r;
#endif
	if (depth >= 1.0) {
		// Sky pixels are drawn by the sky pass afterwards.
		discard;
	}

	vec4 ndc = vec4(screen_uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	vec4 view_pos = inv_projection_matrix * ndc;
	view_pos /= view_pos.w;
	vec3 vertex = view_pos.xyz;

	vec3 view = -normalize(vertex);

	// Read the G-buffer.
#ifdef USE_MULTIVIEW
	vec4 normal_roughness = textureLod(sampler2DArray(normal_roughness_buffer, SAMPLER_LINEAR_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
#else
	vec4 normal_roughness = textureLod(sampler2D(normal_roughness_buffer, SAMPLER_LINEAR_CLAMP), screen_uv, 0.0);
#endif
	normal_roughness = normal_roughness_compatibility(normal_roughness);
	vec3 normal = normalize(normal_roughness.xyz * 2.0 - 1.0);
	float roughness = normal_roughness.w;

#ifdef USE_MULTIVIEW
	vec4 albedo_alpha = textureLod(sampler2DArray(gbuffer_albedo_buffer, SAMPLER_LINEAR_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
#else
	vec4 albedo_alpha = textureLod(sampler2D(gbuffer_albedo_buffer, SAMPLER_LINEAR_CLAMP), screen_uv, 0.0);
#endif
	vec3 albedo = albedo_alpha.rgb;
	float alpha = albedo_alpha.a;

#ifdef USE_MULTIVIEW
	vec4 orm = textureLod(sampler2DArray(gbuffer_orm_buffer, SAMPLER_LINEAR_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
#else
	vec4 orm = textureLod(sampler2D(gbuffer_orm_buffer, SAMPLER_LINEAR_CLAMP), screen_uv, 0.0);
#endif
	float ao = orm.r;
	float metallic = orm.b;
	float sss_strength = orm.a;

#ifdef USE_MULTIVIEW
	vec4 emission_alpha = textureLod(sampler2DArray(gbuffer_emission_buffer, SAMPLER_LINEAR_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
#else
	vec4 emission_alpha = textureLod(sampler2D(gbuffer_emission_buffer, SAMPLER_LINEAR_CLAMP), screen_uv, 0.0);
#endif
	vec3 emission = emission_alpha.rgb;

	// Cluster position for light lookups.
	uvec2 cluster_pos = uvec2(gl_FragCoord.xy) >> implementation_data.cluster_shift;
	uint cluster_offset = (implementation_data.cluster_width * cluster_pos.y + cluster_pos.x) * (implementation_data.max_cluster_element_count_div_32 + 32);
	uint cluster_z = uint(clamp((-vertex.z / scene_data.z_far) * 32.0, 0.0, 31.0));

	vec3 vertex_ddx = dFdx(vertex);
	vec3 vertex_ddy = dFdy(vertex);

	// Energy conservation.
	vec3 f0 = F0(metallic, 0.5, albedo);
	vec2 envBRDF = prefiltered_dfg(roughness, clamp(dot(normal, view), 0.0001, 1.0)).xy;
	vec3 energy_compensation = get_energy_compensation(f0, envBRDF.y);

	vec3 direct_specular_light = vec3(0.0, 0.0, 0.0);
	vec3 indirect_specular_light = vec3(0.0, 0.0, 0.0);
	vec3 diffuse_light = vec3(0.0, 0.0, 0.0);
	vec3 ambient_light = vec3(0.0, 0.0, 0.0);

	// Indirect lighting: GI buffers (SDFGI/VoxelGI processed by gi.process_gi).
	if (bool(scene_data.flags & SCENE_DATA_FLAGS_USE_AMBIENT_LIGHT)) {
		ambient_light = scene_data.ambient_light_color_energy.rgb;

		if (bool(scene_data.flags & SCENE_DATA_FLAGS_USE_REFLECTION_CUBEMAP)) {
			vec3 ref_vec = reflect(-view, normal);
			ref_vec = mix(ref_vec, normal, roughness * roughness);

			float horizon = min(1.0 + dot(ref_vec, normal), 1.0);
			ref_vec = scene_data.radiance_inverse_xform * ref_vec;

			float roughness_lod = sqrt(roughness) * MAX_ROUGHNESS_LOD;
#ifdef USE_RADIANCE_OCTMAP_ARRAY
			float ref_lod = vec3_to_oct_lod(dFdx(ref_vec), dFdy(ref_vec), scene_data_block.data.radiance_pixel_size);
			vec2 ref_uv = vec3_to_oct_with_border(ref_vec, vec2(scene_data_block.data.radiance_border_size, 1.0 - scene_data_block.data.radiance_border_size * 2.0));
			indirect_specular_light = textureLod(sampler2DArray(radiance_octmap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec3(ref_uv, 0.0), ref_lod).rgb;
#else
			vec2 ref_uv = vec3_to_oct_with_border(ref_vec, vec2(scene_data_block.data.radiance_border_size, 1.0 - scene_data_block.data.radiance_border_size * 2.0));
			indirect_specular_light = textureLod(sampler2D(radiance_octmap, DEFAULT_SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), ref_uv, roughness_lod).rgb;
#endif

			indirect_specular_light *= scene_data.IBL_exposure_normalization;
			indirect_specular_light *= horizon * horizon;
			indirect_specular_light *= scene_data.ambient_light_color_energy.a;
		}

		// GI buffers (ambient/reflection) from gi.process_gi.
#ifdef USE_MULTIVIEW
		vec4 buffer_ambient = textureLod(sampler2DArray(ambient_buffer, SAMPLER_LINEAR_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
		vec4 buffer_reflection = textureLod(sampler2DArray(reflection_buffer, SAMPLER_LINEAR_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
#else
		vec4 buffer_ambient = textureLod(sampler2D(ambient_buffer, SAMPLER_LINEAR_CLAMP), screen_uv, 0.0);
		vec4 buffer_reflection = textureLod(sampler2D(reflection_buffer, SAMPLER_LINEAR_CLAMP), screen_uv, 0.0);
#endif
		ambient_light = mix(ambient_light, buffer_ambient.rgb, buffer_ambient.a);
		indirect_specular_light = mix(indirect_specular_light, buffer_reflection.rgb, buffer_reflection.a);

		// SSAO.
		if (bool(implementation_data.ss_effects_flags & SCREEN_SPACE_EFFECTS_FLAGS_USE_SSAO)) {
#ifdef USE_MULTIVIEW
			float ssao = texture(sampler2DArray(ao_buffer, SAMPLER_LINEAR_CLAMP), vec3(screen_uv, ViewIndex)).r;
#else
			float ssao = texture(sampler2D(ao_buffer, SAMPLER_LINEAR_CLAMP), screen_uv).r;
#endif
			ao = min(ao, ssao);
		}

		// Reflection probes.
		{
			vec4 reflection_accum = vec4(0.0, 0.0, 0.0, 0.0);
			vec4 ambient_accum = vec4(0.0, 0.0, 0.0, 0.0);

			uint cluster_reflection_offset = cluster_offset + implementation_data.cluster_type_size * 4;

			uint item_min;
			uint item_max;
			uint item_from;
			uint item_to;

			cluster_get_item_range(cluster_reflection_offset + implementation_data.max_cluster_element_count_div_32 + cluster_z, item_min, item_max, item_from, item_to);

			item_from = subgroupBroadcastFirst(subgroupMin(item_from));
			item_to = subgroupBroadcastFirst(subgroupMax(item_to));

			vec3 ref_vec = normalize(reflect(-view, normal));
			ref_vec = mix(ref_vec, normal, roughness * roughness * roughness * roughness);

			for (uint i = item_from; i < item_to; i++) {
				uint mask = cluster_buffer.data[cluster_reflection_offset + i];
				mask &= cluster_get_range_clip_mask(i, item_min, item_max);

				uint merged_mask = subgroupBroadcastFirst(subgroupOr(mask));
				while (merged_mask != 0) {
					uint bit = findMSB(merged_mask);
					merged_mask &= ~(1u << bit);

					if (((1u << bit) & mask) == 0) { //do not process if not originally here
						continue;
					}

					uint reflection_index = 32 * i + bit;

					if (reflection_accum.a >= 1.0 && ambient_accum.a >= 1.0) {
						break;
					}

					reflection_process(reflection_index, vertex, ref_vec, normal, roughness, ambient_light, ambient_accum, reflection_accum);
				}
			}

			if (ambient_accum.a < 1.0) {
				ambient_accum.rgb = ambient_light * (1.0 - ambient_accum.a) + ambient_accum.rgb;
			}

			if (reflection_accum.a < 1.0) {
				reflection_accum.rgb = indirect_specular_light * (1.0 - reflection_accum.a) + reflection_accum.rgb;
			}

			if (reflection_accum.a > 0.0) {
				indirect_specular_light = reflection_accum.rgb;
			}

			ambient_light = ambient_accum.rgb;
		}

		// Finalize ambient.
		ambient_light *= ao;
		ambient_light *= albedo.rgb;

		// SSIL.
		if (bool(implementation_data.ss_effects_flags & SCREEN_SPACE_EFFECTS_FLAGS_USE_SSIL)) {
#ifdef USE_MULTIVIEW
			vec4 ssil = textureLod(sampler2DArray(ssil_buffer, SAMPLER_LINEAR_CLAMP), vec3(screen_uv, ViewIndex), 0.0);
#else
			vec4 ssil = textureLod(sampler2D(ssil_buffer, SAMPLER_LINEAR_CLAMP), screen_uv, 0.0);
#endif
			ambient_light *= 1.0 - ssil.a;
			ambient_light += ssil.rgb * albedo.rgb;
		}

		// SSR.
		if (bool(implementation_data.ss_effects_flags & SCREEN_SPACE_EFFECTS_FLAGS_USE_SSR)) {
			bool resolve_ssr = bool(implementation_data.ss_effects_flags & SCREEN_SPACE_EFFECTS_FLAGS_RESOLVE_SSR);

			float ssr_mip_level = 0.0;
			if (resolve_ssr) {
#ifdef USE_MULTIVIEW
				ssr_mip_level = textureLod(sampler2DArray(ssr_mip_level_buffer, SAMPLER_NEAREST_CLAMP), vec3(screen_uv, ViewIndex), 0.0).x;
#else
				ssr_mip_level = textureLod(sampler2D(ssr_mip_level_buffer, SAMPLER_NEAREST_CLAMP), screen_uv, 0.0).x;
#endif
				ssr_mip_level *= 14.0;
			}

#ifdef USE_MULTIVIEW
			vec4 ssr = textureLod(sampler2DArray(ssr_buffer, SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), vec3(screen_uv, ViewIndex), ssr_mip_level);
#else
			vec4 ssr = textureLod(sampler2D(ssr_buffer, SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP), screen_uv, ssr_mip_level);
#endif

			if (resolve_ssr) {
				const vec3 rec709_luminance_weights = vec3(0.2126, 0.7152, 0.0722);
				ssr.rgb /= 1.0 - dot(ssr.rgb, rec709_luminance_weights);
			}

			ssr *= smoothstep(0.0, 1.0, 1.0 - clamp((roughness - 0.6) / (0.7 - 0.6), 0.0, 1.0));

			indirect_specular_light = indirect_specular_light * (1.0 - ssr.a) + ssr.rgb;
		}

		// Apply energy compensation and DFG to the indirect specular.
		float NdotV = clamp(dot(normal, view), 0.0001, 1.0);
		vec2 envBRDF2 = prefiltered_dfg(roughness, NdotV).xy;
		vec3 energy_compensation2 = get_energy_compensation(f0, envBRDF2.y);
		float f90 = clamp(50.0 * f0.g, metallic, 1.0);
		indirect_specular_light *= energy_compensation2 * ((f90 - f0) * envBRDF2.x + f0 * envBRDF2.y);
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
				float depth_z = -vertex.z;
				vec3 light_dir = directional_lights.data[i].direction;
				vec3 base_normal_bias = normal * (1.0 - max(0.0, dot(light_dir, -normal)));

#define BIAS_FUNC(m_var, m_idx)                                                                 \
	m_var.xyz += light_dir * directional_lights.data[i].shadow_bias[m_idx];                     \
	vec3 normal_bias = base_normal_bias * directional_lights.data[i].shadow_normal_bias[m_idx]; \
	normal_bias -= light_dir * dot(light_dir, normal_bias);                                     \
	m_var.xyz += normal_bias;

				if (sc_use_directional_soft_shadows() && directional_lights.data[i].softshadow_angle > 0) {
					uint blend_count = 0;
					const uint blend_max = directional_lights.data[i].blend_splits ? 2 : 1;

					if (depth_z < directional_lights.data[i].shadow_split_offsets.x) {
						vec4 v = vec4(vertex, 1.0);

						BIAS_FUNC(v, 0)

						vec4 pssm_coord = (directional_lights.data[i].shadow_matrix1 * v);
						pssm_coord /= pssm_coord.w;

						float range_pos = dot(directional_lights.data[i].direction, v.xyz);
						float range_begin = directional_lights.data[i].shadow_range_begin.x;
						float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
						vec2 tex_scale = directional_lights.data[i].uv_scale1 * test_radius;
						shadow = sample_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data.taa_frame_count);
						blend_count++;
					}

					if (blend_count < blend_max && depth_z < directional_lights.data[i].shadow_split_offsets.y) {
						vec4 v = vec4(vertex, 1.0);

						BIAS_FUNC(v, 1)

						vec4 pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
						pssm_coord /= pssm_coord.w;

						float range_pos = dot(directional_lights.data[i].direction, v.xyz);
						float range_begin = directional_lights.data[i].shadow_range_begin.y;
						float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
						vec2 tex_scale = directional_lights.data[i].uv_scale2 * test_radius;
						float s = sample_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data.taa_frame_count);

						if (blend_count == 0) {
							shadow = s;
						} else {
							float blend = smoothstep(0.0, directional_lights.data[i].shadow_split_offsets.x, depth_z);
							shadow = mix(shadow, s, blend);
						}

						blend_count++;
					}

					if (blend_count < blend_max && depth_z < directional_lights.data[i].shadow_split_offsets.z) {
						vec4 v = vec4(vertex, 1.0);

						BIAS_FUNC(v, 2)

						vec4 pssm_coord = (directional_lights.data[i].shadow_matrix3 * v);
						pssm_coord /= pssm_coord.w;

						float range_pos = dot(directional_lights.data[i].direction, v.xyz);
						float range_begin = directional_lights.data[i].shadow_range_begin.z;
						float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
						vec2 tex_scale = directional_lights.data[i].uv_scale3 * test_radius;
						float s = sample_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data.taa_frame_count);

						if (blend_count == 0) {
							shadow = s;
						} else {
							float blend = smoothstep(directional_lights.data[i].shadow_split_offsets.x, directional_lights.data[i].shadow_split_offsets.y, depth_z);
							shadow = mix(shadow, s, blend);
						}

						blend_count++;
					}

					if (blend_count < blend_max) {
						vec4 v = vec4(vertex, 1.0);

						BIAS_FUNC(v, 3)

						vec4 pssm_coord = (directional_lights.data[i].shadow_matrix4 * v);
						pssm_coord /= pssm_coord.w;

						float range_pos = dot(directional_lights.data[i].direction, v.xyz);
						float range_begin = directional_lights.data[i].shadow_range_begin.w;
						float test_radius = (range_pos - range_begin) * directional_lights.data[i].softshadow_angle;
						vec2 tex_scale = directional_lights.data[i].uv_scale4 * test_radius;
						float s = sample_directional_soft_shadow(directional_shadow_atlas, pssm_coord.xyz, tex_scale * directional_lights.data[i].soft_shadow_scale, scene_data.taa_frame_count);

						if (blend_count == 0) {
							shadow = s;
						} else {
							float blend = smoothstep(directional_lights.data[i].shadow_split_offsets.y, directional_lights.data[i].shadow_split_offsets.z, depth_z);
							shadow = mix(shadow, s, blend);
						}
					}
				} else { //no soft shadows
					vec4 pssm_coord;
					float blur_factor;

					if (depth_z < directional_lights.data[i].shadow_split_offsets.x) {
						vec4 v = vec4(vertex, 1.0);

						BIAS_FUNC(v, 0)

						pssm_coord = (directional_lights.data[i].shadow_matrix1 * v);
						blur_factor = 1.0;
					} else if (depth_z < directional_lights.data[i].shadow_split_offsets.y) {
						vec4 v = vec4(vertex, 1.0);

						BIAS_FUNC(v, 1)

						pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
						blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.y;
					} else if (depth_z < directional_lights.data[i].shadow_split_offsets.z) {
						vec4 v = vec4(vertex, 1.0);

						BIAS_FUNC(v, 2)

						pssm_coord = (directional_lights.data[i].shadow_matrix3 * v);
						blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.z;
					} else {
						vec4 v = vec4(vertex, 1.0);

						BIAS_FUNC(v, 3)

						pssm_coord = (directional_lights.data[i].shadow_matrix4 * v);
						blur_factor = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.w;
					}

					pssm_coord /= pssm_coord.w;

					shadow = sample_directional_pcf_shadow(directional_shadow_atlas, scene_data.directional_shadow_pixel_size * directional_lights.data[i].soft_shadow_scale * (blur_factor + (1.0 - blur_factor) * float(directional_lights.data[i].blend_splits)), pssm_coord, scene_data.taa_frame_count);

					if (directional_lights.data[i].blend_splits) {
						float pssm_blend;
						float blur_factor2;

						if (depth_z < directional_lights.data[i].shadow_split_offsets.x) {
							vec4 v = vec4(vertex, 1.0);
							BIAS_FUNC(v, 1)
							pssm_coord = (directional_lights.data[i].shadow_matrix2 * v);
							pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.x - directional_lights.data[i].shadow_split_offsets.x * 0.1, directional_lights.data[i].shadow_split_offsets.x, depth_z);
							blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.y;
						} else if (depth_z < directional_lights.data[i].shadow_split_offsets.y) {
							vec4 v = vec4(vertex, 1.0);
							BIAS_FUNC(v, 2)
							pssm_coord = (directional_lights.data[i].shadow_matrix3 * v);
							pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.y - directional_lights.data[i].shadow_split_offsets.y * 0.1, directional_lights.data[i].shadow_split_offsets.y, depth_z);
							blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.z;
						} else if (depth_z < directional_lights.data[i].shadow_split_offsets.z) {
							vec4 v = vec4(vertex, 1.0);
							BIAS_FUNC(v, 3)
							pssm_coord = (directional_lights.data[i].shadow_matrix4 * v);
							pssm_blend = smoothstep(directional_lights.data[i].shadow_split_offsets.z - directional_lights.data[i].shadow_split_offsets.z * 0.1, directional_lights.data[i].shadow_split_offsets.z, depth_z);
							blur_factor2 = directional_lights.data[i].shadow_split_offsets.x / directional_lights.data[i].shadow_split_offsets.w;
						} else {
							pssm_blend = 0.0;
							blur_factor2 = 1.0;
						}

						pssm_coord /= pssm_coord.w;

						float shadow2 = sample_directional_pcf_shadow(directional_shadow_atlas, scene_data.directional_shadow_pixel_size * directional_lights.data[i].soft_shadow_scale * (blur_factor2 + (1.0 - blur_factor2) * float(directional_lights.data[i].blend_splits)), pssm_coord, scene_data.taa_frame_count);
						shadow = mix(shadow, shadow2, pssm_blend);
					}
				}

#undef BIAS_FUNC
			}

			shadow = mix(1.0, shadow, directional_lights.data[i].shadow_opacity);

			float size_A = sc_use_directional_soft_shadows() ? directional_lights.data[i].size : 0.0;

			light_compute(normal, directional_lights.data[i].direction, view, size_A,
					directional_lights.data[i].color * directional_lights.data[i].energy,
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
	diffuse_light *= ao;
	direct_specular_light *= ao;
	diffuse_light *= 1.0 - metallic;
	ambient_light *= 1.0 - metallic;

	vec3 color = emission + ambient_light + diffuse_light + direct_specular_light + indirect_specular_light;

#ifdef MODE_SEPARATE_SPECULAR
	frag_color = vec4(color - (direct_specular_light + indirect_specular_light), sss_strength);
	specular_color = vec4(direct_specular_light + indirect_specular_light, metallic);
#else
	frag_color = vec4(color, alpha);
#endif
}
