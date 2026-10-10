/**************************************************************************/
/*  frp_pass_context.h                                                    */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#pragma once

#include "core/object/ref_counted.h"
#include "core/math/basis.h"
#include "core/os/mutex.h"
#include "core/templates/hash_set.h"
#include "core/templates/hash_map.h"
#include "core/templates/vector.h"
#include "core/variant/callable.h"
#include "core/variant/type_info.h"
#include "servers/rendering/frp_pipeline_spec.h"

#include <functional>

class RenderDataRD;
class RenderSceneBuffersRD;

// The FRP Core surface a pass runs on, in the sense URP gives a ScriptableRenderPass:
// the frame's state plus the engine's rendering primitives. A pass that is part of an
// FRP pipeline receives one of these instead of a bare CompositorEffect callback, so
// it can drive the frame (draw the G-buffer, run deferred lighting, resolve, tone map)
// with the engine's own implementations instead of reimplementing them.
//
// Every primitive maps to exactly one internal renderer operation, which is also what
// the engine's built-in passes call: the default path and a scripted pass therefore
// execute the same code.
class FRPPassContext : public RefCounted {
	GDCLASS(FRPPassContext, RefCounted);

	RenderDataRD *render_data = nullptr;
	std::function<void(int)> operation_runner;
	std::function<bool(int)> operation_is_scheduled;
	std::function<void(int)> stage_runner;
	// Callbacks are consumed immediately after their scheduled operation and all
	// remaining entries are cleared at frame end; queues never cross frames.
	HashMap<int, Vector<Callable>> after_operation_callbacks;
	HashSet<int> dispatching_after_operation_callbacks;
	HashSet<int> completed_operations;
	// Presents a texture to the viewport's render target. Only the renderer can reach
	// the render target, so the primitive goes through this callback.
	std::function<void(const StringName &)> present_runner;
	std::function<float(int)> pre_exposure_reader;
	std::function<void(int, float)> pre_exposure_writer;
	std::function<void(RID)> eye_exposure_texture_writer;
	// Resolved frame parameters, keyed by native pass id or custom pass name.
	Dictionary pass_parameters;
	// Immutable FRP volume inputs, published after clustered lighting has been
	// prepared. camera transforms/origins and projections are view-specific; the
	// transforms already include the Vector3 eye offset. The fixed two-view storage
	// matches RenderSceneRender::MAX_RENDER_VIEWS.
	Dictionary volume_frame_inputs[2];
	int volume_frame_view_count = 0;
	// The volume output belongs to the addon RenderSceneBuffers owner. These are
	// borrowed handles only; FRPPassContext never frees them.
	RID volume_output_texture;
	PackedFloat32Array volume_sampling_parameters;
	float volume_rgb_pre_exposure = 1.0f;
	bool volume_deferred_composition = false;
	// Render-local Feng Height Fog snapshot. It is written by the Sky-anchored
	// HeightFog pass and consumed by the later forward fallback/transparent ops.
	PackedFloat32Array height_fog_parameters;
	// Frame-local atmosphere handoff. No scene-node mutation or addon lookup.
	PackedFloat32Array atmosphere_parameters;
	RID atmosphere_light_rids[2];
	RID atmosphere_optical_texture;
	RID atmosphere_multiple_texture;
	// Optional per-frame capture of the global SkyLight diffuse term for GI passes.
	bool sky_light_diffuse_requested = false;
	bool indirect_specular_requested = false;
	std::function<RID(int)> indirect_specular_target_provider;
	RID indirect_specular_target_cache[2];
	bool indirect_specular_target_cached[2] = { false, false };
	bool indirect_specular_modified[2] = { false, false };
	// Current scene exposure scale excluding pre-exposure, matching the FRP lighting UBO.
	float scene_exposure_normalization = 1.0f;
	// Immutable cloud inputs for this frame. The pass supplies only value packets and
	// renderer texture/light RIDs; native cloud stages consume them before the context
	// is released. No Node or Resource is retained across frames.
	PackedFloat32Array cloud_material_parameters;
	int64_t cloud_snapshot_source_signature = 0;
	RID cloud_textures[4]; // shape, detail, weather, curl.
	RID cloud_layout_textures[3]; // borrowed UE layout inputs: pattern, mask, height profile.
	RID cloud_suns[2]; // primary and secondary DirectionalLight base RIDs.
	bool cloud_sun_cast_shadows_on_clouds[2] = { false, false };
	Vector3 cloud_sun_ground_transmittance[2] = { Vector3(1, 1, 1), Vector3(1, 1, 1) };
	// Native renderer inputs are published after LightStorage has prepared this
	// frame. These are bounded std140 packets plus borrowed renderer-owned RIDs.
	PackedFloat32Array cloud_lighting_parameters; // 48 floats / 192 bytes.
	PackedFloat32Array cloud_native_shadow_parameters; // 156 floats / 624 bytes.
	PackedFloat32Array cloud_projection_parameters; // 140 floats / 560 bytes, authored by the addon.
	RID cloud_sky_octmap;
	RID cloud_directional_shadow_atlas;
	RID cloud_shadow_sampler;
	// GPU outputs are borrowed from the pass' RenderSceneBuffersRD textures. The
	// context only exposes them to later native consumers in this same frame.
	RID cloud_outputs[8]; // radiance, T, depth, sun0 shadow, sun1 shadow, AO, ambient, raw AO.
	// Reflection capture metadata is per face; immutable source snapshots are held
	// by the capture-effect lease, while camera matrices come from current RenderData.
	bool cloud_capture_active = false;
	uint64_t cloud_capture_batch_id = 0;
	int cloud_capture_face_index = -1;
	int cloud_capture_face_count = 0;
	Vector3 cloud_capture_origin_world_m;
	float cloud_capture_exposure_normalization = 1.0f;
	// Optional mode selected by the FRP Post Process pass for this frame only.
	// -1 leaves the Environment's renderer mode untouched; 5 is FRP's UE film LUT.
	int tonemap_mode_override = -1;

