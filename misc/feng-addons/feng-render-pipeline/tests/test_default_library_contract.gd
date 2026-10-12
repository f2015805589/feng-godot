extends SceneTree
## CPU-only checks for default library ordering, RTGI compatibility, and callback aliases.

const PassBase = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const PassTexture = preload("res://addons/feng-render-pipeline/passes/pass_texture.gd")
const RendererScript = preload("res://addons/feng-render-pipeline/renderer.gd")
const LibraryManager = preload("res://addons/feng-render-pipeline/pipeline/library_manager.gd")
const PipelineValidator = preload("res://addons/feng-render-pipeline/pipeline/pipeline_validator.gd")
const FengReflectionSettingsScript = preload("res://addons/feng-render-pipeline/reflection_settings.gd")
const RTGI_SCRIPT_PATH := "res://addons/feng-raytracing/passes/feng_rt_gi_pass.gd"
const FENG_PROBE_PASS_PATH := "res://addons/feng-reflect-probe/passes/feng_reflect_probe_pass.gd"

var failures := 0
var checks := 0

func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func _pass_index(passes: Array, stable_id: StringName) -> int:
	for index in passes.size():
		if passes[index] != null and passes[index].stable_id == stable_id:
			return index
	return -1

func _rt_provider_count(passes: Array) -> int:
	var count := 0
	for pass_entry in passes:
		if pass_entry != null and pass_entry.has_method("get_indirect_gi_kind") \
				and StringName(pass_entry.call("get_indirect_gi_kind")) == &"rt_gi":
			count += 1
	return count

func _reflection_source_count(passes: Array, source_kind: StringName) -> int:
	var count := 0
	for pass_entry in passes:
		var source_pass = pass_entry.get_parameter_source() if pass_entry != null \
				and pass_entry.has_method("get_parameter_source") else pass_entry
		if source_pass != null and source_pass.has_method("get_reflection_source_kind") \
				and StringName(source_pass.call("get_reflection_source_kind")) == source_kind:
			count += 1
	return count

func _empty_pass_textures() -> Array[PassTexture]:
	return []

