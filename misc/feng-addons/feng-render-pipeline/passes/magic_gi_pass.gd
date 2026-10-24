@tool
class_name FengMagicGIPass
extends FengRuntimeSnapshotPass
## Applies the current lighting to a baked surface PRT field.
##
## Bake textures are cached by the immutable data identity and bake version. The
## Lighting is cached per bake and refreshed only when its sources change.

const U = preload("../rd/uniforms.gd")
const DirectionalCache = preload("magic_gi_directional_cache.gd")
const DynamicVolumeCache = preload("magic_gi_dynamic_volume_cache.gd")
const PreinterpolatedVolumeCache = preload("magic_gi_preinterpolated_volume_cache.gd")
const PagedPreparedVolumeCache = preload("magic_gi_paged_prepared_volume_cache.gd")
const CLVEditorSnapshot = preload("magic_gi_clv_editor_snapshot.gd")
const ClipmapCache = preload("magic_gi_clv_cache.gd")
const MagicDawnBlockChartCache = preload("magic_gi_block_chart_cache.gd")
const ProbeBlockFieldCache = preload("magic_gi_probe_block_field_cache.gd")
const MagicDawnBakedSHCache = preload("magic_gi_baked_sh_clv_cache.gd")
const PageStream = preload("magic_gi_page_stream.gd")
const PageResidency = preload("magic_gi_page_residency.gd")
const PageUpload = preload("magic_gi_page_upload.gd")
const ProbeClusters = preload("magic_gi_probe_clusters.gd")
const SurfelGPU = preload("magic_gi_surfel_gpu.gd")
const SurfelNRD = preload("magic_gi_surfel_nrd.gd")
const RTGI_RUNTIME_PATH := "res://addons/feng-raytracing/scene/feng_rt_gi_runtime.gd"
const MAGIC_GI_OUTPUT: StringName = &"magic_gi"
const MAGIC_GI_CLV_SCREEN_HALF_INCIDENT: StringName = &"magic_gi_clv_screen_half_incident"
const MAGIC_GI_CLV_SCREEN_HALF_GUIDE: StringName = &"magic_gi_clv_screen_half_guide"
const MAGIC_GI_CLV_SCREEN_EDGE_INCIDENT: StringName = &"magic_gi_clv_screen_edge_incident"
const MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE := 8
const MAGIC_GI_DYNAMIC_SCREEN_HALF_INCIDENT: StringName = &"magic_gi_dynamic_screen_half_incident"
const MAGIC_GI_DYNAMIC_SCREEN_HALF_GUIDE: StringName = &"magic_gi_dynamic_screen_half_guide"
const MAGIC_GI_DYNAMIC_SCREEN_EDGE_INCIDENT: StringName = &"magic_gi_dynamic_screen_edge_incident"
const MAGIC_GI_DYNAMIC_SCREEN_RESOLVE_SHADER_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_dynamic_volume_screen_resolve.glsl"
const MAGIC_GI_DYNAMIC_SCREEN_FRAME_UBO_BYTES := 448
const MAGIC_GI_DYNAMIC_SCREEN_PUSH_BYTES := 24
const MAGIC_GI_DYNAMIC_SCREEN_WORKGROUP_SIZE := 8
const MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_BYTES := 7 * 4
const MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_COUNTER_NAMES := [
	"tile_count", "coherent_tiles", "edge_tiles", "valid_receivers",
	"invalid_receivers", "sample_calls", "sample_misses"]
const MAGIC_GI_APPLY_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_apply.glsl")
const MAGIC_GI_APPLY_MAGICDAWN_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_apply_magicdawn.glsl")
const MAGIC_GI_CLV_DEBUG_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_debug.glsl")
const MAGIC_GI_CLV_SCREEN_RESOLVE_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_screen_resolve.glsl")
const MAGIC_GI_CLV_SCREEN_PARTIAL_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_screen_partial.glsl")
const MAGIC_GI_CLV_SCREEN_CLASSIFY_SHADER_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_screen_classify.glsl"
const MAGIC_GI_CLV_SCREEN_DIAG_COUNTER_NAMES := [
	"tile_count", "coherent_tiles", "edge_tiles", "valid_receivers",
	"invalid_receivers", "sample_calls", "sample_misses", "domain_flat_hits",
	"domain_curved_hits", "legacy_strict_hits", "approx_hits", "partial_diffuse_hits",
	"partial_sh_hits", "partial_lod0_prepares", "partial_lod1_prepares",
	"partial_lod2_prepares", "partial_candidate_corners", "partial_visibility_rays",
	"partial_blocked_rays", "bvh_node_visits", "route_lod0", "route_lod1",
		"route_lod2", "axis_x", "axis_y", "axis_z", "confidence_sum_cent",
	"confidence_count", "owner_or_bounds_misses", "partial_calls", "partial_ray_visits",
	"reserved", "partial_coarse_invocations", "partial_coarse_pending",
	"partial_local_invocations", "partial_local_pending", "size_fail_extents",
	"size_fail_cache", "size_fail_depth", "size_fail_normal", "size_fail_edge",
	"size_fail_half_incident", "size_fail_half_guide", "fast_coarse_invocations",
	"fast_local_pending_pixels", "partial_coarse_guide_valid", "partial_coarse_guide_invalid",
	"partial_coarse_alpha_negative", "partial_coarse_alpha_nonnegative",
	"partial_local_negative_pixels", "partial_local_nonnegative_pixels",
	"partial_post_size_entries", "partial_before_first_image_load",
	"split_stage_magic"]
const MAGIC_GI_CLV_SCREEN_DIAG_COUNTER_COUNT := 53
const MAGIC_GI_CLV_SCREEN_DIAG_WORD_COUNT := MAGIC_GI_CLV_SCREEN_DIAG_COUNTER_COUNT * 2
const MAGIC_GI_CLV_SCREEN_DIAG_BYTES := MAGIC_GI_CLV_SCREEN_DIAG_WORD_COUNT * 4
const IndirectGISelection = preload("../pipeline/indirect_gi_selection.gd")
const UBO_BINDING := 9
const MAGIC_GI_FULL_FEATURES_SPEC_ID := 0
const MAGIC_GI_PRT_CACHE_GENERAL_SPEC_ID := 1
const MAGIC_GI_PRT_SOURCE_ONLY_SPEC_ID := 4
const MAGIC_GI_PRT_CERT_ONLY_SPEC_ID := 6
const MAGIC_GI_PRT_GENERAL_ONLY_SPEC_ID := 7
const MAGIC_GI_PRT_QUEUE_CONSUMER_SPEC_ID := 8
const MAGIC_GI_PRT_STAGE_LEGACY := 0
const MAGIC_GI_PRT_STAGE_CACHE_GENERAL := 1
const MAGIC_GI_PRT_STAGE_SOURCE := 2
const MAGIC_GI_PRT_STAGE_CERT_ONLY := 3
const MAGIC_GI_PRT_STAGE_GENERAL_ONLY := 4
const MAGIC_GI_PRT_STAGE_THREE_SOURCE := 5
const MAGIC_GI_SOURCE_PENDING_BINDING := 30
const MAGIC_GI_PRT_MISS_QUEUE_BINDING := 31
const MAGIC_GI_PRT_MISS_QUEUE_CONTROL_BINDING := 32
const MAGIC_GI_PRT_QUEUE_APPLY_SHADER_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_apply_compact.glsl"
const MAGIC_GI_PRT_QUEUE_FINALIZE_SHADER_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_prt_queue_finalize.glsl"
const MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE := 8
const MAGIC_GI_PRT_QUEUE_LOCAL_INVOCATIONS := 64
const MAGIC_GI_PRT_QUEUE_CONTROL_BYTES := 8
const MAGIC_GI_PRT_QUEUE_INDIRECT_BYTES := 12
const UBO_SIZE := 448 # Three mat4, two vec4, and separate secondary/sky SH vec4 arrays.
const MAX_CACHED_BAKES := 8
const MAX_FAILED_STREAM_PAGE_REVISIONS := 512
const RUNTIME_SCRIPT_PATH := "res://addons/feng-magic-gi/feng_magic_gi_runtime.gd"
const SKY_DIFFUSE_TEXTURE: StringName = &"sky_light_diffuse"
const MagicGIDebugRequest = preload("magic_gi_debug_request.gd")
const DIFFUSE_AO_BINDING := 16
const DIFFUSE_AO_VIEW_CACHE_LIMIT := 32
const RELIGHT_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_relight.glsl")
const PENDING_PAGE_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_pending_page.glsl")
const PRT_GUIDE_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_prt_guide.glsl")
const PRT_RESOLVE_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_prt_resolve.glsl")
const PAGE_PARAMS_BINDING := 23
const PAGE_PARAMS_SIZE := 128
const PENDING_PARAMS_SIZE := 256
const PROBE_CLUSTER_BINDING := 24
const CLV_STATS_BINDING := 27
const CLV_STATS_WORDS := 140
const CLV_STATS_BYTES := CLV_STATS_WORDS * 4
const MAGICDAWN_STATS_WORDS := 8
const MAGICDAWN_STATS_BYTES := MAGICDAWN_STATS_WORDS * 4
const MAGICDAWN_NATIVE_LAYOUT_VERSION := 17
const MAGICDAWN_BAKED_SH_REVISION := 2
const MAGICDAWN_NATIVE_OWNER_PARAMETER_BYTES := 96
const CLV_APPROX_DIAG_LEVEL_REASONS := [
	"invalid_step", "nonfinite_position", "outside_window", "seam",
	"base_tag", "neighbor_tag", "neighbor_not_ready", "low_coverage",
	"nonfinite_samples", "normal_magnitude", "normal_alignment", "plane_variance",
	"patch_variance", "patch_integer", "receiver_plane", "nonfinite_radiance",
	"plane_residual", "plane_precision",
]
const CLV_APPROX_DIAG_GLOBAL_REASONS := [
	"disabled", "layout_mismatch", "invalid_input", "invalid_normal",
	"no_levels", "outside_bake",
]
const PROBE_NEIGHBOR_MASK_RADIUS := 2
const PROBE_NEIGHBOR_MASK_WORDS := 4 # 5^3 query cells, packed into 128 bits.
const PROBE_NEIGHBOR_MASK_MAX_CELLS := 262144
const PROBE_NEIGHBOR_MASK_BINDING := 28
const PROBE_NEIGHBOR_CELL_LIST_BINDING := 29
const PROBE_NEIGHBOR_CELL_LIST_MAX_BYTES := 33554432
const GPU_TIMESTAMP_OUTER_MARKERS := ["Begin", "End",
		"Native Prepare Begin", "Native Prepare End",
		"Relight Begin", "Relight End", "CLV Begin", "CLV End",
		"Apply Begin", "Apply End", "CLV Debug Mirror Begin", "CLV Debug Mirror End",
		"Screen Cache Resolve Begin", "Screen Cache Resolve End",
		"Dynamic Screen Resolve Begin", "Dynamic Screen Resolve End",
		"Screen Cache Classify Begin", "Screen Cache Classify End",
		"Screen Cache Fast Resolve Begin", "Screen Cache Fast Resolve End",
		"Screen Cache Fast Coarse Begin", "Screen Cache Fast Coarse End",
		"Screen Cache Fast Local Begin", "Screen Cache Fast Local End",
		"Screen Cache Partial Resolve Begin", "Screen Cache Partial Resolve End",
		"Screen Cache Partial Coarse Begin", "Screen Cache Partial Coarse End",
		"Screen Cache Partial Local Edges Begin", "Screen Cache Partial Local Edges End"]
const PROBE_CLUSTER_CPU_CACHE_LIMIT := 32
const PROBE_CLUSTER_CPU_CACHE_BYTES := 16 * 1024 * 1024
const CLV_CACHE_BACKEND_LEGACY := 0
const CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART := 1
const CLV_INTERNAL_LAYOUT_AUTHORED := 0
const CLV_INTERNAL_LAYOUT13_TEST := 13
const CLV_INTERNAL_LAYOUT14_V0_TEST := 14
const CLV_MAGICDAWN_BAKED_SH_LAYOUT_VERSION := 17
const CLV_MAGICDAWN_BAKED_SH_TEXTURE_COUNT := 7
const CLV_LEGACY_LAYOUT_VERSION := 9
const CLV_MAGICDAWN_DYNAMIC_PRT_LAYOUT_VERSION := 9
const CLV_BLOCK_CHART_LAYOUT_VERSION := 13
const CLV_BLOCK_CHART_COLUMN_COUNT := 72
const CLV_INTERNAL_LAYOUT14_B_APPLY_SHADER_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_apply_b14.glsl"

enum CLVDebugView { OFF, CASCADE_LEVELS, CACHE_VALIDITY, CELLS, RECONSTRUCTED_LIGHTING, REJECTION_REASONS }

## Choose Magic GI in Debug Buffers to view the native layout-9 CLV sample. The
## diagnostic mirror is dispatched only while that buffer is requested and reads
## the same already-relit cache as deferred lighting; it never runs a PRT fallback.
@export_enum("Off", "Cascade Levels", "Cache Validity", "Cells", "Reconstructed Lighting", "Rejection Reasons")
var clv_debug_view: int = CLVDebugView.OFF:
	set(value):
		var next := clampi(value, CLVDebugView.OFF, CLVDebugView.REJECTION_REASONS)
		if clv_debug_view == next:
			return
		clv_debug_view = next
		emit_changed()

@export var clv_debug_view_status := "CLV debug mirror is idle until Debug Buffers → Magic GI requests it."

func _validate_property(property: Dictionary) -> void:
	var property_name := String(property.get("name", ""))
	if property_name != "clv_debug_view" and property_name != "clv_debug_view_status":
		return
	var baked_sh_backend := _magicdawn_backend_selected_for_inspector()
	if property_name == "clv_debug_view_status":
		if baked_sh_backend:
			property["usage"] = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
		else:
			# Keep the message out of legacy inspectors and resource serialization.
			property["usage"] = PROPERTY_USAGE_STORAGE

func _magicdawn_backend_selected_for_inspector() -> bool:
	if _last_clv_cache_backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART:
		return true
	if not Engine.is_editor_hint():
		return false
	# Inspector can be opened before the tool runtime has published a viewport
	# snapshot. Read the edited scene's authored Volume directly in that case.
	var edited_root := EditorInterface.get_edited_scene_root()
	if edited_root != null:
		if _node_selects_magicdawn_backend(edited_root):
			return true
		for volume in edited_root.find_children("*", "FMagicGIVolume", true, false):
			if _node_selects_magicdawn_backend(volume):
				return true
	var runtime_script := _get_runtime_script()
	if runtime_script == null or not runtime_script.has_method("snapshots"):
		return false
	var snapshots_value: Variant = runtime_script.call("snapshots")
	if not snapshots_value is Array:
		return false
	for snapshot_value in snapshots_value:
		if snapshot_value is Dictionary and _clv_cache_backend(snapshot_value) \
				== CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
				and bool(snapshot_value.get("use_clv", true)):
			return true
	return false

func _node_selects_magicdawn_backend(node: Object) -> bool:
	if node == null or not is_instance_valid(node) or not node.has_method("is_surfel_mode"):
		return false
	return not bool(node.call("is_surfel_mode")) \
			and bool(node.get("use_clv")) \
			and int(node.get("clv_cache_backend")) == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART

var _relight_shader := RID()
var _relight_pipeline := RID()
var _magicdawn_clv_debug_shader := RID()
var _magicdawn_clv_debug_pipeline := RID()
var _magicdawn_clv_debug_nearest_sampler := RID()
var _magicdawn_clv_debug_linear_sampler := RID()
var _magicdawn_screen_resolve_shader := RID()
var _magicdawn_screen_resolve_pipeline := RID()
var _magicdawn_screen_partial_shader := RID()
var _magicdawn_screen_partial_pipeline := RID()
var _magicdawn_screen_classify_shader_resource: RDShaderFile
var _magicdawn_screen_classify_shader := RID()
var _magicdawn_screen_classify_pipeline := RID()
var _magicdawn_screen_resolve_nearest_sampler := RID()
var _magicdawn_screen_resolve_linear_sampler := RID()
var _magicdawn_screen_resolve_diagnostics_buffer := RID()
var _dynamic_volume_screen_resolve_shader := RID()
var _dynamic_volume_screen_resolve_pipeline := RID()
var _dynamic_volume_screen_resolve_shader_resource: RDShaderFile
var _dynamic_volume_screen_nearest_sampler := RID()
var _dynamic_volume_screen_linear_sampler := RID()
var _dynamic_volume_screen_diagnostics_buffer := RID()
var _dynamic_volume_screen_frame_ubo := RID()
var _dynamic_volume_screen_frame_bytes := PackedByteArray()
var _dynamic_volume_screen_dispatch_serial := 0
var _dynamic_volume_screen_runtime_state: Dictionary = {"status": "idle"}
var _dynamic_volume_screen_diagnostic_armed := false
var _dynamic_volume_screen_diagnostic_pending := false
var _dynamic_volume_screen_diagnostic_token := 0
var _dynamic_volume_screen_diagnostic_result: Dictionary = {"status": "not_requested"}
var _dynamic_volume_screen_diagnostic_owner_packet: Dictionary = {}
var _dynamic_volume_screen_diagnostic_counts: Dictionary = {}
var _dynamic_volume_screen_diagnostic_metadata: Dictionary = {}
var _dynamic_volume_screen_diagnostic_owner_parameters := RID()
var _magicdawn_screen_diagnostic_armed := false
var _magicdawn_screen_diagnostic_pending := false
var _magicdawn_screen_diagnostic_token := 0
var _magicdawn_screen_diagnostic_roi := Rect2i()
var _magicdawn_screen_diagnostic_result: Dictionary = {"status": "not_requested"}
var _magicdawn_screen_resolve_dispatch_serial := 0
var _magicdawn_screen_resolve_status := "idle"
var _magicdawn_clv_debug_status := "not_requested"
var _magicdawn_active_readback_armed := false
var _magicdawn_active_readback_context: Dictionary = {}
var _magicdawn_active_readback_token := 0
var _magicdawn_active_readback_result: Dictionary = {}
var _magicdawn_active_readback_queue_state: Dictionary = {}
var _frame_magicdawn_clv_renderer_active := false
var _clipmaps: Dictionary = {}
var _frame_clipmap: RefCounted
var _last_clv_cache_backend := CLV_CACHE_BACKEND_LEGACY
## RAM-only experiment selector. This is intentionally not exported or stored in
## scene resources; 14 is a falsification prototype, never an authored backend.
var _clv_internal_test_layout := CLV_INTERNAL_LAYOUT_AUTHORED
var _layout14_b_internal_test_enabled := false
var _layout14_b_apply_shader_resource: RDShaderFile
var _layout14_b_saved_shader_file: RDShaderFile
var _layout14_b_frame_active := false
var _layout14_b_frame_moments := RID()
var _layout14_b_frame_sampler := RID()
var _layout14_b_frame_tags := RID()
var _layout14_b_error := "disabled"
var _layout14_b_apply_runtime_rejected := false
var _clv_fallback: Dictionary = {}
@export var native_clv_lighting_enabled := true
## Native deferred consumer for the persisted layout-17 total-SH clipmap. When
## unavailable or not confirmed consumed, the standalone MagicDawn apply remains
## the correctness fallback and can be used for A/B comparison.
@export var native_baked_sh_lighting_enabled := true
## Experimental deferred general-CLV path. It requires fast exact CLV, one view,
## single-sample G-buffer resources and a ready source-only queue consumer.
@export var native_deferred_general_queue_enabled := false

## Angular response-table resolution for the live free-space TransferMatrix volume.
## Higher values reduce SH directional approximation error at additional cache
## memory and per-light-change projection cost.
@export_range(8, 16, 4) var dynamic_volume_response_resolution := 8
## Cells per axis in each of the four prepared TransferMatrix CLV levels. Larger
## windows preserve .25m source spacing and extend coverage in every direction;
## memory, initial upload and relight work grow cubically. The default is 16.
## This controls layout 5 only, independently of legacy/experimental CLV caches.
@export_enum("16:16", "24:24", "32:32") var prepared_clv_resolution := 16
## Experimental cache-window size A/B. 16 remains the default; larger values
## expand every clipmap level while preserving the configured world-space cell spacing.
@export_range(16, 24, 8) var prt_clv_resolution := ClipmapCache.RESOLUTION
## Experimental ABI9 face-volume consumer. Keep disabled in normal projects until
## the suffix build and GPU quality/performance validation are complete.
@export var approximate_clv_volume_enabled := false
## Experimental approximate-lane tag fast path. The support readiness bit is
## published only after the complete logical 2x2x2 tag neighborhood is checked.
@export var approximate_clv_ready_bit_enabled := false
## Experimental exact static-BVH LOS for uncertified CLV corners. This A/B
## candidate starts at the stored radiance surface anchor and defaults off.
@export var exact_clv_corner_visibility_enabled := false
## Opt-in shader specialization for ordinary PRT. Keep false until validated.
@export var prt_fast_shader_variant_enabled := false
## Experimental two-dispatch PRT split. Disabled by default; unsupported paths use legacy.
@export var prt_two_stage_source_fallback_enabled := false
## Backup three-dispatch PRT split. Disabled by default; unsupported paths use legacy.
@export var prt_three_stage_source_fallback_enabled := false
## Opt-in single-queue compaction for uncertified PRT pixels. Requires a device
## subgroup ballot capability and the optional compact apply shader root.
@export var prt_compact_miss_queue_enabled := false
var _prt_stage_pipeline_signature := ""
var _prt_stage_pipelines: Dictionary = {}
var _prt_stage_pipeline_specialization_values: Dictionary = {}
var _prt_compact_shader_resource: RDShaderFile
var _prt_compact_shader_spirv: RDShaderSPIRV
var _prt_compact_shader := RID()
var _prt_compact_pipelines: Dictionary = {}
var _prt_compact_pipeline_specialization_values: Dictionary = {}
var _prt_compact_pipeline_signature := ""
var _native_general_queue_consumer_signature := ""
var _native_general_queue_uniform_set := RID()
var _prt_compact_finalize_shader_resource: RDShaderFile
var _prt_compact_finalize_shader_spirv: RDShaderSPIRV
var _prt_compact_finalize_shader := RID()
var _prt_compact_finalize_pipeline := RID()
var _prt_compact_finalize_pipeline_signature := ""
var _prt_compact_queue_buffer := RID()
var _prt_compact_queue_control_buffer := RID()
var _prt_compact_indirect_args_buffer := RID()
var _prt_compact_finalize_uniform_set := RID()
var _prt_compact_finalize_uniform_set_signature := ""
var _prt_compact_queue_capacity_pixels := 0
var _prt_compact_last_capability: Dictionary = {"status": "not_checked"}
var _prt_compact_dispatch_frame := -1
var _prt_compact_queue_metadata: Dictionary = {
	"enabled": false, "eligible": false, "active": false,
	"fallback_reason": "disabled", "active_stages": [],
	"dispatch_frame": -1, "indirect_dispatch_calls": 0,
	"queue_count": {"status": "not_read_back"},
	"overflow": {"status": "not_read_back"},
	"indirect_dimensions": {"status": "not_read_back"},
}
var _prt_source_pending_texture := RID()
var _prt_source_pending_size := Vector2i.ZERO
var _last_prt_two_stage_active := false
var _last_prt_two_stage_stage_values := PackedInt32Array([MAGIC_GI_PRT_STAGE_LEGACY])
var _last_prt_three_stage_active := false
var _last_prt_three_stage_stage_values := PackedInt32Array([MAGIC_GI_PRT_STAGE_LEGACY])
var _native_prepared_views: Dictionary = {}
var _native_baked_sh_prepared_views: Dictionary = {}
var _native_baked_sh_attempted_views: Dictionary = {}
var _native_baked_sh_publications: Dictionary = {}
var _native_baked_sh_publication_counter: int = 0
var _frame_native_baked_sh_consumed := false
var _frame_native_baked_sh_publication: Dictionary = {}
var _native_baked_sh_state: Dictionary = {"enabled": false, "active": false,
	"consumed": false, "frame": -1, "publication_token": 0,
	"status": "not_started", "fallback_reason": "not_started"}
var _frame_native_clv_fallback_only := false
var _frame_native_clv_status_known := false
var _frame_native_general_queue_active := false
var _frame_native_general_queue_msaa := -1
var _frame_native_general_queue_view_count := 0
var _native_general_queue_state: Dictionary = {
	"enabled": false, "preflight_ready": false, "active": false,
	"fallback_reason": "disabled", "frame": -1,
	"runtime_msaa": -1, "runtime_view_count": 0,
	"queue_capacity_pixels": 0, "consumer": "source_only_exact_gather",
}
var _last_native_clv_lighting_active := false
var _last_native_clv_lighting_qa_mode := -1
var _last_native_screen_cache_lighting_active := false
var _last_native_screen_cache_lighting_frame := -1
var _last_native_screen_cache_frame_token := -1
var _last_native_clv_owner_control_w := -1.0
var _last_native_clv_owner_parameters_rid := RID()
var _last_prt_shader_full_features := true
var _prt_hdr_readback_mutex := Mutex.new()
var _prt_hdr_readback_next_id := 0
var _prt_hdr_readback_pending_id := 0
var _prt_hdr_readback_request_frame := -1
var _prt_hdr_readback_kind := ""
var _prt_hdr_readback_result: Dictionary = {}
var _last_native_clv_lighting_frame := -1
var _last_native_prepare_cpu_usec := 0
var _native_prepare_diagnostics_enabled := false
var _last_native_prepare_rejection := "not_started"
var _last_native_prepare_frame := -1
var _last_native_prepare_owner_diagnostic := ""
var _last_prt_pass_cpu_usec := 0
var _last_frame_pre_exposure := 1.0
var _last_frame_scene_exposure_normalization := 1.0
var _last_exposure_frame := -1
## Runtime A/B switch for the exact empty-cell source lookup mask. The mask
## resource stays cached; false binds a zero dummy and runs the original lookup.
var probe_neighbor_mask_optimization_enabled := true
## Opt-in CSR list of ordered occupied source cells for each receiver cell.
## Runtime A/B toggle; enabling after upload rebuilds the cached list once.
@export var probe_neighbor_cell_list_optimization_enabled := false
var _native_owner_ubos: Array[RID] = [RID(), RID()]
var _native_owner_bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
var _native_gi_parameters_ubo := RID()
var _native_gi_parameters_bytes := PackedByteArray()
var _magicdawn_native_owner_ubos: Array[RID] = [RID(), RID()]
var _magicdawn_native_owner_bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
var _dynamic_volume_cache: Variant
var _dynamic_volume_cache_key := ""
var _dynamic_volume_source_instance_id := 0
var _dynamic_volume_publication_token := 0
var _dynamic_volume_runtime_state: Dictionary = {"status": "idle"}
var _dynamic_volume_debug: RefCounted
## Hidden RAM-only baked-SH QA selector. Modes 0..2 preserve their prior
## sampling behavior; mode 3 tests valid-weight normalization at the mode-0 point.
var _magicdawn_receiver_qa_mode := 0
## Hidden runner-only field codec selector: 0 prefers scaled R16F, 16 requires
## trying R16F, and 32 uses the unscaled R32F reference path.
var _magicdawn_field_format_override := 0

var _bake_resources: Dictionary = {}
var _cache_clock := 0
var _pre_exposure := 1.0
var _scene_exposure_normalization := 1.0
var _sky_diffuse_input: TextureInput
var _zero_sky_diffuse := RID()
var _replacement_request_prepared := false
var _frame_replacement_enabled := false
var _replacement_bridge_warning_shown := false
var _frame_diffuse_ao_texture := RID()
var _frame_input_bindings: Dictionary = {}
var _frame_view_matrices: Dictionary = {}
var _diffuse_ao_white := RID()
var _diffuse_ao_view_cache: Dictionary = {}
var _diffuse_ao_cache_clock := 0
var _page_residency: RefCounted
var _page_uploads: Dictionary = {}
var _page_ready_by_key: Dictionary = {}
var _page_failed_versions: Dictionary = {}
var _page_params_ubo := RID()
var _probe_cluster_fallback := RID()
var _probe_neighbor_mask_disabled := RID()
var _pending_page_params_ubo := RID()
var _pending_page_shader := RID()
var _pending_page_pipeline := RID()
var _prt_guide_shader := RID()
var _prt_guide_pipeline := RID()
var _prt_resolve_shader := RID()
var _prt_resolve_pipeline := RID()
var _prt_linear_sampler := RID()
var _prt_raw_views: Dictionary = {}
var _prt_profile_resource_log_count := 0
var _prt_raw_debug_output := false
## Temporary, opt-in exact-gather diagnostics for source-probe PRT comparisons.
## Values 100..105 are consumed by magic_gi_apply.glsl and ignored by normal frames.
var prt_surface_exact_debug_mode := 0
var prt_surface_exact_debug_output := RID()
var prt_surface_exact_debug_depth := RID()
var prt_surface_exact_debug_point_buffer := RID()
var prt_surface_exact_debug_pixel := Vector2i(-1, -1)
var prt_surface_exact_debug_last_mode := 0
var prt_surface_exact_debug_frame := 0
var prt_surface_exact_debug_capture_frame := -1
var _exact_point_debug_buffer := RID()
var _clv_stats_buffer := RID()
var _clv_stats_buffer_bytes := 0
var _clv_stats_capture_armed := false
var _clv_stats_capture_active := false
var _clv_stats_capture_frame := -1
var _magicdawn_stats_buffer := RID()
var _magicdawn_stats_capture_armed := false
var _magicdawn_stats_capture_active := false
var _magicdawn_stats_capture_frame := -1
var _magicdawn_stats_last_values := PackedInt32Array()
var _magicdawn_frame_active := false
var _magicdawn_clv_prt_frame := false
var _magicdawn_clv_prt_prepared := false
var _magicdawn_dynamic_output_cleared := false
var _magicdawn_unready_bake_warning_keys: Dictionary = {}
var _magicdawn_shader_saved: RDShaderFile
var _magicdawn_keywords_saved: Dictionary = {}
var _magicdawn_runtime_state: Dictionary = {}
var _magicdawn_debug_sidecar_forced := false
var _last_frame_ubo_bytes := PackedByteArray()
var _last_page_params_bytes := PackedByteArray()
var _clv_fallback_mode := -1
var _frame_prt_scale := 1
var _stream_frame_token := -1
var _stream_demand_frame_token := -1
var _stream_frame_demands: Dictionary = {}
var _stream_dispatch_active := false
var _stream_dispatch_rect := Rect2i()
var _stream_dispatch_extent := Vector2i()
var probe_cluster_culling_enabled := true
## Temporary, opt-in GPU timing around this pass's complete work. The default is
## off so normal frames do not consume timestamp queries.
var gpu_timestamp_profiling_enabled := false
var _gpu_timestamp_outer_only := false
## PRT gather scale. Scale 1 is the reference-quality default; higher scales
## gather from the current G-buffer at reduced resolution and resolve GI against
## full-resolution depth, normals, and receiver material data.
@export_enum("Full Resolution:1", "Half Resolution:2", "Quarter Resolution:4",
		"Eighth Resolution:8", "Sixteenth Resolution:16")
var prt_apply_scale: int = 1:
	set(value):
		var next := 1 if value <= 1 else (2 if value < 4 else (4 if value < 8 else (8 if value < 16 else 16)))
		if prt_apply_scale == next:
			return
		prt_apply_scale = next
		emit_changed()
@export var prt_resolve_fast_path := false:
	set(value):
		if prt_resolve_fast_path == value:
			return
		prt_resolve_fast_path = value
		emit_changed()
var _probe_cluster_payload_cache: Dictionary = {}
var _probe_cluster_payload_cache_bytes := 0
var _probe_cluster_payload_cache_clock := 0
var _probe_cluster_debug_frame := -1
var _probe_cluster_debug_bound_keys: Dictionary = {}
var _surfel_gpu: RefCounted
var _surfel_nrd: RefCounted
var _frame_surfel_inputs: Array[Dictionary] = []
var _frame_rtgi_snapshot: Dictionary = {}
var _surfel_runtime_start_queued := false
var _surfel_request_prepared := false
var _surfel_replacement_requested := false
var _surfel_nrd_frame_active := false
var _surfel_nrd_frame_fallback_reason := ""
var _surfel_warnings: Dictionary = {}
var _rtgi_runtime_script: Script
var _rtgi_runtime_script_checked := false

func get_indirect_gi_kind() -> StringName:
	return IndirectGISelection.KIND_MAGIC

func set_internal_clv_test_layout(layout_version: int) -> bool:
	if layout_version not in [CLV_INTERNAL_LAYOUT_AUTHORED,
			CLV_INTERNAL_LAYOUT13_TEST, CLV_INTERNAL_LAYOUT14_V0_TEST]:
		return false
	if layout_version != CLV_INTERNAL_LAYOUT14_V0_TEST \
			and _layout14_b_internal_test_enabled:
		set_internal_layout14_b_test_enabled(false)
	_clv_internal_test_layout = layout_version
	return true

## Runner-only receiver sampling control. Mode 4 preserves the active owner and
## its sky-replacement branch while bypassing receiver sampling for a paired
## zero-contribution cost baseline. Mode 5 colors native sampler hits magenta
## and misses cyan to validate the renderer route. Mode 6 forces only dynamic
## volume moment visibility to one; mode 7 also bypasses only the receiver-side
## gate, mode 8 preserves the original hard gate with moments visible, and mode
## 9 bypasses only sidedness while retaining the real moment visibility.
## None are exported.
func set_magicdawn_receiver_qa_mode_for_runner(mode: int) -> bool:
	if mode < 0 or mode > 9:
		return false
	_magicdawn_receiver_qa_mode = mode
	return true

## RAM-only GPU A/B selector. It is deliberately not an exported resource field.
func set_magicdawn_field_format_for_runner(format_tag: int) -> bool:
	if format_tag != 0 and format_tag != 16 and format_tag != 32:
		return false
	_magicdawn_field_format_override = format_tag
	return true

## Arms one explicit readback from the exact active layout-9 cache.
## This is a diagnostic-only operation; normal rendering never reads the cache back.
func request_magicdawn_active_cache_readback_for_runner() -> bool:
	_magicdawn_active_readback_armed = true
	_magicdawn_active_readback_context.clear()
	_magicdawn_active_readback_result.clear()
	_magicdawn_active_readback_queue_state.clear()
	return true

## Queues asynchronous reads after a completed frame. Never call synchronous RD readback
## from the render callback: on D3D12 it can invalidate the active command list.
func read_magicdawn_active_cache_readback_for_runner() -> Dictionary:
	if not _magicdawn_active_readback_armed:
		return {"started": false, "error": "readback_not_armed"}
	if _magicdawn_active_readback_context.is_empty():
		return {"started": false, "error": "active_cache_not_captured"}
	var context := _magicdawn_active_readback_context
	var prepared_value: Variant = context.get("prepared")
	var cache_value: Variant = context.get("cache")
	if not prepared_value is Dictionary or not cache_value is RefCounted:
		return {"started": false, "error": "active_cache_context_invalid"}
	var prepared: Dictionary = prepared_value
	var cache: RefCounted = cache_value
	# Freeze this frame's prepared/cache lease before scheduling async copies. Later
	# render callbacks must not replace the context while its readbacks are pending.
	_magicdawn_active_readback_armed = false
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return {"started": false, "error": "rendering_device_unavailable"}
	var resolution := int(cache.get("resolution"))
	if resolution not in [16, 24]:
		return {"started": false, "error": "active_cache_resolution_unsupported"}
	var cache_key := str(prepared.get("cache_key", ""))
	var bake: Dictionary = _bake_resources.get(cache_key, {})
	var directional_value: Variant = bake.get("directional")
	var bindings: Dictionary = {}
	if directional_value is RefCounted and directional_value.has_method("get_clv_transfer_bindings"):
		var bindings_value: Variant = directional_value.call("get_clv_transfer_bindings")
		if bindings_value is Dictionary:
			bindings = bindings_value
	context["input_bindings"] = bindings
	context["snapshot_lighting"] = _frame_snapshot.get("lighting", PackedFloat32Array()).duplicate()
	context["snapshot_sky"] = _frame_snapshot.get("sky_lighting", PackedFloat32Array()).duplicate()
	_magicdawn_active_readback_token += 1
	var token := _magicdawn_active_readback_token
	context["token"] = token
	context["readbacks"] = {}
	context["errors"] = {}
	context["pending"] = 0
	context["queued"] = 0
	context["request_frame"] = Engine.get_frames_drawn()
	var probes := int(bindings.get("probes", 0))
	var emitters := int(bindings.get("emitters", 0))
	var requests: Array[Dictionary] = [
		{"key": "params", "kind": "buffer", "rid": cache.get("parameters"), "size": 80},
		{"key": "ubo", "kind": "buffer", "rid": _ubo, "size": UBO_SIZE},
		{"key": "input_transfer", "kind": "buffer", "rid": bindings.get("transfer", RID()),
			"size": mini(probes * 243 * 4, 4096)},
		{"key": "input_sky", "kind": "buffer", "rid": bindings.get("sky", RID()),
			"size": mini(probes * 81 * 4, 4096)},
		{"key": "input_emission", "kind": "buffer", "rid": bindings.get("emission", RID()),
			"size": mini(probes * emitters * 54 * 4, 4096)},
		{"key": "input_sources", "kind": "buffer", "rid": bindings.get("sources", RID()),
			"size": mini(emitters * 6 * 4, 4096)}]
	for request in requests:
		var key := str(request.get("key", ""))
		var rid_value: Variant = request.get("rid", RID())
		if not rid_value is RID or not rid_value.is_valid():
			context["errors"][key] = "invalid_rid"
			continue
		var callback := Callable(self, "_magicdawn_active_cache_readback_callback").bind(token, key)
		var error := ERR_INVALID_PARAMETER
		if str(request.get("kind", "")) == "texture":
			error = rd.texture_get_data_async(rid_value, 0, callback)
		else:
			var request_size := int(request.get("size", 0))
			if request_size > 0:
				error = rd.buffer_get_data_async(rid_value, callback, 0, request_size)
		if error == OK:
			context["pending"] = int(context["pending"]) + 1
			context["queued"] = int(context["queued"]) + 1
		else:
			context["errors"][key] = error
	# Include a small, one-shot snapshot of representative receivers from the exact
	# prepared cache. The cache owns its diagnostic buffers/pipeline, and this context
	# keeps that cache lease alive until its asynchronous callback completes.
	var summary_error := ERR_UNAVAILABLE
	if cache.has_method("debug_summary_request"):
		var receivers: Array[Dictionary] = [
			{"name": "sphere_front", "world": Vector3(0.68, 0.68, 1.23), "normal": Vector3.BACK},
			{"name": "sphere_left", "world": Vector3(0.0, 0.68, 0.55), "normal": Vector3.LEFT},
			{"name": "sphere_bottom_contact", "world": Vector3(0.68, 0.0, 0.55), "normal": Vector3.DOWN},
			{"name": "back_wall_floor_corner", "world": Vector3(0.0, 0.02, -2.39), "normal": Vector3.BACK}]
		var summary_context := {"view": int(context.get("view", -1)),
			"frame": int(prepared.get("frame", -1)), "cache_key": cache_key,
			"request_frame": int(context.get("request_frame", -1)),
			"debug_view": int(clv_debug_view)}
		var summary_callback := Callable(self, "_magicdawn_active_cache_debug_summary_callback")
		summary_error = int(cache.call("debug_summary_request", rd, receivers,
			summary_callback, token, summary_context))
		if summary_error == OK:
			context["debug_summary_cache_lease"] = cache
			context["pending"] = int(context["pending"]) + 1
			context["queued"] = int(context["queued"]) + 1
		else:
			context["errors"]["debug_summary"] = {"code": summary_error,
				"state": cache.call("get_debug_summary_state") \
					if cache.has_method("get_debug_summary_state") else {}}
	else:
		context["errors"]["debug_summary"] = "active_cache_debug_summary_api_unavailable"
	if int(context["pending"]) == 0:
		_magicdawn_active_readback_context.clear()
		return {"started": false, "error": "no_readbacks_queued", "request_errors": context["errors"]}
	var status := {"started": true, "queued": int(context["queued"]),
		"request_frame": int(context["request_frame"]), "token": token,
		"debug_summary_error": summary_error, "request_errors": context["errors"]}
	_magicdawn_runtime_state["active_cache_readback_queue"] = status
	_magicdawn_active_readback_queue_state = status.duplicate(true)
	print("[CLV_ACTIVE_READBACK_QUEUED] " + JSON.stringify(status))
	return status

func _magicdawn_active_cache_readback_callback(data: PackedByteArray, token: int, key: String) -> void:
	# RenderingDevice owns/reuses its callback buffer. Copy before deferring to the main thread.
	call_deferred("_magicdawn_finish_active_cache_readback", data.duplicate(), token, key)

func _magicdawn_active_cache_debug_summary_callback(data: PackedByteArray,
		token: int, metadata: Dictionary) -> void:
	if token != _magicdawn_active_readback_token \
			or int(_magicdawn_active_readback_context.get("token", -1)) != token:
		return
	_magicdawn_active_readback_context["debug_summary_metadata"] = metadata.duplicate(true)
	# The cache already marshals this callback to the main thread. Reuse the same
	# request counter/finalizer so the active cache lease survives all readbacks.
	call_deferred("_magicdawn_finish_active_cache_readback", data.duplicate(),
		token, "debug_summary")

func _magicdawn_finish_active_cache_readback(data: PackedByteArray, token: int, key: String) -> void:
	if token != _magicdawn_active_readback_token \
			or int(_magicdawn_active_readback_context.get("token", -1)) != token:
		return
	var readbacks: Dictionary = _magicdawn_active_readback_context.get("readbacks", {})
	readbacks[key] = data
	_magicdawn_active_readback_context["readbacks"] = readbacks
	_magicdawn_active_readback_context["pending"] = maxi(0,
		int(_magicdawn_active_readback_context.get("pending", 0)) - 1)
	if int(_magicdawn_active_readback_context["pending"]) > 0:
		return
	var context := _magicdawn_active_readback_context
	var result := _magicdawn_read_active_clv_cache(context, readbacks)
	var summary_bytes: PackedByteArray = readbacks.get("debug_summary", PackedByteArray())
	if not summary_bytes.is_empty():
		result["representative_cache"] = _magicdawn_summarize_debug_summary(
			summary_bytes, context.get("debug_summary_metadata", {}))
	else:
		result["representative_cache"] = {"valid": false,
			"error": context.get("errors", {}).get("debug_summary", "debug_summary_callback_missing")}
	_magicdawn_runtime_state["active_cache_readback"] = result
	_magicdawn_active_readback_result = result.duplicate(true)
	_magicdawn_active_readback_queue_state = {
		"started": true, "completed": true, "queued": int(context.get("queued", 0)),
		"request_frame": int(context.get("request_frame", -1)),
		"callback_frame": int(context.get("callback_frame", -1)),
		"completion_frame": Engine.get_frames_drawn(),
		"token": token, "request_errors": context.get("errors", {}).duplicate(true)}
	print("[CLV_ACTIVE_READBACK] " + JSON.stringify(result))
	_magicdawn_active_readback_context.clear()
	_magicdawn_active_readback_armed = false


func _magicdawn_summarize_debug_summary(bytes: PackedByteArray,
		metadata_value: Variant) -> Dictionary:
	if not metadata_value is Dictionary:
		return {"valid": false, "error": "debug_summary_metadata_invalid"}
	var metadata: Dictionary = metadata_value
	var record_words := int(metadata.get("record_words", 0))
	var record_count := int(metadata.get("record_count", 0))
	var sample_count := int(metadata.get("sample_count", 0))
	var level_count := int(metadata.get("levels", 0))
	var corners_per_level := int(metadata.get("corners_per_level", 0))
	var expected_bytes := record_count * record_words * 4
	if int(metadata.get("snapshot_format_version", -1)) != 1 \
			or int(metadata.get("cache_layout_version", -1)) != 9 \
			or record_words != 194 or sample_count <= 0 or level_count != 3 \
			or corners_per_level != 8 \
			or record_count != sample_count * level_count * corners_per_level \
			or bytes.size() != expected_bytes:
		return {"valid": false, "error": "debug_summary_shape_or_version_mismatch",
			"actual_bytes": bytes.size(), "expected_bytes": expected_bytes,
			"metadata": metadata}
	var receivers_value: Variant = metadata.get("receivers", [])
	if not receivers_value is Array or receivers_value.size() != sample_count:
		return {"valid": false, "error": "debug_summary_receiver_metadata_mismatch"}
	var receiver_summaries: Array[Dictionary] = []
	for sample_index in sample_count:
		var receiver_value: Variant = receivers_value[sample_index]
		var receiver: Dictionary = receiver_value if receiver_value is Dictionary else {}
		var level_summaries: Array[Dictionary] = []
		for level in level_count:
			var counts := {"window": 0, "tag_match": 0, "axis_supported": 0,
				"stencil_count_valid": 0, "transfer_marker": 0, "neighbor_ready": 0,
				"relit_rgb_nonzero_corners": 0, "secondary_alpha_positive": 0,
				"primary_alpha_positive": 0}
			var corner_summaries: Array[Dictionary] = []
			for corner in corners_per_level:
				var record_index := sample_index * level_count * corners_per_level \
						+ level * corners_per_level + corner
				var word := record_index * record_words
				var flags := int(bytes.decode_u32((word + 4) * 4))
				var logical := Vector3i(bytes.decode_s32((word + 9) * 4),
					bytes.decode_s32((word + 10) * 4), bytes.decode_s32((word + 11) * 4))
				var tag := Vector4i(bytes.decode_s32((word + 13) * 4),
					bytes.decode_s32((word + 14) * 4), bytes.decode_s32((word + 15) * 4),
					bytes.decode_s32((word + 16) * 4))
				var support := int(bytes.decode_u32((word + 17) * 4))
				var stencil_count := int(bytes.decode_u32((word + 18) * 4))
				var stencil_marker := int(bytes.decode_u32((word + 19) * 4))
				var stencil_candidates := bytes.decode_float((word + 20) * 4)
				var stencil_visible := bytes.decode_float((word + 21) * 4)
				var transport_stats := _magicdawn_summary_read_vec4f(bytes, (word + 22) * 4)
				var sky_stats := _magicdawn_summary_read_vec4f(bytes, (word + 26) * 4)
				var emission_stats := _magicdawn_summary_read_vec4f(bytes, (word + 30) * 4)
				var relit_nonzero_rgb := 0
				var relit_max_abs_rgb := 0.0
				for coefficient in 18:
					var sh := _magicdawn_summary_read_vec4f(bytes, (word + 46 + coefficient * 4) * 4)
					for channel in 3:
						var absolute := absf(sh[channel])
						if absolute > 1e-20:
							relit_nonzero_rgb += 1
						relit_max_abs_rgb = maxf(relit_max_abs_rgb, absolute)
				var secondary := _magicdawn_summary_read_vec4f(bytes, (word + 118) * 4)
				var primary := _magicdawn_summary_read_vec4f(bytes, (word + 122) * 4)
				var metadata_vec := _magicdawn_summary_read_vec4f(bytes, (word + 126) * 4)
				var anchor := _magicdawn_summary_read_vec4f(bytes, (word + 130) * 4)
				var approx_geometry := _magicdawn_summary_read_vec4f(bytes, (word + 134) * 4)
				var plane_moments := _magicdawn_summary_read_vec4f(bytes, (word + 138) * 4)
				var fraction := _magicdawn_summary_read_vec4f(bytes, (word + 142) * 4)
				var first_blocker := "none"
				if (flags & 2) == 0:
					first_blocker = "window"
				elif (flags & 4) == 0:
					first_blocker = "tag_epoch"
				elif (flags & 8) == 0:
					first_blocker = "axis_support"
				elif (flags & 16) == 0:
					first_blocker = "stencil_count"
				elif (flags & 32) == 0:
					first_blocker = "transfer_marker"
				elif (flags & 64) == 0:
					first_blocker = "neighbor_tags"
				else:
					first_blocker = "candidate"
				if (flags & 2) != 0:
					counts["window"] = int(counts["window"]) + 1
				if (flags & 4) != 0:
					counts["tag_match"] = int(counts["tag_match"]) + 1
				if (flags & 8) != 0:
					counts["axis_supported"] = int(counts["axis_supported"]) + 1
				if (flags & 16) != 0:
					counts["stencil_count_valid"] = int(counts["stencil_count_valid"]) + 1
				if (flags & 32) != 0:
					counts["transfer_marker"] = int(counts["transfer_marker"]) + 1
				if (flags & 64) != 0:
					counts["neighbor_ready"] = int(counts["neighbor_ready"]) + 1
				if relit_nonzero_rgb > 0:
					counts["relit_rgb_nonzero_corners"] = int(counts["relit_rgb_nonzero_corners"]) + 1
				if secondary.w > 0.0:
					counts["secondary_alpha_positive"] = int(counts["secondary_alpha_positive"]) + 1
				if primary.w > 0.0:
					counts["primary_alpha_positive"] = int(counts["primary_alpha_positive"]) + 1
				var stencils: Array[Dictionary] = []
				for stencil_index in mini(stencil_count, 4):
					var stencil_word := word + 146 + stencil_index * 3
					stencils.append({"probe": int(bytes.decode_u32(stencil_word * 4)),
						"secondary_weight": bytes.decode_float((stencil_word + 1) * 4),
						"sky_weight": bytes.decode_float((stencil_word + 2) * 4)})
				corner_summaries.append({"corner": corner, "flags": flags,
					"valid": (flags & 1) != 0, "window": (flags & 2) != 0,
					"tag_match": (flags & 4) != 0, "axis_supported": (flags & 8) != 0,
					"stencil_count_valid": (flags & 16) != 0,
					"transfer_marker": (flags & 32) != 0,
					"neighbor_ready": (flags & 64) != 0,
					"first_blocker": first_blocker, "logical": logical, "tag": tag,
					"support": support, "stencil_count": stencil_count,
					"stencil_marker": stencil_marker,
					"stencil_candidates": stencil_candidates,
					"stencil_visible": stencil_visible,
					"transport_stats_nonzero_max_sum_nonfinite": transport_stats,
					"sky_stats_nonzero_max_sum_nonfinite": sky_stats,
					"emission_stats_nonzero_max_sum_nonfinite": emission_stats,
					"relit_rgb_nonzero": relit_nonzero_rgb,
					"relit_rgb_max_abs": relit_max_abs_rgb,
					"diffuse_secondary": secondary, "diffuse_primary": primary,
					"metadata": metadata_vec, "anchor": anchor,
					"approx_geometry": approx_geometry,
					"plane_moments": plane_moments, "fraction": fraction,
					"stencils_first4": stencils})
			level_summaries.append({"level": level, "counts": counts,
				"corners": corner_summaries})
		receiver_summaries.append({"name": str(receiver.get("name", "receiver_%d" % sample_index)),
			"world": receiver.get("world", Vector3.ZERO),
			"normal": receiver.get("normal", Vector3.UP), "levels": level_summaries})
	return {"valid": true, "snapshot_format_version": 1, "cache_layout_version": 9,
		"record_words": record_words, "record_count": record_count,
		"bytes": bytes.size(), "resolution": metadata.get("resolution", -1),
		"spacing": metadata.get("spacing", -1.0),
		"geometry_epoch": metadata.get("geometry_epoch", -1),
		"emitter_count": metadata.get("emitter_count", -1),
		"relight_serial": metadata.get("relight_serial", -1),
		"relight_lighting_revision": metadata.get("relight_lighting_revision", -1),
		"origins": metadata.get("origins", []), "context": metadata.get("context", {}),
		"receivers": receiver_summaries}

func _magicdawn_summary_read_vec4f(bytes: PackedByteArray, offset: int) -> Vector4:
	if offset < 0 or offset + 16 > bytes.size():
		return Vector4.ZERO
	return Vector4(bytes.decode_float(offset), bytes.decode_float(offset + 4),
		bytes.decode_float(offset + 8), bytes.decode_float(offset + 12))

func set_internal_layout14_b_test_enabled(enabled: bool) -> bool:
	if enabled and _clv_internal_test_layout != CLV_INTERNAL_LAYOUT14_V0_TEST:
		return false
	if enabled and _effective_clv_resolution() != 16:
		return false
	if enabled and (prt_apply_scale != 1 or prt_compact_miss_queue_enabled \
			or prt_two_stage_source_fallback_enabled \
			or prt_three_stage_source_fallback_enabled):
		return false
	if enabled:
		_layout14_b_apply_runtime_rejected = false
		if _layout14_b_saved_shader_file == null:
			if not shader_file is RDShaderFile:
				_layout14_b_error = "normal_apply_shader_unavailable"
				return false
			_layout14_b_saved_shader_file = shader_file as RDShaderFile
		_layout14_b_internal_test_enabled = true
		_layout14_b_error = "not_initialized"
		_ensure_layout14_b_apply_shader_resource()
	else:
		_layout14_b_internal_test_enabled = false
		_layout14_b_frame_active = false
		_layout14_b_frame_moments = RID()
		_layout14_b_frame_sampler = RID()
		_layout14_b_frame_tags = RID()
		_layout14_b_error = "disabled"
		if _layout14_b_saved_shader_file != null:
			shader_file = _layout14_b_saved_shader_file
	for entry_value in _clipmaps.values():
		if not entry_value is Dictionary:
			continue
		var cache: RefCounted = entry_value.get("cache")
		if cache != null and cache.has_method("set_internal_b_test_enabled"):
			cache.call("set_internal_b_test_enabled", _layout14_b_cache_requested())
	return true


func get_internal_layout14_b_test_state() -> Dictionary:
	return {"requested": _layout14_b_internal_test_enabled,
		"frame_active": _layout14_b_frame_active,
		"apply_shader_loaded": _layout14_b_apply_shader_resource != null,
		"error": _layout14_b_error,
		"sidecar_bytes": ProbeBlockFieldCache.estimate_node_visibility_gpu_bytes(
				_effective_clv_resolution()) if _layout14_b_cache_requested() else 0}


func _layout14_b_cache_requested() -> bool:
	return _layout14_b_internal_test_enabled \
			and _ensure_layout14_b_apply_shader_resource()


func _ensure_layout14_b_apply_shader_resource() -> bool:
	if _layout14_b_apply_runtime_rejected:
		return false
	if _layout14_b_apply_shader_resource == null:
		var shader_value: Resource = ResourceLoader.load(
				CLV_INTERNAL_LAYOUT14_B_APPLY_SHADER_PATH)
		if shader_value is RDShaderFile:
			_layout14_b_apply_shader_resource = shader_value as RDShaderFile
	if _layout14_b_apply_shader_resource == null:
		_layout14_b_error = "apply_shader_unavailable"
		return false
	var spirv: RDShaderSPIRV = _layout14_b_apply_shader_resource.get_spirv()
	if spirv == null or _layout14_b_apply_shader_resource.base_error != "" \
			or spirv.bytecode_compute.is_empty() or spirv.compile_error_compute != "":
		_layout14_b_error = "apply_shader_compile_error"
		return false
	return true


func _layout14_b_raw_source_ready(directional: RefCounted) -> bool:
	if directional == null or not directional.has_method("raw_sidecar_matches"):
		return false
	var raw_rid_value: Variant = directional.get("raw_lighting")
	if not raw_rid_value is RID:
		return false
	var raw_rid: RID = raw_rid_value
	var probe_count := int(directional.get("probes"))
	var expected_bytes := maxi(4, probe_count * 18 * 16)
	return raw_rid.is_valid() and probe_count > 0 \
			and int(directional.get("raw_lighting_bytes")) == expected_bytes \
			and bool(directional.call("raw_sidecar_matches", _frame_snapshot))

func _set_layout14_b_frame_active(active: bool, state: Dictionary = {}) -> void:
	_layout14_b_frame_active = active
	_layout14_b_frame_moments = RID()
	_layout14_b_frame_sampler = RID()
	_layout14_b_frame_tags = RID()
	if active:
		_layout14_b_frame_moments = state.get("moments", RID())
		_layout14_b_frame_sampler = state.get("sampler", RID())
		_layout14_b_frame_tags = state.get("tags", RID())
		shader_file = _layout14_b_apply_shader_resource
	else:
		if _layout14_b_saved_shader_file != null:
			shader_file = _layout14_b_saved_shader_file

func _clv_cache_backend(snapshot: Dictionary) -> int:
	if _clv_internal_test_layout == CLV_INTERNAL_LAYOUT13_TEST \
			or _clv_internal_test_layout == CLV_INTERNAL_LAYOUT14_V0_TEST:
		return CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART
	return int(snapshot.get("clv_cache_backend", CLV_CACHE_BACKEND_LEGACY))

func _clv_layout_version_for_backend(backend: int) -> int:
	if backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and _clv_internal_test_layout == CLV_INTERNAL_LAYOUT14_V0_TEST:
		return CLV_INTERNAL_LAYOUT14_V0_TEST
	if backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and _clv_internal_test_layout == CLV_INTERNAL_LAYOUT_AUTHORED:
		return CLV_MAGICDAWN_DYNAMIC_PRT_LAYOUT_VERSION
	return CLV_BLOCK_CHART_LAYOUT_VERSION \
			if backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART else CLV_LEGACY_LAYOUT_VERSION

func _clv_texture_columns_for_backend(backend: int) -> int:
	if backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and _clv_internal_test_layout == CLV_INTERNAL_LAYOUT14_V0_TEST:
		return ProbeBlockFieldCache.FIELD_COLUMN_COUNT
	if backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and _clv_internal_test_layout == CLV_INTERNAL_LAYOUT_AUTHORED:
		return ClipmapCache.CLV_TEXTURE_COLUMNS
	return CLV_BLOCK_CHART_COLUMN_COUNT \
			if backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART else ClipmapCache.CLV_TEXTURE_COLUMNS

func _clv_gpu_bytes_for_backend(backend: int, requested_resolution: int,
		requested_format_tag := -1, boundary_record_count := 0,
		dynamic_emitter_count := 0) -> int:
	if backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART:
		if _clv_internal_test_layout == CLV_INTERNAL_LAYOUT14_V0_TEST:
			var bytes := ProbeBlockFieldCache.estimate_field_gpu_bytes(requested_resolution)
			if _layout14_b_cache_requested():
				bytes += ProbeBlockFieldCache.estimate_node_visibility_gpu_bytes(requested_resolution)
			return bytes
		if _clv_internal_test_layout == CLV_INTERNAL_LAYOUT_AUTHORED:
			return ClipmapCache.estimate_gpu_bytes(requested_resolution, true,
				maxi(dynamic_emitter_count, 0))
		return MagicDawnBlockChartCache.estimate_block_gpu_bytes(requested_resolution)
	return ClipmapCache.estimate_gpu_bytes(requested_resolution)

func _new_clv_cache(backend: int):
	if backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART:
		if _clv_internal_test_layout == CLV_INTERNAL_LAYOUT14_V0_TEST:
			var cache := ProbeBlockFieldCache.new()
			cache.set_internal_b_test_enabled(_layout14_b_cache_requested())
			return cache
		if _clv_internal_test_layout == CLV_INTERNAL_LAYOUT_AUTHORED:
			return ClipmapCache.new()
		return MagicDawnBlockChartCache.new()
	return ClipmapCache.new()

func get_last_prt_compact_queue_metadata() -> Dictionary:
	var metadata := _prt_compact_queue_metadata.duplicate(true)
	metadata["metadata_sample_frame"] = Engine.get_frames_drawn()
	return metadata

func get_native_clv_lighting_state() -> Dictionary:
	var native_queue_state: Dictionary = _native_general_queue_state.duplicate(true)
	native_queue_state["consumer_pipeline_metadata"] = _native_general_source_queue_pipeline_metadata()
	var query_frame := Engine.get_frames_drawn()
	var last_frame := _last_native_clv_lighting_frame
	var frame_age := query_frame - last_frame if last_frame >= 0 else -1
	var frame_is_current := last_frame >= 0 and frame_age == 0
	var execution_qa_mode := _last_native_clv_lighting_qa_mode if frame_is_current else -1
	var status := "not_rendered"
	if last_frame >= 0:
		if frame_is_current:
			status = "active_on_current_frame" if _last_native_clv_lighting_active else "inactive_on_current_frame"
		else:
			status = "stale_last_execution"
	return {"active": _last_native_clv_lighting_active and frame_is_current,
		"last_execution_active": _last_native_clv_lighting_active,
		"frame": last_frame,
		"query_frame": query_frame,
		"frame_age": frame_age,
		"frame_is_current": frame_is_current,
		"receiver_sample_qa_mode": execution_qa_mode,
		"owner_control_w_from_published_buffer": _last_native_clv_owner_control_w \
				if frame_is_current else -1.0,
		"owner_parameters_rid_id": _last_native_clv_owner_parameters_rid.get_id() \
				if frame_is_current and _last_native_clv_owner_parameters_rid.is_valid() else 0,
		"owner_control_source": "same_owner_rid_published_to_clv_binding_58" \
				if frame_is_current and _last_native_clv_owner_parameters_rid.is_valid() else "unavailable",
		"consumer_sample_bypassed": frame_is_current and execution_qa_mode == 4,
		"consumer_sample_status": "matched_sky_zero_sample_baseline" \
				if frame_is_current and execution_qa_mode == 4 \
				else ("native_sample_hit_magenta_miss_cyan" \
				if frame_is_current and execution_qa_mode == 5 \
				else ("native_clv_sampling" if frame_is_current \
				and execution_qa_mode == 0 else "unverified")),
		"status": status,
		"approximate_clv_volume_enabled": approximate_clv_volume_enabled,
		"approximate_clv_ready_bit_enabled": approximate_clv_ready_bit_enabled,
		"exact_clv_corner_visibility_enabled": exact_clv_corner_visibility_enabled,
		"prt_shader_full_features": _last_prt_shader_full_features,
		"prt_fast_shader_variant_enabled": prt_fast_shader_variant_enabled,
		"prt_two_stage_source_fallback_enabled": prt_two_stage_source_fallback_enabled,
		"prt_two_stage_active": _last_prt_two_stage_active,
		"prt_two_stage_stage_values": Array(_last_prt_two_stage_stage_values),
		"prt_three_stage_source_fallback_enabled": prt_three_stage_source_fallback_enabled,
		"prt_three_stage_active": _last_prt_three_stage_active,
		"prt_three_stage_stage_values": Array(_last_prt_three_stage_stage_values),
		"prt_stage_pipeline_metadata": _prt_stage_pipeline_metadata(),
		"prt_compact_miss_queue": get_last_prt_compact_queue_metadata(),
		"native_general_queue": native_queue_state,
		"specialization_values": shader_keywords.duplicate(),
		"clv_cache_backend": _last_clv_cache_backend,
		"clv_layout_version": _clv_layout_version_for_backend(_last_clv_cache_backend),
		"clv_texture_columns": _clv_texture_columns_for_backend(_last_clv_cache_backend),
		"magicdawn": get_magicdawn_runtime_state(),
		"prepare_rejection": _last_native_prepare_rejection,
		"prepare_frame": _last_native_prepare_frame,
		"prepare_owner_diagnostic": _last_native_prepare_owner_diagnostic,
		"native_prepare_cpu_usec": _last_native_prepare_cpu_usec,
		"prt_pass_cpu_usec": _last_prt_pass_cpu_usec,
		"last_frame_pre_exposure": _last_frame_pre_exposure,
		"last_frame_scene_exposure_normalization": _last_frame_scene_exposure_normalization,
		"last_exposure_frame": _last_exposure_frame}

func get_native_baked_sh_lighting_state() -> Dictionary:
	return _native_baked_sh_state.duplicate(true)


func _native_general_source_queue_pipeline_metadata() -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	var pipeline: RID = _prt_compact_pipelines.get("native_general_source_queue", RID())
	var actual_values: Dictionary = _prt_compact_pipeline_specialization_values.get(
			"native_general_source_queue", {})
	var expected_values := _native_general_queue_consumer_values()
	var expected_signature := "%s|stage=native_general_source_queue|values=%s" % [
			_prt_compact_pipeline_signature, str(expected_values)]
	var actual_signature := _native_general_queue_consumer_signature
	var pipeline_valid := _prt_compact_pipeline_is_valid(rd, pipeline)
	return {"stage": "native_general_source_queue",
		"rid": _prt_compact_rid_id(pipeline),
		"shader_resource": MAGIC_GI_PRT_QUEUE_APPLY_SHADER_PATH,
		"shader_rid": _prt_compact_rid_id(_prt_compact_shader),
		"specialization_values": actual_values.duplicate(true),
		"expected_specialization_values": expected_values,
		"signature": actual_signature,
		"expected_signature": expected_signature,
		"valid": pipeline_valid,
		"signature_matches": pipeline_valid and actual_signature == expected_signature \
				and actual_values == expected_values}


## Request an untimed, one-shot readback of the production magic_gi RGBA16F output.
## This does not alter shader settings or force the full specialization; result metadata
## records the actual frame's selected specialization. Poll the returned request_id.
func request_prt_linear_output_readback() -> Dictionary:
	var debug_mode := prt_apply_scale != 1
	debug_mode = debug_mode or clv_debug_view != CLVDebugView.OFF
	debug_mode = debug_mode or _prt_raw_debug_output
	debug_mode = debug_mode or _clv_stats_capture_armed or _clv_stats_capture_active
	debug_mode = debug_mode or prt_surface_exact_debug_mode != 0
	if debug_mode:
		return {"accepted": false, "error": "Readback requires ordinary scale-1 PRT mode"}
	if gpu_timestamp_profiling_enabled:
		return {"accepted": false, "error": "Disable timing before requesting a synchronous output readback"}
	_prt_hdr_readback_mutex.lock()
	if _prt_hdr_readback_pending_id != 0:
		_prt_hdr_readback_mutex.unlock()
		return {"accepted": false, "error": "A production-output readback is already pending"}
	_prt_hdr_readback_next_id += 1
	_prt_hdr_readback_pending_id = _prt_hdr_readback_next_id
	_prt_hdr_readback_request_frame = Engine.get_frames_drawn()
	_prt_hdr_readback_kind = "prt_linear"
	_prt_hdr_readback_result = {"request_id": _prt_hdr_readback_pending_id, "pending": true}
	var request_id := _prt_hdr_readback_pending_id
	_prt_hdr_readback_mutex.unlock()
	return {"accepted": true, "request_id": request_id}

func get_prt_linear_output_readback(request_id: int) -> Dictionary:
	_prt_hdr_readback_mutex.lock()
	var result: Dictionary = _prt_hdr_readback_result.duplicate()
	var pending_id := _prt_hdr_readback_pending_id
	var request_frame := _prt_hdr_readback_request_frame
	if int(result.get("request_id", -1)) == request_id \
			and str(result.get("readback_kind", "prt_linear")) != "prt_linear":
		_prt_hdr_readback_mutex.unlock()
		return {"request_id": request_id, "pending": false, "valid": false,
			"error": "Request is for scene HDR, not the PRT sidecar"}
	if pending_id == request_id and Engine.get_frames_drawn() - request_frame > 120:
		_prt_hdr_readback_result = {"request_id": request_id, "pending": false,
			"valid": false, "error": "Readback timed out before an ordinary PRT frame"}
		_prt_hdr_readback_pending_id = 0
		_prt_hdr_readback_kind = ""
		pending_id = 0
		result = _prt_hdr_readback_result.duplicate()
	_prt_hdr_readback_mutex.unlock()
	if int(result.get("request_id", -1)) != request_id:
		return {"valid": false, "pending": false, "error": "Unknown readback request id"}
	result["pending"] = pending_id == request_id
	return result

## Request one untimed readback of the internal scene-color HDR after this pass.
## This is distinct from the PRT sidecar readback: it includes native deferred
## contributions and the post-lighting compute result at this pass boundary.
func request_prt_scene_hdr_readback() -> Dictionary:
	var debug_mode := prt_apply_scale != 1
	debug_mode = debug_mode or clv_debug_view != CLVDebugView.OFF
	debug_mode = debug_mode or _prt_raw_debug_output
	debug_mode = debug_mode or _clv_stats_capture_armed or _clv_stats_capture_active
	debug_mode = debug_mode or prt_surface_exact_debug_mode != 0
	if debug_mode:
		return {"accepted": false, "error": "Scene HDR readback requires ordinary scale-1 PRT mode"}
	if gpu_timestamp_profiling_enabled:
		return {"accepted": false, "error": "Disable GPU timing before synchronous scene HDR readback"}
	_prt_hdr_readback_mutex.lock()
	if _prt_hdr_readback_pending_id != 0:
		_prt_hdr_readback_mutex.unlock()
		return {"accepted": false, "error": "A PRT readback request is already pending"}
	_prt_hdr_readback_next_id += 1
	_prt_hdr_readback_pending_id = _prt_hdr_readback_next_id
	_prt_hdr_readback_request_frame = Engine.get_frames_drawn()
	_prt_hdr_readback_kind = "scene_hdr"
	_prt_hdr_readback_result = {"request_id": _prt_hdr_readback_pending_id,
		"pending": true, "readback_kind": _prt_hdr_readback_kind}
	var request_id := _prt_hdr_readback_pending_id
	_prt_hdr_readback_mutex.unlock()
	return {"accepted": true, "request_id": request_id}

func get_prt_scene_hdr_readback(request_id: int) -> Dictionary:
	_prt_hdr_readback_mutex.lock()
	var result: Dictionary = _prt_hdr_readback_result.duplicate()
	var pending_id := _prt_hdr_readback_pending_id
	var request_frame := _prt_hdr_readback_request_frame
	if int(result.get("request_id", -1)) == request_id \
			and str(result.get("readback_kind", "")) != "scene_hdr":
		_prt_hdr_readback_mutex.unlock()
		return {"request_id": request_id, "pending": false, "valid": false,
			"error": "Request is not for scene HDR"}
	if pending_id == request_id and Engine.get_frames_drawn() - request_frame > 120:
		_prt_hdr_readback_result = {"request_id": request_id, "pending": false,
			"readback_kind": "scene_hdr", "valid": false,
			"error": "Readback timed out before an ordinary Magic GI frame"}
		_prt_hdr_readback_pending_id = 0
		_prt_hdr_readback_kind = ""
		pending_id = 0
		result = _prt_hdr_readback_result.duplicate()
	_prt_hdr_readback_mutex.unlock()
	if int(result.get("request_id", -1)) != request_id:
		return {"request_id": request_id, "valid": false, "pending": false,
			"error": "Unknown readback request id"}
	result["pending"] = pending_id == request_id
	return result

func _service_prt_linear_output_readback(output: RID, view: int,
		rd: RenderingDevice) -> void:
	if view != 0:
		return
	_prt_hdr_readback_mutex.lock()
	var request_id := _prt_hdr_readback_pending_id
	var readback_kind := _prt_hdr_readback_kind
	_prt_hdr_readback_mutex.unlock()
	if request_id == 0 or readback_kind != "prt_linear":
		return
	var result := {
		"request_id": request_id,
		"frame": Engine.get_frames_drawn(),
		"process_frame": Engine.get_process_frames(),
		"view": view,
		"prt_fast_shader_variant_enabled": prt_fast_shader_variant_enabled,
		"prt_shader_full_features": _last_prt_shader_full_features,
		"specialization_constant_0": shader_keywords.get(MAGIC_GI_FULL_FEATURES_SPEC_ID, true),
		"specialization_constant_1_stages": Array(_last_prt_two_stage_stage_values),
		"specialization_constant_2": shader_keywords.get(2, null),
		"prt_two_stage_source_fallback_enabled": prt_two_stage_source_fallback_enabled,
		"prt_two_stage_active": _last_prt_two_stage_active,
		"prt_three_stage_source_fallback_enabled": prt_three_stage_source_fallback_enabled,
		"prt_three_stage_active": _last_prt_three_stage_active,
		"prt_three_stage_stage_values": Array(_last_prt_three_stage_stage_values),
		"specialization_values": shader_keywords.duplicate(),
		"prt_stage_pipeline_metadata": _prt_stage_pipeline_metadata(),
		"pre_exposure": _last_frame_pre_exposure,
		"scene_exposure_normalization": _last_frame_scene_exposure_normalization,
		"format": -1,
		"width": 0,
		"height": 0,
		"depth": 0,
		"texture_type": -1,
		"samples": 0,
		"usage_bits": 0,
		"copy_from": false,
		"expected_bytes": 0,
		"bytes_size": 0,
		"shader_compile_error_compute": "",
		"compute_bytecode_size": 0,
		"shader_valid": false,
		"compute_pipeline_valid": false,
		"binding_error": _binding_error,
		"prt_compact_queue_diagnostic": {"status": "not_requested"},
		"bytes": PackedByteArray(),
		"valid": false
	}
	var shader_compile_error := "Shader resource unavailable"
	var compute_bytecode_size := 0
	if shader_file != null:
		var spirv: RDShaderSPIRV = shader_file.get_spirv()
		if spirv != null:
			shader_compile_error = spirv.compile_error_compute
			compute_bytecode_size = spirv.bytecode_compute.size()
	var shader_valid := _shader.is_valid()
	var compute_pipeline_valid := _compute_pipeline.is_valid()
	result["shader_compile_error_compute"] = shader_compile_error
	result["compute_bytecode_size"] = compute_bytecode_size
	result["shader_valid"] = shader_valid
	result["compute_pipeline_valid"] = compute_pipeline_valid
	var execution_valid := shader_compile_error.is_empty() and compute_bytecode_size > 0
	execution_valid = execution_valid and shader_valid and compute_pipeline_valid and not _binding_error
	var frame_debug_mode := _frame_prt_scale != 1
	frame_debug_mode = frame_debug_mode or clv_debug_view != CLVDebugView.OFF
	frame_debug_mode = frame_debug_mode or _prt_raw_debug_output
	frame_debug_mode = frame_debug_mode or _clv_stats_capture_active or _clv_stats_capture_armed
	frame_debug_mode = frame_debug_mode or prt_surface_exact_debug_mode != 0
	frame_debug_mode = frame_debug_mode or gpu_timestamp_profiling_enabled
	if frame_debug_mode:
		result["error"] = "Readback frame was debug, raw, scaled, stats, or timed"
	elif rd == null or not output.is_valid() or not rd.texture_is_valid(output):
		result["error"] = "Production magic_gi output RID is invalid"
	else:
		var texture_format: RDTextureFormat = rd.texture_get_format(output)
		result["format"] = texture_format.format
		result["width"] = texture_format.width
		result["height"] = texture_format.height
		result["depth"] = texture_format.depth
		result["texture_type"] = texture_format.texture_type
		result["samples"] = texture_format.samples
		result["usage_bits"] = texture_format.usage_bits
		var copy_from := (texture_format.usage_bits & RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT) != 0
		result["copy_from"] = copy_from
		var expected_bytes := texture_format.width * texture_format.height * 8
		result["expected_bytes"] = expected_bytes
		var format_valid := texture_format.texture_type == RenderingDevice.TEXTURE_TYPE_2D
		format_valid = format_valid and texture_format.format == RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format_valid = format_valid and texture_format.depth == 1
		format_valid = format_valid and texture_format.samples == RenderingDevice.TEXTURE_SAMPLES_1
		format_valid = format_valid and texture_format.width > 0 and texture_format.height > 0 and copy_from
		if format_valid:
			var payload: PackedByteArray = rd.texture_get_data(output, 0)
			result["bytes"] = payload
			result["bytes_size"] = payload.size()
			result["valid"] = payload.size() == expected_bytes and execution_valid
			if not result["valid"]:
				result["error"] = "Output bytes, shader/pipeline state, or compute binding validation failed"
		else:
			result["error"] = "magic_gi output is not a copyable 2D RGBA16F texture"
	if not frame_debug_mode and bool(result.get("valid", false)):
		result["prt_compact_queue_diagnostic"] = _read_prt_compact_queue_diagnostic(rd,
				int(result["frame"]))
	_prt_hdr_readback_mutex.lock()
	if _prt_hdr_readback_pending_id == request_id:
		_prt_hdr_readback_result = result
		_prt_hdr_readback_pending_id = 0
		_prt_hdr_readback_kind = ""
	_prt_hdr_readback_mutex.unlock()

func _complete_prt_scene_hdr_readback_error(reason: String) -> void:
	_prt_hdr_readback_mutex.lock()
	var request_id := _prt_hdr_readback_pending_id
	var readback_kind := _prt_hdr_readback_kind
	if request_id != 0 and readback_kind == "scene_hdr":
		_prt_hdr_readback_result = {
			"request_id": request_id,
			"readback_kind": "scene_hdr",
			"pending": false,
			"valid": false,
			"frame": Engine.get_frames_drawn(),
			"error": reason
		}
		_prt_hdr_readback_pending_id = 0
		_prt_hdr_readback_kind = ""
	_prt_hdr_readback_mutex.unlock()

func _service_prt_scene_hdr_readback(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice) -> void:
	_prt_hdr_readback_mutex.lock()
	var request_id := _prt_hdr_readback_pending_id
	var request_frame := _prt_hdr_readback_request_frame
	var readback_kind := _prt_hdr_readback_kind
	_prt_hdr_readback_mutex.unlock()
	if request_id == 0 or readback_kind != "scene_hdr":
		return
	if view != 0:
		return
	var frame := Engine.get_frames_drawn()
	var result := {
		"request_id": request_id,
		"readback_kind": "scene_hdr",
		"request_frame": request_frame,
		"frame": frame,
		"process_frame": Engine.get_process_frames(),
		"exposure_frame": _last_exposure_frame,
		"view": view,
		"data_domain": "internal_scene_color_hdr_after_magic_gi_before_tonemap",
		"exposure_encoding": "stored render-buffer values; no exposure normalization applied by readback",
		"readback_call_site": "after_apply_end_capture",
		"gpu_timestamp_profiling_enabled": gpu_timestamp_profiling_enabled,
		"pre_exposure": _last_frame_pre_exposure,
		"scene_exposure_normalization": _last_frame_scene_exposure_normalization,
		"native_clv_status_known": _frame_native_clv_status_known,
		"native_clv_active": _frame_native_clv_fallback_only,
		"native_clv_frame": frame if _frame_native_clv_status_known else -1,
		"native_clv_active_same_frame": _frame_native_clv_status_known,
		"native_clv_state_source": "FRPPassContext.is_magic_gi_clv_lighting_active sampled before this pass",
		"prt_fast_shader_variant_enabled": prt_fast_shader_variant_enabled,
		"prt_shader_full_features": _last_prt_shader_full_features,
		"specialization_values": shader_keywords.duplicate(true),
		"prt_two_stage_active": _last_prt_two_stage_active,
		"prt_two_stage_stage_values": Array(_last_prt_two_stage_stage_values),
		"prt_three_stage_active": _last_prt_three_stage_active,
		"prt_three_stage_stage_values": Array(_last_prt_three_stage_stage_values),
		"prt_stage_pipeline_metadata": _prt_stage_pipeline_metadata(),
		"binding_error": _binding_error,
		"shader_valid": _shader.is_valid(),
		"compute_pipeline_valid": _compute_pipeline.is_valid(),
		"source_is_pass_color_storage_image": false,
		"scene_color_rid_valid": false,
		"resolved_color_layer_match": false,
		"msaa_color_layer_present": false,
		"resolve_status": "not_checked",
		"format": -1,
		"expected_format": RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		"width": 0,
		"height": 0,
		"internal_width": 0,
		"internal_height": 0,
		"size_matches_internal": false,
		"depth": 0,
		"texture_type": -1,
		"samples": 0,
		"usage_bits": 0,
		"copy_from": false,
		"expected_bytes": 0,
		"bytes_size": 0,
		"bytes": PackedByteArray(),
		"valid": false
	}
	var frame_debug_mode := _frame_prt_scale != 1
	frame_debug_mode = frame_debug_mode or clv_debug_view != CLVDebugView.OFF
	frame_debug_mode = frame_debug_mode or _prt_raw_debug_output
	frame_debug_mode = frame_debug_mode or _clv_stats_capture_active or _clv_stats_capture_armed
	frame_debug_mode = frame_debug_mode or prt_surface_exact_debug_mode != 0
	frame_debug_mode = frame_debug_mode or gpu_timestamp_profiling_enabled
	if frame_debug_mode:
		result["error"] = "Scene HDR readback frame was debug, raw, scaled, stats, exact-debug, or timed"
	elif bool(_frame_snapshot.get("surfel", false)):
		result["error"] = "Scene HDR readback does not support the surfel pass path"
	elif bool(_frame_snapshot.get("streamed", false)):
		result["error"] = "Scene HDR readback does not support the streamed pass path"
	elif buffers == null or rd == null:
		result["error"] = "Scene HDR readback has no render buffers or RenderingDevice"
	else:
		var pass_color_input := inputs.size() > 0 \
				and inputs[0].source == TextureInput.Source.COLOR \
				and inputs[0].binding_type == TextureInput.BindingType.STORAGE_IMAGE
		var scene_color: RID = inputs[0].get_texture(buffers, view) if pass_color_input else RID()
		var resolved_color: RID = buffers.get_color_layer(view, false)
		var msaa_color: RID = buffers.get_color_layer(view, true)
		var scene_color_valid := scene_color.is_valid() and rd.texture_is_valid(scene_color)
		var resolved_color_valid := resolved_color.is_valid() and rd.texture_is_valid(resolved_color)
		var msaa_color_valid := msaa_color.is_valid() and rd.texture_is_valid(msaa_color)
		result["source_is_pass_color_storage_image"] = pass_color_input
		result["scene_color_rid_valid"] = scene_color_valid
		result["resolved_color_layer_match"] = scene_color_valid and resolved_color_valid \
				and scene_color == resolved_color
		result["msaa_color_layer_present"] = msaa_color_valid
		if not pass_color_input:
			result["error"] = "Magic GI input 0 is not the COLOR storage-image declaration"
		elif not scene_color_valid:
			result["error"] = "Post-MagicGI scene-color RID is invalid"
		elif not bool(result["resolved_color_layer_match"]):
			result["resolve_status"] = "pass input does not match RenderSceneBuffersRD resolved color layer"
			result["error"] = "Scene-color resolve layer could not be proven"
		else:
			var texture_format: RDTextureFormat = rd.texture_get_format(scene_color)
			var internal_size: Vector2i = buffers.get_internal_size()
			result["format"] = texture_format.format
			result["width"] = texture_format.width
			result["height"] = texture_format.height
			result["internal_width"] = internal_size.x
			result["internal_height"] = internal_size.y
			result["depth"] = texture_format.depth
			result["texture_type"] = texture_format.texture_type
			result["samples"] = texture_format.samples
			result["usage_bits"] = texture_format.usage_bits
			var copy_from := (texture_format.usage_bits & RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT) != 0
			result["copy_from"] = copy_from
			var expected_bytes := texture_format.width * texture_format.height * 8
			result["expected_bytes"] = expected_bytes
			var size_matches := texture_format.width == internal_size.x \
					and texture_format.height == internal_size.y
			result["size_matches_internal"] = size_matches
			var format_valid := texture_format.texture_type == RenderingDevice.TEXTURE_TYPE_2D
			format_valid = format_valid and texture_format.format == RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
			format_valid = format_valid and texture_format.depth == 1
			format_valid = format_valid and texture_format.samples == RenderingDevice.TEXTURE_SAMPLES_1
			format_valid = format_valid and texture_format.width > 0 and texture_format.height > 0
			format_valid = format_valid and size_matches and copy_from
			result["resolve_status"] = "resolved_single_sample_color_layer" \
					if texture_format.samples == RenderingDevice.TEXTURE_SAMPLES_1 else "not_resolved_single_sample"
			if not format_valid:
				result["error"] = "Scene HDR requires copyable 2D RGBA16F resolved color at internal size"
			else:
				var payload: PackedByteArray = rd.texture_get_data(scene_color, 0)
				result["bytes"] = payload
				result["bytes_size"] = payload.size()
				result["valid"] = payload.size() == expected_bytes
				if not result["valid"]:
					result["error"] = "Scene HDR readback byte count did not match RGBA16F dimensions"
	_prt_hdr_readback_mutex.lock()
	if _prt_hdr_readback_pending_id == request_id and _prt_hdr_readback_kind == "scene_hdr":
		_prt_hdr_readback_result = result
		_prt_hdr_readback_pending_id = 0
		_prt_hdr_readback_kind = ""
	_prt_hdr_readback_mutex.unlock()

func _read_prt_compact_queue_diagnostic(rd: RenderingDevice,
		sample_frame: int) -> Dictionary:
	var metadata := _prt_compact_queue_metadata
	if not bool(metadata.get("active", false)):
		return {"status": "not_active", "dispatch_frame": int(metadata.get("dispatch_frame", -1)),
			"metadata_sample_frame": sample_frame}
	var dispatch_frame := int(metadata.get("dispatch_frame", -1))
	if dispatch_frame < 0 or dispatch_frame != sample_frame \
			or dispatch_frame != _last_native_clv_lighting_frame:
		return {"status": "frame_mismatch", "dispatch_frame": dispatch_frame,
			"metadata_sample_frame": sample_frame,
			"native_draw_frame": _last_native_clv_lighting_frame}
	if rd == null or not _prt_compact_queue_control_buffer.is_valid() \
			or not _prt_compact_indirect_args_buffer.is_valid():
		return {"status": "buffer_unavailable", "dispatch_frame": dispatch_frame,
			"metadata_sample_frame": sample_frame}
	var control := rd.buffer_get_data(_prt_compact_queue_control_buffer, 0,
			MAGIC_GI_PRT_QUEUE_CONTROL_BYTES)
	var args := rd.buffer_get_data(_prt_compact_indirect_args_buffer, 0,
			MAGIC_GI_PRT_QUEUE_INDIRECT_BYTES)
	if control.size() != MAGIC_GI_PRT_QUEUE_CONTROL_BYTES \
			or args.size() != MAGIC_GI_PRT_QUEUE_INDIRECT_BYTES:
		return {"status": "readback_size_mismatch", "dispatch_frame": dispatch_frame,
			"metadata_sample_frame": sample_frame,
			"control_bytes": control.size(), "args_bytes": args.size()}
	var count := int(control.decode_u32(0))
	var overflow := int(control.decode_u32(4))
	var dimensions := [int(args.decode_u32(0)), int(args.decode_u32(4)),
		int(args.decode_u32(8))]
	var expected_x := maxi(1, _prt_compact_ceil_div(count, MAGIC_GI_PRT_QUEUE_LOCAL_INVOCATIONS))
	var normal_dimensions_match_count: Variant = null
	var expected_overflow_dimensions: Variant = null
	var overflow_dimensions_match_full_view: Variant = null
	if overflow == 0:
		normal_dimensions_match_count = dimensions == [expected_x, 1, 1]
	else:
		var dispatch_size: Array = metadata.get("dispatch_size", [])
		if dispatch_size.size() == 2:
			expected_overflow_dimensions = [
				maxi(1, _prt_compact_ceil_div(int(dispatch_size[0]), MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE)),
				maxi(1, _prt_compact_ceil_div(int(dispatch_size[1]), MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE)),
				1,
			]
			overflow_dimensions_match_full_view = dimensions == expected_overflow_dimensions
	return {"status": "read_back", "dispatch_frame": dispatch_frame,
		"metadata_sample_frame": sample_frame, "count": count, "overflow": overflow,
		"indirect_dimensions": dimensions,
		"capacity_pixels": _prt_compact_queue_capacity_pixels,
		"count_positive": count > 0,
		"count_within_capacity": count <= _prt_compact_queue_capacity_pixels,
		"overflow_zero": overflow == 0,
		"expected_normal_dimensions": [expected_x, 1, 1],
		"normal_dimensions_match_count": normal_dimensions_match_count,
		"expected_overflow_dimensions": expected_overflow_dimensions,
		"overflow_dimensions_match_full_view": overflow_dimensions_match_full_view}

func set_native_prepare_diagnostics_enabled(enabled: bool) -> void:
	_native_prepare_diagnostics_enabled = enabled
	_last_native_prepare_rejection = "not_started"
	_last_native_prepare_frame = -1
	_last_native_prepare_owner_diagnostic = ""

func _set_native_prepare_rejection(reason: String) -> void:
	if _native_prepare_diagnostics_enabled:
		_last_native_prepare_rejection = reason

## Read-only profiling view of the active CLV scheduler. The bake's source probes
## stay surface-anchored; these are separate, camera-relative lighting cache cells.
func get_prt_clv_runtime_state() -> Dictionary:
	var caches: Array[Dictionary] = []
	var raw_sidecars_by_bake: Dictionary = {}
	for key in _clipmaps:
		var entry: Dictionary = _clipmaps[key]
		var cache: RefCounted = entry.get("cache")
		if cache == null:
			continue
		var pending_value: Variant = cache.get("_pending")
		var pending_cursor := int(cache.get("_cursor"))
		var pending_count := 0
		if pending_value is Array:
			pending_count = maxi((pending_value as Array).size() - pending_cursor, 0)
		var origins_value: Variant = cache.get("_origins")
		var texture_rid: RID = cache.get("texture")
		var tags_rid: RID = cache.get("tags")
		var support_rid: RID = cache.get("support")
		var cache_backend := int(entry.get("cache_backend", CLV_CACHE_BACKEND_LEGACY))
		var layout14_state: Dictionary = {}
		if cache.has_method("get_layout14_runtime_state"):
			var layout14_value: Variant = cache.call("get_layout14_runtime_state")
			if layout14_value is Dictionary:
				layout14_state = layout14_value
		var layout_state: Dictionary = {}
		if cache.has_method("get_layout16_runtime_state"):
			var layout_value: Variant = cache.call("get_layout16_runtime_state")
			if layout_value is Dictionary:
				layout_state = layout_value
		var bake_key := str(entry.get("bake", ""))
		var raw_sidecar_allocated := false
		var raw_sidecar_estimated_bytes := 0
		if not bake_key.is_empty() and _bake_resources.has(bake_key):
			var bake_resource_value: Variant = _bake_resources[bake_key]
			if bake_resource_value is Dictionary:
				var directional_value: Variant = bake_resource_value.get("directional")
				if directional_value is RefCounted:
					raw_sidecar_estimated_bytes = int(directional_value.get("raw_lighting_bytes"))
					var raw_rid_value: Variant = directional_value.get("raw_lighting")
					raw_sidecar_allocated = raw_rid_value is RID and raw_rid_value.is_valid()
					if not raw_sidecars_by_bake.has(bake_key):
						raw_sidecars_by_bake[bake_key] = {
							"bake_key": bake_key,
							"allocated": raw_sidecar_allocated,
							"estimated_bytes": raw_sidecar_estimated_bytes,
							"allocated_bytes": raw_sidecar_estimated_bytes if raw_sidecar_allocated else 0}
		caches.append({"pending_cells": pending_count,
			"origin_count": origins_value.size() if origins_value is Array else 0,
			"origins_cells": origins_value.duplicate() if origins_value is Array else [],
			"origins_hash": hash(origins_value) if origins_value is Array else 0,
			"spacing_m": float(cache.get("_spacing")),
			"resolution": int(cache.get("resolution")),
			"parameter_resolution": int(cache.get("parameter_resolution")),
			"requested_resolution": prt_clv_resolution,
			"gpu_bytes": int(entry.get("gpu_bytes",
					_clv_gpu_bytes_for_backend(cache_backend, int(cache.get("resolution"))))),
			"geometry_epoch": int(cache.get("_geometry_epoch")),
			"content_revision": int(cache.get("_content_revision")),
			"cache_backend": cache_backend,
			"layout_version": _clv_layout_version_for_backend(cache_backend),
			"texture_columns": _clv_texture_columns_for_backend(cache_backend),
			"texture_valid": texture_rid.is_valid(),
			"tags_valid": tags_rid.is_valid(),
			"support_valid": support_rid.is_valid(),
			"layout14_runtime_state": layout14_state,
			"layout16_runtime_state": layout_state,
			"layout17_runtime_state": layout_state,
			"field_format_tag": int(entry.get("field_format_tag", 0)),
			"field_codec": entry.get("field_codec", Vector4.ZERO),
			"field_codec_fallback_reason": str(entry.get("field_codec_fallback_reason", "")),
			"field_format_override": int(entry.get("field_format_override", -1)),
			"raw_sidecar_allocated": raw_sidecar_allocated,
			"raw_sidecar_estimated_bytes": raw_sidecar_estimated_bytes,
			"raw_sidecar_allocated_bytes": raw_sidecar_estimated_bytes \
					if raw_sidecar_allocated else 0})
	var raw_sidecar_estimated_total := 0
	var raw_sidecar_allocated_total := 0
	for raw_state_value in raw_sidecars_by_bake.values():
		var raw_state := raw_state_value as Dictionary
		raw_sidecar_estimated_total += int(raw_state.get("estimated_bytes", 0))
		raw_sidecar_allocated_total += int(raw_state.get("allocated_bytes", 0))
	return {"cache_count": caches.size(), "requested_resolution": prt_clv_resolution,
		"selected_backend": _last_clv_cache_backend,
		"layout_version": _clv_layout_version_for_backend(_last_clv_cache_backend),
		"texture_columns": _clv_texture_columns_for_backend(_last_clv_cache_backend),
		"raw_sidecar_resources": raw_sidecars_by_bake.values(),
		"raw_sidecar_estimated_bytes": raw_sidecar_estimated_total,
		"raw_sidecar_allocated_bytes": raw_sidecar_allocated_total,
		"clipmaps": caches}

## Metadata for the persistent revision-2 probe SH upload. This reports the actual
## FP32 storage buffer used by the CLV producer; it does not read or synchronize it.
func get_magicdawn_baked_source_state(cache_key := "") -> Dictionary:
	var selected_key := cache_key
	if selected_key.is_empty():
		selected_key = str(_native_baked_sh_state.get("cache_key", ""))
	if selected_key.is_empty():
		selected_key = str(_magicdawn_runtime_state.get("cache_key", ""))
	if selected_key.is_empty() and _bake_resources.size() == 1:
		selected_key = str(_bake_resources.keys()[0])
	if selected_key.is_empty() or not _bake_resources.has(selected_key):
		return {"available": false, "error": "bake_cache_key_unavailable",
			"available_bake_keys": _bake_resources.keys()}
	var cached_value: Variant = _bake_resources[selected_key]
	if not cached_value is Dictionary:
		return {"available": false, "error": "bake_resource_invalid",
			"cache_key": selected_key}
	var cached: Dictionary = cached_value
	var directional_value: Variant = cached.get("directional")
	if not directional_value is RefCounted:
		return {"available": false, "error": "directional_cache_unavailable",
			"cache_key": selected_key}
	var directional: RefCounted = directional_value
	var source_value: Variant = directional.get("baked_indirect_lighting")
	var source_rid: RID = source_value if source_value is RID else RID()
	var probe_count := int(directional.get("probes"))
	var source_bytes := int(directional.get("baked_indirect_lighting_bytes"))
	var expected_bytes := probe_count * 28 * 4
	var source_revision := int(cached.get("baked_indirect_sh_revision", 0))
	return {"available": source_rid.is_valid() and probe_count > 0 \
			and source_bytes == expected_bytes,
		"error": "" if source_rid.is_valid() and source_bytes == expected_bytes \
			else "baked_source_upload_incomplete",
		"cache_key": selected_key,
		"baked_sh_revision": source_revision,
		"includes_primary_sky": bool(cached.get("baked_indirect_sh_includes_primary_sky", false)),
		"includes_direct_directional_light": false,
		"source_buffer_rid": source_rid,
		"source_buffer_role": "persisted_revision2_baked_total_indirect_sh",
		"source_format": "R32_SFLOAT storage buffer",
		"source_probe_count": probe_count,
		"source_stride_vec4": 7,
		"source_stride_bytes": 112,
		"source_coefficients_per_probe": 27,
		"source_coefficient_bytes_per_probe": 108,
		"source_padding_lanes_per_probe": 1,
		"source_bytes": source_bytes,
		"expected_source_bytes": expected_bytes}

## Explicit untimed, small probe readback for validating the persisted SH-to-SSBO
## upload. The render path never calls this synchronous GPU read.
func read_magicdawn_baked_source_probes(probe_indices: PackedInt32Array,
		cache_key := "") -> Dictionary:
	if probe_indices.is_empty() or probe_indices.size() > 64:
		return {"valid": false, "error": "probe_index_count_out_of_range"}
	var source_state := get_magicdawn_baked_source_state(cache_key)
	if not bool(source_state.get("available", false)):
		return {"valid": false, "error": str(source_state.get("error", "source_unavailable")),
			"source_state": source_state}
	var probe_count := int(source_state.get("source_probe_count", 0))
	var source_rid: RID = source_state.get("source_buffer_rid", RID())
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not source_rid.is_valid():
		return {"valid": false, "error": "rendering_device_or_source_rid_unavailable"}
	var samples: Array[Dictionary] = []
	for probe_index in probe_indices:
		if probe_index < 0 or probe_index >= probe_count:
			return {"valid": false, "error": "probe_index_out_of_range:%d" % probe_index}
		var bytes: PackedByteArray = rd.buffer_get_data(source_rid,
				probe_index * 112, 112)
		if bytes.size() != 112:
			return {"valid": false, "error": "probe_source_readback_failed:%d" % probe_index}
		var lanes := bytes.to_float32_array()
		if lanes.size() != 28:
			return {"valid": false, "error": "probe_source_lane_count_invalid:%d" % probe_index}
		samples.append({"probe_index": probe_index,
			"coefficients": lanes.slice(0, 27), "padding_lane": lanes[27]})
	return {"valid": true, "cache_key": str(source_state.get("cache_key", "")),
		"source_probe_count": probe_count, "stride_vec4": 7,
		"coefficient_count": 27, "samples": samples}

## Untimed, one-shot cell readback for investigating a specific certified-sample
## miss. This synchronously reads the bounded CLV textures and is never called
## from the render path or a timing sample.
func read_prt_clv_cell_readback(receivers: Array[Dictionary]) -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return {"valid": false, "error": "RenderingDevice unavailable"}
	var selected_cache: RefCounted
	for entry_value in _clipmaps.values():
		if not entry_value is Dictionary:
			continue
		var candidate_entry := entry_value as Dictionary
		if int(candidate_entry.get("cache_backend", CLV_CACHE_BACKEND_LEGACY)) \
				== CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART:
			return {"valid": false,
				"error": "The ABI10 single-chart cache has a different readback schema."}
		var candidate: RefCounted = candidate_entry.get("cache")
		if candidate == null or not candidate.get("texture").is_valid() \
				or not candidate.get("tags").is_valid() or not candidate.get("support").is_valid():
			continue
		if (candidate.get("_origins") as Array).size() == ClipmapCache.LEVELS:
			selected_cache = candidate
			break
	if selected_cache == null:
		return {"valid": false, "error": "No initialized three-level CLV cache"}
	var texture_bytes: PackedByteArray = rd.texture_get_data(selected_cache.get("texture"), 0)
	var tag_bytes: PackedByteArray = rd.texture_get_data(selected_cache.get("tags"), 0)
	var support_bytes: PackedByteArray = rd.texture_get_data(selected_cache.get("support"), 0)
	var resolution := int(selected_cache.get("resolution"))
	const level_count := 3
	var texture_width := resolution * ClipmapCache.CLV_TEXTURE_COLUMNS
	var texture_height := resolution
	var texture_depth := resolution * level_count
	var expected_texture_bytes := texture_width * texture_height * texture_depth * 16
	var expected_tag_bytes := resolution * resolution * texture_depth * 16
	var expected_support_bytes := resolution * resolution * texture_depth * 4
	if texture_bytes.size() != expected_texture_bytes or tag_bytes.size() != expected_tag_bytes \
			or support_bytes.size() != expected_support_bytes:
		return {"valid": false, "error": "CLV texture readback size mismatch",
			"received_bytes": [texture_bytes.size(), tag_bytes.size(), support_bytes.size()],
			"expected_bytes": [expected_texture_bytes, expected_tag_bytes, expected_support_bytes]}
	var spacing := float(selected_cache.get("_spacing"))
	var geometry_epoch := int(selected_cache.get("_geometry_epoch"))
	var origins: Array = selected_cache.get("_origins")
	var read_receivers: Array[Dictionary] = []
	for receiver in receivers:
		var world: Vector3 = receiver.get("world", Vector3.ZERO)
		var normal: Vector3 = receiver.get("normal", Vector3.UP)
		var axis := _clv_dominant_axis(normal)
		var lods: Array[Dictionary] = []
		for level in level_count:
			var step := spacing * float(1 << level)
			var position := (world + normal * step * 0.75) / step - Vector3.ONE * 0.5
			var base := Vector3i(floori(position.x), floori(position.y), floori(position.z))
			var origin: Vector3i = origins[level]
			var relative := base - origin
			var in_query_window := relative.x >= 0 and relative.y >= 0 and relative.z >= 0 \
					and relative.x < resolution - 1 and relative.y < resolution - 1 \
					and relative.z < resolution - 1
			var physical := Vector3i(_clv_posmod(base.x, resolution),
				_clv_posmod(base.y, resolution), _clv_posmod(base.z, resolution))
			var seam := physical.x == resolution - 1 or physical.y == resolution - 1 \
				or physical.z == resolution - 1
			var slot := Vector3i(physical.x, physical.y, physical.z + level * resolution)
			var base_tag := _clv_read_vec4i(tag_bytes, resolution, resolution, slot)
			var base_support := _clv_read_u32(support_bytes, resolution, resolution, slot)
			var corners: Array[Dictionary] = []
			for corner in 8:
				var logical := base + Vector3i(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
				var corner_physical := Vector3i(_clv_posmod(logical.x, resolution),
					_clv_posmod(logical.y, resolution), _clv_posmod(logical.z, resolution))
				var corner_slot := Vector3i(corner_physical.x, corner_physical.y,
					corner_physical.z + level * resolution)
				var tag := _clv_read_vec4i(tag_bytes, resolution, resolution, corner_slot)
				var metadata_column := axis * ClipmapCache.CLV_FACE_SLOT_COLUMNS + ClipmapCache.SURFACE_METADATA_COLUMN
				var anchor_column := axis * ClipmapCache.CLV_FACE_SLOT_COLUMNS + ClipmapCache.SURFACE_ANCHOR_COLUMN
				var metadata := _clv_read_vec4f(texture_bytes, texture_width, texture_height,
					corner_slot, metadata_column)
				var anchor := _clv_read_vec4f(texture_bytes, texture_width, texture_height,
					corner_slot, anchor_column)
				var corner_support := _clv_read_u32(support_bytes, resolution, resolution, corner_slot)
				corners.append({"corner": corner, "logical": logical, "physical_slot": corner_slot,
					"tag": tag, "tag_matches_logical_epoch": tag.x == logical.x and tag.y == logical.y \
						and tag.z == logical.z and tag.w == geometry_epoch,
					"support": corner_support,
					"axis_support": (corner_support & (1 << axis)) != 0,
					"face_metadata": metadata, "face_anchor": anchor,
					"face_record_valid": metadata.w > 0.0 and absf(anchor.w) >= 1.0})
			var all_tags_match := true
			var all_faces_valid := true
			var same_patch := true
			var same_normal := true
			var same_anchor_plane := true
			var reference_metadata: Vector4 = corners[0].get("face_metadata")
			var reference_anchor: Vector4 = corners[0].get("face_anchor")
			for corner_record in corners:
				var corner_metadata: Vector4 = corner_record.get("face_metadata")
				var corner_anchor: Vector4 = corner_record.get("face_anchor")
				all_tags_match = all_tags_match and bool(corner_record.get("tag_matches_logical_epoch", false))
				all_faces_valid = all_faces_valid and bool(corner_record.get("face_record_valid", false))
				same_patch = same_patch and corner_metadata.w == reference_metadata.w
				same_normal = same_normal and (_clv_xyz(corner_metadata) - _clv_xyz(reference_metadata)).length_squared() <= 1e-10
				var magnitude := maxf(step, maxf(absf(corner_anchor.x), maxf(absf(corner_anchor.y), absf(corner_anchor.z))))
				var tolerance := maxf(1e-5, step * 1e-4) + maxf(1e-5, magnitude * 1.9073486328125e-6)
				same_anchor_plane = same_anchor_plane and absf((_clv_xyz(corner_anchor) - _clv_xyz(reference_anchor)).dot(_clv_xyz(reference_metadata))) <= tolerance
			var face_compatible := all_tags_match and all_faces_valid and same_patch and same_normal and same_anchor_plane
			var certificate_complete := (base_support & 128) != 0
			var certified := (base_support & (1 << axis)) != 0
			var reject_class := "unknown"
			if not in_query_window:
				reject_class = "outside_logical_window"
			elif seam:
				reject_class = "physical_modulo_seam"
			elif not all_tags_match:
				reject_class = "corner_tag_or_epoch_mismatch"
			elif not all_faces_valid:
				reject_class = "missing_face_or_visible_source_support"
			elif not same_patch or not same_normal or not same_anchor_plane:
				reject_class = "nearest_face_selection_discontinuity_or_geometric_incompatibility"
			elif certificate_complete and not certified:
				reject_class = "final_conservative_bounds_certificate_rejected"
			elif certified:
				reject_class = "certified_axis_support_present"
			else:
				reject_class = "certificate_not_completed"
			lods.append({"level": level, "step_m": step, "origin": origin,
				"query_position": position, "query_fraction": position - position.floor(),
				"logical_base": base, "relative_base": relative, "in_query_window": in_query_window,
				"physical_base": physical, "physical_seam": seam, "slot": slot,
				"base_tag": base_tag, "expected_epoch": geometry_epoch,
				"base_tag_matches": base_tag.x == base.x and base_tag.y == base.y \
						and base_tag.z == base.z and base_tag.w == geometry_epoch,
				"support_byte": base_support, "completed_bit": certificate_complete,
				"requested_axis": axis, "requested_axis_support": certified,
				"face_compatibility": {"all_corner_tags_match": all_tags_match,
					"all_faces_valid": all_faces_valid, "same_patch": same_patch,
					"same_normal": same_normal, "same_anchor_plane": same_anchor_plane,
					"all_pre_certificate_conditions_pass": face_compatible},
				"reject_class": reject_class, "eight_corners": corners})
		read_receivers.append({"name": str(receiver.get("name", "receiver")), "world": world,
			"normal": normal, "dominant_axis": axis, "lods": lods})
	return {"valid": true, "cache": {"spacing_m": spacing, "geometry_epoch": geometry_epoch,
		"content_revision": int(selected_cache.get("_content_revision")),
		"origins": origins.duplicate(), "origins_hash": hash(origins),
		"pending_cells": maxi((selected_cache.get("_pending") as Array).size() \
				- int(selected_cache.get("_cursor")), 0), "layout_version": CLV_LEGACY_LAYOUT_VERSION,
		"resolution": resolution,
		"gpu_bytes": ClipmapCache.estimate_gpu_bytes_breakdown(resolution)},
		"texture_dimensions": [texture_width, texture_height, texture_depth],
		"receiver_count": read_receivers.size(), "receivers": read_receivers,
		"timing_note": "Untimed synchronous GPU texture readback; not a performance sample."}

func _clv_dominant_axis(normal: Vector3) -> int:
	var magnitude := Vector3(absf(normal.x), absf(normal.y), absf(normal.z))
	if magnitude.x >= magnitude.y and magnitude.x >= magnitude.z:
		return 0
	if magnitude.y >= magnitude.z:
		return 1
	return 2

func _clv_posmod(value: int, modulus: int) -> int:
	return ((value % modulus) + modulus) % modulus

func _clv_xyz(value: Vector4) -> Vector3:
	return Vector3(value.x, value.y, value.z)

func _clv_read_vec4i(bytes: PackedByteArray, width: int, height: int, slot: Vector3i) -> Vector4i:
	var offset := ((slot.z * height + slot.y) * width + slot.x) * 16
	return Vector4i(bytes.decode_s32(offset), bytes.decode_s32(offset + 4),
		bytes.decode_s32(offset + 8), bytes.decode_s32(offset + 12))

func _clv_read_u32(bytes: PackedByteArray, width: int, height: int, slot: Vector3i) -> int:
	var offset := ((slot.z * height + slot.y) * width + slot.x) * 4
	return int(bytes.decode_u32(offset))

func _clv_read_vec4f(bytes: PackedByteArray, width: int, height: int,
		slot: Vector3i, column: int) -> Vector4:
	var x := slot.x + column * 16
	var offset := ((slot.z * height + slot.y) * width + x) * 16
	return Vector4(bytes.decode_float(offset), bytes.decode_float(offset + 4),
		bytes.decode_float(offset + 8), bytes.decode_float(offset + 12))

func _frp_execute(ctx: FRPPassContext) -> void:
	var cpu_start_usec := Time.get_ticks_usec()
	_last_prt_pass_cpu_usec = 0
	_frame_native_baked_sh_consumed = false
	_frame_native_baked_sh_publication.clear()
	_frame_prt_scale = 1
	_frame_native_clv_fallback_only = false
	_frame_native_clv_status_known = false
	_frame_magicdawn_clv_renderer_active = false
	_magicdawn_clv_debug_status = "not_requested"
	_frame_native_general_queue_active = false
	_frame_native_general_queue_msaa = -1
	_frame_native_general_queue_view_count = 0
	_last_native_clv_lighting_active = false
	_last_native_clv_lighting_frame = Engine.get_frames_drawn()
	_last_native_clv_lighting_qa_mode = -1
	_last_native_screen_cache_lighting_active = false
	_last_native_screen_cache_lighting_frame = Engine.get_frames_drawn()
	_last_native_screen_cache_frame_token = -1
	_frame_surfel_inputs.clear()
	_frame_rtgi_snapshot.clear()
	_frame_diffuse_ao_texture = RID()
	_surfel_nrd_frame_active = false
	_surfel_nrd_frame_fallback_reason = ""
	var rd := RenderingServer.get_rendering_device()
	_capture_gpu_timestamp(rd, "Begin")
	if rd != null:
		_prune_prt_raw_views(rd)
		if not _diffuse_ao_view_cache.is_empty():
			_prune_diffuse_ao_view_cache(rd)
	if not IndirectGISelection.is_owner(ctx, String(get_parameter_key()),
			IndirectGISelection.KIND_MAGIC, true):
		# An active RTGI plan owns the diffuse-indirect slot, even if its scene or
		# backend is unsupported this frame. Leave native SkyDiffuse untouched and
		# clear this pass's old sidecar so no later consumer can reuse stale GI.
		_replacement_request_prepared = false
		_surfel_request_prepared = false
		_surfel_replacement_requested = false
		_frame_replacement_enabled = false
		_release_surfel_nrd_if_active()
		_clear_magic_gi_output(ctx)
		_native_prepared_views.clear()
		_native_baked_sh_prepared_views.clear()
		_native_baked_sh_attempted_views.clear()
		_native_baked_sh_publications.clear()
		if ctx.has_method("clear_magic_gi_baked_sh_inputs"):
			ctx.call("clear_magic_gi_baked_sh_inputs")
		_capture_gpu_timestamp(rd, "End")
		_last_prt_pass_cpu_usec = Time.get_ticks_usec() - cpu_start_usec
		return
	_frame_diffuse_ao_texture = ctx.get_diffuse_ambient_occlusion_texture() if ctx != null else RID()
	_frame_replacement_enabled = false
	_pre_exposure = ctx.get_pre_exposure(0) if ctx != null else 1.0
	_scene_exposure_normalization = _get_scene_exposure_normalization(ctx)
	_last_frame_pre_exposure = _pre_exposure
	_last_frame_scene_exposure_normalization = _scene_exposure_normalization
	_last_exposure_frame = Engine.get_frames_drawn()
	if ctx != null:
		var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
		if buffers != null and bool(_snapshot_for_target(buffers).get("surfel", false)):
			for view in buffers.get_view_count():
				_frame_surfel_inputs.append(ctx.get_volume_frame_inputs(view))
			var target: RID = buffers.get_render_target()
			if target.is_valid():
				var rtgi_runtime := _get_rtgi_runtime_script()
				if rtgi_runtime != null and rtgi_runtime.has_method("snapshot_for_target"):
					var rtgi_value: Variant = rtgi_runtime.call("snapshot_for_target", target)
					if rtgi_value is Dictionary:
						_frame_rtgi_snapshot = rtgi_value
	# RenderFRPClustered sets this after selecting and binding the native lighting
	# variant. Only that renderer decision can authorize the compute pass to skip
	# certified pixels; a locally prepared cache alone is not proof that deferred
	# lighting consumed the borrowed CLV RIDs.
	_frame_native_clv_status_known = ctx != null \
		and ctx.has_method("is_magic_gi_clv_lighting_active")
	_frame_native_clv_fallback_only = _frame_native_clv_status_known \
		and bool(ctx.call("is_magic_gi_clv_lighting_active"))
	_frame_native_general_queue_active = ctx != null \
			and ctx.has_method("is_magic_gi_general_queue_active") \
			and bool(ctx.call("is_magic_gi_general_queue_active"))
	if ctx != null and ctx.has_method("get_magic_gi_general_queue_runtime_msaa"):
		_frame_native_general_queue_msaa = int(ctx.call("get_magic_gi_general_queue_runtime_msaa"))
	if ctx != null and ctx.has_method("get_magic_gi_general_queue_runtime_view_count"):
		_frame_native_general_queue_view_count = int(ctx.call("get_magic_gi_general_queue_runtime_view_count"))
	_native_general_queue_state["active"] = _frame_native_general_queue_active
	_native_general_queue_state["runtime_msaa"] = _frame_native_general_queue_msaa
	_native_general_queue_state["runtime_view_count"] = _frame_native_general_queue_view_count
	_native_general_queue_state["frame"] = Engine.get_frames_drawn()
	super._frp_execute(ctx)
	if ctx != null and ctx.has_method("is_magic_gi_clv_lighting_active"):
		_last_native_clv_lighting_active = bool(ctx.call("is_magic_gi_clv_lighting_active"))
	_last_native_clv_lighting_frame = Engine.get_frames_drawn()
	_last_native_screen_cache_frame_token = int(ctx.call("get_frame_token")) \
			if ctx != null and ctx.has_method("get_frame_token") else -1
	var screen_cache_input_current: bool = ctx != null \
			and ctx.has_method("has_magic_gi_screen_cache_input") \
			and bool(ctx.call("has_magic_gi_screen_cache_input", 0)) \
			and _last_native_screen_cache_frame_token >= 0 \
			and int(_magicdawn_runtime_state.get("screen_cache_frame_token", -1)) \
			== _last_native_screen_cache_frame_token \
			and int(_magicdawn_runtime_state.get("screen_cache_dispatch_token", 0)) > 0
	_last_native_screen_cache_lighting_active = screen_cache_input_current \
			and ctx.has_method("is_magic_gi_screen_cache_lighting_active") \
			and bool(ctx.call("is_magic_gi_screen_cache_lighting_active"))
	_last_native_screen_cache_lighting_frame = Engine.get_frames_drawn()
	_magicdawn_runtime_state["screen_cache_renderer_active"] = \
			_last_native_screen_cache_lighting_active
	_magicdawn_runtime_state["screen_cache_renderer_active_raw"] = ctx != null \
			and ctx.has_method("is_magic_gi_screen_cache_lighting_active") \
			and bool(ctx.call("is_magic_gi_screen_cache_lighting_active"))
	_magicdawn_runtime_state["screen_cache_renderer_frame"] = \
			_last_native_screen_cache_lighting_frame
	_magicdawn_runtime_state["screen_cache_renderer_frame_token"] = \
			_last_native_screen_cache_frame_token
	_magicdawn_runtime_state["screen_cache_lease_current"] = screen_cache_input_current
	_magicdawn_runtime_state["screen_cache_renderer_path_active"] = \
			_last_native_screen_cache_lighting_active
	if _last_native_screen_cache_lighting_active:
		_magicdawn_runtime_state["renderer_path_active"] = true
		_magicdawn_runtime_state["status"] = \
				"native_layout9_screen_cache_renderer_path_active"
	_last_native_clv_owner_control_w = -1.0
	_last_native_clv_owner_parameters_rid = RID()
	for prepared_value in _native_prepared_views.values():
		if prepared_value is Dictionary and prepared_value.has("owner_control_w") \
				and prepared_value.get("owner_parameters_rid", RID()) is RID:
			_last_native_clv_owner_control_w = float(prepared_value.get("owner_control_w", -1.0))
			_last_native_clv_owner_parameters_rid = prepared_value.get("owner_parameters_rid", RID())
			break
	_last_native_clv_lighting_qa_mode = int(round(_last_native_clv_owner_control_w)) \
			if is_finite(_last_native_clv_owner_control_w) and _last_native_clv_owner_control_w >= 0.0 else -1
	_capture_gpu_timestamp(rd, "End")
	_pre_exposure = 1.0
	_scene_exposure_normalization = 1.0
	_replacement_request_prepared = false
	_frame_replacement_enabled = false
	_frame_diffuse_ao_texture = RID()
	_frame_surfel_inputs.clear()
	_frame_rtgi_snapshot.clear()
	_surfel_request_prepared = false
	_surfel_replacement_requested = false
	_frame_prt_scale = 1
	_frame_native_clv_fallback_only = false
	_frame_native_baked_sh_consumed = false
	_frame_native_baked_sh_publication.clear()
	_native_prepared_views.clear()
	_native_baked_sh_prepared_views.clear()
	_native_baked_sh_attempted_views.clear()
	_native_baked_sh_publications.clear()
	_last_prt_pass_cpu_usec = Time.get_ticks_usec() - cpu_start_usec

func _frp_execute_with_snapshot(ctx: FRPPassContext, snapshot: Dictionary) -> void:
	# Page dispatches share a view's G-buffer bindings and camera matrices. Keep
	# this reuse inside one invocation so captures and resized viewports stay fresh.
	_frame_input_bindings.clear()
	_frame_view_matrices.clear()
	if _dynamic_volume_publication_token > 0:
		var expected_token := _dynamic_volume_publication_token
		var expected_frame_token := int(_dynamic_volume_runtime_state.get("frame_token", -1))
		var current_frame_token := int(ctx.call("get_frame_token")) \
				if ctx != null and ctx.has_method("get_frame_token") else -1
		var lease_current := current_frame_token == expected_frame_token \
				and ctx != null and ctx.has_method("has_magic_gi_dynamic_volume_input") \
				and bool(ctx.call("has_magic_gi_dynamic_volume_input", 0))
		var consumed_token := int(ctx.call("get_magic_gi_dynamic_volume_consumed_token")) \
				if ctx != null and ctx.has_method("get_magic_gi_dynamic_volume_consumed_token") else 0
		var direct_volume_consumed := lease_current and consumed_token == expected_token \
				and ctx.has_method("is_magic_gi_dynamic_volume_lighting_active") \
				and bool(ctx.call("is_magic_gi_dynamic_volume_lighting_active"))
		var screen_state: Dictionary = _dynamic_volume_screen_runtime_state
		var screen_lease_current: bool = lease_current \
				and current_frame_token == int(screen_state.get("frame_token", -1)) \
				and int(screen_state.get("source_publication_token", 0)) == expected_token \
				and int(screen_state.get("dispatch_token", 0)) > 0 \
				and ctx.has_method("has_magic_gi_dynamic_screen_cache_input") \
				and bool(ctx.call("has_magic_gi_dynamic_screen_cache_input", 0))
		var screen_active_raw := ctx != null \
				and ctx.has_method("is_magic_gi_dynamic_screen_cache_lighting_active") \
				and bool(ctx.call("is_magic_gi_dynamic_screen_cache_lighting_active"))
		var screen_cache_consumed := screen_lease_current and screen_active_raw
		var renderer_consumed := direct_volume_consumed or screen_cache_consumed
		_dynamic_volume_runtime_state["renderer_active"] = renderer_consumed
		_dynamic_volume_runtime_state["active"] = renderer_consumed
		_dynamic_volume_runtime_state["direct_volume_renderer_active"] = direct_volume_consumed
		_dynamic_volume_runtime_state["screen_cache_renderer_active"] = screen_cache_consumed
		_dynamic_volume_runtime_state["renderer_current"] = renderer_consumed \
				and current_frame_token == expected_frame_token
		_dynamic_volume_runtime_state["renderer_frame"] = Engine.get_frames_drawn()
		_dynamic_volume_runtime_state["renderer_frame_token"] = current_frame_token
		_dynamic_volume_runtime_state["lease_current"] = lease_current
		_dynamic_volume_runtime_state["consumed_token"] = consumed_token
		_dynamic_volume_runtime_state["screen_cache_lease_current"] = screen_lease_current
		_dynamic_volume_runtime_state["screen_cache_renderer_active_raw"] = screen_active_raw
		_dynamic_volume_runtime_state["screen_cache_frame_token"] = int(
				screen_state.get("frame_token", -1))
		_dynamic_volume_runtime_state["screen_cache_dispatch_token"] = int(
				screen_state.get("dispatch_token", 0))
		_dynamic_volume_screen_runtime_state["active"] = screen_cache_consumed
		_dynamic_volume_screen_runtime_state["renderer_active_raw"] = screen_active_raw
		_dynamic_volume_screen_runtime_state["lease_current"] = screen_lease_current
		_dynamic_volume_screen_runtime_state["renderer_frame"] = Engine.get_frames_drawn()
		_dynamic_volume_screen_runtime_state["renderer_frame_token"] = current_frame_token
		if screen_cache_consumed:
			_dynamic_volume_screen_runtime_state["status"] = "native_screen_cache_active"
		elif not str(_dynamic_volume_screen_runtime_state.get("status", "")) \
				in ["idle", "prepare_started", "waiting_for_gbuffer", "native_preinterpolated_clv"]:
			_dynamic_volume_screen_runtime_state["status"] = "native_screen_cache_not_consumed"
		var route_status := "native_dynamic_screen_cache_active" \
				if screen_cache_consumed else ("native_dynamic_volume_active" \
				if direct_volume_consumed else "native_dynamic_volume_not_consumed")
		_dynamic_volume_runtime_state["status"] = route_status
		_dynamic_volume_runtime_state["fallback_reason"] = "" if renderer_consumed \
				else "renderer_did_not_consume_current_volume_or_screen_lease"
		_magicdawn_runtime_state["backend"] = "dynamic_free_space_volume"
		_magicdawn_runtime_state["renderer_path_active"] = renderer_consumed
		_magicdawn_runtime_state["native_dynamic_volume_active"] = direct_volume_consumed
		_magicdawn_runtime_state["native_dynamic_screen_cache_active"] = screen_cache_consumed
		_magicdawn_runtime_state["native_clv_lighting_active"] = false
		_magicdawn_runtime_state["status"] = str(_dynamic_volume_runtime_state["status"])
		_magicdawn_runtime_state["dynamic_volume"] = _dynamic_volume_runtime_state.duplicate(true)
		_magicdawn_runtime_state["dynamic_volume_screen"] = \
				_dynamic_volume_screen_runtime_state.duplicate(true)
		if renderer_consumed and CLVEditorSnapshot.has_requests():
			_publish_preinterpolated_editor_snapshot(ctx, snapshot)
		super._frp_execute_with_snapshot(ctx, snapshot)
		_dynamic_volume_publication_token = 0
		return
	if _magicdawn_clv_prt_frame:
		var renderer_clv_active := ctx != null \
				and ctx.has_method("is_magic_gi_clv_lighting_active") \
				and bool(ctx.call("is_magic_gi_clv_lighting_active"))
		var renderer_screen_cache_active := ctx != null \
				and ctx.has_method("is_magic_gi_screen_cache_lighting_active") \
				and bool(ctx.call("is_magic_gi_screen_cache_lighting_active"))
		var screen_cache_token := int(ctx.call("get_frame_token")) \
				if ctx != null and ctx.has_method("get_frame_token") else -1
		var screen_cache_lease_current: bool = ctx != null \
				and ctx.has_method("has_magic_gi_screen_cache_input") \
				and bool(ctx.call("has_magic_gi_screen_cache_input", 0)) \
				and screen_cache_token >= 0 \
				and screen_cache_token == int(_magicdawn_runtime_state.get(
						"screen_cache_frame_token", -1)) \
				and int(_magicdawn_runtime_state.get("screen_cache_dispatch_token", 0)) > 0
		var screen_cache_consumed_current: bool = renderer_screen_cache_active \
				and screen_cache_lease_current
		_frame_magicdawn_clv_renderer_active = _magicdawn_clv_prt_prepared \
				and renderer_clv_active
		if _magicdawn_clv_prt_prepared and renderer_clv_active:
			# Backend 1 is exclusively the native layout-9 CLV consumer. Do not run
			# the old screen-space PRT gather as a correctness or miss fallback.
			_magicdawn_runtime_state["status"] = "native_layout9_clv_renderer_path_active"
			_magicdawn_runtime_state["renderer_path_active"] = true
			_magicdawn_runtime_state["native_clv_lighting_active"] = true
			_magicdawn_runtime_state["receiver_hit_count"] = null
			_magicdawn_runtime_state["native_clv_pixel_sampling"] = "fused_deferred_pbr"
			_magicdawn_runtime_state["fallback_path"] = "disabled_fail_closed"
		elif _magicdawn_clv_prt_prepared and screen_cache_consumed_current:
			# The screen-cache specialization consumes the same prepared CLV lease,
			# while the full-resolution CLV-active flag correctly stays false.
			_magicdawn_clv_debug_status = "screen_cache_active_debug_view_uses_legacy_clv_path"
			_magicdawn_runtime_state["status"] = \
					"native_layout9_screen_cache_renderer_path_active"
			_magicdawn_runtime_state["renderer_path_active"] = true
			_magicdawn_runtime_state["native_clv_lighting_active"] = false
			_magicdawn_runtime_state["screen_cache_renderer_active"] = true
			_magicdawn_runtime_state["screen_cache_renderer_active_raw"] = true
			_magicdawn_runtime_state["screen_cache_renderer_frame_token"] = screen_cache_token
			_magicdawn_runtime_state["screen_cache_lease_current"] = true
			_magicdawn_runtime_state["screen_cache_renderer_path_active"] = true
			_magicdawn_runtime_state["native_clv_pixel_sampling"] = "half_res_receiver_cache_plus_edge_fallback"
			_magicdawn_runtime_state["fallback_path"] = "disabled_fail_closed"
		else:
			# Keep the screen lease intact when the renderer selected the screen-cache
			# specialization; clearing CLV inputs also clears the screen-cache lease.
			if not screen_cache_lease_current and ctx != null \
					and ctx.has_method("clear_magic_gi_clv_inputs"):
				ctx.call("clear_magic_gi_clv_inputs")
			_magicdawn_runtime_state["status"] = "native_layout9_clv_not_consumed_fail_closed"
			_magicdawn_runtime_state["renderer_path_active"] = false
			_magicdawn_runtime_state["native_clv_lighting_active"] = renderer_clv_active
			_magicdawn_runtime_state["fallback_path"] = "disabled_fail_closed"
			if not _magicdawn_clv_prt_prepared:
				_magicdawn_runtime_state["fallback_reason"] = \
					str(_magicdawn_runtime_state.get("fallback_reason",
						"layout9_clv_prepare_not_published"))
			else:
				_magicdawn_runtime_state["fallback_reason"] = \
					"renderer_did_not_activate_native_clv_path"
		# Let the base snapshot pass publish this frame's snapshot and invoke our
		# debug-only _render mirror. Returning here used to leave the layout-9
		# sidecar permanently black even though deferred lighting consumed the cache.
		super._frp_execute_with_snapshot(ctx, snapshot)
		_magicdawn_clv_prt_frame = false
		_magicdawn_clv_prt_prepared = false
		_frame_magicdawn_clv_renderer_active = false
		return
	_frame_native_baked_sh_publication = _confirmed_magicdawn_native_publication(
			ctx, snapshot)
	_frame_native_baked_sh_consumed = not _frame_native_baked_sh_publication.is_empty()
	if _frame_native_baked_sh_consumed:
		_native_baked_sh_state = _frame_native_baked_sh_publication.duplicate(true)
		_native_baked_sh_state["active"] = true
		_native_baked_sh_state["consumed"] = true
		if not str(_native_baked_sh_state.get("status", "")).begins_with("native_consumed"):
			_native_baked_sh_state["status"] = "native_consumed"
		_native_baked_sh_state["fallback_reason"] = ""
	else:
		var prepare_fallback_reason := str(_native_baked_sh_state.get(
				"fallback_reason", ""))
		var prepare_fallback_is_specific := not prepare_fallback_reason.is_empty() \
				and prepare_fallback_reason != "preflight_pending" \
				and prepare_fallback_reason != "native_consumption_not_confirmed"
		_native_baked_sh_state["active"] = false
		_native_baked_sh_state["consumed"] = false
		_native_baked_sh_state["frame"] = Engine.get_frames_drawn()
		_native_baked_sh_state["status"] = "standalone_fallback"
		if not prepare_fallback_is_specific:
			_native_baked_sh_state["fallback_reason"] = "native_layout17_not_confirmed_consumed"
	super._frp_execute_with_snapshot(ctx, snapshot)
	_frame_native_baked_sh_consumed = false
	_frame_native_baked_sh_publication.clear()
	_native_baked_sh_prepared_views.clear()
	_native_baked_sh_attempted_views.clear()
	_native_baked_sh_publications.clear()
	_frame_input_bindings.clear()
	_frame_view_matrices.clear()

func _get_scene_exposure_normalization(ctx: FRPPassContext) -> float:
	if ctx == null:
		return 1.0
	var value: float = ctx.get_scene_exposure_normalization()
	if is_finite(value) and value > 0.0:
		return value
	return 1.0

func _capture_gpu_timestamp(rd: RenderingDevice, label: String) -> void:
	if gpu_timestamp_profiling_enabled and rd != null \
			and (not _gpu_timestamp_outer_only or GPU_TIMESTAMP_OUTER_MARKERS.has(label)):
		rd.capture_timestamp("Magic GI Pass " + label)

## Prepare runs before the native lighting operation. It opts this frame into
## the exact SkyLight diffuse attachment only when a current bake can replace it.
func _frp_prepare(ctx: FRPPassContext) -> void:
	if _native_prepare_diagnostics_enabled:
		_last_native_prepare_frame = Engine.get_frames_drawn()
		_last_native_prepare_rejection = "prepare_started"
	_replacement_request_prepared = false
	_surfel_request_prepared = false
	_surfel_replacement_requested = false
	_magicdawn_dynamic_output_cleared = false
	_magicdawn_clv_prt_frame = false
	_magicdawn_clv_prt_prepared = false
	_native_prepared_views.clear()
	_native_baked_sh_prepared_views.clear()
	_native_baked_sh_attempted_views.clear()
	_native_baked_sh_publications.clear()
	_frame_native_baked_sh_consumed = false
	_frame_native_baked_sh_publication.clear()
	_native_baked_sh_state = {"enabled": native_baked_sh_lighting_enabled,
		"active": false, "consumed": false, "frame": Engine.get_frames_drawn(),
		"publication_token": 0, "status": "preflight_pending",
		"fallback_reason": "preflight_pending"}
	_magicdawn_debug_sidecar_forced = false
	_dynamic_volume_publication_token = 0
	_dynamic_volume_runtime_state = {"status": "idle", "active": false,
		"frame": Engine.get_frames_drawn(), "publication_token": 0}
	_last_native_prepare_cpu_usec = 0
	_native_general_queue_state = {
		"enabled": native_deferred_general_queue_enabled,
		"preflight_ready": false, "active": false,
		"fallback_reason": "preflight_not_run", "frame": Engine.get_frames_drawn(),
		"runtime_msaa": -1, "runtime_view_count": 0,
		"queue_capacity_pixels": 0, "consumer": "source_only_exact_gather",
	}
	if ctx == null:
		if _native_prepare_diagnostics_enabled:
			_last_native_prepare_rejection = "missing_context"
		return
	if ctx.has_method("clear_magic_gi_baked_sh_inputs"):
		ctx.call("clear_magic_gi_baked_sh_inputs")
	if ctx.has_method("clear_magic_gi_dynamic_volume_inputs"):
		ctx.call("clear_magic_gi_dynamic_volume_inputs")
	var general_queue_bridge_reason := _native_general_queue_bridge_reason(ctx)
	if not IndirectGISelection.is_owner(ctx, String(get_parameter_key()),
			IndirectGISelection.KIND_MAGIC, true):
		if _native_prepare_diagnostics_enabled:
			_last_native_prepare_rejection = "not_indirect_gi_owner"
		return
	if general_queue_bridge_reason.is_empty():
		ctx.call("clear_magic_gi_general_queue_inputs")
	elif native_deferred_general_queue_enabled:
		_native_general_queue_state["fallback_reason"] = general_queue_bridge_reason
	if ctx.has_method("set_magic_gi_profile_enabled"):
		ctx.set_magic_gi_profile_enabled(gpu_timestamp_profiling_enabled)
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	var snapshot := _snapshot_for_target(buffers)
	if bool(snapshot.get("surfel", false)):
		if _native_prepare_diagnostics_enabled:
			_last_native_prepare_rejection = "surfel_mode"
		var owner_size: Variant = snapshot.get("owner_size", Vector3.ZERO)
		if str(snapshot.get("cache_key", "")).is_empty() \
				or not snapshot.get("owner_transform", Transform3D.IDENTITY) is Transform3D \
				or not owner_size is Vector3 or owner_size.x <= 0.0 or owner_size.y <= 0.0 or owner_size.z <= 0.0:
			_warn_surfel_once("configuration", "Surfel GI volume configuration is incomplete; leaving native Sky diffuse unchanged.")
			return
		var target: RID = buffers.get_render_target() if buffers != null else RID()
		var runtime := _get_rtgi_runtime_script()
		if runtime == null:
			_warn_surfel_once("runtime", "Surfel GI requires the optional feng-raytracing addon; leaving native Sky diffuse unchanged.")
			return
		var device := RenderingServer.get_rendering_device()
		if not target.is_valid() or device == null or not device.has_feature(
				RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
			_warn_surfel_once("backend", "Surfel GI requires a RenderingDevice with ray-tracing pipeline support; leaving native Sky diffuse unchanged.")
			return
		_queue_surfel_runtime_start()
		runtime.call("request_target", target)
		var resolved_surfel: Variant = get_resolved_parameters(ctx).get("parameters", parameters)
		var pass_strength := float(resolved_surfel.x) if resolved_surfel is Vector4 else float(parameters.x)
		var geometry_value: Variant = runtime.call("snapshot_for_target", target) if runtime.has_method("snapshot_for_target") else {}
		var geometry_ready: bool = geometry_value is Dictionary and bool(geometry_value.get("valid", false)) \
				and int(geometry_value.get("world_id", 0)) == int(snapshot.get("world_id", 0)) \
				and geometry_value.get("instances", []) is Array and not geometry_value.get("instances", []).is_empty()
		_surfel_replacement_requested = geometry_ready and _replacement_requested(snapshot, pass_strength)
		if _surfel_replacement_requested:
			ctx.request_sky_light_diffuse()
		_surfel_request_prepared = true
		return
	if bool(snapshot.get("streamed", false)):
		_request_streaming_views(ctx, buffers)
	var resolved: Variant = get_resolved_parameters(ctx).get("parameters", parameters)
	var pass_strength := float(resolved.x) if resolved is Vector4 else float(parameters.x)
	var replacement_requested := _replacement_requested(snapshot, pass_strength)
	var free_space_snapshot := _single_free_space_source_snapshot(snapshot)
	if not free_space_snapshot.is_empty():
		if not native_clv_lighting_enabled:
			_dynamic_volume_runtime_state["status"] = "native_clv_disabled"
			return
		_magicdawn_runtime_state = {"backend": "dynamic_free_space_volume",
			"status": "dynamic_volume_prepare_started", "renderer_path_active": false,
			"frame": Engine.get_frames_drawn(), "native_clv_lighting_active": false}
		var prepare_cpu_start_usec := Time.get_ticks_usec()
		var dynamic_prepare_rd := RenderingServer.get_rendering_device()
		_capture_gpu_timestamp(dynamic_prepare_rd, "Native Prepare Begin")
		_prepare_native_dynamic_volume(ctx, buffers, free_space_snapshot,
				resolved, replacement_requested)
		_capture_gpu_timestamp(dynamic_prepare_rd, "Native Prepare End")
		_last_native_prepare_cpu_usec = Time.get_ticks_usec() - prepare_cpu_start_usec
		return
	var dynamic_clv_snapshot := _is_magicdawn_dynamic_clv_snapshot(snapshot)
	if replacement_requested and not dynamic_clv_snapshot:
		ctx.request_sky_light_diffuse()
		_replacement_request_prepared = true
	if dynamic_clv_snapshot:
		_magicdawn_clv_prt_frame = true
		_magicdawn_clv_prt_prepared = false
		_native_baked_sh_state = {"enabled": false, "active": false,
			"consumed": false, "frame": Engine.get_frames_drawn(),
			"status": "not_used_dynamic_clv_layout9",
			"fallback_reason": "backend_1_uses_live_transfer_matrix"}
		_magicdawn_runtime_state = {
			"backend": CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART,
			"prt_model": "CLV_BLOCK_RELIGHT",
			"sh_basis": "real_orthonormal_degree2_coefficients9",
			"layout_version": CLV_MAGICDAWN_DYNAMIC_PRT_LAYOUT_VERSION,
			"status": "native_clv_prepare_started",
			"pixel_csr_fallback": false,
			"replacement_enabled": replacement_requested,
			"clv_debug_view_supported": true,
			"clv_debug_view_status": "mirror_idle_until_debug_buffers_requests_magic_gi",
			"frame": Engine.get_frames_drawn(),
		}
		_magicdawn_clv_debug_status = "idle_until_debug_buffers_requests_magic_gi"
		if not native_clv_lighting_enabled:
			_magicdawn_runtime_state["status"] = "native_clv_disabled_fail_closed"
			_magicdawn_runtime_state["fallback_reason"] = "native_clv_lighting_disabled"
			ctx.clear_magic_gi_clv_inputs()
			return
		if not _can_prepare_native_prt(ctx, buffers, snapshot):
			_magicdawn_runtime_state["status"] = "native_clv_preflight_rejected_fail_closed"
			_magicdawn_runtime_state["fallback_reason"] = "native_clv_preflight_rejected"
			ctx.clear_magic_gi_clv_inputs()
			return
		var prepare_cpu_start_usec := Time.get_ticks_usec()
		_prepare_native_prt_clv(ctx, buffers, snapshot, resolved, replacement_requested)
		_last_native_prepare_cpu_usec = Time.get_ticks_usec() - prepare_cpu_start_usec
		_magicdawn_clv_prt_prepared = _native_prepared_views.size() == buffers.get_view_count()
		if _magicdawn_clv_prt_prepared:
			if replacement_requested:
				ctx.request_sky_light_diffuse()
				_replacement_request_prepared = true
			_magicdawn_runtime_state["status"] = "native_clv_prepared_waiting_for_renderer"
			_magicdawn_runtime_state["native_inputs_published"] = true
			_magicdawn_runtime_state["screen_cache_status"] = "waiting_for_gbuffer"
			if buffers.get_view_count() == 1 and ctx.has_method("enqueue_after_operation") \
					and ctx.has_method("get_frame_token"):
				var renderer_frame_token := int(ctx.call("get_frame_token"))
				var prepared_key := _native_view_key(buffers, 0)
				var callback := Callable(self, "_render_magicdawn_screen_cache_after_gbuffer") \
						.bind(buffers, prepared_key, renderer_frame_token)
				var queued := bool(ctx.call("enqueue_after_operation", NativeSpec.PASS_GBUFFER,
						callback))
				_magicdawn_runtime_state["screen_cache_status"] = "gbuffer_callback_queued" \
						if queued else "gbuffer_operation_not_scheduled"
			else:
				_magicdawn_runtime_state["screen_cache_status"] = "unsupported_view_or_context"
		else:
			_replacement_request_prepared = false
			_magicdawn_runtime_state["status"] = "native_clv_prepare_failed_fail_closed"
			_magicdawn_runtime_state["native_inputs_published"] = false
			if not _magicdawn_runtime_state.has("fallback_reason"):
				_magicdawn_runtime_state["fallback_reason"] = "clipmap_or_native_binding_unavailable"
			ctx.clear_magic_gi_clv_inputs()
		return
	if _is_magicdawn_authored_snapshot(snapshot):
		if not native_baked_sh_lighting_enabled:
			_native_baked_sh_state["status"] = "standalone_a_b_selected"
			_native_baked_sh_state["fallback_reason"] = "native_baked_sh_disabled"
			return
		if bool(snapshot.get("streamed", false)):
			_native_baked_sh_state["status"] = "streamed_not_supported"
			_native_baked_sh_state["fallback_reason"] = "streamed_combined_field_not_ready"
			return
		if _magicdawn_debug_sidecar_requested(buffers):
			_magicdawn_debug_sidecar_forced = true
			_native_baked_sh_state["status"] = "debug_sidecar_forced_standalone"
			_native_baked_sh_state["fallback_reason"] = "debug_buffers_magic_gi_selected"
			return
		var prepare_cpu_start_usec := Time.get_ticks_usec()
		_prepare_native_magicdawn_baked_sh(ctx, buffers, snapshot, resolved,
				replacement_requested)
		_last_native_prepare_cpu_usec = Time.get_ticks_usec() - prepare_cpu_start_usec
		return
	if native_clv_lighting_enabled and _can_prepare_native_prt(ctx, buffers, snapshot):
		var prepare_cpu_start_usec := Time.get_ticks_usec()
		_prepare_native_prt_clv(ctx, buffers, snapshot, resolved, replacement_requested)
		_last_native_prepare_cpu_usec = Time.get_ticks_usec() - prepare_cpu_start_usec
	elif _native_prepare_diagnostics_enabled and native_clv_lighting_enabled \
			and _last_native_prepare_rejection == "prepare_started":
		_last_native_prepare_rejection = "native_prepare_not_eligible"
	elif _native_prepare_diagnostics_enabled and not native_clv_lighting_enabled:
		_last_native_prepare_rejection = "native_disabled"

func _single_free_space_source_snapshot(snapshot: Dictionary) -> Dictionary:
	if snapshot.get("prepared_source_header") is Resource:
		return snapshot
	if snapshot.get("free_space_volume_source") is Resource:
		return snapshot if bool(snapshot.get("free_space_source_ready", false)) \
				and str(snapshot.get("free_space_source_status", "")) == "ready" else {}
	var pages_value: Variant = snapshot.get("pages", [])
	if not pages_value is Array:
		return {}
	var source_pages: Array[Dictionary] = []
	for page_value in pages_value:
		if page_value is Dictionary and page_value.get("free_space_volume_source") is Resource:
			source_pages.append(page_value)
	if source_pages.size() != 1:
		return {}
	var merged := snapshot.duplicate()
	merged.merge(source_pages[0], true)
	merged["data"] = null
	return merged if bool(merged.get("free_space_source_ready", false)) \
			and str(merged.get("free_space_source_status", "")) == "ready" else {}

func _publish_preinterpolated_editor_snapshot(ctx: FRPPassContext, snapshot: Dictionary) -> void:
	if not _dynamic_volume_cache is PreinterpolatedVolumeCache:
		return
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	var target := buffers.get_render_target() if buffers != null else RID()
	var volume_id := int(snapshot.get("volume_id", 0))
	if not target.is_valid() or not CLVEditorSnapshot.has_request(volume_id, target.get_id()):
		return
	var state: Dictionary = _dynamic_volume_cache.get_runtime_state()
	var request := CLVEditorSnapshot.claim(volume_id, target.get_id(),
		_dynamic_volume_cache_key, int(state.get("relight_revision", 0)),
		int(state.get("clipmap_update_count", 0)))
	if request.is_empty():
		return
	var error: Error = _dynamic_volume_cache.request_editor_snapshot(
		RenderingServer.get_rendering_device(), request)
	if error != OK:
		CLVEditorSnapshot.fail(request, "clv_readback_queue_failed_%d" % error)

func _prepare_native_dynamic_volume(ctx: FRPPassContext,
		buffers: RenderSceneBuffersRD, snapshot: Dictionary,
		resolved_parameters: Variant, replacement_requested: bool) -> void:
	_dynamic_volume_screen_runtime_state = {"status": "prepare_started",
		"frame": Engine.get_frames_drawn(), "active": false,
		"frame_token": -1, "dispatch_token": 0}
	if ctx != null and ctx.has_method("clear_magic_gi_dynamic_screen_cache_inputs"):
		ctx.call("clear_magic_gi_dynamic_screen_cache_inputs")
	_dynamic_volume_runtime_state = {"status": "prepare_started",
		"frame": Engine.get_frames_drawn(), "active": false,
		"publication_token": 0, "fallback_reason": "prepare_started"}
	if ctx == null or buffers == null or not ctx.has_method("set_magic_gi_dynamic_volume_input") \
			or not ctx.has_method("get_frame_token"):
		_dynamic_volume_runtime_state["status"] = "bridge_unavailable"
		_dynamic_volume_runtime_state["fallback_reason"] = "missing_context_or_dynamic_volume_api"
		return
	var view_count := buffers.get_view_count()
	if view_count < 1 or view_count > 2:
		_dynamic_volume_runtime_state["status"] = "unsupported_view_count"
		_dynamic_volume_runtime_state["fallback_reason"] = "view_count:%d" % view_count
		return
	var paged := snapshot.get("prepared_source_header") is Resource
	if paged and (not ctx.has_method("get_magic_gi_paged_prepared_abi_version") \
			or int(ctx.call("get_magic_gi_paged_prepared_abi_version")) != 1 \
			or not ctx.has_method("get_magic_gi_paged_prepared_layout_version") \
			or int(ctx.call("get_magic_gi_paged_prepared_layout_version")) != 6 \
			or not ctx.has_method("get_magic_gi_paged_prepared_parameters_size") \
			or int(ctx.call("get_magic_gi_paged_prepared_parameters_size")) != 208 \
			or not ctx.has_method("get_magic_gi_paged_prepared_max_lods") \
			or int(ctx.call("get_magic_gi_paged_prepared_max_lods")) < 10):
		ctx.call("clear_magic_gi_dynamic_volume_inputs")
		_dynamic_volume_runtime_state["status"] = "paged_prepared_bridge_incompatible"
		_dynamic_volume_runtime_state["fallback_reason"] = "engine_requires_paged_clv_abi_1"
		return
	var source_value: Variant = snapshot.get("prepared_source_header") if paged \
		else snapshot.get("free_space_volume_source")
	if not source_value is Resource:
		_dynamic_volume_runtime_state["status"] = "source_missing"
		_dynamic_volume_runtime_state["fallback_reason"] = "free_space_volume_source_missing"
		return
	var source: Resource = source_value
	var source_signature := str(snapshot.get("free_space_source_signature", ""))
	if paged:
		source_signature = str(source.get("directional_source_signature"))
	var validated := bool(snapshot.get("free_space_source_validated", false)) \
			and int(snapshot.get("free_space_source_instance_id", 0)) == source.get_instance_id() \
			and source_signature == str(source.get("directional_source_signature"))
	var expected_geometry_signature := int(snapshot.get("geometry_signature",
			source.get("geometry_signature")))
	validated = validated and expected_geometry_signature == int(source.get("geometry_signature"))
	if paged:
		validated = source.has_method("is_paged_prepared_source") \
			and bool(source.call("is_paged_prepared_source")) \
			and expected_geometry_signature == int(source.get("geometry_signature"))
	if not source.has_method("is_header_valid") \
			or not bool(source.call("is_header_valid")) \
			or (not validated and (not source.has_method("is_valid") \
				or not bool(source.call("is_valid")))):
		_dynamic_volume_runtime_state["status"] = "source_rejected"
		_dynamic_volume_runtime_state["fallback_reason"] = "source_validation_token_or_header_invalid"
		return
	var cache_key := str(snapshot.get("cache_key", ""))
	if cache_key.is_empty():
		_dynamic_volume_runtime_state["status"] = "source_rejected"
		_dynamic_volume_runtime_state["fallback_reason"] = "missing_source_cache_key"
		return
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_dynamic_volume_runtime_state["status"] = "source_rejected"
		_dynamic_volume_runtime_state["fallback_reason"] = "rendering_device_unavailable"
		return
	var render_data := ctx.get_render_data()
	var scene_data := render_data.get_render_scene_data() if render_data != null else null
	if scene_data == null:
		_dynamic_volume_runtime_state["status"] = "scene_data_missing"
		_dynamic_volume_runtime_state["fallback_reason"] = "scene_data_missing"
		return
	var camera_transform: Transform3D = scene_data.get_cam_transform()
	var camera_world := camera_transform.origin
	var camera_forward := -camera_transform.basis.z
	if camera_forward.length_squared() > 1e-8:
		camera_forward = camera_forward.normalized()
	else:
		camera_forward = Vector3.FORWARD
	var page_key := str(snapshot.get("free_space_source_page_key", cache_key))
	var use_prepared: bool = source.has_method("has_preinterpolated_clv") and source.has_preinterpolated_clv()
	var selected_prepared_resolution := _effective_prepared_clv_resolution()
	var cache_identity := "%s:%s:%d:%d:%s:angular%d" % [cache_key, page_key,
			source.get_instance_id(), expected_geometry_signature, source_signature,
		dynamic_volume_response_resolution]
	if use_prepared:
		cache_identity += ":prepared%d" % selected_prepared_resolution
	var gi_radius_m := float(snapshot.get("gi_radius_m", 512.0))
	var gpu_budget_bytes := int(snapshot.get("gpu_budget_bytes", 128 * 1024 * 1024))
	if paged:
		cache_identity += ":paged6:radius%s:budget%d" % [str(gi_radius_m), gpu_budget_bytes]
	if _dynamic_volume_cache == null or _dynamic_volume_cache_key != cache_identity:
		if _dynamic_volume_cache != null and _dynamic_volume_cache.has_method("owned_rids"):
			_free_rids(rd, _dynamic_volume_cache.call("owned_rids"))
		_dynamic_volume_cache = null
		_dynamic_volume_cache_key = ""
		# The base pass snapshots owned RIDs for deferred teardown. Refresh as soon
		# as the old cache is detached so a failed replacement cannot free it twice.
		_sync_owned_rid_snapshot()
		var new_cache: Variant = PagedPreparedVolumeCache.new() if paged else \
			(PreinterpolatedVolumeCache.new() if use_prepared else DynamicVolumeCache.new())
		if use_prepared:
			new_cache.resolution = selected_prepared_resolution
		var created := false
		if paged:
			new_cache.gpu_budget_bytes = gpu_budget_bytes
			new_cache.requested_upload_budget_bytes = int(snapshot.get("streaming_budget", {}).get("upload_bytes_per_frame", 0))
			created = new_cache.create_paged(rd, source, snapshot.get("prepared_transfer_pages", []),
				int(snapshot.get("prepared_pages_revision", 0)), camera_world, gi_radius_m)
		else:
			created = new_cache.create(rd, source, validated,
				dynamic_volume_response_resolution, camera_world, camera_forward)
		if not created:
			if new_cache.has_method("owned_rids"):
				_free_rids(rd, new_cache.call("owned_rids"))
			_dynamic_volume_runtime_state["status"] = "cache_create_failed"
			_dynamic_volume_runtime_state["fallback_reason"] = str(new_cache.get_runtime_state().get("last_error", "unknown"))
			return
		_dynamic_volume_cache = new_cache
		_dynamic_volume_cache_key = cache_identity
		_dynamic_volume_source_instance_id = source.get_instance_id()
		_sync_owned_rid_snapshot()
	var cache: Variant = _dynamic_volume_cache
	if paged:
		cache.requested_upload_budget_bytes = int(snapshot.get("streaming_budget", {}).get("upload_bytes_per_frame", 0))
	var clipmap_updated: bool = cache.update_pages(rd, source, snapshot.get("prepared_transfer_pages", []),
		int(snapshot.get("prepared_pages_revision", 0)), camera_world, gi_radius_m) if paged \
		else bool(cache.call("update_clipmap", rd, source, camera_world, false, camera_forward))
	if paged:
		# Paging may replace its compact GPU operator pool, including on failure.
		_sync_owned_rid_snapshot()
	if not clipmap_updated:
		_dynamic_volume_runtime_state["status"] = "clipmap_update_failed"
		_dynamic_volume_runtime_state["fallback_reason"] = str(cache.get_runtime_state().get("last_error", "unknown"))
		return
	var owner_transform: Variant = snapshot.get("owner_transform", source.get("source_transform_world"))
	var owner_size: Variant = snapshot.get("owner_size", source.get("source_size_m"))
	if not owner_transform is Transform3D or not owner_size is Vector3 \
			or minf(owner_size.x, minf(owner_size.y, owner_size.z)) <= 0.0:
		_dynamic_volume_runtime_state["status"] = "owner_invalid"
		_dynamic_volume_runtime_state["fallback_reason"] = "owner_transform_or_size_invalid"
		return
	var previous_snapshot := _frame_snapshot
	var previous_scene_data := _frame_scene_data
	var previous_parameters := _frame_parameters
	var previous_replacement := _frame_replacement_enabled
	var previous_pre_exposure := _pre_exposure
	var previous_scene_normalization := _scene_exposure_normalization
	_frame_snapshot = snapshot
	_frame_scene_data = scene_data
	_frame_parameters = resolved_parameters
	_frame_replacement_enabled = replacement_requested
	_pre_exposure = ctx.get_pre_exposure(0)
	_scene_exposure_normalization = _get_scene_exposure_normalization(ctx)
	var lighting_ubo_ok := _update_frame_ubo(snapshot, scene_data, 0, rd)
	var relight_ok: bool = lighting_ubo_ok and bool(cache.call("relight", rd, _ubo,
			snapshot, gpu_timestamp_profiling_enabled))
	var owner_ok := relight_ok
	var owner_ubos: Array[RID] = []
	for view in view_count:
		if not owner_ok:
			break
		owner_ok = (_write_magicdawn_native_owner_parameters(rd, view,
				snapshot, replacement_requested, _scene_exposure_normalization)
			and _magicdawn_native_owner_ubos[view].is_valid()
			and owner_transform is Transform3D and owner_size is Vector3)
		owner_ubos.append(_magicdawn_native_owner_ubos[view])
	var token := _next_magicdawn_publication_token()
	var frame_token := int(ctx.call("get_frame_token"))
	if owner_ok and frame_token > 0:
		var fields: Array = cache.get_field_textures()
		var moments: RID = cache.get_moments_texture()
		var relocation: RID = cache.get_relocation_buffer()
		var validity_buffer: RID = cache.get_validity_buffer()
		for view in view_count:
			ctx.call("set_magic_gi_dynamic_volume_input", view, fields,
					cache.parameters, owner_ubos[view], cache.dimensions,
					moments, relocation, validity_buffer, cache.origin_world,
					cache.spacing_m, cache.response_resolution,
					int(cache.get_runtime_state().get("layout_version", DynamicVolumeCache.LAYOUT_VERSION)), token, frame_token)
			owner_ok = owner_ok and bool(ctx.call("has_magic_gi_dynamic_volume_input", view))
		if not owner_ok:
			ctx.call("clear_magic_gi_dynamic_volume_inputs")
			_dynamic_volume_runtime_state["status"] = "volume_lease_rejected"
			_dynamic_volume_runtime_state["fallback_reason"] = "context_rejected_current_volume_lease"
	if owner_ok and frame_token > 0:
		# Prepared CLV replaces the shader's local sky diffuse directly. Neither
		# its native consumer nor its debug mirror reads the separate sky MRT.
		# Keep the output request for older layouts' screen replacement paths;
		# other passes retain their own requests through the shared context.
		var needs_sky_diffuse_output := replacement_requested \
				and int(cache.get_runtime_state().get("layout_version", 0)) not in [5, 6]
		if needs_sky_diffuse_output:
			ctx.request_sky_light_diffuse()
		_replacement_request_prepared = replacement_requested
		_dynamic_volume_publication_token = token
		var published_cache_state: Dictionary = cache.get_runtime_state()
		_dynamic_volume_runtime_state = {
			"status": "published_waiting_for_renderer",
			"frame": Engine.get_frames_drawn(), "frame_token": frame_token,
			"publication_token": token, "cache_identity": cache_identity,
			"source_validated": validated, "source_instance_id": source.get_instance_id(),
			"source_signature": source_signature, "active": false,
			"owner_control_w_published": float(_magicdawn_receiver_qa_mode),
			"receiver_sample_qa_mode_published": _magicdawn_receiver_qa_mode,
			"owner_parameters_rid_id": owner_ubos[0].get_id() if not owner_ubos.is_empty() \
					and owner_ubos[0].is_valid() else 0,
			"replacement_requested": replacement_requested,
			"sky_diffuse_output_requested": needs_sky_diffuse_output,
			"cache": published_cache_state,
			"clipmap_resolution": int(published_cache_state.get("clipmap_resolution", 16)),
			"valid_resident_cells": int(published_cache_state.get("valid_resident_cells", 0)),
			"clip_cell_count": int(published_cache_state.get("clip_cell_count", 0)),
			"fallback_reason": "awaiting_native_draw"}
		_dynamic_volume_screen_runtime_state = {"status": "waiting_for_gbuffer",
			"frame_token": frame_token, "source_publication_token": token,
			"cache_revision": int(cache.get_runtime_state().get("relight_revision", -1)),
			"dispatch_token": int(cache.get_runtime_state().get("dispatch_count", 0)),
			"active": false, "half_size": Vector2i.ZERO}
		if int(cache.get_runtime_state().get("layout_version", 0)) in [5, 6]:
			_dynamic_volume_screen_runtime_state["status"] = "native_preinterpolated_clv"
		elif view_count == 1 and ctx.has_method("enqueue_after_operation"):
			var frame_ubo_bytes := _build_dynamic_volume_screen_frame_bytes(scene_data,
					buffers.get_internal_size())
			if frame_ubo_bytes.size() == MAGIC_GI_DYNAMIC_SCREEN_FRAME_UBO_BYTES:
				var callback := Callable(self,
						"_render_dynamic_volume_screen_cache_after_gbuffer").bind(
					buffers, cache, owner_ubos[0], token, frame_token,
					int(_dynamic_volume_screen_runtime_state["cache_revision"]),
					int(_dynamic_volume_screen_runtime_state["dispatch_token"]),
					frame_ubo_bytes)
				var queued := bool(ctx.call("enqueue_after_operation",
						NativeSpec.PASS_GBUFFER, callback))
				_dynamic_volume_screen_runtime_state["status"] = \
						"gbuffer_callback_queued" if queued else "gbuffer_operation_not_scheduled"
			else:
				_dynamic_volume_screen_runtime_state["status"] = "frame_ubo_pack_failed"
				_dynamic_volume_screen_runtime_state["fallback_reason"] = "frame_ubo_size_or_projection_invalid"
		else:
			_dynamic_volume_screen_runtime_state["status"] = "unsupported_view_or_callback_api"
	else:
		if str(_dynamic_volume_runtime_state.get("status", "")) != "volume_lease_rejected":
			_dynamic_volume_runtime_state["status"] = "prepare_failed"
			_dynamic_volume_runtime_state["fallback_reason"] = "ubo_relight_or_owner_setup_failed"
		_dynamic_volume_screen_runtime_state["status"] = "volume_prepare_failed"
		_dynamic_volume_screen_runtime_state["fallback_reason"] = \
				str(_dynamic_volume_runtime_state.get("fallback_reason", "prepare_failed"))
	_frame_snapshot = previous_snapshot
	_frame_scene_data = previous_scene_data
	_frame_parameters = previous_parameters
	_frame_replacement_enabled = previous_replacement
	_pre_exposure = previous_pre_exposure
	_scene_exposure_normalization = previous_scene_normalization

func _build_dynamic_volume_screen_frame_bytes(scene_data: RenderSceneData,
		full_size: Vector2i, view := 0) -> PackedByteArray:
	if scene_data == null or view < 0 or view >= scene_data.get_view_count() \
			or full_size.x <= 0 or full_size.y <= 0:
		return PackedByteArray()
	var values := PackedFloat32Array()
	_append_projection(values, scene_data.get_view_projection(view).inverse())
	_append_transform(values, Transform3D.IDENTITY)
	var camera: Transform3D = scene_data.get_cam_transform()
	_append_transform(values, Transform3D(camera.basis.orthonormalized(), camera.origin))
	values.append_array(PackedFloat32Array([float(full_size.x), float(full_size.y), 1.0, 1.0]))
	values.append_array(PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))
	for _lane in 56:
		values.append(0.0)
	if values.size() * 4 != MAGIC_GI_DYNAMIC_SCREEN_FRAME_UBO_BYTES:
		return PackedByteArray()
	for value in values:
		if not is_finite(value):
			return PackedByteArray()
	return values.to_byte_array()

func _ensure_dynamic_volume_screen_resolve_resources(rd: RenderingDevice) -> bool:
	if rd == null:
		_dynamic_volume_screen_runtime_state["status"] = "rendering_device_unavailable"
		return false
	if _dynamic_volume_screen_resolve_shader_resource == null:
		var shader_value := ResourceLoader.load(MAGIC_GI_DYNAMIC_SCREEN_RESOLVE_SHADER_PATH)
		if not shader_value is RDShaderFile:
			_dynamic_volume_screen_runtime_state["status"] = "screen_shader_resource_unavailable"
			return false
		_dynamic_volume_screen_resolve_shader_resource = shader_value as RDShaderFile
	if not _dynamic_volume_screen_resolve_shader.is_valid():
		var spirv := _dynamic_volume_screen_resolve_shader_resource.get_spirv()
		if spirv == null or not spirv.compile_error_compute.is_empty() \
				or spirv.bytecode_compute.is_empty():
			_dynamic_volume_screen_runtime_state["status"] = \
					"screen_shader_compile_failed:%s" % (
					spirv.compile_error_compute if spirv != null else "missing_spirv")
			return false
		_dynamic_volume_screen_resolve_shader = rd.shader_create_from_spirv(spirv,
				"Magic GI Dynamic Volume Screen Resolve")
		if not _dynamic_volume_screen_resolve_shader.is_valid():
			_dynamic_volume_screen_runtime_state["status"] = "screen_shader_create_failed"
			return false
	if not _dynamic_volume_screen_resolve_pipeline.is_valid():
		_dynamic_volume_screen_resolve_pipeline = rd.compute_pipeline_create(
				_dynamic_volume_screen_resolve_shader)
		if not _dynamic_volume_screen_resolve_pipeline.is_valid():
			_dynamic_volume_screen_runtime_state["status"] = "screen_pipeline_create_failed"
			return false
	if not _dynamic_volume_screen_nearest_sampler.is_valid():
		var nearest_state := RDSamplerState.new()
		nearest_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		nearest_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		nearest_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		nearest_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		nearest_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		nearest_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_dynamic_volume_screen_nearest_sampler = rd.sampler_create(nearest_state)
	if not _dynamic_volume_screen_nearest_sampler.is_valid():
		_dynamic_volume_screen_runtime_state["status"] = "screen_nearest_sampler_create_failed"
		return false
	if not _dynamic_volume_screen_linear_sampler.is_valid():
		var linear_state := RDSamplerState.new()
		linear_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		linear_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		linear_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		linear_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		linear_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		linear_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_dynamic_volume_screen_linear_sampler = rd.sampler_create(linear_state)
	if not _dynamic_volume_screen_linear_sampler.is_valid():
		_dynamic_volume_screen_runtime_state["status"] = "screen_linear_sampler_create_failed"
		return false
	if not _dynamic_volume_screen_diagnostics_buffer.is_valid():
		var diagnostic_zero := PackedByteArray()
		diagnostic_zero.resize(MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_BYTES)
		_dynamic_volume_screen_diagnostics_buffer = rd.storage_buffer_create(
				MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_BYTES, diagnostic_zero)
	if not _dynamic_volume_screen_diagnostics_buffer.is_valid():
		_dynamic_volume_screen_runtime_state["status"] = "screen_diagnostics_buffer_create_failed"
		return false
	if not _dynamic_volume_screen_frame_ubo.is_valid():
		var zero_frame := PackedByteArray()
		zero_frame.resize(MAGIC_GI_DYNAMIC_SCREEN_FRAME_UBO_BYTES)
		_dynamic_volume_screen_frame_ubo = rd.uniform_buffer_create(
				MAGIC_GI_DYNAMIC_SCREEN_FRAME_UBO_BYTES, zero_frame)
	if not _dynamic_volume_screen_frame_ubo.is_valid():
		_dynamic_volume_screen_runtime_state["status"] = "screen_frame_ubo_create_failed"
		return false
	_sync_owned_rid_snapshot()
	return true

func _dynamic_volume_screen_texture_matches(rd: RenderingDevice, texture: RID,
		expected_size: Vector2i, expected_format: int) -> bool:
	if rd == null or not texture.is_valid() or not rd.texture_is_valid(texture) \
			or expected_size.x <= 0 or expected_size.y <= 0:
		return false
	var format: RDTextureFormat = rd.texture_get_format(texture)
	return format.texture_type == RenderingDevice.TEXTURE_TYPE_2D \
			and (expected_format < 0 or format.format == expected_format) \
			and format.width == expected_size.x and format.height == expected_size.y \
			and format.samples == RenderingDevice.TEXTURE_SAMPLES_1 \
			and (format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) != 0

func arm_magic_gi_dynamic_volume_screen_diagnostics_for_runner() -> Dictionary:
	if _dynamic_volume_screen_diagnostic_armed or _dynamic_volume_screen_diagnostic_pending:
		return {"accepted": false, "error": "diagnostic_already_armed_or_pending"}
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _ensure_dynamic_volume_screen_resolve_resources(rd):
		return {"accepted": false, "error": "screen_diagnostics_unavailable"}
	if rd.buffer_clear(_dynamic_volume_screen_diagnostics_buffer, 0,
			MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_BYTES) != OK:
		return {"accepted": false, "error": "screen_diagnostic_buffer_clear_failed"}
	_dynamic_volume_screen_diagnostic_armed = true
	_dynamic_volume_screen_diagnostic_owner_packet.clear()
	_dynamic_volume_screen_diagnostic_counts.clear()
	_dynamic_volume_screen_diagnostic_result = {"status": "armed",
		"counter_schema": "dynamic_volume_screen_route_v1"}
	return {"accepted": true, "counter_schema": "dynamic_volume_screen_route_v1"}

func get_magic_gi_dynamic_volume_screen_diagnostics() -> Dictionary:
	var result := _dynamic_volume_screen_diagnostic_result.duplicate(true)
	result["pending"] = _dynamic_volume_screen_diagnostic_pending
	return result

func _decode_dynamic_volume_owner_packet(data: PackedByteArray) -> Dictionary:
	if data.size() != MAGICDAWN_NATIVE_OWNER_PARAMETER_BYTES:
		return {"status": "owner_packet_size_mismatch", "actual_bytes": data.size(),
			"expected_bytes": MAGICDAWN_NATIVE_OWNER_PARAMETER_BYTES}
	var values := data.to_float32_array()
	if values.size() != 24:
		return {"status": "owner_packet_word_count_mismatch", "actual_floats": values.size()}
	for value in values:
		if not is_finite(value):
			return {"status": "owner_packet_non_finite"}
	return {"status": "readback_complete", "layout": "mat4+size4+control4",
		"owner_size": [values[16], values[17], values[18]],
		"replacement_requested": values[19] > 0.5,
		"strength": values[20], "sky_owner": values[21] > 0.5,
		"normalization": values[22], "control_w_qa_mode": values[23],
		"control_offset_bytes": 80}

func read_magic_gi_dynamic_volume_screen_diagnostics_for_runner() -> Dictionary:
	if not _dynamic_volume_screen_diagnostic_pending:
		return get_magic_gi_dynamic_volume_screen_diagnostics()
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _dynamic_volume_screen_diagnostics_buffer.is_valid() \
			or not _dynamic_volume_screen_diagnostic_owner_parameters.is_valid():
		return _fail_dynamic_volume_screen_diagnostic_readback({
			"status": "readback_resources_unavailable"})
	# This one-shot runner read happens after frame_post_draw, outside the render callback.
	var counter_bytes := rd.buffer_get_data(_dynamic_volume_screen_diagnostics_buffer,
			0, MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_BYTES)
	var owner_bytes := rd.buffer_get_data(_dynamic_volume_screen_diagnostic_owner_parameters,
			0, MAGICDAWN_NATIVE_OWNER_PARAMETER_BYTES)
	if counter_bytes.size() != MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_BYTES:
		return _fail_dynamic_volume_screen_diagnostic_readback({"status": "counter_size_mismatch",
			"actual_bytes": counter_bytes.size(),
			"expected_bytes": MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_BYTES,
			"frame_token": int(_dynamic_volume_screen_diagnostic_metadata.get("frame_token", -1)),
			"cache_revision": int(_dynamic_volume_screen_diagnostic_metadata.get("cache_revision", -1)),
			"dispatch_serial": int(_dynamic_volume_screen_diagnostic_metadata.get("dispatch_serial", -1))})
	if owner_bytes.size() != MAGICDAWN_NATIVE_OWNER_PARAMETER_BYTES:
		return _fail_dynamic_volume_screen_diagnostic_readback({"status": "owner_packet_size_mismatch",
			"actual_bytes": owner_bytes.size(),
			"expected_bytes": MAGICDAWN_NATIVE_OWNER_PARAMETER_BYTES})
	var raw := counter_bytes.to_int32_array()
	if raw.size() != MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_COUNTER_NAMES.size():
		return _fail_dynamic_volume_screen_diagnostic_readback({"status": "counter_word_count_mismatch",
			"actual_words": raw.size(),
			"expected_words": MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_COUNTER_NAMES.size()})
	var counts: Dictionary = {}
	for index in MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_COUNTER_NAMES.size():
		counts[MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_COUNTER_NAMES[index]] = maxi(0, raw[index])
	var tile_count := maxi(1, int(counts.get("tile_count", 0)))
	counts["coherent_tile_fraction"] = float(counts.get("coherent_tiles", 0)) / float(tile_count)
	counts["edge_tile_fraction"] = float(counts.get("edge_tiles", 0)) / float(tile_count)
	counts["calls_per_receiver"] = float(counts.get("sample_calls", 0)) \
			/ maxf(1.0, float(counts.get("valid_receivers", 0)))
	var owner_packet := _decode_dynamic_volume_owner_packet(owner_bytes)
	if String(owner_packet.get("status", "")) != "readback_complete":
		return _fail_dynamic_volume_screen_diagnostic_readback(owner_packet)
	_dynamic_volume_screen_diagnostic_pending = false
	_dynamic_volume_screen_diagnostic_owner_parameters = RID()
	_dynamic_volume_screen_diagnostic_counts = counts
	_dynamic_volume_screen_diagnostic_owner_packet = owner_packet
	_dynamic_volume_screen_diagnostic_result = {"status": "complete",
		"frame_token": int(_dynamic_volume_screen_diagnostic_metadata.get("frame_token", -1)),
		"cache_revision": int(_dynamic_volume_screen_diagnostic_metadata.get("cache_revision", -1)),
		"dispatch_serial": int(_dynamic_volume_screen_diagnostic_metadata.get("dispatch_serial", -1)),
		"half_size": _dynamic_volume_screen_diagnostic_metadata.get("half_size", Vector2i.ZERO),
		"counts": counts,
		"owner_packet": owner_packet,
		"counter_schema": "dynamic_volume_screen_route_v1"}
	_dynamic_volume_screen_runtime_state["diagnostics"] = \
			_dynamic_volume_screen_diagnostic_result.duplicate(true)
	print("[MAGIC_GI_DYNAMIC_SCREEN_ROUTE_DIAGNOSTICS] " +
			JSON.stringify(_dynamic_volume_screen_diagnostic_result))
	return get_magic_gi_dynamic_volume_screen_diagnostics()

func _fail_dynamic_volume_screen_diagnostic_readback(details: Dictionary) -> Dictionary:
	_dynamic_volume_screen_diagnostic_pending = false
	_dynamic_volume_screen_diagnostic_token += 1
	_dynamic_volume_screen_diagnostic_owner_parameters = RID()
	_dynamic_volume_screen_diagnostic_result = details.duplicate(true)
	_dynamic_volume_screen_diagnostic_result["status"] = "readback_failed"
	return _dynamic_volume_screen_diagnostic_result

func _render_dynamic_volume_screen_cache_after_gbuffer(ctx: FRPPassContext,
		buffers: RenderSceneBuffersRD, cache: RefCounted, owner_parameters: RID,
		source_publication_token: int, frame_token: int, cache_revision: int,
		cache_dispatch_count: int, frame_bytes: PackedByteArray) -> void:
	if ctx == null or buffers == null:
		_dynamic_volume_screen_runtime_state["status"] = "invalid_callback_context"
		return
	ctx.call("clear_magic_gi_dynamic_screen_cache_inputs")
	if buffers.get_view_count() != 1 or not ctx.has_method("get_frame_token") \
			or int(ctx.call("get_frame_token")) != frame_token \
			or not ctx.has_method("has_magic_gi_dynamic_volume_input") \
			or not bool(ctx.call("has_magic_gi_dynamic_volume_input", 0)) \
			or source_publication_token <= 0 or cache == null \
			or cache != _dynamic_volume_cache:
		_dynamic_volume_screen_runtime_state["status"] = "source_or_frame_lease_mismatch"
		return
	var cache_state_value: Variant = cache.call("get_runtime_state") \
			if cache.has_method("get_runtime_state") else {}
	if not cache_state_value is Dictionary:
		_dynamic_volume_screen_runtime_state["status"] = "cache_state_unavailable"
		return
	var cache_state: Dictionary = cache_state_value
	if not bool(cache.call("is_ready")) \
			or int(cache_state.get("relight_revision", -1)) != cache_revision \
			or int(cache_state.get("dispatch_count", -1)) != cache_dispatch_count:
		_dynamic_volume_screen_runtime_state["status"] = "cache_relight_revision_mismatch"
		return
	if frame_bytes.size() != MAGIC_GI_DYNAMIC_SCREEN_FRAME_UBO_BYTES:
		_dynamic_volume_screen_runtime_state["status"] = "screen_frame_ubo_payload_invalid"
		return
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not owner_parameters.is_valid() or not cache.parameters.is_valid() \
			or not cache.get_moments_texture().is_valid() \
			or not cache.get_relocation_buffer().is_valid() \
			or not cache.get_validity_buffer().is_valid():
		_dynamic_volume_screen_runtime_state["status"] = "screen_source_resources_unavailable"
		return
	var depth: RID = inputs[1].get_texture(buffers, 0) if inputs.size() > 1 else RID()
	var normal: RID = inputs[2].get_texture(buffers, 0) if inputs.size() > 2 else RID()
	var half_incident: RID = buffers.get_texture(NativeSpec.SCOPE_PIPELINE,
			MAGIC_GI_DYNAMIC_SCREEN_HALF_INCIDENT)
	var half_guide: RID = buffers.get_texture(NativeSpec.SCOPE_PIPELINE,
			MAGIC_GI_DYNAMIC_SCREEN_HALF_GUIDE)
	var edge_incident: RID = buffers.get_texture(NativeSpec.SCOPE_PIPELINE,
			MAGIC_GI_DYNAMIC_SCREEN_EDGE_INCIDENT)
	var full_size: Vector2i = buffers.get_internal_size()
	var half_size: Vector2i = buffers.get_texture_slice_size(NativeSpec.SCOPE_PIPELINE,
			MAGIC_GI_DYNAMIC_SCREEN_HALF_INCIDENT, 0)
	var expected_half := Vector2i(floori(float(full_size.x + 1) * 0.5),
			floori(float(full_size.y + 1) * 0.5))
	if half_size != expected_half \
			or not _dynamic_volume_screen_texture_matches(rd, depth, full_size,
					-1) \
			or not _dynamic_volume_screen_texture_matches(rd, normal, full_size,
					RenderingDevice.DATA_FORMAT_A2B10G10R10_UNORM_PACK32) \
			or not _dynamic_volume_screen_texture_matches(rd, half_incident, half_size,
					RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT) \
			or not _dynamic_volume_screen_texture_matches(rd, half_guide, half_size,
					RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT) \
			or not _dynamic_volume_screen_texture_matches(rd, edge_incident, full_size,
					RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT):
		_dynamic_volume_screen_runtime_state["status"] = "screen_attachment_format_or_size_mismatch"
		return
	if not _ensure_dynamic_volume_screen_resolve_resources(rd):
		return
	if rd.buffer_update(_dynamic_volume_screen_frame_ubo, 0, frame_bytes.size(), frame_bytes) != OK:
		_dynamic_volume_screen_runtime_state["status"] = "screen_frame_ubo_update_failed"
		return
	_dynamic_volume_screen_frame_bytes = frame_bytes.duplicate()
	var field_textures: Array = cache.get_field_textures()
	if field_textures.size() != 1 or not field_textures[0].is_valid():
		_dynamic_volume_screen_runtime_state["status"] = "screen_response_field_unavailable"
		return
	var set0 := UniformSetCacheRD.get_cache(_dynamic_volume_screen_resolve_shader, 0, [
		U.sampled(0, _dynamic_volume_screen_nearest_sampler, depth),
		U.sampled(1, _dynamic_volume_screen_nearest_sampler, normal),
		U.image(2, half_incident), U.image(3, half_guide), U.image(4, edge_incident),
		U.uniform_buffer(5, _dynamic_volume_screen_frame_ubo),
		U.storage_buffer(6, _dynamic_volume_screen_diagnostics_buffer)])
	var set1 := UniformSetCacheRD.get_cache(_dynamic_volume_screen_resolve_shader, 1, [
		_magicdawn_sampler_uniform(62, _dynamic_volume_screen_linear_sampler),
		_magicdawn_texture_uniform(69, field_textures[0]),
		U.uniform_buffer(76, cache.parameters), U.uniform_buffer(77, owner_parameters),
		_magicdawn_texture_uniform(87, cache.get_moments_texture()),
		U.storage_buffer(88, cache.get_relocation_buffer()),
		U.storage_buffer(89, cache.get_validity_buffer())])
	if not set0.is_valid() or not set1.is_valid():
		_dynamic_volume_screen_runtime_state["status"] = "screen_uniform_set_creation_failed"
		return
	var diagnostic_this_dispatch := _dynamic_volume_screen_diagnostic_armed \
			and not _dynamic_volume_screen_diagnostic_pending
	if diagnostic_this_dispatch and rd.buffer_clear(_dynamic_volume_screen_diagnostics_buffer,
			0, MAGIC_GI_DYNAMIC_SCREEN_DIAGNOSTIC_BYTES) != OK:
		_dynamic_volume_screen_diagnostic_armed = false
		_dynamic_volume_screen_diagnostic_result = {"status": "diagnostic_buffer_clear_failed"}
		diagnostic_this_dispatch = false
	var push := PackedInt32Array([full_size.x, full_size.y,
		half_size.x, half_size.y, 1 if diagnostic_this_dispatch else 0, 0]).to_byte_array()
	if push.size() != MAGIC_GI_DYNAMIC_SCREEN_PUSH_BYTES:
		_dynamic_volume_screen_runtime_state["status"] = "screen_push_constant_size_mismatch"
		return
	rd.draw_command_begin_label("Magic GI Dynamic Volume Screen Resolve", Color(0.25, 0.75, 0.9))
	_capture_gpu_timestamp(rd, "Dynamic Screen Resolve Begin")
	var list := rd.compute_list_begin()
	if list < 0:
		_capture_gpu_timestamp(rd, "Dynamic Screen Resolve End")
		rd.draw_command_end_label()
		_dynamic_volume_screen_runtime_state["status"] = "screen_compute_list_begin_failed"
		return
	rd.compute_list_bind_compute_pipeline(list, _dynamic_volume_screen_resolve_pipeline)
	rd.compute_list_bind_uniform_set(list, set0, 0)
	rd.compute_list_bind_uniform_set(list, set1, 1)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list,
			ceili(float(half_size.x) / float(MAGIC_GI_DYNAMIC_SCREEN_WORKGROUP_SIZE)),
			ceili(float(half_size.y) / float(MAGIC_GI_DYNAMIC_SCREEN_WORKGROUP_SIZE)), 1)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "Dynamic Screen Resolve End")
	rd.draw_command_end_label()
	_dynamic_volume_screen_dispatch_serial += 1
	if diagnostic_this_dispatch:
		_dynamic_volume_screen_diagnostic_armed = false
		_dynamic_volume_screen_diagnostic_pending = true
		_dynamic_volume_screen_diagnostic_token += 1
		_dynamic_volume_screen_diagnostic_owner_parameters = owner_parameters
		_dynamic_volume_screen_diagnostic_counts.clear()
		_dynamic_volume_screen_diagnostic_owner_packet.clear()
		_dynamic_volume_screen_diagnostic_metadata = {"frame_token": frame_token,
			"cache_revision": cache_revision,
			"dispatch_serial": _dynamic_volume_screen_dispatch_serial,
			"half_size": half_size}
		_dynamic_volume_screen_diagnostic_result = {"status": "pending_readback",
			"frame_token": frame_token, "cache_revision": cache_revision,
			"dispatch_serial": _dynamic_volume_screen_dispatch_serial}
	ctx.call("set_magic_gi_dynamic_screen_cache_input", 0, half_incident, half_guide,
			edge_incident, source_publication_token, cache_revision,
			_dynamic_volume_screen_dispatch_serial, frame_token)
	if not bool(ctx.call("has_magic_gi_dynamic_screen_cache_input", 0)):
		ctx.call("clear_magic_gi_dynamic_screen_cache_inputs")
		_dynamic_volume_screen_runtime_state["status"] = "screen_publication_rejected"
		return
	_dynamic_volume_screen_runtime_state = {
		"status": "resolved_published", "active": false,
		"frame": Engine.get_frames_drawn(), "frame_token": frame_token,
		"source_publication_token": source_publication_token,
		"cache_revision": cache_revision,
		"cache_dispatch_count": cache_dispatch_count,
		"dispatch_token": _dynamic_volume_screen_dispatch_serial,
		"half_size": half_size, "full_size": full_size,
		"texture_ids": [half_incident.get_id(), half_guide.get_id(), edge_incident.get_id()],
		"diagnostic_enabled": diagnostic_this_dispatch}

func _request_streaming_views(ctx: FRPPassContext, buffers: RenderSceneBuffersRD) -> void:
	if ctx == null or buffers == null:
		return
	var runtime_script := _get_runtime_script()
	if runtime_script == null or not runtime_script.has_method("request_streaming_view"):
		return
	var render_data := ctx.get_render_data()
	var scene_data := render_data.get_render_scene_data() if render_data != null else null
	if scene_data == null:
		return
	var camera: Transform3D = scene_data.get_cam_transform()
	var target: RID = buffers.get_render_target()
	if not target.is_valid():
		return
	for view in buffers.get_view_count():
		runtime_script.call("request_streaming_view", target, view, camera.origin, AABB(),
			_effective_prepared_clv_resolution())

func _can_prepare_native_prt(ctx: FRPPassContext, buffers: RenderSceneBuffersRD,
		snapshot: Dictionary) -> bool:
	if ctx == null:
		_set_native_prepare_rejection("missing_context")
		return false
	if buffers == null:
		_set_native_prepare_rejection("missing_render_buffers")
		return false
	var magicdawn_dynamic_prt := _is_magicdawn_dynamic_clv_snapshot(snapshot)
	if _clv_cache_backend(snapshot) == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and not magicdawn_dynamic_prt:
		_set_native_prepare_rejection("block_chart_requires_compute_consumer")
		return false
	if not ctx.has_method("set_magic_gi_clv_input"):
		_set_native_prepare_rejection("missing_native_bridge")
		return false
	# Older canonical executables may expose the bridge name while still consuming
	# the pre-ABI9 CLV columns. Never let such a consumer steal this frame from the
	# compute implementation. A missing getter means the bridge is unversioned.
	if not ctx.has_method("get_magic_gi_clv_layout_version"):
		_set_native_prepare_rejection("missing_native_clv_layout_version")
		return false
	if not ctx.has_method("supports_magic_gi_clv_resolution"):
		_set_native_prepare_rejection("missing_native_clv_resolution_guard")
		return false
	var native_clv_layout_version := int(ctx.call("get_magic_gi_clv_layout_version"))
	if native_clv_layout_version != CLV_LEGACY_LAYOUT_VERSION:
		_set_native_prepare_rejection("native_clv_layout_mismatch:%d" % native_clv_layout_version)
		return false
	if prt_clv_resolution != ClipmapCache.RESOLUTION \
			and prt_clv_resolution != ClipmapCache.EXPANDED_RESOLUTION:
		_set_native_prepare_rejection("unsupported_clv_resolution:%d" % prt_clv_resolution)
		return false
	if not bool(ctx.call("supports_magic_gi_clv_resolution", _effective_clv_resolution())):
		_set_native_prepare_rejection("native_clv_resolution_unsupported:%d" % _effective_clv_resolution())
		return false
	if bool(snapshot.get("surfel", false)):
		_set_native_prepare_rejection("surfel_mode")
		return false
	if bool(snapshot.get("streamed", false)):
		_set_native_prepare_rejection("streamed_bake")
		return false
	if not bool(snapshot.get("use_clv", true)):
		_set_native_prepare_rejection("clv_disabled")
		return false
	if prt_apply_scale != 1:
		_set_native_prepare_rejection("non_reference_apply_scale")
		return false
	if clv_debug_view != CLVDebugView.OFF and not magicdawn_dynamic_prt:
		_set_native_prepare_rejection("clv_debug_view_active")
		return false
	if _clv_stats_capture_armed:
		_set_native_prepare_rejection("stats_capture_armed")
		return false
	if int(prt_surface_exact_debug_mode) != 0:
		_set_native_prepare_rejection("exact_debug_mode_active")
		return false
	var view_count := buffers.get_view_count()
	if view_count < 1 or view_count > 2:
		_set_native_prepare_rejection("unsupported_view_count:%d" % view_count)
		return false
	var data: Variant = snapshot.get("data")
	var owner_transform: Variant = snapshot.get("owner_transform", Transform3D.IDENTITY)
	var owner_size: Variant = snapshot.get("owner_size", Vector3.ZERO)
	if _native_prepare_diagnostics_enabled:
		_last_native_prepare_owner_diagnostic = "has_owner_transform=%s owner_transform_type=%s owner_size_present=%s owner_size_type=%s owner_size=%s keys=%s" % [
			str(snapshot.has("owner_transform")), type_string(typeof(owner_transform)),
			str(snapshot.has("owner_size")), type_string(typeof(owner_size)),
			str(owner_size), str(snapshot.keys())]
	if str(snapshot.get("cache_key", "")).is_empty():
		_set_native_prepare_rejection("missing_cache_key")
		return false
	if not is_instance_valid(data):
		_set_native_prepare_rejection("missing_bake_data")
		return false
	if not owner_transform is Transform3D:
		_set_native_prepare_rejection("invalid_owner_transform")
		return false
	if not owner_size is Vector3:
		_set_native_prepare_rejection("missing_owner_size" if not snapshot.has("owner_size") \
				else "owner_size_type:%s" % type_string(typeof(owner_size)))
		return false
	if owner_size.x <= 0.0 or owner_size.y <= 0.0 or owner_size.z <= 0.0:
		_set_native_prepare_rejection("nonpositive_owner_size:%s" % str(owner_size))
		return false
	_set_native_prepare_rejection("eligible")
	return true

func _prepare_native_prt_clv(ctx: FRPPassContext, buffers: RenderSceneBuffersRD,
		snapshot: Dictionary, resolved_parameters: Variant, replacement_requested: bool) -> void:
	var render_data := ctx.get_render_data()
	var scene_data := render_data.get_render_scene_data() if render_data != null else null
	if scene_data == null:
		_set_native_prepare_rejection("missing_scene_data")
		return
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_set_native_prepare_rejection("missing_rendering_device")
		return
	var previous_snapshot := _frame_snapshot
	var previous_scene_data := _frame_scene_data
	var previous_parameters := _frame_parameters
	var previous_replacement := _frame_replacement_enabled
	var previous_pre_exposure := _pre_exposure
	var previous_scene_exposure := _scene_exposure_normalization
	_frame_snapshot = snapshot
	_frame_scene_data = scene_data
	_frame_parameters = resolved_parameters
	_frame_replacement_enabled = replacement_requested
	_pre_exposure = ctx.get_pre_exposure(0)
	_scene_exposure_normalization = _get_scene_exposure_normalization(ctx)
	_capture_gpu_timestamp(rd, "Native Prepare Begin")
	var magicdawn_dynamic_clv := _is_magicdawn_dynamic_clv_snapshot(snapshot)
	var published := true
	for view in buffers.get_view_count():
		if not _prepare_prt_clv_view(buffers, view, rd):
			published = false
			break
		var clipmap: RefCounted = _frame_clipmap
		if clipmap == null or not clipmap.texture.is_valid() or not clipmap.tags.is_valid() \
				or not clipmap.support.is_valid() or not clipmap.parameters.is_valid() \
				or int(clipmap.get("resolution")) != _effective_clv_resolution() \
				or int(clipmap.get("parameter_resolution")) != int(clipmap.get("resolution")) \
				or not _write_native_gi_parameters(rd, snapshot):
			published = false
			break
		var owner_parameters_ready := false
		var owner_parameters := RID()
		if magicdawn_dynamic_clv:
			owner_parameters_ready = _write_magicdawn_native_owner_parameters(rd, view,
					snapshot, replacement_requested, _scene_exposure_normalization)
			owner_parameters = _magicdawn_native_owner_ubos[view]
		else:
			owner_parameters_ready = _write_native_owner_parameters(rd, view, snapshot,
					replacement_requested, _scene_exposure_normalization)
			owner_parameters = _native_owner_ubos[view]
		if not owner_parameters_ready or not owner_parameters.is_valid():
			published = false
			break
		var screen_cache_revision := -1
		var screen_cache_dispatch_token := 0
		if magicdawn_dynamic_clv:
			var cache_state_value: Variant = clipmap.get_runtime_state() \
					if clipmap.has_method("get_runtime_state") else {}
			if cache_state_value is Dictionary:
				var cache_state: Dictionary = cache_state_value
				screen_cache_revision = int(cache_state.get("relight_lighting_revision", -1))
				screen_cache_dispatch_token = int(cache_state.get("relight_serial", 0))
		ctx.set_magic_gi_clv_input(view, clipmap.texture, clipmap.tags, clipmap.support,
				clipmap.parameters, owner_parameters, _native_gi_parameters_ubo,
				screen_cache_revision, screen_cache_dispatch_token)
		var key := _native_view_key(buffers, view)
		_native_prepared_views[key] = {
			"frame": Engine.get_frames_drawn(),
			"renderer_frame_token": int(ctx.call("get_frame_token")) \
					if ctx.has_method("get_frame_token") else -1,
			"cache_key": str(snapshot.get("cache_key", "")),
			"version": int(snapshot.get("version", -1)),
			"lighting_revision": int(_magicdawn_runtime_state.get("completed_lighting_revision", -1)),
			"screen_cache_revision": screen_cache_revision,
			"screen_cache_dispatch_token": screen_cache_dispatch_token,
			"owner_parameters_rid": owner_parameters,
			"owner_control_w": float(_magicdawn_receiver_qa_mode) if magicdawn_dynamic_clv else 0.0,
			"clipmap": clipmap,
		}
	if not published:
		ctx.clear_magic_gi_clv_inputs()
		_native_prepared_views.clear()
		_set_native_prepare_rejection("resource_publish_failed")
	else:
		_set_native_prepare_rejection("published")
		_prepare_native_deferred_general_queue(ctx, buffers, rd, snapshot)
	_capture_gpu_timestamp(rd, "Native Prepare End")
	_frame_clipmap = null
	_frame_snapshot = previous_snapshot
	_frame_scene_data = previous_scene_data
	_frame_parameters = previous_parameters
	_frame_replacement_enabled = previous_replacement
	_pre_exposure = previous_pre_exposure
	_scene_exposure_normalization = previous_scene_exposure
	_frame_view_matrices.clear()
	_frame_input_bindings.clear()

func _ensure_magicdawn_screen_resolve_resources(rd: RenderingDevice) -> bool:
	if rd == null:
		_magicdawn_screen_resolve_status = "rendering_device_unavailable"
		return false
	# Load the new stage lazily so a fresh project import cannot make the main
	# pass script fail to parse while this wrapper's .glsl.import is generated.
	if _magicdawn_screen_classify_shader_resource == null:
		var classify_resource := ResourceLoader.load(MAGIC_GI_CLV_SCREEN_CLASSIFY_SHADER_PATH)
		if not classify_resource is RDShaderFile:
			_magicdawn_screen_resolve_status = "classify_shader_resource_unavailable"
			return false
		_magicdawn_screen_classify_shader_resource = classify_resource as RDShaderFile
	if not _magicdawn_screen_classify_shader.is_valid():
		var classify_spirv := _magicdawn_screen_classify_shader_resource.get_spirv()
		if classify_spirv == null or not classify_spirv.compile_error_compute.is_empty() \
				or classify_spirv.bytecode_compute.is_empty():
			_magicdawn_screen_resolve_status = "classify_shader_compile_failed:%s" % (
					classify_spirv.compile_error_compute if classify_spirv != null else "missing_spirv")
			return false
		_magicdawn_screen_classify_shader = rd.shader_create_from_spirv(classify_spirv,
				"Magic GI CLV Screen Classify")
		if not _magicdawn_screen_classify_shader.is_valid():
			_magicdawn_screen_resolve_status = "classify_shader_create_failed"
			return false
	if not _magicdawn_screen_classify_pipeline.is_valid():
		_magicdawn_screen_classify_pipeline = rd.compute_pipeline_create(
				_magicdawn_screen_classify_shader)
		if not _magicdawn_screen_classify_pipeline.is_valid():
			_magicdawn_screen_resolve_status = "classify_pipeline_create_failed"
			return false
	if not _magicdawn_screen_resolve_shader.is_valid():
		var spirv := MAGIC_GI_CLV_SCREEN_RESOLVE_SHADER.get_spirv()
		if spirv == null or not spirv.compile_error_compute.is_empty() \
				or spirv.bytecode_compute.is_empty():
			_magicdawn_screen_resolve_status = "shader_compile_failed:%s" % (
					spirv.compile_error_compute if spirv != null else "missing_spirv")
			return false
		_magicdawn_screen_resolve_shader = rd.shader_create_from_spirv(spirv,
				"Magic GI CLV Screen Resolve")
		if not _magicdawn_screen_resolve_shader.is_valid():
			_magicdawn_screen_resolve_status = "shader_create_failed"
			return false
	if not _magicdawn_screen_resolve_pipeline.is_valid():
		_magicdawn_screen_resolve_pipeline = rd.compute_pipeline_create(
				_magicdawn_screen_resolve_shader)
		if not _magicdawn_screen_resolve_pipeline.is_valid():
			_magicdawn_screen_resolve_status = "pipeline_create_failed"
			return false
	if not _magicdawn_screen_partial_shader.is_valid():
		var partial_spirv := MAGIC_GI_CLV_SCREEN_PARTIAL_SHADER.get_spirv()
		if partial_spirv == null or not partial_spirv.compile_error_compute.is_empty() \
				or partial_spirv.bytecode_compute.is_empty():
			_magicdawn_screen_resolve_status = "partial_shader_compile_failed:%s" % (
					partial_spirv.compile_error_compute if partial_spirv != null else "missing_spirv")
			return false
		_magicdawn_screen_partial_shader = rd.shader_create_from_spirv(partial_spirv,
				"Magic GI CLV Screen Partial Resolve")
		if not _magicdawn_screen_partial_shader.is_valid():
			_magicdawn_screen_resolve_status = "partial_shader_create_failed"
			return false
	if not _magicdawn_screen_partial_pipeline.is_valid():
		_magicdawn_screen_partial_pipeline = rd.compute_pipeline_create(
				_magicdawn_screen_partial_shader)
		if not _magicdawn_screen_partial_pipeline.is_valid():
			_magicdawn_screen_resolve_status = "partial_pipeline_create_failed"
			return false
	if not _magicdawn_screen_resolve_nearest_sampler.is_valid():
		var sampler := RDSamplerState.new()
		sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_magicdawn_screen_resolve_nearest_sampler = rd.sampler_create(sampler)
	if not _magicdawn_screen_resolve_nearest_sampler.is_valid():
		_magicdawn_screen_resolve_status = "sampler_create_failed"
		return false
	if not _magicdawn_screen_resolve_linear_sampler.is_valid():
		var linear := RDSamplerState.new()
		linear.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		linear.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		linear.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		linear.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		linear.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		linear.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_magicdawn_screen_resolve_linear_sampler = rd.sampler_create(linear)
	if not _magicdawn_screen_resolve_linear_sampler.is_valid():
		_magicdawn_screen_resolve_status = "linear_sampler_create_failed"
		return false
	if not _magicdawn_screen_resolve_diagnostics_buffer.is_valid():
		var zero_diagnostics := PackedByteArray()
		zero_diagnostics.resize(MAGIC_GI_CLV_SCREEN_DIAG_BYTES)
		_magicdawn_screen_resolve_diagnostics_buffer = rd.storage_buffer_create(
				MAGIC_GI_CLV_SCREEN_DIAG_BYTES, zero_diagnostics)
	if not _magicdawn_screen_resolve_diagnostics_buffer.is_valid():
		_magicdawn_screen_resolve_status = "diagnostic_buffer_create_failed"
		return false
	_sync_owned_rid_snapshot()
	return true

## Arm a one-frame route/workload snapshot for the next successful screen-cache
## resolve. The readback is asynchronous and limited to a small counter block.
## `roi_max` is exclusive and uses full-resolution viewport pixel coordinates.
func arm_magicdawn_screen_resolve_diagnostics(roi_min: Vector2i,
		roi_max: Vector2i) -> Dictionary:
	if _magicdawn_screen_diagnostic_armed or _magicdawn_screen_diagnostic_pending:
		return {"accepted": false, "error": "screen_diagnostic_already_armed_or_pending"}
	if roi_min.x < 0 or roi_min.y < 0 or roi_max.x <= roi_min.x \
			or roi_max.y <= roi_min.y:
		return {"accepted": false, "error": "invalid_screen_diagnostic_roi"}
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _ensure_magicdawn_screen_resolve_resources(rd):
		return {"accepted": false, "error": "screen_resolve_resources_unavailable"}
	if rd.buffer_clear(_magicdawn_screen_resolve_diagnostics_buffer, 0,
			MAGIC_GI_CLV_SCREEN_DIAG_BYTES) != OK:
		return {"accepted": false, "error": "diagnostic_buffer_clear_failed"}
	_magicdawn_screen_diagnostic_roi = Rect2i(roi_min, roi_max - roi_min)
	_magicdawn_screen_diagnostic_armed = true
	_magicdawn_screen_diagnostic_result = {"status": "armed",
		"roi_min": roi_min, "roi_max_exclusive": roi_max,
		"counter_schema": "screen_resolve_route_work_v3"}
	return {"accepted": true, "roi_min": roi_min, "roi_max_exclusive": roi_max}

func get_magicdawn_screen_resolve_diagnostics() -> Dictionary:
	return _magicdawn_screen_diagnostic_result.duplicate(true)

func _magicdawn_screen_diagnostic_readback_callback(data: PackedByteArray,
		token: int, frame_token: int, revision: int, dispatch_serial: int,
		roi_min: Vector2i, roi_max: Vector2i) -> void:
	call_deferred("_magicdawn_finish_screen_diagnostic_readback", data.duplicate(),
			token, frame_token, revision, dispatch_serial, roi_min, roi_max)

func _magicdawn_finish_screen_diagnostic_readback(data: PackedByteArray,
		token: int, frame_token: int, revision: int, dispatch_serial: int,
		roi_min: Vector2i, roi_max: Vector2i) -> void:
	if token != _magicdawn_screen_diagnostic_token:
		return
	_magicdawn_screen_diagnostic_pending = false
	if data.size() != MAGIC_GI_CLV_SCREEN_DIAG_BYTES:
		_magicdawn_screen_diagnostic_result = {"status": "readback_size_mismatch",
			"actual_bytes": data.size(), "expected_bytes": MAGIC_GI_CLV_SCREEN_DIAG_BYTES,
			"frame_token": frame_token, "cache_revision": revision,
			"dispatch_serial": dispatch_serial}
		return
	var raw := data.to_int32_array()
	if raw.size() != MAGIC_GI_CLV_SCREEN_DIAG_WORD_COUNT:
		_magicdawn_screen_diagnostic_result = {"status": "readback_word_count_mismatch",
			"actual_words": raw.size(), "expected_words": MAGIC_GI_CLV_SCREEN_DIAG_WORD_COUNT}
		return
	var global_counts := _magicdawn_decode_screen_diagnostic_group(raw, 0)
	var roi_counts := _magicdawn_decode_screen_diagnostic_group(raw,
			MAGIC_GI_CLV_SCREEN_DIAG_COUNTER_COUNT)
	_magicdawn_screen_diagnostic_result = {"status": "complete",
		"frame_token": frame_token, "cache_revision": revision,
		"dispatch_serial": dispatch_serial, "roi_min": roi_min,
		"roi_max_exclusive": roi_max, "global": global_counts, "roi": roi_counts,
		"counter_schema": "screen_resolve_route_work_v3"}
	_magicdawn_runtime_state["screen_resolve_diagnostics"] = \
			_magicdawn_screen_diagnostic_result.duplicate(true)
	print("[MAGIC_GI_SCREEN_ROUTE_DIAGNOSTICS] " +
			JSON.stringify(_magicdawn_screen_diagnostic_result))

func _magicdawn_decode_screen_diagnostic_group(raw: PackedInt32Array,
		base: int) -> Dictionary:
	var result: Dictionary = {}
	for index in MAGIC_GI_CLV_SCREEN_DIAG_COUNTER_COUNT:
		result[MAGIC_GI_CLV_SCREEN_DIAG_COUNTER_NAMES[index]] = maxi(0, raw[base + index])
	var confidence_count := int(result.get("confidence_count", 0))
	result["mean_confidence"] = float(result.get("confidence_sum_cent", 0)) \
			/ 100.0 / maxf(1.0, float(confidence_count))
	result["coherent_tile_fraction"] = float(result.get("coherent_tiles", 0)) \
			/ maxf(1.0, float(result.get("tile_count", 0)))
	result["edge_tile_fraction"] = float(result.get("edge_tiles", 0)) \
			/ maxf(1.0, float(result.get("tile_count", 0)))
	result["partial_ray_mean_nodes"] = float(result.get("bvh_node_visits", 0)) \
			/ maxf(1.0, float(result.get("partial_visibility_rays", 0)))
	return result

func _render_magicdawn_screen_cache_after_gbuffer(ctx: FRPPassContext,
		buffers: RenderSceneBuffersRD, prepared_key: String, frame_token: int) -> void:
	if ctx == null or buffers == null or buffers.get_view_count() != 1:
		_magicdawn_screen_resolve_status = "invalid_callback_context"
		if ctx != null:
			ctx.call("clear_magic_gi_screen_cache_inputs")
		return
	ctx.call("clear_magic_gi_screen_cache_inputs")
	if not ctx.has_magic_gi_clv_input(0) or not ctx.has_method("get_frame_token") \
			or int(ctx.call("get_frame_token")) != frame_token:
		_magicdawn_screen_resolve_status = "clv_or_frame_lease_mismatch"
		return
	var prepared_value: Variant = _native_prepared_views.get(prepared_key, {})
	if not prepared_value is Dictionary:
		_magicdawn_screen_resolve_status = "prepared_view_missing"
		return
	var prepared: Dictionary = prepared_value
	if int(prepared.get("renderer_frame_token", -1)) != frame_token:
		_magicdawn_screen_resolve_status = "prepared_frame_token_mismatch"
		return
	var cache_value: Variant = prepared.get("clipmap")
	if not cache_value is RefCounted:
		_magicdawn_screen_resolve_status = "prepared_clipmap_missing"
		return
	var cache: RefCounted = cache_value
	var cache_state_value: Variant = cache.call("get_runtime_state") \
			if cache.has_method("get_runtime_state") else {}
	if not cache_state_value is Dictionary:
		_magicdawn_screen_resolve_status = "cache_runtime_state_missing"
		return
	var cache_state: Dictionary = cache_state_value
	var expected_revision := int(prepared.get("screen_cache_revision", -1))
	var expected_dispatch := int(prepared.get("screen_cache_dispatch_token", 0))
	if expected_revision < 0 or expected_dispatch <= 0 \
			or int(cache_state.get("relight_lighting_revision", -1)) != expected_revision \
			or int(cache_state.get("relight_serial", 0)) != expected_dispatch \
			or bool(cache_state.get("relight_pending", true)):
		_magicdawn_screen_resolve_status = "relight_lease_stale_or_pending"
		return
	var rd := RenderingServer.get_rendering_device()
	var depth: RID = inputs[1].get_texture(buffers, 0) if inputs.size() > 1 else RID()
	var normal: RID = inputs[2].get_texture(buffers, 0) if inputs.size() > 2 else RID()
	var half_incident: RID = buffers.get_texture(NativeSpec.SCOPE_PIPELINE,
			MAGIC_GI_CLV_SCREEN_HALF_INCIDENT)
	var half_guide: RID = buffers.get_texture(NativeSpec.SCOPE_PIPELINE,
			MAGIC_GI_CLV_SCREEN_HALF_GUIDE)
	var edge_incident: RID = buffers.get_texture(NativeSpec.SCOPE_PIPELINE,
			MAGIC_GI_CLV_SCREEN_EDGE_INCIDENT)
	var bake_value: Variant = _bake_resources.get(str(prepared.get("cache_key", "")), {})
	if not bake_value is Dictionary:
		_magicdawn_screen_resolve_status = "matching_bake_resources_missing"
		return
	var bake: Dictionary = bake_value
	var visibility_nodes: RID = bake.get("visibility_nodes", RID())
	var visibility_triangles: RID = bake.get("visibility_triangles", RID())
	if rd == null or not depth.is_valid() or not normal.is_valid() \
			or not cache.texture.is_valid() or not cache.tags.is_valid() \
			or not cache.support.is_valid() or not cache.parameters.is_valid() \
			or not visibility_nodes.is_valid() or not visibility_triangles.is_valid() \
			or not half_incident.is_valid() or not half_guide.is_valid() \
			or not edge_incident.is_valid():
		_magicdawn_screen_resolve_status = "screen_cache_input_unavailable"
		return
	if not rd.texture_is_valid(depth) or not rd.texture_is_valid(normal) \
			or not rd.texture_is_valid(cache.texture) or not rd.texture_is_valid(cache.tags) \
			or not rd.texture_is_valid(cache.support) or not rd.texture_is_valid(half_incident) \
			or not rd.texture_is_valid(half_guide) or not rd.texture_is_valid(edge_incident) \
			or not visibility_nodes.is_valid() or not visibility_triangles.is_valid():
		_magicdawn_screen_resolve_status = "screen_cache_resource_invalid"
		return
	var full_size: Vector2i = buffers.get_internal_size()
	var half_size: Vector2i = buffers.get_texture_slice_size(NativeSpec.SCOPE_PIPELINE,
			MAGIC_GI_CLV_SCREEN_HALF_INCIDENT, 0)
	if full_size.x <= 0 or full_size.y <= 0 or half_size.x <= 0 or half_size.y <= 0 \
			or not _ensure_magicdawn_screen_resolve_resources(rd):
		_magicdawn_screen_resolve_status = "empty_size_or_pipeline_unavailable"
		ctx.call("clear_magic_gi_screen_cache_inputs")
		return
	var owner_parameters: RID = prepared.get("owner_parameters_rid", RID())
	if not owner_parameters.is_valid() or not _ubo.is_valid() \
			or not _native_gi_parameters_ubo.is_valid():
		_magicdawn_screen_resolve_status = "frame_parameters_unavailable"
		return
	var classify_set0 := UniformSetCacheRD.get_cache(_magicdawn_screen_classify_shader, 0, [
		U.sampled(0, _magicdawn_screen_resolve_nearest_sampler, depth),
		U.sampled(1, _magicdawn_screen_resolve_nearest_sampler, normal),
		U.image(2, half_incident), U.image(3, half_guide), U.image(4, edge_incident),
		U.uniform_buffer(5, _ubo),
		U.storage_buffer(6, _magicdawn_screen_resolve_diagnostics_buffer)])
	var classify_set1 := UniformSetCacheRD.get_cache(_magicdawn_screen_classify_shader, 1, [
		U.uniform_buffer(58, owner_parameters),
		U.uniform_buffer(60, _native_gi_parameters_ubo)])
	var fast_set0 := UniformSetCacheRD.get_cache(_magicdawn_screen_resolve_shader, 0, [
		U.sampled(0, _magicdawn_screen_resolve_nearest_sampler, depth),
		U.sampled(1, _magicdawn_screen_resolve_nearest_sampler, normal),
		U.image(2, half_incident), U.image(3, half_guide), U.image(4, edge_incident),
		U.uniform_buffer(5, _ubo),
		U.storage_buffer(6, _magicdawn_screen_resolve_diagnostics_buffer)])
	var fast_set1 := UniformSetCacheRD.get_cache(_magicdawn_screen_resolve_shader, 1, [
		_magicdawn_texture_uniform(50, cache.texture),
		_magicdawn_texture_uniform(51, cache.tags),
		_magicdawn_texture_uniform(52, cache.support),
		U.uniform_buffer(53, cache.parameters),
		U.uniform_buffer(58, owner_parameters),
		U.uniform_buffer(60, _native_gi_parameters_ubo),
		_magicdawn_sampler_uniform(61, _magicdawn_screen_resolve_nearest_sampler),
		_magicdawn_sampler_uniform(62, _magicdawn_screen_resolve_linear_sampler)])
	var partial_set0 := UniformSetCacheRD.get_cache(_magicdawn_screen_partial_shader, 0, [
		U.sampled(0, _magicdawn_screen_resolve_nearest_sampler, depth),
		U.sampled(1, _magicdawn_screen_resolve_nearest_sampler, normal),
		U.image(2, half_incident), U.image(3, half_guide), U.image(4, edge_incident),
		U.uniform_buffer(5, _ubo),
		U.storage_buffer(6, _magicdawn_screen_resolve_diagnostics_buffer)])
	var partial_set1 := UniformSetCacheRD.get_cache(_magicdawn_screen_partial_shader, 1, [
		_magicdawn_texture_uniform(50, cache.texture),
		_magicdawn_texture_uniform(51, cache.tags),
		_magicdawn_texture_uniform(52, cache.support),
		U.uniform_buffer(53, cache.parameters),
		U.uniform_buffer(58, owner_parameters),
		U.uniform_buffer(60, _native_gi_parameters_ubo),
		_magicdawn_sampler_uniform(61, _magicdawn_screen_resolve_nearest_sampler),
		_magicdawn_sampler_uniform(62, _magicdawn_screen_resolve_linear_sampler),
		U.storage_buffer(63, visibility_nodes),
		U.storage_buffer(64, visibility_triangles)])
	if not classify_set0.is_valid() or not classify_set1.is_valid() \
			or not fast_set0.is_valid() or not fast_set1.is_valid() \
			or not partial_set0.is_valid() or not partial_set1.is_valid():
		_magicdawn_screen_resolve_status = "uniform_set_creation_failed"
		return
	var diagnostic_this_dispatch := _magicdawn_screen_diagnostic_armed
	var diagnostic_roi := _magicdawn_screen_diagnostic_roi
	if diagnostic_this_dispatch and rd.buffer_clear(_magicdawn_screen_resolve_diagnostics_buffer,
			0, MAGIC_GI_CLV_SCREEN_DIAG_BYTES) != OK:
		_magicdawn_screen_diagnostic_armed = false
		diagnostic_this_dispatch = false
		_magicdawn_screen_diagnostic_result = {"status": "diagnostic_buffer_clear_failed"}
	var diagnostic_min := diagnostic_roi.position if diagnostic_this_dispatch else Vector2i.ZERO
	var diagnostic_max := diagnostic_roi.end if diagnostic_this_dispatch else Vector2i.ZERO
	var push_coarse := PackedInt32Array([full_size.x, full_size.y,
		half_size.x, half_size.y,
		diagnostic_min.x, diagnostic_min.y, diagnostic_max.x, diagnostic_max.y,
		1 if diagnostic_this_dispatch else 0, 0]).to_byte_array()
	var push_local_edges := PackedInt32Array([full_size.x, full_size.y,
		half_size.x, half_size.y,
		diagnostic_min.x, diagnostic_min.y, diagnostic_max.x, diagnostic_max.y,
		1 if diagnostic_this_dispatch else 0, 1]).to_byte_array()
	if push_coarse.size() != 40 or push_local_edges.size() != 40:
		_magicdawn_screen_resolve_status = "screen_partial_push_constant_size_mismatch"
		return
	var push_classify := PackedInt32Array([full_size.x, full_size.y,
		half_size.x, half_size.y,
		diagnostic_min.x, diagnostic_min.y, diagnostic_max.x, diagnostic_max.y,
		1 if diagnostic_this_dispatch else 0, 2]).to_byte_array()
	if push_classify.size() != 40:
		_magicdawn_screen_resolve_status = "screen_classify_push_constant_size_mismatch"
		return
	if diagnostic_this_dispatch:
		print("[MAGIC_GI_SCREEN_DIAG_PUSH] armed=%s coarse=(enabled:%d mode:%d) local=(enabled:%d mode:%d) bytes=%d/%d" % [
			str(diagnostic_this_dispatch), push_coarse.decode_s32(32), push_coarse.decode_s32(36),
			push_local_edges.decode_s32(32), push_local_edges.decode_s32(36),
			push_coarse.size(), push_local_edges.size()])
		var image_binding_ids := [half_incident.get_id(), half_guide.get_id(), edge_incident.get_id()]
		print("[MAGIC_GI_SCREEN_DIAG_IMAGE_BINDINGS] fast0=%s partial0=%s sizes=(half:%s edge:%s) diagnostics=(rid:%d bytes:%d)" % [
			str(image_binding_ids), str(image_binding_ids), str(half_size), str(full_size),
			_magicdawn_screen_resolve_diagnostics_buffer.get_id(), MAGIC_GI_CLV_SCREEN_DIAG_BYTES])
	rd.draw_command_begin_label("Magic GI CLV Screen Resolve", Color(0.25, 0.75, 0.9))
	_capture_gpu_timestamp(rd, "Screen Cache Resolve Begin")
	_capture_gpu_timestamp(rd, "Screen Cache Classify Begin")
	var classify_list := rd.compute_list_begin()
	if classify_list < 0:
		_capture_gpu_timestamp(rd, "Screen Cache Classify End")
		_capture_gpu_timestamp(rd, "Screen Cache Fast Resolve Begin")
		_capture_gpu_timestamp(rd, "Screen Cache Fast Coarse Begin")
		_capture_gpu_timestamp(rd, "Screen Cache Fast Coarse End")
		_capture_gpu_timestamp(rd, "Screen Cache Fast Local Begin")
		_capture_gpu_timestamp(rd, "Screen Cache Fast Local End")
		_capture_gpu_timestamp(rd, "Screen Cache Fast Resolve End")
		_capture_gpu_timestamp(rd, "Screen Cache Resolve End")
		rd.draw_command_end_label()
		_magicdawn_screen_resolve_status = "classify_compute_list_begin_failed"
		return
	rd.compute_list_bind_compute_pipeline(classify_list, _magicdawn_screen_classify_pipeline)
	rd.compute_list_bind_uniform_set(classify_list, classify_set0, 0)
	rd.compute_list_bind_uniform_set(classify_list, classify_set1, 1)
	rd.compute_list_set_push_constant(classify_list, push_classify, push_classify.size())
	rd.compute_list_dispatch(classify_list,
			ceili(float(full_size.x) / float(MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE)),
			ceili(float(full_size.y) / float(MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE)), 1)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "Screen Cache Classify End")
	_capture_gpu_timestamp(rd, "Screen Cache Fast Resolve Begin")
	_capture_gpu_timestamp(rd, "Screen Cache Fast Coarse Begin")
	var fast_list := rd.compute_list_begin()
	if fast_list < 0:
		_capture_gpu_timestamp(rd, "Screen Cache Fast Coarse End")
		_capture_gpu_timestamp(rd, "Screen Cache Fast Local Begin")
		_capture_gpu_timestamp(rd, "Screen Cache Fast Local End")
		_capture_gpu_timestamp(rd, "Screen Cache Fast Resolve End")
		_capture_gpu_timestamp(rd, "Screen Cache Resolve End")
		rd.draw_command_end_label()
		_magicdawn_screen_resolve_status = "compute_list_begin_failed"
		return
	rd.compute_list_bind_compute_pipeline(fast_list, _magicdawn_screen_resolve_pipeline)
	rd.compute_list_bind_uniform_set(fast_list, fast_set0, 0)
	rd.compute_list_bind_uniform_set(fast_list, fast_set1, 1)
	rd.compute_list_set_push_constant(fast_list, push_coarse, push_coarse.size())
	rd.compute_list_dispatch(fast_list,
			ceili(float(half_size.x) / float(MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE)),
			ceili(float(half_size.y) / float(MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE)), 1)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "Screen Cache Fast Coarse End")
	_capture_gpu_timestamp(rd, "Screen Cache Fast Local Begin")
	var fast_local_list := rd.compute_list_begin()
	if fast_local_list < 0:
		_capture_gpu_timestamp(rd, "Screen Cache Fast Local End")
		_capture_gpu_timestamp(rd, "Screen Cache Fast Resolve End")
		_capture_gpu_timestamp(rd, "Screen Cache Resolve End")
		rd.draw_command_end_label()
		_magicdawn_screen_resolve_status = "fast_local_compute_list_begin_failed"
		return
	rd.compute_list_bind_compute_pipeline(fast_local_list, _magicdawn_screen_resolve_pipeline)
	rd.compute_list_bind_uniform_set(fast_local_list, fast_set0, 0)
	rd.compute_list_bind_uniform_set(fast_local_list, fast_set1, 1)
	rd.compute_list_set_push_constant(fast_local_list,
			push_local_edges, push_local_edges.size())
	var fast_local_group_size := Vector2i(
			floori(float(full_size.x + 1) * 0.5),
			floori(float(full_size.y + 1) * 0.5))
	rd.compute_list_dispatch(fast_local_list,
			ceili(float(fast_local_group_size.x) / float(MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE)),
			ceili(float(fast_local_group_size.y) / float(MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE)), 1)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "Screen Cache Fast Local End")
	_capture_gpu_timestamp(rd, "Screen Cache Fast Resolve End")
	_capture_gpu_timestamp(rd, "Screen Cache Partial Resolve Begin")
	_capture_gpu_timestamp(rd, "Screen Cache Partial Coarse Begin")
	var partial_coarse_list := rd.compute_list_begin()
	if partial_coarse_list < 0:
		_capture_gpu_timestamp(rd, "Screen Cache Partial Coarse End")
		_capture_gpu_timestamp(rd, "Screen Cache Partial Resolve End")
		_capture_gpu_timestamp(rd, "Screen Cache Resolve End")
		rd.draw_command_end_label()
		_magicdawn_screen_resolve_status = "partial_coarse_compute_list_begin_failed"
		return
	rd.compute_list_bind_compute_pipeline(partial_coarse_list, _magicdawn_screen_partial_pipeline)
	rd.compute_list_bind_uniform_set(partial_coarse_list, partial_set0, 0)
	rd.compute_list_bind_uniform_set(partial_coarse_list, partial_set1, 1)
	rd.compute_list_set_push_constant(partial_coarse_list, push_coarse, push_coarse.size())
	rd.compute_list_dispatch(partial_coarse_list,
			ceili(float(half_size.x) / float(MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE)),
			ceili(float(half_size.y) / float(MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE)), 1)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "Screen Cache Partial Coarse End")
	_capture_gpu_timestamp(rd, "Screen Cache Partial Local Edges Begin")
	var partial_edges_list := rd.compute_list_begin()
	if partial_edges_list < 0:
		_capture_gpu_timestamp(rd, "Screen Cache Partial Local Edges End")
		_capture_gpu_timestamp(rd, "Screen Cache Partial Resolve End")
		_capture_gpu_timestamp(rd, "Screen Cache Resolve End")
		rd.draw_command_end_label()
		_magicdawn_screen_resolve_status = "partial_edges_compute_list_begin_failed"
		return
	rd.compute_list_bind_compute_pipeline(partial_edges_list, _magicdawn_screen_partial_pipeline)
	rd.compute_list_bind_uniform_set(partial_edges_list, partial_set0, 0)
	rd.compute_list_bind_uniform_set(partial_edges_list, partial_set1, 1)
	rd.compute_list_set_push_constant(partial_edges_list,
			push_local_edges, push_local_edges.size())
	rd.compute_list_dispatch(partial_edges_list,
			ceili(float(fast_local_group_size.x) / float(MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE)),
			ceili(float(fast_local_group_size.y) / float(MAGIC_GI_CLV_SCREEN_WORKGROUP_SIZE)), 1)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "Screen Cache Partial Local Edges End")
	_capture_gpu_timestamp(rd, "Screen Cache Partial Resolve End")
	_capture_gpu_timestamp(rd, "Screen Cache Resolve End")
	rd.draw_command_end_label()
	_magicdawn_screen_resolve_dispatch_serial += 1
	if diagnostic_this_dispatch:
		_magicdawn_screen_diagnostic_armed = false
		_magicdawn_screen_diagnostic_pending = true
		_magicdawn_screen_diagnostic_token += 1
		var diagnostic_token := _magicdawn_screen_diagnostic_token
		var diagnostic_callback := Callable(self,
				"_magicdawn_screen_diagnostic_readback_callback").bind(
				diagnostic_token, frame_token, expected_revision,
				_magicdawn_screen_resolve_dispatch_serial, diagnostic_roi.position,
				diagnostic_roi.end)
		var readback_error := rd.buffer_get_data_async(_magicdawn_screen_resolve_diagnostics_buffer,
				diagnostic_callback, 0, MAGIC_GI_CLV_SCREEN_DIAG_BYTES)
		if readback_error != OK:
			_magicdawn_screen_diagnostic_pending = false
			_magicdawn_screen_diagnostic_result = {"status": "async_readback_failed",
				"error": readback_error, "frame_token": frame_token,
				"cache_revision": expected_revision}
	var dispatch_token := expected_dispatch
	ctx.call("set_magic_gi_screen_cache_input", 0, half_incident, half_guide,
			edge_incident, cache.texture, expected_revision, dispatch_token, frame_token)
	if not ctx.has_magic_gi_screen_cache_input(0):
		_magicdawn_screen_resolve_status = "publication_rejected_by_context_lease"
		ctx.call("clear_magic_gi_screen_cache_inputs")
		return
	_magicdawn_screen_resolve_status = "classify_fast_and_partial_five_stage_dispatched_and_published"
	_magicdawn_runtime_state["screen_cache_status"] = _magicdawn_screen_resolve_status
	_magicdawn_runtime_state["screen_cache_frame_token"] = frame_token
	_magicdawn_runtime_state["screen_cache_dispatch_token"] = dispatch_token
	_magicdawn_runtime_state["screen_cache_cache_revision"] = expected_revision
	_magicdawn_runtime_state["screen_cache_half_size"] = half_size
	_magicdawn_runtime_state["screen_cache_scale"] = 0.125
	_magicdawn_runtime_state["screen_cache_tile_size"] = 8
	_magicdawn_runtime_state["screen_cache_edge_fallback"] = "coarse 8x8 tile, grouped 2x2, then full-pixel discontinuity"

func _is_magicdawn_authored_snapshot(snapshot: Dictionary) -> bool:
	return _clv_cache_backend(snapshot) == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and _clv_internal_test_layout == CLV_INTERNAL_LAYOUT_AUTHORED \
			and _clv_layout_version_for_backend(CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART) \
			== MAGICDAWN_NATIVE_LAYOUT_VERSION

func _is_magicdawn_dynamic_clv_snapshot(snapshot: Dictionary) -> bool:
	return _clv_cache_backend(snapshot) == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and _clv_internal_test_layout == CLV_INTERNAL_LAYOUT_AUTHORED

func _magicdawn_debug_sidecar_requested(buffers: RenderSceneBuffersRD) -> bool:
	if buffers == null:
		return false
	var target := buffers.get_render_target()
	return target.is_valid() and MagicGIDebugRequest.is_requested(int(target.get_id()))

func _magicdawn_native_bridge_reason(ctx: FRPPassContext) -> String:
	if ctx == null:
		return "missing_context"
	for method_name in ["set_magic_gi_baked_sh_input",
			"has_magic_gi_baked_sh_input", "clear_magic_gi_baked_sh_inputs",
			"get_magic_gi_baked_sh_layout_version",
			"get_magic_gi_baked_sh_consumed_token"]:
		if not ctx.has_method(method_name):
			return "missing_native_layout17_api:%s" % method_name
	var layout_version := int(ctx.call("get_magic_gi_baked_sh_layout_version"))
	if layout_version != MAGICDAWN_NATIVE_LAYOUT_VERSION:
		return "native_baked_sh_layout_mismatch:%d" % layout_version
	return ""

static func _magicdawn_layout16_codec_valid(codec_value: Variant,
		format_tag: int) -> bool:
	if not codec_value is Vector4:
		return false
	var codec: Vector4 = codec_value
	if format_tag == 16:
		return is_finite(codec.x) and codec.x > 0.0 \
				and is_finite(codec.y) and codec.y > 0.0 \
				and is_finite(codec.x * codec.y) \
				and absf(codec.x * codec.y - 1.0) <= 2e-6 \
				and codec.z == 16.0 and codec.w == 1.0
	if format_tag == 32:
		return codec == MagicDawnBakedSHCache.DEFAULT_CODEC_R32
	return false

func _next_magicdawn_publication_token() -> int:
	if _native_baked_sh_publication_counter >= 9223372036854775806:
		_native_baked_sh_publication_counter = 1
	else:
		_native_baked_sh_publication_counter += 1
	if _native_baked_sh_publication_counter == 0:
		_native_baked_sh_publication_counter = 1
	return _native_baked_sh_publication_counter

func _ensure_magicdawn_native_owner_buffers(rd: RenderingDevice) -> bool:
	var changed := false
	for view in 2:
		if not _magicdawn_native_owner_ubos[view].is_valid():
			var zero := PackedByteArray()
			zero.resize(MAGICDAWN_NATIVE_OWNER_PARAMETER_BYTES)
			_magicdawn_native_owner_ubos[view] = rd.uniform_buffer_create(
					MAGICDAWN_NATIVE_OWNER_PARAMETER_BYTES, zero)
			_magicdawn_native_owner_bytes[view] = PackedByteArray()
			changed = true
	if changed:
		_sync_owned_rid_snapshot()
	return _magicdawn_native_owner_ubos[0].is_valid() \
			and _magicdawn_native_owner_ubos[1].is_valid()

func _write_magicdawn_native_owner_parameters(rd: RenderingDevice, view: int,
		snapshot: Dictionary, replacement_requested: bool,
		scene_normalization: float) -> bool:
	if view < 0 or view >= 2 or not _ensure_magicdawn_native_owner_buffers(rd):
		return false
	var owner_transform: Variant = snapshot.get("owner_transform", Transform3D.IDENTITY)
	var owner_size: Variant = snapshot.get("owner_size", Vector3.ZERO)
	if not owner_transform is Transform3D or not owner_size is Vector3 \
			or owner_size.x <= 0.0 or owner_size.y <= 0.0 or owner_size.z <= 0.0:
		return false
	var pass_strength := float(_frame_parameters.x) if _frame_parameters is Vector4 \
			else float(parameters.x)
	var normalization := scene_normalization if is_finite(scene_normalization) \
			and scene_normalization > 0.0 else 1.0
	var values := PackedFloat32Array()
	_append_matrix4(values, owner_transform.affine_inverse())
	values.append_array(PackedFloat32Array([owner_size.x, owner_size.y,
		owner_size.z, 1.0]))
	values.append_array(PackedFloat32Array([
		maxf(float(snapshot.get("strength", 1.0)) * pass_strength, 0.0),
		1.0 if replacement_requested else 0.0,
		normalization,
		float(_magicdawn_receiver_qa_mode)]))
	var bytes := values.to_byte_array()
	if bytes.size() != MAGICDAWN_NATIVE_OWNER_PARAMETER_BYTES:
		return false
	if bytes == _magicdawn_native_owner_bytes[view]:
		return true
	if rd.buffer_update(_magicdawn_native_owner_ubos[view], 0, bytes.size(), bytes) != OK:
		return false
	_magicdawn_native_owner_bytes[view] = bytes
	return true

func _prepare_native_magicdawn_baked_sh(ctx: FRPPassContext,
		buffers: RenderSceneBuffersRD, snapshot: Dictionary,
		resolved_parameters: Variant, replacement_requested: bool) -> void:
	var bridge_reason := _magicdawn_native_bridge_reason(ctx)
	if not bridge_reason.is_empty():
		_native_baked_sh_state["status"] = "standalone_fallback"
		_native_baked_sh_state["fallback_reason"] = bridge_reason
		return
	if buffers == null:
		_native_baked_sh_state["status"] = "standalone_fallback"
		_native_baked_sh_state["fallback_reason"] = "missing_render_buffers"
		return
	if not replacement_requested or not _replacement_request_prepared:
		_native_baked_sh_state["status"] = "standalone_fallback"
		_native_baked_sh_state["fallback_reason"] = "sky_replacement_not_requested"
		return
	if bool(snapshot.get("surfel", false)) or bool(snapshot.get("streamed", false)) \
			or not bool(snapshot.get("use_clv", true)):
		_native_baked_sh_state["status"] = "standalone_fallback"
		_native_baked_sh_state["fallback_reason"] = "unsupported_scene_mode"
		return
	if buffers.get_view_count() < 1 or buffers.get_view_count() > 2:
		_native_baked_sh_state["status"] = "standalone_fallback"
		_native_baked_sh_state["fallback_reason"] = "unsupported_view_count:%d" % buffers.get_view_count()
		return
	if prt_apply_scale != 1 or clv_debug_view != CLVDebugView.OFF \
			or _clv_stats_capture_armed or int(prt_surface_exact_debug_mode) != 0:
		_native_baked_sh_state["status"] = "standalone_fallback"
		_native_baked_sh_state["fallback_reason"] = "unsupported_apply_configuration"
		return
	var data: Variant = snapshot.get("data")
	if not is_instance_valid(data) or not data.has_method("has_baked_indirect_sh") \
			or not bool(data.call("has_baked_indirect_sh")):
		_native_baked_sh_state["status"] = "standalone_fallback"
		_native_baked_sh_state["fallback_reason"] = "revision2_baked_sh_unavailable"
		return
	var baked_revision := int(data.get("baked_indirect_sh_revision"))
	if baked_revision != MAGICDAWN_BAKED_SH_REVISION:
		_native_baked_sh_state["status"] = "standalone_fallback"
		_native_baked_sh_state["fallback_reason"] = "baked_sh_revision_mismatch:%d" % baked_revision
		return
	var render_data := ctx.get_render_data()
	var scene_data := render_data.get_render_scene_data() if render_data != null else null
	var rd := RenderingServer.get_rendering_device()
	if scene_data == null or rd == null:
		_native_baked_sh_state["status"] = "standalone_fallback"
		_native_baked_sh_state["fallback_reason"] = "missing_scene_or_rendering_device"
		return
	if not _ensure_magicdawn_native_owner_buffers(rd):
		_native_baked_sh_state["status"] = "standalone_fallback"
		_native_baked_sh_state["fallback_reason"] = "owner_parameter_buffer_creation_failed"
		return

	var previous_snapshot := _frame_snapshot
	var previous_scene_data := _frame_scene_data
	var previous_parameters := _frame_parameters
	var previous_replacement := _frame_replacement_enabled
	var previous_pre_exposure := _pre_exposure
	var previous_scene_exposure := _scene_exposure_normalization
	var previous_frame_clipmap := _frame_clipmap
	var previous_magicdawn_active := _magicdawn_frame_active
	var previous_prt_scale := _frame_prt_scale
	_frame_snapshot = snapshot
	_frame_scene_data = scene_data
	_frame_parameters = resolved_parameters
	_frame_replacement_enabled = replacement_requested
	_pre_exposure = ctx.get_pre_exposure(0)
	_scene_exposure_normalization = _get_scene_exposure_normalization(ctx)
	_frame_prt_scale = 1
	_frame_clipmap = null
	_magicdawn_frame_active = false
	var frame := Engine.get_frames_drawn()
	var view_count := buffers.get_view_count()
	var cache_key := str(snapshot.get("cache_key", ""))
	var bake_version := int(snapshot.get("version", -1))
	var token := _next_magicdawn_publication_token()
	var published := not cache_key.is_empty() and bake_version >= 0
	var failure_reason := ""
	var failure_details: Dictionary = {}
	var publication_field_format_tag := -1
	var publication_codec := Vector4.ZERO
	_capture_gpu_timestamp(rd, "Native Prepare Begin")
	for view in view_count:
		var view_key := _native_view_key(buffers, view)
		_native_baked_sh_attempted_views[view_key] = {
			"frame": frame, "cache_key": cache_key, "version": bake_version,
			"layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"baked_sh_revision": baked_revision, "view": view,
			"view_count": view_count}
		if not published:
			published = false
			failure_reason = "invalid_publication_key"
			break
		if not _prepare_prt_clv_view(buffers, view, rd):
			published = false
			failure_reason = "layout17_cache_prepare_failed"
			failure_details = _magicdawn_runtime_state.duplicate(true)
			break
		var clipmap: RefCounted = _frame_clipmap
		if clipmap == null or not clipmap.has_method("get_field_textures") \
				or not clipmap.has_method("get_layout16_runtime_state"):
			published = false
			failure_reason = "layout17_cache_api_unavailable"
			break
		var fields_value: Variant = clipmap.call("get_field_textures")
		var fields: Array[RID] = []
		if fields_value is Array:
			for field_value in fields_value:
				if field_value is RID:
					fields.append(field_value)
		var fields_valid := true
		for field in fields:
			fields_valid = fields_valid and field.is_valid()
		if fields.size() != CLV_MAGICDAWN_BAKED_SH_TEXTURE_COUNT \
				or not fields_valid \
				or not clipmap.parameters.is_valid():
			published = false
			failure_reason = "layout17_field_or_parameter_rid_invalid"
			break
		var cache_report_value: Variant = clipmap.call("get_layout16_runtime_state")
		if not cache_report_value is Dictionary:
			published = false
			failure_reason = "layout17_cache_state_unavailable"
			break
		var cache_report: Dictionary = cache_report_value
		if int(cache_report.get("layout_version", -1)) != MAGICDAWN_NATIVE_LAYOUT_VERSION \
				or not bool(cache_report.get("texture_count_valid", false)) \
				or not bool(cache_report.get("texture_rids_valid", false)) \
				or int(cache_report.get("field_texture_count", -1)) != CLV_MAGICDAWN_BAKED_SH_TEXTURE_COUNT \
				or int(cache_report.get("clipmap_parameter_bytes", -1)) != 96 \
				or int(cache_report.get("geometry_epoch", -1)) < 0:
			published = false
			failure_reason = "layout17_cache_state_invalid"
			break
		var codec_value: Variant = cache_report.get("codec", Vector4.ZERO)
		var field_format_tag := int(cache_report.get("format_tag", -1))
		if not _magicdawn_layout16_codec_valid(codec_value, field_format_tag):
			published = false
			failure_reason = "layout17_codec_or_format_invalid"
			break
		var field_codec: Vector4 = codec_value
		publication_field_format_tag = field_format_tag
		publication_codec = field_codec
		var prepared_state := {
			"frame": frame, "buffer_instance_id": buffers.get_instance_id(),
			"view": view, "view_count": view_count,
			"cache_key": cache_key, "version": bake_version,
			"data_instance_id": data.get_instance_id(),
			"baked_sh_revision": baked_revision,
			"layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"field_format_tag": field_format_tag, "codec": field_codec,
			"geometry_epoch": int(cache_report.get("geometry_epoch", -1)),
			"content_revision": int(cache_report.get("content_revision", -1)),
			"clipmap": clipmap, "fields": fields,
			"parameters": clipmap.parameters,
			"cache_report": cache_report.duplicate(true), "prepared": true}
		_native_baked_sh_prepared_views[view_key] = prepared_state
		if not _write_magicdawn_native_owner_parameters(rd, view, snapshot,
				replacement_requested, _scene_exposure_normalization):
			published = false
			failure_reason = "layout17_owner_parameter_upload_failed"
			break
		ctx.call("set_magic_gi_baked_sh_input", view, fields,
				clipmap.parameters, _magicdawn_native_owner_ubos[view], field_codec, token)
		if not bool(ctx.call("has_magic_gi_baked_sh_input", view)):
			published = false
			failure_reason = "layout17_context_rejected_view"
			break
	if published:
		var publication := {"enabled": true, "active": false, "consumed": false,
			"frame": frame, "view_count": view_count, "publication_token": token,
			"cache_key": cache_key, "bake_version": bake_version,
			"baked_sh_revision": baked_revision,
			"layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"field_format_tag": publication_field_format_tag,
			"codec": publication_codec,
			"status": "published_waiting_for_native_draw",
			"fallback_reason": "native_consumption_not_confirmed",
			"strength": maxf(float(snapshot.get("strength", 1.0)) \
					* (float(resolved_parameters.x) if resolved_parameters is Vector4 \
						else float(parameters.x)), 0.0),
			"scene_exposure_normalization": _scene_exposure_normalization,
			"pre_exposure_applied_by": "FRP deferred-lighting tail exactly once",
			"replacement_enabled": replacement_requested,
			"sky_ownership_bridge_active": replacement_requested,
			"receiver_sample_qa_mode": _magicdawn_receiver_qa_mode,
			"sky_attachment_requested_for_standalone_fallback": _replacement_request_prepared}
		_native_baked_sh_publications[token] = publication
		_native_baked_sh_state = publication.duplicate(true)
	else:
		if failure_reason.is_empty():
			failure_reason = "invalid_publication_key"
		ctx.call("clear_magic_gi_baked_sh_inputs")
		_native_baked_sh_state = {"enabled": true, "active": false,
			"consumed": false, "frame": frame, "publication_token": token,
			"cache_key": cache_key, "bake_version": bake_version,
			"baked_sh_revision": baked_revision,
			"layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"status": "standalone_fallback", "fallback_reason": failure_reason,
			"prepared_view_count": _native_baked_sh_prepared_views.size(),
			"failure_details": failure_details}
	_capture_gpu_timestamp(rd, "Native Prepare End")
	_frame_clipmap = previous_frame_clipmap
	_magicdawn_frame_active = previous_magicdawn_active
	_frame_prt_scale = previous_prt_scale
	_frame_snapshot = previous_snapshot
	_frame_scene_data = previous_scene_data
	_frame_parameters = previous_parameters
	_frame_replacement_enabled = previous_replacement
	_pre_exposure = previous_pre_exposure
	_scene_exposure_normalization = previous_scene_exposure
	_frame_view_matrices.clear()
	_frame_input_bindings.clear()

func _magicdawn_native_prepared_state(buffers: RenderSceneBuffersRD, view: int,
		snapshot: Dictionary) -> Dictionary:
	if buffers == null or view < 0 or view >= buffers.get_view_count():
		return {}
	var view_key := _native_view_key(buffers, view)
	var state: Dictionary = _native_baked_sh_prepared_views.get(view_key, {})
	var data: Variant = snapshot.get("data")
	if state.is_empty() or not bool(state.get("prepared", false)) \
			or int(state.get("frame", -1)) != Engine.get_frames_drawn() \
			or int(state.get("buffer_instance_id", -1)) != buffers.get_instance_id() \
			or int(state.get("view", -1)) != view \
			or int(state.get("view_count", -1)) != buffers.get_view_count() \
			or str(state.get("cache_key", "")) != str(snapshot.get("cache_key", "")) \
			or int(state.get("version", -1)) != int(snapshot.get("version", -1)) \
			or not is_instance_valid(data) \
			or int(state.get("data_instance_id", -1)) != data.get_instance_id() \
			or int(state.get("baked_sh_revision", -1)) != MAGICDAWN_BAKED_SH_REVISION \
			or int(data.get("baked_indirect_sh_revision")) != MAGICDAWN_BAKED_SH_REVISION \
			or int(state.get("layout_version", -1)) != MAGICDAWN_NATIVE_LAYOUT_VERSION:
		return {}
	var clipmap: RefCounted = state.get("clipmap")
	if clipmap == null or not clipmap.parameters.is_valid() \
			or not clipmap.has_method("get_field_textures") \
			or not clipmap.has_method("get_layout16_runtime_state"):
		return {}
	var clip_key := "%d:%d:%d:%s" % [buffers.get_instance_id(), view,
			MAGICDAWN_NATIVE_LAYOUT_VERSION, str(snapshot.get("cache_key", ""))]
	if not _clipmaps.has(clip_key) or _clipmaps[clip_key].get("cache") != clipmap:
		return {}
	var report_value: Variant = clipmap.call("get_layout16_runtime_state")
	if not report_value is Dictionary:
		return {}
	var report: Dictionary = report_value
	if int(report.get("layout_version", -1)) != MAGICDAWN_NATIVE_LAYOUT_VERSION \
			or int(report.get("geometry_epoch", -2)) != int(state.get("geometry_epoch", -1)) \
			or int(report.get("content_revision", -2)) != int(state.get("content_revision", -1)) \
			or int(report.get("clipmap_parameter_bytes", -1)) != 96 \
			or int(report.get("format_tag", -1)) != int(state.get("field_format_tag", -2)) \
			or report.get("codec", Vector4.ZERO) != state.get("codec", Vector4.ONE) \
			or not _magicdawn_layout16_codec_valid(report.get("codec", Vector4.ZERO),
					int(report.get("format_tag", -1))):
		return {}
	var fields_value: Variant = clipmap.call("get_field_textures")
	if not fields_value is Array or fields_value.size() != CLV_MAGICDAWN_BAKED_SH_TEXTURE_COUNT:
		return {}
	var expected_fields: Array = state.get("fields", [])
	if expected_fields.size() != fields_value.size():
		return {}
	for index in fields_value.size():
		var field: RID = fields_value[index]
		if field != expected_fields[index] or not field.is_valid():
			return {}
	return state

func _magicdawn_native_prepare_attempted_this_frame(buffers: RenderSceneBuffersRD,
		view: int) -> bool:
	if buffers == null:
		return false
	var state: Dictionary = _native_baked_sh_attempted_views.get(
			_native_view_key(buffers, view), {})
	return not state.is_empty() and int(state.get("frame", -1)) == Engine.get_frames_drawn()

func _confirmed_magicdawn_native_publication(ctx: FRPPassContext,
		snapshot: Dictionary) -> Dictionary:
	if not native_baked_sh_lighting_enabled or ctx == null \
			or not ctx.has_method("get_magic_gi_baked_sh_consumed_token"):
		return {}
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return {}
	var token := int(ctx.call("get_magic_gi_baked_sh_consumed_token"))
	if token <= 0 or not _native_baked_sh_publications.has(token):
		return {}
	var publication: Dictionary = _native_baked_sh_publications[token].duplicate(true)
	# A matching consumed token is emitted only after the renderer submitted its
	# native lighting draw with every current view input. Once that happened, late
	# snapshot changes must never cause standalone Apply to add the same GI twice.
	# Keep the consumed publication for this frame and report any drift for refresh
	# on the next prepare instead of rejecting the token.
	var resolved_value: Variant = get_resolved_parameters(ctx).get("parameters", parameters)
	var current_pass_strength := float(resolved_value.x) if resolved_value is Vector4 \
			else float(parameters.x)
	var current_strength := maxf(float(snapshot.get("strength", 1.0)) \
			* current_pass_strength, 0.0)
	var current_normalization := _get_scene_exposure_normalization(ctx)
	if int(publication.get("frame", -1)) != Engine.get_frames_drawn() \
			or int(publication.get("view_count", -1)) != buffers.get_view_count() \
			or int(publication.get("baked_sh_revision", -1)) != MAGICDAWN_BAKED_SH_REVISION \
			or int(publication.get("layout_version", -1)) != MAGICDAWN_NATIVE_LAYOUT_VERSION:
		return {}
	var tuple_matches := str(publication.get("cache_key", "")) \
			== str(snapshot.get("cache_key", "")) \
			and int(publication.get("bake_version", -1)) == int(snapshot.get("version", -1)) \
			and is_equal_approx(float(publication.get("strength", -1.0)), current_strength) \
			and is_equal_approx(float(publication.get("scene_exposure_normalization", -1.0)), current_normalization) \
			and _replacement_requested(snapshot, current_pass_strength) \
			and _is_magicdawn_authored_snapshot(snapshot)
	var cache_lease_matches := true
	for view in buffers.get_view_count():
		if not ctx.has_method("has_magic_gi_baked_sh_input") \
				or not bool(ctx.call("has_magic_gi_baked_sh_input", view)) \
				or _magicdawn_native_prepared_state(buffers, view, snapshot).is_empty():
			cache_lease_matches = false
			break
	publication["publication_token"] = token
	publication["confirmed_consumed_token"] = token
	publication["published_tuple_matches_current"] = tuple_matches
	publication["prepared_cache_lease_matches"] = cache_lease_matches
	publication["status"] = "native_consumed" if tuple_matches and cache_lease_matches \
			else "native_consumed_frozen_payload"
	publication["deferred_refresh_reason"] = "" if tuple_matches and cache_lease_matches \
			else ("snapshot_changed_after_native_draw" if not tuple_matches \
				else "cache_lease_changed_after_native_draw")
	publication["active"] = true
	publication["consumed"] = true
	publication["fallback_reason"] = ""
	return publication

func _native_view_key(buffers: RenderSceneBuffersRD, view: int) -> String:
	return "%d:%d" % [buffers.get_instance_id(), view]

func _native_general_queue_eligibility_reason(buffers: RenderSceneBuffersRD,
		snapshot: Dictionary) -> String:
	if not native_deferred_general_queue_enabled:
		return "disabled"
	if not native_clv_lighting_enabled:
		return "native_clv_disabled"
	if mode != Mode.COMPUTE:
		return "apply_mode_not_compute"
	if buffers == null or buffers.get_view_count() != 1:
		return "requires_single_view"
	if int(buffers.get_msaa_3d()) != RenderingServer.VIEWPORT_MSAA_DISABLED:
		return "requires_single_sample_gbuffer"
	if not bool(snapshot.get("use_clv", true)) or bool(snapshot.get("streamed", false)) \
			or bool(snapshot.get("surfel", false)):
		return "unsupported_source_mode"
	if _clv_cache_backend(snapshot) == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART:
		return "block_chart_requires_compute_consumer"
	if not prt_fast_shader_variant_enabled or prt_apply_scale != 1 \
			or clv_debug_view != CLVDebugView.OFF or _prt_raw_debug_output \
			or _clv_stats_capture_armed or _clv_stats_capture_active \
			or approximate_clv_volume_enabled or exact_clv_corner_visibility_enabled \
			or prt_surface_exact_debug_mode != 0:
		return "requires_ordinary_fast_exact_sampler"
	for constant_id in [2, 3, 5]:
		if bool(shader_keywords.get(constant_id, false)):
			return "unsupported_sampler_specialization_%d" % constant_id
	return ""

func _native_general_queue_bridge_reason(ctx: FRPPassContext) -> String:
	if ctx == null:
		return "missing_context"
	var required_methods := PackedStringArray([
		"set_magic_gi_general_queue_input",
		"clear_magic_gi_general_queue_inputs",
		"has_magic_gi_general_queue_input",
		"set_magic_gi_general_queue_active",
		"is_magic_gi_general_queue_active",
		"get_magic_gi_general_queue_runtime_msaa",
		"get_magic_gi_general_queue_runtime_view_count",
	])
	for method_name in required_methods:
		if not ctx.has_method(method_name):
			return "missing_queue_bridge:" + method_name
	return ""

func _prepare_native_deferred_general_queue(ctx: FRPPassContext,
		buffers: RenderSceneBuffersRD, rd: RenderingDevice, snapshot: Dictionary) -> bool:
	var size := buffers.get_internal_size() if buffers != null else Vector2i.ZERO
	var reason := _native_general_queue_eligibility_reason(buffers, snapshot)
	if not reason.is_empty():
		_native_general_queue_state["fallback_reason"] = reason
		return false
	var bridge_reason := _native_general_queue_bridge_reason(ctx)
	if not bridge_reason.is_empty():
		_native_general_queue_state["fallback_reason"] = bridge_reason
		return false
	if rd == null or size.x <= 0 or size.y <= 0:
		_native_general_queue_state["fallback_reason"] = "invalid_rendering_device_or_size"
		return false
	var pixel_count := size.x * size.y
	if pixel_count <= 0 or pixel_count > 1073741823:
		_native_general_queue_state["fallback_reason"] = "queue_capacity_out_of_range"
		return false
	var cache_key := str(snapshot.get("cache_key", ""))
	if cache_key.is_empty() or not _bake_resources.has(cache_key):
		_native_general_queue_state["fallback_reason"] = "bake_resources_unavailable"
		return false
	var cached: Dictionary = _bake_resources[cache_key]
	var directional: RefCounted = cached.get("directional")
	if directional == null or not directional.lighting.is_valid() \
			or not cached.get("geometry", RID()).is_valid() \
			or not cached.get("visibility_moments", RID()).is_valid() \
			or not cached.get("visibility_nodes", RID()).is_valid() \
			or not cached.get("visibility_triangles", RID()).is_valid():
		_native_general_queue_state["fallback_reason"] = "general_sampler_resources_unavailable"
		return false
	var capability := _prt_compact_capability(rd)
	if not bool(capability.get("supported", false)):
		_native_general_queue_state["fallback_reason"] = "queue_capability:" + str(
				capability.get("reason", "unsupported"))
		return false
	var full_groups_x := _prt_compact_ceil_div(size.x, MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE)
	var full_groups_y := _prt_compact_ceil_div(size.y, MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE)
	var compact_groups_x := _prt_compact_ceil_div(pixel_count,
			MAGIC_GI_PRT_QUEUE_LOCAL_INVOCATIONS)
	var max_groups_x := int(capability.get("max_compute_workgroup_count_x", 0))
	var max_groups_y := int(capability.get("max_compute_workgroup_count_y", 0))
	if full_groups_x <= 0 or full_groups_y <= 0 or compact_groups_x <= 0 \
			or full_groups_x > max_groups_x or compact_groups_x > max_groups_x \
			or full_groups_y > max_groups_y:
		_native_general_queue_state["fallback_reason"] = "consumer_dispatch_limit"
		return false
	if not _ensure_prt_source_pending_texture(rd, size).is_valid():
		_native_general_queue_state["fallback_reason"] = "source_pending_texture_unavailable"
		return false
	if not _ensure_prt_compact_queue_buffers(rd, pixel_count):
		_native_general_queue_state["fallback_reason"] = "queue_buffers_unavailable"
		return false
	if not _ensure_prt_compact_apply_program(rd) \
			or not _ensure_prt_native_general_queue_consumer(rd):
		_native_general_queue_state["fallback_reason"] = "source_queue_pipeline_unavailable"
		return false
	if not _ensure_prt_compact_finalize_program(rd) \
			or not _ensure_prt_compact_finalize_uniform_set(rd):
		_native_general_queue_state["fallback_reason"] = "queue_finalize_unavailable"
		return false
	_frame_input_bindings.clear()
	_frame_view_matrices.clear()
	_binding_error = false
	var binding_data := _collect_bindings(buffers, 0, rd)
	if _binding_error:
		_native_general_queue_state["fallback_reason"] = "source_queue_bindings_unavailable"
		_frame_input_bindings.clear()
		_frame_view_matrices.clear()
		return false
	var uniforms: Array[RDUniform] = binding_data["uniforms"].duplicate()
	var occupied: Dictionary = {}
	for uniform_value in uniforms:
		var uniform: RDUniform = uniform_value
		occupied[uniform.binding] = true
	if occupied.has(MAGIC_GI_SOURCE_PENDING_BINDING) \
			or occupied.has(MAGIC_GI_PRT_MISS_QUEUE_BINDING) \
			or occupied.has(MAGIC_GI_PRT_MISS_QUEUE_CONTROL_BINDING):
		_native_general_queue_state["fallback_reason"] = "source_queue_binding_collision"
		_frame_input_bindings.clear()
		_frame_view_matrices.clear()
		return false
	uniforms.append(U.image(MAGIC_GI_SOURCE_PENDING_BINDING, _prt_source_pending_texture))
	uniforms.append(U.storage_buffer(MAGIC_GI_PRT_MISS_QUEUE_BINDING,
			_prt_compact_queue_buffer))
	uniforms.append(U.storage_buffer(MAGIC_GI_PRT_MISS_QUEUE_CONTROL_BINDING,
			_prt_compact_queue_control_buffer))
	var consumer_set := _make_prt_compact_apply_uniform_set(rd, uniforms)
	if not consumer_set.is_valid() or not rd.uniform_set_is_valid(consumer_set):
		_native_general_queue_state["fallback_reason"] = "source_queue_uniform_set_unavailable"
		_frame_input_bindings.clear()
		_frame_view_matrices.clear()
		return false
	if rd.buffer_clear(_prt_compact_queue_control_buffer, 0,
			MAGIC_GI_PRT_QUEUE_CONTROL_BYTES) != OK \
			or rd.texture_clear(_prt_source_pending_texture, Color(0, 0, 0, 0),
				0, 1, 0, 1) != OK:
		_native_general_queue_state["fallback_reason"] = "queue_frame_clear_failed"
		_frame_input_bindings.clear()
		_frame_view_matrices.clear()
		return false
	# The renderer inserts an ordering boundary before its next eligible lighting draw;
	# descriptor-resource hazards order these clears before fragment writes.
	ctx.call("set_magic_gi_general_queue_input", 0,
			cached["geometry"], cached["visibility_moments"],
			cached["visibility_nodes"], cached["visibility_triangles"],
			directional.lighting, _prt_compact_queue_buffer,
			_prt_compact_queue_control_buffer, _prt_source_pending_texture)
	_native_general_queue_state["preflight_ready"] = true
	_native_general_queue_state["fallback_reason"] = ""
	_native_general_queue_state["queue_capacity_pixels"] = pixel_count
	_native_general_queue_state["consumer_uniform_set"] = consumer_set.get_id()
	_native_general_queue_state["consumer_pipeline"] = _prt_compact_pipelines[
			"native_general_source_queue"].get_id()
	_native_general_queue_uniform_set = consumer_set
	_prt_compact_last_capability = capability.duplicate(true)
	_sync_owned_rid_snapshot()
	_frame_input_bindings.clear()
	_frame_view_matrices.clear()
	return true

func _native_prepared_state(buffers: RenderSceneBuffersRD, view: int,
		cache_key: String) -> Dictionary:
	if not native_clv_lighting_enabled or buffers == null or cache_key.is_empty() or _frame_prt_scale != 1 \
			or prt_apply_scale != 1 or clv_debug_view != CLVDebugView.OFF \
			or int(prt_surface_exact_debug_mode) != 0:
		return {}
	var state: Dictionary = _native_prepared_views.get(_native_view_key(buffers, view), {})
	if int(state.get("frame", -1)) != Engine.get_frames_drawn() \
			or str(state.get("cache_key", "")) != cache_key \
			or int(state.get("version", -1)) != int(_frame_snapshot.get("version", -1)):
		return {}
	var clipmap: RefCounted = state.get("clipmap")
	if clipmap == null or not clipmap.texture.is_valid() or not clipmap.tags.is_valid() \
			or not clipmap.support.is_valid() or not clipmap.parameters.is_valid() \
			or int(clipmap.get("resolution")) != _effective_clv_resolution() \
			or int(clipmap.get("parameter_resolution")) != int(clipmap.get("resolution")):
		return {}
	return state

func _ensure_native_parameter_buffers(rd: RenderingDevice) -> bool:
	var changed := false
	if not _native_gi_parameters_ubo.is_valid():
		var zero := PackedByteArray()
		zero.resize(96)
		_native_gi_parameters_ubo = rd.uniform_buffer_create(96, zero)
		_native_gi_parameters_bytes = PackedByteArray()
		changed = true
	for view in 2:
		if not _native_owner_ubos[view].is_valid():
			var zero := PackedByteArray()
			zero.resize(96)
			_native_owner_ubos[view] = rd.uniform_buffer_create(96, zero)
			_native_owner_bytes[view] = PackedByteArray()
			changed = true
	if changed:
		_sync_owned_rid_snapshot()
	return _native_gi_parameters_ubo.is_valid() \
			and _native_owner_ubos[0].is_valid() and _native_owner_ubos[1].is_valid()

func _write_native_gi_parameters(rd: RenderingDevice, snapshot: Dictionary) -> bool:
	if not _ensure_native_parameter_buffers(rd):
		return false
	var cache_key := str(snapshot.get("cache_key", ""))
	if not _bake_resources.has(cache_key):
		return false
	var cached: Dictionary = _bake_resources[cache_key]
	var bake_data: Variant = snapshot.get("data")
	var world_to_grid: Variant = bake_data.get("world_to_grid") if is_instance_valid(bake_data) else null
	var dimensions: Variant = cached.get("grid_dims", Vector3i.ZERO)
	if not world_to_grid is Transform3D or not dimensions is Vector3i:
		return false
	var values := PackedFloat32Array()
	_append_matrix4(values, world_to_grid)
	values.append_array(PackedFloat32Array([float(dimensions.x), float(dimensions.y),
		float(dimensions.z), float(cached.get("probe_count", 0))]))
	values.append_array(PackedFloat32Array([float(snapshot.get("strength", 1.0)),
		float(cached.get("spacing", 0.0)), 1.0 if _frame_replacement_enabled else 0.0,
		1.0 if bool(cached.get("exact_visibility", false)) else 0.0]))
	var bytes := values.to_byte_array()
	if bytes.size() != 96:
		return false
	if bytes == _native_gi_parameters_bytes:
		return true
	if rd.buffer_update(_native_gi_parameters_ubo, 0, bytes.size(), bytes) != OK:
		return false
	_native_gi_parameters_bytes = bytes
	return true

func _write_native_owner_parameters(rd: RenderingDevice, view: int,
		snapshot: Dictionary, replacement_requested: bool, exposure_scale: float) -> bool:
	if view < 0 or view >= 2 or not _ensure_native_parameter_buffers(rd):
		return false
	var owner_transform: Variant = snapshot.get("owner_transform", Transform3D.IDENTITY)
	var owner_size: Variant = snapshot.get("owner_size", Vector3.ZERO)
	if not owner_transform is Transform3D or not owner_size is Vector3 \
			or owner_size.x <= 0.0 or owner_size.y <= 0.0 or owner_size.z <= 0.0:
		return false
	var pass_strength := float(_frame_parameters.x) if _frame_parameters is Vector4 else float(parameters.x)
	var values := PackedFloat32Array()
	_append_matrix4(values, owner_transform.affine_inverse())
	values.append_array(PackedFloat32Array([owner_size.x, owner_size.y, owner_size.z, 1.0]))
	values.append_array(PackedFloat32Array([
		maxf(float(snapshot.get("strength", 1.0)) * pass_strength, 0.0),
		1.0 if replacement_requested else 0.0,
		exposure_scale if is_finite(exposure_scale) and exposure_scale > 0.0 else 1.0,
		0.0]))
	var bytes := values.to_byte_array()
	if bytes.size() != 96:
		return false
	if bytes == _native_owner_bytes[view]:
		return true
	if rd.buffer_update(_native_owner_ubos[view], 0, bytes.size(), bytes) != OK:
		return false
	_native_owner_bytes[view] = bytes
	return true

func _clear_magic_gi_output(ctx: FRPPassContext) -> void:
	if ctx == null:
		return
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	var rd := RenderingServer.get_rendering_device()
	if buffers == null or rd == null or inputs.size() <= 5:
		return
	var declaration: TextureInput = inputs[5]
	if declaration == null:
		return
	for view in buffers.get_view_count():
		var output := declaration.get_texture(buffers, view)
		if output.is_valid():
			rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)

func _replacement_requested(snapshot: Dictionary, pass_strength := 1.0) -> bool:
	return bool(snapshot.get("replacement_enabled", false)) \
		and float(snapshot.get("strength", 1.0)) * pass_strength > 0.0

func _get_rtgi_runtime_script() -> Script:
	if not _rtgi_runtime_script_checked:
		_rtgi_runtime_script_checked = true
		if ResourceLoader.exists(RTGI_RUNTIME_PATH):
			var loaded: Variant = load(RTGI_RUNTIME_PATH)
			if loaded is Script:
				_rtgi_runtime_script = loaded
	return _rtgi_runtime_script

func _queue_surfel_runtime_start() -> void:
	if _surfel_runtime_start_queued:
		return
	var runtime := _get_rtgi_runtime_script()
	if runtime == null:
		return
	_surfel_runtime_start_queued = true
	_start_surfel_runtime.call_deferred()

func _start_surfel_runtime() -> void:
	_surfel_runtime_start_queued = false
	var runtime := _get_rtgi_runtime_script()
	if runtime != null and runtime.has_method("start"):
		runtime.call("start")

func _warn_surfel_once(key: String, message: String) -> void:
	if _surfel_warnings.has(key):
		return
	_surfel_warnings[key] = true
	push_warning(message)

func _warn_missing_replacement_bridge() -> void:
	if _replacement_bridge_warning_shown:
		return
	_replacement_bridge_warning_shown = true
	push_warning("Magic GI is using additive fallback because FRP did not provide the requested SkyLight diffuse attachment. Rebuild/update feng-godot to enable exact SkyLight replacement.")

func _parameter_bytes(scale_sign := 1.0) -> PackedByteArray:
	var value: Vector4 = _frame_parameters if _frame_parameters is Vector4 else parameters
	var pre_exposure := _pre_exposure * _scene_exposure_normalization
	if _magicdawn_frame_active:
		return PackedFloat32Array([value.x, pre_exposure,
				float(_magicdawn_receiver_qa_mode),
				201.0 if _magicdawn_stats_capture_active else 0.0]).to_byte_array()
	if _frame_native_clv_fallback_only and _frame_prt_scale == 1:
		scale_sign = -absf(scale_sign)
	var debug_view := 100.0 if _prt_raw_debug_output else float(clv_debug_view)
	var exact_debug_mode := int(prt_surface_exact_debug_mode)
	if _frame_prt_scale == 1 and _clv_stats_capture_active \
			and clv_debug_view == CLVDebugView.OFF and exact_debug_mode == 0:
		debug_view = 106.0
	if _frame_prt_scale == 1 and ((exact_debug_mode >= 100 and exact_debug_mode <= 105) \
			or (exact_debug_mode >= 107 and exact_debug_mode <= 110)):
		debug_view = float(exact_debug_mode)
	return PackedFloat32Array([value.x, pre_exposure,
		float(_frame_prt_scale) * scale_sign, debug_view]).to_byte_array()

func _init() -> void:
	inputs = _make_inputs()
	outputs = _make_outputs()
	_surfel_gpu = SurfelGPU.new()
	_surfel_nrd = SurfelNRD.new()
	_sky_diffuse_input = TextureInput.new()
	_sky_diffuse_input.binding = 12
	_sky_diffuse_input.source = TextureInput.Source.CUSTOM
	_sky_diffuse_input.custom_scope = NativeSpec.SCOPE_FRP_CLUSTERED
	_sky_diffuse_input.custom_name = SKY_DIFFUSE_TEXTURE

func runtime_script_path() -> String:
	return RUNTIME_SCRIPT_PATH


## Diagnostic switch for paired validation; normal rendering enables culling when
## the immutable page metadata is valid.
func set_probe_cluster_culling_enabled(enabled: bool) -> void:
	probe_cluster_culling_enabled = enabled


func _probe_neighbor_mask_is_usable(cached: Dictionary) -> bool:
	if not probe_neighbor_mask_optimization_enabled \
			or not bool(cached.get("probe_neighbor_mask_enabled", false)):
		return false
	var mask_rid: RID = cached.get("probe_neighbor_masks", RID())
	return mask_rid.is_valid()


func _probe_neighbor_cell_list_is_usable(cached: Dictionary) -> bool:
	if not probe_neighbor_cell_list_optimization_enabled \
			or not bool(cached.get("probe_neighbor_cell_list_enabled", false)):
		return false
	var list_rid: RID = cached.get("probe_neighbor_cell_lists", RID())
	return list_rid.is_valid()


func get_probe_cluster_debug_info(cache_key := "") -> Dictionary:
	var selected_key := cache_key
	if selected_key.is_empty():
		selected_key = str(_frame_snapshot.get("cache_key", ""))
	if not _bake_resources.has(selected_key):
		return {"cache_key": selected_key, "available": false,
			"culling_enabled": probe_cluster_culling_enabled}
	var cached: Dictionary = _bake_resources[selected_key]
	var cluster_rid: RID = cached.get("probe_clusters", RID())
	var table_valid := bool(cached.get("probe_cluster_enabled", false)) \
			and cluster_rid.is_valid()
	return {"cache_key": selected_key, "available": table_valid,
		"active": probe_cluster_culling_enabled and table_valid,
		"culling_enabled": probe_cluster_culling_enabled,
		"probe_cluster_bytes": int(cached.get("probe_cluster_bytes", 0)),
		"cluster_gpu_bytes": int(cached.get("probe_cluster_bytes", 0)),
		"cell_count": int(cached.get("probe_cluster_cell_count", 0)),
		"cluster_count": int(cached.get("probe_cluster_count", 0)),
		"probe_slots": int(cached.get("probe_cluster_probe_slots", 0)),
		"neighbor_mask_enabled": bool(cached.get("probe_neighbor_mask_enabled", false)),
		"neighbor_mask_runtime_enabled": probe_neighbor_mask_optimization_enabled,
		"neighbor_mask_bytes": int(cached.get("probe_neighbor_mask_bytes", 0)),
		"neighbor_mask_candidate_cell_records": int(cached.get("probe_neighbor_mask_candidate_cell_records", 0)),
		"neighbor_mask_bound": cached.get("apply_neighbor_mask", RID()).is_valid(),
		"neighbor_mask_active_for_last_draw": _probe_neighbor_mask_is_usable(cached) \
				and _probe_cluster_debug_bound_keys.has(selected_key),
		"neighbor_cell_list_requested": probe_neighbor_cell_list_optimization_enabled,
		"neighbor_cell_list_enabled": bool(cached.get("probe_neighbor_cell_list_enabled", false)),
		"neighbor_cell_list_active_for_last_draw": _probe_neighbor_cell_list_is_usable(cached) \
				and _probe_cluster_debug_bound_keys.has(selected_key),
		"neighbor_cell_list_bytes": int(cached.get("probe_neighbor_cell_list_bytes", 0)),
		"neighbor_cell_list_candidate_records": int(cached.get("probe_neighbor_cell_list_candidate_records", 0)),
		"neighbor_cell_list_validation": cached.get("probe_neighbor_cell_list_validation", {}),
		"neighbor_cell_list_reason": str(cached.get("probe_neighbor_cell_list_reason", "")),
		"signature": str(cached.get("probe_cluster_signature", "")),
		"buffer_valid": cluster_rid.is_valid(),
		"streamed": bool(cached.get("stream_page", false)),
		"page_key": str(cached.get("page_key", "")),
		"active_for_last_draw": _probe_cluster_debug_bound_keys.has(selected_key),
		"gpu_bytes": int(cached.get("gpu_bytes", 0))}


func get_probe_cluster_debug_info_all() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key_value in _bake_resources.keys():
		var info := get_probe_cluster_debug_info(str(key_value))
		if not info.is_empty():
			result.append(info)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("cache_key", "")) < str(b.get("cache_key", "")))
	return result


## Precompute which cells in each receiver cell's exact radius-two lookup are
## occupied. The shader still traverses the same 5^3 neighborhood in the same
## order and fetches the same probe slots; this only avoids reading slot zero
## from the source index texture for known-empty cells.
func _probe_neighbor_mask_source_counts(data: Resource, dimensions: Vector3i) -> Dictionary:
	var cells := dimensions.x * dimensions.y * dimensions.z
	if dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0 \
			or dimensions.x > 64 or dimensions.y > 64 or dimensions.z > 64 \
			or cells <= 0 or cells > PROBE_NEIGHBOR_MASK_MAX_CELLS:
		return {"valid": false, "reason": "grid_dimensions_out_of_range"}
	var indices_value: Variant = data.get("cell_indices")
	if not indices_value is PackedInt32Array:
		return {"valid": false, "reason": "cell_indices_missing"}
	var indices: PackedInt32Array = indices_value
	var adaptive := bool(data.get("adaptive_placement"))
	var ranges_value: Variant = data.get("cell_ranges")
	var ranges: PackedInt32Array = ranges_value if ranges_value is PackedInt32Array else PackedInt32Array()
	var counts := PackedInt32Array()
	counts.resize(cells)
	if adaptive:
		if ranges.size() != cells * 2:
			return {"valid": false, "reason": "adaptive_range_size_mismatch"}
		for cell in cells:
			var first := int(ranges[cell * 2])
			var count := int(ranges[cell * 2 + 1])
			if first < 0 or count < 0 or first + count > indices.size():
				return {"valid": false, "reason": "adaptive_range_out_of_bounds"}
			counts[cell] = count
	else:
		const fixed_capacity := 8
		if indices.size() != cells * fixed_capacity:
			return {"valid": false, "reason": "fixed_capacity_size_mismatch"}
		for cell in cells:
			var first := cell * fixed_capacity
			var count := 0
			for slot in fixed_capacity:
				if indices[first + slot] < 0:
					break
				count += 1
			counts[cell] = count
	return {"valid": true, "counts": counts, "indices": indices,
		"ranges": ranges, "adaptive": adaptive}


func build_probe_neighbor_mask_payload(data: Resource, dimensions: Vector3i) -> Dictionary:
	var source := _probe_neighbor_mask_source_counts(data, dimensions)
	if not bool(source.get("valid", false)):
		return {"enabled": false, "reason": str(source.get("reason", "invalid_source")),
			"words": PackedInt32Array([0, 0, 0, 0]), "occupied_cells": 0,
			"candidate_cell_records": 0}
	var counts: PackedInt32Array = source["counts"]
	var cells := dimensions.x * dimensions.y * dimensions.z
	var words := PackedInt32Array()
	words.resize(cells * PROBE_NEIGHBOR_MASK_WORDS)
	words.fill(0)
	var occupied_cells := 0
	for count in counts:
		if count > 0:
			occupied_cells += 1
	var candidate_cell_records := 0
	for z in range(dimensions.z):
		for y in range(dimensions.y):
			for x in range(dimensions.x):
				var receiver_flat := x + y * dimensions.x + z * dimensions.x * dimensions.y
				var word_base := receiver_flat * PROBE_NEIGHBOR_MASK_WORDS
				for dz in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
					var source_z := z + dz
					if source_z < 0 or source_z >= dimensions.z:
						continue
					for dy in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
						var source_y := y + dy
						if source_y < 0 or source_y >= dimensions.y:
							continue
						for dx in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
							var source_x := x + dx
							if source_x < 0 or source_x >= dimensions.x:
								continue
							var source_flat := source_x + source_y * dimensions.x \
									+ source_z * dimensions.x * dimensions.y
							if counts[source_flat] <= 0:
								continue
							var neighbor_ordinal := (dz + PROBE_NEIGHBOR_MASK_RADIUS) * 25 \
									+ (dy + PROBE_NEIGHBOR_MASK_RADIUS) * 5 \
									+ (dx + PROBE_NEIGHBOR_MASK_RADIUS)
							var word_index := neighbor_ordinal >> 5
							var bit_index := neighbor_ordinal & 31
							words[word_base + word_index] = int(words[word_base + word_index]) \
									| (1 << bit_index)
							candidate_cell_records += 1
	var payload := {"enabled": true, "words": words, "occupied_cells": occupied_cells,
		"candidate_cell_records": candidate_cell_records,
		"bytes": words.size() * 4}
	var verification := validate_probe_neighbor_mask_payload(data, dimensions, payload)
	payload["validated_exactly"] = bool(verification.get("valid", false))
	payload["validation"] = verification
	if not bool(payload["validated_exactly"]):
		payload["enabled"] = false
	return payload


## Compare the original 5^3 lookup traversal with the masked traversal for every
## receiver cell, including boundary clipping and the exact ordered probe IDs.
func validate_probe_neighbor_mask_payload(data: Resource, dimensions: Vector3i,
		payload: Dictionary = {}) -> Dictionary:
	if payload.is_empty():
		return {"valid": false, "reason": "payload_missing"}
	var source := _probe_neighbor_mask_source_counts(data, dimensions)
	if not bool(source.get("valid", false)):
		return {"valid": false, "reason": str(source.get("reason", "invalid_source"))}
	if not bool(payload.get("enabled", false)):
		return {"valid": false, "reason": str(payload.get("reason", "payload_disabled"))}
	var counts: PackedInt32Array = source["counts"]
	var indices: PackedInt32Array = source["indices"]
	var ranges: PackedInt32Array = source["ranges"]
	var adaptive := bool(source["adaptive"])
	var words_value: Variant = payload.get("words")
	if not words_value is PackedInt32Array:
		return {"valid": false, "reason": "mask_words_missing"}
	var words: PackedInt32Array = words_value
	var cells := dimensions.x * dimensions.y * dimensions.z
	if words.size() != cells * PROBE_NEIGHBOR_MASK_WORDS:
		return {"valid": false, "reason": "mask_word_count_mismatch",
			"expected_words": cells * PROBE_NEIGHBOR_MASK_WORDS,
			"actual_words": words.size()}
	var receiver_cells_checked := 0
	var in_bounds_neighbor_slots := 0
	var occupied_neighbor_slots := 0
	var skipped_empty_neighbor_slots := 0
	var original_probe_visit_count := 0
	var masked_probe_visit_count := 0
	for z in range(dimensions.z):
		for y in range(dimensions.y):
			for x in range(dimensions.x):
				var receiver_flat := x + y * dimensions.x + z * dimensions.x * dimensions.y
				var word_base := receiver_flat * PROBE_NEIGHBOR_MASK_WORDS
				var original_receiver_visits := PackedInt32Array()
				var masked_receiver_visits := PackedInt32Array()
				for dz in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
					var source_z := z + dz
					if source_z < 0 or source_z >= dimensions.z:
						continue
					for dy in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
						var source_y := y + dy
						if source_y < 0 or source_y >= dimensions.y:
							continue
						for dx in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
							var source_x := x + dx
							if source_x < 0 or source_x >= dimensions.x:
								continue
							in_bounds_neighbor_slots += 1
							var source_flat := source_x + source_y * dimensions.x \
									+ source_z * dimensions.x * dimensions.y
							var neighbor_ordinal := (dz + PROBE_NEIGHBOR_MASK_RADIUS) * 25 \
									+ (dy + PROBE_NEIGHBOR_MASK_RADIUS) * 5 \
									+ (dx + PROBE_NEIGHBOR_MASK_RADIUS)
							var bit_index := neighbor_ordinal & 31
							var word_index := neighbor_ordinal >> 5
							var occupied := (int(words[word_base + word_index]) & (1 << bit_index)) != 0
							var source_count := int(counts[source_flat])
							if occupied:
								occupied_neighbor_slots += 1
							else:
								skipped_empty_neighbor_slots += 1
							if (source_count > 0) != occupied:
								return {"valid": false, "reason": "occupancy_bit_mismatch",
									"receiver_flat": receiver_flat, "source_flat": source_flat,
									"neighbor_ordinal": neighbor_ordinal,
									"source_count": source_count, "mask_occupied": occupied}
							for slot in source_count:
								var probe := int(indices[ranges[source_flat * 2] + slot] \
										if adaptive else indices[source_flat * 8 + slot])
								if probe < 0:
									break
								original_receiver_visits.append(probe)
								if occupied:
									masked_receiver_visits.append(probe)
				if original_receiver_visits != masked_receiver_visits:
					return {"valid": false, "reason": "ordered_probe_sequence_mismatch",
						"receiver_flat": receiver_flat,
						"original_probe_count": original_receiver_visits.size(),
						"masked_probe_count": masked_receiver_visits.size()}
				receiver_cells_checked += 1
				original_probe_visit_count += original_receiver_visits.size()
				masked_probe_visit_count += masked_receiver_visits.size()
	return {"valid": true,
		"reason": "",
		"receiver_cells_checked": receiver_cells_checked,
		"in_bounds_neighbor_slots_checked": in_bounds_neighbor_slots,
		"occupied_neighbor_cell_visits": occupied_neighbor_slots,
		"empty_neighbor_cell_visits_skipped": skipped_empty_neighbor_slots,
		"original_probe_visits": original_probe_visit_count,
		"masked_probe_visits": masked_probe_visit_count,
		"ordered_probe_sequence_equal": true}


func build_probe_neighbor_cell_list_payload(data: Resource, dimensions: Vector3i) -> Dictionary:
	var disabled := {"enabled": false, "reason": "disabled",
		"words": PackedInt32Array([0]), "candidate_cell_records": 0, "bytes": 0}
	if not probe_neighbor_cell_list_optimization_enabled:
		return disabled
	if not _probe_neighbor_cell_list_boundary_fixture_valid():
		disabled["reason"] = "boundary_fixture_failed"
		return disabled
	var source := _probe_neighbor_mask_source_counts(data, dimensions)
	if not bool(source.get("valid", false)):
		disabled["reason"] = str(source.get("reason", "invalid_source"))
		return disabled
	var counts: PackedInt32Array = source["counts"]
	var cells := dimensions.x * dimensions.y * dimensions.z
	var record_count := 0
	for receiver_flat in cells:
		var x := receiver_flat % dimensions.x
		var y := floori(float(receiver_flat) / float(dimensions.x)) % dimensions.y
		var z := floori(float(receiver_flat) / float(dimensions.x * dimensions.y))
		for dz in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
			var source_z := z + dz
			if source_z < 0 or source_z >= dimensions.z:
				continue
			for dy in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
				var source_y := y + dy
				if source_y < 0 or source_y >= dimensions.y:
					continue
				for dx in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
					var source_x := x + dx
					if source_x < 0 or source_x >= dimensions.x:
						continue
					var source_flat := source_x + source_y * dimensions.x \
							+ source_z * dimensions.x * dimensions.y
					if counts[source_flat] > 0:
						record_count += 1
	var total_words := cells + 1 + record_count
	if total_words * 4 > PROBE_NEIGHBOR_CELL_LIST_MAX_BYTES:
		disabled["reason"] = "candidate_list_exceeds_32_mib_budget"
		return disabled
	var words := PackedInt32Array()
	words.resize(total_words)
	var cursor := 0
	for receiver_flat in cells:
		var x := receiver_flat % dimensions.x
		var y := floori(float(receiver_flat) / float(dimensions.x)) % dimensions.y
		var z := floori(float(receiver_flat) / float(dimensions.x * dimensions.y))
		words[receiver_flat] = cursor
		for dz in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
			var source_z := z + dz
			if source_z < 0 or source_z >= dimensions.z:
				continue
			for dy in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
				var source_y := y + dy
				if source_y < 0 or source_y >= dimensions.y:
					continue
				for dx in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
					var source_x := x + dx
					if source_x < 0 or source_x >= dimensions.x:
						continue
					var source_flat := source_x + source_y * dimensions.x \
							+ source_z * dimensions.x * dimensions.y
					if counts[source_flat] <= 0:
						continue
					words[cells + 1 + cursor] = source_flat
					cursor += 1
		words[receiver_flat + 1] = cursor
	var payload := {"enabled": true, "reason": "", "words": words,
		"candidate_cell_records": record_count, "bytes": words.size() * 4}
	var verification := validate_probe_neighbor_cell_list_payload(data, dimensions, payload)
	payload["validated_exactly"] = bool(verification.get("valid", false))
	payload["validation"] = verification
	if not bool(payload["validated_exactly"]):
		payload["enabled"] = false
		payload["reason"] = str(verification.get("reason", "ordered_candidate_validation_failed"))
	return payload


func validate_probe_neighbor_cell_list_payload(data: Resource, dimensions: Vector3i,
		payload: Dictionary = {}) -> Dictionary:
	var source := _probe_neighbor_mask_source_counts(data, dimensions)
	if not bool(source.get("valid", false)):
		return {"valid": false, "reason": str(source.get("reason", "invalid_source"))}
	if not bool(payload.get("enabled", false)):
		return {"valid": false, "reason": str(payload.get("reason", "payload_disabled"))}
	var counts: PackedInt32Array = source["counts"]
	var indices: PackedInt32Array = source["indices"]
	var ranges: PackedInt32Array = source["ranges"]
	var adaptive := bool(source["adaptive"])
	var words_value: Variant = payload.get("words")
	if not words_value is PackedInt32Array:
		return {"valid": false, "reason": "candidate_words_missing"}
	var words: PackedInt32Array = words_value
	var cells := dimensions.x * dimensions.y * dimensions.z
	if words.size() < cells + 1 or int(words[cells]) < 0 \
			or cells + 1 + int(words[cells]) != words.size():
		return {"valid": false, "reason": "candidate_word_count_mismatch"}
	var receiver_cells_checked := 0
	var candidate_cell_records_checked := 0
	var source_probe_slots_checked := 0
	for receiver_flat in cells:
		var start := int(words[receiver_flat])
		var end := int(words[receiver_flat + 1])
		if start < 0 or end < start or end > int(words[cells]):
			return {"valid": false, "reason": "candidate_offsets_invalid",
				"receiver_flat": receiver_flat, "start": start, "end": end}
		var cursor := start
		var original_probe_sequence := PackedInt32Array()
		var x := receiver_flat % dimensions.x
		var y := floori(float(receiver_flat) / float(dimensions.x)) % dimensions.y
		var z := floori(float(receiver_flat) / float(dimensions.x * dimensions.y))
		for dz in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
			var source_z := z + dz
			if source_z < 0 or source_z >= dimensions.z:
				continue
			for dy in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
				var source_y := y + dy
				if source_y < 0 or source_y >= dimensions.y:
					continue
				for dx in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
					var source_x := x + dx
					if source_x < 0 or source_x >= dimensions.x:
						continue
					var source_flat := source_x + source_y * dimensions.x \
							+ source_z * dimensions.x * dimensions.y
					var source_count := int(counts[source_flat])
					if source_count <= 0:
						continue
					if cursor >= end or int(words[cells + 1 + cursor]) != source_flat:
						return {"valid": false, "reason": "ordered_candidate_cell_mismatch",
							"receiver_flat": receiver_flat, "source_flat": source_flat,
							"candidate_index": cursor - start}
					var index_start := int(ranges[source_flat * 2]) if adaptive else source_flat * 8
					for slot in source_count:
						var probe := int(indices[index_start + slot])
						if probe < 0:
							return {"valid": false, "reason": "negative_probe_in_candidate_cell",
								"receiver_flat": receiver_flat, "source_flat": source_flat,
								"slot": slot}
						original_probe_sequence.append(probe)
						source_probe_slots_checked += 1
					cursor += 1
					candidate_cell_records_checked += 1
		if cursor != end:
			return {"valid": false, "reason": "unexpected_candidate_cell",
				"receiver_flat": receiver_flat, "expected_end": cursor, "actual_end": end}
		var listed_probe_sequence := PackedInt32Array()
		for candidate_index in range(start, end):
			var source_flat := int(words[cells + 1 + candidate_index])
			var source_count := int(counts[source_flat])
			var index_start := int(ranges[source_flat * 2]) if adaptive else source_flat * 8
			for slot in source_count:
				listed_probe_sequence.append(int(indices[index_start + slot]))
		if listed_probe_sequence != original_probe_sequence:
			return {"valid": false, "reason": "ordered_probe_sequence_mismatch",
				"receiver_flat": receiver_flat,
				"original_probe_count": original_probe_sequence.size(),
				"candidate_probe_count": listed_probe_sequence.size()}
		receiver_cells_checked += 1
	return {"valid": true, "reason": "", "receiver_cells_checked": receiver_cells_checked,
		"candidate_cell_records_checked": candidate_cell_records_checked,
		"source_probe_slots_checked": source_probe_slots_checked,
		"ordered_source_cells_equal": true, "ordered_probe_sequence_equal": true}


static func _probe_neighbor_cell_list_boundary_fixture_valid() -> bool:
	# A 2x2x2 grid exercises both clipped ends of every axis. For a receiver
	# at (0,0,0), occupied cells must retain dz/dy/dx order from the old loops.
	var dimensions := Vector3i(2, 2, 2)
	var occupied := PackedInt32Array([1, 0, 1, 1, 0, 1, 0, 1])
	var actual := PackedInt32Array()
	for dz in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
		var z := dz
		if z < 0 or z >= dimensions.z:
			continue
		for dy in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
			var y := dy
			if y < 0 or y >= dimensions.y:
				continue
			for dx in range(-PROBE_NEIGHBOR_MASK_RADIUS, PROBE_NEIGHBOR_MASK_RADIUS + 1):
				var x := dx
				if x < 0 or x >= dimensions.x:
					continue
				var flat := x + y * dimensions.x + z * dimensions.x * dimensions.y
				if occupied[flat] > 0:
					actual.append(flat)
	return actual == PackedInt32Array([0, 2, 3, 5, 7])


func _record_probe_cluster_binding(cache_key: String) -> void:
	var frame := Engine.get_frames_drawn()
	if frame != _probe_cluster_debug_frame:
		_probe_cluster_debug_frame = frame
		_probe_cluster_debug_bound_keys.clear()
	_probe_cluster_debug_bound_keys[cache_key] = true

## Saved pre-PRT-v2 resources carry only four inputs and no independent output.
## FengRenderer calls this on the main thread after deserialization so old authored
## passes are upgraded without changing their enabled state or strength settings.
func ensure_frp_contract() -> bool:
	var expected_inputs := _make_inputs()
	var expected_outputs := _make_outputs()
	var changed := false
	if not _inputs_match(inputs, expected_inputs):
		inputs = expected_inputs
		changed = true
	if not _outputs_match(outputs, expected_outputs):
		outputs = expected_outputs
		changed = true
	return changed

func _make_inputs() -> Array[TextureInput]:
	var color := TextureInput.new()
	color.binding = 0
	color.source = TextureInput.Source.COLOR
	color.binding_type = TextureInput.BindingType.STORAGE_IMAGE
	var depth := TextureInput.new()
	depth.binding = 1
	depth.source = TextureInput.Source.DEPTH
	var normal := TextureInput.new()
	normal.binding = 2
	normal.source = TextureInput.Source.NORMAL_ROUGHNESS
	var albedo := TextureInput.new()
	albedo.binding = 3
	albedo.source = TextureInput.Source.ALBEDO
	var orm := TextureInput.new()
	orm.binding = 4
	orm.source = TextureInput.Source.ORM
	var contribution := TextureInput.new()
	contribution.binding = 5
	contribution.source = TextureInput.Source.CUSTOM
	contribution.custom_scope = NativeSpec.SCOPE_PIPELINE
	contribution.custom_name = MAGIC_GI_OUTPUT
	contribution.binding_type = TextureInput.BindingType.STORAGE_IMAGE
	var motion := TextureInput.new()
	motion.binding = 6
	motion.source = TextureInput.Source.MOTION_VECTORS
	return [color, depth, normal, albedo, orm, contribution, motion]

func _make_outputs() -> Array[OutputDeclaration]:
	var output := OutputDeclaration.new()
	output.name = MAGIC_GI_OUTPUT
	output.data_format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	output.usage = OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE \
		| OutputDeclaration.Usage.COPY_TO | OutputDeclaration.Usage.COPY_FROM
	var half_incident := _make_screen_cache_output(MAGIC_GI_CLV_SCREEN_HALF_INCIDENT,
		Vector2(0.125, 0.125))
	var half_guide := _make_screen_cache_output(MAGIC_GI_CLV_SCREEN_HALF_GUIDE,
		Vector2(0.125, 0.125))
	var edge_incident := _make_screen_cache_output(MAGIC_GI_CLV_SCREEN_EDGE_INCIDENT,
		Vector2.ONE)
	var dynamic_half_incident := _make_screen_cache_output(
		MAGIC_GI_DYNAMIC_SCREEN_HALF_INCIDENT, Vector2(0.5, 0.5))
	var dynamic_half_guide := _make_screen_cache_output(
		MAGIC_GI_DYNAMIC_SCREEN_HALF_GUIDE, Vector2(0.5, 0.5))
	var dynamic_edge_incident := _make_screen_cache_output(
		MAGIC_GI_DYNAMIC_SCREEN_EDGE_INCIDENT, Vector2.ONE)
	return [output, half_incident, half_guide, edge_incident,
		dynamic_half_incident, dynamic_half_guide, dynamic_edge_incident]

func _make_screen_cache_output(output_name: StringName, output_scale: Vector2) -> OutputDeclaration:
	var output := OutputDeclaration.new()
	output.name = output_name
	# Dynamic irradiance is HDR and may exceed binary16 in bright scenes. Keep the
	# cache lossless here; the screen path is transient and not part of bake files.
	output.data_format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	output.usage = OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE
	output.scale = output_scale
	return output

func _render_surfel(buffers: RenderSceneBuffersRD, view: int, device: RenderingDevice) -> void:
	var output: RID = inputs[5].get_texture(buffers, view) if inputs.size() > 5 else RID()
	if not output.is_valid():
		_warn_surfel_once("output", "Surfel GI could not acquire its output attachment.")
		return
	var sky_diffuse: RID = _sky_diffuse_input.get_texture(buffers, view)
	var diffuse_replacement_requested: bool = _surfel_request_prepared and _surfel_replacement_requested
	_frame_replacement_enabled = diffuse_replacement_requested and sky_diffuse.is_valid()
	if diffuse_replacement_requested and not sky_diffuse.is_valid():
		_warn_missing_replacement_bridge()
	var geometry := _frame_rtgi_snapshot.duplicate(false)
	var geometry_instances: Variant = geometry.get("instances", [])
	var volume_world_id := int(_frame_snapshot.get("world_id", 0))
	var geometry_ready: bool = bool(geometry.get("valid", false)) \
			and int(geometry.get("world_id", 0)) == volume_world_id \
			and geometry_instances is Array and not geometry_instances.is_empty()
	if not geometry_ready:
		# The RTGI scene snapshot is published asynchronously. During its initial
		# warmup there is no Surfel contribution yet; keep the output neutral and
		# leave native Sky diffuse in charge without reporting a missing bridge.
		_surfel_nrd_frame_fallback_reason = "Waiting for the RT geometry snapshot"
		device.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_release_surfel_nrd_if_active()
		return
	if _frame_surfel_inputs.size() <= view:
		_surfel_nrd_frame_fallback_reason = "FRP frame inputs are unavailable"
		device.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_release_surfel_nrd_if_active()
		_warn_surfel_once("frame-input", "Surfel GI frame inputs are unavailable for this view.")
		return
	var frame: Dictionary = _frame_surfel_inputs[view]
	var color: RID = inputs[0].get_texture(buffers, view)
	var depth: RID = inputs[1].get_texture(buffers, view)
	var normal: RID = inputs[2].get_texture(buffers, view)
	var albedo: RID = inputs[3].get_texture(buffers, view)
	var orm: RID = inputs[4].get_texture(buffers, view)
	var snapshot := geometry.duplicate(false)
	snapshot.merge(_frame_snapshot, true)
	snapshot["valid"] = geometry_ready
	if not bool(frame.get("valid", false)) or int(frame.get("abi_version", 0)) != 1:
		_surfel_nrd_frame_fallback_reason = "FRP frame-input contract is invalid"
		device.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_release_surfel_nrd_if_active()
		_warn_surfel_once("frame-contract", "Surfel GI received an invalid FRP frame-input packet.")
		return
	var frame_token := int(frame.get("frame_generation", Engine.get_frames_drawn()))
	var textures: Array[RID] = [depth, normal, albedo, orm]
	var pass_strength := float(_frame_parameters.x) if _frame_parameters is Vector4 else float(parameters.x)
	var full_size := buffers.get_internal_size()
	var settings_value: Variant = snapshot.get("surfel_settings", {})
	var settings: Dictionary = settings_value if settings_value is Dictionary else {}
	var nrd_requested := int(settings.get("denoiser", 0)) == 0
	var motion: RID = inputs[6].get_texture(buffers, view) if inputs.size() > 6 else RID()
	var nrd_target: Dictionary = {}
	var nrd_revision_before := int(_surfel_nrd.call("get_resource_revision")) \
			if _surfel_nrd != null else -1
	if nrd_requested and not motion.is_valid():
		_surfel_nrd_frame_fallback_reason = "FRP motion-vector attachment is unavailable"
		_warn_surfel_once("nrd-motion-input", "Surfel NRD RELAX requires FRP motion vectors; using the World Cache gather path for this frame.")
	elif nrd_requested and _surfel_nrd != null:
		var render_target: RID = buffers.get_render_target()
		var render_target_id := int(frame.get("render_target_id",
			render_target.get_id() if render_target.is_valid() else 0))
		nrd_target = _surfel_nrd.call("prepare_view", device, frame, snapshot,
			full_size, render_target_id, int(frame.get("view_index", view)), motion)
	elif _surfel_nrd != null:
		_release_surfel_nrd_if_active()
	var nrd_active := bool(nrd_target.get("active", false))
	if nrd_requested and not nrd_active:
		var fallback_reason := str(nrd_target.get("reason", ""))
		if fallback_reason.is_empty():
			fallback_reason = _surfel_nrd_frame_fallback_reason
		if fallback_reason.is_empty():
			fallback_reason = str(_surfel_nrd.get("error") \
				if _surfel_nrd != null else "NRD adapter is unavailable")
		_surfel_nrd_frame_fallback_reason = fallback_reason
		_warn_surfel_once("nrd-fallback:" + fallback_reason,
			"Surfel NRD RELAX is unavailable; using the World Cache gather path: %s" % fallback_reason)
	elif not nrd_requested:
		_surfel_nrd_frame_fallback_reason = "World Cache denoiser selected"
	var gpu_revision_before := int(_surfel_gpu.call("get_resource_revision")) \
			if _surfel_gpu != null else -1
	var succeeded: bool = _surfel_gpu != null and bool(_surfel_gpu.call("render", device,
		snapshot, frame, textures, color, output, sky_diffuse, _frame_diffuse_ao_texture,
		full_size, pass_strength, _frame_replacement_enabled, frame_token,
		nrd_target if nrd_active else {}))
	var gpu_revision_synced := gpu_revision_before
	var gpu_revision_after_gather := int(_surfel_gpu.call("get_resource_revision")) \
			if _surfel_gpu != null else gpu_revision_before
	if gpu_revision_after_gather != gpu_revision_before:
		_sync_owned_rid_snapshot()
		gpu_revision_synced = gpu_revision_after_gather
	if succeeded and nrd_active and _surfel_nrd != null:
		succeeded = bool(_surfel_nrd.call("resolve_view", frame, snapshot, full_size,
			textures, motion, color, output, sky_diffuse, _frame_diffuse_ao_texture,
			pass_strength, _frame_replacement_enabled, frame_token, nrd_target))
		if succeeded:
			_surfel_nrd_frame_active = true
		else:
			var nrd_failure := str(_surfel_nrd.get("error"))
			_surfel_nrd_frame_fallback_reason = nrd_failure
			succeeded = bool(_surfel_gpu.call("render", device, snapshot, frame, textures,
				color, output, sky_diffuse, _frame_diffuse_ao_texture, full_size,
				pass_strength, _frame_replacement_enabled, frame_token, {}))
			_warn_surfel_once("nrd-dispatch-fallback:" + nrd_failure,
				"Surfel NRD RELAX dispatch failed; using the World Cache gather path: %s" % nrd_failure)
	elif not succeeded and nrd_active and _surfel_gpu != null:
		var gather_failure := str(_surfel_gpu.get("error"))
		_surfel_nrd_frame_fallback_reason = gather_failure
		_surfel_nrd.call("invalidate_view", nrd_target, gather_failure)
		succeeded = bool(_surfel_gpu.call("render", device, snapshot, frame, textures,
			color, output, sky_diffuse, _frame_diffuse_ao_texture, full_size,
			pass_strength, _frame_replacement_enabled, frame_token, {}))
		if succeeded:
			_warn_surfel_once("nrd-gather-fallback:" + gather_failure,
				"Surfel NRD gather failed; using the World Cache gather path: %s" % gather_failure)
	var gpu_revision_after_render := int(_surfel_gpu.call("get_resource_revision")) \
			if _surfel_gpu != null else gpu_revision_synced
	if gpu_revision_after_render != gpu_revision_synced:
		_sync_owned_rid_snapshot()
	if _surfel_nrd != null and int(_surfel_nrd.call("get_resource_revision")) != nrd_revision_before:
		_sync_owned_rid_snapshot()
	if nrd_requested and not _surfel_nrd_frame_active and _surfel_nrd_frame_fallback_reason.is_empty():
		_surfel_nrd_frame_fallback_reason = "World Cache gather path is active"
	if not succeeded:
		device.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		var reason := str(_surfel_gpu.get("error")) if _surfel_gpu != null else "Surfel helper is unavailable"
		_warn_surfel_once("render:" + reason, "Surfel GI is inactive: %s" % reason)

func get_surfel_debug_info(cache_key := "", readback_counters := false) -> Dictionary:
	var result: Dictionary = _surfel_gpu.call("get_debug_info", cache_key, readback_counters) \
			if _surfel_gpu != null and _surfel_gpu.has_method("get_debug_info") else {"available": false}
	var nrd_info: Dictionary = _surfel_nrd.call("get_debug_info") \
			if _surfel_nrd != null and _surfel_nrd.has_method("get_debug_info") else {"available": false}
	nrd_info["history_available"] = bool(nrd_info.get("active", false))
	nrd_info["active"] = _surfel_nrd_frame_active
	result["nrd"] = nrd_info
	result["denoiser_active"] = _surfel_nrd_frame_active
	if not bool(result["denoiser_active"]):
		result["denoiser_fallback_reason"] = _surfel_nrd_frame_fallback_reason \
				if not _surfel_nrd_frame_fallback_reason.is_empty() \
				else str(nrd_info.get("error", "World Cache gather selected"))
	return result

func _release_surfel_nrd_if_active() -> void:
	if _surfel_nrd == null or not _surfel_nrd.has_method("has_owned_resources") \
			or not bool(_surfel_nrd.call("has_owned_resources")):
		return
	_surfel_nrd.call("release_all")
	_sync_owned_rid_snapshot()

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["parameters"])

func refresh_resource_flags() -> void:
	# These are pass-owned inputs and requirements. Do not change FengPass's
	# raise-only behavior for third-party passes which set flags manually.
	access_resolved_color = true
	access_resolved_depth = true
	needs_normal_roughness = true
	super.refresh_resource_flags()
	needs_motion_vectors = true

func _validate_runtime_inputs(buffers: RenderSceneBuffersRD, view: int) -> bool:
	# The declaration requests velocity generation for NRD. Keep the input optional
	# here so legacy render paths can use the exact World Cache gather if FRP cannot
	# provide it; _render_surfel gates NRD on the actual RID.
	for declaration in inputs:
		if declaration == null:
			_report("Texture declarations cannot be null.")
			return false
		if declaration.source == TextureInput.Source.MOTION_VECTORS:
			continue
		if not declaration.get_texture(buffers, view).is_valid():
			_report("Texture is unavailable for binding %d." % declaration.binding)
			return false
	return true

func _magicdawn_texture_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform

func _magicdawn_sampler_uniform(binding: int, sampler: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
	uniform.binding = binding
	uniform.add_id(sampler)
	return uniform

func _ensure_magicdawn_clv_debug_resources(rd: RenderingDevice) -> bool:
	if not _magicdawn_clv_debug_shader.is_valid():
		var spirv := MAGIC_GI_CLV_DEBUG_SHADER.get_spirv()
		if spirv == null or not spirv.compile_error_compute.is_empty() \
				or spirv.bytecode_compute.is_empty():
			_magicdawn_clv_debug_status = "shader_compile_failed"
			return false
		_magicdawn_clv_debug_shader = rd.shader_create_from_spirv(spirv,
				"Magic GI Layout-9 CLV Debug Mirror")
		if not _magicdawn_clv_debug_shader.is_valid():
			_magicdawn_clv_debug_status = "shader_create_failed"
			return false
	if not _magicdawn_clv_debug_pipeline.is_valid():
		_magicdawn_clv_debug_pipeline = rd.compute_pipeline_create(
				_magicdawn_clv_debug_shader)
		if not _magicdawn_clv_debug_pipeline.is_valid():
			_magicdawn_clv_debug_status = "pipeline_create_failed"
			return false
	if not _magicdawn_clv_debug_nearest_sampler.is_valid():
		var nearest := RDSamplerState.new()
		nearest.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		nearest.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		nearest.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		nearest.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		nearest.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		nearest.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_magicdawn_clv_debug_nearest_sampler = rd.sampler_create(nearest)
	if not _magicdawn_clv_debug_linear_sampler.is_valid():
		var linear := RDSamplerState.new()
		linear.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		linear.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		linear.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		linear.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		linear.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		linear.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_magicdawn_clv_debug_linear_sampler = rd.sampler_create(linear)
	if not _magicdawn_clv_debug_nearest_sampler.is_valid() \
			or not _magicdawn_clv_debug_linear_sampler.is_valid():
		_magicdawn_clv_debug_status = "sampler_create_failed"
		return false
	_sync_owned_rid_snapshot()
	return true

func _magicdawn_dynamic_debug_cache(buffers: RenderSceneBuffersRD, view: int) -> Dictionary:
	if buffers == null or view < 0 or view >= buffers.get_view_count():
		return {}
	var state: Dictionary = _native_prepared_views.get(_native_view_key(buffers, view), {})
	if state.is_empty() or int(state.get("frame", -1)) != Engine.get_frames_drawn() \
			or str(state.get("cache_key", "")) != str(_frame_snapshot.get("cache_key", "")) \
			or int(state.get("version", -1)) != int(_frame_snapshot.get("version", -1)):
		return {}
	var cache: RefCounted = state.get("clipmap")
	if cache == null or not cache.texture.is_valid() or not cache.tags.is_valid() \
			or not cache.support.is_valid() or not cache.parameters.is_valid():
		return {}
	if rd_texture_invalid(cache.texture) or rd_texture_invalid(cache.tags) \
			or rd_texture_invalid(cache.support):
		return {}
	var cache_state: Dictionary = cache.get_runtime_state() \
			if cache.has_method("get_runtime_state") else {}
	if cache_state.is_empty() or int(cache_state.get("layout_version", -1)) != 9 \
			or not bool(cache_state.get("transfer_matrix_valid", false)) \
			or int(cache_state.get("relight_serial", 0)) <= 0 \
			or int(cache_state.get("relight_lighting_revision", -1)) \
				< int(state.get("lighting_revision", -1)) \
			or bool(cache_state.get("relight_pending", true)):
		return {}
	state["cache_state"] = cache_state
	return state

func rd_texture_invalid(texture: RID) -> bool:
	var rd := RenderingServer.get_rendering_device()
	return rd == null or not texture.is_valid() or not rd.texture_is_valid(texture)

func _render_magicdawn_dynamic_clv_debug(buffers: RenderSceneBuffersRD,
		view: int, rd: RenderingDevice) -> void:
	var output: RID = inputs[5].get_texture(buffers, view) if inputs.size() > 5 else RID()
	if not output.is_valid():
		_magicdawn_clv_debug_status = "sidecar_output_unavailable"
		return
	if not _magicdawn_debug_sidecar_requested(buffers):
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_clv_debug_status = "idle_debug_buffers_not_requesting_magic_gi"
		return
	if not _frame_magicdawn_clv_renderer_active:
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_clv_debug_status = "native_layout9_consumer_inactive_fail_closed"
		_magicdawn_runtime_state["clv_debug_view_status"] = _magicdawn_clv_debug_status
		return
	var prepared := _magicdawn_dynamic_debug_cache(buffers, view)
	if prepared.is_empty():
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_clv_debug_status = "current_relit_layout9_cache_unavailable_fail_closed"
		_magicdawn_runtime_state["clv_debug_view_status"] = _magicdawn_clv_debug_status
		return
	var owner_parameters_value: Variant = prepared.get("owner_parameters_rid", RID())
	if not owner_parameters_value is RID:
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_clv_debug_status = "current_owner_parameters_unavailable_fail_closed"
		_magicdawn_runtime_state["clv_debug_view_status"] = _magicdawn_clv_debug_status
		return
	var owner_parameters: RID = owner_parameters_value
	if not _ubo.is_valid() \
			or not owner_parameters.is_valid() \
			or not _native_gi_parameters_ubo.is_valid():
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_clv_debug_status = "native_parameter_buffer_unavailable_fail_closed"
		_magicdawn_runtime_state["clv_debug_view_status"] = _magicdawn_clv_debug_status
		return
	if not _ensure_magicdawn_clv_debug_resources(rd):
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_runtime_state["clv_debug_view_status"] = _magicdawn_clv_debug_status
		return
	var depth: RID = inputs[1].get_texture(buffers, view)
	var normal: RID = inputs[2].get_texture(buffers, view)
	var albedo: RID = inputs[3].get_texture(buffers, view)
	var orm: RID = inputs[4].get_texture(buffers, view)
	var diffuse_ao: RID = _frame_diffuse_ao_texture
	if not diffuse_ao.is_valid() or not rd.texture_is_valid(diffuse_ao):
		diffuse_ao = _ensure_white_diffuse_ao(rd)
	var cache: RefCounted = prepared.get("clipmap")
	if not depth.is_valid() or not normal.is_valid() or not albedo.is_valid() \
			or not orm.is_valid() or not diffuse_ao.is_valid() \
			or rd.texture_is_valid(depth) == false \
			or rd.texture_is_valid(normal) == false \
			or rd.texture_is_valid(albedo) == false \
			or rd.texture_is_valid(orm) == false:
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_clv_debug_status = "gbuffer_input_unavailable_fail_closed"
		_magicdawn_runtime_state["clv_debug_view_status"] = _magicdawn_clv_debug_status
		return
	var set0 := UniformSetCacheRD.get_cache(_magicdawn_clv_debug_shader, 0, [
		U.sampled(1, _magicdawn_clv_debug_nearest_sampler, depth),
		U.sampled(2, _magicdawn_clv_debug_nearest_sampler, normal),
		U.sampled(3, _magicdawn_clv_debug_nearest_sampler, albedo),
		U.sampled(4, _magicdawn_clv_debug_nearest_sampler, orm),
		U.image(5, output), U.uniform_buffer(9, _ubo),
		U.sampled(16, _magicdawn_clv_debug_linear_sampler, diffuse_ao)])
	var set1 := UniformSetCacheRD.get_cache(_magicdawn_clv_debug_shader, 1, [
		_magicdawn_texture_uniform(50, cache.texture),
		_magicdawn_texture_uniform(51, cache.tags),
		_magicdawn_texture_uniform(52, cache.support),
		U.uniform_buffer(53, cache.parameters),
		U.uniform_buffer(58, owner_parameters),
		U.uniform_buffer(60, _native_gi_parameters_ubo),
		_magicdawn_sampler_uniform(61, _magicdawn_clv_debug_nearest_sampler),
		_magicdawn_sampler_uniform(62, _magicdawn_clv_debug_linear_sampler)])
	if not set0.is_valid() or not set1.is_valid():
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_clv_debug_status = "uniform_set_create_failed"
		_magicdawn_runtime_state["clv_debug_view_status"] = _magicdawn_clv_debug_status
		return
	var size: Vector2i = buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_clv_debug_status = "empty_render_size"
		_magicdawn_runtime_state["clv_debug_view_status"] = _magicdawn_clv_debug_status
		return
	if _magicdawn_active_readback_armed \
			and clv_debug_view in [CLVDebugView.RECONSTRUCTED_LIGHTING,
				CLVDebugView.REJECTION_REASONS]:
		# Keep this exact view/cache alive until the runner queues async readback after
		# frame_post_draw. Synchronous RD readback from this callback is unsafe on D3D12.
		_magicdawn_active_readback_context = {
			"prepared": prepared, "cache": cache, "view": view,
			"callback_frame": Engine.get_frames_drawn()}
	var push := PackedByteArray()
	push.append_array(PackedInt32Array([size.x, size.y, clv_debug_view]).to_byte_array())
	push.append_array(PackedFloat32Array([maxf(_pre_exposure, 0.0)]).to_byte_array())
	_capture_gpu_timestamp(rd, "CLV Debug Mirror Begin")
	rd.draw_command_begin_label("Magic GI Layout-9 CLV Debug Mirror", Color(0.3, 0.8, 0.5))
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _magicdawn_clv_debug_pipeline)
	rd.compute_list_bind_uniform_set(list, set0, 0)
	rd.compute_list_bind_uniform_set(list, set1, 1)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(float(size.x) / 8.0), ceili(float(size.y) / 8.0), 1)
	rd.compute_list_end()
	rd.draw_command_end_label()
	_capture_gpu_timestamp(rd, "CLV Debug Mirror End")
	_magicdawn_clv_debug_status = "dispatched"
	_magicdawn_runtime_state["clv_debug_view_status"] = "layout9_%s_mirror_dispatched" % \
			("contribution" if clv_debug_view == CLVDebugView.OFF else "diagnostic")
	_magicdawn_runtime_state["clv_debug_mirror_frame"] = Engine.get_frames_drawn()
	_magicdawn_runtime_state["clv_debug_mirror_view"] = view
	_magicdawn_runtime_state["clv_debug_mirror_sample_contract"] = \
			"native_certified_then_native_approx; no_probe_or_legacy_fallback"

func _render_preinterpolated_clv_debug(buffers: RenderSceneBuffersRD,
		view: int, rd: RenderingDevice) -> void:
	var output: RID = inputs[5].get_texture(buffers, view)
	if not output.is_valid(): return
	rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
	if not _magicdawn_debug_sidecar_requested(buffers):
		_magicdawn_clv_debug_status = "idle_debug_buffers_not_requesting_magic_gi"
		return
	if not bool(_dynamic_volume_runtime_state.get("renderer_current", false)) \
			or view >= _magicdawn_native_owner_ubos.size():
		_magicdawn_clv_debug_status = "dynamic_clv_consumer_not_current"
		return
	if _dynamic_volume_debug == null:
		_dynamic_volume_debug = preload("magic_gi_dynamic_volume_debug.gd").new()
	var ao: RID = _frame_diffuse_ao_texture
	if not ao.is_valid() or not rd.texture_is_valid(ao):
		ao = _ensure_white_diffuse_ao(rd)
	_magicdawn_clv_debug_status = _dynamic_volume_debug.draw(rd, _dynamic_volume_cache,
		_magicdawn_native_owner_ubos[view],
		_build_dynamic_volume_screen_frame_bytes(_frame_scene_data, buffers.get_internal_size(), view),
		inputs[1].get_texture(buffers, view), inputs[2].get_texture(buffers, view),
		inputs[3].get_texture(buffers, view), inputs[4].get_texture(buffers, view),
		ao, output, buffers.get_internal_size(), clv_debug_view, _pre_exposure)
	_magicdawn_runtime_state["clv_debug_view_status"] = _magicdawn_clv_debug_status
	_magicdawn_runtime_state["clv_debug_mirror_frame"] = Engine.get_frames_drawn()
	_sync_owned_rid_snapshot()

func _magicdawn_read_active_clv_cache(context: Dictionary,
		readbacks: Dictionary) -> Dictionary:
	var prepared: Dictionary = context.get("prepared", {})
	var cache: RefCounted = context.get("cache")
	var view := int(context.get("view", -1))
	var result := {"valid": false, "view": view,
		"frame": int(prepared.get("frame", -1)),
		"cache_key": str(prepared.get("cache_key", "")),
		"callback_frame": int(context.get("callback_frame", -1)),
		"request_frame": int(context.get("request_frame", -1)),
		"request_errors": context.get("errors", {}),
		"timing_note": "One-shot asynchronous diagnostic only; excluded from normal rendering and performance samples."}
	if cache == null:
		result["error"] = "active_cache_unavailable"
		return result
	var resolution := int(cache.get("resolution"))
	if resolution not in [16, 24]:
		result["error"] = "active_cache_resolution_unsupported"
		return result
	var cache_state: Dictionary = cache.get_runtime_state() \
			if cache.has_method("get_runtime_state") else {}
	var params_bytes: PackedByteArray = readbacks.get("params", PackedByteArray())
	var parameters := {"valid": params_bytes.size() == 80,
		"spacing_m": -1.0, "approximate_enabled": -1.0,
		"exact_corner_visibility_enabled": -1.0, "approximate_ready_bit_enabled": -1.0,
		"resolution": -1, "levels": -1, "epoch": -1, "layout": -1}
	if params_bytes.size() == 80:
		parameters["spacing_m"] = params_bytes.decode_float(48)
		parameters["approximate_enabled"] = params_bytes.decode_float(52)
		parameters["exact_corner_visibility_enabled"] = params_bytes.decode_float(56)
		parameters["approximate_ready_bit_enabled"] = params_bytes.decode_float(60)
		parameters["resolution"] = params_bytes.decode_s32(64)
		parameters["levels"] = params_bytes.decode_s32(68)
		parameters["epoch"] = params_bytes.decode_s32(72)
		parameters["layout"] = params_bytes.decode_s32(76)
	result["cache_state"] = cache_state
	result["parameters"] = parameters

	var ubo_bytes: PackedByteArray = readbacks.get("ubo", PackedByteArray())
	var lighting_value: Variant = context.get("snapshot_lighting", PackedFloat32Array())
	var sky_value: Variant = context.get("snapshot_sky", PackedFloat32Array())
	var lighting := PackedFloat32Array()
	var sky := PackedFloat32Array()
	if lighting_value is PackedFloat32Array:
		lighting = lighting_value
	if sky_value is PackedFloat32Array:
		sky = sky_value
	result["live_sh"] = {
		"ubo_bytes": ubo_bytes.size(),
		"snapshot_lighting": _magicdawn_readback_packed_metrics(lighting),
		"ubo_lighting": _magicdawn_readback_float_metrics(ubo_bytes, 224, 27),
		"lighting_max_abs_delta": _magicdawn_readback_max_delta(ubo_bytes, 224, lighting),
		"snapshot_sky": _magicdawn_readback_packed_metrics(sky),
		"ubo_sky": _magicdawn_readback_float_metrics(ubo_bytes, 336, 27),
		"sky_max_abs_delta": _magicdawn_readback_max_delta(ubo_bytes, 336, sky)}

	var bake: Dictionary = _bake_resources.get(str(prepared.get("cache_key", "")), {})
	var directional_value: Variant = bake.get("directional")
	var input_bindings: Dictionary = context.get("input_bindings", {})
	if directional_value is RefCounted and directional_value.has_method("get_clv_transfer_bindings"):
		var bindings_value: Variant = directional_value.call("get_clv_transfer_bindings")
		if bindings_value is Dictionary:
			input_bindings = bindings_value
	var probes := int(input_bindings.get("probes", 0))
	var emitters := int(input_bindings.get("emitters", 0))
	result["transfer_inputs"] = {
		"lighting_revision": int(input_bindings.get("lighting_revision", -1)),
		"sources_ready": bool(input_bindings.get("sources_ready", false)),
		"probes": probes, "emitters": emitters,
		"transfer": _magicdawn_readback_buffer_metrics(readbacks.get("input_transfer", PackedByteArray()),
			mini(probes * 243 * 4, 4096)),
		"sky": _magicdawn_readback_buffer_metrics(readbacks.get("input_sky", PackedByteArray()),
			mini(probes * 81 * 4, 4096)),
		"emission": _magicdawn_readback_buffer_metrics(readbacks.get("input_emission", PackedByteArray()),
			mini(probes * emitters * 54 * 4, 4096)),
		"sources": _magicdawn_readback_buffer_metrics(readbacks.get("input_sources", PackedByteArray()),
			mini(emitters * 6 * 4, 4096))}
	result["readback_sizes"] = {"params": [params_bytes.size(), 80],
		"ubo": [ubo_bytes.size(), UBO_SIZE],
		"input_transfer": [readbacks.get("input_transfer", PackedByteArray()).size(),
			mini(probes * 243 * 4, 4096)],
		"input_sky": [readbacks.get("input_sky", PackedByteArray()).size(),
			mini(probes * 81 * 4, 4096)]}
	result["next_layer"] = "aggregate_transfer_matrix_and_relit_layout9_texture_not_read_in_small_buffer_tier"
	result["valid"] = params_bytes.size() == 80 and ubo_bytes.size() == UBO_SIZE
	return result

func _magicdawn_readback_float_metrics(bytes: PackedByteArray, offset: int,
		count: int) -> Dictionary:
	if offset < 0 or count < 0 or offset + count * 4 > bytes.size():
		return {"valid": false, "float_count": count}
	var nonzero := 0
	var nonfinite := 0
	var maximum := 0.0
	var sum_abs := 0.0
	for index in count:
		var value := bytes.decode_float(offset + index * 4)
		if not is_finite(value):
			nonfinite += 1
			continue
		var absolute := absf(value)
		if absolute > 1e-20:
			nonzero += 1
		maximum = maxf(maximum, absolute)
		sum_abs += absolute
	return {"valid": true, "float_count": count, "nonzero": nonzero,
		"nonfinite": nonfinite, "max_abs": maximum, "sum_abs": sum_abs}

func _magicdawn_readback_packed_metrics(values: PackedFloat32Array) -> Dictionary:
	var nonzero := 0
	var nonfinite := 0
	var maximum := 0.0
	var sum_abs := 0.0
	for value in values:
		if not is_finite(value):
			nonfinite += 1
			continue
		var absolute := absf(value)
		if absolute > 1e-20:
			nonzero += 1
		maximum = maxf(maximum, absolute)
		sum_abs += absolute
	return {"count": values.size(), "nonzero": nonzero,
		"nonfinite": nonfinite, "max_abs": maximum, "sum_abs": sum_abs}

func _magicdawn_readback_max_delta(bytes: PackedByteArray, offset: int,
		values: PackedFloat32Array) -> float:
	if values.size() != 27 or bytes.size() < offset + 27 * 4:
		return INF
	var maximum := 0.0
	for index in 27:
		maximum = maxf(maximum, absf(bytes.decode_float(offset + index * 4) - values[index]))
	return maximum

func _magicdawn_readback_buffer_metrics(bytes: PackedByteArray, byte_count: int) -> Dictionary:
	var request_size := mini(byte_count, 4096)
	return {"valid": request_size > 0 and bytes.size() == request_size, "bytes": bytes.size(),
		"summary": _magicdawn_readback_float_metrics(bytes, 0, bytes.size() / 4)}

func _magicdawn_readback_transfer_face(bytes: PackedByteArray, width: int,
		resolution: int, slot: Vector3i, axis: int, emitters: int) -> Dictionary:
	var level := floori(float(slot.z) / float(resolution))
	var local_z := slot.z % resolution
	var texture_z := (level * 3 + axis) * resolution + local_z
	var summary := {"directional": {"nonzero": 0, "max_abs": 0.0, "sum_abs": 0.0},
		"sky": {"nonzero": 0, "max_abs": 0.0, "sum_abs": 0.0},
		"emission": {"nonzero": 0, "max_abs": 0.0, "sum_abs": 0.0}}
	for scalar_index in 324 + maxi(0, emitters) * 54:
		var column := scalar_index >> 2
		var component := scalar_index & 3
		var x := column * resolution + slot.x
		var offset := ((texture_z * resolution + slot.y) * width + x) * 16 + component * 4
		if offset < 0 or offset + 4 > bytes.size():
			continue
		var value := bytes.decode_float(offset)
		if not is_finite(value):
			continue
		var category := "directional" if scalar_index < 243 else \
				("sky" if scalar_index < 324 else "emission")
		var stats: Dictionary = summary[category]
		var absolute := absf(value)
		if absolute > 1e-20:
			stats["nonzero"] = int(stats["nonzero"]) + 1
		stats["max_abs"] = maxf(float(stats["max_abs"]), absolute)
		stats["sum_abs"] = float(stats["sum_abs"]) + absolute
	return summary

func _magicdawn_readback_relight_face(bytes: PackedByteArray, width: int,
		resolution: int, slot: Vector3i, axis: int) -> Dictionary:
	var coefficients := {"nonzero_rgb": 0, "max_abs_rgb": 0.0, "sum_abs_rgb": 0.0}
	for column in 18:
		var value := _magicdawn_readback_vec4f(bytes, width, resolution, slot, axis * 24 + column)
		for component in 3:
			var absolute := absf(value[component])
			if absolute > 1e-20:
				coefficients["nonzero_rgb"] = int(coefficients["nonzero_rgb"]) + 1
			coefficients["max_abs_rgb"] = maxf(float(coefficients["max_abs_rgb"]), absolute)
			coefficients["sum_abs_rgb"] = float(coefficients["sum_abs_rgb"]) + absolute
	var metadata := _magicdawn_readback_vec4f(bytes, width, resolution, slot, axis * 24 + 18)
	var anchor := _magicdawn_readback_vec4f(bytes, width, resolution, slot, axis * 24 + 19)
	var secondary := _magicdawn_readback_vec4f(bytes, width, resolution, slot, axis * 24 + 20)
	var primary := _magicdawn_readback_vec4f(bytes, width, resolution, slot, axis * 24 + 21)
	return {"coefficient_rgb": coefficients, "metadata": metadata, "anchor": anchor,
		"secondary_rgb": Vector3(secondary.x, secondary.y, secondary.z),
		"secondary_alpha": secondary.w,
		"primary_rgb": Vector3(primary.x, primary.y, primary.z), "primary_alpha": primary.w}

func _magicdawn_readback_vec4f(bytes: PackedByteArray, width: int,
		resolution: int, slot: Vector3i, column: int) -> Vector4:
	var x := slot.x + column * resolution
	var offset := ((slot.z * resolution + slot.y) * width + x) * 16
	if offset < 0 or offset + 16 > bytes.size():
		return Vector4.ZERO
	return Vector4(bytes.decode_float(offset), bytes.decode_float(offset + 4),
		bytes.decode_float(offset + 8), bytes.decode_float(offset + 12))

func _magicdawn_readback_receiver(cache_bytes: PackedByteArray, tag_bytes: PackedByteArray,
		support_bytes: PackedByteArray, stencil_bytes: PackedByteArray,
		texture_width: int, resolution: int, spacing: float, geometry_epoch: int,
		origins: Array, receiver: Dictionary) -> Dictionary:
	var world: Vector3 = receiver.get("world", Vector3.ZERO)
	var normal: Vector3 = receiver.get("normal", Vector3.UP)
	var axis := _clv_dominant_axis(normal)
	var levels: Array[Dictionary] = []
	for level in 3:
		if level >= origins.size() or spacing <= 0.0:
			continue
		var step := spacing * float(1 << level)
		var position := (world + normal * step * 0.75) / step - Vector3.ONE * 0.5
		var base := Vector3i(floori(position.x), floori(position.y), floori(position.z))
		var origin: Vector3i = origins[level]
		var relative := base - origin
		var corners: Array[Dictionary] = []
		for corner in 8:
			var logical := base + Vector3i(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
			var physical := Vector3i(_clv_posmod(logical.x, resolution),
				_clv_posmod(logical.y, resolution), _clv_posmod(logical.z, resolution))
			var slot := Vector3i(physical.x, physical.y, physical.z + level * resolution)
			var tag := _clv_read_vec4i(tag_bytes, resolution, resolution, slot)
			var support := _clv_read_u32(support_bytes, resolution, resolution, slot)
			var face_index := ((slot.z * resolution + slot.y) * resolution + slot.x) * 3 + axis
			var stencil_word := face_index * 52
			var marker := stencil_word * 4 + 8 <= stencil_bytes.size() \
					and (int(stencil_bytes.decode_u32((stencil_word + 1) * 4)) & 0x80000000) != 0
			var stencil_count := int(stencil_bytes.decode_u32(stencil_word * 4)) \
				if stencil_word * 4 + 4 <= stencil_bytes.size() else -1
			corners.append({"corner": corner, "logical": logical, "slot": slot,
				"tag": tag, "tag_epoch_match": tag.w == geometry_epoch,
				"support": support, "axis_support": (support & (1 << axis)) != 0,
				"transfer_valid": marker, "stencil_count": stencil_count,
				"metadata": _magicdawn_readback_vec4f(cache_bytes, texture_width,
					resolution, slot, axis * 24 + 18),
				"anchor": _magicdawn_readback_vec4f(cache_bytes, texture_width,
					resolution, slot, axis * 24 + 19),
				"secondary": _magicdawn_readback_vec4f(cache_bytes, texture_width,
					resolution, slot, axis * 24 + 20),
				"primary": _magicdawn_readback_vec4f(cache_bytes, texture_width,
					resolution, slot, axis * 24 + 21)})
		levels.append({"level": level, "step_m": step, "origin": origin,
			"query_position": position, "query_fraction": position - position.floor(),
			"logical_base": base, "relative_base": relative,
			"inside_window": relative.x >= 0 and relative.y >= 0 and relative.z >= 0 \
					and relative.x < resolution - 1 and relative.y < resolution - 1 \
					and relative.z < resolution - 1, "axis": axis, "corners": corners})
	return {"name": str(receiver.get("name", "receiver")), "world": world,
		"normal": normal, "axis": axis, "levels": levels}

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	_last_prt_two_stage_active = false
	_last_prt_two_stage_stage_values = PackedInt32Array([MAGIC_GI_PRT_STAGE_LEGACY])
	_last_prt_three_stage_active = false
	_last_prt_three_stage_stage_values = PackedInt32Array([MAGIC_GI_PRT_STAGE_LEGACY])
	_frame_prt_scale = 1
	if _dynamic_volume_publication_token > 0 and _dynamic_volume_cache != null \
			and int(_dynamic_volume_cache.get_runtime_state().get("layout_version", 0)) in [5, 6]:
		_render_preinterpolated_clv_debug(buffers, view, rd)
		return
	if _frame_snapshot.get("prepared_source_header") is Resource:
		# Incompatible ABI, missing pages or failed residency must never fall
		# through into a legacy CSR/static-lighting implementation.
		var paged_output: RID = inputs[5].get_texture(buffers, view)
		if paged_output.is_valid(): rd.texture_clear(paged_output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	if _is_magicdawn_dynamic_clv_snapshot(_frame_snapshot):
		_render_magicdawn_dynamic_clv_debug(buffers, view, rd)
		return
	if bool(_frame_snapshot.get("surfel", false)):
		_render_surfel(buffers, view, rd)
		_complete_prt_scene_hdr_readback_error("Scene HDR readback does not support the surfel pass path")
		return
	_release_surfel_nrd_if_active()
	var resolved_parameters: Vector4 = _frame_parameters if _frame_parameters is Vector4 else parameters
	var replacement_eligible := _replacement_requested(_frame_snapshot, resolved_parameters.x)
	var sky_diffuse: RID = _sky_diffuse_input.get_texture(buffers, view)
	_frame_replacement_enabled = replacement_eligible and _replacement_request_prepared and sky_diffuse.is_valid()
	if replacement_eligible and not _frame_replacement_enabled:
		_warn_missing_replacement_bridge()
	if bool(_frame_snapshot.get("streamed", false)):
		_release_prt_raw_view(buffers, view, rd)
		if _clv_cache_backend(_frame_snapshot) == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
				and _clv_internal_test_layout == CLV_INTERNAL_LAYOUT_AUTHORED:
			# Layout 16 needs one persistent field spanning all resident pages. Until
			# the streamed producer can publish that combined field, fail closed and
			# leave native lighting untouched instead of entering the legacy CSR path.
			_frame_replacement_enabled = false
			var streamed_output: RID = inputs[5].get_texture(buffers, view)
			if streamed_output.is_valid():
				rd.texture_clear(streamed_output, Color(0, 0, 0, 0), 0, 1, 0, 1)
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "streamed_combined_field_not_ready", "pixel_csr_fallback": false,
				"replacement_enabled": false}
			return
		_render_streamed(buffers, view, rd)
		_complete_prt_scene_hdr_readback_error("Scene HDR readback does not support the streamed pass path")
		return
	if clv_debug_view == CLVDebugView.OFF:
		_frame_prt_scale = prt_apply_scale
	if _frame_prt_scale <= 1:
		_release_prt_raw_view(buffers, view, rd)
	var output: RID = inputs[5].get_texture(buffers, view)
	if not output.is_valid():
		_complete_prt_scene_hdr_readback_error("PRT output is unavailable in the requested scene HDR frame")
		return
	var cache_key := str(_frame_snapshot.get("cache_key", ""))
	var magicdawn_prepared_state := _magicdawn_native_prepared_state(
			buffers, view, _frame_snapshot)
	if _frame_native_baked_sh_consumed:
		if magicdawn_prepared_state.is_empty():
			# The renderer reported a consumed publication, but the matching cache
			# lease no longer validates. Never add a second contribution or re-update
			# a cache that was already prepared earlier in this frame.
			rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
			_magicdawn_frame_active = false
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "native_consumed_cache_lease_mismatch",
				"pixel_csr_fallback": false, "native_consumed": true,
				"standalone_apply_dispatched": false,
				"replacement_enabled": true, "sky_ownership_bridge_active": true}
			_complete_prt_scene_hdr_readback_error(
					"Native baked-SH draw consumed a publication whose cache lease no longer matches")
			return
		_frame_replacement_enabled = true
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_frame_active = false
		_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"status": "native_consumed_standalone_apply_skipped",
			"pixel_csr_fallback": false, "native_consumed": true,
			"standalone_apply_dispatched": false,
			"replacement_enabled": true, "sky_ownership_bridge_active": true,
			"publication_token": int(_frame_native_baked_sh_publication.get(
					"publication_token", 0)),
			"baked_indirect_sh_revision": MAGICDAWN_BAKED_SH_REVISION,
			"scene_exposure_normalization": _scene_exposure_normalization,
			"pre_exposure_applied_by": "FRP deferred-lighting tail exactly once"}
		_service_prt_scene_hdr_readback(buffers, view, rd)
		return
	var exact_debug_mode := int(prt_surface_exact_debug_mode)
	var exact_debug_active := _frame_prt_scale == 1 \
			and ((exact_debug_mode >= 100 and exact_debug_mode <= 105) \
				or (exact_debug_mode >= 107 and exact_debug_mode <= 109))
	if exact_debug_active:
		# This opt-in branch isolates each diagnostic mode from any prior sidecar data.
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		prt_surface_exact_debug_output = output
		prt_surface_exact_debug_depth = inputs[1].get_texture(buffers, view)
		prt_surface_exact_debug_point_buffer = _exact_point_debug_buffer
	var native_state := _native_prepared_state(buffers, view, cache_key)
	var prepared_clipmap: RefCounted = native_state.get("clipmap") if not native_state.is_empty() else null
	if not magicdawn_prepared_state.is_empty():
		prepared_clipmap = magicdawn_prepared_state.get("clipmap")
	elif _magicdawn_native_prepare_attempted_this_frame(buffers, view):
		# Native preflight already attempted this view and failed or its frame/bake
		# tuple changed. Repeating update() here could double the producer budget.
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_magicdawn_frame_active = false
		_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"status": "prepared_cache_mismatch_fail_closed",
			"pixel_csr_fallback": false, "native_consumed": false,
			"standalone_apply_dispatched": false,
			"fallback_reason": "frame_view_bake_layout_or_revision_changed",
			"native_prepare_fallback_reason": str(
					_native_baked_sh_state.get("fallback_reason", "")),
			"native_prepare_failure_details": _native_baked_sh_state.get(
					"failure_details", {})}
		_complete_prt_scene_hdr_readback_error(
				"Prepared layout-17 cache lease changed; skipped repeat update and pixel fallback")
		return
	if not _prepare_prt_clv_view(buffers, view, rd, prepared_clipmap):
		_frame_replacement_enabled = false
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_complete_prt_scene_hdr_readback_error("PRT cache preparation failed before scene HDR readback")
		return
	var shader_before := _shader
	var compute_before := _compute_pipeline
	var sampler_before := _sampler
	var shader_file_before := shader_file
	var raster_count_before := _raster_pipelines.size()
	var magicdawn_active := _magicdawn_frame_active
	var keywords_before: Dictionary = shader_keywords.duplicate(true) if magicdawn_active else {}
	var force_full_features := _frame_prt_scale != 1
	force_full_features = force_full_features or clv_debug_view != CLVDebugView.OFF
	force_full_features = force_full_features or _prt_raw_debug_output
	force_full_features = force_full_features or _clv_stats_capture_armed or _clv_stats_capture_active
	force_full_features = force_full_features or approximate_clv_volume_enabled
	force_full_features = force_full_features or exact_clv_corner_visibility_enabled
	force_full_features = force_full_features or prt_surface_exact_debug_mode != 0
	var full_shader_features := not prt_fast_shader_variant_enabled or force_full_features
	if magicdawn_active:
		shader_file = MAGIC_GI_APPLY_MAGICDAWN_SHADER
		# The dedicated layout-17 shader declares no specialization constants. Do
		# not inherit the old shader's IDs, B14 keywords, or staged source variants.
		shader_keywords.clear()
		_keyword_signature = ""
	else:
		set_shader_keyword(MAGIC_GI_FULL_FEATURES_SPEC_ID, full_shader_features)
		_last_prt_shader_full_features = full_shader_features
	_clv_stats_capture_active = _clv_stats_capture_armed
	_clv_stats_capture_armed = false
	_magicdawn_stats_capture_active = magicdawn_active and _magicdawn_stats_capture_armed
	if magicdawn_active:
		_magicdawn_stats_capture_armed = false
		_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"status": "shader_or_dispatch_not_started", "pixel_csr_fallback": false,
			"includes_primary_sky": true, "includes_direct_directional_light": false,
			"replacement_enabled": _frame_replacement_enabled,
			"stats_capture_frame": _magicdawn_stats_capture_frame}
	_capture_gpu_timestamp(rd, "Apply Begin")
	super._render(buffers, view, rd)
	_capture_gpu_timestamp(rd, "Apply End")
	if _clv_stats_capture_active:
		_clv_stats_capture_frame = Engine.get_process_frames()
	_service_prt_linear_output_readback(output, view, rd)
	_service_prt_scene_hdr_readback(buffers, view, rd)
	_clv_stats_capture_active = false
	_magicdawn_stats_capture_active = false
	if exact_debug_active:
		prt_surface_exact_debug_last_mode = exact_debug_mode
		prt_surface_exact_debug_frame += 1
		prt_surface_exact_debug_capture_frame = Engine.get_process_frames()
	_frame_clipmap = null
	if magicdawn_active:
		shader_file = shader_file_before
		shader_keywords = keywords_before
		_keyword_signature = ""
	if shader_before != _shader or compute_before != _compute_pipeline \
			or sampler_before != _sampler or raster_count_before != _raster_pipelines.size():
		_sync_owned_rid_snapshot()

func _prepare_prt_clv_view(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice, prepared_clipmap: RefCounted = null) -> bool:
	if _is_magicdawn_dynamic_clv_snapshot(_frame_snapshot):
		return _prepare_magicdawn_dynamic_clv_view(buffers, view, rd)
	_frame_clipmap = null
	_magicdawn_frame_active = false
	if _layout14_b_internal_test_enabled:
		_set_layout14_b_frame_active(false)
	else:
		_layout14_b_frame_active = false
		_layout14_b_frame_moments = RID()
		_layout14_b_frame_sampler = RID()
		_layout14_b_frame_tags = RID()
		if _layout14_b_saved_shader_file != null \
				and shader_file == _layout14_b_apply_shader_resource:
			shader_file = _layout14_b_saved_shader_file
	var clv_backend := _clv_cache_backend(_frame_snapshot)
	if _last_clv_cache_backend != clv_backend:
		_last_clv_cache_backend = clv_backend
		if Engine.is_editor_hint():
			notify_property_list_changed()
	var requested_layout := _clv_layout_version_for_backend(clv_backend)
	var magicdawn_baked_path := requested_layout == CLV_MAGICDAWN_BAKED_SH_LAYOUT_VERSION \
			and _clv_internal_test_layout == CLV_INTERNAL_LAYOUT_AUTHORED
	if magicdawn_baked_path:
		_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"status": "layout17_prepare_started", "pixel_csr_fallback": false,
			"replacement_enabled": false}
	if magicdawn_baked_path and (not bool(_frame_snapshot.get("use_clv", true)) \
			or _frame_prt_scale != 1):
		_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"status": "unsupported_apply_configuration", "pixel_csr_fallback": false,
			"replacement_enabled": false}
		return false
	if magicdawn_baked_path and clv_debug_view != CLVDebugView.OFF:
		# The baked-SH shader has no CLV diagnostic visualization. Keep the normal
		# contribution live; Debug Buffers → Magic GI reads this standalone output.
		_magicdawn_runtime_state["clv_debug_view_status"] = "unsupported_ignored_gi_remains_active"
	if not _ensure_sampler(rd):
		if magicdawn_baked_path:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "sampler_setup_failed", "pixel_csr_fallback": false,
				"replacement_enabled": false}
		return false
	if not _ensure_page_param_buffers(rd):
		if magicdawn_baked_path:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "page_parameter_buffer_setup_failed", "pixel_csr_fallback": false,
				"page_params_valid": _page_params_ubo.is_valid(),
				"pending_page_params_valid": _pending_page_params_ubo.is_valid(),
				"replacement_enabled": false}
		return false
	if not _write_page_params(rd, AABB(), Rect2i(Vector2i.ZERO, buffers.get_internal_size()),
			_frame_snapshot, false):
		if magicdawn_baked_path:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "page_parameter_upload_failed", "pixel_csr_fallback": false,
				"replacement_enabled": false}
		return false
	var cache_key := str(_frame_snapshot.get("cache_key", ""))
	var data: Variant = _frame_snapshot.get("data")
	var version := int(_frame_snapshot.get("version", -1))
	if _frame_scene_data == null:
		if magicdawn_baked_path:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "missing_scene_data", "pixel_csr_fallback": false,
				"replacement_enabled": false}
		return false
	if cache_key.is_empty():
		if magicdawn_baked_path:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "missing_bake_cache_key", "pixel_csr_fallback": false,
				"replacement_enabled": false}
		return false
	if not is_instance_valid(data):
		if magicdawn_baked_path:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "missing_bake_data", "pixel_csr_fallback": false,
				"replacement_enabled": false}
		return false
	# Layout-16 segment visibility requires a persisted, validated v6 BVH.
	# Older moment previews intentionally synthesize empty traversal buffers and
	# must never enter the baked-SH producer, whose empty-tree result is clear.
	if magicdawn_baked_path and int(data.get("format_version")) != 6:
		_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"status": "current_visibility_bvh_required", "pixel_csr_fallback": false,
			"data_format_version": int(data.get("format_version")),
			"required_data_format_version": 6, "replacement_enabled": false}
		return false
	if not _ensure_bake_resources(cache_key, data, version, rd):
		if magicdawn_baked_path:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "bake_resource_prepare_failed", "pixel_csr_fallback": false,
				"replacement_enabled": false}
		return false
	var cached: Dictionary = _bake_resources[cache_key]
	# This O(1) cache bit proves the uploaded BVH came through Data's full v6
	# validator. It also rejects a stale/legacy cache reused by the baked backend.
	if magicdawn_baked_path and not bool(cached.get("exact_visibility", false)):
		_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
			"status": "validated_visibility_bvh_upload_missing", "pixel_csr_fallback": false,
			"exact_visibility": false, "replacement_enabled": false}
		return false
	var clv_layout_version := _clv_layout_version_for_backend(clv_backend)
	if magicdawn_baked_path:
		if not data.has_method("has_baked_indirect_sh") \
				or not bool(data.call("has_baked_indirect_sh")):
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "revision2_baked_sh_unavailable", "pixel_csr_fallback": false,
				"baked_sh_revision": int(data.get("baked_indirect_sh_revision")),
				"replacement_enabled": false}
			_report_baked_sh_unready_once(data,
				"MagicDawn baked SH backend needs a verified revision-2 total-SH Bake; run Bake before using backend 1.")
			return false
		var baked_directional: RefCounted = cached.get("directional")
		var baked_field_value: Variant = null
		if baked_directional != null:
			baked_field_value = baked_directional.get("baked_indirect_lighting")
		if not baked_field_value is RID:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "baked_source_buffer_missing", "pixel_csr_fallback": false,
				"baked_sh_revision": int(data.get("baked_indirect_sh_revision")),
				"replacement_enabled": false}
			_report("MagicDawn baked SH producer has no uploaded revision-2 probe field.")
			return false
		var baked_field: RID = baked_field_value
		if not baked_field.is_valid():
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "baked_source_buffer_invalid", "pixel_csr_fallback": false,
				"replacement_enabled": false}
			return false
	if not magicdawn_baked_path \
			and not _update_emission_texture(cache_key, _frame_snapshot, data, rd):
		return false
	var selected_resolution := _effective_clv_resolution(clv_backend)
	var codec_info: Dictionary = {}
	var requested_format_tag := 32
	var requested_codec := MagicDawnBakedSHCache.DEFAULT_CODEC_R32
	if magicdawn_baked_path:
		var codec_info_value: Variant = cached.get("magicdawn_baked_sh_codec", {})
		if not codec_info_value is Dictionary:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "baked_sh_codec_unavailable", "pixel_csr_fallback": false,
				"replacement_enabled": false}
			return false
		codec_info = codec_info_value
		var codec_value: Variant = codec_info.get("codec", Vector4.ZERO)
		if not bool(codec_info.get("valid", false)) or not codec_value is Vector4:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "baked_sh_codec_invalid", "pixel_csr_fallback": false,
				"codec_error": str(codec_info.get("error", "missing_codec")),
				"replacement_enabled": false}
			return false
		requested_codec = codec_value
		requested_format_tag = int(codec_info.get("format_tag", 32))
		if _magicdawn_field_format_override == 32:
			requested_format_tag = 32
			requested_codec = MagicDawnBakedSHCache.DEFAULT_CODEC_R32
		elif requested_format_tag != 16:
			requested_format_tag = 32
			requested_codec = MagicDawnBakedSHCache.DEFAULT_CODEC_R32
	var boundary_tensor_payload: Dictionary = {"valid": false}
	var boundary_record_count := 0
	if magicdawn_baked_path \
			and clv_backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and clv_layout_version == CLV_MAGICDAWN_BAKED_SH_LAYOUT_VERSION \
			and data.has_method("get_baked_boundary_tensor_records_for_runtime"):
		var boundary_payload_value: Variant = data.call(
				"get_baked_boundary_tensor_records_for_runtime")
		if boundary_payload_value is Dictionary:
			boundary_tensor_payload = boundary_payload_value
			if bool(boundary_tensor_payload.get("valid", false)):
				var boundary_keys_value: Variant = boundary_tensor_payload.get("keys", null)
				if boundary_keys_value is PackedInt32Array \
						and boundary_keys_value.size() % 4 == 0:
					boundary_record_count = boundary_keys_value.size() / 4
	var clv_gpu_bytes := _clv_gpu_bytes_for_backend(clv_backend,
			selected_resolution, requested_format_tag, boundary_record_count)
	# Compute fallback reconstructs its own view ray for each view; native deferred
	# lighting receives a separate bake-only UBO so a multiview draw shares no camera matrix.
	if not _update_frame_ubo(_frame_snapshot, _frame_scene_data, view, rd):
		if magicdawn_baked_path:
			_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
				"status": "frame_ubo_update_failed", "pixel_csr_fallback": false,
				"replacement_enabled": false}
		return false
	if clv_layout_version == CLV_INTERNAL_LAYOUT14_V0_TEST \
			and int(cached.get("probe_count", 0)) <= 0:
		# There is no directional payload to turn into the optional V0 field.
		# Leave the clipmap null so the ordinary PRT pass uses its source path;
		# in particular, do not allocate or bind a zero-probe raw sidecar.
		_frame_clipmap = null
		_cache_clock += 1
		cached["last_used"] = _cache_clock
		_bake_resources[cache_key] = cached
		return true
	if prepared_clipmap != null:
		_frame_clipmap = prepared_clipmap
		_magicdawn_frame_active = magicdawn_baked_path
	else:
		if not magicdawn_baked_path:
			_capture_gpu_timestamp(rd, "Relight Begin")
			if not _update_probe_lighting(cache_key, _frame_snapshot, rd):
				return false
			_capture_gpu_timestamp(rd, "Relight End")
		var directional: RefCounted = cached.get("directional")
		_capture_gpu_timestamp(rd, "CLV Begin")
		if directional != null and bool(_frame_snapshot.get("use_clv", true)):
			var clip_key := "%d:%d:%d:%s" % [buffers.get_instance_id(), view,
				MAGICDAWN_NATIVE_LAYOUT_VERSION, cache_key]
			if _clipmaps.has(clip_key):
				var old_entry: Dictionary = _clipmaps[clip_key]
				if not _clipmap_layout_is_current(old_entry, clv_backend,
						_magicdawn_field_format_override if magicdawn_baked_path else -1):
					var old_cache: RefCounted = old_entry.get("cache")
					if old_cache != null:
						_free_rids(rd, old_cache.owned_rids())
					_clipmaps.erase(clip_key)
					_sync_owned_rid_snapshot()
			if not _clipmaps.has(clip_key):
				var clipmap = _new_clv_cache(clv_backend)
				var create_succeeded := false
				if magicdawn_baked_path:
					create_succeeded = bool(clipmap.call("create", rd,
							selected_resolution, false, 0, requested_format_tag, requested_codec,
							boundary_record_count))
				else:
					create_succeeded = clipmap.create(rd, selected_resolution)
				if not create_succeeded:
					var cache_create_state: Dictionary = {}
					if clipmap.has_method("get_layout16_runtime_state"):
						var cache_create_state_value: Variant = \
								clipmap.call("get_layout16_runtime_state")
						if cache_create_state_value is Dictionary:
							cache_create_state = cache_create_state_value
					var cache_create_error := str(cache_create_state.get("last_error",
							clipmap.get("_last_error")))
					_free_rids(rd, clipmap.owned_rids())
					# A missing block-chart cache is an ordinary CLV miss: keep the PRT
					# pass alive and let the shared tail evaluate its source gather.
					if clv_backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART:
						_capture_gpu_timestamp(rd, "CLV End")
						if magicdawn_baked_path:
							_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
								"status": "clipmap_create_failed", "pixel_csr_fallback": false,
								"replacement_enabled": false,
								"resolution": selected_resolution,
								"requested_format_tag": requested_format_tag,
								"requested_codec": requested_codec,
								"cache_error": cache_create_error,
								"cache_state": cache_create_state}
							return false
						return true
					return false
				var actual_gpu_bytes := clv_gpu_bytes
				var field_cache_state: Dictionary = {}
				if magicdawn_baked_path:
					var field_cache_state_value: Variant = clipmap.call("get_layout16_runtime_state")
					if not field_cache_state_value is Dictionary:
						_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
							"status": "layout17_cache_state_unavailable",
							"pixel_csr_fallback": false, "replacement_enabled": false}
						_free_rids(rd, clipmap.owned_rids())
						return false
					field_cache_state = field_cache_state_value
					actual_gpu_bytes = int(field_cache_state.get("field_gpu_bytes_estimate", 0))
					if actual_gpu_bytes <= 0:
						_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
							"status": "layout17_cache_memory_estimate_invalid",
							"pixel_csr_fallback": false, "replacement_enabled": false,
							"cache_state": field_cache_state.duplicate(true)}
						_free_rids(rd, clipmap.owned_rids())
						return false
				_clipmaps[clip_key] = {"cache": clipmap, "owner": weakref(buffers),
					"last_used": _cache_clock, "bake": cache_key,
					"layout_version": clv_layout_version, "cache_backend": clv_backend,
					"requested_resolution": selected_resolution,
					"resolution": int(clipmap.get("resolution")),
					"gpu_bytes": actual_gpu_bytes,
				"field_format_tag": int(field_cache_state.get("format_tag", 0)),
					"field_codec": field_cache_state.get("codec", Vector4.ZERO),
				"boundary_tensor_record_count": int(field_cache_state.get(
						"boundary_tensor_record_count", 0)),
				"boundary_tensor_buffer_generation": int(field_cache_state.get(
						"boundary_tensor_buffer_generation", 0)),
					"field_codec_fallback_reason": str(codec_info.get("fallback_reason", "")) \
							if magicdawn_baked_path else "",
					"field_format_fallback_reason": str(
							field_cache_state.get("format_fallback_reason", "")),
					"field_format_override": _magicdawn_field_format_override \
							if magicdawn_baked_path else -1}
				_sync_owned_rid_snapshot()
			var entry: Dictionary = _clipmaps[clip_key]
			entry.last_used = _cache_clock
			var spacing := float(_frame_snapshot.get("clv_cell_size", 0.5))
			var source_bounds: AABB = cached.source_bounds
			var camera_world_position: Vector3 = _frame_scene_data.get_cam_transform().origin
			var focus := ClipmapCache.focus_for_bounds(
					camera_world_position, source_bounds, spacing,
					int(entry.cache.get("resolution")))
			var baked_focus := focus
			var baked_focus_domain := AABB()
			var baked_focus_report: Dictionary = {}
			if magicdawn_baked_path:
				baked_focus_domain = _magicdawn_world_focus_domain(source_bounds, _frame_snapshot)
				if not _valid_clv_focus_bounds(baked_focus_domain):
					_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
						"status": "invalid_world_space_focus_domain", "pixel_csr_fallback": false,
						"replacement_enabled": false,
						"source_bounds_world": [source_bounds.position.x, source_bounds.position.y,
							source_bounds.position.z, source_bounds.size.x, source_bounds.size.y,
							source_bounds.size.z],
						"owner_transform": _frame_snapshot.get("owner_transform"),
						"owner_size": _frame_snapshot.get("owner_size"),
						"focus_domain_valid": false}
					return false
				baked_focus_report = MagicDawnBakedSHCache.focus_for_baked_domain(
						camera_world_position, baked_focus_domain, spacing,
						int(entry.cache.get("resolution")))
				if not bool(baked_focus_report.get("valid", false)):
					_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
						"status": "invalid_world_space_focus_domain", "pixel_csr_fallback": false,
						"replacement_enabled": false,
						"focus_report": baked_focus_report}
					return false
				var baked_focus_value: Variant = baked_focus_report.get("focus_world")
				if not baked_focus_value is Vector3:
					_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
						"status": "invalid_world_space_focus_domain", "pixel_csr_fallback": false,
						"replacement_enabled": false,
						"focus_report": baked_focus_report}
					return false
				baked_focus = baked_focus_value
			var clv_bake := cached
			var clv_bake_is_copy := false
			var clv_cluster_buffer := _cluster_binding_for_cache(cached, rd)
			if not clv_cluster_buffer.is_valid():
				if clv_backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART:
					_capture_gpu_timestamp(rd, "CLV End")
					if magicdawn_baked_path:
						_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
								"status": "probe_cluster_unavailable", "pixel_csr_fallback": false,
								"replacement_enabled": false}
						return false
					return true
				return false
			if clv_backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART:
				# Layout 12 builds chart domains from the exact packed CPU bake snapshot.
				# The GPU RIDs remain the normal production bindings; these arrays are
				# consumed only by the bounded CPU geometry index builder.
				clv_bake = cached.duplicate(false)
				clv_bake_is_copy = true
				clv_bake["probe_clusters"] = clv_cluster_buffer
				clv_bake["cpu_visibility_nodes"] = data.visibility_nodes
				clv_bake["cpu_visibility_triangles"] = data.visibility_triangles
				clv_bake["cpu_geometry_key"] = "%s:%d:%d" % [cache_key,
					int(cached.get("data_id", -1)), version]
			elif clv_cluster_buffer != cached.get("probe_clusters", RID()):
				clv_bake = cached.duplicate(false)
				clv_bake_is_copy = true
				clv_bake["probe_clusters"] = clv_cluster_buffer
			if magicdawn_baked_path \
					and clv_layout_version == CLV_MAGICDAWN_BAKED_SH_LAYOUT_VERSION:
				if not clv_bake_is_copy:
					clv_bake = cached.duplicate(false)
					clv_bake_is_copy = true
				clv_bake["boundary_tensor_records_payload"] = boundary_tensor_payload
			var geometry_epoch := _nonstream_clv_geometry_epoch(
					_frame_snapshot, cache_key, int(cached.get("data_id", -1)), version)
			var content_revision := 1 if magicdawn_baked_path else \
					_nonstream_clv_content_revision(_frame_snapshot, cached, int(directional.epoch))
			var layout14_b_requested_for_frame := clv_layout_version == CLV_INTERNAL_LAYOUT14_V0_TEST \
				and _layout14_b_internal_test_enabled
			var layout14_b_raw_ready := false
			if layout14_b_requested_for_frame:
				layout14_b_raw_ready = _layout14_b_raw_source_ready(directional)
				if not layout14_b_raw_ready:
					# A stale raw sidecar must not spend work building a field the B root cannot use.
					_frame_clipmap = null
					_set_layout14_b_frame_active(false)
					_layout14_b_error = "raw_directional_sidecar_unavailable_or_stale"
					_capture_gpu_timestamp(rd, "CLV End")
					_prune_clipmaps(rd)
					_cache_clock += 1
					cached["last_used"] = _cache_clock
					_bake_resources[cache_key] = cached
					return true
			var cache_update_succeeded := false
			var boundary_buffer_generation_before := int(
					entry.get("boundary_tensor_buffer_generation", 0))
			if clv_layout_version == CLV_INTERNAL_LAYOUT14_V0_TEST:
				if entry.cache.has_method("set_internal_b_test_enabled"):
					entry.cache.call("set_internal_b_test_enabled",
							_layout14_b_cache_requested())
				cache_update_succeeded = entry.cache.update(rd, focus, spacing,
					geometry_epoch, content_revision, clv_bake, directional, _ubo, _sampler,
					int(_frame_snapshot.get("clv_cells_per_frame", 256)),
					approximate_clv_volume_enabled,
					exact_clv_corner_visibility_enabled,
					approximate_clv_ready_bit_enabled, false, camera_world_position)
			elif magicdawn_baked_path:
				cache_update_succeeded = entry.cache.update(rd, baked_focus,
					spacing, geometry_epoch, content_revision, clv_bake, directional,
					_ubo, _sampler,
					int(_frame_snapshot.get("clv_cells_per_frame", 256)),
					false, false, false, false, camera_world_position,
					baked_focus_domain, baked_focus_report)
			else:
				cache_update_succeeded = entry.cache.update(rd, focus, spacing,
					geometry_epoch, content_revision, clv_bake, directional, _ubo, _sampler,
					int(_frame_snapshot.get("clv_cells_per_frame", 256)),
					approximate_clv_volume_enabled,
					exact_clv_corner_visibility_enabled,
					approximate_clv_ready_bit_enabled)
			var updated_gpu_bytes := int(entry.get("gpu_bytes", clv_gpu_bytes))
			if magicdawn_baked_path \
					and clv_layout_version == CLV_MAGICDAWN_BAKED_SH_LAYOUT_VERSION:
				var updated_state_value: Variant = entry.cache.call("get_layout16_runtime_state")
				if not updated_state_value is Dictionary:
					_sync_owned_rid_snapshot()
					_magicdawn_runtime_state = {"backend": 1,
						"layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
						"status": "layout17_cache_state_unavailable_after_update",
						"pixel_csr_fallback": false, "replacement_enabled": false}
					return false
				var updated_state: Dictionary = updated_state_value
				updated_gpu_bytes = int(updated_state.get("field_gpu_bytes_estimate", 0))
				if updated_gpu_bytes <= 0:
					_magicdawn_runtime_state = {"backend": 1,
						"layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
						"status": "layout17_cache_memory_estimate_invalid_after_update",
						"pixel_csr_fallback": false, "replacement_enabled": false}
					return false
				entry["boundary_tensor_buffer_generation"] = int(
						updated_state.get("boundary_tensor_buffer_generation", 0))
				entry["boundary_tensor_record_count"] = int(
						updated_state.get("boundary_tensor_record_count", 0))
				if int(entry.get("boundary_tensor_buffer_generation", 0)) \
						!= boundary_buffer_generation_before:
					_clipmaps[clip_key] = entry
					_sync_owned_rid_snapshot()
			entry["gpu_bytes"] = updated_gpu_bytes
			_clipmaps[clip_key] = entry
			if not cache_update_succeeded:
				# Never sample an older block-chart entry after a failed producer update.
				# A null cache binds the zero-tag fallback and forces the PRT source path.
				if clv_backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART:
					_capture_gpu_timestamp(rd, "CLV End")
					if magicdawn_baked_path:
						_magicdawn_runtime_state = {"backend": 1, "layout_version": MAGICDAWN_NATIVE_LAYOUT_VERSION,
								"status": "producer_update_failed", "pixel_csr_fallback": false,
								"replacement_enabled": false,
							"cache_error": str(entry.cache.get("_last_error")),
							"cache_state": entry.cache.call("get_layout16_runtime_state") \
								if entry.cache.has_method("get_layout16_runtime_state") else {}}
						return false
					return true
				return false
			_frame_clipmap = entry.cache
			_magicdawn_frame_active = magicdawn_baked_path
			if clv_layout_version == CLV_INTERNAL_LAYOUT14_V0_TEST \
					and _layout14_b_internal_test_enabled:
				_sync_owned_rid_snapshot()
				var b_state_value: Variant = entry.cache.call("get_node_visibility_bindings", rd) \
						if entry.cache.has_method("get_node_visibility_bindings") else {}
				var b_state: Dictionary = b_state_value if b_state_value is Dictionary else {}
				var raw_source_ready := layout14_b_raw_ready
				if bool(b_state.get("valid", false)) \
						and _ensure_layout14_b_apply_shader_resource() and raw_source_ready:
					_set_layout14_b_frame_active(true, b_state)
					_layout14_b_error = ""
				else:
					_frame_clipmap = null
					_set_layout14_b_frame_active(false)
					if not bool(b_state.get("valid", false)):
						_layout14_b_error = str(b_state.get("error", "sidecar_unavailable"))
					elif not raw_source_ready:
						_layout14_b_error = "raw_directional_sidecar_unavailable_or_stale"
			else:
				_set_layout14_b_frame_active(false)
		_capture_gpu_timestamp(rd, "CLV End")
		_prune_clipmaps(rd)
	_cache_clock += 1
	cached["last_used"] = _cache_clock
	_bake_resources[cache_key] = cached
	return true

func _prepare_magicdawn_dynamic_clv_view(buffers: RenderSceneBuffersRD,
		view: int, rd: RenderingDevice) -> bool:
	_frame_clipmap = null
	_magicdawn_frame_active = false
	var failure := func(status: String, reason: String, details: Dictionary = {}) -> bool:
		_magicdawn_runtime_state["status"] = status
		_magicdawn_runtime_state["fallback_reason"] = reason
		_magicdawn_runtime_state["pixel_csr_fallback"] = false
		for key in details:
			_magicdawn_runtime_state[key] = details[key]
		return false
	if not bool(_frame_snapshot.get("use_clv", true)) \
			or bool(_frame_snapshot.get("streamed", false)) \
			or bool(_frame_snapshot.get("surfel", false)):
		return failure.call("unsupported_scene_mode_fail_closed",
			"dynamic_clv_requires_nonstreamed_non_surfel_clv")
	if _frame_scene_data == null:
		return failure.call("scene_data_unavailable_fail_closed", "missing_scene_data")
	if not _ensure_sampler(rd):
		return failure.call("sampler_setup_failed_fail_closed", "sampler_setup_failed")
	if not _ensure_page_param_buffers(rd):
		return failure.call("page_parameter_buffer_setup_failed_fail_closed",
			"page_parameter_buffer_setup_failed")
	if not _write_page_params(rd, AABB(), Rect2i(Vector2i.ZERO,
			buffers.get_internal_size()), _frame_snapshot, false):
		return failure.call("page_parameter_upload_failed_fail_closed",
			"page_parameter_upload_failed")
	var cache_key := str(_frame_snapshot.get("cache_key", ""))
	var data: Variant = _frame_snapshot.get("data")
	var version := int(_frame_snapshot.get("version", -1))
	if cache_key.is_empty() or not is_instance_valid(data):
		return failure.call("bake_data_unavailable_fail_closed",
			"missing_cache_key_or_bake_data")
	if not _ensure_bake_resources(cache_key, data, version, rd):
		return failure.call("bake_resource_prepare_failed_fail_closed",
			"bake_resource_prepare_failed")
	var cached: Dictionary = _bake_resources.get(cache_key, {})
	var directional_value: Variant = cached.get("directional")
	if not directional_value is RefCounted:
		return failure.call("transfer_matrix_source_unavailable_fail_closed",
			"directional_cache_unavailable")
	var directional: RefCounted = directional_value
	if not directional.has_method("update_clv_inputs") \
			or not directional.has_method("get_clv_transfer_bindings") \
			or not directional.has_method("get_clv_input_revision"):
		return failure.call("transfer_matrix_api_unavailable_fail_closed",
			"directional_clv_input_api_unavailable")
	if not directional.call("update_clv_inputs", rd, _frame_snapshot):
		return failure.call("transfer_matrix_input_update_failed_fail_closed",
			"directional_clv_input_update_failed")
	var input_revision := int(directional.call("get_clv_input_revision"))
	var direct_inputs_value: Variant = directional.call("get_clv_transfer_bindings")
	if not direct_inputs_value is Dictionary:
		return failure.call("transfer_matrix_bindings_invalid_fail_closed",
			"directional_clv_bindings_not_dictionary")
	var direct_inputs: Dictionary = direct_inputs_value
	var emitter_count := int(direct_inputs.get("emitters", -1))
	if not _magicdawn_transfer_bindings_valid(direct_inputs) or emitter_count < 0:
		return failure.call("transfer_matrix_bindings_invalid_fail_closed",
			"transfer_sky_emission_source_rid_invalid", {"input_revision": input_revision})
	if not _update_emission_texture(cache_key, _frame_snapshot, data, rd):
		return failure.call("emission_texture_update_failed_fail_closed",
			"emission_texture_update_failed", {"lighting_revision": input_revision})
	if not _update_frame_ubo(_frame_snapshot, _frame_scene_data, view, rd):
		return failure.call("frame_ubo_update_failed_fail_closed",
			"frame_ubo_update_failed", {"lighting_revision": input_revision})
	var selected_resolution := _effective_clv_resolution(CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART)
	if selected_resolution != ClipmapCache.RESOLUTION \
			and selected_resolution != ClipmapCache.EXPANDED_RESOLUTION:
		return failure.call("unsupported_clv_resolution_fail_closed",
			"dynamic_layout9_requires_supported_resolution_16_or_24", {
			"requested_resolution": prt_clv_resolution,
			"selected_resolution": selected_resolution})
	var gpu_bytes := _clv_gpu_bytes_for_backend(CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART,
			selected_resolution, -1, 0, emitter_count)
	if gpu_bytes <= 0:
		return failure.call("dynamic_clv_memory_estimate_invalid_fail_closed",
			"dynamic_clv_memory_estimate_invalid", {"resolution": selected_resolution,
			"emitter_count": emitter_count})
	var clip_key := "%d:%d:%d:%s" % [buffers.get_instance_id(), view,
			CLV_MAGICDAWN_DYNAMIC_PRT_LAYOUT_VERSION, cache_key]
	if _clipmaps.has(clip_key):
		var previous_entry: Dictionary = _clipmaps[clip_key]
		if not _clipmap_layout_is_current(previous_entry,
				CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART, -1, emitter_count):
			var previous_cache: RefCounted = previous_entry.get("cache")
			if previous_cache != null:
				_free_rids(rd, previous_cache.owned_rids())
			_clipmaps.erase(clip_key)
			_sync_owned_rid_snapshot()
	if not _clipmaps.has(clip_key):
		var new_cache := ClipmapCache.new()
		if not new_cache.create(rd, selected_resolution, true, emitter_count):
			var create_state: Dictionary = new_cache.get_runtime_state() \
					if new_cache.has_method("get_runtime_state") else {}
			var create_error := str(create_state.get("relight_error",
					new_cache.get("_last_error")))
			_free_rids(rd, new_cache.owned_rids())
			_sync_owned_rid_snapshot()
			return failure.call("dynamic_clv_create_failed_fail_closed",
				"dynamic_clv_create_failed", {"cache_error": create_error,
				"cache_state": create_state, "resolution": selected_resolution,
				"emitter_count": emitter_count})
		var breakdown := ClipmapCache.estimate_gpu_bytes_breakdown(
				selected_resolution, true, emitter_count)
		if not new_cache.transfer_matrix.is_valid() \
				or int(breakdown.get("total_bytes", -1)) != gpu_bytes:
			_free_rids(rd, new_cache.owned_rids())
			_sync_owned_rid_snapshot()
			return failure.call("dynamic_clv_allocation_contract_failed_fail_closed",
				"transfer_matrix_or_memory_estimate_mismatch", {
					"cache_state": new_cache.get_runtime_state(),
					"estimated_gpu_bytes": gpu_bytes,
					"breakdown": breakdown})
		_clipmaps[clip_key] = {"cache": new_cache, "owner": weakref(buffers),
			"last_used": _cache_clock, "bake": cache_key,
			"view": view,
			"layout_version": CLV_MAGICDAWN_DYNAMIC_PRT_LAYOUT_VERSION,
			"cache_backend": CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART,
			"requested_resolution": selected_resolution,
			"resolution": int(new_cache.get("resolution")),
			"gpu_bytes": gpu_bytes, "dynamic_transfer": true,
			"emitter_count": emitter_count,
			"source_probe_count": int(direct_inputs.get("probes", 0)),
			"transfer_matrix_bytes": int(breakdown.get("transfer_matrix_bytes", 0)),
			"gpu_bytes_breakdown": breakdown.duplicate(true)}
		_sync_owned_rid_snapshot()
	var entry: Dictionary = _clipmaps[clip_key]
	entry["last_used"] = _cache_clock
	entry["view"] = view
	var clipmap: RefCounted = entry.get("cache")
	var spacing := float(_frame_snapshot.get("clv_cell_size", 0.25))
	if not is_finite(spacing) or spacing <= 0.0:
		return failure.call("invalid_clv_spacing_fail_closed", "nonpositive_clv_spacing",
			{"spacing_m": spacing})
	var source_bounds_value: Variant = cached.get("source_bounds", AABB())
	if not source_bounds_value is AABB or not _valid_clv_focus_bounds(source_bounds_value):
		return failure.call("invalid_source_bounds_fail_closed", "invalid_source_bounds")
	var camera_position: Vector3 = _frame_scene_data.get_cam_transform().origin
	var focus := ClipmapCache.focus_for_bounds(camera_position, source_bounds_value,
			spacing, int(clipmap.get("resolution")))
	var cluster_buffer := _cluster_binding_for_cache(cached, rd)
	if not cluster_buffer.is_valid():
		return failure.call("probe_cluster_unavailable_fail_closed",
			"probe_cluster_buffer_invalid")
	var clv_bake: Dictionary = cached
	if cluster_buffer != cached.get("probe_clusters", RID()):
		clv_bake = cached.duplicate(false)
		clv_bake["probe_clusters"] = cluster_buffer
	var geometry_epoch := _nonstream_clv_geometry_epoch(_frame_snapshot,
			cache_key, int(cached.get("data_id", -1)), version)
	_capture_gpu_timestamp(rd, "CLV Begin")
	var update_ok: bool = clipmap.update(rd, focus, spacing, geometry_epoch,
			input_revision, clv_bake, directional, _ubo, _sampler,
			int(_frame_snapshot.get("clv_cells_per_frame", 256)),
			approximate_clv_volume_enabled, false, false, true)
	if not update_ok:
		_capture_gpu_timestamp(rd, "CLV End")
		var update_state: Dictionary = clipmap.get_runtime_state()
		return failure.call("dynamic_clv_geometry_fill_failed_fail_closed",
			"layout9_transfer_matrix_fill_failed", {"lighting_revision": input_revision,
			"cache_state": update_state})
	_capture_gpu_timestamp(rd, "Relight Begin")
	var relight_ok: bool = clipmap.relight_resident(rd, _ubo, input_revision)
	_capture_gpu_timestamp(rd, "Relight End")
	_capture_gpu_timestamp(rd, "CLV End")
	if not relight_ok:
		var relight_failure_state: Dictionary = clipmap.get_runtime_state()
		return failure.call("resident_clv_relight_failed_fail_closed",
			"layout9_resident_relight_failed", {"lighting_revision": input_revision,
			"cache_state": relight_failure_state})
	var cache_state: Dictionary = clipmap.get_runtime_state()
	if not bool(cache_state.get("transfer_matrix_valid", false)) \
			or int(cache_state.get("transfer_matrix_emitters", -1)) != emitter_count \
			or int(cache_state.get("relight_lighting_revision", -1)) < input_revision \
			or bool(cache_state.get("relight_pending", true)):
		return failure.call("resident_clv_state_invalid_fail_closed",
			"resident_relight_revision_or_matrix_not_ready", {
				"lighting_revision": input_revision, "cache_state": cache_state})
	entry["gpu_bytes"] = gpu_bytes
	entry["emitter_count"] = emitter_count
	entry["source_probe_count"] = int(direct_inputs.get("probes", 0))
	entry["last_lighting_revision"] = input_revision
	_clipmaps[clip_key] = entry
	_frame_clipmap = clipmap
	_magicdawn_runtime_state.merge({
		"status": "resident_clv_relit",
		"cache_key": cache_key,
		"layout_version": CLV_MAGICDAWN_DYNAMIC_PRT_LAYOUT_VERSION,
		"resolution": int(clipmap.get("resolution")),
		"spacing_m": spacing,
		"source_probe_count": int(direct_inputs.get("probes", 0)),
		"emitter_count": emitter_count,
		"lighting_revision": input_revision,
		"completed_lighting_revision": int(cache_state.get("relight_lighting_revision", -1)),
		"dirty_blocks": int(cache_state.get("geometry_pending_blocks", 0)),
		"pending_blocks": int(cache_state.get("geometry_pending_blocks", 0)),
		"gpu_bytes": gpu_bytes,
		"transfer_matrix_bytes": int(cache_state.get("transfer_matrix_bytes", 0)),
		"gpu_bytes_breakdown": entry.get("gpu_bytes_breakdown", {}),
		"cache_state": cache_state.duplicate(true),
		"pixel_csr_fallback": false,
		"includes_direct_directional_light": false,
		"includes_primary_sky": true,
		"native_inputs_published": false,
		"renderer_path_active": false,
		"fallback_path": "disabled_fail_closed",
	}, true)
	_cache_clock += 1
	cached["last_used"] = _cache_clock
	_bake_resources[cache_key] = cached
	return true

func _magicdawn_transfer_bindings_valid(bindings: Dictionary) -> bool:
	for key in ["transfer", "sky", "emission", "sources"]:
		var value: Variant = bindings.get(key, RID())
		if not value is RID or not value.is_valid():
			return false
	return bool(bindings.get("sources_ready", false))

func _report_baked_sh_unready_once(data: Resource, reason: String) -> void:
	var resource_id := data.get_instance_id() if is_instance_valid(data) else 0
	var bake_version := int(data.get("bake_version")) if is_instance_valid(data) else -1
	var revision := int(data.get("baked_indirect_sh_revision")) if is_instance_valid(data) else -1
	var key := "%d:%d:%d:%s" % [resource_id, bake_version, revision, reason]
	if _magicdawn_unready_bake_warning_keys.has(key):
		return
	_magicdawn_unready_bake_warning_keys[key] = true
	_report(reason)

func _ensure_page_param_buffers(rd: RenderingDevice) -> bool:
	if not _page_params_ubo.is_valid():
		var zero := PackedByteArray()
		zero.resize(PAGE_PARAMS_SIZE)
		_page_params_ubo = rd.uniform_buffer_create(PAGE_PARAMS_SIZE, zero)
		_last_page_params_bytes = PackedByteArray()
	if not _pending_page_params_ubo.is_valid():
		var zero := PackedByteArray()
		zero.resize(PENDING_PARAMS_SIZE)
		_pending_page_params_ubo = rd.uniform_buffer_create(PENDING_PARAMS_SIZE, zero)
	return _page_params_ubo.is_valid() and _pending_page_params_ubo.is_valid()

func _append_matrix4(values: PackedFloat32Array, transform: Transform3D) -> void:
	for axis in [transform.basis.x, transform.basis.y, transform.basis.z, transform.origin]:
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]))
	values[values.size() - 1] = 1.0

func _write_page_params(rd: RenderingDevice, core: AABB, rect: Rect2i,
		snapshot: Dictionary, enabled: bool) -> bool:
	var owner_transform: Variant = snapshot.get("owner_transform", Transform3D.IDENTITY)
	var owner_size: Variant = snapshot.get("owner_size", Vector3.ZERO)
	var has_owner: bool = owner_transform is Transform3D and owner_size is Vector3 \
			and owner_size.x > 0.0 and owner_size.y > 0.0 and owner_size.z > 0.0
	var bytes := PackedByteArray()
	bytes.append_array(PackedFloat32Array([core.position.x, core.position.y, core.position.z, 1.0 if enabled else 0.0]).to_byte_array())
	var core_max := core.position + core.size
	bytes.append_array(PackedFloat32Array([core_max.x, core_max.y, core_max.z, 0.0]).to_byte_array())
	bytes.append_array(PackedInt32Array([rect.position.x, rect.position.y, rect.size.x, rect.size.y]).to_byte_array())
	var inverse: Transform3D = owner_transform.affine_inverse() if has_owner else Transform3D.IDENTITY
	var matrix := PackedFloat32Array()
	_append_matrix4(matrix, inverse)
	bytes.append_array(matrix.to_byte_array())
	bytes.append_array(PackedFloat32Array([owner_size.x if has_owner else 0.0,
		owner_size.y if has_owner else 0.0, owner_size.z if has_owner else 0.0, 1.0 if has_owner else 0.0]).to_byte_array())
	if bytes.size() != PAGE_PARAMS_SIZE:
		return false
	if bytes == _last_page_params_bytes:
		return true
	if rd.buffer_update(_page_params_ubo, 0, PAGE_PARAMS_SIZE, bytes) != OK:
		return false
	_last_page_params_bytes = bytes
	return true

func _write_pending_page_params(rd: RenderingDevice, core: AABB, rect: Rect2i,
		snapshot: Dictionary, enabled: bool, ownership: float) -> bool:
	var scene_data := _frame_scene_data
	if scene_data == null:
		return false
	var inverse_projection: Projection = scene_data.get_view_projection(_active_render_view).inverse()
	var camera: Transform3D = scene_data.get_cam_transform()
	var owner_transform: Variant = snapshot.get("owner_transform", Transform3D.IDENTITY)
	var owner_size: Variant = snapshot.get("owner_size", Vector3.ZERO)
	var has_owner: bool = owner_transform is Transform3D and owner_size is Vector3 \
			and owner_size.x > 0.0 and owner_size.y > 0.0 and owner_size.z > 0.0
	var bytes := PackedByteArray()
	var projection_values := PackedFloat32Array()
	_append_projection(projection_values, inverse_projection)
	bytes.append_array(projection_values.to_byte_array())
	var camera_values := PackedFloat32Array()
	_append_transform(camera_values, Transform3D(camera.basis.orthonormalized(), camera.origin))
	bytes.append_array(camera_values.to_byte_array())
	bytes.append_array(PackedFloat32Array([core.position.x, core.position.y, core.position.z, 1.0 if enabled else 0.0]).to_byte_array())
	var core_max := core.position + core.size
	bytes.append_array(PackedFloat32Array([core_max.x, core_max.y, core_max.z, ownership]).to_byte_array())
	bytes.append_array(PackedInt32Array([rect.position.x, rect.position.y, rect.size.x, rect.size.y]).to_byte_array())
	var inverse_owner: Transform3D = owner_transform.affine_inverse() if has_owner else Transform3D.IDENTITY
	var owner_values := PackedFloat32Array()
	_append_matrix4(owner_values, inverse_owner)
	bytes.append_array(owner_values.to_byte_array())
	bytes.append_array(PackedFloat32Array([owner_size.x if has_owner else 0.0,
		owner_size.y if has_owner else 0.0, owner_size.z if has_owner else 0.0, 1.0 if has_owner else 0.0]).to_byte_array())
	return bytes.size() == PENDING_PARAMS_SIZE \
			and rd.buffer_update(_pending_page_params_ubo, 0, PENDING_PARAMS_SIZE, bytes) == OK

var _active_render_view := 0

func _ensure_shader(rd: RenderingDevice) -> bool:
	if shader_file == MAGIC_GI_APPLY_SHADER \
			or (_layout14_b_apply_shader_resource != null \
				and shader_file == _layout14_b_apply_shader_resource):
		# Make all current defaults explicit once. Legacy leaves all stage flags false.
		var spec_defaults := {0: true, 1: false, 2: false, 3: false,
				4: false, 6: false, 7: false}
		for constant_id_value in spec_defaults:
			var constant_id := int(constant_id_value)
			var default_value: bool = bool(spec_defaults[constant_id])
			if constant_id in [MAGIC_GI_PRT_CACHE_GENERAL_SPEC_ID,
					MAGIC_GI_PRT_SOURCE_ONLY_SPEC_ID, MAGIC_GI_PRT_CERT_ONLY_SPEC_ID,
					MAGIC_GI_PRT_GENERAL_ONLY_SPEC_ID]:
				if not shader_keywords.has(constant_id) or shader_keywords[constant_id] != false:
					set_shader_keyword(constant_id, false)
			elif not shader_keywords.has(constant_id):
				set_shader_keyword(constant_id, default_value)
	var current_shader := false
	if shader_file != null:
		var requested_spirv = shader_file.get_spirv()
		current_shader = requested_spirv != null and _shader.is_valid() \
				and _shader_resource == shader_file and _spirv == requested_spirv \
				and _shader_mode == mode and _keyword_signature == _keyword_signature_now()
	if not current_shader:
		_clear_prt_stage_pipeline_cache(rd)
	var shader_ready := super._ensure_shader(rd)
	if shader_ready:
		return true
	if shader_file == _layout14_b_apply_shader_resource \
			and _layout14_b_frame_active:
		# A valid SPIR-V blob does not guarantee that this device can create its
		# shader or pipeline. Fail closed to the ordinary source gather instead of
		# returning from the pass with no GI output.
		_layout14_b_apply_runtime_rejected = true
		_layout14_b_error = "apply_pipeline_creation_failed_source_fallback"
		_set_layout14_b_frame_active(false)
		_frame_clipmap = null
		return super._ensure_shader(rd)
	return false

func _clear_prt_stage_pipeline_cache(rd: RenderingDevice) -> void:
	if rd != null and not _prt_stage_pipelines.is_empty():
		var pipelines: Array[RID] = []
		for pipeline_value in _prt_stage_pipelines.values():
			pipelines.append(pipeline_value)
		_free_rids(rd, pipelines)
	_prt_stage_pipelines.clear()
	_prt_stage_pipeline_specialization_values.clear()
	_prt_stage_pipeline_signature = ""
	_sync_owned_rid_snapshot()

func _prt_stage_specialization_values(stage: int) -> Dictionary:
	var values: Dictionary = shader_keywords.duplicate()
	# Keep this complete even before the first base pipeline is created.
	if not values.has(MAGIC_GI_FULL_FEATURES_SPEC_ID):
		values[MAGIC_GI_FULL_FEATURES_SPEC_ID] = true
	if not values.has(2):
		values[2] = false
	if not values.has(3):
		values[3] = false
	for constant_id in [MAGIC_GI_PRT_CACHE_GENERAL_SPEC_ID,
			MAGIC_GI_PRT_SOURCE_ONLY_SPEC_ID, MAGIC_GI_PRT_CERT_ONLY_SPEC_ID,
			MAGIC_GI_PRT_GENERAL_ONLY_SPEC_ID]:
		if not values.has(constant_id):
			values[constant_id] = false
	values[MAGIC_GI_PRT_CACHE_GENERAL_SPEC_ID] = stage in [
			MAGIC_GI_PRT_STAGE_CACHE_GENERAL, MAGIC_GI_PRT_STAGE_THREE_SOURCE]
	values[MAGIC_GI_PRT_SOURCE_ONLY_SPEC_ID] = stage in [
			MAGIC_GI_PRT_STAGE_SOURCE, MAGIC_GI_PRT_STAGE_THREE_SOURCE]
	values[MAGIC_GI_PRT_CERT_ONLY_SPEC_ID] = stage == MAGIC_GI_PRT_STAGE_CERT_ONLY
	values[MAGIC_GI_PRT_GENERAL_ONLY_SPEC_ID] = stage == MAGIC_GI_PRT_STAGE_GENERAL_ONLY
	return values

func _prt_stage_specialization(values: Dictionary) -> Array:
	var ids := values.keys()
	ids.sort()
	var constants: Array = []
	for constant_id in ids:
		var constant := RDPipelineSpecializationConstant.new()
		constant.constant_id = int(constant_id)
		constant.value = values[constant_id]
		constants.append(constant)
	return constants

func _prt_stage_ids(three_stage: bool) -> Array:
	if three_stage:
		return [MAGIC_GI_PRT_STAGE_CERT_ONLY, MAGIC_GI_PRT_STAGE_GENERAL_ONLY,
				MAGIC_GI_PRT_STAGE_THREE_SOURCE]
	return [MAGIC_GI_PRT_STAGE_CACHE_GENERAL, MAGIC_GI_PRT_STAGE_SOURCE]

func _prt_stage_name(stage: int) -> String:
	match stage:
		MAGIC_GI_PRT_STAGE_CACHE_GENERAL:
			return "cache_general"
		MAGIC_GI_PRT_STAGE_SOURCE:
			return "source_only"
		MAGIC_GI_PRT_STAGE_CERT_ONLY:
			return "v3_cert_only"
		MAGIC_GI_PRT_STAGE_GENERAL_ONLY:
			return "v3_general_only"
		MAGIC_GI_PRT_STAGE_THREE_SOURCE:
			return "v3_source_only"
	return "unknown"

func _ensure_prt_stage_pipelines(rd: RenderingDevice, three_stage: bool) -> bool:
	if not _shader.is_valid():
		return false
	var stage_ids := _prt_stage_ids(three_stage)
	var stage_set := "three" if three_stage else "two"
	var signature := "%d|%s|%s" % [_shader.get_id(), _keyword_signature_now(), stage_set]
	if _prt_stage_pipeline_signature != signature:
		_clear_prt_stage_pipeline_cache(rd)
		_prt_stage_pipeline_signature = signature
		for stage in stage_ids:
			var specialization_values := _prt_stage_specialization_values(stage)
			var pipeline: RID = rd.compute_pipeline_create(_shader,
					_prt_stage_specialization(specialization_values))
			if not pipeline.is_valid():
				_clear_prt_stage_pipeline_cache(rd)
				_report("Cannot create staged PRT compute pipeline (%s)." % _prt_stage_name(stage))
				return false
			_prt_stage_pipelines[stage] = pipeline
			_prt_stage_pipeline_specialization_values[stage] = specialization_values
		_sync_owned_rid_snapshot()
	for stage in stage_ids:
		if not _prt_stage_pipelines.has(stage):
			return false
	return true

func _prt_stage_pipeline_metadata() -> Dictionary:
	var keyword_signature := _keyword_signature_now()
	var current_signature := ""
	var shader_rid := 0
	var shader_state_matches := false
	if _shader.is_valid():
		shader_rid = _shader.get_id()
		current_signature = "%d|%s" % [shader_rid, keyword_signature]
		shader_state_matches = _shader_resource == shader_file and _shader_mode == mode \
				and _keyword_signature == keyword_signature
		if shader_file != null:
			shader_state_matches = shader_state_matches and _spirv == shader_file.get_spirv()
	var legacy_pipeline: RID = _compute_pipeline
	var active_sequence: Array = ["legacy"]
	if _last_prt_three_stage_active:
		active_sequence = ["cert_only", "general_only", "source_only"]
	elif _last_prt_two_stage_active:
		active_sequence = ["cache_general", "source_only"]
	var metadata := {
		"shader_rid": shader_rid,
		"keyword_signature": keyword_signature,
		"cache_signature": _prt_stage_pipeline_signature,
		"active_pipeline_sequence": active_sequence,
		"legacy": {
			"rid": legacy_pipeline.get_id() if legacy_pipeline.is_valid() else 0,
			"specialization_values": _prt_stage_specialization_values(MAGIC_GI_PRT_STAGE_LEGACY),
			"signature": current_signature,
			"signature_matches": shader_state_matches and legacy_pipeline.is_valid(),
		},
	}
	for stage in [MAGIC_GI_PRT_STAGE_CACHE_GENERAL, MAGIC_GI_PRT_STAGE_SOURCE,
			MAGIC_GI_PRT_STAGE_CERT_ONLY, MAGIC_GI_PRT_STAGE_GENERAL_ONLY,
			MAGIC_GI_PRT_STAGE_THREE_SOURCE]:
		if not _prt_stage_pipelines.has(stage):
			continue
		var name := _prt_stage_name(stage)
		var pipeline: RID = _prt_stage_pipelines.get(stage, RID())
		var actual_values: Dictionary = _prt_stage_pipeline_specialization_values.get(stage, {})
		var expected_values := _prt_stage_specialization_values(stage)
		var stage_set := "three" if stage in [MAGIC_GI_PRT_STAGE_CERT_ONLY,
				MAGIC_GI_PRT_STAGE_GENERAL_ONLY, MAGIC_GI_PRT_STAGE_THREE_SOURCE] else "two"
		var expected_signature := "%s|%s" % [current_signature, stage_set]
		metadata[name] = {
			"rid": pipeline.get_id() if pipeline.is_valid() else 0,
			"specialization_values": actual_values.duplicate(true),
			"signature": _prt_stage_pipeline_signature,
			"signature_matches": shader_state_matches and pipeline.is_valid() \
					and _prt_stage_pipeline_signature == expected_signature \
					and actual_values == expected_values,
		}
	return metadata

func _ensure_prt_source_pending_texture(rd: RenderingDevice, size: Vector2i) -> RID:
	if size.x <= 0 or size.y <= 0:
		return RID()
	if _prt_source_pending_texture.is_valid() and rd.texture_is_valid(_prt_source_pending_texture) \
			and _prt_source_pending_size == size:
		return _prt_source_pending_texture
	if _prt_source_pending_texture.is_valid():
		_free_rids(rd, [_prt_source_pending_texture])
	_prt_source_pending_texture = RID()
	_prt_source_pending_size = Vector2i.ZERO
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R32_UINT
	format.width = size.x
	format.height = size.y
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_prt_source_pending_texture = rd.texture_create(format, RDTextureView.new(), [])
	if not _prt_source_pending_texture.is_valid():
		_sync_owned_rid_snapshot()
		_report("Cannot create PRT source-pending classification texture.")
		return RID()
	_prt_source_pending_size = size
	_sync_owned_rid_snapshot()
	return _prt_source_pending_texture

func _can_use_prt_two_stage() -> bool:
	return prt_two_stage_source_fallback_enabled and mode == Mode.COMPUTE \
			and not native_clv_lighting_enabled and not _frame_native_clv_fallback_only \
			and _frame_prt_scale == 1 \
			and not _stream_dispatch_active and not bool(_frame_snapshot.get("streamed", false)) \
			and clv_debug_view == CLVDebugView.OFF and not _prt_raw_debug_output \
			and not _clv_stats_capture_armed and not _clv_stats_capture_active \
			and not approximate_clv_volume_enabled and not exact_clv_corner_visibility_enabled \
			and prt_surface_exact_debug_mode == 0

func _can_use_prt_three_stage() -> bool:
	return prt_three_stage_source_fallback_enabled and mode == Mode.COMPUTE \
			and not native_clv_lighting_enabled and not _frame_native_clv_fallback_only \
			and _frame_prt_scale == 1 \
			and not _stream_dispatch_active and not bool(_frame_snapshot.get("streamed", false)) \
			and clv_debug_view == CLVDebugView.OFF and not _prt_raw_debug_output \
			and not _clv_stats_capture_armed and not _clv_stats_capture_active \
			and not approximate_clv_volume_enabled and not exact_clv_corner_visibility_enabled \
			and prt_surface_exact_debug_mode == 0

func _prt_compact_eligibility_reason() -> String:
	if shader_file != MAGIC_GI_APPLY_SHADER:
		return "unexpected_apply_shader"
	if mode != Mode.COMPUTE:
		return "mode_not_compute"
	if _frame_prt_scale != 1:
		return "scaled_prt_application"
	if _stream_dispatch_active:
		return "stream_dispatch"
	if native_clv_lighting_enabled or _frame_native_clv_fallback_only:
		return "native_clv_lighting"
	if bool(_frame_snapshot.get("streamed", false)):
		return "streamed_source"
	if clv_debug_view != CLVDebugView.OFF or _prt_raw_debug_output:
		return "debug_view"
	if _clv_stats_capture_armed or _clv_stats_capture_active:
		return "clv_stats_capture"
	if approximate_clv_volume_enabled or exact_clv_corner_visibility_enabled:
		return "approximate_or_exact_clv_mode"
	if prt_surface_exact_debug_mode != 0:
		return "exact_surface_debug"
	if workgroup_size != Vector2i(MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE,
			MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE):
		return "unsupported_workgroup_size"
	return ""

func _prt_compact_capability(rd: RenderingDevice) -> Dictionary:
	if rd == null:
		return {"supported": false, "reason": "rendering_device_unavailable"}
	var names := [
		"LIMIT_SUBGROUP_SIZE", "LIMIT_SUBGROUP_IN_SHADERS", "LIMIT_SUBGROUP_OPERATIONS",
		"SHADER_STAGE_COMPUTE_BIT", "SUBGROUP_BASIC_BIT", "SUBGROUP_BALLOT_BIT",
		"LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X", "LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_Y",
		"LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_Z",
	]
	var constants: Dictionary = {}
	var missing: Array[String] = []
	for name in names:
		var constant_name := StringName(name)
		if not ClassDB.class_has_integer_constant(&"RenderingDevice", constant_name):
			missing.append(name)
		else:
			constants[name] = ClassDB.class_get_integer_constant(&"RenderingDevice", constant_name)
	if not missing.is_empty():
		return {"supported": false, "reason": "missing_rendering_device_constants",
			"missing_constants": missing}
	var subgroup_size := int(rd.limit_get(int(constants["LIMIT_SUBGROUP_SIZE"])))
	var stage_flags := int(rd.limit_get(int(constants["LIMIT_SUBGROUP_IN_SHADERS"])))
	var operation_flags := int(rd.limit_get(int(constants["LIMIT_SUBGROUP_OPERATIONS"])))
	var compute_stage := int(constants["SHADER_STAGE_COMPUTE_BIT"])
	var required_operations := int(constants["SUBGROUP_BASIC_BIT"]) \
			| int(constants["SUBGROUP_BALLOT_BIT"])
	var max_groups_x := int(rd.limit_get(int(constants["LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X"])))
	var max_groups_y := int(rd.limit_get(int(constants["LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_Y"])))
	var max_groups_z := int(rd.limit_get(int(constants["LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_Z"])))
	if subgroup_size <= 0:
		return {"supported": false, "reason": "subgroup_size_unavailable",
			"subgroup_size": subgroup_size}
	if (stage_flags & compute_stage) == 0:
		return {"supported": false, "reason": "subgroup_compute_stage_unavailable",
			"subgroup_size": subgroup_size, "subgroup_stage_flags": stage_flags}
	if (operation_flags & required_operations) != required_operations:
		return {"supported": false, "reason": "subgroup_basic_ballot_unavailable",
			"subgroup_size": subgroup_size, "subgroup_operation_flags": operation_flags,
			"required_subgroup_operations": required_operations}
	return {"supported": true, "reason": "", "subgroup_size": subgroup_size,
		"subgroup_stage_flags": stage_flags, "subgroup_operation_flags": operation_flags,
		"required_subgroup_operations": required_operations,
		"max_compute_workgroup_count_x": max_groups_x,
		"max_compute_workgroup_count_y": max_groups_y,
		"max_compute_workgroup_count_z": max_groups_z}

func _prt_compact_specialization_values(cert_only: bool) -> Dictionary:
	var values: Dictionary = shader_keywords.duplicate()
	var defaults := {
		MAGIC_GI_FULL_FEATURES_SPEC_ID: true,
		MAGIC_GI_PRT_CACHE_GENERAL_SPEC_ID: false,
		2: false,
		3: false,
		MAGIC_GI_PRT_SOURCE_ONLY_SPEC_ID: false,
		MAGIC_GI_PRT_CERT_ONLY_SPEC_ID: false,
		MAGIC_GI_PRT_GENERAL_ONLY_SPEC_ID: false,
		MAGIC_GI_PRT_QUEUE_CONSUMER_SPEC_ID: false,
	}
	for constant_id in defaults:
		if not values.has(constant_id):
			values[constant_id] = defaults[constant_id]
	# V4 uses one cert producer and one general/source consumer. Keep all unrelated
	# authored specialization values intact while disabling the legacy split flags.
	values[MAGIC_GI_PRT_CACHE_GENERAL_SPEC_ID] = false
	values[MAGIC_GI_PRT_SOURCE_ONLY_SPEC_ID] = false
	values[MAGIC_GI_PRT_CERT_ONLY_SPEC_ID] = cert_only
	values[MAGIC_GI_PRT_GENERAL_ONLY_SPEC_ID] = not cert_only
	values[MAGIC_GI_PRT_QUEUE_CONSUMER_SPEC_ID] = not cert_only
	return values

func _prt_compact_specialization(values: Dictionary) -> Array:
	return _prt_stage_specialization(values)

func _prt_compact_rid_id(rid: RID) -> int:
	return rid.get_id() if rid.is_valid() else 0

func _prt_compact_pipeline_is_valid(rd: RenderingDevice, pipeline: RID) -> bool:
	return rd != null and pipeline.is_valid() and rd.compute_pipeline_is_valid(pipeline)

func _prt_compact_metadata_base(eligible: bool, reason: String,
		dispatch_size := Vector2i.ZERO, active := false) -> Dictionary:
	var pixel_count := maxi(dispatch_size.x, 0) * maxi(dispatch_size.y, 0)
	var cert_pipeline: RID = _prt_compact_pipelines.get("cert_only", RID())
	var consumer_pipeline: RID = _prt_compact_pipelines.get("general_queue_consumer", RID())
	var expected_pipeline_signature := ""
	if _prt_compact_shader.is_valid():
		expected_pipeline_signature = "%s|shader=%d|keywords=%s" % [
			MAGIC_GI_PRT_QUEUE_APPLY_SHADER_PATH,
			_prt_compact_shader.get_id(), _keyword_signature_now()]
	var expected_cert_values := _prt_compact_specialization_values(true)
	var expected_consumer_values := _prt_compact_specialization_values(false)
	var actual_cert_values: Dictionary = _prt_compact_pipeline_specialization_values.get("cert_only", {})
	var actual_consumer_values: Dictionary = _prt_compact_pipeline_specialization_values.get(
			"general_queue_consumer", {})
	var expected_finalize_signature := ""
	if _prt_compact_finalize_shader.is_valid():
		expected_finalize_signature = "%s|shader=%d|specialization=none" % [
			MAGIC_GI_PRT_QUEUE_FINALIZE_SHADER_PATH,
			_prt_compact_finalize_shader.get_id()]
	var active_stages: Array = []
	var psos := {
		"cert_only": {
			"rid": _prt_compact_rid_id(cert_pipeline),
			"valid": _prt_compact_pipeline_is_valid(
					RenderingServer.get_rendering_device(), cert_pipeline),
			"specialization_values": actual_cert_values.duplicate(true),
			"expected_specialization_values": expected_cert_values,
			"signature": _prt_compact_pipeline_signature + "|stage=cert_only",
			"signature_matches": cert_pipeline.is_valid() \
					and _prt_compact_pipeline_signature == expected_pipeline_signature \
					and actual_cert_values == expected_cert_values,
		},
		"general_queue_consumer": {
			"rid": _prt_compact_rid_id(consumer_pipeline),
			"valid": _prt_compact_pipeline_is_valid(
					RenderingServer.get_rendering_device(), consumer_pipeline),
			"specialization_values": actual_consumer_values.duplicate(true),
			"expected_specialization_values": expected_consumer_values,
			"signature": _prt_compact_pipeline_signature + "|stage=general_queue_consumer",
			"signature_matches": consumer_pipeline.is_valid() \
					and _prt_compact_pipeline_signature == expected_pipeline_signature \
					and actual_consumer_values == expected_consumer_values,
		},
		"finalize": {
			"rid": _prt_compact_rid_id(_prt_compact_finalize_pipeline),
			"valid": _prt_compact_pipeline_is_valid(RenderingServer.get_rendering_device(),
					_prt_compact_finalize_pipeline),
			"specialization_values": {},
			"signature": _prt_compact_finalize_pipeline_signature,
			"expected_signature": expected_finalize_signature,
			"signature_matches": _prt_compact_finalize_pipeline.is_valid() \
					and _prt_compact_finalize_pipeline_signature == expected_finalize_signature,
		},
	}
	var pipeline_signatures := {
		"cert_only": {
			"shader_resource": MAGIC_GI_PRT_QUEUE_APPLY_SHADER_PATH,
			"shader_rid": _prt_compact_rid_id(_prt_compact_shader),
			"specialization_values": actual_cert_values.duplicate(true),
			"signature": psos["cert_only"]["signature"],
			"valid": psos["cert_only"]["valid"] \
					and psos["cert_only"]["signature_matches"],
		},
		"general_queue_consumer": {
			"shader_resource": MAGIC_GI_PRT_QUEUE_APPLY_SHADER_PATH,
			"shader_rid": _prt_compact_rid_id(_prt_compact_shader),
			"specialization_values": actual_consumer_values.duplicate(true),
			"signature": psos["general_queue_consumer"]["signature"],
			"valid": psos["general_queue_consumer"]["valid"] \
					and psos["general_queue_consumer"]["signature_matches"],
		},
		"finalize": {
			"shader_resource": MAGIC_GI_PRT_QUEUE_FINALIZE_SHADER_PATH,
			"shader_rid": _prt_compact_rid_id(_prt_compact_finalize_shader),
			"specialization_values": {},
			"signature": psos["finalize"]["signature"],
			"valid": psos["finalize"]["valid"] \
					and psos["finalize"]["signature_matches"],
		},
	}
	var pipeline_valid := bool(pipeline_signatures["cert_only"]["valid"]) \
			and bool(pipeline_signatures["general_queue_consumer"]["valid"]) \
			and bool(pipeline_signatures["finalize"]["valid"])
	var bindings := {
		"source_pending_marker": MAGIC_GI_SOURCE_PENDING_BINDING,
		"miss_pixel_queue": MAGIC_GI_PRT_MISS_QUEUE_BINDING,
		"queue_control": MAGIC_GI_PRT_MISS_QUEUE_CONTROL_BINDING,
		"finalize_control": 0,
		"finalize_indirect_args": 1,
	}
	if active:
		active_stages = ["cert_only", "general_queue_consumer"]
	return {
		"enabled": prt_compact_miss_queue_enabled,
		"eligible": eligible,
		"active": active,
		"fallback_reason": reason,
		"dispatch_frame": _prt_compact_dispatch_frame,
		"shader_resource": MAGIC_GI_PRT_QUEUE_APPLY_SHADER_PATH,
		"shader_rid": _prt_compact_rid_id(_prt_compact_shader),
		"shader_signature": _prt_compact_pipeline_signature,
		"capability": _prt_compact_last_capability.duplicate(true),
		"finalize_shader_resource": MAGIC_GI_PRT_QUEUE_FINALIZE_SHADER_PATH,
		"finalize_shader_rid": _prt_compact_rid_id(_prt_compact_finalize_shader),
		"active_stages": active_stages,
		"pipeline_valid": pipeline_valid,
		"pipeline_signatures": pipeline_signatures,
		"psos": psos,
		"rids": {
			"apply_shader": _prt_compact_rid_id(_prt_compact_shader),
			"finalize_shader": _prt_compact_rid_id(_prt_compact_finalize_shader),
			"cert_only": _prt_compact_rid_id(cert_pipeline),
			"general_queue_consumer": _prt_compact_rid_id(consumer_pipeline),
			"finalize": _prt_compact_rid_id(_prt_compact_finalize_pipeline),
			"queue": _prt_compact_rid_id(_prt_compact_queue_buffer),
			"control": _prt_compact_rid_id(_prt_compact_queue_control_buffer),
			"indirect_args": _prt_compact_rid_id(_prt_compact_indirect_args_buffer),
			"finalize_uniform_set": _prt_compact_rid_id(_prt_compact_finalize_uniform_set),
		},
		"specialization_values": {
			"cert_only": _prt_compact_pipeline_specialization_values.get(
					"cert_only", {}).duplicate(true),
			"general_queue_consumer": _prt_compact_pipeline_specialization_values.get(
					"general_queue_consumer", {}).duplicate(true),
		},
		"queue_capacity_pixels": _prt_compact_queue_capacity_pixels,
		"queue_capacity_bytes": _prt_compact_queue_capacity_pixels * 4,
		"control_buffer_bytes": MAGIC_GI_PRT_QUEUE_CONTROL_BYTES,
		"indirect_args_buffer_bytes": MAGIC_GI_PRT_QUEUE_INDIRECT_BYTES,
		"dispatch_size": [dispatch_size.x, dispatch_size.y],
		"full_view_groups": [
			ceili(float(dispatch_size.x) / float(MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE)),
			ceili(float(dispatch_size.y) / float(MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE)), 1,
		],
		"bindings": bindings,
		"indirect_dispatch_calls": 1 if active else 0,
		"overflow_recovery": "full_view_marker_scan",
		"queue_count": {"status": "not_read_back"},
		"overflow": {"status": "not_read_back"},
		"indirect_dimensions": {"status": "not_read_back"},
	}

func _record_prt_compact_fallback(reason: String, eligible: bool,
		dispatch_size := Vector2i.ZERO) -> void:
	_prt_compact_queue_metadata = _prt_compact_metadata_base(eligible, reason, dispatch_size)

func _prt_compact_ceil_div(value: int, divisor: int) -> int:
	if value <= 0 or divisor <= 0:
		return 0
	var quotient := floori(float(value) / float(divisor))
	return quotient + (1 if value % divisor != 0 else 0)

func _clear_prt_compact_apply_program(rd: RenderingDevice) -> void:
	if rd != null:
		var pipelines: Array[RID] = []
		for pipeline_value in _prt_compact_pipelines.values():
			pipelines.append(pipeline_value)
		_free_rids(rd, pipelines)
		_free_rids(rd, [_prt_compact_shader])
	_prt_compact_pipelines.clear()
	_prt_compact_pipeline_specialization_values.clear()
	_prt_compact_pipeline_signature = ""
	_native_general_queue_consumer_signature = ""
	_prt_compact_shader = RID()
	_prt_compact_shader_spirv = null
	_sync_owned_rid_snapshot()

func _clear_prt_compact_finalize_program(rd: RenderingDevice) -> void:
	if rd != null:
		_free_rids(rd, [_prt_compact_finalize_uniform_set, _prt_compact_finalize_pipeline,
			_prt_compact_finalize_shader])
	_prt_compact_finalize_uniform_set = RID()
	_prt_compact_finalize_uniform_set_signature = ""
	_prt_compact_finalize_pipeline = RID()
	_prt_compact_finalize_pipeline_signature = ""
	_prt_compact_finalize_shader = RID()
	_prt_compact_finalize_shader_spirv = null
	_sync_owned_rid_snapshot()

func _clear_prt_compact_queue_buffers(rd: RenderingDevice) -> void:
	if rd != null:
		_free_rids(rd, [_prt_compact_finalize_uniform_set, _prt_compact_queue_buffer,
			_prt_compact_queue_control_buffer, _prt_compact_indirect_args_buffer])
	_prt_compact_finalize_uniform_set = RID()
	_prt_compact_finalize_uniform_set_signature = ""
	_prt_compact_queue_buffer = RID()
	_prt_compact_queue_control_buffer = RID()
	_prt_compact_indirect_args_buffer = RID()
	_prt_compact_queue_capacity_pixels = 0
	_sync_owned_rid_snapshot()

func _load_optional_rd_shader(path: String) -> RDShaderFile:
	if not ResourceLoader.exists(path):
		return null
	var resource: Resource = ResourceLoader.load(path)
	if resource is RDShaderFile:
		return resource as RDShaderFile
	return null

func _ensure_prt_compact_apply_program(rd: RenderingDevice) -> bool:
	if _prt_compact_shader_resource == null:
		_prt_compact_shader_resource = _load_optional_rd_shader(MAGIC_GI_PRT_QUEUE_APPLY_SHADER_PATH)
	if _prt_compact_shader_resource == null:
		return false
	var spirv: RDShaderSPIRV = _prt_compact_shader_resource.get_spirv()
	if spirv == null or _prt_compact_shader_resource.base_error != "" \
			or spirv.bytecode_compute.is_empty() or spirv.compile_error_compute != "":
		return false
	if not _prt_compact_shader.is_valid() or _prt_compact_shader_spirv != spirv:
		_clear_prt_compact_apply_program(rd)
		_prt_compact_shader = rd.shader_create_from_spirv(spirv)
		if not _prt_compact_shader.is_valid():
			_clear_prt_compact_apply_program(rd)
			return false
		_prt_compact_shader_spirv = spirv
		_sync_owned_rid_snapshot()
	var base_signature := "%s|shader=%d|keywords=%s" % [
		MAGIC_GI_PRT_QUEUE_APPLY_SHADER_PATH,
		_prt_compact_shader.get_id(), _keyword_signature_now()]
	var cert_existing: RID = _prt_compact_pipelines.get("cert_only", RID())
	var consumer_existing: RID = _prt_compact_pipelines.get("general_queue_consumer", RID())
	var pipelines_ready := cert_existing.is_valid() and consumer_existing.is_valid()
	pipelines_ready = pipelines_ready and rd.compute_pipeline_is_valid(cert_existing) \
			and rd.compute_pipeline_is_valid(consumer_existing)
	if _prt_compact_pipeline_signature != base_signature or not pipelines_ready:
		var pipelines: Array[RID] = []
		for pipeline_value in _prt_compact_pipelines.values():
			pipelines.append(pipeline_value)
		_free_rids(rd, pipelines)
		_prt_compact_pipelines.clear()
		_prt_compact_pipeline_specialization_values.clear()
		_prt_compact_pipeline_signature = ""
		for stage_name in ["cert_only", "general_queue_consumer"]:
			var cert_only: bool = stage_name == "cert_only"
			var specialization_values := _prt_compact_specialization_values(cert_only)
			var pipeline: RID = rd.compute_pipeline_create(_prt_compact_shader,
					_prt_compact_specialization(specialization_values))
			if not pipeline.is_valid() or not rd.compute_pipeline_is_valid(pipeline):
				_clear_prt_compact_apply_program(rd)
				return false
			_prt_compact_pipelines[stage_name] = pipeline
			_prt_compact_pipeline_specialization_values[stage_name] = specialization_values
		_prt_compact_pipeline_signature = base_signature
		_sync_owned_rid_snapshot()
	var cert_pipeline: RID = _prt_compact_pipelines["cert_only"]
	var consumer_pipeline: RID = _prt_compact_pipelines["general_queue_consumer"]
	return rd.compute_pipeline_is_valid(cert_pipeline) \
			and rd.compute_pipeline_is_valid(consumer_pipeline)

func _native_general_queue_consumer_values() -> Dictionary:
	var values := _prt_stage_specialization_values(MAGIC_GI_PRT_STAGE_SOURCE)
	# The deferred variant is deliberately limited to the exact, non-diagnostic
	# fast sampler. The source consumer keeps the same ordinary specialization.
	values[MAGIC_GI_FULL_FEATURES_SPEC_ID] = false
	values[2] = false
	values[3] = false
	values[5] = false
	values[MAGIC_GI_PRT_QUEUE_CONSUMER_SPEC_ID] = true
	return values

func _ensure_prt_native_general_queue_consumer(rd: RenderingDevice) -> bool:
	if not _ensure_prt_compact_apply_program(rd):
		return false
	var values := _native_general_queue_consumer_values()
	var signature := "%s|stage=native_general_source_queue|values=%s" % [
		_prt_compact_pipeline_signature, str(values)]
	var existing: RID = _prt_compact_pipelines.get("native_general_source_queue", RID())
	if existing.is_valid() and rd.compute_pipeline_is_valid(existing) \
			and _native_general_queue_consumer_signature == signature \
			and _prt_compact_pipeline_specialization_values.get(
				"native_general_source_queue", {}) == values:
		return true
	if existing.is_valid():
		_free_rids(rd, [existing])
	_prt_compact_pipelines.erase("native_general_source_queue")
	_prt_compact_pipeline_specialization_values.erase("native_general_source_queue")
	_native_general_queue_consumer_signature = ""
	var pipeline := rd.compute_pipeline_create(_prt_compact_shader,
			_prt_stage_specialization(values))
	if not pipeline.is_valid() or not rd.compute_pipeline_is_valid(pipeline):
		_free_rids(rd, [pipeline])
		return false
	_prt_compact_pipelines["native_general_source_queue"] = pipeline
	_prt_compact_pipeline_specialization_values["native_general_source_queue"] = values
	_native_general_queue_consumer_signature = signature
	_sync_owned_rid_snapshot()
	return true

func _ensure_prt_compact_finalize_program(rd: RenderingDevice) -> bool:
	if _prt_compact_finalize_shader_resource == null:
		_prt_compact_finalize_shader_resource = _load_optional_rd_shader(
				MAGIC_GI_PRT_QUEUE_FINALIZE_SHADER_PATH)
	if _prt_compact_finalize_shader_resource == null:
		return false
	var spirv: RDShaderSPIRV = _prt_compact_finalize_shader_resource.get_spirv()
	if spirv == null or _prt_compact_finalize_shader_resource.base_error != "" \
			or spirv.bytecode_compute.is_empty() or spirv.compile_error_compute != "":
		return false
	var finalize_pipeline_ready := _prt_compact_finalize_pipeline.is_valid() \
			and rd.compute_pipeline_is_valid(_prt_compact_finalize_pipeline)
	if not _prt_compact_finalize_shader.is_valid() or _prt_compact_finalize_shader_spirv != spirv \
			or not finalize_pipeline_ready:
		_clear_prt_compact_finalize_program(rd)
		_prt_compact_finalize_shader = rd.shader_create_from_spirv(spirv)
		if not _prt_compact_finalize_shader.is_valid():
			_clear_prt_compact_finalize_program(rd)
			return false
		_prt_compact_finalize_shader_spirv = spirv
		_prt_compact_finalize_pipeline = rd.compute_pipeline_create(
				_prt_compact_finalize_shader, [])
		if not _prt_compact_finalize_pipeline.is_valid() \
				or not rd.compute_pipeline_is_valid(_prt_compact_finalize_pipeline):
			_clear_prt_compact_finalize_program(rd)
			return false
		_prt_compact_finalize_pipeline_signature = "%s|shader=%d|specialization=none" % [
			MAGIC_GI_PRT_QUEUE_FINALIZE_SHADER_PATH,
			_prt_compact_finalize_shader.get_id()]
		_sync_owned_rid_snapshot()
	return rd.compute_pipeline_is_valid(_prt_compact_finalize_pipeline)

func _ensure_prt_compact_queue_buffers(rd: RenderingDevice, pixel_count: int) -> bool:
	if pixel_count <= 0 or pixel_count > 1073741823:
		return false
	var buffers_ready := _prt_compact_queue_capacity_pixels == pixel_count \
			and _prt_compact_queue_buffer.is_valid() \
			and _prt_compact_queue_control_buffer.is_valid() \
			and _prt_compact_indirect_args_buffer.is_valid()
	if buffers_ready:
		return true
	var queue_buffer := rd.storage_buffer_create(pixel_count * 4, PackedByteArray())
	var control_buffer := rd.storage_buffer_create(MAGIC_GI_PRT_QUEUE_CONTROL_BYTES,
			PackedByteArray())
	var indirect_args_buffer := rd.storage_buffer_create(MAGIC_GI_PRT_QUEUE_INDIRECT_BYTES,
			PackedByteArray(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	if not queue_buffer.is_valid() or not control_buffer.is_valid() \
			or not indirect_args_buffer.is_valid():
		_free_rids(rd, [queue_buffer, control_buffer, indirect_args_buffer])
		return false
	_clear_prt_compact_queue_buffers(rd)
	_prt_compact_queue_buffer = queue_buffer
	_prt_compact_queue_control_buffer = control_buffer
	_prt_compact_indirect_args_buffer = indirect_args_buffer
	_prt_compact_queue_capacity_pixels = pixel_count
	_sync_owned_rid_snapshot()
	return true

func _ensure_prt_compact_finalize_uniform_set(rd: RenderingDevice) -> bool:
	if not _prt_compact_finalize_shader.is_valid() \
			or not _prt_compact_queue_control_buffer.is_valid() \
			or not _prt_compact_indirect_args_buffer.is_valid():
		return false
	var signature := "%d|%d|%d" % [_prt_compact_finalize_shader.get_id(),
		_prt_compact_queue_control_buffer.get_id(), _prt_compact_indirect_args_buffer.get_id()]
	if _prt_compact_finalize_uniform_set.is_valid() \
			and _prt_compact_finalize_uniform_set_signature == signature \
			and rd.uniform_set_is_valid(_prt_compact_finalize_uniform_set):
		return true
	_free_rids(rd, [_prt_compact_finalize_uniform_set])
	_prt_compact_finalize_uniform_set = RID()
	var uniforms: Array[RDUniform] = [
		U.storage_buffer(0, _prt_compact_queue_control_buffer),
		U.storage_buffer(1, _prt_compact_indirect_args_buffer),
	]
	_prt_compact_finalize_uniform_set = rd.uniform_set_create(uniforms,
			_prt_compact_finalize_shader, 0)
	if not _prt_compact_finalize_uniform_set.is_valid() \
			or not rd.uniform_set_is_valid(_prt_compact_finalize_uniform_set):
		_prt_compact_finalize_uniform_set_signature = ""
		return false
	_prt_compact_finalize_uniform_set_signature = signature
	_sync_owned_rid_snapshot()
	return true

func _make_prt_compact_apply_uniform_set(rd: RenderingDevice,
		uniforms: Array[RDUniform]) -> RID:
	if not _prt_compact_shader.is_valid():
		return RID()
	return UniformSetCacheRD.get_cache(_prt_compact_shader, 0, uniforms)

func _ensure_prt_compact_legacy_marker(rd: RenderingDevice) -> bool:
	if _prt_source_pending_texture.is_valid() and rd.texture_is_valid(_prt_source_pending_texture):
		return true
	return _ensure_prt_source_pending_texture(rd, Vector2i.ONE).is_valid()

func _render_prt_compact_miss_queue(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice) -> bool:
	var dispatch_size := buffers.get_internal_size()
	var target := _selected_target(false)
	if target != &"":
		if not buffers.has_texture(PIPELINE_SCOPE, target):
			_record_prt_compact_fallback("dispatch_target_unavailable", true)
			return false
		dispatch_size = buffers.get_texture_slice_size(PIPELINE_SCOPE, target, 0)
	if dispatch_size.x <= 0 or dispatch_size.y <= 0:
		_record_prt_compact_fallback("invalid_dispatch_size", true, dispatch_size)
		return false
	var pixel_count := dispatch_size.x * dispatch_size.y
	if pixel_count <= 0 or pixel_count > 1073741823:
		_record_prt_compact_fallback("queue_capacity_out_of_range", true, dispatch_size)
		return false
	var capability := _prt_compact_capability(rd)
	_prt_compact_last_capability = capability.duplicate(true)
	if not bool(capability.get("supported", false)):
		_record_prt_compact_fallback("capability:" + str(capability.get("reason", "unsupported")),
				true, dispatch_size)
		return false
	var full_groups_x := _prt_compact_ceil_div(dispatch_size.x, MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE)
	var full_groups_y := _prt_compact_ceil_div(dispatch_size.y, MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE)
	var max_consumer_groups_x := _prt_compact_ceil_div(pixel_count,
			MAGIC_GI_PRT_QUEUE_LOCAL_INVOCATIONS)
	var max_groups_x := int(capability.get("max_compute_workgroup_count_x", 0))
	var max_groups_y := int(capability.get("max_compute_workgroup_count_y", 0))
	var max_groups_z := int(capability.get("max_compute_workgroup_count_z", 0))
	if full_groups_x <= 0 or full_groups_y <= 0 or max_consumer_groups_x <= 0 \
			or full_groups_x > max_groups_x or max_consumer_groups_x > max_groups_x \
			or full_groups_y > max_groups_y or max_groups_z < 1:
		_record_prt_compact_fallback("dispatch_exceeds_device_workgroup_limits", true, dispatch_size)
		return false
	if not _ensure_prt_source_pending_texture(rd, dispatch_size).is_valid():
		_record_prt_compact_fallback("source_pending_marker_unavailable", true, dispatch_size)
		return false
	if not _ensure_prt_compact_queue_buffers(rd, pixel_count):
		_record_prt_compact_fallback("queue_buffer_allocation_failed", true, dispatch_size)
		return false
	if not _ensure_prt_compact_apply_program(rd):
		_record_prt_compact_fallback("compact_apply_shader_or_pipeline_unavailable", true,
				dispatch_size)
		return false
	if not _ensure_prt_compact_finalize_program(rd):
		_record_prt_compact_fallback("finalize_shader_or_pipeline_unavailable", true,
				dispatch_size)
		return false
	if not _ensure_prt_compact_finalize_uniform_set(rd):
		_record_prt_compact_fallback("finalize_uniform_set_unavailable", true, dispatch_size)
		return false
	var binding_data := _collect_bindings(buffers, view, rd)
	if _binding_error:
		_record_prt_compact_fallback("apply_bindings_unavailable", true, dispatch_size)
		return false
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	var occupied: Dictionary = {}
	for uniform_value in uniforms:
		var uniform: RDUniform = uniform_value
		occupied[uniform.binding] = true
	if occupied.has(MAGIC_GI_SOURCE_PENDING_BINDING) \
			or occupied.has(MAGIC_GI_PRT_MISS_QUEUE_BINDING) \
			or occupied.has(MAGIC_GI_PRT_MISS_QUEUE_CONTROL_BINDING):
		_record_prt_compact_fallback("reserved_binding_collision", true, dispatch_size)
		return false
	uniforms.append(U.image(MAGIC_GI_SOURCE_PENDING_BINDING, _prt_source_pending_texture))
	uniforms.append(U.storage_buffer(MAGIC_GI_PRT_MISS_QUEUE_BINDING,
			_prt_compact_queue_buffer))
	uniforms.append(U.storage_buffer(MAGIC_GI_PRT_MISS_QUEUE_CONTROL_BINDING,
			_prt_compact_queue_control_buffer))
	var apply_uniform_set := _make_prt_compact_apply_uniform_set(rd, uniforms)
	if not apply_uniform_set.is_valid() or not rd.uniform_set_is_valid(apply_uniform_set):
		_record_prt_compact_fallback("apply_uniform_set_unavailable", true, dispatch_size)
		return false
	_capture_gpu_timestamp(rd, "PRT Compact Queue Clear+Cert Begin")
	if rd.buffer_clear(_prt_compact_queue_control_buffer, 0,
			MAGIC_GI_PRT_QUEUE_CONTROL_BYTES) != OK:
		_record_prt_compact_fallback("queue_control_clear_failed", true, dispatch_size)
		return false
	var push := _parameter_bytes()
	var finalize_push := PackedInt32Array([pixel_count, dispatch_size.x, dispatch_size.y,
			MAGIC_GI_PRT_QUEUE_LOCAL_INVOCATIONS, MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE,
			MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE]).to_byte_array()
	var list := rd.compute_list_begin()
	if list < 0:
		_record_prt_compact_fallback("compute_list_begin_failed", true, dispatch_size)
		return false
	rd.compute_list_bind_compute_pipeline(list, _prt_compact_pipelines["cert_only"])
	rd.compute_list_bind_uniform_set(list, apply_uniform_set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, full_groups_x, full_groups_y, 1)
	rd.compute_list_add_barrier(list)
	_capture_gpu_timestamp(rd, "PRT Compact Queue Finalize Begin")
	rd.compute_list_bind_compute_pipeline(list, _prt_compact_finalize_pipeline)
	rd.compute_list_bind_uniform_set(list, _prt_compact_finalize_uniform_set, 0)
	rd.compute_list_set_push_constant(list, finalize_push, finalize_push.size())
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_add_barrier(list)
	_capture_gpu_timestamp(rd, "PRT Compact Queue Consumer Begin")
	rd.compute_list_bind_compute_pipeline(list, _prt_compact_pipelines["general_queue_consumer"])
	rd.compute_list_bind_uniform_set(list, apply_uniform_set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch_indirect(list, _prt_compact_indirect_args_buffer, 0)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "PRT Compact Queue Consumer End")
	_prt_compact_queue_metadata = _prt_compact_metadata_base(true, "", dispatch_size, true)
	return true

func _make_uniform_set(uniforms: Array[RDUniform]) -> RID:
	var source_pending_required := _shader_resource == MAGIC_GI_APPLY_SHADER \
			or (_layout14_b_frame_active and shader_file == _layout14_b_apply_shader_resource)
	if not source_pending_required:
		return super._make_uniform_set(uniforms)
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_report("Cannot access the RenderingDevice for the PRT source-pending image.")
		return RID()
	if not _prt_source_pending_texture.is_valid() or not rd.texture_is_valid(_prt_source_pending_texture):
		if not _ensure_prt_source_pending_texture(rd, Vector2i.ONE).is_valid():
			return RID()
	var has_source_pending := false
	for uniform_value in uniforms:
		var uniform: RDUniform = uniform_value
		if uniform.binding == MAGIC_GI_SOURCE_PENDING_BINDING:
			has_source_pending = true
			break
	if not has_source_pending:
		uniforms.append(U.image(MAGIC_GI_SOURCE_PENDING_BINDING, _prt_source_pending_texture))
	return super._make_uniform_set(uniforms)

func _render_native_general_source_queue_consumer(buffers: RenderSceneBuffersRD,
		view: int, rd: RenderingDevice) -> bool:
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0 or not _native_general_queue_uniform_set.is_valid() \
			or not rd.uniform_set_is_valid(_native_general_queue_uniform_set) \
			or not _prt_compact_pipelines.has("native_general_source_queue") \
			or not _prt_compact_pipeline_is_valid(rd,
				_prt_compact_pipelines["native_general_source_queue"]):
		_native_general_queue_state["consumer_failure"] = "preflight_resource_invalid_after_deferred"
		return false
	var pipeline: RID = _prt_compact_pipelines["native_general_source_queue"]
	var finalize_ready := _prt_compact_finalize_pipeline.is_valid() \
			and rd.compute_pipeline_is_valid(_prt_compact_finalize_pipeline) \
			and _prt_compact_finalize_uniform_set.is_valid() \
			and rd.uniform_set_is_valid(_prt_compact_finalize_uniform_set)
	var finalize_push := PackedInt32Array([
		size.x * size.y, size.x, size.y,
		MAGIC_GI_PRT_QUEUE_LOCAL_INVOCATIONS,
		MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE, MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE,
	]).to_byte_array()
	var source_push := _parameter_bytes(-1.0)
	_capture_gpu_timestamp(rd, "Native General Queue Source Begin")
	# The renderer inserted an ordering boundary after its producer draw; resource
	# hazards carry the image and buffer writes into this source-only compute list.
	if not finalize_ready:
		# This late recovery only widens work to source-only marker scans; it never
		# re-runs certified/general CLV after native contributions.
		var overflow := PackedInt32Array([1]).to_byte_array()
		if rd.buffer_update(_prt_compact_queue_control_buffer, 4, 4, overflow) != OK:
			_native_general_queue_state["consumer_failure"] = "marker_scan_overflow_flag_failed"
			return false
	var list := rd.compute_list_begin()
	if list < 0:
		_native_general_queue_state["consumer_failure"] = "compute_list_begin_failed"
		return false
	if finalize_ready:
		rd.compute_list_bind_compute_pipeline(list, _prt_compact_finalize_pipeline)
		rd.compute_list_bind_uniform_set(list, _prt_compact_finalize_uniform_set, 0)
		rd.compute_list_set_push_constant(list, finalize_push, finalize_push.size())
		rd.compute_list_dispatch(list, 1, 1, 1)
		rd.compute_list_add_barrier(list)
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, _native_general_queue_uniform_set, 0)
		rd.compute_list_set_push_constant(list, source_push, source_push.size())
		rd.compute_list_dispatch_indirect(list, _prt_compact_indirect_args_buffer, 0)
		_native_general_queue_state["source_dispatch"] = "indirect_queue_or_overflow_scan"
	else:
		# The overflow flag above makes this same source-only consumer scan markers.
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, _native_general_queue_uniform_set, 0)
		rd.compute_list_set_push_constant(list, source_push, source_push.size())
		rd.compute_list_dispatch(list,
				_prt_compact_ceil_div(size.x, MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE),
				_prt_compact_ceil_div(size.y, MAGIC_GI_PRT_QUEUE_WORKGROUP_SIZE), 1)
		_native_general_queue_state["source_dispatch"] = "late_failure_marker_scan"
	_native_general_queue_state["source_consumer_dispatched"] = true
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "Native General Queue Source End")
	_prt_compact_dispatch_frame = Engine.get_frames_drawn()
	_prt_compact_queue_metadata = _prt_compact_metadata_base(true,
			"native_deferred_general_source_queue", size, true)
	_prt_compact_queue_metadata["active_stages"] = [
		"native_deferred_general_clv", "source_only_exact_gather"]
	_prt_compact_queue_metadata["producer_invocation_contract"] = "single_view_single_sample_fullscreen_triangle_one_invocation_per_pixel"
	_prt_compact_queue_metadata["runtime_msaa"] = _frame_native_general_queue_msaa
	_prt_compact_queue_metadata["runtime_view_count"] = _frame_native_general_queue_view_count
	_native_general_queue_state["fallback_reason"] = ""
	return true

func _render_compute(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _is_magicdawn_dynamic_clv_snapshot(_frame_snapshot):
		# Layout-9 backend 1 has no screen-space PRT fallback. Outside the FRP
		# native consumer it must fail closed instead of reverting to per-pixel work.
		_magicdawn_runtime_state["status"] = "native_layout9_requires_frp_fail_closed"
		_magicdawn_runtime_state["fallback_reason"] = "native_frp_clv_consumer_unavailable"
		_magicdawn_runtime_state["pixel_csr_fallback"] = false
		return
	if _magicdawn_frame_active:
		_render_magicdawn_compute(buffers, view, rd)
		return
	_prt_compact_dispatch_frame = _last_native_clv_lighting_frame
	if _frame_native_general_queue_active:
		# Never re-enter the full compute PRT path after deferred general hits have
		# already contributed. Late failures can only scan the queued source markers.
		if _frame_native_general_queue_view_count != 1 \
				or _frame_native_general_queue_msaa != RenderingServer.VIEWPORT_MSAA_DISABLED:
			_native_general_queue_state["consumer_failure"] = "runtime_eligibility_contract_mismatch"
			_native_general_queue_state["source_consumer_dispatched"] = false
			return
		if _render_native_general_source_queue_consumer(buffers, view, rd):
			return
		_native_general_queue_state["active"] = true
		_native_general_queue_state["source_consumer_dispatched"] = false
		return
	if prt_compact_miss_queue_enabled:
		_prt_compact_last_capability = {"status": "not_checked"}
		var ineligible_reason := _prt_compact_eligibility_reason()
		if not ineligible_reason.is_empty():
			_record_prt_compact_fallback(ineligible_reason, false)
			if ineligible_reason not in ["scaled_prt_application", "stream_dispatch"]:
				if not _ensure_prt_compact_legacy_marker(rd):
					return
				return super._render_compute(buffers, view, rd)
		elif _render_prt_compact_miss_queue(buffers, view, rd):
			return
		else:
			if not _ensure_prt_compact_legacy_marker(rd):
				return
			return super._render_compute(buffers, view, rd)
	elif bool(_prt_compact_queue_metadata.get("enabled", false)):
		_prt_compact_last_capability = {"status": "not_checked"}
		_record_prt_compact_fallback("disabled", false)
	else:
		_prt_compact_queue_metadata["dispatch_frame"] = _prt_compact_dispatch_frame
		_prt_compact_queue_metadata["indirect_dispatch_calls"] = 0
	if not _stream_dispatch_active and _frame_prt_scale > 1:
		if not _ensure_prt_source_pending_texture(rd, Vector2i.ONE).is_valid():
			return
		_render_prt_scaled(buffers, view, rd)
		return
	if not _stream_dispatch_active:
		if _can_use_prt_three_stage() and _render_prt_three_stage(buffers, view, rd):
			return
		if _can_use_prt_two_stage() and _render_prt_two_stage(buffers, view, rd):
			return
		if not _ensure_prt_source_pending_texture(rd, Vector2i.ONE).is_valid():
			return
		return super._render_compute(buffers, view, rd)
	if not _ensure_prt_source_pending_texture(rd, Vector2i.ONE).is_valid():
		return
	if workgroup_size.x <= 0 or workgroup_size.y <= 0 or _stream_dispatch_rect.size.x <= 0 \
			or _stream_dispatch_rect.size.y <= 0:
		return
	var binding_data := _collect_bindings(buffers, view, rd)
	if _binding_error:
		return
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	var uniform_set := _make_uniform_set(uniforms)
	if not uniforms.is_empty() and not uniform_set.is_valid():
		return
	var push := _parameter_bytes(-1.0 if _frame_native_clv_fallback_only else 1.0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _compute_pipeline)
	if uniform_set.is_valid():
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(float(_stream_dispatch_rect.size.x) / workgroup_size.x),
		ceili(float(_stream_dispatch_rect.size.y) / workgroup_size.y), 1)
	rd.compute_list_end()

func _render_prt_two_stage(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice) -> bool:
	if workgroup_size.x <= 0 or workgroup_size.y <= 0 \
			or not _ensure_prt_stage_pipelines(rd, false):
		return false
	var dispatch_size := buffers.get_internal_size()
	var target := _selected_target(false)
	if target != &"":
		if not buffers.has_texture(PIPELINE_SCOPE, target):
			_report("Dispatch target '%s' is unavailable." % target)
			return false
		dispatch_size = buffers.get_texture_slice_size(PIPELINE_SCOPE, target, 0)
	if dispatch_size.x <= 0 or dispatch_size.y <= 0 \
			or not _ensure_prt_source_pending_texture(rd, dispatch_size).is_valid():
		return false
	var binding_data := _collect_bindings(buffers, view, rd)
	if _binding_error:
		return false
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	var uniform_set := _make_uniform_set(uniforms)
	if not uniforms.is_empty() and not uniform_set.is_valid():
		return false
	var push := _parameter_bytes()
	var groups_x := ceili(float(dispatch_size.x) / float(workgroup_size.x))
	var groups_y := ceili(float(dispatch_size.y) / float(workgroup_size.y))
	var list := rd.compute_list_begin()
	if list < 0:
		return false
	rd.compute_list_bind_compute_pipeline(list,
			_prt_stage_pipelines[MAGIC_GI_PRT_STAGE_CACHE_GENERAL])
	if uniform_set.is_valid():
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, groups_x, groups_y, 1)
	# Makes the stage-A r32ui imageStore visible to every stage-B imageLoad.
	rd.compute_list_add_barrier(list)
	rd.compute_list_bind_compute_pipeline(list,
			_prt_stage_pipelines[MAGIC_GI_PRT_STAGE_SOURCE])
	if uniform_set.is_valid():
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, groups_x, groups_y, 1)
	rd.compute_list_end()
	_last_prt_two_stage_active = true
	_last_prt_two_stage_stage_values = PackedInt32Array([
			MAGIC_GI_PRT_STAGE_CACHE_GENERAL, MAGIC_GI_PRT_STAGE_SOURCE])
	return true

func _render_prt_three_stage(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice) -> bool:
	if workgroup_size.x <= 0 or workgroup_size.y <= 0 \
			or not _ensure_prt_stage_pipelines(rd, true):
		return false
	var dispatch_size := buffers.get_internal_size()
	var target := _selected_target(false)
	if target != &"":
		if not buffers.has_texture(PIPELINE_SCOPE, target):
			_report("Dispatch target '%s' is unavailable." % target)
			return false
		dispatch_size = buffers.get_texture_slice_size(PIPELINE_SCOPE, target, 0)
	if dispatch_size.x <= 0 or dispatch_size.y <= 0 \
			or not _ensure_prt_source_pending_texture(rd, dispatch_size).is_valid():
		return false
	var binding_data := _collect_bindings(buffers, view, rd)
	if _binding_error:
		return false
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	var uniform_set := _make_uniform_set(uniforms)
	if not uniforms.is_empty() and not uniform_set.is_valid():
		return false
	var push := _parameter_bytes()
	var groups_x := ceili(float(dispatch_size.x) / float(workgroup_size.x))
	var groups_y := ceili(float(dispatch_size.y) / float(workgroup_size.y))
	var stage_sequence := [MAGIC_GI_PRT_STAGE_CERT_ONLY,
			MAGIC_GI_PRT_STAGE_GENERAL_ONLY, MAGIC_GI_PRT_STAGE_THREE_SOURCE]
	var stage_timestamp_labels := ["PRT V3 Cert Begin", "PRT V3 General Begin",
			"PRT V3 Source Begin"]
	_capture_gpu_timestamp(rd, stage_timestamp_labels[0])
	var list := rd.compute_list_begin()
	if list < 0:
		return false
	for index in stage_sequence.size():
		if index > 0:
			# This ends the previous list and starts an empty one. Captures are legal
			# here (dispatch_count is zero) and stay between the two stage dispatches.
			rd.compute_list_add_barrier(list)
			_capture_gpu_timestamp(rd, stage_timestamp_labels[index])
		rd.compute_list_bind_compute_pipeline(list, _prt_stage_pipelines[stage_sequence[index]])
		if uniform_set.is_valid():
			rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, groups_x, groups_y, 1)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "PRT V3 Source End")
	_last_prt_three_stage_active = true
	_last_prt_three_stage_stage_values = PackedInt32Array(stage_sequence)
	return true

func _render_prt_scaled(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice) -> void:
	var full_size := buffers.get_internal_size()
	if workgroup_size.x <= 0 or workgroup_size.y <= 0:
		_report("PRT gather workgroup size must be positive.")
		return
	var raw_size := Vector2i(ceili(float(full_size.x) / float(_frame_prt_scale)),
		ceili(float(full_size.y) / float(_frame_prt_scale)))
	var output: RID = inputs[5].get_texture(buffers, view)
	var use_fast_resolve := prt_resolve_fast_path and _frame_prt_scale > 1
	if not output.is_valid() or full_size.x <= 0 or full_size.y <= 0 \
			or not _ensure_prt_resolve_pipeline(rd) or not _ensure_sampler(rd) \
			or not _ensure_prt_linear_sampler(rd) \
			or (use_fast_resolve and not _ensure_prt_guide_pipeline(rd)):
		if output.is_valid():
			rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	var raw := _ensure_prt_raw_texture(buffers, view, rd, raw_size)
	if not raw.is_valid():
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	var guide_views := _ensure_prt_guide_textures(buffers, view, rd, raw_size)
	var guide: RID = guide_views.get("guide", RID())
	var certificate: RID = guide_views.get("certificate", RID())
	if not guide.is_valid() or not certificate.is_valid():
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	var binding_data := _collect_bindings(buffers, view, rd)
	if _binding_error:
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	var gather_uniforms: Array[RDUniform] = []
	for uniform_value in binding_data.get("uniforms", []):
		var uniform: RDUniform = uniform_value
		if uniform.binding != 5:
			gather_uniforms.append(uniform)
	gather_uniforms.append(U.image(5, raw))
	var gather_set := _make_uniform_set(gather_uniforms)
	if not gather_set.is_valid():
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	if gpu_timestamp_profiling_enabled and _prt_profile_resource_log_count < 3:
		print("[Magic GI PRT] resource frame=%d raw=%d guide=%d certificate=%d gather_set=%d gi_ubo=%d uniforms=%d raw_size=%s" % [
			Engine.get_process_frames(), raw.get_id(), guide.get_id(), certificate.get_id(),
			gather_set.get_id(), _ubo.get_id(), gather_uniforms.size(), str(raw_size)])
		_prt_profile_resource_log_count += 1
	_capture_gpu_timestamp(rd, "Apply Gather Begin")
	var gather_list := rd.compute_list_begin()
	if gather_list < 0:
		_capture_gpu_timestamp(rd, "Apply Gather End")
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	rd.compute_list_bind_compute_pipeline(gather_list, _compute_pipeline)
	rd.compute_list_bind_uniform_set(gather_list, gather_set, 0)
	var push := _parameter_bytes()
	rd.compute_list_set_push_constant(gather_list, push, push.size())
	rd.compute_list_dispatch(gather_list,
		ceili(float(raw_size.x) / float(workgroup_size.x)),
		ceili(float(raw_size.y) / float(workgroup_size.y)), 1)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "Apply Gather End")
	if _prt_raw_debug_output:
		return
	if use_fast_resolve and not _dispatch_prt_guide(buffers, view, rd, raw, guide,
			certificate, raw_size):
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	if not _dispatch_prt_resolve(buffers, view, rd, raw, output, full_size,
			guide, certificate, use_fast_resolve):
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)

func _dispatch_prt_guide(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice,
		raw: RID, guide: RID, certificate: RID, raw_size: Vector2i) -> bool:
	var depth: RID = inputs[1].get_texture(buffers, view)
	var normal: RID = inputs[2].get_texture(buffers, view)
	if not depth.is_valid() or not normal.is_valid() or not _ubo.is_valid():
		_report("PRT guide generation requires the current depth, normal, and GI parameter inputs.")
		return false
	var uniforms: Array[RDUniform] = [
		U.sampled(0, _sampler, raw), U.sampled(1, _sampler, depth),
		U.sampled(2, _sampler, normal), U.image(3, guide), U.image(4, certificate),
		U.uniform_buffer(9, _ubo)]
	var uniform_set := UniformSetCacheRD.get_cache(_prt_guide_shader, 0, uniforms)
	if not uniform_set.is_valid():
		_report("Magic GI PRT guide uniform set is invalid.")
		return false
	_capture_gpu_timestamp(rd, "Apply Guide Begin")
	var list := rd.compute_list_begin()
	if list < 0:
		_capture_gpu_timestamp(rd, "Apply Guide End")
		return false
	rd.compute_list_bind_compute_pipeline(list, _prt_guide_pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	var push := _parameter_bytes()
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(float(raw_size.x) / 8.0),
		ceili(float(raw_size.y) / 8.0), 1)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "Apply Guide End")
	return true

func _dispatch_prt_resolve(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice, raw: RID, output: RID, full_size: Vector2i,
		guide := RID(), certificate := RID(), use_fast_resolve := false) -> bool:
	var color: RID = inputs[0].get_texture(buffers, view)
	var depth: RID = inputs[1].get_texture(buffers, view)
	var normal: RID = inputs[2].get_texture(buffers, view)
	var albedo: RID = inputs[3].get_texture(buffers, view)
	var orm: RID = inputs[4].get_texture(buffers, view)
	var sky := _sky_diffuse_input.get_texture(buffers, view)
	if not sky.is_valid():
		sky = _ensure_zero_sky_diffuse(rd)
	var diffuse_ao := _get_diffuse_ao_view(buffers, view, rd)
	if not diffuse_ao.is_valid():
		diffuse_ao = _ensure_white_diffuse_ao(rd)
	if not color.is_valid() or not depth.is_valid() or not normal.is_valid() \
			or not albedo.is_valid() or not orm.is_valid() or not sky.is_valid() \
			or not diffuse_ao.is_valid() or not _ubo.is_valid():
		_report("PRT resolve requires current color, G-buffer, Sky diffuse, AO, and GI parameter inputs.")
		return false
	var uniforms: Array[RDUniform] = [
		U.sampled(0, _sampler, raw), U.sampled(1, _sampler, depth),
		U.sampled(2, _sampler, normal), U.sampled(3, _sampler, albedo),
		U.sampled(4, _sampler, orm), U.sampled(5, _sampler, sky),
		U.sampled(6, _sampler, diffuse_ao), U.image(7, color),
		U.image(8, output), U.uniform_buffer(9, _ubo)]
	if not guide.is_valid() or not certificate.is_valid() \
			or not _prt_linear_sampler.is_valid():
		_report("PRT resolve requires valid guide, certificate, and linear sampler resources.")
		return false
	uniforms.append(U.sampled(10, _sampler, guide))
	uniforms.append(U.sampled(11, _sampler, certificate))
	uniforms.append(U.sampled(12, _prt_linear_sampler, raw))
	var uniform_set := UniformSetCacheRD.get_cache(_prt_resolve_shader, 0, uniforms)
	if not uniform_set.is_valid():
		_report("Magic GI PRT resolve uniform set is invalid.")
		return false
	_capture_gpu_timestamp(rd, "Apply Resolve Begin")
	var list := rd.compute_list_begin()
	if list < 0:
		_capture_gpu_timestamp(rd, "Apply Resolve End")
		return false
	rd.compute_list_bind_compute_pipeline(list, _prt_resolve_pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	var push := _parameter_bytes(-1.0 if use_fast_resolve else 1.0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(float(full_size.x) / 8.0),
		ceili(float(full_size.y) / 8.0), 1)
	rd.compute_list_end()
	_capture_gpu_timestamp(rd, "Apply Resolve End")
	return true

func _ensure_prt_raw_texture(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice, size: Vector2i) -> RID:
	_prune_prt_raw_views(rd)
	var key := "%d:%d" % [buffers.get_instance_id(), view]
	var state: Dictionary = _prt_raw_views.get(key, {})
	var existing: RID = state.get("texture", RID())
	if existing.is_valid() and Vector2i(state.get("size", Vector2i.ZERO)) == size \
			and bool(state.get("diagnostic_readback", false)) == _prt_raw_debug_output \
			and rd.texture_is_valid(existing):
		return existing
	if not state.is_empty():
		_free_rids(rd, [existing, state.get("guide", RID()),
			state.get("certificate", RID())])
		_prt_raw_views.erase(key)
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = size.x
	format.height = size.y
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	if _prt_raw_debug_output:
		format.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var texture := rd.texture_create(format, RDTextureView.new(), [])
	if not texture.is_valid():
		return RID()
	if rd.texture_clear(texture, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK:
		_free_rids(rd, [texture])
		return RID()
	_prt_raw_views[key] = {"texture": texture, "owner": weakref(buffers),
		"size": size, "diagnostic_readback": _prt_raw_debug_output}
	_sync_owned_rid_snapshot()
	return texture

func _release_prt_raw_view(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice) -> void:
	if buffers == null or rd == null:
		return
	var key := "%d:%d" % [buffers.get_instance_id(), view]
	if not _prt_raw_views.has(key):
		return
	var state: Dictionary = _prt_raw_views[key]
	_free_rids(rd, [state.get("texture", RID()), state.get("guide", RID()),
		state.get("certificate", RID())])
	_prt_raw_views.erase(key)
	_sync_owned_rid_snapshot()

func _ensure_prt_guide_textures(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice, size: Vector2i) -> Dictionary:
	var key := "%d:%d" % [buffers.get_instance_id(), view]
	var state: Dictionary = _prt_raw_views.get(key, {})
	var guide: RID = state.get("guide", RID())
	var certificate: RID = state.get("certificate", RID())
	if Vector2i(state.get("size", Vector2i.ZERO)) == size \
			and guide.is_valid() and certificate.is_valid() \
			and rd.texture_is_valid(guide) and rd.texture_is_valid(certificate):
		return {"guide": guide, "certificate": certificate}
	if guide.is_valid() or certificate.is_valid():
		_free_rids(rd, [guide, certificate])
		state.erase("guide")
		state.erase("certificate")
	var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var guide_format := RDTextureFormat.new()
	guide_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	guide_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	guide_format.width = size.x
	guide_format.height = size.y
	guide_format.depth = 1
	guide_format.array_layers = 1
	guide_format.mipmaps = 1
	guide_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	guide_format.usage_bits = usage
	guide = rd.texture_create(guide_format, RDTextureView.new(), [])
	if not guide.is_valid() or rd.texture_clear(guide, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK:
		if guide.is_valid():
			_free_rids(rd, [guide])
		return {}
	var certificate_format := RDTextureFormat.new()
	certificate_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	certificate_format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	certificate_format.width = size.x
	certificate_format.height = size.y
	certificate_format.depth = 1
	certificate_format.array_layers = 1
	certificate_format.mipmaps = 1
	certificate_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	certificate_format.usage_bits = usage
	certificate = rd.texture_create(certificate_format, RDTextureView.new(), [])
	if not certificate.is_valid() \
			or rd.texture_clear(certificate, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK:
		_free_rids(rd, [guide, certificate])
		return {}
	state["guide"] = guide
	state["certificate"] = certificate
	state["size"] = size
	state["owner"] = weakref(buffers)
	_prt_raw_views[key] = state
	_sync_owned_rid_snapshot()
	return {"guide": guide, "certificate": certificate}

func _ensure_prt_linear_sampler(rd: RenderingDevice) -> bool:
	if _prt_linear_sampler.is_valid():
		return true
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_prt_linear_sampler = rd.sampler_create(state)
	return _prt_linear_sampler.is_valid()

func _ensure_prt_guide_pipeline(rd: RenderingDevice) -> bool:
	if _prt_guide_shader.is_valid() and _prt_guide_pipeline.is_valid():
		return true
	var spirv := PRT_GUIDE_SHADER.get_spirv()
	if spirv == null or PRT_GUIDE_SHADER.base_error != "" \
			or spirv.bytecode_compute.is_empty() or spirv.compile_error_compute != "":
		_report("Magic GI PRT guide shader failed to compile: " + PRT_GUIDE_SHADER.base_error)
		return false
	if not _prt_guide_shader.is_valid():
		_prt_guide_shader = rd.shader_create_from_spirv(spirv, "Magic GI PRT Coarse Guide")
		if not _prt_guide_shader.is_valid():
			return false
	if not _prt_guide_pipeline.is_valid():
		_prt_guide_pipeline = rd.compute_pipeline_create(_prt_guide_shader)
		if not _prt_guide_pipeline.is_valid():
			_free_rids(rd, [_prt_guide_shader])
			_prt_guide_shader = RID()
			return false
	_sync_owned_rid_snapshot()
	return true

func _prune_prt_raw_views(rd: RenderingDevice) -> void:
	var removed := false
	for key_value in _prt_raw_views.keys():
		var key := str(key_value)
		var state: Dictionary = _prt_raw_views[key]
		var owner: WeakRef = state.get("owner")
		if owner == null or owner.get_ref() == null:
			var textures: Array[RID] = [state.get("texture", RID()),
				state.get("guide", RID()), state.get("certificate", RID()),
			state.get("certificate", RID())]
			_free_rids(rd, textures)
			_prt_raw_views.erase(key)
			removed = true
	if removed:
		_sync_owned_rid_snapshot()

func _ensure_prt_resolve_pipeline(rd: RenderingDevice) -> bool:
	if _prt_resolve_shader.is_valid() and _prt_resolve_pipeline.is_valid():
		return true
	var spirv := PRT_RESOLVE_SHADER.get_spirv()
	if spirv == null or PRT_RESOLVE_SHADER.base_error != "" \
			or spirv.bytecode_compute.is_empty() or spirv.compile_error_compute != "":
		_report("Magic GI PRT resolve shader failed to compile: " + PRT_RESOLVE_SHADER.base_error)
		return false
	if not _prt_resolve_shader.is_valid():
		_prt_resolve_shader = rd.shader_create_from_spirv(spirv, "Magic GI PRT Edge-aware Resolve")
		if not _prt_resolve_shader.is_valid():
			return false
	if not _prt_resolve_pipeline.is_valid():
		_prt_resolve_pipeline = rd.compute_pipeline_create(_prt_resolve_shader)
		if not _prt_resolve_pipeline.is_valid():
			_free_rids(rd, [_prt_resolve_shader])
			_prt_resolve_shader = RID()
			return false
	_sync_owned_rid_snapshot()
	return true

func _ensure_pending_page_pipeline(rd: RenderingDevice) -> bool:
	if _pending_page_shader.is_valid() and _pending_page_pipeline.is_valid():
		return true
	if _page_residency != null and _page_residency.allocation_budget_remaining() <= 0:
		return false
	var spirv := PENDING_PAGE_SHADER.get_spirv()
	if spirv == null or PENDING_PAGE_SHADER.base_error != "" \
			or spirv.bytecode_compute.is_empty() or spirv.compile_error_compute != "":
		_report("Magic GI pending-page shader failed to compile: " + PENDING_PAGE_SHADER.base_error)
		return false
	var allocated := 0
	if not _pending_page_shader.is_valid():
		_pending_page_shader = rd.shader_create_from_spirv(spirv, "Magic GI Pending Page Ownership")
		if not _pending_page_shader.is_valid():
			return false
		allocated += 1
	if not _pending_page_pipeline.is_valid():
		if _page_residency != null and _page_residency.allocation_budget_remaining() < 1:
			if allocated > 0:
				_page_residency.account_allocations(allocated)
			_sync_owned_rid_snapshot()
			return false
	if _pending_page_shader.is_valid():
		_pending_page_pipeline = rd.compute_pipeline_create(_pending_page_shader)
		if not _pending_page_pipeline.is_valid():
			if allocated > 0 and _page_residency != null:
				_page_residency.account_allocations(allocated)
			_sync_owned_rid_snapshot()
			return false
		allocated += 1
	if allocated > 0 and _page_residency != null \
			and not _page_residency.account_allocations(allocated):
		return false
	_sync_owned_rid_snapshot()
	return _pending_page_shader.is_valid() and _pending_page_pipeline.is_valid()

func _render_pending_page(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice,
		page: Dictionary, rect: Rect2i, snapshot: Dictionary) -> void:
	if not _frame_replacement_enabled or not _ensure_pending_page_pipeline(rd) \
			or not _ensure_sampler(rd):
		return
	var color: RID = inputs[0].get_texture(buffers, view)
	var depth: RID = inputs[1].get_texture(buffers, view)
	var orm: RID = inputs[4].get_texture(buffers, view)
	var output: RID = inputs[5].get_texture(buffers, view)
	var sky: RID = _sky_diffuse_input.get_texture(buffers, view)
	if not color.is_valid() or not depth.is_valid() or not orm.is_valid() \
			or not output.is_valid() or not sky.is_valid():
		return
	var resolved: Vector4 = _frame_parameters if _frame_parameters is Vector4 else parameters
	var ownership := clampf(float(snapshot.get("strength", 1.0)) * resolved.x, 0.0, 1.0)
	_active_render_view = view
	if not _write_pending_page_params(rd, page["core_bounds"], rect, snapshot, true, ownership):
		return
	var uniforms: Array[RDUniform] = [U.image(0, color), U.sampled(1, _sampler, depth),
		U.sampled(2, _sampler, orm), U.image(3, output), U.sampled(4, _sampler, sky),
		U.uniform_buffer(5, _pending_page_params_ubo)]
	var uniform_set := UniformSetCacheRD.get_cache(_pending_page_shader, 0, uniforms)
	if not uniform_set.is_valid():
		return
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pending_page_pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, ceili(float(rect.size.x) / 8.0), ceili(float(rect.size.y) / 8.0), 1)
	rd.compute_list_end()

func _render_streamed(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	var output: RID = inputs[5].get_texture(buffers, view)
	if not output.is_valid() or _frame_scene_data == null \
			or view >= _frame_scene_data.get_view_count():
		return
	_active_render_view = view
	var extent: Vector2i = buffers.get_internal_size()
	if extent.x <= 0 or extent.y <= 0:
		return
	rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
	if not _ensure_page_param_buffers(rd):
		return

	var root_snapshot := _frame_snapshot
	_last_clv_cache_backend = _clv_cache_backend(root_snapshot)
	var root_replacement := _frame_replacement_enabled
	var previous_clipmap: RefCounted = _frame_clipmap
	var frame_token := Engine.get_frames_drawn()
	_stream_frame_token = frame_token
	var camera: Transform3D = _frame_scene_data.get_cam_transform()
	var all_ready_pages := PageStream.normalize_streamed_snapshot(root_snapshot)
	var pending_descriptors := _stream_pending_descriptors(root_snapshot)
	var cache_namespace := _stream_cache_namespace(root_snapshot)
	var demand_packet := _stream_gpu_demand_keys(root_snapshot,
		all_ready_pages, pending_descriptors, buffers, extent, frame_token)
	var desired_cache_keys: PackedStringArray = demand_packet.get("keys", PackedStringArray())
	var ready_projections: Array = demand_packet.get("ready_projections", [])
	var pending_projections: Array = demand_packet.get("pending_projections", [])
	var projected_by_key: Dictionary = ready_projections[view] \
			if view < ready_projections.size() and ready_projections[view] is Dictionary else {}
	var projected_pending_by_key: Dictionary = pending_projections[view] \
			if view < pending_projections.size() and pending_projections[view] is Dictionary else {}
	if bool(root_snapshot.get("use_clv", true)) \
			and _clv_cache_backend(root_snapshot) != CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and _stream_pages_have_directional(all_ready_pages):
		_ensure_streamed_clipmap_cache(buffers, view, rd, frame_token)
	var snapshot_budget_value: Variant = root_snapshot.get("streaming_budget", {})
	var stream_budget: Dictionary = snapshot_budget_value if snapshot_budget_value is Dictionary else {}
	var gpu_budget := int(stream_budget.get("gpu_bytes",
		stream_budget.get("gpu_resident_bytes", PageStream.GPU_RESIDENT_BUDGET_BYTES)))
	var upload_budget := int(stream_budget.get("upload_bytes_per_frame",
		PageStream.GPU_UPLOAD_BUDGET_BYTES_PER_FRAME))
	var allocation_budget := int(stream_budget.get("allocations_per_frame", 4))
	_prune_clipmaps(rd)
	var view_cache_reserve := _stream_clipmap_reserve_bytes()
	var global_reserve := maxi(PageStream.GPU_GLOBAL_RESERVE_BYTES,
		int(stream_budget.get("reserved_gpu_bytes", 0)))
	var frame_evictions := _begin_page_residency_frame(frame_token, gpu_budget,
		upload_budget, global_reserve + view_cache_reserve, allocation_budget,
		desired_cache_keys, rd)
	if not frame_evictions.is_empty():
		_sync_owned_rid_snapshot()

	var visible_pages: Array[Dictionary] = []
	var fallback_pages: Array[Dictionary] = []
	var pending_by_key: Dictionary = {}
	for pending_page in pending_descriptors:
		var pending_key := str(pending_page.get("page_key", ""))
		if not pending_key.is_empty():
			pending_by_key[pending_key] = pending_page

	# Each descriptor is immutable. The pass admits and incrementally uploads only
	# pages intersecting this view or the current clipmap prefetch window. This
	# keeps page uploads local while allowing the per-view CLV to warm before a
	# core reaches the screen.
	for page in all_ready_pages:
		var page_key := str(page.get("page_key", ""))
		var core_value: Variant = page.get("core_bounds", AABB())
		if page_key.is_empty() or not core_value is AABB:
			continue
		var core: AABB = core_value
		var selection: Dictionary = projected_by_key.get(page_key, {})
		var projected: Dictionary = selection.get("projection", {})
		var screen_visible := bool(projected.get("visible", false))
		var cache_near := bool(selection.get("cache_near", false))
		if not screen_visible and not cache_near:
			continue
		var cache_key := PageStream.stable_version_key(cache_namespace, page)
		var page_ready := _advance_stream_page(page, cache_key, rd)
		var render_page: Dictionary = page
		if not page_ready:
			# A current light-only revision can wait for its indivisible emission
			# atlas upload while the same immutable page continues using its prior,
			# internally-consistent lighting snapshot.
			var fallback := _stream_page_fallback(root_snapshot, page, cache_key)
			if fallback.is_empty():
				pending_by_key[page_key] = {"page_key": page_key, "core_bounds": core}
				continue
			render_page = fallback
			cache_key = str(render_page.get("_cache_key", cache_key))
		if root_replacement and not bool(render_page.get("replacement_enabled", false)):
			if screen_visible:
				pending_by_key[page_key] = {"page_key": page_key, "core_bounds": core}
			continue
		var rect: Rect2i = projected.get("rect", Rect2i())
		var ready_entry := _prepare_stream_page_for_view(root_snapshot, render_page,
				cache_key, view, rd)
		if bool(ready_entry.get("emission_pending", false)):
			var previous_page := _stream_page_fallback(root_snapshot, page, cache_key)
			if previous_page.is_empty():
				if screen_visible:
					pending_by_key[page_key] = {"page_key": page_key, "core_bounds": core}
				continue
			render_page = previous_page
			cache_key = str(render_page.get("_cache_key", cache_key))
			ready_entry = _prepare_stream_page_for_view(root_snapshot, render_page,
					cache_key, view, rd)
		if ready_entry.is_empty():
			if screen_visible:
				pending_by_key[page_key] = {"page_key": page_key, "core_bounds": core}
			continue
		if bool(ready_entry.get("emission_pending", false)):
			if screen_visible:
				pending_by_key[page_key] = {"page_key": page_key, "core_bounds": core}
			continue
		var selected_page: Dictionary = ready_entry.get("page", render_page)
		selected_page = selected_page.duplicate(false)
		selected_page["_cache_key"] = cache_key
		selected_page["_snapshot"] = ready_entry.get("snapshot", {})
		_page_ready_by_key[_stream_owner_page_key(root_snapshot, selected_page)] = cache_key
		fallback_pages.append(selected_page)
		if screen_visible:
			selected_page["_dispatch_rect"] = projected.get("rect", Rect2i())
			visible_pages.append(selected_page)
			pending_by_key.erase(page_key)

	var pending_to_draw: Array[Dictionary] = []
	var pending_keys: Array = pending_by_key.keys()
	pending_keys.sort()
	for key_value in pending_keys:
		var pending: Dictionary = pending_by_key[key_value]
		var core_value: Variant = pending.get("core_bounds", AABB())
		if not core_value is AABB:
			continue
		# During a same-core revision transition, keep the previous immutable page
		# visible until the replacement has completed upload and relighting.
		var previous_page := _stream_page_fallback(root_snapshot, pending, "")
		if not previous_page.is_empty():
			var previous_key := str(_page_ready_by_key.get(
				_stream_owner_page_key(root_snapshot, pending), ""))
			var previous_snapshot := PageStream.page_snapshot(root_snapshot,
				previous_page, previous_key)
			var previous_entry := _prepare_stream_page_for_view(root_snapshot,
				previous_page, previous_key, view, rd)
			if not previous_entry.is_empty() and not bool(previous_entry.get("emission_pending", false)):
				var previous_ready: Dictionary = previous_entry.get("page", previous_page).duplicate(false)
				previous_ready["_cache_key"] = previous_key
				previous_ready["_snapshot"] = previous_entry.get("snapshot", previous_snapshot)
				fallback_pages.append(previous_ready)
				var old_projection_entry: Dictionary = projected_pending_by_key.get(
					str(pending.get("page_key", "")), {})
				var old_projection: Dictionary = old_projection_entry.get("projection", {})
				if bool(old_projection.get("visible", false)):
					previous_ready["_dispatch_rect"] = old_projection.get("rect", Rect2i())
					visible_pages.append(previous_ready)
					continue
		var core: AABB = core_value
		var pending_projection: Dictionary = projected_pending_by_key.get(
			str(pending.get("page_key", "")), {}).get("projection", {})
		var projected := pending_projection
		if not bool(projected.get("visible", false)):
			continue
		pending["_dispatch_rect"] = projected.get("rect", Rect2i())
		pending_to_draw.append(pending)

	# CLV cache is unique per render target/view, never per page. Page revisions
	# enqueue only their owner cells; camera movement enqueues only entering slabs.
	_frame_clipmap = null
	if bool(root_snapshot.get("use_clv", true)):
		_frame_clipmap = _update_streamed_clipmap(buffers, view, rd, root_snapshot,
				fallback_pages, camera.origin, frame_token)

	for page in visible_pages:
		var page_snapshot: Dictionary = page.get("_snapshot", {})
		var page_cache_key := str(page.get("_cache_key", ""))
		var rect: Rect2i = page.get("_dispatch_rect", Rect2i())
		if page_snapshot.is_empty() or page_cache_key.is_empty() \
				or rect.size.x <= 0 or rect.size.y <= 0:
			continue
		_render_stream_page(buffers, view, rd, page, page_snapshot,
				page_cache_key, rect, root_snapshot)

	# Unknown manifest-covered cores keep SkyDiffuse ownership while their page is
	# loading, over budget, or failed. They are never treated as valid black pages.
	for page in pending_to_draw:
		_render_pending_page(buffers, view, rd, page,
				page.get("_dispatch_rect", Rect2i()), root_snapshot)

	_stream_dispatch_active = false
	_stream_dispatch_rect = Rect2i()
	_stream_dispatch_extent = Vector2i()
	_frame_snapshot = root_snapshot
	_frame_replacement_enabled = root_replacement
	_frame_clipmap = previous_clipmap
	_cache_clock += 1
	_prune_clipmaps(rd)
	_sync_owned_rid_snapshot()


func _stream_pending_descriptors(snapshot: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen: Dictionary = {}
	var explicit_pages: Variant = snapshot.get("pending_pages", [])
	if explicit_pages is Array:
		for value in explicit_pages:
			if value is Dictionary and value.get("core_bounds") is AABB:
				var page_key := str(value.get("page_key", ""))
				if not page_key.is_empty() and not seen.has(page_key):
					seen[page_key] = true
					result.append(value)
	var keys_value: Variant = snapshot.get("pending_page_keys", PackedStringArray())
	var manifest: Variant = snapshot.get("manifest")
	if keys_value is PackedStringArray and manifest is Object:
		for page_key in keys_value:
			if seen.has(page_key):
				continue
			var metadata := PageStream.descriptor_for_key(manifest, String(page_key))
			if not metadata.is_empty() and metadata.get("core_bounds") is AABB:
				seen[String(page_key)] = true
				result.append(metadata)
	return result


func _aabb_intersects(first: AABB, second: AABB) -> bool:
	var first_end := first.position + first.size
	var second_end := second.position + second.size
	return first.size.x > 0.0 and first.size.y > 0.0 and first.size.z > 0.0 \
			and second.size.x > 0.0 and second.size.y > 0.0 and second.size.z > 0.0 \
			and first.position.x < second_end.x and first_end.x > second.position.x \
			and first.position.y < second_end.y and first_end.y > second.position.y \
			and first.position.z < second_end.z and first_end.z > second.position.z


func _advance_stream_page(page: Dictionary, cache_key: String,
		rd: RenderingDevice) -> bool:
	var page_key := str(page.get("page_key", ""))
	var page_version := int(page.get("version", -1))
	if page_key.is_empty() or cache_key.is_empty() or page_version < 0:
		return false
	if _stream_page_failed_for_revision(cache_key, page_version):
		return false
	if _bake_resources.has(cache_key):
		var cached: Dictionary = _bake_resources[cache_key]
		var ledger_entry: Dictionary = _page_residency.entry(cache_key)
		if not ledger_entry.is_empty() and int(cached.get("gpu_bytes", -1)) \
				== int(ledger_entry.get("gpu_bytes", -2)) \
				and int(cached.get("source_gpu_bytes", -1)) == int(page.get("gpu_bytes", -2)) \
				and _stream_cached_page_valid(cached, page):
			_page_residency.touch(cache_key)
			return true
		_release_stream_page_resources(cache_key, rd, not ledger_entry.is_empty())

	var uploader: RefCounted = _page_uploads.get(cache_key)
	if uploader == null:
		var upload_page := _page_with_probe_clusters(page)
		var page_bytes := int(upload_page.get("gpu_bytes", 0))
		var admission := _admit_stream_page(cache_key, page_key, page_bytes, rd)
		if not bool(admission.get("admitted", false)):
			return false
		uploader = PageUpload.new()
		_page_uploads[cache_key] = uploader
		if not uploader.begin(rd, upload_page, cache_key):
			_report("Magic GI page %s could not begin upload: %s" % [page_key, uploader.error])
			_rollback_failed_stream_page(cache_key, page_version, rd)
			return false
		_sync_owned_rid_snapshot()
	if uploader.failed():
		_report("Magic GI page %s upload failed: %s" % [page_key, uploader.error])
		_rollback_failed_stream_page(cache_key, page_version, rd)
		return false

	var allocation_remaining: int = _page_residency.allocation_budget_remaining()
	if allocation_remaining > 0 and uploader.has_pending_allocations():
		var allocation_count: int = uploader.allocate_step(rd, mini(2, allocation_remaining))
		if allocation_count < 0 or not _page_residency.account_allocations(allocation_count):
			_report("Magic GI page %s allocation transaction failed." % page_key)
			_rollback_failed_stream_page(cache_key, page_version, rd)
			return false
		var actual_page_bytes := int(uploader.call("gpu_bytes"))
		var reservation: Dictionary = _page_residency.entry(cache_key)
		if not reservation.is_empty() and actual_page_bytes > 0 \
				and actual_page_bytes < int(reservation.get("gpu_bytes", 0)) \
				and not _page_residency.reduce_gpu_bytes(cache_key, actual_page_bytes):
			_report("Magic GI page %s could not reconcile optional cluster-buffer fallback bytes." % page_key)
			_rollback_failed_stream_page(cache_key, page_version, rd)
			return false
		if allocation_count > 0:
			# RIDs become owned as soon as they are allocated, even while the page is
			# still staged across frames. Keep teardown's ownership snapshot current.
			_sync_owned_rid_snapshot()
	if uploader.failed():
		_report("Magic GI page %s allocation failed: %s" % [page_key, uploader.error])
		_rollback_failed_stream_page(cache_key, page_version, rd)
		return false

	var remaining_upload: int = _page_residency.upload_budget_remaining()
	if remaining_upload > 0 and uploader.has_pending_uploads():
		var uploaded: int = uploader.upload_step(rd, remaining_upload)
		if uploaded < 0 or not _page_residency.account_upload(uploaded):
			_report("Magic GI page %s upload transaction failed." % page_key)
			_rollback_failed_stream_page(cache_key, page_version, rd)
			return false
	if uploader.failed():
		_report("Magic GI page %s upload failed: %s" % [page_key, uploader.error])
		_rollback_failed_stream_page(cache_key, page_version, rd)
		return false
	if not uploader.is_ready():
		return false

	var ready_cache: Dictionary = uploader.take_ready_cache()
	if ready_cache.is_empty():
		_report("Magic GI page %s completed without a transferable GPU cache." % page_key)
		_rollback_failed_stream_page(cache_key, page_version, rd)
		return false
	ready_cache["page_key"] = page_key
	ready_cache["identity"] = str(page.get("identity", ""))
	ready_cache["page_revision"] = page_version
	ready_cache["source_gpu_bytes"] = int(page.get("gpu_bytes", 0))
	ready_cache["gpu_bytes"] = int(ready_cache.get("gpu_bytes", page.get("gpu_bytes", 0)))
	ready_cache["published_page"] = page.duplicate(false)
	ready_cache["last_used"] = _cache_clock
	_bake_resources[cache_key] = ready_cache
	_page_residency.mark_ready(cache_key)
	_sync_owned_rid_snapshot()
	return true


func _stream_cached_page_valid(cached: Dictionary, page: Dictionary) -> bool:
	var data_value: Variant = page.get("data")
	if not data_value is Resource or int(cached.get("data_id", -1)) != data_value.get_instance_id() \
			or int(cached.get("version", -1)) != int(page.get("version", -2)):
		return false
	for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
			"visibility_nodes", "visibility_triangles", "indices", "index_entries",
			"emission", "probe_lighting", "probe_clusters"]:
		var rid: RID = cached.get(name, RID())
		if not rid.is_valid():
			return false
	var directional: RefCounted = cached.get("directional")
	return directional == null or directional.is_ready()


func _page_with_probe_clusters(page: Dictionary) -> Dictionary:
	var result := page.duplicate(false)
	var data_value: Variant = page.get("data")
	var data: Resource = data_value if data_value is Resource else null
	var generation := int(page.get("version", data.get("bake_version") if data != null else -1))
	var geometry_revision := int(page.get("geometry_revision", generation))
	var signature := ProbeClusters.cache_key(data.get_instance_id() if data != null else -1,
		generation, geometry_revision)
	var payload: Dictionary = _probe_cluster_cached_payload(signature)
	if payload.is_empty():
		var dimensions: Vector3i = data.get("grid_dims") if data != null else Vector3i.ZERO
		var probe_count := int(data.call("probe_count")) \
				if data != null and data.has_method("probe_count") else 0
		var upload_value: Variant = page.get("render_upload", {})
		var upload: Dictionary = upload_value if upload_value is Dictionary else {}
		var current_geometry_format := data != null and int(data.get("format_version")) >= 6
		payload = ProbeClusters.build(upload, dimensions, probe_count, signature,
			current_geometry_format)
		_cache_probe_cluster_payload(signature, payload)
	var bytes_value: Variant = payload.get("bytes")
	var bytes: PackedByteArray = bytes_value if bytes_value is PackedByteArray else PackedByteArray()
	if bytes.size() < ProbeClusters.HEADER_BYTES:
		payload = ProbeClusters.disabled_payload(signature)
		bytes = payload["bytes"]
		_cache_probe_cluster_payload(signature, payload)
	result["probe_cluster_payload"] = payload
	result["probe_cluster_signature"] = signature
	result["source_gpu_bytes"] = int(page.get("gpu_bytes", 0))
	result["gpu_bytes"] = maxi(0, int(page.get("gpu_bytes", 0))) + bytes.size()
	return result


func _probe_cluster_cached_payload(signature: String) -> Dictionary:
	if not _probe_cluster_payload_cache.has(signature):
		return {}
	_probe_cluster_payload_cache_clock += 1
	var entry: Dictionary = _probe_cluster_payload_cache[signature]
	entry["last_used"] = _probe_cluster_payload_cache_clock
	_probe_cluster_payload_cache[signature] = entry
	var payload: Variant = entry.get("payload")
	return payload if payload is Dictionary else {}


func _cache_probe_cluster_payload(signature: String, payload: Dictionary) -> void:
	if signature.is_empty():
		return
	var existing: Dictionary = _probe_cluster_payload_cache.get(signature, {})
	_probe_cluster_payload_cache_bytes -= int(existing.get("byte_count", 0))
	_probe_cluster_payload_cache_clock += 1
	var bytes_value: Variant = payload.get("bytes")
	var byte_count: int = bytes_value.size() if bytes_value is PackedByteArray else 0
	_probe_cluster_payload_cache[signature] = {"payload": payload,
		"last_used": _probe_cluster_payload_cache_clock, "byte_count": byte_count}
	_probe_cluster_payload_cache_bytes += byte_count
	while _probe_cluster_payload_cache.size() > PROBE_CLUSTER_CPU_CACHE_LIMIT \
			or _probe_cluster_payload_cache_bytes > PROBE_CLUSTER_CPU_CACHE_BYTES:
		var oldest_signature := ""
		var oldest_clock := 0x7fffffff
		for candidate in _probe_cluster_payload_cache:
			if str(candidate) == signature:
				continue
			var candidate_clock := int(_probe_cluster_payload_cache[candidate].get("last_used", 0))
			if candidate_clock < oldest_clock:
				oldest_clock = candidate_clock
				oldest_signature = str(candidate)
		if oldest_signature.is_empty():
			break
		var removed: Dictionary = _probe_cluster_payload_cache[oldest_signature]
		_probe_cluster_payload_cache_bytes -= int(removed.get("byte_count", 0))
		_probe_cluster_payload_cache.erase(oldest_signature)


func _stream_cache_namespace(snapshot: Dictionary) -> String:
	return "%d:%d:%s" % [int(snapshot.get("world_id", -1)),
		int(snapshot.get("volume_id", -1)), str(snapshot.get("manifest_key", ""))]


func _stream_owner_page_key(snapshot: Dictionary, page: Dictionary) -> String:
	return "%d:%d:%s" % [int(snapshot.get("world_id", -1)),
		int(snapshot.get("volume_id", -1)), str(page.get("page_key", ""))]


func _nonzero_clv_epoch(value: int) -> int:
	var token := value & 0x7fffffff
	return 1 if token == 0 else token


func _nonstream_clv_geometry_epoch(snapshot: Dictionary, cache_key: String,
		data_id: int, version: int) -> int:
	# This token describes the immutable bake whose geometry generated the cache.
	# Lighting revisions belong to the refresh queue and must not invalidate tags.
	return _nonzero_clv_epoch(hash([int(snapshot.get("world_id", -1)),
		int(snapshot.get("volume_id", -1)), cache_key, data_id, version,
		float(snapshot.get("clv_cell_size", 0.5)),
		_clv_layout_version_for_backend(_clv_cache_backend(snapshot))]))


func _nonstream_clv_content_revision(snapshot: Dictionary, cached: Dictionary,
		directional_epoch: int) -> int:
	return int(hash([directional_epoch,
		str(snapshot.get("emission_identity", "")),
		int(snapshot.get("emission_revision", 0)),
		str(cached.get("emission_identity", "")),
		int(cached.get("emission_revision", -1))]) & 0x7fffffff)


func _stream_manifest_geometry_epoch(snapshot: Dictionary, spacing: float) -> int:
	return _nonzero_clv_epoch(hash([int(snapshot.get("world_id", -1)),
		int(snapshot.get("volume_id", -1)), str(snapshot.get("manifest_key", "")),
		str(snapshot.get("generation", "")), spacing, CLV_LEGACY_LAYOUT_VERSION]))


func _stream_page_geometry_epoch(snapshot: Dictionary, page: Dictionary,
		spacing: float) -> int:
	return _nonzero_clv_epoch(hash([int(snapshot.get("world_id", -1)),
		int(snapshot.get("volume_id", -1)), str(snapshot.get("manifest_key", "")),
		str(snapshot.get("generation", "")),
		str(page.get("page_key", "")), str(page.get("identity", "")),
		str(page.get("content_hash", "")), int(page.get("version", -1)),
		spacing, CLV_LEGACY_LAYOUT_VERSION]))


func _stream_page_content_revision(page: Dictionary, directional_epoch: int) -> int:
	return int(hash([directional_epoch,
		str(page.get("emission_identity", "")),
		int(page.get("emission_revision", page.get("revision", 0)))]) & 0x7fffffff)


func _project_streamed_pages(pages: Array[Dictionary], projection: Projection,
		camera_position: Vector3, extent: Vector2i, world_to_view: Transform3D,
		cache_bounds: AABB) -> Dictionary:
	var result: Dictionary = {}
	for page in pages:
		var page_key := str(page.get("page_key", ""))
		var core_value: Variant = page.get("core_bounds", AABB())
		if page_key.is_empty() or not core_value is AABB:
			continue
		var core: AABB = core_value
		result[page_key] = {
			"projection": PageStream.project_core(core, projection,
				camera_position, extent, world_to_view),
			"cache_near": _aabb_intersects(core, cache_bounds),
		}
	return result


func _stream_gpu_demand_keys(root_snapshot: Dictionary, pages: Array[Dictionary],
		pending_pages: Array[Dictionary], buffers: RenderSceneBuffersRD,
		extent: Vector2i, frame_token: int) -> Dictionary:
	if _stream_demand_frame_token != frame_token:
		_stream_demand_frame_token = frame_token
		_stream_frame_demands.clear()
	if _frame_scene_data == null:
		return {}
	var target: RID = buffers.get_render_target()
	var target_id := target.get_id() if target.is_valid() else buffers.get_instance_id()
	var cache_namespace := _stream_cache_namespace(root_snapshot)
	var clv_spacing := maxf(float(root_snapshot.get("clv_cell_size", 0.5)), 0.1)
	var clv_radius := float(_effective_clv_resolution()) * clv_spacing
	var view_count := _frame_scene_data.get_view_count()
	var camera: Transform3D = _frame_scene_data.get_cam_transform()
	var world_to_view := Transform3D(camera.basis.orthonormalized(), camera.origin).affine_inverse()
	var cache_bounds := AABB(camera.origin - Vector3.ONE * clv_radius,
		Vector3.ONE * clv_radius * 2.0)
	var projections: Array[Projection] = []
	for candidate_view in range(view_count):
		projections.append(_frame_scene_data.get_view_projection(candidate_view))
	var input_signature := _stream_projection_input_signature(pages, pending_pages)
	var demand_key := var_to_str([target_id, frame_token, cache_namespace,
		str(root_snapshot.get("generation", "")), extent, view_count, input_signature])
	var scene_data_id := _frame_scene_data.get_instance_id()
	# The packet is shared by every view of this immutable frame snapshot. Exact
	# camera/projection checks also cover captures that reuse a target in one frame.
	if _stream_frame_demands.has(demand_key):
		var cached_packet: Dictionary = _stream_frame_demands[demand_key]
		if int(cached_packet.get("scene_data_id", -1)) == scene_data_id \
				and cached_packet.get("camera", Transform3D()) == camera \
				and cached_packet.get("projections", []) == projections \
				and float(cached_packet.get("clv_spacing", -1.0)) == clv_spacing:
			return cached_packet

	var ready_projections: Array[Dictionary] = []
	var pending_projections: Array[Dictionary] = []
	var requested: Dictionary = {}
	# Demand selection already needs the projection of every view. Keep those maps
	# for the later per-view draw instead of projecting the same page boxes again.
	for candidate_view in range(view_count):
		var projection: Projection = projections[candidate_view]
		var ready_projection := _project_streamed_pages(pages, projection,
			camera.origin, extent, world_to_view, cache_bounds)
		var pending_projection := _project_streamed_pages(pending_pages, projection,
			camera.origin, extent, world_to_view, cache_bounds)
		ready_projections.append(ready_projection)
		pending_projections.append(pending_projection)
		for page in pages:
			var core_value: Variant = page.get("core_bounds", AABB())
			if not core_value is AABB:
				continue
			var projected_entry: Dictionary = ready_projection.get(
				str(page.get("page_key", "")), {})
			var projected: Dictionary = projected_entry.get("projection", {})
			if not bool(projected.get("visible", false)) \
					and not bool(projected_entry.get("cache_near", false)):
				continue
			var cache_key := PageStream.stable_version_key(cache_namespace, page)
			if not cache_key.is_empty():
				requested[cache_key] = true
			var previous := _stream_page_fallback(root_snapshot, page, cache_key)
			if not previous.is_empty():
				var previous_key := str(_page_ready_by_key.get(
					_stream_owner_page_key(root_snapshot, page), ""))
				if not previous_key.is_empty():
					requested[previous_key] = true
		for pending_page in pending_pages:
			var core_value: Variant = pending_page.get("core_bounds", AABB())
			if not core_value is AABB:
				continue
			var projected_entry: Dictionary = pending_projection.get(
				str(pending_page.get("page_key", "")), {})
			var projected: Dictionary = projected_entry.get("projection", {})
			if not bool(projected.get("visible", false)) \
					and not bool(projected_entry.get("cache_near", false)):
				continue
			var previous := _stream_page_fallback(root_snapshot, pending_page, "")
			if previous.is_empty():
				continue
			var previous_key := str(_page_ready_by_key.get(
				_stream_owner_page_key(root_snapshot, pending_page), ""))
			if not previous_key.is_empty():
				requested[previous_key] = true
	var result := PackedStringArray()
	for key in requested:
		result.append(String(key))
	result.sort()
	var packet := {
		"keys": result,
		"ready_projections": ready_projections,
		"pending_projections": pending_projections,
		"scene_data_id": scene_data_id,
		"camera": camera,
		"projections": projections,
		"clv_spacing": clv_spacing,
	}
	_stream_frame_demands[demand_key] = packet
	return packet


func _stream_projection_input_signature(pages: Array[Dictionary],
		pending_pages: Array[Dictionary]) -> Array:
	var entries: Array = []
	for page in pages:
		var core_value: Variant = page.get("core_bounds", AABB())
		if not core_value is AABB:
			continue
		var data_value: Variant = page.get("data")
		var data_id: int = data_value.get_instance_id() if data_value is Resource else -1
		entries.append([0, str(page.get("page_key", "")),
			str(page.get("identity", "")), int(page.get("version", -1)),
			int(page.get("emission_revision", page.get("revision", 0))), data_id,
			core_value.position, core_value.size])
	for page in pending_pages:
		var core_value: Variant = page.get("core_bounds", AABB())
		if not core_value is AABB:
			continue
		entries.append([1, str(page.get("page_key", "")),
			core_value.position, core_value.size])
	entries.sort_custom(func(a: Array, b: Array) -> bool:
		return var_to_str(a) < var_to_str(b))
	return entries


func _stream_page_fallback(root_snapshot: Dictionary, page: Dictionary,
		cache_key: String) -> Dictionary:
	var old_key := str(_page_ready_by_key.get(_stream_owner_page_key(root_snapshot, page), ""))
	if old_key.is_empty() or not _bake_resources.has(old_key) \
			or _page_residency == null or not _page_residency.is_ready(old_key):
		return {}
	var cached: Dictionary = _bake_resources[old_key]
	var previous: Variant = cached.get("published_page", {})
	if not previous is Dictionary:
		return {}
	var old_core: Variant = previous.get("core_bounds")
	var new_core: Variant = page.get("core_bounds")
	if not old_core is AABB or not new_core is AABB or old_core != new_core:
		return {}
	if cache_key == old_key and (str(cached.get("identity", "")) != str(page.get("identity", "")) \
			or int(cached.get("page_revision", -1)) != int(page.get("version", -2))):
		return {}
	var result: Dictionary = previous.duplicate(false)
	result["_cache_key"] = old_key
	return result


func _prepare_stream_page_for_view(root_snapshot: Dictionary, page: Dictionary,
		cache_key: String, view: int, rd: RenderingDevice) -> Dictionary:
	if not _bake_resources.has(cache_key):
		return {}
	var cached: Dictionary = _bake_resources[cache_key]
	var page_snapshot := PageStream.page_snapshot(root_snapshot, page, cache_key)
	var previous_snapshot := _frame_snapshot
	var previous_replacement := _frame_replacement_enabled
	_frame_snapshot = page_snapshot
	_frame_replacement_enabled = previous_replacement \
			and bool(page_snapshot.get("replacement_enabled", true))
	if not _update_stream_emission_texture(cache_key, page_snapshot, rd):
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
		return {"page": page, "snapshot": page_snapshot, "emission_pending": true}
	# Relighting consumes the frame UBO only when its sources changed. Pixel
	# application and CLV jobs prepare their own view/page UBO before dispatch.
	if cached.get("lighting_sources", []) != _probe_lighting_sources(cached, page_snapshot):
		if not _update_frame_ubo(page_snapshot, _frame_scene_data, view, rd) \
				or not _update_probe_lighting(cache_key, page_snapshot, rd):
			_frame_snapshot = previous_snapshot
			_frame_replacement_enabled = previous_replacement
			return {}
	cached = _bake_resources[cache_key]
	cached["published_page"] = page.duplicate(false)
	cached["last_used"] = _cache_clock
	_bake_resources[cache_key] = cached
	_frame_snapshot = previous_snapshot
	_frame_replacement_enabled = previous_replacement
	return {"page": page, "snapshot": page_snapshot}


func _update_stream_emission_texture(cache_key: String, page: Dictionary,
		rd: RenderingDevice) -> bool:
	if not _bake_resources.has(cache_key):
		return false
	var cached: Dictionary = _bake_resources[cache_key]
	var identity := str(page.get("identity", ""))
	var revision := int(page.get("emission_revision", page.get("revision", 0)))
	if str(cached.get("emission_identity", "")) == identity \
			and int(cached.get("emission_revision", -1)) == revision:
		return true
	var image_value: Variant = page.get("emission_image")
	if not image_value is Image or image_value.is_empty():
		return false
	var image: Image = image_value
	if image.get_size() != cached.get("emission_size", image.get_size()) \
			or image.get_format() != cached.get("emission_format", image.get_format()):
		return false # A size/format change requires a new immutable page identity.
	var byte_count := PageStream.image_byte_count(image)
	if byte_count <= 0 or byte_count > _page_residency.upload_budget_remaining():
		return false
	var bytes := image.get_data()
	if bytes.size() != byte_count:
		return false
	var emission_rid: RID = cached.get("emission", RID())
	if not emission_rid.is_valid() or rd.texture_update(emission_rid, 0, bytes) != OK:
		return false
	if not _page_residency.account_upload(bytes.size()):
		return false # The same render thread owns the ledger; this guards future callers.
	cached["emission_identity"] = identity
	cached["emission_revision"] = revision
	_bake_resources[cache_key] = cached
	return true


func _stream_clipmap_reserve_bytes() -> int:
	var result := 0
	for entry: Dictionary in _clipmaps.values():
		result += int(entry.get("gpu_bytes", ClipmapCache.estimate_gpu_bytes()))
	if _probe_cluster_fallback.is_valid():
		result += 16
	if not _clv_fallback.is_empty():
		result += 16 + 16 + 4 + 80 + 320
	return result


func _stream_pages_have_directional(pages: Array[Dictionary]) -> bool:
	for page in pages:
		var data: Variant = page.get("data")
		if data is Resource and data.get("directional") != null:
			return true
	return false


func _ensure_streamed_clipmap_cache(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice, frame_token: int) -> RefCounted:
	var target: RID = buffers.get_render_target()
	var target_id := target.get_id() if target.is_valid() else buffers.get_instance_id()
	var clip_key := "stream:%d:%d" % [target_id, view]
	if _clipmaps.has(clip_key):
		var existing: Dictionary = _clipmaps[clip_key]
		var owner_ref: WeakRef = existing.get("owner")
		if owner_ref != null and owner_ref.get_ref() == buffers \
				and _clipmap_layout_is_current(existing):
			existing["last_used"] = frame_token
			_clipmaps[clip_key] = existing
			return existing.cache
		var old_cache: RefCounted = existing.get("cache")
		if old_cache != null:
			_free_rids(rd, old_cache.owned_rids())
		_clipmaps.erase(clip_key)
		_sync_owned_rid_snapshot()
	var clipmap := ClipmapCache.new()
	if not clipmap.create(rd, _effective_clv_resolution()):
		_free_rids(rd, clipmap.owned_rids())
		return null
	_clipmaps[clip_key] = {"cache": clipmap, "owner": weakref(buffers),
		"last_used": frame_token, "resolution": int(clipmap.get("resolution")),
		"gpu_bytes": ClipmapCache.estimate_gpu_bytes(int(clipmap.get("resolution"))),
		"layout_version": CLV_LEGACY_LAYOUT_VERSION, "streamed": true, "bake": ""}
	_sync_owned_rid_snapshot()
	return clipmap



func _clipmap_layout_is_current(entry: Dictionary, backend := -1,
		requested_format_override := -1, expected_dynamic_emitters := -1) -> bool:
	if backend < 0:
		backend = int(entry.get("cache_backend", CLV_CACHE_BACKEND_LEGACY))
	if int(entry.get("layout_version", -1)) != _clv_layout_version_for_backend(backend) \
			or int(entry.get("cache_backend", CLV_CACHE_BACKEND_LEGACY)) != backend \
			or int(entry.get("resolution", -1)) != _effective_clv_resolution(backend):
		return false
	if backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and _clv_internal_test_layout == CLV_INTERNAL_LAYOUT_AUTHORED:
		var dynamic_cache: RefCounted = entry.get("cache")
		if not bool(entry.get("dynamic_transfer", false)) \
				or dynamic_cache == null or not dynamic_cache.has_method("get_runtime_state"):
			return false
		var dynamic_state_value: Variant = dynamic_cache.call("get_runtime_state")
		if not dynamic_state_value is Dictionary:
			return false
		var dynamic_state: Dictionary = dynamic_state_value
		var dynamic_emitters := int(entry.get("emitter_count", -1))
		if expected_dynamic_emitters >= 0 and dynamic_emitters != expected_dynamic_emitters:
			return false
		var expected_gpu_bytes := ClipmapCache.estimate_gpu_bytes(
				_effective_clv_resolution(backend), true, maxi(dynamic_emitters, 0))
		return int(dynamic_state.get("layout_version", -1)) \
				== CLV_MAGICDAWN_DYNAMIC_PRT_LAYOUT_VERSION \
			and bool(dynamic_state.get("transfer_matrix_valid", false)) \
			and int(dynamic_state.get("transfer_matrix_emitters", -1)) == dynamic_emitters \
			and int(dynamic_state.get("resident_resolution", -1)) \
				== _effective_clv_resolution(backend) \
			and int(entry.get("gpu_bytes", -1)) == expected_gpu_bytes \
			and dynamic_cache.get("texture").is_valid() \
			and dynamic_cache.get("tags").is_valid() \
			and dynamic_cache.get("support").is_valid() \
			and dynamic_cache.get("parameters").is_valid() \
			and dynamic_cache.get("transfer_matrix").is_valid()
		# The legacy static layout-17 producer remains isolated from the authored
		# backend-1 selector; it must never be mistaken for a dynamic layout-9 cache.
		return false
	return int(entry.get("gpu_bytes", -1)) == _clv_gpu_bytes_for_backend(
			backend, _effective_clv_resolution(backend))

func _effective_prepared_clv_resolution() -> int:
	if prepared_clv_resolution >= 32:
		return 32
	return 24 if prepared_clv_resolution >= 24 else 16

func _effective_clv_resolution(backend := -1) -> int:
	var selected_backend := backend
	if selected_backend < 0:
		selected_backend = _clv_cache_backend(_frame_snapshot) \
				if not _frame_snapshot.is_empty() else _last_clv_cache_backend
	if selected_backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			and _clv_internal_test_layout == CLV_INTERNAL_LAYOUT_AUTHORED:
		if prt_clv_resolution >= 32:
			return 32
		if prt_clv_resolution >= 24:
			return 24
		return 16
	return ClipmapCache.EXPANDED_RESOLUTION \
			if prt_clv_resolution >= ClipmapCache.EXPANDED_RESOLUTION \
			else ClipmapCache.RESOLUTION


static func _valid_clv_focus_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
			and bounds.size.x >= 0.0 and bounds.size.y >= 0.0 and bounds.size.z >= 0.0


static func _magicdawn_world_focus_domain(source_bounds: AABB,
		snapshot: Dictionary) -> AABB:
	var invalid := AABB(Vector3.ZERO, Vector3.ONE * -1.0)
	if not _valid_clv_focus_bounds(source_bounds):
		return invalid
	var transform_value: Variant = snapshot.get("owner_transform")
	var size_value: Variant = snapshot.get("owner_size")
	if not transform_value is Transform3D or not size_value is Vector3:
		return invalid
	var owner_transform: Transform3D = transform_value
	var owner_size: Vector3 = size_value
	if not owner_transform.origin.is_finite() or not owner_size.is_finite() \
			or owner_size.x <= 0.0 or owner_size.y <= 0.0 or owner_size.z <= 0.0 \
			or not owner_transform.basis.x.is_finite() \
			or not owner_transform.basis.y.is_finite() \
			or not owner_transform.basis.z.is_finite():
		return invalid
	var half_extent := (owner_transform.basis.x.abs() * owner_size.x \
			+ owner_transform.basis.y.abs() * owner_size.y \
			+ owner_transform.basis.z.abs() * owner_size.z) * 0.5
	var owner_lower := owner_transform.origin - half_extent
	var owner_upper := owner_transform.origin + half_extent
	var source_upper := source_bounds.position + source_bounds.size
	var lower := Vector3(maxf(source_bounds.position.x, owner_lower.x),
		maxf(source_bounds.position.y, owner_lower.y),
		maxf(source_bounds.position.z, owner_lower.z))
	var upper := Vector3(minf(source_upper.x, owner_upper.x),
		minf(source_upper.y, owner_upper.y),
		minf(source_upper.z, owner_upper.z))
	if upper.x < lower.x or upper.y < lower.y or upper.z < lower.z:
		return invalid
	return AABB(lower, upper - lower)


static func _union_clv_source_bounds(source_bounds: Array[AABB]) -> AABB:
	var result := AABB()
	var has_bounds := false
	for bounds in source_bounds:
		if not _valid_clv_focus_bounds(bounds):
			continue
		result = result.merge(bounds) if has_bounds else bounds
		has_bounds = true
	return result if has_bounds else AABB(Vector3.ZERO, Vector3.ONE * -1.0)


func _update_streamed_clipmap(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice, root_snapshot: Dictionary,
		ready_pages: Array[Dictionary], camera: Vector3, frame_token: int) -> RefCounted:
	_last_clv_cache_backend = _clv_cache_backend(root_snapshot)
	# The first block-chart backend is an immutable local-bake path. Do not silently
	# feed streamed-page data into the legacy 3-axis consumer when it is selected.
	# Returning no cache leaves the apply shader on its exact PRT source fallback.
	if _clv_cache_backend(root_snapshot) == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART:
		return null
	if ready_pages.is_empty():
		return null
	var pages_with_directional: Array[Dictionary] = []
	var source_bounds_for_focus: Array[AABB] = []
	var pages_by_key: Dictionary = {}
	for page in ready_pages:
		var cache_key := str(page.get("_cache_key", ""))
		if cache_key.is_empty() or not _bake_resources.has(cache_key):
			continue
		var cached: Dictionary = _bake_resources[cache_key]
		if cached.get("directional") == null:
			continue
		var page_key := str(page.get("page_key", ""))
		if page_key.is_empty():
			continue
		pages_with_directional.append(page)
		var source_bounds_value: Variant = cached.get("source_bounds", AABB())
		if source_bounds_value is AABB:
			var source_bounds: AABB = source_bounds_value
			if _valid_clv_focus_bounds(source_bounds):
				source_bounds_for_focus.append(source_bounds)
		pages_by_key[page_key] = page
	if pages_with_directional.is_empty():
		return null
	var target: RID = buffers.get_render_target()
	var target_id := target.get_id() if target.is_valid() else buffers.get_instance_id()
	var clip_key := "stream:%d:%d" % [target_id, view]
	var clipmap_value: RefCounted = _ensure_streamed_clipmap_cache(buffers,
		view, rd, frame_token)
	if clipmap_value == null:
		return null
	var entry: Dictionary = _clipmaps[clip_key]
	entry["last_used"] = frame_token
	_clipmaps[clip_key] = entry
	var clipmap: RefCounted = clipmap_value
	var spacing := float(root_snapshot.get("clv_cell_size", 0.5))
	var manifest_epoch := _stream_manifest_geometry_epoch(root_snapshot, spacing)
	var focus := camera
	var focus_bounds := _union_clv_source_bounds(source_bounds_for_focus)
	if _valid_clv_focus_bounds(focus_bounds):
		focus = ClipmapCache.focus_for_bounds(camera, focus_bounds, spacing,
				int(clipmap.get("resolution")))
	clipmap.queue_updates(focus, spacing, manifest_epoch)
	if not clipmap.update_parameters(rd, spacing, manifest_epoch,
			approximate_clv_volume_enabled,
			exact_clv_corner_visibility_enabled,
			approximate_clv_ready_bit_enabled):
		return null
	var retained_keys := PackedStringArray()
	for page in pages_with_directional:
		var page_key := str(page.get("page_key", ""))
		var cache_key := str(page.get("_cache_key", ""))
		var cached: Dictionary = _bake_resources[cache_key]
		var directional: RefCounted = cached.get("directional")
		var geometry_epoch := _stream_page_geometry_epoch(root_snapshot, page, spacing)
		var content_revision := _stream_page_content_revision(page, int(directional.epoch))
		retained_keys.append(page_key)
		clipmap.queue_page_revision(page_key, page.get("core_bounds", AABB()),
				spacing, geometry_epoch, content_revision)
	clipmap.retain_page_epochs(retained_keys)
	var jobs: Array[Vector4i] = clipmap.take_jobs(clampi(
		int(root_snapshot.get("clv_cells_per_frame", 256)), 32, 512))
	var grouped: Dictionary = {}
	for cell in jobs:
		var owner_index := PageStream.owner_index(pages_with_directional,
				clipmap.world_position(cell, spacing))
		if owner_index < 0:
			continue
		var owner_page: Dictionary = pages_with_directional[owner_index]
		var owner_key := str(owner_page.get("page_key", ""))
		var cells: Array = grouped.get(owner_key, [])
		cells.append(cell)
		grouped[owner_key] = cells
	var owner_keys: Array = grouped.keys()
	owner_keys.sort()
	for page_key_value in owner_keys:
		var page_key := String(page_key_value)
		var owner_page: Dictionary = pages_by_key.get(page_key, {})
		if owner_page.is_empty():
			continue
		var page_cache_key := str(owner_page.get("_cache_key", ""))
		var page_snapshot: Dictionary = owner_page.get("_snapshot", {})
		if page_snapshot.is_empty() or not _bake_resources.has(page_cache_key):
			continue
		var previous_snapshot := _frame_snapshot
		var previous_replacement := _frame_replacement_enabled
		_frame_snapshot = page_snapshot
		_frame_replacement_enabled = previous_replacement \
				and bool(page_snapshot.get("replacement_enabled", true))
		if not _update_frame_ubo(page_snapshot, _frame_scene_data, view, rd):
			clipmap.requeue_jobs(grouped[page_key])
			_frame_snapshot = previous_snapshot
			_frame_replacement_enabled = previous_replacement
			continue
		var cached: Dictionary = _bake_resources[page_cache_key]
		var directional: RefCounted = cached.get("directional")
		var geometry_epoch := _stream_page_geometry_epoch(root_snapshot, owner_page, spacing)
		var selected_cells: Array[Vector4i] = []
		for cell in grouped[page_key]:
			selected_cells.append(cell)
		if not clipmap.set_expected_page_epoch(rd, geometry_epoch) \
				or not clipmap.dispatch_page_jobs(rd, selected_cells, spacing, geometry_epoch,
					cached, directional, _ubo, _sampler):
			clipmap.requeue_jobs(selected_cells)
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
	return clipmap


func _render_stream_page(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice,
		page: Dictionary, snapshot: Dictionary, cache_key: String, rect: Rect2i,
		root_snapshot: Dictionary) -> void:
	var previous_snapshot := _frame_snapshot
	var previous_replacement := _frame_replacement_enabled
	var previous_clipmap: RefCounted = _frame_clipmap
	_frame_snapshot = snapshot
	_frame_replacement_enabled = previous_replacement \
			and bool(snapshot.get("replacement_enabled", true))
	if not _write_page_params(rd, page.get("core_bounds", AABB()), rect,
			root_snapshot, true) or not _update_frame_ubo(snapshot, _frame_scene_data, view, rd):
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
		_frame_clipmap = previous_clipmap
		return
	var cache_key_value := str(cache_key)
	var cached: Dictionary = _bake_resources.get(cache_key_value, {})
	if cached.is_empty():
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
		_frame_clipmap = previous_clipmap
		return
	var directional: RefCounted = cached.get("directional")
	if _frame_clipmap != null and directional != null \
			and bool(snapshot.get("use_clv", true)):
		var geometry_epoch := _stream_page_geometry_epoch(root_snapshot, page,
				float(root_snapshot.get("clv_cell_size", 0.5)))
		if not _frame_clipmap.set_expected_page_epoch(rd, geometry_epoch):
			_frame_clipmap = null
	else:
		_frame_clipmap = null
	if not shader_file is RDShaderFile or not _ensure_shader(rd):
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
		_frame_clipmap = previous_clipmap
		return
	var shader_before := _shader
	var compute_before := _compute_pipeline
	var sampler_before := _sampler
	var raster_count_before := _raster_pipelines.size()
	_stream_dispatch_rect = rect
	_stream_dispatch_extent = buffers.get_internal_size()
	_stream_dispatch_active = true
	super._render(buffers, view, rd)
	_stream_dispatch_active = false
	_stream_dispatch_rect = Rect2i()
	_stream_dispatch_extent = Vector2i()
	if shader_before != _shader or compute_before != _compute_pipeline \
			or sampler_before != _sampler or raster_count_before != _raster_pipelines.size():
		_sync_owned_rid_snapshot()
	_frame_snapshot = previous_snapshot
	_frame_replacement_enabled = previous_replacement
	_frame_clipmap = previous_clipmap

## Begin the shared per-frame page budget and release every LRU key the ledger
## retired. The ledger never owns RenderingDevice objects; this render-thread
## bridge keeps its byte accounting and physical residency in lockstep.
func _begin_page_residency_frame(frame_token: int, gpu_budget_bytes: int,
		upload_budget_bytes: int, reserved_bytes: int, allocation_budget: int,
		active_keys: PackedStringArray, rd: RenderingDevice) -> PackedStringArray:
	if _page_residency == null:
		_page_residency = PageResidency.new()
	var evicted: PackedStringArray = _page_residency.begin_frame(frame_token,
		gpu_budget_bytes, upload_budget_bytes, reserved_bytes, allocation_budget, active_keys)
	_release_page_residency_evictions(evicted, rd)
	return evicted

func _admit_stream_page(cache_key: String, page_key: String, gpu_bytes: int,
		rd: RenderingDevice) -> Dictionary:
	if _page_residency == null:
		_page_residency = PageResidency.new()
	var admission: Dictionary = _page_residency.admit(cache_key, page_key, gpu_bytes)
	_release_page_residency_evictions(admission.get("evicted", PackedStringArray()), rd)
	return admission

func _rollback_failed_stream_page(cache_key: String, page_version: int, rd: RenderingDevice) -> void:
	_release_stream_page_resources(cache_key, rd, true)
	# Do not retry a permanently-invalid/allocation-failing immutable revision every
	# frame. A new page version can clear this marker and start a fresh transaction.
	_remember_failed_stream_page_revision(cache_key, page_version)

func _remember_failed_stream_page_revision(cache_key: String, page_version: int) -> void:
	_page_failed_versions[cache_key] = page_version
	while _page_failed_versions.size() > MAX_FAILED_STREAM_PAGE_REVISIONS:
		var failed_keys: Array = _page_failed_versions.keys()
		if failed_keys.is_empty():
			break
		_page_failed_versions.erase(failed_keys[0])

func _stream_page_failed_for_revision(cache_key: String, page_version: int) -> bool:
	return int(_page_failed_versions.get(cache_key, -1)) == page_version

func _release_page_residency_evictions(evicted: PackedStringArray, rd: RenderingDevice) -> void:
	for cache_key in evicted:
		_release_stream_page_resources(str(cache_key), rd, false)

## Drop one staged or published streamed page. Call this for all upload/create
## failures so a failed page cannot retain either its reservation or partial RIDs.
func _release_stream_page_resources(cache_key: String, rd: RenderingDevice,
		rollback_ledger := true) -> void:
	var rids: Array[RID] = []
	if _page_uploads.has(cache_key):
		var uploader: RefCounted = _page_uploads[cache_key]
		if uploader != null and uploader.has_method("owned_rids"):
			rids.append_array(uploader.call("owned_rids"))
		_page_uploads.erase(cache_key)
	if _bake_resources.has(cache_key):
		var cached: Dictionary = _bake_resources[cache_key]
		_bake_resources.erase(cache_key)
		var directional: RefCounted = cached.get("directional")
		if directional != null:
			rids.append_array(directional.owned_rids())
		for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
				"visibility_nodes", "visibility_triangles", "indices", "index_entries",
				"emission", "probe_lighting", "probe_clusters"]:
			var rid: RID = cached.get(name, RID())
			if rid.is_valid():
				rids.append(rid)
	for page_key in _page_ready_by_key.keys():
		if str(_page_ready_by_key[page_key]) == cache_key:
			_page_ready_by_key.erase(page_key)
	_page_failed_versions.erase(cache_key)
	if rollback_ledger and _page_residency != null:
		_page_residency.remove(cache_key)
	# Normally staging and published ownership are exclusive. Deduplicate defensively
	# so a failure during the publication handoff cannot issue free_rid twice.
	var unique_rids: Array[RID] = []
	var seen: Dictionary = {}
	for rid in rids:
		if rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			unique_rids.append(rid)
	_free_rids(rd, unique_rids)
	_sync_owned_rid_snapshot()

func _ensure_bake_resources(cache_key: String, data: Resource, version: int, rd: RenderingDevice) -> bool:
	if _bake_resources.has(cache_key):
		var cached: Dictionary = _bake_resources[cache_key]
		if cached.get("data_id", -1) == data.get_instance_id() \
				and cached.get("version", -1) == version \
				and cached.get("transfer", RID()).is_valid() \
				and cached.get("primary_sky", RID()).is_valid() \
				and cached.get("geometry", RID()).is_valid() \
				and cached.get("visibility_moments", RID()).is_valid() \
				and cached.get("visibility_nodes", RID()).is_valid() \
				and cached.get("visibility_triangles", RID()).is_valid() \
				and cached.get("indices", RID()).is_valid() \
				and cached.get("index_entries", RID()).is_valid() \
				and cached.get("probe_clusters", RID()).is_valid() \
				and cached.get("probe_lighting", RID()).is_valid() \
				and cached.get("emission", RID()).is_valid() \
				and (not bool(cached.get("probe_neighbor_mask_enabled", false)) \
					or cached.get("probe_neighbor_masks", RID()).is_valid()) \
				and (not bool(cached.get("probe_neighbor_cell_list_enabled", false)) \
					or cached.get("probe_neighbor_cell_lists", RID()).is_valid()) \
				and (not probe_neighbor_cell_list_optimization_enabled \
					or bool(cached.get("probe_neighbor_cell_list_enabled", false)) \
					or str(cached.get("probe_neighbor_cell_list_reason", "disabled")) != "disabled") \
				and _baked_indirect_sh_upload_matches(data, cached):
			if not cached.has("magicdawn_baked_sh_codec") \
					and data.has_method("has_baked_indirect_sh") \
					and bool(data.call("has_baked_indirect_sh")):
				var source_value: Variant = data.get("baked_indirect_sh")
				if source_value is PackedFloat32Array:
					cached["magicdawn_baked_sh_codec"] = \
							MagicDawnBakedSHCache.choose_codec(source_value)
					_bake_resources[cache_key] = cached
			return true
		_release_bake_resources(cache_key, rd)
	# Data owns validation and all atlas layouts. It validates once, then prepares
	# the complete immutable upload bundle; the FRP boundary only checks its shape.
	if not data.has_method("make_render_upload"):
		_report("The selected Magic GI bake does not provide runtime upload data; rebake or update the Magic GI addon.")
		return false
	var upload: Variant = data.call("make_render_upload")
	if not upload is Dictionary:
		_report("The selected Magic GI bake is invalid or stale; rebake it with the current PRT format.")
		return false
	var source_bounds_value: Variant = upload.get("surface_bounds")
	if not source_bounds_value is AABB or not _valid_clv_focus_bounds(source_bounds_value):
		_report("The selected Magic GI bake has no finite surface-sample bounds; rebake it with the current PRT format.")
		return false
	var transfer_value: Variant = upload.get("transfer_image")
	var primary_sky_value: Variant = upload.get("primary_sky_image")
	var geometry_value: Variant = upload.get("geometry_image")
	var visibility_value: Variant = upload.get("visibility_moment_image")
	var node_value: Variant = upload.get("visibility_node_bytes")
	var triangle_value: Variant = upload.get("visibility_triangle_bytes")
	var index_value: Variant = upload.get("index_bytes")
	var emission_value: Variant = upload.get("emission_image")
	if not transfer_value is Image or not primary_sky_value is Image or not geometry_value is Image \
			or not visibility_value is Image \
			or not node_value is PackedByteArray or not triangle_value is PackedByteArray \
			or not index_value is PackedByteArray \
			or not emission_value is Image:
		_report("The selected Magic GI bake could not create its complete PRT upload bundle.")
		return false
	var transfer_image: Image = transfer_value
	var primary_sky_image: Image = primary_sky_value
	var geometry_image: Image = geometry_value
	var visibility_image: Image = visibility_value
	var node_bytes: PackedByteArray = node_value
	var triangle_bytes: PackedByteArray = triangle_value
	var index_bytes: PackedByteArray = index_value
	var emission_image: Image = emission_value
	if transfer_image.is_empty() or primary_sky_image.is_empty() or geometry_image.is_empty() \
			or visibility_image.is_empty() or index_bytes.is_empty() \
			or node_bytes.is_empty() or node_bytes.size() % 32 != 0 \
			or triangle_bytes.is_empty() or triangle_bytes.size() % 48 != 0 \
			or emission_image.is_empty():
		_report("The selected Magic GI bake returned an empty runtime upload payload.")
		return false
	var transfer_rid := _create_image_texture(rd, transfer_image, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	var primary_sky_rid := _create_image_texture(rd, primary_sky_image, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	var geometry_rid := _create_image_texture(rd, geometry_image, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	var visibility_rid := _create_image_texture(rd, visibility_image, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT)
	var node_rid := rd.storage_buffer_create(node_bytes.size(), node_bytes)
	var triangle_rid := rd.storage_buffer_create(triangle_bytes.size(), triangle_bytes)
	var dims: Vector3i = data.get("grid_dims")
	var index_rid := _create_index_texture(rd, dims, index_bytes, bool(upload.get("sparse_indices", false)))
	var index_entries: PackedByteArray = upload.get("index_entries", PackedInt32Array([0]).to_byte_array())
	var entries_rid := rd.storage_buffer_create(index_entries.size(), index_entries)
	var probe_count := int(data.call("probe_count"))
	var neighbor_mask_payload := build_probe_neighbor_mask_payload(data, dims)
	var neighbor_mask_enabled := bool(neighbor_mask_payload.get("enabled", false)) \
			and bool(neighbor_mask_payload.get("validated_exactly", false))
	var neighbor_mask_bytes := PackedByteArray()
	var neighbor_mask_rid := RID()
	if neighbor_mask_enabled:
		var words: PackedInt32Array = neighbor_mask_payload["words"]
		neighbor_mask_bytes = words.to_byte_array()
		neighbor_mask_rid = rd.storage_buffer_create(neighbor_mask_bytes.size(), neighbor_mask_bytes)
		neighbor_mask_enabled = neighbor_mask_rid.is_valid()
	var neighbor_cell_list_payload: Dictionary
	if probe_neighbor_cell_list_optimization_enabled \
			and bool(neighbor_mask_payload.get("validated_exactly", false)):
		neighbor_cell_list_payload = build_probe_neighbor_cell_list_payload(data, dims)
	elif probe_neighbor_cell_list_optimization_enabled:
		neighbor_cell_list_payload = {"enabled": false, "reason": "source_order_validation_unavailable",
			"words": PackedInt32Array([0]), "candidate_cell_records": 0, "bytes": 0}
	else:
		neighbor_cell_list_payload = build_probe_neighbor_cell_list_payload(data, dims)
	var neighbor_cell_list_enabled := bool(neighbor_cell_list_payload.get("enabled", false)) \
			and bool(neighbor_cell_list_payload.get("validated_exactly", false))
	var neighbor_cell_list_bytes := PackedByteArray()
	var neighbor_cell_list_rid := RID()
	if neighbor_cell_list_enabled:
		var list_words: PackedInt32Array = neighbor_cell_list_payload["words"]
		neighbor_cell_list_bytes = list_words.to_byte_array()
		neighbor_cell_list_rid = rd.storage_buffer_create(neighbor_cell_list_bytes.size(),
				neighbor_cell_list_bytes)
		neighbor_cell_list_enabled = neighbor_cell_list_rid.is_valid()
	if not neighbor_cell_list_enabled and probe_neighbor_cell_list_optimization_enabled \
			and str(neighbor_cell_list_payload.get("reason", "")).is_empty():
		neighbor_cell_list_payload["reason"] = "rendering_device_buffer_create_failed"
	var estimated_gpu_bytes := int(data.call("estimate_gpu_bytes")) \
			if data.has_method("estimate_gpu_bytes") else 0
	var geometry_revision := int(_frame_snapshot.get("geometry_revision", version))
	var cluster_signature := ProbeClusters.cache_key(data.get_instance_id(), version, geometry_revision)
	var cluster_payload := ProbeClusters.build(upload, dims, probe_count, cluster_signature,
		int(data.get("format_version")) >= 6)
	var cluster_bytes: PackedByteArray = cluster_payload["bytes"]
	var cluster_rid := rd.storage_buffer_create(cluster_bytes.size(), cluster_bytes)
	if not cluster_rid.is_valid() and bool(cluster_payload.get("enabled", false)):
		cluster_payload = ProbeClusters.disabled_payload(cluster_signature,
				dims.x * dims.y * dims.z)
		cluster_bytes = cluster_payload["bytes"]
		cluster_rid = rd.storage_buffer_create(cluster_bytes.size(), cluster_bytes)
	var emission_rid := _create_image_texture(rd, emission_image, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
	var lighting_rid := rd.storage_buffer_create(probe_count * 32)
	var source_bounds: AABB = source_bounds_value
	var baked_sh_codec: Dictionary = {}
	var baked_sh_revision := int(data.get("baked_indirect_sh_revision"))
	var baked_sh_source_value: Variant = data.get("baked_indirect_sh")
	var baked_sh_persisted_scalar_count := 0
	if baked_sh_source_value is PackedFloat32Array:
		var baked_sh_source: PackedFloat32Array = baked_sh_source_value
		baked_sh_persisted_scalar_count = baked_sh_source.size()
	if data.has_method("has_baked_indirect_sh") \
			and bool(data.call("has_baked_indirect_sh")):
		var baked_sh_value: Variant = data.get("baked_indirect_sh")
		if baked_sh_value is PackedFloat32Array:
			baked_sh_codec = MagicDawnBakedSHCache.choose_codec(baked_sh_value)
	var directional: RefCounted
	if data.get("directional") != null:
		directional = DirectionalCache.new()
		if not directional.create(rd, data):
			_free_rids(rd, directional.owned_rids())
			_free_rids(rd, [transfer_rid, primary_sky_rid, geometry_rid, visibility_rid,
				node_rid, triangle_rid, index_rid, entries_rid, cluster_rid, emission_rid,
				lighting_rid, neighbor_mask_rid, neighbor_cell_list_rid])
			return false
	if not transfer_rid.is_valid() or not primary_sky_rid.is_valid() or not geometry_rid.is_valid() \
			or not visibility_rid.is_valid() \
			or not node_rid.is_valid() or not triangle_rid.is_valid() \
			or not index_rid.is_valid() or not entries_rid.is_valid() or not cluster_rid.is_valid() \
			or not emission_rid.is_valid() or not lighting_rid.is_valid():
		if directional != null:
			_free_rids(rd, directional.owned_rids())
		for rid in [transfer_rid, primary_sky_rid, geometry_rid, visibility_rid,
				node_rid, triangle_rid, index_rid, entries_rid, cluster_rid, emission_rid,
				lighting_rid, neighbor_mask_rid, neighbor_cell_list_rid]:
			if rid.is_valid():
				rd.free_rid(rid)
		_report("RenderingDevice could not upload the Magic GI PRT atlas, emission atlas, or index grid.")
		return false
	_bake_resources[cache_key] = {
		"data_id": data.get_instance_id(),
		"version": version,
		"transfer": transfer_rid,
		"primary_sky": primary_sky_rid,
		"geometry": geometry_rid,
		"visibility_moments": visibility_rid,
		"visibility_nodes": node_rid,
		"visibility_triangles": triangle_rid,
		"indices": index_rid,
		"index_entries": entries_rid,
		"probe_clusters": cluster_rid,
		"probe_cluster_enabled": bool(cluster_payload.get("enabled", false)),
		"probe_cluster_bytes": cluster_bytes.size(),
		"probe_cluster_signature": cluster_signature,
		"probe_cluster_cell_count": int(cluster_payload.get("cell_count", 0)),
		"probe_cluster_count": int(cluster_payload.get("cluster_count", 0)),
		"probe_cluster_probe_slots": int(cluster_payload.get("probe_slots", 0)),
		"probe_neighbor_masks": neighbor_mask_rid,
		"probe_neighbor_mask_enabled": neighbor_mask_enabled,
		"probe_neighbor_mask_bytes": neighbor_mask_bytes.size() if neighbor_mask_enabled else 0,
		"probe_neighbor_mask_candidate_cell_records": int(neighbor_mask_payload.get("candidate_cell_records", 0)) \
				if neighbor_mask_enabled else 0,
		"probe_neighbor_mask_validation": neighbor_mask_payload.get("validation", {}),
		"probe_neighbor_cell_lists": neighbor_cell_list_rid,
		"probe_neighbor_cell_list_enabled": neighbor_cell_list_enabled,
		"probe_neighbor_cell_list_bytes": neighbor_cell_list_bytes.size() \
				if neighbor_cell_list_enabled else 0,
		"probe_neighbor_cell_list_candidate_records": int(neighbor_cell_list_payload.get(
				"candidate_cell_records", 0)) if neighbor_cell_list_enabled else 0,
		"probe_neighbor_cell_list_validation": neighbor_cell_list_payload.get("validation", {}),
		"probe_neighbor_cell_list_reason": str(neighbor_cell_list_payload.get("reason", "")),
		"gpu_bytes": maxi(0, estimated_gpu_bytes) + cluster_bytes.size() \
				+ (neighbor_mask_bytes.size() if neighbor_mask_enabled else 0) \
				+ (neighbor_cell_list_bytes.size() if neighbor_cell_list_enabled else 0),
		"emission": emission_rid,
		"probe_lighting": lighting_rid,
		"directional": directional,
		"source_bounds": source_bounds,
		"magicdawn_baked_sh_codec": baked_sh_codec,
		"emission_identity": "",
		"emission_revision": -1,
		"grid_dims": dims,
		"spacing": float(data.get("spacing")),
		"probe_count": int(data.call("probe_count")),
		"baked_indirect_sh_revision": baked_sh_revision,
		"baked_indirect_sh_signature": int(data.get("baked_indirect_lighting_signature")),
		"baked_indirect_sh_includes_primary_sky": baked_sh_revision == MAGICDAWN_BAKED_SH_REVISION,
		"baked_indirect_sh_persisted_scalar_count": baked_sh_persisted_scalar_count,
		"exact_visibility": int(data.get("format_version")) >= 6,
		"last_used": _cache_clock,
	}
	_prune_bake_cache(rd)
	_sync_owned_rid_snapshot()
	return true

func _baked_indirect_sh_upload_matches(data: Resource, cached: Dictionary) -> bool:
	if not data.has_method("has_baked_indirect_sh") \
			or not bool(data.call("has_baked_indirect_sh")):
		return true
	var values_value: Variant = data.get("baked_indirect_sh")
	if not values_value is PackedFloat32Array:
		return false
	var values: PackedFloat32Array = values_value
	var probe_count := int(data.call("probe_count"))
	var directional_value: Variant = cached.get("directional")
	if not directional_value is RefCounted:
		return false
	var directional: RefCounted = directional_value
	var source_value: Variant = directional.get("baked_indirect_lighting")
	var source_rid: RID = source_value if source_value is RID else RID()
	return source_rid.is_valid() \
			and probe_count > 0 and values.size() == probe_count * 27 \
			and int(directional.get("probes")) == probe_count \
			and int(directional.get("baked_indirect_lighting_bytes")) == probe_count * 28 * 4 \
			and int(cached.get("baked_indirect_sh_revision", -1)) \
				== int(data.get("baked_indirect_sh_revision")) \
			and int(cached.get("baked_indirect_sh_signature", -1)) \
				== int(data.get("baked_indirect_lighting_signature")) \
			and int(cached.get("baked_indirect_sh_persisted_scalar_count", -1)) == values.size()

## Relight each probe only when its sources change. Geometry filtering remains in
## the surface gather; this cache is independent of camera, exposure and material.
func _probe_lighting_sources(cached: Dictionary, snapshot: Dictionary) -> Array:
	return [snapshot.get("lighting", PackedFloat32Array()),
		snapshot.get("sky_lighting", PackedFloat32Array()),
		cached["emission_identity"], cached["emission_revision"]]


func _update_probe_lighting(cache_key: String, snapshot: Dictionary, rd: RenderingDevice) -> bool:
	var cached: Dictionary = _bake_resources[cache_key]
	var sources := _probe_lighting_sources(cached, snapshot)
	if cached.get("lighting_sources", []) == sources:
		if _clv_internal_test_layout == CLV_INTERNAL_LAYOUT14_V0_TEST:
			var current_directional: RefCounted = cached.get("directional")
			if current_directional == null \
					or not current_directional.has_method("ensure_raw_sidecar") \
					or not current_directional.has_method("raw_sidecar_matches"):
				return false
			if not bool(current_directional.ensure_raw_sidecar(rd)):
				# Calibrated lighting is already current; keep the ordinary root live.
				# B activation below separately rejects the missing raw sidecar.
				return true
			if not bool(current_directional.raw_sidecar_matches(snapshot)):
				if bool(current_directional.update(rd, _ubo, snapshot,
						cached["probe_lighting"], true)):
					return true
				# Raw-sidecar refresh failed before dispatch; relight the calibrated buffer
				# and let the binding gate select the ordinary source path this frame.
				return bool(current_directional.update(rd, _ubo, snapshot,
					cached["probe_lighting"], false))
		return true
	if not _ensure_sampler(rd):
		return false
	if not _relight_shader.is_valid():
		_relight_shader = rd.shader_create_from_spirv(RELIGHT_SHADER.get_spirv(), "Magic GI Relight")
		_sync_owned_rid_snapshot()
		if not _relight_shader.is_valid():
			return false
	if not _relight_pipeline.is_valid():
		_relight_pipeline = rd.compute_pipeline_create(_relight_shader)
		_sync_owned_rid_snapshot()
		if not _relight_pipeline.is_valid():
			return false
	var uniform_set := UniformSetCacheRD.get_cache(_relight_shader, 0, [
		U.sampled(0, _sampler, cached["transfer"]),
		U.sampled(1, _sampler, cached["primary_sky"]),
		U.sampled(2, _sampler, cached["emission"]),
		U.uniform_buffer(3, _ubo), U.storage_buffer(4, cached["probe_lighting"]),
	])
	if not uniform_set.is_valid():
		return false
	rd.draw_command_begin_label("Magic GI Relight", Color(0.4, 0.8, 0.3))
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _relight_pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, (int(cached["probe_count"]) + 63) / 64, 1, 1)
	rd.compute_list_end()
	rd.draw_command_end_label()
	var directional: RefCounted = cached.get("directional")
	if directional != null:
		var write_raw_sidecar := _clv_internal_test_layout == CLV_INTERNAL_LAYOUT14_V0_TEST
		if not bool(directional.update(rd, _ubo, snapshot, cached["probe_lighting"],
				write_raw_sidecar)):
			if write_raw_sidecar and bool(directional.update(rd, _ubo, snapshot,
					cached["probe_lighting"], false)):
				# Preserve ordinary calibrated output while B's raw sidecar is unavailable.
				cached["lighting_sources"] = sources.duplicate(true)
				return true
			return false
	cached["lighting_sources"] = sources.duplicate(true)
	return true

func _make_emission_image(data: Resource, snapshot: Dictionary) -> Image:
	var payload: Variant = snapshot.get("emission_payload", PackedFloat32Array())
	if not payload is PackedFloat32Array:
		_report("Magic GI emissive response is not a packed float array; using a black emission atlas.")
		payload = PackedFloat32Array()
	var payload_array: PackedFloat32Array = payload
	var image: Variant = data.call("make_emission_atlas_image", payload_array)
	if image is Image:
		return image
	if not payload_array.is_empty():
		_report("Magic GI emissive response does not match the bake; using a black emission atlas.")
	image = data.call("make_emission_atlas_image", PackedFloat32Array())
	return image if image is Image else null

func _update_emission_texture(cache_key: String, snapshot: Dictionary, data: Resource, rd: RenderingDevice) -> bool:
	if not _bake_resources.has(cache_key):
		return false
	var cached: Dictionary = _bake_resources[cache_key]
	var identity := str(snapshot.get("emission_identity", cache_key))
	var revision := int(snapshot.get("emission_revision", 0))
	if cached.get("emission_identity", "") == identity \
			and cached.get("emission_revision", -1) == revision:
		return true
	var image := _make_emission_image(data, snapshot)
	if image == null:
		_report("Magic GI could not create the emissive atlas.")
		return false
	var emission_rid: RID = cached.get("emission", RID())
	if not emission_rid.is_valid() or rd.texture_update(emission_rid, 0, image.get_data()) != OK:
		_report("RenderingDevice could not update the Magic GI emission atlas.")
		return false
	cached["emission_identity"] = identity
	cached["emission_revision"] = revision
	_bake_resources[cache_key] = cached
	return true

func _create_image_texture(rd: RenderingDevice, image: Image, data_format: int, extra_usage_bits := 0) -> RID:
	return _create_texture(rd, image.get_size(), data_format, image.get_data(), extra_usage_bits)

func _create_index_texture(rd: RenderingDevice, dims: Vector3i, bytes: PackedByteArray, sparse := false) -> RID:
	return _create_texture(rd, Vector2i(dims.x * (1 if sparse else 8), dims.y * dims.z),
		RenderingDevice.DATA_FORMAT_R32G32_SINT if sparse else RenderingDevice.DATA_FORMAT_R32_SINT, bytes)

func _create_texture(rd: RenderingDevice, size: Vector2i, data_format: int, bytes: PackedByteArray,
		extra_usage_bits := 0) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = data_format
	format.width = size.x
	format.height = size.y
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | extra_usage_bits
	return rd.texture_create(format, RDTextureView.new(), [bytes])

func _prune_bake_cache(rd: RenderingDevice) -> void:
	var legacy_count := 0
	for cached: Dictionary in _bake_resources.values():
		if not bool(cached.get("stream_page", false)):
			legacy_count += 1
	while legacy_count > MAX_CACHED_BAKES:
		var oldest_key: String = ""
		var oldest := 0x7fffffff
		for key in _bake_resources:
			if bool(_bake_resources[key].get("stream_page", false)):
				continue
			var last_used := int(_bake_resources[key].get("last_used", 0))
			if last_used < oldest:
				oldest = last_used
				oldest_key = str(key)
		if oldest_key == "":
			return
		_release_bake_resources(oldest_key, rd)
		legacy_count -= 1

func _release_bake_resources(cache_key: String, rd: RenderingDevice) -> void:
	_free_rids(rd, _take_bake_rids(cache_key))
	_sync_owned_rid_snapshot()

func _take_bake_rids(cache_key: String) -> Array[RID]:
	var rids: Array[RID] = []
	if not _bake_resources.has(cache_key):
		return rids
	var cached: Dictionary = _bake_resources[cache_key]
	_bake_resources.erase(cache_key)
	var directional: RefCounted = cached.get("directional")
	if directional != null:
		rids.append_array(directional.owned_rids())
	for key in _clipmaps.keys():
		if _clipmaps[key].bake == cache_key:
			rids.append_array(_clipmaps[key].cache.owned_rids())
			_clipmaps.erase(key)
	for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
			"visibility_nodes", "visibility_triangles", "indices", "index_entries",
			"probe_clusters", "emission", "probe_lighting", "probe_neighbor_masks",
			"probe_neighbor_cell_lists"]:
		var rid: RID = cached.get(name, RID())
		if rid.is_valid():
			rids.append(rid)
	return rids

func _update_frame_ubo(snapshot: Dictionary, scene_data: RenderSceneData, view: int, rd: RenderingDevice) -> bool:
	if snapshot.get("free_space_volume_source") is Resource or snapshot.get("prepared_source_header") is Resource:
		return _update_dynamic_volume_frame_ubo(snapshot, rd)
	if scene_data == null or view >= scene_data.get_view_count():
		return false
	var cached: Dictionary = _bake_resources[str(snapshot.get("cache_key", ""))]
	var view_matrices: Array = _frame_view_matrices.get(view, [])
	if view_matrices.is_empty():
		var projection_values := PackedFloat32Array()
		_append_projection(projection_values, scene_data.get_view_projection(view).inverse())
		var camera: Transform3D = scene_data.get_cam_transform()
		var camera_values := PackedFloat32Array()
		_append_transform(camera_values, Transform3D(camera.basis.orthonormalized(), camera.origin))
		view_matrices = [projection_values, camera_values]
		_frame_view_matrices[view] = view_matrices
	var dimensions: Vector3i = cached["grid_dims"]
	var lighting: Variant = snapshot.get("lighting", PackedFloat32Array())
	if not lighting is PackedFloat32Array or lighting.size() != 27:
		return false
	var sky_lighting: Variant = snapshot.get("sky_lighting", PackedFloat32Array())
	if not sky_lighting is PackedFloat32Array or sky_lighting.size() != 27:
		sky_lighting = PackedFloat32Array()
		sky_lighting.resize(27)
	var values := PackedFloat32Array()
	values.append_array(view_matrices[0])
	var bake_data: Resource = snapshot["data"]
	var world_to_grid: Transform3D = bake_data.get("world_to_grid")
	_append_transform(values, world_to_grid)
	values.append_array(view_matrices[1])
	values.append_array(PackedFloat32Array([float(dimensions.x), float(dimensions.y), float(dimensions.z), float(cached["probe_count"])]))
	values.append_array(PackedFloat32Array([
		float(snapshot.get("strength", 1.0)),
		float(cached["spacing"]),
		1.0 if _frame_replacement_enabled else 0.0,
		1.0 if cached["exact_visibility"] else 0.0,
	]))
	for coefficient_index in range(2):
		var coefficients: PackedFloat32Array = lighting if coefficient_index == 0 else sky_lighting
		values.append_array(coefficients)
		values.append(1.0 if coefficient_index == 0 \
				and _probe_neighbor_mask_is_usable(cached) else (1.0 if coefficient_index == 1 \
				and _probe_neighbor_cell_list_is_usable(cached) else 0.0))
		# SH9 RGB occupies seven vec4s; the last lane is otherwise padding.
	# No bake or no runtime producer is a true no-op: only allocate GPU state
	# after the matching, validated snapshot has made it all the way to the shader.
	return _commit_frame_ubo(values, UBO_SIZE, rd)

func _update_dynamic_volume_frame_ubo(snapshot: Dictionary, rd: RenderingDevice) -> bool:
	var paged := snapshot.get("prepared_source_header") is Resource
	var source_value: Variant = snapshot.get("prepared_source_header") if paged \
		else snapshot.get("free_space_volume_source")
	if not source_value is Resource:
		return false
	var source: Resource = source_value
	var dimensions_value: Variant = source.get("dimensions")
	var probe_count := maxi(1, int(_dynamic_volume_cache.clip_cell_count)) if paged \
		and _dynamic_volume_cache != null else int(source.get("probe_count"))
	if not dimensions_value is Vector3i or probe_count <= 0:
		return false
	var lighting_value: Variant = snapshot.get("lighting", PackedFloat32Array())
	if not lighting_value is PackedFloat32Array or lighting_value.size() != 27:
		return false
	var sky_value: Variant = snapshot.get("sky_lighting", PackedFloat32Array())
	if not sky_value is PackedFloat32Array or sky_value.size() != 27:
		sky_value = PackedFloat32Array()
		sky_value.resize(27)
	var dimensions: Vector3i = dimensions_value
	# The relight compute only reads the two SH9 blocks. Keep the common GI UBO
	# ABI (448 bytes) while filling its unused matrix prefix with zeros.
	var values := PackedFloat32Array()
	values.resize(56)
	values.fill(0.0)
	values[48] = float(dimensions.x)
	values[49] = float(dimensions.y)
	values[50] = float(dimensions.z)
	values[51] = float(probe_count)
	values[52] = float(snapshot.get("strength", 1.0))
	values[53] = float(source.get("spacing_m"))
	values[54] = 1.0 if bool(snapshot.get("replacement_requested", false)) else 0.0
	values[55] = 0.0
	values.append_array(lighting_value)
	values.append(0.0)
	values.append_array(sky_value)
	values.append(0.0)
	if values.size() * 4 != UBO_SIZE:
		return false
	return _commit_frame_ubo(values, UBO_SIZE, rd)

func _commit_frame_ubo(values: PackedFloat32Array, ubo_size: int, rd: RenderingDevice) -> bool:
	var had_ubo := _ubo.is_valid()
	var bytes := values.to_byte_array()
	if had_ubo and ubo_size == UBO_SIZE and bytes == _last_frame_ubo_bytes:
		return true
	var succeeded := super._commit_frame_ubo(values, ubo_size, rd)
	if succeeded and not had_ubo:
		_sync_owned_rid_snapshot()
	if succeeded and ubo_size == UBO_SIZE:
		_last_frame_ubo_bytes = bytes
	return succeeded

func _collect_bindings(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> Dictionary:
	var binding_data := _collect_frame_input_bindings(buffers, view, rd)
	if _binding_error or _frame_snapshot.is_empty():
		return binding_data
	if _magicdawn_frame_active:
		return _collect_magicdawn_bindings(binding_data, rd)
	var cache_key := str(_frame_snapshot.get("cache_key", ""))
	if not _bake_resources.has(cache_key):
		_binding_error = true
		return binding_data
	var cached: Dictionary = _bake_resources[cache_key]
	var cluster_buffer := _cluster_binding_for_cache(cached, rd)
	if not cluster_buffer.is_valid():
		_binding_error = true
		return binding_data
	var uniforms: Array[RDUniform] = binding_data["uniforms"].duplicate()
	var neighbor_mask_buffer: RID = cached.get("probe_neighbor_masks", RID()) \
			if _probe_neighbor_mask_is_usable(cached) else RID()
	if not neighbor_mask_buffer.is_valid():
		if not _ensure_probe_neighbor_mask_disabled(rd):
			_binding_error = true
			return binding_data
		neighbor_mask_buffer = _probe_neighbor_mask_disabled
	var neighbor_cell_list_buffer: RID = cached.get("probe_neighbor_cell_lists", RID())
	if not neighbor_cell_list_buffer.is_valid():
		if not _ensure_probe_neighbor_mask_disabled(rd):
			_binding_error = true
			return binding_data
		neighbor_cell_list_buffer = _probe_neighbor_mask_disabled
	if cached.get("apply_sampler", RID()) != _sampler \
			or cached.get("apply_cluster", RID()) != cluster_buffer \
			or cached.get("apply_neighbor_mask", RID()) != neighbor_mask_buffer \
			or cached.get("apply_neighbor_cell_list", RID()) != neighbor_cell_list_buffer:
		cached["apply_uniforms"] = [U.sampled(7, _sampler, cached["geometry"]),
			U.sampled(8, _sampler, cached["indices"]), U.sampled(13, _sampler, cached["visibility_moments"]),
			U.storage_buffer(14, cached["visibility_nodes"]), U.storage_buffer(15, cached["visibility_triangles"]),
			U.storage_buffer(17, cached["probe_lighting"]), U.storage_buffer(22, cached["index_entries"]),
			U.storage_buffer(PROBE_CLUSTER_BINDING, cluster_buffer),
			U.storage_buffer(PROBE_NEIGHBOR_MASK_BINDING, neighbor_mask_buffer),
			U.storage_buffer(PROBE_NEIGHBOR_CELL_LIST_BINDING, neighbor_cell_list_buffer)]
		cached["apply_sampler"] = _sampler
		cached["apply_cluster"] = cluster_buffer
		cached["apply_neighbor_mask"] = neighbor_mask_buffer
		cached["apply_neighbor_cell_list"] = neighbor_cell_list_buffer
	uniforms.append_array(cached["apply_uniforms"])
	uniforms.append(_ubo_uniform(UBO_BINDING))
	if not _ensure_clv_fallback(rd):
		_binding_error = true
		return binding_data
	var directional: RefCounted = cached.get("directional")
	if _frame_clipmap == null:
		var mode_value := _clv_layout_version_for_backend(_last_clv_cache_backend) \
				if _last_clv_cache_backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
				else (1 if directional != null else 0)
		if mode_value != _clv_fallback_mode:
			var fallback_parameters := PackedByteArray()
			if mode_value == CLV_BLOCK_CHART_LAYOUT_VERSION \
					or mode_value == CLV_INTERNAL_LAYOUT14_V0_TEST:
				for _origin_index in 3:
					fallback_parameters.append_array(PackedInt32Array([0, 0, 0, 0]).to_byte_array())
				fallback_parameters.append_array(PackedFloat32Array([
					maxf(float(_frame_snapshot.get("clv_cell_size", 0.25)), 0.001), 0.0, 0.0, 0.0]).to_byte_array())
				fallback_parameters.append_array(PackedInt32Array([1, 3, 0,
					mode_value]).to_byte_array())
			else:
				fallback_parameters.resize(80)
				fallback_parameters.encode_s32(76, mode_value)
			if rd.buffer_update(_clv_fallback.parameters, 0, fallback_parameters.size(), fallback_parameters) != OK:
				_binding_error = true
				return binding_data
			_clv_fallback_mode = mode_value
	uniforms.append(U.storage_buffer(18, directional.lighting if directional != null else _clv_fallback.lighting))
	uniforms.append(U.sampled(19, _frame_clipmap.sampler if _frame_clipmap != null else _sampler,
		_frame_clipmap.texture if _frame_clipmap != null else _clv_fallback.texture))
	uniforms.append(U.sampled(20, _sampler, _frame_clipmap.tags if _frame_clipmap != null else _clv_fallback.tags))
	uniforms.append(U.uniform_buffer(21, _frame_clipmap.parameters if _frame_clipmap != null else _clv_fallback.parameters))
	uniforms.append(U.sampled(25, _sampler,
		_frame_clipmap.support if _frame_clipmap != null else _clv_fallback.support))
	if _layout14_b_frame_active:
		if not _layout14_b_frame_moments.is_valid() \
				or not _layout14_b_frame_sampler.is_valid() \
				or not _layout14_b_frame_tags.is_valid():
			_binding_error = true
			return binding_data
		uniforms.append(U.sampled(33, _layout14_b_frame_sampler,
				_layout14_b_frame_moments))
		uniforms.append(U.storage_buffer(34, _layout14_b_frame_tags))
		var raw_directional: RefCounted = cached.get("directional")
		var raw_rid_value: Variant = raw_directional.get("raw_lighting") \
				if raw_directional != null else null
		if not raw_rid_value is RID:
			_binding_error = true
			return binding_data
		var raw_rid: RID = raw_rid_value
		uniforms.append(U.storage_buffer(35, raw_rid))
	if not _ensure_exact_point_debug_buffer(rd):
		_binding_error = true
		return binding_data
	var debug_target := prt_surface_exact_debug_pixel if (prt_surface_exact_debug_mode == 105 \
			or prt_surface_exact_debug_mode >= 107 and prt_surface_exact_debug_mode <= 110) \
			and prt_surface_exact_debug_pixel.x >= 0 and prt_surface_exact_debug_pixel.y >= 0 \
			else Vector2i(-1, -1)
	var target_bytes := PackedInt32Array([debug_target.x, debug_target.y]).to_byte_array()
	if rd.buffer_update(_exact_point_debug_buffer, 32, 8, target_bytes) != OK:
		_binding_error = true
		return binding_data
	uniforms.append(U.storage_buffer(26, _exact_point_debug_buffer))
	if not _ensure_clv_stats_buffer(rd):
		_binding_error = true
		return binding_data
	uniforms.append(U.storage_buffer(CLV_STATS_BINDING, _clv_stats_buffer))
	if not _page_params_ubo.is_valid():
		_binding_error = true
		return binding_data
	uniforms.append(U.uniform_buffer(PAGE_PARAMS_BINDING, _page_params_ubo))
	binding_data["uniforms"] = uniforms
	_record_probe_cluster_binding(cache_key)
	return binding_data

func _collect_magicdawn_bindings(binding_data: Dictionary, rd: RenderingDevice) -> Dictionary:
	if _frame_clipmap == null or not _frame_clipmap.has_method("get_field_textures") \
			or not _ensure_magicdawn_stats_buffer(rd) or not _ubo.is_valid() \
			or not _page_params_ubo.is_valid():
		_binding_error = true
		return binding_data
	var fields_value: Variant = _frame_clipmap.call("get_field_textures")
	if not fields_value is Array or fields_value.size() != CLV_MAGICDAWN_BAKED_SH_TEXTURE_COUNT:
		_binding_error = true
		return binding_data
	var fields: Array = fields_value
	var field_sampler: RID = _frame_clipmap.get("sampler")
	var clipmap_parameters: RID = _frame_clipmap.get("parameters")
	if not field_sampler.is_valid() or not clipmap_parameters.is_valid():
		_binding_error = true
		return binding_data
	var uniforms: Array[RDUniform] = []
	var found_required := {}
	var input_uniforms: Array = binding_data.get("uniforms", [])
	for uniform_value in input_uniforms:
		if not uniform_value is RDUniform:
			continue
		var uniform: RDUniform = uniform_value
		if uniform.binding in [0, 1, 2, 3, 4, 5, 12, DIFFUSE_AO_BINDING]:
			uniforms.append(uniform)
			found_required[uniform.binding] = true
	for required_binding in [0, 1, 2, 3, 4, 5, 12, DIFFUSE_AO_BINDING]:
		if not found_required.has(required_binding):
			_binding_error = true
			return binding_data
	uniforms.append(_ubo_uniform(UBO_BINDING))
	for field_index in CLV_MAGICDAWN_BAKED_SH_TEXTURE_COUNT:
		var field_value: Variant = fields[field_index]
		if not field_value is RID:
			_binding_error = true
			return binding_data
		var field_rid: RID = field_value
		if not field_rid.is_valid():
			_binding_error = true
			return binding_data
		uniforms.append(U.sampled(40 + field_index, field_sampler, field_rid))
	uniforms.append(U.uniform_buffer(21, clipmap_parameters))
	uniforms.append(U.uniform_buffer(PAGE_PARAMS_BINDING, _page_params_ubo))
	uniforms.append(U.storage_buffer(CLV_STATS_BINDING, _magicdawn_stats_buffer))
	binding_data["uniforms"] = uniforms
	return binding_data

func _ensure_magicdawn_stats_buffer(rd: RenderingDevice) -> bool:
	if _magicdawn_stats_buffer.is_valid():
		return true
	var zero := PackedByteArray()
	zero.resize(MAGICDAWN_STATS_BYTES)
	_magicdawn_stats_buffer = rd.storage_buffer_create(MAGICDAWN_STATS_BYTES, zero)
	if _magicdawn_stats_buffer.is_valid():
		_sync_owned_rid_snapshot()
	return _magicdawn_stats_buffer.is_valid()

func arm_magicdawn_stats_capture() -> bool:
	if _magicdawn_stats_capture_active or _magicdawn_stats_capture_armed \
			or clv_debug_view != CLVDebugView.OFF or prt_apply_scale != 1:
		return false
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _ensure_magicdawn_stats_buffer(rd) \
			or rd.buffer_clear(_magicdawn_stats_buffer, 0, MAGICDAWN_STATS_BYTES) != OK:
		return false
	_magicdawn_stats_capture_armed = true
	_magicdawn_stats_last_values = PackedInt32Array()
	return true

func read_magicdawn_stats() -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _magicdawn_stats_buffer.is_valid() \
			or _magicdawn_stats_capture_frame < 0:
		return {"status": "not_captured", "dispatch_frame": _magicdawn_stats_capture_frame}
	var bytes := rd.buffer_get_data(_magicdawn_stats_buffer, 0, MAGICDAWN_STATS_BYTES)
	var counts := bytes.to_int32_array()
	if counts.size() < MAGICDAWN_STATS_WORDS:
		return {"status": "readback_failed", "bytes": bytes.size()}
	_magicdawn_stats_last_values = counts
	return _magicdawn_stats_snapshot()

func _magicdawn_stats_snapshot() -> Dictionary:
	if _magicdawn_stats_last_values.size() < MAGICDAWN_STATS_WORDS:
		return {"status": "not_read_back", "dispatch_frame": _magicdawn_stats_capture_frame}
	var counts := _magicdawn_stats_last_values
	return {"status": "read_back", "dispatch_frame": _magicdawn_stats_capture_frame,
		"dispatched_invocations": counts[0], "depth_material_receivers": counts[1],
		"valid_world_normal_receivers": counts[2], "positive_coverage_samples": counts[3],
		"zero_coverage_samples": counts[4], "single_lod_samples": counts[5],
		"two_lod_transition_samples": counts[6], "outer_fade_samples": counts[7],
		"counts": counts}

func get_magicdawn_runtime_state() -> Dictionary:
	var state := _magicdawn_runtime_state.duplicate(true)
	state["dynamic_volume"] = _dynamic_volume_runtime_state.duplicate(true)
	state["dynamic_volume_screen"] = _dynamic_volume_screen_runtime_state.duplicate(true)
	state["screen_resolve_diagnostics"] = \
			_magicdawn_screen_diagnostic_result.duplicate(true)
	if not _magicdawn_active_readback_queue_state.is_empty():
		state["active_cache_readback_queue"] = _magicdawn_active_readback_queue_state.duplicate(true)
	if not _magicdawn_active_readback_result.is_empty():
		state["active_cache_readback"] = _magicdawn_active_readback_result.duplicate(true)
	var native_fusion := _native_baked_sh_state.duplicate(true)
	state["native_fusion"] = native_fusion
	var native_sky_ownership_active := bool(native_fusion.get("consumed", false)) \
			and bool(native_fusion.get("replacement_enabled", false))
	if native_sky_ownership_active:
		# Report the last publication the renderer actually consumed. The per-frame
		# scratch replacement flag is cleared after Execute and is not ownership state.
		state["replacement_enabled"] = true
		state["sky_ownership_bridge_active"] = true
	else:
		state["sky_ownership_bridge_active"] = bool(state.get("replacement_enabled", false))
	state["backend"] = _last_clv_cache_backend
	state["layout_version"] = _clv_layout_version_for_backend(_last_clv_cache_backend)
	state["screen_shader_resource"] = \
			"res://addons/feng-render-pipeline/library/magic-gi/magic_gi_apply_magicdawn.glsl"
	state["pixel_csr_fallback"] = false if _last_clv_cache_backend == 1 else null
	state["includes_primary_sky"] = bool(state.get("includes_primary_sky", false))
	state["includes_direct_directional_light"] = false
	state["receiver_sample_qa_mode"] = _magicdawn_receiver_qa_mode
	state["stats_capture_frame"] = _magicdawn_stats_capture_frame
	state["stats"] = _magicdawn_stats_snapshot()
	state["clv_debug_view"] = clv_debug_view
	state["clv_debug_view_supported"] = true
	state["clv_debug_view_status"] = _magicdawn_clv_debug_status \
			if _last_clv_cache_backend == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
			else "available"
	state["debug_sidecar_forced_standalone"] = _magicdawn_debug_sidecar_forced
	state["standalone_apply_dispatched"] = str(state.get("status", "")) == "dispatched"
	state["native_baked_sh_consumed"] = bool(native_fusion.get("consumed", false))
	var caches: Array[Dictionary] = []
	var dynamic_caches: Array[Dictionary] = []
	var primary_dynamic: Dictionary = {}
	var primary_dynamic_last_used := -1
	for entry_value in _clipmaps.values():
		if not entry_value is Dictionary:
			continue
		var entry := entry_value as Dictionary
		if int(entry.get("layout_version", -1)) == CLV_MAGICDAWN_DYNAMIC_PRT_LAYOUT_VERSION \
				and int(entry.get("cache_backend", -1)) == CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART \
				and bool(entry.get("dynamic_transfer", false)):
			var dynamic_cache_value: Variant = entry.get("cache")
			if dynamic_cache_value is RefCounted:
				var dynamic_cache: RefCounted = dynamic_cache_value
				if dynamic_cache.has_method("get_runtime_state"):
					var dynamic_cache_state_value: Variant = dynamic_cache.call("get_runtime_state")
					if dynamic_cache_state_value is Dictionary:
						var dynamic_cache_state: Dictionary = dynamic_cache_state_value
						var dynamic_entry := {
							"view": int(entry.get("view", -1)),
							"cache_key": str(entry.get("bake", "")),
							"source_probe_count": int(entry.get("source_probe_count", 0)),
							"emitter_count": int(entry.get("emitter_count", 0)),
							"lighting_revision": int(entry.get("last_lighting_revision", -1)),
							"gpu_bytes": int(entry.get("gpu_bytes", 0)),
							"gpu_bytes_breakdown": entry.get("gpu_bytes_breakdown", {}),
							"cache_state": dynamic_cache_state.duplicate(true),
						}
						dynamic_caches.append(dynamic_entry)
						var last_used := int(entry.get("last_used", 0))
						if last_used >= primary_dynamic_last_used:
							primary_dynamic = dynamic_entry
							primary_dynamic_last_used = last_used
		if int(entry.get("layout_version", -1)) != CLV_MAGICDAWN_BAKED_SH_LAYOUT_VERSION:
			continue
		var cache: RefCounted = entry.get("cache")
		if cache != null and cache.has_method("get_layout16_runtime_state"):
			caches.append(cache.call("get_layout16_runtime_state"))
	state["field_caches"] = caches
	state["dynamic_clv_caches"] = dynamic_caches
	state["dynamic_clv_cache_count"] = dynamic_caches.size()
	state["prt_model"] = "CLV_BLOCK_RELIGHT" if not primary_dynamic.is_empty() else ""
	state["sh_basis"] = "real_orthonormal_degree2_coefficients9" \
			if not primary_dynamic.is_empty() else ""
	if not primary_dynamic.is_empty():
		var dynamic_cache_state: Dictionary = primary_dynamic.get("cache_state", {})
		var completed_revision := int(dynamic_cache_state.get("relight_lighting_revision", -1))
		var geometry_pending := int(dynamic_cache_state.get("geometry_pending_blocks", 0))
		# The backend is selected from the live cache below; publish the current
		# mirror state here as well so callers do not see the pre-selection default.
		state["clv_debug_view_status"] = _magicdawn_clv_debug_status
		state["backend"] = CLV_CACHE_BACKEND_MAGICDAWN_BLOCK_CHART
		state["layout_version"] = CLV_MAGICDAWN_DYNAMIC_PRT_LAYOUT_VERSION
		state["view"] = int(primary_dynamic.get("view", -1))
		state["cache_key"] = str(primary_dynamic.get("cache_key", ""))
		state["source_probe_count"] = int(primary_dynamic.get("source_probe_count", 0))
		state["emitter_count"] = int(primary_dynamic.get("emitter_count", 0))
		state["lighting_revision"] = int(primary_dynamic.get("lighting_revision", -1))
		state["completed_lighting_revision"] = completed_revision
		state["dirty_blocks"] = geometry_pending
		state["pending_blocks"] = int(dynamic_cache_state.get("pending_blocks", geometry_pending))
		state["geometry_pending_blocks"] = geometry_pending
		state["dispatch_serial"] = int(dynamic_cache_state.get("dispatch_serial", 0))
		state["dispatch_frame"] = int(dynamic_cache_state.get("last_dispatch_frame", -1))
		state["last_dispatch_frame"] = int(dynamic_cache_state.get("last_dispatch_frame", -1))
		state["last_dispatch_blocks"] = int(dynamic_cache_state.get("last_dispatch_blocks", 0))
		state["relight_serial"] = int(dynamic_cache_state.get("relight_serial", 0))
		state["relight_dispatches"] = int(dynamic_cache_state.get("relight_serial", 0))
		state["last_relight_frame"] = int(dynamic_cache_state.get("last_relight_frame", -1))
		state["last_relight_cells"] = int(dynamic_cache_state.get("last_relight_cells", 0))
		state["last_relight_faces"] = int(dynamic_cache_state.get("last_relight_faces", 0))
		state["relight_lighting_revision"] = completed_revision
		state["relight_pending"] = bool(dynamic_cache_state.get("relight_pending", true))
		state["relight_scheduled_and_dispatched"] = bool(
				dynamic_cache_state.get("relight_scheduled_and_dispatched", false))
		state["scheduled_and_dispatched"] = bool(
				dynamic_cache_state.get("scheduled_and_dispatched", false))
		state["fill_scheduled_and_dispatched"] = bool(
				dynamic_cache_state.get("fill_scheduled_and_dispatched", false))
		state["resident_levels"] = int(dynamic_cache_state.get("resident_levels", 0))
		state["resident_resolution"] = int(dynamic_cache_state.get("resident_resolution", 0))
		state["resolution"] = int(dynamic_cache_state.get("resident_resolution", 0))
		state["resident_cells"] = int(dynamic_cache_state.get("resident_cells", 0))
		state["resident_face_slots"] = int(dynamic_cache_state.get("resident_face_slots", 0))
		state["face_slots"] = int(dynamic_cache_state.get("resident_face_slots", 0))
		state["transfer_matrix_valid"] = bool(dynamic_cache_state.get("transfer_matrix_valid", false))
		state["transfer_matrix_emitters"] = int(
				dynamic_cache_state.get("transfer_matrix_emitters", -1))
		state["transfer_matrix_bytes"] = int(dynamic_cache_state.get("transfer_matrix_bytes", 0))
		state["transfer_matrix_error"] = str(dynamic_cache_state.get("relight_error", ""))
		state["cache_error"] = str(dynamic_cache_state.get("relight_error", ""))
		state["gpu_bytes"] = int(primary_dynamic.get("gpu_bytes", 0))
		state["gpu_bytes_breakdown"] = primary_dynamic.get("gpu_bytes_breakdown", {})
		state["cache_state"] = dynamic_cache_state.duplicate(true)
	var volume_cache_state: Dictionary = _dynamic_volume_runtime_state.get("cache", {})
	if bool(volume_cache_state.get("preinterpolated_transfer", false)):
		state["backend"] = "preinterpolated_clv_transfer"
		state["layout_version"] = int(volume_cache_state.get("layout_version", 0))
		state["prt_model"] = "CLV_TRANSFER_MATRIX_RELIGHT"
		state["sh_basis"] = "real_orthonormal_degree2_coefficients9"
		state["runtime_geometry_queries"] = 0
		state["pixel_csr_fallback"] = false
		state["resident_levels"] = volume_cache_state.get("clipmap_lod_count", 0)
		state["resident_cells"] = volume_cache_state.get("clip_cell_count", 0)
		state["clipmap_resolution"] = volume_cache_state.get("clipmap_resolution", 16)
		state["valid_resident_cells"] = volume_cache_state.get("valid_resident_cells", 0)
		state["gpu_bytes"] = volume_cache_state.get("gpu_bytes", 0)
		state["relight_serial"] = volume_cache_state.get("relight_revision", 0)
		state["clv_debug_view_status"] = _magicdawn_clv_debug_status
		if bool(volume_cache_state.get("paged_prepared_transfer", false)):
			state["backend"] = "paged_preinterpolated_clv_transfer"
			for field in ["gi_radius_m", "loaded_bricks", "resident_operator_slots",
				"operator_pool_bytes", "gpu_budget_bytes", "uploaded_operator_bytes_last_update",
				"maximum_uploaded_operator_bytes", "requested_upload_budget_bytes",
				"upload_budget_enforced", "upload_budget_exceeded_count", "prepared_pages_revision"]:
				state[field] = volume_cache_state.get(field)
	return state

func _render_magicdawn_compute(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice) -> void:
	if workgroup_size.x <= 0 or workgroup_size.y <= 0:
		_magicdawn_runtime_state["status"] = "invalid_workgroup_size"
		return
	var binding_data := _collect_bindings(buffers, view, rd)
	if _binding_error:
		_magicdawn_runtime_state["status"] = "apply_binding_failed"
		return
	var uniforms: Array[RDUniform] = binding_data.get("uniforms", [])
	var uniform_set := _make_uniform_set(uniforms)
	if not uniform_set.is_valid():
		_magicdawn_runtime_state["status"] = "apply_uniform_set_failed"
		return
	var dispatch_size := buffers.get_internal_size()
	var target := _selected_target(false)
	if target != &"":
		if not buffers.has_texture(PIPELINE_SCOPE, target):
			_magicdawn_runtime_state["status"] = "apply_target_unavailable"
			return
		dispatch_size = buffers.get_texture_slice_size(PIPELINE_SCOPE, target, 0)
	if dispatch_size.x <= 0 or dispatch_size.y <= 0:
		_magicdawn_runtime_state["status"] = "empty_dispatch"
		return
	var list := rd.compute_list_begin()
	if list < 0:
		_magicdawn_runtime_state["status"] = "compute_list_begin_failed"
		return
	rd.compute_list_bind_compute_pipeline(list, _compute_pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	var push := _parameter_bytes()
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list,
		ceili(float(dispatch_size.x) / workgroup_size.x),
		ceili(float(dispatch_size.y) / workgroup_size.y), 1)
	rd.compute_list_end()
	_magicdawn_runtime_state["status"] = "dispatched"
	_magicdawn_runtime_state["dispatch_frame"] = Engine.get_process_frames()
	if _magicdawn_stats_capture_active:
		_magicdawn_stats_capture_frame = Engine.get_process_frames()
		_magicdawn_runtime_state["stats_capture_frame"] = _magicdawn_stats_capture_frame
	_magicdawn_runtime_state["dispatch_size"] = [dispatch_size.x, dispatch_size.y]
	_magicdawn_runtime_state["shader_resource"] = \
			"res://addons/feng-render-pipeline/library/magic-gi/magic_gi_apply_magicdawn.glsl"
	_magicdawn_runtime_state["includes_primary_sky"] = true
	_magicdawn_runtime_state["includes_direct_directional_light"] = false
	_magicdawn_runtime_state["pixel_csr_fallback"] = false
	_magicdawn_runtime_state["replacement_enabled"] = _frame_replacement_enabled
	_magicdawn_runtime_state["baked_indirect_sh_revision"] = 2
	_magicdawn_runtime_state["source_spacing_m"] = float(_frame_snapshot.get("source_spacing", 0.25))
	_magicdawn_runtime_state["clv_spacing_m"] = float(_frame_snapshot.get("clv_cell_size", 0.25))

func _ensure_exact_point_debug_buffer(rd: RenderingDevice) -> bool:
	if _exact_point_debug_buffer.is_valid():
		return true
	var zero := PackedByteArray()
	zero.resize(144)
	_exact_point_debug_buffer = rd.storage_buffer_create(144, zero)
	if _exact_point_debug_buffer.is_valid():
		_sync_owned_rid_snapshot()
	return _exact_point_debug_buffer.is_valid()

func _ensure_probe_neighbor_mask_disabled(rd: RenderingDevice) -> bool:
	if _probe_neighbor_mask_disabled.is_valid():
		return true
	var dummy := PackedInt32Array([0, 0, 0, 0]).to_byte_array()
	_probe_neighbor_mask_disabled = rd.storage_buffer_create(dummy.size(), dummy)
	if _probe_neighbor_mask_disabled.is_valid():
		_sync_owned_rid_snapshot()
	return _probe_neighbor_mask_disabled.is_valid()

## Arm one untimed diagnostic frame. Reading the buffer synchronizes with the GPU,
## so callers must do so only after the capture frame and outside timing samples.
func arm_prt_clv_stats_capture() -> bool:
	if clv_debug_view != CLVDebugView.OFF or prt_apply_scale != 1 \
			or int(prt_surface_exact_debug_mode) != 0 or _clv_stats_capture_active:
		return false
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _ensure_clv_stats_buffer(rd):
		return false
	if rd.buffer_clear(_clv_stats_buffer, 0, CLV_STATS_BYTES) != OK:
		return false
	_clv_stats_capture_armed = true
	return true

## Arm one selected receiver pixel. Each mode is a separate untimed frame, with
## a fresh sidecar buffer so an unchanged marker cannot masquerade as a capture.
func arm_prt_clv_point_capture(mode: int, pixel: Vector2i) -> bool:
	if mode < 107 or mode > 110 or pixel.x < 0 or pixel.y < 0 \
			or clv_debug_view != CLVDebugView.OFF or prt_apply_scale != 1 \
			or int(prt_surface_exact_debug_mode) != 0 \
			or _clv_stats_capture_active or _clv_stats_capture_armed:
		return false
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _ensure_exact_point_debug_buffer(rd):
		return false
	if rd.buffer_clear(_exact_point_debug_buffer, 0, 144) != OK:
		return false
	prt_surface_exact_debug_pixel = pixel
	prt_surface_exact_debug_mode = mode
	return true

func read_prt_clv_point_fields() -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _exact_point_debug_buffer.is_valid():
		return {}
	var bytes := rd.buffer_get_data(_exact_point_debug_buffer, 0, 144)
	if bytes.size() < 144:
		return {}
	var floats := bytes.to_float32_array()
	var integers := bytes.to_int32_array()
	var approximate_diag_code_word := bytes.decode_u32(136)
	var approximate_diag_status_word := bytes.decode_u32(140)
	var approximate_diag_reasons := [
		approximate_diag_code_word & 0xff,
		(approximate_diag_code_word >> 8) & 0xff,
		(approximate_diag_code_word >> 16) & 0xff,
	]
	var approximate_diag_reason_names := []
	for reason_code in approximate_diag_reasons:
		if reason_code == 0:
			approximate_diag_reason_names.append("accepted")
		elif reason_code == 255:
			approximate_diag_reason_names.append("not_attempted")
		elif reason_code <= CLV_APPROX_DIAG_LEVEL_REASONS.size():
			approximate_diag_reason_names.append(CLV_APPROX_DIAG_LEVEL_REASONS[reason_code - 1])
		else:
			approximate_diag_reason_names.append("unknown")
	var approximate_diag_global_code := (approximate_diag_code_word >> 24) & 0xff
	var approximate_diag_global_name := "none"
	if approximate_diag_global_code > 0 \
			and approximate_diag_global_code <= CLV_APPROX_DIAG_GLOBAL_REASONS.size():
		approximate_diag_global_name = CLV_APPROX_DIAG_GLOBAL_REASONS[
				approximate_diag_global_code - 1]
	var approximate_diag_available := \
			(approximate_diag_status_word & 0xff000000) == 0xa9000000
	return {
		"secondary": Vector3(floats[0], floats[1], floats[2]),
		"primary_sky": Vector3(floats[3], floats[4], floats[5]),
		"status": integers[6],
		"marker": integers[7],
		"receiver_world": Vector3(floats[10], floats[11], floats[12]),
		"receiver_normal": Vector3(floats[13], floats[14], floats[15]),
		"receiver_triangle": integers[16],
		"approximate_confidence": floats[17],
		"approximate_level": integers[33] - 1 if integers[33] > 0 else -1,
		"approximate_diagnostic_available": approximate_diag_available,
		"approximate_diagnostic_hit": approximate_diag_available \
				and (approximate_diag_status_word & 1) != 0,
		"approximate_diagnostic_level": \
				((approximate_diag_status_word >> 1) & 3) - 1 \
				if approximate_diag_available and ((approximate_diag_status_word >> 1) & 3) > 0 else -1,
		"approximate_reject_codes_by_level": approximate_diag_reasons,
		"approximate_reject_reasons_by_level": approximate_diag_reason_names,
		"approximate_global_reject_code": approximate_diag_global_code,
		"approximate_global_reject_reason": approximate_diag_global_name,
		"sky_diffuse_before_replacement": Vector3(floats[18], floats[19], floats[20]),
		"scene_color_before_magic_gi": Vector3(floats[21], floats[22], floats[23]),
		"material_albedo": Vector3(floats[24], floats[25], floats[26]),
		"material_ao": floats[27],
		"material_metallic": floats[28],
		"diffuse_ambient_occlusion": floats[29],
		"gi_strength": floats[30],
		"pass_strength": floats[31],
		"pre_exposure_times_scene_normalization": floats[32],
		"mode": prt_surface_exact_debug_last_mode,
		"capture_frame": prt_surface_exact_debug_capture_frame,
	}

func read_prt_clv_stats() -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _clv_stats_buffer.is_valid():
		return {}
	var values := rd.buffer_get_data(_clv_stats_buffer, 0, CLV_STATS_BYTES).to_int32_array()
	if values.size() < CLV_STATS_WORDS:
		return {}
	var approximate_diag_levels := []
	for level in range(3):
		var counter_base := 80 + level * 20
		var level_rejections := {}
		for reason_code in range(1, CLV_APPROX_DIAG_LEVEL_REASONS.size() + 1):
			level_rejections[CLV_APPROX_DIAG_LEVEL_REASONS[reason_code - 1]] = \
					values[counter_base + 1 + reason_code]
		approximate_diag_levels.append({
			"attempts": values[counter_base],
			"accepted": values[counter_base + 1],
			"rejections": level_rejections,
		})
	var approximate_diag_global_rejections := {}
	for reason_code in range(1, CLV_APPROX_DIAG_GLOBAL_REASONS.size() + 1):
		approximate_diag_global_rejections[CLV_APPROX_DIAG_GLOBAL_REASONS[reason_code - 1]] = \
				values[73 + reason_code]
	return {
		"raw_counts": values,
		"dispatched_samples": values[0],
		"depth_lit_candidates": values[1],
		"in_bake_coverage": values[2],
		"certified_trilinear_hits": values[3],
		"general_clv_hits": values[4],
		"source_probe_gathers": values[5],
		"positive_visible_support": values[6],
		"nonzero_prt_contribution": values[7],
		"certified_reject_bad_layout_or_input": values[8],
		"certified_reject_outside_all_levels": values[9],
		"certified_reject_tag_or_epoch": values[10],
		"certified_reject_axis_support": values[11],
		"certified_reject_normal": values[12],
		"certified_reject_plane_or_bounds": values[13],
		"general_clv_attempts": values[14],
		"general_clv_reject_disabled": values[15],
		"general_clv_reject_outside": values[16],
		"general_clv_reject_no_valid_corners": values[17],
		"general_clv_reject_geometry_blocked": values[18],
		"general_clv_reject_no_exact_support": values[19],
		"general_clv_reject_no_exact_candidate": values[20],
		"general_clv_reject_outside_bake_grid": values[21],
		"general_clv_reject_incomplete_support": values[22],
		"general_clv_reject_uncertified": values[23],
		"general_clv_full_support_hits": values[24],
		"general_clv_filtered_hits": values[25],
		"general_clv_level_0_hits": values[26],
		"general_clv_level_1_hits": values[27],
		"general_clv_level_2_hits": values[28],
		"certified_level_0_hits": values[29],
		"certified_level_1_hits": values[30],
		"certified_level_2_hits": values[31],
		"general_clv_level_queries": values[32],
		"general_clv_corner_tag_metadata_reads": values[33],
		"general_clv_positive_valid_corners": values[34],
		"general_clv_box_certificate_tests": values[35],
		"general_clv_visibility_moment_queries": values[36],
		"general_clv_radiance_texture_samples": values[37],
		"general_clv_exact_visibility_queries": values[57],
		"general_clv_exact_visibility_blocked": values[58],
		"general_clv_exact_visibility_source_side_rejects": values[59],
		"gather_neighbor_cells_visited": values[38],
		"gather_neighbor_cells_mask_skipped": values[39],
		"gather_neighbor_cells_window_zero": values[40],
		"gather_probe_slot_lookups": values[41],
		"gather_valid_probe_ids": values[42],
		"gather_probe_surface_records": values[43],
		"gather_plane_gate_passes": values[44],
		"gather_visibility_checks": values[45],
		"gather_visibility_moment_queries": values[46],
		"gather_accepted_probe_contributions": values[47],
		"gather_radiance_texture_samples": values[48],
		"gather_wide_fallback_neighborhoods": values[49],
		"gather_wide_pool_candidates_tested": values[50],
		"gather_wide_pool_candidates_visible": values[51],
		"approximate_volume_hits": values[52],
		"approximate_volume_level_0_hits": values[53],
		"approximate_volume_level_1_hits": values[54],
		"approximate_volume_level_2_hits": values[55],
		"approximate_volume_mean_confidence": float(values[56]) / maxf(float(values[52]) * 1000.0, 1.0),
		"approximate_volume_confidence_histogram": {
			"0.0-0.1": values[60], "0.1-0.2": values[61], "0.2-0.3": values[62],
			"0.3-0.4": values[63], "0.4-0.5": values[64], "0.5-0.6": values[65],
			"0.6-0.7": values[66], "0.7-0.8": values[67], "0.8-0.9": values[68],
			"0.9-1.0": values[69]},
		"approximate_diagnostic_calls": values[70],
		"approximate_diagnostic_hits": values[71],
		"approximate_diagnostic_misses": values[72],
		"approximate_diagnostic_mismatches": values[73],
		"approximate_diagnostic_global_rejections": approximate_diag_global_rejections,
		"approximate_diagnostic_levels": approximate_diag_levels,
		"capture_frame": _clv_stats_capture_frame,
	}

func _ensure_clv_stats_buffer(rd: RenderingDevice) -> bool:
	if _clv_stats_buffer.is_valid() and _clv_stats_buffer_bytes == CLV_STATS_BYTES:
		return true
	if _clv_stats_buffer.is_valid():
		rd.free_rid(_clv_stats_buffer)
		_clv_stats_buffer = RID()
	_clv_stats_buffer_bytes = 0
	# Remove the retired RID from the deferred ownership snapshot before any
	# replacement allocation can fail. Otherwise shutdown may later free a RID
	# that this method already released.
	_sync_owned_rid_snapshot()
	var zero := PackedByteArray()
	zero.resize(CLV_STATS_BYTES)
	_clv_stats_buffer = rd.storage_buffer_create(CLV_STATS_BYTES, zero)
	if _clv_stats_buffer.is_valid():
		_clv_stats_buffer_bytes = CLV_STATS_BYTES
		_sync_owned_rid_snapshot()
	return _clv_stats_buffer.is_valid()


func _collect_frame_input_bindings(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> Dictionary:
	_binding_error = false
	if _frame_input_bindings.has(view):
		return _frame_input_bindings[view].duplicate()
	var binding_data := super._collect_bindings(buffers, view, rd)
	if _binding_error or _frame_snapshot.is_empty():
		return binding_data
	if not _ensure_sampler(rd):
		_binding_error = true
		return binding_data
	var sky_diffuse: RID = _sky_diffuse_input.get_texture(buffers, view)
	if not sky_diffuse.is_valid():
		sky_diffuse = _ensure_zero_sky_diffuse(rd)
	var diffuse_ao := _get_diffuse_ao_view(buffers, view, rd)
	if not diffuse_ao.is_valid():
		diffuse_ao = _ensure_white_diffuse_ao(rd)
	if not sky_diffuse.is_valid() or not diffuse_ao.is_valid():
		_binding_error = true
		_report("Cannot create the neutral SkyLight or diffuse AO fallback texture.")
		return binding_data
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	uniforms.append(U.sampled(12, _sampler, sky_diffuse))
	uniforms.append(U.sampled(DIFFUSE_AO_BINDING, _sampler, diffuse_ao))
	_frame_input_bindings[view] = binding_data
	return binding_data.duplicate()


func _cluster_binding_for_cache(cached: Dictionary, rd: RenderingDevice) -> RID:
	var cluster_rid: RID = cached.get("probe_clusters", RID())
	if probe_cluster_culling_enabled and bool(cached.get("probe_cluster_enabled", false)) \
			and cluster_rid.is_valid():
		return cluster_rid
	if not _probe_cluster_fallback.is_valid():
		var disabled := ProbeClusters.disabled_payload("diagnostic-fallback")
		var bytes: PackedByteArray = disabled["bytes"]
		_probe_cluster_fallback = rd.storage_buffer_create(bytes.size(), bytes)
		if _probe_cluster_fallback.is_valid():
			_sync_owned_rid_snapshot()
	return _probe_cluster_fallback

func _ensure_clv_fallback(rd: RenderingDevice) -> bool:
	if not _clv_fallback.is_empty():
		return true
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.width = 1
	format.height = 1
	format.depth = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	var zero := PackedByteArray()
	zero.resize(16)
	var texture := rd.texture_create(format, RDTextureView.new(), [zero])
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT
	var tags := rd.texture_create(format, RDTextureView.new(), [zero])
	format.format = RenderingDevice.DATA_FORMAT_R32_UINT
	zero.resize(4)
	var support := rd.texture_create(format, RDTextureView.new(), [zero])
	zero.resize(80)
	_clv_fallback = {"texture": texture, "tags": tags, "support": support,
		"parameters": rd.uniform_buffer_create(80, zero), "lighting": rd.storage_buffer_create(320)}
	_clv_fallback_mode = -1
	for rid: RID in _clv_fallback.values():
		if not rid.is_valid():
			for allocated: RID in _clv_fallback.values():
				if allocated.is_valid():
					rd.free_rid(allocated)
			_clv_fallback.clear()
			return false
	_sync_owned_rid_snapshot()
	return true

func _prune_clipmaps(rd: RenderingDevice) -> void:
	var removed := false
	for key in _clipmaps.keys():
		if _clipmaps[key].owner.get_ref() == null:
			_free_rids(rd, _clipmaps[key].cache.owned_rids())
			_clipmaps.erase(key)
			removed = true
	while _clipmaps.size() > 32:
		var oldest_key := ""
		var oldest := 0x7fffffff
		for key in _clipmaps:
			var entry: Dictionary = _clipmaps[key]
			if entry.cache == _frame_clipmap or (bool(entry.get("streamed", false)) \
					and int(entry.get("last_used", -1)) >= _stream_frame_token):
				continue
			if int(entry.last_used) < oldest:
				oldest = int(_clipmaps[key].last_used)
				oldest_key = key
		if oldest_key.is_empty():
			break
		_free_rids(rd, _clipmaps[oldest_key].cache.owned_rids())
		_clipmaps.erase(oldest_key)
		removed = true
	if removed:
		_sync_owned_rid_snapshot()

func _get_diffuse_ao_view(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> RID:
	var texture := _frame_diffuse_ao_texture
	if buffers == null or not texture.is_valid() or not rd.texture_is_valid(texture):
		return RID()
	var format := rd.texture_get_format(texture)
	var size := buffers.get_internal_size()
	var multi := buffers.get_view_count() > 1
	var expected_type := RenderingDevice.TEXTURE_TYPE_2D_ARRAY if multi else RenderingDevice.TEXTURE_TYPE_2D
	if format.texture_type != expected_type or (format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) == 0 \
			or format.width != size.x or format.height != size.y \
			or (multi and format.array_layers < buffers.get_view_count()):
		return RID()
	if not multi:
		return texture
	var cache_key := "%s:%d" % [str(texture.get_id()), view]
	_diffuse_ao_cache_clock += 1
	var cached: Dictionary = _diffuse_ao_view_cache.get(cache_key, {})
	if not cached.is_empty() and cached.get("base", RID()) == texture and rd.texture_is_valid(cached.get("view", RID())):
		cached["last_used"] = _diffuse_ao_cache_clock
		_diffuse_ao_view_cache[cache_key] = cached
		return cached["view"]
	var texture_view := RDTextureView.new()
	texture_view.format_override = format.format
	var slice := rd.texture_create_shared_from_slice(texture_view, texture, view, 0, 1, RenderingDevice.TEXTURE_SLICE_2D)
	if not slice.is_valid():
		return RID()
	_diffuse_ao_view_cache[cache_key] = {"base": texture, "view": slice, "last_used": _diffuse_ao_cache_clock}
	_prune_diffuse_ao_view_cache(rd)
	_sync_owned_rid_snapshot()
	return slice

func _prune_diffuse_ao_view_cache(rd: RenderingDevice) -> void:
	var removed_invalid := false
	for key in _diffuse_ao_view_cache.keys():
		var cached: Dictionary = _diffuse_ao_view_cache[key]
		var base: RID = cached.get("base", RID())
		var view: RID = cached.get("view", RID())
		if not base.is_valid() or not rd.texture_is_valid(base) or not view.is_valid() or not rd.texture_is_valid(view):
			if view.is_valid() and rd.texture_is_valid(view):
				rd.free_rid(view)
			_diffuse_ao_view_cache.erase(key)
			removed_invalid = true
	while _diffuse_ao_view_cache.size() > DIFFUSE_AO_VIEW_CACHE_LIMIT:
		var oldest_key := ""
		var oldest := 0x7fffffff
		for key in _diffuse_ao_view_cache:
			var last_used := int(_diffuse_ao_view_cache[key].get("last_used", 0))
			if last_used < oldest:
				oldest = last_used
				oldest_key = str(key)
		if oldest_key.is_empty():
			return
		var cached: Dictionary = _diffuse_ao_view_cache[oldest_key]
		var view: RID = cached.get("view", RID())
		if view.is_valid():
			rd.free_rid(view)
		_diffuse_ao_view_cache.erase(oldest_key)
		removed_invalid = true
	if removed_invalid:
		_sync_owned_rid_snapshot()

func _ensure_white_diffuse_ao(rd: RenderingDevice) -> RID:
	if _diffuse_ao_white.is_valid() and rd.texture_is_valid(_diffuse_ao_white):
		return _diffuse_ao_white
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	# IEEE 754 binary16 1.0, serialized little-endian for one R16F texel.
	_diffuse_ao_white = rd.texture_create(format, RDTextureView.new(), [PackedByteArray([0x00, 0x3c])])
	_sync_owned_rid_snapshot()
	return _diffuse_ao_white

func _ensure_zero_sky_diffuse(rd: RenderingDevice) -> RID:
	if _zero_sky_diffuse.is_valid():
		return _zero_sky_diffuse
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBAH)
	if image == null:
		return RID()
	image.set_pixel(0, 0, Color(0, 0, 0, 0))
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var layer_data: Array[PackedByteArray] = [image.get_data()]
	_zero_sky_diffuse = rd.texture_create(format, RDTextureView.new(), layer_data)
	_sync_owned_rid_snapshot()
	return _zero_sky_diffuse

func _current_owned_rids() -> Array[RID]:
	var rids: Array[RID] = []
	if _dynamic_volume_cache != null and _dynamic_volume_cache.has_method("owned_rids"):
		rids.append_array(_dynamic_volume_cache.call("owned_rids"))
	if _surfel_gpu != null and _surfel_gpu.has_method("get_all_rids"):
		rids.append_array(_surfel_gpu.call("get_all_rids"))
	if _surfel_nrd != null and _surfel_nrd.has_method("get_all_rids"):
		rids.append_array(_surfel_nrd.call("get_all_rids"))
	rids.append_array(_raster_pipelines.values())
	rids.append_array([_compute_pipeline, _shader, _sampler, _ubo])
	rids.append_array(_prt_stage_pipelines.values())
	rids.append(_prt_source_pending_texture)
	rids.append(_prt_compact_finalize_uniform_set)
	rids.append(_prt_compact_finalize_pipeline)
	rids.append_array(_prt_compact_pipelines.values())
	rids.append_array([_prt_compact_shader, _prt_compact_finalize_shader,
		_prt_compact_queue_buffer, _prt_compact_queue_control_buffer,
		_prt_compact_indirect_args_buffer])
	rids.append_array([_exact_point_debug_buffer, _clv_stats_buffer, _magicdawn_stats_buffer])
	rids.append(_probe_neighbor_mask_disabled)
	rids.append_array(_native_owner_ubos)
	rids.append_array(_magicdawn_native_owner_ubos)
	rids.append(_native_gi_parameters_ubo)
	rids.append_array([_relight_pipeline, _relight_shader])
	rids.append_array([_magicdawn_clv_debug_pipeline, _magicdawn_clv_debug_shader,
		_magicdawn_clv_debug_nearest_sampler, _magicdawn_clv_debug_linear_sampler])
	if _dynamic_volume_debug != null:
		rids.append_array(_dynamic_volume_debug.owned_rids())
	rids.append_array([_magicdawn_screen_classify_pipeline, _magicdawn_screen_classify_shader])
	rids.append_array([_magicdawn_screen_resolve_pipeline,
		_magicdawn_screen_resolve_shader, _magicdawn_screen_resolve_nearest_sampler,
		_magicdawn_screen_resolve_linear_sampler,
		_magicdawn_screen_resolve_diagnostics_buffer])
	rids.append_array([_magicdawn_screen_partial_pipeline, _magicdawn_screen_partial_shader])
	rids.append_array([_dynamic_volume_screen_resolve_pipeline,
		_dynamic_volume_screen_resolve_shader, _dynamic_volume_screen_nearest_sampler,
		_dynamic_volume_screen_linear_sampler,
		_dynamic_volume_screen_diagnostics_buffer, _dynamic_volume_screen_frame_ubo])
	rids.append_array([_page_params_ubo, _probe_cluster_fallback, _pending_page_params_ubo,
		_pending_page_pipeline, _pending_page_shader, _prt_guide_pipeline,
		_prt_guide_shader, _prt_resolve_pipeline, _prt_resolve_shader,
		_prt_linear_sampler])
	for raw_view: Dictionary in _prt_raw_views.values():
		for name in ["texture", "guide", "certificate"]:
			var texture: RID = raw_view.get(name, RID())
			if texture.is_valid():
				rids.append(texture)
	for uploader: RefCounted in _page_uploads.values():
		if uploader != null and uploader.has_method("owned_rids"):
			rids.append_array(uploader.call("owned_rids"))
	for rid: RID in _clv_fallback.values():
		rids.append(rid)
	for entry: Dictionary in _clipmaps.values():
		rids.append_array(entry.cache.owned_rids())
	for bake: Dictionary in _bake_resources.values():
		if bake.get("directional") != null:
			rids.append_array(bake.directional.owned_rids())
	rids.append_array([_zero_sky_diffuse, _diffuse_ao_white])
	for cached in _bake_resources.values():
		for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
				"visibility_nodes", "visibility_triangles", "indices", "index_entries",
				"probe_clusters", "emission", "probe_lighting", "probe_neighbor_masks",
				"probe_neighbor_cell_lists"]:
			var rid: RID = cached.get(name, RID())
			if rid.is_valid():
				rids.append(rid)
	for cached in _diffuse_ao_view_cache.values():
		var view: RID = cached.get("view", RID())
		var rd := RenderingServer.get_rendering_device()
		if view.is_valid() and rd != null and rd.texture_is_valid(view):
			rids.append(view)
	return rids

func _sync_owned_rid_snapshot() -> void:
	_replace_owned_rid_snapshot(_current_owned_rids())

func _take_owned_rids() -> Array[RID]:
	# PREDELETE invalidates this script's live dispatch after the inherited
	# shader pass transfers its RIDs. Capture the complete owned-only inventory
	# and clear our fields first; only append the detached snapshot afterwards.
	var owned_rids: Array[RID] = super.call("_current_owned_rids")
	if _dynamic_volume_cache != null and _dynamic_volume_cache.has_method("owned_rids"):
		owned_rids.append_array(_dynamic_volume_cache.call("owned_rids"))
	if _surfel_gpu != null and _surfel_gpu.has_method("take_owned_rids"):
		owned_rids.append_array(_surfel_gpu.call("take_owned_rids"))
	if _surfel_nrd != null and _surfel_nrd.has_method("take_owned_rids"):
		owned_rids.append_array(_surfel_nrd.call("take_owned_rids"))
	owned_rids.append_array([_prt_guide_pipeline, _prt_guide_shader,
		_prt_resolve_pipeline, _prt_resolve_shader,
		_prt_linear_sampler])
	owned_rids.append_array([_exact_point_debug_buffer, _clv_stats_buffer, _magicdawn_stats_buffer])
	owned_rids.append_array([_magicdawn_clv_debug_pipeline, _magicdawn_clv_debug_shader,
		_magicdawn_clv_debug_nearest_sampler, _magicdawn_clv_debug_linear_sampler])
	if _dynamic_volume_debug != null:
		owned_rids.append_array(_dynamic_volume_debug.owned_rids())
	owned_rids.append_array([_magicdawn_screen_classify_pipeline, _magicdawn_screen_classify_shader])
	owned_rids.append_array([_magicdawn_screen_resolve_pipeline,
		_magicdawn_screen_resolve_shader, _magicdawn_screen_resolve_nearest_sampler,
		_magicdawn_screen_resolve_linear_sampler,
		_magicdawn_screen_resolve_diagnostics_buffer])
	owned_rids.append_array([_magicdawn_screen_partial_pipeline, _magicdawn_screen_partial_shader])
	owned_rids.append_array([_dynamic_volume_screen_resolve_pipeline,
		_dynamic_volume_screen_resolve_shader, _dynamic_volume_screen_nearest_sampler,
		_dynamic_volume_screen_linear_sampler,
		_dynamic_volume_screen_diagnostics_buffer, _dynamic_volume_screen_frame_ubo])
	owned_rids.append_array(_magicdawn_native_owner_ubos)
	owned_rids.append(_probe_neighbor_mask_disabled)
	owned_rids.append_array(_prt_stage_pipelines.values())
	owned_rids.append(_prt_source_pending_texture)
	owned_rids.append(_prt_compact_finalize_uniform_set)
	owned_rids.append(_prt_compact_finalize_pipeline)
	owned_rids.append_array(_prt_compact_pipelines.values())
	owned_rids.append_array([_prt_compact_shader, _prt_compact_finalize_shader,
		_prt_compact_queue_buffer, _prt_compact_queue_control_buffer,
		_prt_compact_indirect_args_buffer])
	for raw_view: Dictionary in _prt_raw_views.values():
		for name in ["texture", "guide", "certificate"]:
			var texture: RID = raw_view.get(name, RID())
			if texture.is_valid():
				owned_rids.append(texture)
	_surfel_gpu = null
	_surfel_nrd = null
	_dynamic_volume_cache = null
	_dynamic_volume_cache_key = ""
	_dynamic_volume_source_instance_id = 0
	_dynamic_volume_publication_token = 0
	_dynamic_volume_runtime_state = {"status": "detached"}
	_dynamic_volume_screen_runtime_state = {"status": "detached", "active": false}
	_dynamic_volume_debug = null
	_bake_resources.clear()
	_page_uploads.clear()
	_page_ready_by_key.clear()
	_page_failed_versions.clear()
	_stream_frame_demands.clear()
	_page_residency = null
	_clipmaps.clear()
	_clv_fallback.clear()
	_clv_fallback_mode = -1
	_frame_clipmap = null
	_native_prepared_views.clear()
	_native_baked_sh_prepared_views.clear()
	_native_baked_sh_attempted_views.clear()
	_native_baked_sh_publications.clear()
	_frame_native_baked_sh_consumed = false
	_frame_native_baked_sh_publication.clear()
	_frame_native_clv_fallback_only = false
	for view in 2:
		_native_owner_ubos[view] = RID()
		_native_owner_bytes[view] = PackedByteArray()
		_magicdawn_native_owner_ubos[view] = RID()
		_magicdawn_native_owner_bytes[view] = PackedByteArray()
	_native_gi_parameters_ubo = RID()
	_native_gi_parameters_bytes = PackedByteArray()
	_relight_shader = RID()
	_relight_pipeline = RID()
	_magicdawn_clv_debug_shader = RID()
	_magicdawn_clv_debug_pipeline = RID()
	_magicdawn_clv_debug_nearest_sampler = RID()
	_magicdawn_clv_debug_linear_sampler = RID()
	_magicdawn_screen_resolve_shader = RID()
	_magicdawn_screen_resolve_pipeline = RID()
	_magicdawn_screen_partial_shader = RID()
	_magicdawn_screen_partial_pipeline = RID()
	_magicdawn_screen_classify_shader = RID()
	_magicdawn_screen_classify_pipeline = RID()
	_magicdawn_screen_classify_shader_resource = null
	_magicdawn_screen_resolve_nearest_sampler = RID()
	_magicdawn_screen_resolve_linear_sampler = RID()
	_magicdawn_screen_resolve_diagnostics_buffer = RID()
	_dynamic_volume_screen_resolve_shader = RID()
	_dynamic_volume_screen_resolve_pipeline = RID()
	_dynamic_volume_screen_nearest_sampler = RID()
	_dynamic_volume_screen_linear_sampler = RID()
	_dynamic_volume_screen_diagnostics_buffer = RID()
	_dynamic_volume_screen_frame_ubo = RID()
	_dynamic_volume_screen_frame_bytes = PackedByteArray()
	_dynamic_volume_screen_dispatch_serial = 0
	_dynamic_volume_screen_resolve_shader_resource = null
	_magicdawn_screen_diagnostic_armed = false
	_magicdawn_screen_diagnostic_pending = false
	_magicdawn_clv_debug_status = "detached"
	_frame_magicdawn_clv_renderer_active = false
	_page_params_ubo = RID()
	_last_page_params_bytes = PackedByteArray()
	_last_frame_ubo_bytes = PackedByteArray()
	_probe_cluster_fallback = RID()
	_probe_neighbor_mask_disabled = RID()
	_pending_page_params_ubo = RID()
	_pending_page_shader = RID()
	_pending_page_pipeline = RID()
	_prt_guide_shader = RID()
	_prt_guide_pipeline = RID()
	_prt_stage_pipelines.clear()
	_prt_stage_pipeline_specialization_values.clear()
	_prt_stage_pipeline_signature = ""
	_prt_source_pending_texture = RID()
	_prt_source_pending_size = Vector2i.ZERO
	_prt_compact_shader_resource = null
	_prt_compact_shader_spirv = null
	_prt_compact_shader = RID()
	_prt_compact_pipelines.clear()
	_prt_compact_pipeline_specialization_values.clear()
	_prt_compact_pipeline_signature = ""
	_prt_compact_finalize_shader_resource = null
	_prt_compact_finalize_shader_spirv = null
	_prt_compact_finalize_shader = RID()
	_prt_compact_finalize_pipeline = RID()
	_prt_compact_finalize_pipeline_signature = ""
	_prt_compact_queue_buffer = RID()
	_prt_compact_queue_control_buffer = RID()
	_prt_compact_indirect_args_buffer = RID()
	_prt_compact_finalize_uniform_set = RID()
	_prt_compact_finalize_uniform_set_signature = ""
	_prt_compact_queue_capacity_pixels = 0
	_prt_compact_last_capability = {"status": "not_checked"}
	_prt_compact_queue_metadata = {"enabled": false, "eligible": false, "active": false,
		"fallback_reason": "detached", "active_stages": [], "dispatch_frame": -1,
		"queue_count": {"status": "not_read_back"},
		"overflow": {"status": "not_read_back"},
		"indirect_dimensions": {"status": "not_read_back"}}
	_last_prt_two_stage_active = false
	_last_prt_two_stage_stage_values = PackedInt32Array([MAGIC_GI_PRT_STAGE_LEGACY])
	_last_prt_three_stage_active = false
	_last_prt_three_stage_stage_values = PackedInt32Array([MAGIC_GI_PRT_STAGE_LEGACY])
	_prt_resolve_shader = RID()
	_prt_resolve_pipeline = RID()
	_prt_linear_sampler = RID()
	_exact_point_debug_buffer = RID()
	_clv_stats_buffer = RID()
	_clv_stats_buffer_bytes = 0
	_clv_stats_capture_armed = false
	_clv_stats_capture_active = false
	_magicdawn_stats_buffer = RID()
	_magicdawn_stats_capture_armed = false
	_magicdawn_stats_capture_active = false
	_magicdawn_stats_capture_frame = -1
	_magicdawn_stats_last_values = PackedInt32Array()
	_prt_raw_views.clear()
	_frame_prt_scale = 1
	_zero_sky_diffuse = RID()
	_diffuse_ao_white = RID()
	_frame_diffuse_ao_texture = RID()
	_frame_input_bindings.clear()
	_frame_view_matrices.clear()
	_diffuse_ao_view_cache.clear()
	_probe_cluster_payload_cache.clear()
	_probe_cluster_payload_cache_bytes = 0
	_probe_cluster_debug_bound_keys.clear()
	_probe_cluster_debug_frame = -1
	var rids := super._take_owned_rids()
	rids.append_array(owned_rids)
	return rids