	void _run_operation(int p_operation);
	static void _finish_pre_exposure_readback(const PackedByteArray &p_data, const Ref<FRPPassContext> &p_context, int p_view);

protected:
	static void _bind_methods();

public:
	enum Operation {
		OP_GBUFFER = FRPPipelineSpec::OP_GBUFFER,
		OP_LIGHTING_PREPARE = FRPPipelineSpec::OP_LIGHTING_PREPARE,
		OP_PRE_LIGHTING_STAGE = FRPPipelineSpec::OP_PRE_LIGHTING_STAGE,
		OP_SCREEN_AND_DEPTH_COPY = FRPPipelineSpec::OP_SCREEN_AND_DEPTH_COPY,
	};

	struct SkyLightingSource {
		uint64_t owner_id = 0;
		RID sky;
		float energy = 1.0f;
		Basis rotation;
		float captured_exposure = 1.0f;
		uint64_t revision = 0;
	};

	static void set_sky_lighting_source(RID p_render_target, uint64_t p_owner_id, RID p_sky, float p_energy, const Basis &p_rotation, float p_captured_exposure, uint64_t p_revision);
	static void clear_sky_lighting_source(RID p_render_target, uint64_t p_owner_id);
	static void clear_all_sky_lighting_sources();
	static bool get_sky_lighting_source(RID p_render_target, SkyLightingSource &r_source);

	void setup(RenderDataRD *p_render_data, const std::function<void(int)> &p_operation_runner, const std::function<void(int)> &p_stage_runner, const Dictionary &p_pass_parameters = Dictionary(), const std::function<void(const StringName &)> &p_present_runner = std::function<void(const StringName &)>(), const std::function<float(int)> &p_pre_exposure_reader = std::function<float(int)>(), const std::function<void(int, float)> &p_pre_exposure_writer = std::function<void(int, float)>(), const std::function<void(RID)> &p_eye_exposure_texture_writer = std::function<void(RID)>(), float p_scene_exposure_normalization = 1.0f, const std::function<bool(int)> &p_operation_is_scheduled = std::function<bool(int)>());