func run() -> void:
	var rtgi_script: Script
	if FileAccess.file_exists(RTGI_SCRIPT_PATH):
		rtgi_script = load(RTGI_SCRIPT_PATH) as Script
	var renderer = RendererScript.new()
	var passes: Array = renderer.passes.duplicate()
	var lighting := _pass_index(passes, &"native:3")
	var magic := _pass_index(passes, &"library:magic_gi")
	var rtgi := _pass_index(passes, &"library:rt_gi")
	var ssr := _pass_index(passes, &"library:ssr")
	var sky := _pass_index(passes, &"native:4")
	var expected_pass_count := 19 if rtgi < 0 else 20
	require(passes.size() == expected_pass_count,
			"fresh FRP Passes must contain %d authored entries for the installed addon set" % expected_pass_count)
	require(renderer._pipeline_schema_version == renderer.PIPELINE_SCHEMA_VERSION,
			"a freshly initialized default renderer must carry the current pipeline schema")
	require(lighting >= 0 and magic > lighting and ssr > magic and sky > ssr,
			"fresh FRP schedule must seed Lighting, MagicGI, SSR and Sky in dependency order")
	require(_pass_index(passes, &"library:reflection_resolve") < 0,
			"internal Reflection Resolve must not appear in the authored Passes array")
	require(LibraryManager.manifest_for_path("reflection-resolve/reflection_resolve.tres") == null,
			"the compatibility Resolve template must not be registered in the Pass Library")
	if rtgi >= 0:
		require(rtgi_script != null,
				"the optional RTGI pass must load when the ray-tracing addon is installed")
		require(rtgi == magic + 1 and ssr > rtgi,
				"stock RTGI must immediately follow MagicGI and precede SSR")
		var default_rtgi = passes[rtgi]
		require(not default_rtgi.enabled, "default RTGI must start disabled")
		require(default_rtgi.inputs.size() == 6, "default RTGI must carry all six shader inputs")
		var expected_sources := [PassTexture.Source.DEPTH, PassTexture.Source.NORMAL_ROUGHNESS,
				PassTexture.Source.ALBEDO, PassTexture.Source.ORM, PassTexture.Source.EMISSION,
				PassTexture.Source.INDIRECT_SPECULAR]
		for index in expected_sources.size():
			var input = default_rtgi.inputs[index]
			require(input.binding == index + 1 and input.source == expected_sources[index],
					"RTGI input bindings 1-6 must match its depth/GBuffer/specular ABI")
			require(input.binding_type == PassTexture.BindingType.SAMPLED_TEXTURE,
					"RTGI inputs must be sampled textures")
	else:
		require(not FileAccess.file_exists(RTGI_SCRIPT_PATH),
				"RTGI may be absent from a fresh pipeline only when its optional addon is absent")
	require(ssr >= 0 and passes[ssr].enabled, "default SSR must be seeded and enabled")
	if rtgi < 0:
		require(ssr == magic + 1, "SSR must immediately follow MagicGI when RTGI is not installed")
	var schedule_callable := Callable(renderer, "_is_entry_enabled")
	var runtime_entries: Array = renderer._runtime_entries(schedule_callable)
	var hidden_resolve_index := -1
	var hidden_resolve
	var probe_provider_index := -1
	for index in runtime_entries.size():
		var entry = runtime_entries[index]
		var source_pass = entry.get_parameter_source() if entry.has_method("get_parameter_source") else entry
		if source_pass != null and source_pass.has_method("get_reflection_source_kind"):
			var kind := StringName(source_pass.call("get_reflection_source_kind"))
			if kind == &"resolve":
				hidden_resolve_index = index
				hidden_resolve = source_pass
			elif kind == &"feng_probe":
				probe_provider_index = index
	var runtime_sky := _pass_index(runtime_entries, &"native:4")
	require(hidden_resolve_index > ssr and hidden_resolve_index < runtime_sky,
			"runtime must insert the internal resolver after candidates and before native Sky")
	if FileAccess.file_exists(FENG_PROBE_PASS_PATH):
		var probe_script := load(FENG_PROBE_PASS_PATH) as Script
		require(probe_script != null and probe_script.can_instantiate(),
				"installed FengReflectProbe pass must parse and instantiate")
		require(probe_provider_index > ssr and probe_provider_index < hidden_resolve_index,
				"installed FengReflectProbe addon must inject its hidden provider between SSR and Resolve")
		if probe_provider_index >= 0:
			var probe_pass = runtime_entries[probe_provider_index]
			require(StringName(probe_pass.call("get_reflection_source_kind")) == &"feng_probe",
					"the hidden probe provider must publish the feng_probe source kind")
			require(probe_pass.inputs.size() == 5 and probe_pass.outputs.size() == 1,
					"the hidden probe provider must declare its five GBuffer inputs and one candidate output")
			if probe_pass.outputs.size() == 1:
				var output = probe_pass.outputs[0]
				var required_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
						| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
						| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
				require(output.name == &"feng_probe_reflection"
						and output.data_format == RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
						and output.scale == Vector2.ONE
						and (output.usage & required_usage) == required_usage,
					"the probe candidate output must be full-resolution premultiplied RGBA16F")
	var default_resolve_priority: Array[int] = FengReflectionSettingsScript.priority_for_render_target(
			RID(), hidden_resolve.get_instance_id() if hidden_resolve != null else 0)
	require(hidden_resolve != null and default_resolve_priority == [0, 1, 2, 3],
			"internal resolve must use the default GI/SSR/FengReflectProbe/Sky priority")
	renderer.set_reflection_capture_mode(true)
	var capture_entries: Array = renderer._runtime_entries(schedule_callable)
	require(_reflection_source_count(capture_entries, &"resolve") == 0
			and _reflection_source_count(capture_entries, &"feng_probe") == 0,
			"reflection capture mode must not insert hidden or authored recursive reflection providers")
	renderer.set_reflection_capture_mode(false)
	var restored_runtime: Array = renderer._runtime_entries(schedule_callable)
	require(_reflection_source_count(restored_runtime, &"resolve") == 1,
			"disabling capture mode must restore the ordinary internal Resolve schedule")
	# Scheduling preserves authored/null slots and uses the same per-renderer hidden
	# resources across capture transitions and repeated plan compilation.
	require(restored_runtime.has(hidden_resolve), "capture exit must reuse the hidden resolver")
	var reflected: Array[PassBase] = [null, hidden_resolve, passes[sky]]
	var original_reflected := reflected.duplicate()
	var policy = load("res://addons/feng-render-pipeline/pipeline/reflection_plan.gd").new()
	var always_enabled := func(_entry): return true
	var fallback_priority: Array[int] = []
	var custom_runtime: Array = policy.build(reflected, always_enabled, fallback_priority, false)
	require(reflected == original_reflected and custom_runtime[0] == null,
			"reflection planning must preserve authored entries and empty slots")
	require(_reflection_source_count(custom_runtime, &"resolve") == 1,
			"an authored resolver must suppress the hidden resolver")
	if FileAccess.file_exists(FENG_PROBE_PASS_PATH):
		require(custom_runtime[1].get_reflection_source_kind() == &"feng_probe"
				and custom_runtime[2] == hidden_resolve, "hidden probe must precede an authored resolver")
	require(policy.build(reflected, always_enabled, fallback_priority, true) == [null, passes[sky]],
			"capture filtering must preserve unrelated authored slots")
	var without_sky: Array[PassBase] = [null]
	var first_plan: Array = policy.build(without_sky, always_enabled, fallback_priority, false)
	require(first_plan[-1].get_reflection_source_kind() == &"resolve"
			and policy.build(without_sky, always_enabled, fallback_priority, false) == first_plan,
			"without Sky the hidden resolver belongs last and repeated builds reuse resources")
	var wrapped := FengBuiltinPass.new()
	wrapped.implementation = hidden_resolve
	var wrapped_entries: Array[PassBase] = [wrapped]
	require(_reflection_source_count(policy.build(wrapped_entries, always_enabled, fallback_priority, false), &"resolve") == 1
			and policy.build(wrapped_entries, always_enabled, fallback_priority, true).is_empty(),
			"reflection roles must follow a Builtin implementation, including capture filtering")
	var disabled := func(entry): return entry != wrapped
	var disabled_plan: Array = policy.build(wrapped_entries, disabled, fallback_priority, false)
	require(disabled_plan.has(wrapped) and disabled_plan[-1] == first_plan[-1],
			"disabled authored resolver retains its slot while the hidden resolver supplies work")
	var valid_warnings: PackedStringArray = PipelineValidator.validate_schedule(
			passes, renderer._provided_native_ids(), renderer._declared_provided_ids(), schedule_callable)
	var has_reflection_warning := false
	for warning in valid_warnings:
		if warning.contains("Reflection Resolve") or warning.contains("reflection candidate"):
			has_reflection_warning = true
	require(not has_reflection_warning, "default reflection-provider schedule must validate cleanly")
	var wrong_order: Array = passes.duplicate()
	var moved_ssr = wrong_order.pop_at(ssr)
	wrong_order.insert(wrong_order.size(), moved_ssr)
	var wrong_order_warnings: PackedStringArray = PipelineValidator.validate_schedule(
			wrong_order, renderer._provided_native_ids(), renderer._declared_provided_ids(), schedule_callable)
	var wrong_order_detected := false
	for warning in wrong_order_warnings:
		if warning.contains("candidate providers must run before native Sky"):
			wrong_order_detected = true
	require(wrong_order_detected, "reflection providers must be ordered before native Sky")

	var settings_script := load("res://addons/feng-render-pipeline/reflection_settings.gd") as Script
	var settings = settings_script.new() if settings_script != null else null
	require(settings != null and settings.source_priority == [0, 1, 2, 3],
			"FengReflectionSettings must default to GI, SSR, FengReflectProbe, Sky")
	if settings != null:
		var reverse_priority: Array[int] = [3, 2, 1, 0]
		settings.source_priority = reverse_priority
		require(settings.get_source_priority_snapshot() == reverse_priority,
				"settings must return an immutable copy of a valid priority order")
		FengReflectionSettingsScript.publish_legacy_fallback_priority(17, reverse_priority)
		var invalid_target_priority: Array[int] = FengReflectionSettingsScript.priority_for_render_target(RID(), 17)
		require(invalid_target_priority == reverse_priority,
				"unbound settings lookup must use the resolver-keyed main-thread fallback")
		var independent_priority: Array[int] = FengReflectionSettingsScript.priority_for_render_target(RID(), 18)
		require(independent_priority == [0, 1, 2, 3],
				"legacy priority snapshots must not leak between renderer resolvers")
		FengReflectionSettingsScript.copy_legacy_fallback_priority(17, 19)
		var view_priority: Array[int] = FengReflectionSettingsScript.priority_for_render_target(RID(), 19)
		require(view_priority == reverse_priority,
				"isolated view execution must inherit its source Resolve fallback snapshot")
		for invalid in [[], [0, 1, 1, 3], [-1, 1, 2, 3], [0, 1, 2, 4]]:
			FengReflectionSettingsScript.publish_legacy_fallback_priority(20, invalid)
			require(not FengReflectionSettingsScript.is_valid_priority(invalid)
					and FengReflectionSettingsScript.priority_for_render_target(RID(), 20) == [0, 1, 2, 3],
					"malformed priorities must be normalized before publication")
		require(settings.has_method("_get_configuration_warnings"),
				"settings warnings must use Node's configuration-warning hook")
	settings.free()

	var legacy_renderer = RendererScript.new()
	var legacy_passes: Array = legacy_renderer.passes.duplicate()
	var legacy_rtgi_index := _pass_index(legacy_passes, &"library:rt_gi")
	var legacy_magic_index := _pass_index(legacy_passes, &"library:magic_gi")
	var legacy_ssr_index := _pass_index(legacy_passes, &"library:ssr")
	var legacy_rtgi = legacy_passes[legacy_rtgi_index] if legacy_rtgi_index >= 0 else null
	if legacy_rtgi_index >= 0:
		legacy_passes.remove_at(legacy_rtgi_index)
		legacy_passes.insert(legacy_magic_index + 2, legacy_rtgi)
	var legacy_resolve = load("res://addons/feng-render-pipeline/library/reflection-resolve/reflection_resolve.tres")
	if legacy_resolve != null:
		legacy_resolve = legacy_resolve.duplicate(true)
		legacy_resolve.stable_id = &"library:reflection_resolve"
		var legacy_source_priority: Array[int] = [3, 2, 1, 0]
		legacy_resolve.source_priority = legacy_source_priority
		legacy_passes.append(legacy_resolve)
	var typed_legacy_passes: Array[PassBase] = []
	for entry in legacy_passes:
		typed_legacy_passes.append(entry)
	legacy_renderer.passes = typed_legacy_passes
	legacy_renderer._pipeline_schema_version = 10
	legacy_renderer._synced_library.append("reflection-resolve/reflection_resolve.tres")
	legacy_renderer._synced_library_ids.append("library:reflection_resolve")
	legacy_renderer._ensure_pipeline_initialized(false)
	var migrated_passes: Array = legacy_renderer.passes.duplicate()
	require(_pass_index(migrated_passes, &"library:reflection_resolve") < 0,
			"schema 11 must migrate the exact stock Resolve out of authored Passes")
	require(legacy_renderer._legacy_reflection_source_priority == [3, 2, 1, 0],
			"stock Resolve migration must preserve its configured source priority")
	if legacy_rtgi != null:
		var migrated_magic_index := _pass_index(migrated_passes, &"library:magic_gi")
		require(migrated_passes[migrated_magic_index + 1] == legacy_rtgi,
				"schema 11 must move stock RTGI directly after MagicGI without replacing the resource")
	var migrated_runtime: Array = legacy_renderer._runtime_entries(Callable(legacy_renderer, "_is_entry_enabled"))
	var migrated_resolve
	for entry in migrated_runtime:
		if entry.has_method("get_reflection_source_kind") and entry.get_reflection_source_kind() == &"resolve":
			migrated_resolve = entry
	var migrated_priority: Array[int] = FengReflectionSettingsScript.priority_for_render_target(
			RID(), migrated_resolve.get_instance_id() if migrated_resolve != null else 0)
	require(migrated_resolve != null and migrated_priority == [3, 2, 1, 0],
			"internal resolver must use the priority recovered from the legacy stock resource")
	require(not legacy_renderer._synced_library_ids.has("library:reflection_resolve"),
			"migrated stock Resolve must not remain marked as a library pass")
	legacy_renderer = null
	if rtgi >= 0:
		require(not bool(passes[rtgi].get("_runtime_start_queued")),
				"constructing a disabled RTGI default must not queue Runtime startup")
	require(LibraryManager.load_template({
			"path": "rt-gi/rt_gi.tres",
			"requires_script": "res://addons/feng-raytracing/missing_rtgi.gd"}) == null,
			"library loading must skip optional templates before parsing missing addon scripts")
	var rtgi_instance: PassBase
	if rtgi_script != null:
		rtgi_instance = rtgi_script.new() as PassBase
		require(not bool(rtgi_instance.get("_runtime_start_queued")),
				"constructing an RTGI pass must not queue scene discovery")
		var broken = rtgi_instance.duplicate(true)
		broken.inputs = _empty_pass_textures()
		broken.access_resolved_color = false
		broken.access_resolved_depth = false
		broken.needs_normal_roughness = false
		require(broken.ensure_frp_contract(), "RTGI must repair an old serialized input/access contract")
		require(broken.inputs.size() == 6 and broken.needs_normal_roughness,
				"RTGI contract repair must restore its six inputs and GBuffer requirements")

	var callback_pass = PassBase.new()
	var capture_context = ClassDB.instantiate("FRPPassContext")
	require(capture_context != null, "FRPPassContext must remain a constructible native context for capture passes")
	if capture_context != null:
		capture_context.set_reflection_capture_context(true, 42, 2, 6, Vector3(1.0, 2.0, 3.0), 2.0)
		require(capture_context.is_reflection_capture() and capture_context.is_cloud_capture(),
				"generic reflection capture state must preserve the cloud compatibility getter")
		require(capture_context.get_cloud_capture_batch_id() == 42
				and capture_context.get_cloud_capture_face_index() == 2
				and capture_context.get_cloud_capture_face_count() == 6
				and capture_context.get_cloud_capture_origin_world_m() == Vector3(1.0, 2.0, 3.0)
				and is_equal_approx(capture_context.get_cloud_capture_exposure_normalization(), 2.0),
				"reflection capture context must publish batch, face, origin, and exposure metadata")
		capture_context.set_reflection_capture_context(true, 42, 6, 6, Vector3(), 2.0)
		require(not capture_context.is_reflection_capture(),
				"invalid reflection capture face indices must clear the context to its neutral state")
		capture_context = null

	callback_pass.stage = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_GBUFFER
	require(callback_pass.effect_callback_type == CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_GBUFFER,
			"legacy stage setter must update native callback type")
	callback_pass.effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_LIGHTING
	require(callback_pass.stage == CompositorEffect.EFFECT_CALLBACK_TYPE_POST_LIGHTING,
			"stage getter must reflect the native callback type")
	var standalone_compositor := Compositor.new()
	var standalone_effects: Array[CompositorEffect] = [callback_pass]
	standalone_compositor.compositor_effects = standalone_effects
	require(standalone_compositor.compositor_effects.size() == 1
			and standalone_compositor.compositor_effects[0].effect_callback_type
				== CompositorEffect.EFFECT_CALLBACK_TYPE_POST_LIGHTING,
				"standalone Compositor must retain native callback scheduling for FengPass resources")
	var stage_is_storage := false
	var stage_is_hidden := false
	for property in callback_pass.get_property_list():
		if property.name == "stage":
			var usage := int(property.usage)
			stage_is_storage = (usage & PROPERTY_USAGE_STORAGE) != 0
			stage_is_hidden = (usage & PROPERTY_USAGE_EDITOR) == 0
	require(stage_is_storage and stage_is_hidden, "stage must remain serialized without showing as a duplicate Inspector field")
	var stage_path := "user://frp_stage_alias_roundtrip.tres"
	var save_error := ResourceSaver.save(callback_pass, stage_path)
	require(save_error == OK, "callback alias fixture must save for serialization roundtrip")
	if save_error == OK:
		var restored = ResourceLoader.load(stage_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		require(restored != null and restored.stage == CompositorEffect.EFFECT_CALLBACK_TYPE_POST_LIGHTING \
				and restored.effect_callback_type == CompositorEffect.EFFECT_CALLBACK_TYPE_POST_LIGHTING,
				"serialized legacy stage must roundtrip to the native callback value")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(stage_path))

	if rtgi >= 0 and rtgi_script != null:
		var authored = PassBase.new()
		authored.stable_id = &"custom:keep-order"
		var group: Array = [passes[lighting], authored, passes[ssr], passes[sky]]
		group.insert(LibraryManager.calculate_insert_index(group, &"library:magic_gi"), passes[magic])
		group.insert(LibraryManager.calculate_insert_index(group, &"library:rt_gi"), passes[rtgi])
		require(group[1] == authored and _pass_index(group, &"library:magic_gi")
				< _pass_index(group, &"library:rt_gi") and _pass_index(group, &"library:rt_gi")
				== _pass_index(group, &"library:magic_gi") + 1
				and _pass_index(group, &"library:ssr") > _pass_index(group, &"library:rt_gi"),
				"adding missing anchored defaults must preserve authored entries and place RTGI after MagicGI")

	var synced: Array = renderer._synced_library.duplicate()
	var synced_ids: Array = renderer._synced_library_ids.duplicate()
	var deleted: Array = renderer._deleted_library.duplicate()
	var deleted_ids: Array = renderer._deleted_library_ids.duplicate()
	if rtgi >= 0 and rtgi_script != null:
		var old_stock = rtgi_script.new()
		old_stock.stable_id = &"custom:volume-linked-rtgi"
		old_stock.resource_name = "Volume Linked RTGI"
		old_stock.enabled = true
		old_stock.strength = 0.42
		old_stock.inputs = _empty_pass_textures()
		old_stock.access_resolved_color = false
		old_stock.access_resolved_depth = false
		old_stock.needs_normal_roughness = false
		passes[rtgi] = old_stock
		LibraryManager.sync(passes, synced, synced_ids, deleted, deleted_ids)
		var observed_passes: Array[PassBase] = []
		for pass_entry in passes:
			observed_passes.append(pass_entry)
		renderer.passes = observed_passes
		require(_rt_provider_count(passes) == 1 and old_stock.stable_id == &"custom:volume-linked-rtgi",
				"sync must preserve a legacy RTGI identity and avoid adding a duplicate")
		require(old_stock.enabled and is_equal_approx(old_stock.strength, 0.42),
				"sync must preserve legacy RTGI enable and strength settings")
		require(old_stock.inputs.size() == 6 and old_stock.access_resolved_color
				and old_stock.access_resolved_depth and old_stock.needs_normal_roughness,
				"renderer pass observation must repair a serialized RTGI resource with an incomplete contract")

		var provider_script = load("res://addons/feng-render-pipeline/tests/indirect_gi_provider_fixture.gd")
		var custom_provider = provider_script.new()
		custom_provider.kind = &"rt_gi"
		custom_provider.key = "custom:rtgi_provider"
		custom_provider.stable_id = &"custom:rtgi_provider"
		var subclass_passes: Array = renderer.passes.duplicate()
		subclass_passes[rtgi] = custom_provider
		var subclass_synced: Array = renderer._synced_library.duplicate()
		var subclass_synced_ids: Array = renderer._synced_library_ids.duplicate()
		var subclass_deleted: Array = renderer._deleted_library.duplicate()
		var subclass_deleted_ids: Array = renderer._deleted_library_ids.duplicate()
		LibraryManager.sync(subclass_passes, subclass_synced, subclass_synced_ids,
				subclass_deleted, subclass_deleted_ids)
		require(_rt_provider_count(subclass_passes) == 1
				and custom_provider.stable_id == &"custom:rtgi_provider",
				"an existing RTGI subclass/provider must suppress the default without renaming its key")

		passes.erase(old_stock)
		deleted_ids.append("library:rt_gi")
		LibraryManager.sync(passes, synced, synced_ids, deleted, deleted_ids)
		require(_rt_provider_count(passes) == 0, "a tombstoned default RTGI must not be re-seeded")
		custom_provider = null

	callback_pass = null
	rtgi_instance = null
	passes.clear()
	renderer = null
	call_deferred("_finish")

func _finish() -> void:
	print("DEFAULT_LIBRARY_CONTRACT checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