	// Frame state.
	RenderDataRD *get_render_data() const { return render_data; }
	Ref<RenderSceneBuffersRD> get_render_scene_buffers() const;
	int get_view_count() const;
	Vector2i get_internal_size() const;
	String get_pass_name(int p_pass_id) const;
	bool is_valid_pass_id(int p_pass_id) const;
	// Parameters the pipeline resource authored for a pass. A pass script reads its
	// own settings this way, so the pipeline resource is the single place a project
	// configures a pass.
	Dictionary get_pass_parameters(const Variant &p_pass_id) const;
	float get_pre_exposure(int p_view) const;
	float get_scene_exposure_normalization() const { return scene_exposure_normalization; }
	void set_next_pre_exposure(int p_view, float p_exposure);
	void set_height_fog_parameters(const PackedFloat32Array &p_parameters);
	PackedFloat32Array get_height_fog_parameters() const { return height_fog_parameters; }
	// The publisher supplies a fresh per-view dictionary and does not mutate it afterwards;
	// scripts receive an isolated deep copy from the getter.
	void set_volume_frame_input(int p_view, const Dictionary &p_inputs);
	void clear_volume_frame_inputs();
	Dictionary get_volume_frame_inputs(int p_view = 0) const;
	// Returns -1 when this view has no valid v1 frame packet.
	int64_t get_volume_frame_generation(int p_view = 0) const;
	// Borrowed addon output: one RGBA16F 3D X-tiled view atlas and the v1 20-float
	// sampling packet. Its five vec4 slots are (B,O,S,froxel_pixel_size),
	// (gridX,gridY,gridZ,viewCount), (atlasW,atlasH,atlasD,viewStrideX),
	// (start,far,near,P0), and (1/atlasW,1/atlasH,1/atlasD,valid=1).
	// XY maps internal viewport pixels to froxels by dividing by pixel_size;
	// Z maps depth with log2(max(depth * B + O, epsilon)) * S / gridZ.
	// RGB is stored at P0; alpha is integrated transmittance.
	void set_volume_output(RID p_texture, const PackedFloat32Array &p_sample_parameters, float p_rgb_pre_exposure);
	RID get_volume_texture() const { return volume_output_texture; }
	PackedFloat32Array get_volume_sampling_parameters() const { return volume_sampling_parameters; }
	float get_volume_rgb_pre_exposure() const { return volume_rgb_pre_exposure; }
	bool has_volume_output() const { return volume_output_texture.is_valid() && volume_sampling_parameters.size() == 20; }
	void clear_volume_output();
	void set_volume_deferred_composition(bool p_deferred);
	bool is_volume_deferred_composition() const { return volume_deferred_composition; }
	void set_atmosphere_parameters(const PackedFloat32Array &p_parameters, RID p_light, RID p_secondary_light, RID p_optical_texture, RID p_multiple_texture);
	PackedFloat32Array get_atmosphere_parameters() const { return atmosphere_parameters; }
	// Requests the deferred opaque lighting pass to publish its global SkyLight diffuse contribution.
	void request_sky_light_diffuse();
	bool is_sky_light_diffuse_requested() const { return sky_light_diffuse_requested; }
	void request_indirect_specular();
	bool is_indirect_specular_requested() const { return indirect_specular_requested; }
	void set_indirect_specular_target_provider(const std::function<RID(int)> &p_provider) { indirect_specular_target_provider = p_provider; }
	void begin_indirect_specular_callback();
	RID get_indirect_specular_composite_target(int p_view = 0);
	void mark_indirect_specular_modified(int p_view = 0);
	bool is_indirect_specular_modified(int p_view) const;
	void set_cloud_snapshot(const PackedFloat32Array &p_material_parameters, RID p_shape_texture, RID p_detail_texture, RID p_weather_texture, RID p_curl_texture, RID p_primary_sun, RID p_secondary_sun, int64_t p_source_signature = 0);
	void clear_cloud_snapshot();
	void set_cloud_layout_textures(RID p_pattern_texture, RID p_cloud_mask_texture, RID p_height_profile_texture);
	bool has_cloud_snapshot() const { return !cloud_material_parameters.is_empty(); }
	PackedFloat32Array get_cloud_material_parameters() const { return cloud_material_parameters; }
	int64_t get_cloud_snapshot_source_signature() const { return cloud_snapshot_source_signature; }
	RID get_cloud_texture(int p_index) const { return p_index >= 0 && p_index < 4 ? cloud_textures[p_index] : RID(); }
	RID get_cloud_layout_texture(int p_index) const { return p_index >= 0 && p_index < 3 ? cloud_layout_textures[p_index] : RID(); }
	RID get_cloud_sun(int p_index) const { return p_index >= 0 && p_index < 2 ? cloud_suns[p_index] : RID(); }
	void set_cloud_sun_ground_transmittance(int p_index, const Vector3 &p_transmittance);
	Vector3 get_cloud_sun_ground_transmittance(int p_index) const { return p_index >= 0 && p_index < 2 ? cloud_sun_ground_transmittance[p_index] : Vector3(1, 1, 1); }
	void set_cloud_sun_cast_shadows_on_clouds(int p_index, bool p_enabled);
	bool get_cloud_sun_cast_shadows_on_clouds(int p_index) const { return p_index >= 0 && p_index < 2 && cloud_sun_cast_shadows_on_clouds[p_index]; }
	// Set by RenderFRPClustered after native light/shadow state is ready. These
	// setters are C++ only; the addon consumes the read-only typed getters.
	void set_cloud_native_inputs(const PackedFloat32Array &p_lighting, const PackedFloat32Array &p_native_shadow, RID p_sky_octmap, RID p_directional_shadow_atlas, RID p_shadow_sampler);
	void clear_cloud_native_inputs();
	PackedFloat32Array get_cloud_lighting_parameters() const { return cloud_lighting_parameters; }
	PackedFloat32Array get_cloud_native_shadow_parameters() const { return cloud_native_shadow_parameters; }
	void set_cloud_projection_parameters(const PackedFloat32Array &p_projection);
	void clear_cloud_projection_parameters();
	PackedFloat32Array get_cloud_projection_parameters() const { return cloud_projection_parameters; }
	// 148 floats: addon cloud projection (140), atmosphere-to-cloud sun/map mapping (4), and flags (4).
	PackedFloat32Array get_cloud_atmosphere_parameters() const;
	RID get_cloud_sky_octmap() const { return cloud_sky_octmap; }
	RID get_cloud_directional_shadow_atlas() const { return cloud_directional_shadow_atlas; }
	RID get_cloud_shadow_sampler() const { return cloud_shadow_sampler; }
	// Output slots are 0 radiance, 1 transmittance, 2 front/mean depth, 3/4
	// per-sun cloud shadow maps, 5 final AO, 6 ambient, and 7 raw AO statistics.
	void set_cloud_outputs(RID p_radiance, RID p_transmittance, RID p_depth, RID p_ambient);
	void set_cloud_shadow_outputs(RID p_sun0_shadow, RID p_sun1_shadow, RID p_ambient_occlusion, RID p_raw_ao_statistics);
	void clear_cloud_outputs();
	bool has_cloud_outputs() const { return cloud_outputs[0].is_valid() && cloud_outputs[1].is_valid() && cloud_outputs[2].is_valid(); }
	bool has_cloud_shadow_outputs() const { return cloud_outputs[3].is_valid() || cloud_outputs[4].is_valid() || cloud_outputs[5].is_valid(); }
	RID get_cloud_output(int p_index) const { return p_index >= 0 && p_index < 8 ? cloud_outputs[p_index] : RID(); }
	// Set by the renderer for each face of a reflection capture. No source Node,
	// Environment, or Sky resource is retained by this per-frame context.
	void set_cloud_capture_context(bool p_active, uint64_t p_batch_id, int p_face_index, int p_face_count, const Vector3 &p_origin_world_m, float p_exposure_normalization);
	bool is_cloud_capture() const { return cloud_capture_active; }
	uint64_t get_cloud_capture_batch_id() const { return cloud_capture_batch_id; }
	int get_cloud_capture_face_index() const { return cloud_capture_face_index; }
	int get_cloud_capture_face_count() const { return cloud_capture_face_count; }
	Vector3 get_cloud_capture_origin_world_m() const { return cloud_capture_origin_world_m; }
	float get_cloud_capture_exposure_normalization() const { return cloud_capture_exposure_normalization; }
	float get_cloud_time_seconds() const;
	Vector2 get_taa_jitter() const;
	// Alpha holdout is meaningful only for transparent render targets. Reflection
	// captures use an opaque cubemap target and never publish cloud holdout alpha.
	bool supports_cloud_holdout() const;
	RID get_atmosphere_light_rid(int p_index) const { return p_index >= 0 && p_index < 2 ? atmosphere_light_rids[p_index] : RID(); }
	RID get_atmosphere_optical_texture() const { return atmosphere_optical_texture; }
	RID get_atmosphere_multiple_texture() const { return atmosphere_multiple_texture; }
	void set_tonemap_exposure_texture(RID p_texture);
	void set_tonemap_mode_override(int p_mode);
	int get_tonemap_mode_override() const { return tonemap_mode_override; }
	Error request_next_pre_exposure(RID p_buffer, int p_view, int p_offset);

	// Core primitives. One per engine operation, in execution order.
	void precompute_shadows();
	void execute_virtual_texture_updates();
	void prepare_lighting();
	void draw_gbuffer();
	void draw_motion_vectors();
	void draw_deferred_lighting();
	void merge_subsurface_and_specular();
	void resolve_opaque();
	void draw_sky();
	void resolve_sky();
	void draw_opaque_fallback();
	void copy_screen_and_depth();
	void draw_transparent();
	void temporal_aa_and_upscale();
	void prepare_bloom();
	void resolve_final();
	void copy_history();
	// Bloom preparation, post-processing (DoF and auto exposure), and tone mapping are
	// separate operations. A pass decides where its HDR/LDR effects run:
	//   prepare_bloom(); post_process(); <effects on HDR>; tonemap();
	//   post_process(); tonemap_deferred(); <effects on LDR>; present();
	void post_process();
	void tonemap();
	// Tone mapping that leaves the engine's present step to the caller: the toned image
	// lands in the engine's intermediate texture, which effects can read and write.
	void tonemap_deferred();
	// Copies a pipeline texture (empty name: the engine's toned image) to the viewport's
	// render target, i.e. presents it.
	void present(const StringName &p_texture = StringName());
	// Compatibility: both steps in order, exactly as one entry used to run them.
	void post_process_and_tonemap();

	// Runs every operation of an engine pass (see RenderingServer.get_frp_pipeline_spec()).
	void run_pass(int p_pass_id);
	// Runs a CompositorEffect callback stage, exactly as the engine's own passes do.
	void stage_compositor_effects(int p_callback_type);
	// Queues a one-shot callback after an operation in this frame's execution plan.
	// The callback receives this context as its only argument. Returns false when
	// the operation is absent, the callback is invalid, that operation is already
	// complete/dispatching, or a capture has no screen/depth copy or transparent
	// draw at its late scene-color boundary.
	bool enqueue_after_operation(int p_operation, const Callable &p_callback);
	// Renderer entry point called immediately after a built-in operation returns.
	void dispatch_after_operation_callbacks(int p_operation);
	bool has_pending_after_operation_callbacks() const { return !after_operation_callbacks.is_empty(); }
	// Ends this render frame's scheduling window, releasing any callbacks for
	// operations skipped by an explicit pipeline and invalidating the plan query.
	void clear_after_operation_callbacks();
	// Reports whether the named operation has already executed in this frame.
	bool is_operation_completed(int p_operation) const;
};

VARIANT_ENUM_CAST(FRPPassContext::Operation);
