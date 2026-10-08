@tool
class_name FengRenderer
extends Resource
## Declarative FRP pipeline containing native operations and custom effects.
##
## `passes` is the authored execution list. FengBuiltinPass entries are
## native renderer operations and FengPass entries are compositor effects.
## The list order is the schedule order; a custom pass_entry's `stage` remains its
## callback selector and is only an advisory legacy placement hint.

const PassBase = preload("passes/pass_base.gd")
const BuiltinPass = preload("passes/builtin_pass.gd")
const TextureManager = preload("passes/texture_manager.gd")
const PipelineValidator = preload("pipeline/pipeline_validator.gd")
const PipelineMigrator = preload("pipeline/pipeline_migrator.gd")
const LibraryManager = preload("pipeline/library_manager.gd")
const NativeSpec = preload("pipeline/native_spec.gd")
const ParameterResolver = preload("pipeline/parameter_resolver.gd")
const ExecutionPlan = preload("pipeline/execution_plan.gd")
const CompositorBinding = preload("pipeline/compositor_binding.gd")
const ViewExecutionPolicy = preload("pipeline/view_execution_policy.gd")

## Schema 6 moved the default pass set into the addon: every native entry carries the
## pass script that implements it (FengBuiltinPass.implementation), so the pipeline
## is plugin-side code and the engine's own passes are the no-pipeline fallback.
## Schema 7 moved Eye Adaptation before post-tonemap library effects. Schema 8 adds
## native Bloom after Eye Adaptation and before Color Grade. Schema 9 originally shipped
## Sky/Cloud/Trace/Fog in the wrong relative order; schema 10 repairs only that exact
## released stock sequence and keeps later authored schedules unchanged.
const PIPELINE_SCHEMA_VERSION := 10

## The addon's pass script for each engine pass. A subclass of FengNativePass runs
## the pass through the Core primitives by default and can be replaced per entry
## (or overridden by the project) without an engine change. The keys are the engine's
## stable pass ids; schedule order comes from NativeSpec.seed_order().
const NATIVE_PASS_SCRIPTS := {
	NativeSpec.PASS_SHADOW_PRECOMPUTE: "native/shadow_precompute_pass.gd",
	NativeSpec.PASS_VIRTUAL_TEXTURE: "native/vt_pass.gd",
	NativeSpec.PASS_GBUFFER: "native/gbuffer_pass.gd",
	NativeSpec.PASS_LIGHTING: "native/lighting_pass.gd",
	NativeSpec.PASS_SKY: "native/sky_pass.gd",
	NativeSpec.PASS_TRANSPARENT: "native/transparent_pass.gd",
	NativeSpec.PASS_TEMPORAL_AA: "native/temporal_aa_pass.gd",
	NativeSpec.PASS_POST_PROCESS: "native/post_process_pass.gd",
	NativeSpec.PASS_BLOOM: "native/bloom_pass.gd",
}

const NativePass = preload("passes/native/native_pass.gd")

## Library entries a fresh pipeline seeds at the anchors in their manifest metadata:
## Shadow Precompute, VT, GBuffer, Lighting, Magic GI, Sky, Height Fog, Transparent,
## Temporal AA, Eye Adaptation, Bloom, Color Grade, Post Process, Debug Buffers.
const DEFAULT_LIBRARY_ENTRIES := LibraryManager.DEFAULT_LIBRARY_ENTRIES

## The library entries a fresh pipeline seeds.
const DEFAULT_LIBRARY_SEEDED := LibraryManager.DEFAULT_LIBRARY_SEEDED

## Storage properties the schedule owns besides `passes`. They are named next to the
## fields they describe, and the editor snapshots exactly these for undo.
const PERSISTED_STATE_FIELDS := [
	"_synced_library",
	"_synced_library_ids",
	"_deleted_library",
	"_deleted_library_ids",
	"_pipeline_schema_version",
]

var _passes: Array[PassBase] = []
@export var passes: Array[PassBase] = []:
	get:
		# Lazy initialization avoids mutating a resource while ResourceLoader is
		# still restoring serialized properties. Inspector access happens after
		# restoration, so legacy resources are migrated before they are shown.
		_ensure_pipeline_initialized(false)
		return _passes
	set(value):
		_set_passes(value, true)

## The manifest of library entries this pipeline carries, by template path, and the same
## set by stable id. A path is what an older resource recorded, the id is what survives a
## template moving inside the library, so both are kept.
@export_storage var _synced_library: Array[String] = []
@export_storage var _synced_library_ids: Array[String] = []
## Explicit tombstones prevent a removed library entry from being re-added.
@export_storage var _deleted_library: Array[String] = []
@export_storage var _deleted_library_ids: Array[String] = []
## A zero version lets migration run after serialized properties are restored.
@export_storage var _pipeline_schema_version: int = 0

var _manager := TextureManager.new()
var _observed_passes: Array[PassBase] = []
var _last_valid_schedule := PackedInt32Array()
var _last_validation_warnings := PackedStringArray()
## Pass parameters a volume resolved for the camera using this renderer, plus the pass
## states it switches on or off. Runtime overrides on top of what the pass scripts and
## the entries author.
var _volume_parameters := {}
var _volume_pass_states := {}
var _normalizing := false
var _seed_pending := true
var _volume_context_cache := {}
var _parameter_revision := 0
## Only a successfully bound schedule may be reused for Volume-only updates.
## Authored edits invalidate it through the parameter revision; switches force a
## full validation because they can change texture availability and native ownership.
var _volume_binding: Dictionary = {}
var _view_plans: Array[Dictionary] = []

func _init() -> void:
	changed.connect(_invalidate_volume_context)
	# Fresh custom schedules are current too, even when assigned before the first
	# default-list read. Resource loading restores its serialized version later.
	_pipeline_schema_version = PIPELINE_SCHEMA_VERSION
	# Seed on first use. Loading or duplicating a Renderer restores its own pass
	# list: allocating throwaway default passes here needlessly loads shader
	# templates and creates effect RIDs on every camera's first Volume entry.

func _seed_default_passes() -> void:
	if not _passes.is_empty():
		return
	_passes = _default_seed_list()
	# A freshly seeded pipeline is current by definition. A resource loaded from disk
	# restores its own (possibly older) version afterwards, and the setter resets the
	# version to zero when the loaded list carries no native entries, so migration
	# still runs for resources that need it.
	_pipeline_schema_version = PIPELINE_SCHEMA_VERSION
	_connect_passes()

## The default pass set: every native entry enabled in seed order, with library
## passes inserted at their declared anchors. Only Debug Buffers starts disabled.
func _default_seed_list() -> Array[PassBase]:
	var seeded: Array[PassBase] = []
	for native_id in NativeSpec.seed_order():
		var pass_entry := _make_native_pass(native_id)
		seeded.append(pass_entry)
	LibraryManager.append_defaults(seeded)
	return seeded

## An entry for one engine pass: its id, the stable identity the schedule persists, and
## the addon's script for it as the implementation.
func _make_native_pass(native_id: int) -> PassBase:
	var display_name := NativeSpec.pass_name(native_id)
	var pass_entry := BuiltinPass.new(native_id, display_name) as PassBase
	pass_entry.stable_id = "native:%d" % native_id
	pass_entry.resource_name = display_name
	pass_entry.implementation = _make_default_implementation(native_id)
	return pass_entry

## The addon's pass script for one engine pass, or a plain FengNativePass when a
## project's addon copy does not ship that script.
func _make_default_implementation(native_id: int) -> PassBase:
	var script_path: String = NATIVE_PASS_SCRIPTS.get(native_id, "")
	if script_path != "":
		var script = load(FengAddonLayout.passes_dir() + script_path)
		if script != null:
			var instance = script.new()
			if instance is PassBase:
				return instance
	var fallback := NativePass.new() as PassBase
	fallback.native_id = native_id
	fallback.resource_name = NativeSpec.pass_name(native_id)
	return fallback

func _set_passes(value: Array[PassBase], emit: bool) -> void:
	_seed_pending = false
	_disconnect_passes()
	_passes = value.duplicate()
	# The loader can read exported defaults before restoring the old pass
	# array. Discard constructor-seed migration state for a legacy array;
	# serialized manifest/schema properties are restored after this setter.
	# A list of custom passes that declare the mandatory entries is a valid
	# current-format schedule, not a legacy array.
	if not _has_native_schedule():
		_pipeline_schema_version = 0
		_synced_library_ids.clear()
		_deleted_library_ids.clear()
		_deleted_library.clear()
		_synced_library.clear()
	_connect_passes()
	if emit:
		emit_changed()
		notify_property_list_changed()

func _connect_passes() -> bool:
	_disconnect_passes()
	var changed := false
	for pass_entry in _passes:
		changed = _observe_pass(pass_entry) or changed
	return changed

## Watches one authored pass and everything it carries. A carried pass (an entry's
## implementation, a native pass's overlay) is a resource of its own, so the inspector
## edits it directly and Godot does not forward its `changed` to the resource holding
## it. Without observing them, editing an exposed parameter or switching the carried
## pass off would only reach the engine on the next unrelated change - and the entry's
## enabled state, which follows the chain, would look stale.
func _observe_pass(pass_entry: PassBase) -> bool:
	if pass_entry == null:
		return false
	# Repair persisted shader bindings on the main thread before observing changes.
	var changed := pass_entry.ensure_frp_contract()
	if _observed_passes.has(pass_entry):
		return changed
	if pass_entry.stable_id == &"":
		# Persist an instance identity; a script path cannot distinguish two copies.
		pass_entry.stable_id = StringName("custom:" + ResourceUID.id_to_text(ResourceUID.create_id()))
	for observed in _observed_passes:
		if observed.stable_id == pass_entry.stable_id:
			# Duplicating a resource duplicates its stored ID too. A second resource
			# in this pipeline is a new instance; runtime pipeline copies retain IDs.
			pass_entry.stable_id = StringName("custom:" + ResourceUID.id_to_text(ResourceUID.create_id()))
			break
	_observed_passes.append(pass_entry)
	if not pass_entry.changed.is_connected(_on_pass_changed):
		pass_entry.changed.connect(_on_pass_changed)
	for carried in pass_entry.carried_passes():
		changed = _observe_pass(carried) or changed
	return changed

func _disconnect_passes() -> void:
	for pass_entry in _observed_passes:
		if pass_entry.changed.is_connected(_on_pass_changed):
			pass_entry.changed.disconnect(_on_pass_changed)
	_observed_passes.clear()

func _on_pass_changed() -> void:
	if _normalizing:
		return
	# The edited pass may have gained or lost a carried pass (an implementation or an
	# overlay was set or cleared), so what is observed is refreshed before the change is
	# forwarded: Resource.changed bridges nested pass edits to a Compositor, and native
	# enabled changes also need a new token list.
	_connect_passes()
	# Forward the nested edit so FengCompositor reapplies the schedule. Do not call
	# notify_property_list_changed(): the renderer's property schema did not change,
	# and rebuilding the Inspector collapses expanded pass resources (notably TAA)
	# whenever one of their fields such as enabled is edited.
	emit_changed()

func _ensure_pipeline_initialized(emit: bool) -> bool:
	if _normalizing:
		return false
	_normalizing = true
	if _seed_pending:
		_seed_pending = false
		_seed_default_passes()
	var changed := false
	var previous_version := _pipeline_schema_version
	if previous_version < 6 and not _has_native_schedule():
		changed = _migrate_legacy_passes() or changed
	elif previous_version < 6:
		changed = _migrate_native_pass_set() or changed
	else:
		changed = _normalize_native_entries() or changed
	if previous_version < 7:
		changed = _migrate_eye_adaptation_order() or changed
	if previous_version < 8:
		changed = _migrate_bloom_pass() or changed
	changed = _sync_library(false) or changed
	# Synchronize missing managed passes first so legacy schedules that lacked one of
	# the stock cloud entries can be recognized after the dependency-aware insertion.
	if previous_version < 10:
		changed = PipelineMigrator.migrate_cloud_fog_order(_passes) or changed
	if _pipeline_schema_version < PIPELINE_SCHEMA_VERSION:
		_pipeline_schema_version = PIPELINE_SCHEMA_VERSION
		changed = true
	changed = _connect_passes() or changed
	_normalizing = false
	if changed and emit:
		emit_changed()
	return changed

func _has_native_entries() -> bool:
	for pass_entry in _passes:
		if pass_entry is BuiltinPass:
			return true
	return false

## Native passes the authored list provides through pass scripts, i.e. the passes the
## engine has no token for. A pass that runs an engine entry's work itself declares
## it in `FengPass.provides_native_ids` (a native entry with an implementation
## provides its own id); the renderer then accepts a schedule where that entry is
## absent, and normalization does not re-add it.
func _provided_native_ids() -> Dictionary:
	return ExecutionPlan.provided_native_ids(_passes, _is_entry_enabled)

## Native ids custom passes declare they run. Declaring an id whose engine entry is
## also enabled would run the same work twice.
func _declared_provided_ids() -> Dictionary:
	return ExecutionPlan.declared_provided_ids(_passes, _is_entry_enabled)

## True when custom passes declare every mandatory entry, so the list is a complete
## schedule without any engine entry. Such a list must not be treated as a legacy
## array: migration would seed back the entries the author removed on purpose.
func _provides_mandatory_natives() -> bool:
	var provided := _provided_native_ids()
	for native_id in NativeSpec.mandatory_ids():
		if not provided.has(native_id):
			return false
	return true

func _has_native_schedule() -> bool:
	return _has_native_entries() or _provides_mandatory_natives()

## Native pass ids the schedule provides, as sent to the engine next to the tokens.
func get_provided_native_ids() -> PackedInt32Array:
	_ensure_pipeline_initialized(false)
	var provided := PackedInt32Array()
	for provided_id in _provided_native_ids():
		provided.append(provided_id)
	provided.sort()
	return provided

## Parameters authored per native pass, keyed by pass id: what a pass exposes (see
## FengPass.get_frp_parameters()) with the entry's dictionary overriding it. This is
## the authored state, without the runtime volume layer.
func get_authored_pass_parameters() -> Dictionary:
	_ensure_pipeline_initialized(false)
	return _with_eye_adaptation_state(ParameterResolver.authored(_passes), {})

func get_volume_modules() -> Array[FengPass]:
	_ensure_pipeline_initialized(false)
	return ParameterResolver.volume_modules(_passes)

func get_pass_parameters() -> Dictionary:
	_ensure_pipeline_initialized(false)
	return _with_eye_adaptation_state(ParameterResolver.resolve(_passes, _volume_parameters))

func _with_eye_adaptation_state(parameters: Dictionary, states: Variant = null) -> Dictionary:
	var key := "library:eye_adaptation"
	var eye_pass_enabled := false
	var effective_states: Dictionary = _volume_pass_states if states == null else states
	for pass_entry in _passes:
		if pass_entry != null and pass_entry.stable_id == &"library:eye_adaptation" and ExecutionPlan.is_entry_enabled(pass_entry, effective_states):
			eye_pass_enabled = true
			break
	var exposure: Dictionary = parameters.get(key, {}).duplicate()
	exposure["pre_exposure"] = bool(exposure.get("pre_exposure", false)) and eye_pass_enabled
	exposure["frp_eye_adaptation_enabled"] = eye_pass_enabled
	parameters[key] = exposure
	return parameters

## Revision-cached authored snapshot for per-camera evaluation. Resource changes
## invalidate it; callers receive isolated dictionaries. Stationary Volume frames
## check get_parameter_revision() and need not ask for another snapshot at all.
func get_volume_context() -> Dictionary:
	if _volume_context_cache.is_empty():
		_ensure_pipeline_initialized(false)
	return _initialized_volume_context().duplicate(true)

## The caller already normalized the pipeline. Keep one author snapshot for the
## entire application instead of re-entering library sync from each upload query.
func _initialized_volume_context() -> Dictionary:
	if _volume_context_cache.is_empty():
		_volume_context_cache = {
			"base": ParameterResolver.authored(_passes),
			"schema": ParameterResolver.volume_schema(_passes),
			"aliases": ParameterResolver.volume_aliases(_passes),
			"bindings": ParameterResolver.parameter_bindings(_passes),
		}
	return _volume_context_cache

func get_parameter_revision() -> int:
	return _parameter_revision

func _invalidate_volume_context() -> void:
	_volume_context_cache = {}
	_view_plans.clear()
	_parameter_revision += 1

## Pass parameters and pass states a volume resolved for this camera. The compositor
## pushes them before the frame, and they override the authored values (see FengVolume).
func set_volume_parameters(parameters: Dictionary, pass_states: Dictionary = {}) -> void:
	var next_parameters := parameters.duplicate(true)
	var next_pass_states := pass_states.duplicate(true)
	if next_parameters == _volume_parameters and next_pass_states == _volume_pass_states:
		return
	_volume_parameters = next_parameters
	_volume_pass_states = next_pass_states
	emit_changed()

func get_volume_parameters() -> Dictionary:
	return _volume_parameters.duplicate(true)

func get_volume_pass_states() -> Dictionary:
	return _volume_pass_states.duplicate(true)

## Whether a pass runs in this frame: its own enabled state (which includes the passes
## it carries, see FengPass.is_enabled), overridden by a volume. A custom pass follows
## the states of the passes it provides, so a volume can switch an effect on or off
## wherever the pass lives.
func _is_entry_enabled(pass_entry) -> bool:
	return ExecutionPlan.is_entry_enabled(pass_entry, _volume_pass_states)

## Resources authored before schema 5 carry the pre-collapse native ids. Every entry
## that still exists keeps its enabled state, entries that became internal
## operations of another entry are dropped (their behaviour survives inside the
## entry they map to), and custom passes keep their position relative to the entry
## they followed.
func _migrate_native_pass_set() -> bool:
	var had_temporal_aa := false
	for pass_entry in _passes:
		if pass_entry is BuiltinPass:
			var mapped_id: int = PipelineMigrator.LEGACY_NATIVE_ID_MAP.get((pass_entry as BuiltinPass).native_id, -1)
			if mapped_id == NativeSpec.PASS_TEMPORAL_AA:
				had_temporal_aa = true
				break
	var migrated := PipelineMigrator.migrate_native_pass_set(_passes, NativeSpec.seed_order(), _make_native_pass)
	if not had_temporal_aa:
		for pass_entry in migrated:
			if pass_entry is BuiltinPass and (pass_entry as BuiltinPass).native_id == NativeSpec.PASS_TEMPORAL_AA:
				pass_entry.enabled = false
				break
	_set_passes(migrated, false)
	return true

## Schema 6 placed Color Grade and optional Bloom before exposure. UE meters
## scene color after temporal AA and before Bloom, then grades during tonemapping.
## Move only the managed Eye Adaptation entry, preserving every other pass's order.
func _migrate_eye_adaptation_order() -> bool:
	var eye_index := -1
	var first_after_eye := _passes.size()
	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry == null:
			continue
		if pass_entry.stable_id == &"library:eye_adaptation":
			eye_index = i
		elif pass_entry.stable_id in [
			&"library:bloom_downsample", &"library:bloom_blur",
			&"library:bloom_composite", &"library:color_grade",
		]:
			first_after_eye = mini(first_after_eye, i)
		elif pass_entry is BuiltinPass and (pass_entry as BuiltinPass).native_id == NativeSpec.PASS_BLOOM:
			first_after_eye = mini(first_after_eye, i)
	var temporal_index := _find_native_index(NativeSpec.PASS_TEMPORAL_AA)
	var post_index := _find_native_index(NativeSpec.PASS_POST_PROCESS)
	if eye_index < 0 or first_after_eye >= eye_index or (temporal_index >= 0 and first_after_eye <= temporal_index) or (post_index >= 0 and first_after_eye >= post_index):
		return false
	var eye_pass := _passes[eye_index]
	_passes.remove_at(eye_index)
	_passes.insert(first_after_eye, eye_pass)
	return true

## Schema 8 adds the engine-owned Bloom preparation pass. Insert it after the existing
## Eye Adaptation entry (or before Color Grade/Post when no exposure pass exists) while
## leaving every authored entry in the same relative order.
func _migrate_bloom_pass() -> bool:
	if _find_native_index(NativeSpec.PASS_BLOOM) >= 0:
		return false

	var insert_index := -1
	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry != null and pass_entry.stable_id == &"library:eye_adaptation":
			insert_index = i + 1
			break
	if insert_index < 0:
		for i in _passes.size():
			var pass_entry := _passes[i]
			if pass_entry == null:
				continue
			if pass_entry.stable_id == &"library:color_grade":
				insert_index = i
				break
		if insert_index < 0:
			insert_index = _find_native_index(NativeSpec.PASS_POST_PROCESS)
	if insert_index < 0:
		insert_index = _seed_insert_index(NativeSpec.PASS_BLOOM)

	_passes.insert(insert_index, _make_native_pass(NativeSpec.PASS_BLOOM))
	return true

func _normalize_native_entries() -> bool:
	var changed := false
	for pass_entry in _passes:
		if not pass_entry is BuiltinPass:
			continue
		var native := pass_entry as BuiltinPass
		if NativeSpec.is_valid_id(native.native_id):
			if native.stable_id != "native:%d" % native.native_id:
				native.stable_id = "native:%d" % native.native_id
				changed = true
			var placeholder_name := "native id %d" % native.native_id
			var pass_name := NativeSpec.pass_name(native.native_id)
			if native.resource_name == "" or (native.resource_name == placeholder_name and pass_name != placeholder_name):
				native.resource_name = pass_name
				changed = true
			# An older engine may have serialized the fallback name into both resources
			# when it did not know this native id. Only restore the implementation label
			# when its concrete native pass still agrees with the wrapper's id; an author
			# may have replaced the implementation since the resource was saved.
			if native.implementation is NativePass:
				var implementation := native.implementation as NativePass
				if NativeSpec.is_valid_id(implementation.native_id) \
				and implementation.native_id == native.native_id \
				and implementation._native_pass_id() == native.native_id \
				and implementation.resource_name == placeholder_name \
				and pass_name != placeholder_name:
					implementation.resource_name = pass_name
					changed = true
		# Do not silently repair an invalid or duplicate native ID. The warning
		# and last-valid-schedule behavior makes the authored error reviewable.
	# A mandatory entry is re-added in seed order when a resource is missing one:
	# without it the frame is incomplete rather than merely different. A custom pass
	# that declares the entry provides it, so it stays absent on purpose.
	var provided := _provided_native_ids()
	var mandatory := NativeSpec.mandatory_ids()
	for native_id in NativeSpec.default_ids():
		if not mandatory.has(native_id) or _find_native_index(native_id) >= 0:
			continue
		if provided.has(native_id):
			continue
		_passes.insert(_seed_insert_index(native_id), _make_native_pass(native_id))
		changed = true
	return changed

## Position the seed order gives an entry, relative to the entries already present.
func _seed_insert_index(native_id: int) -> int:
	var seed_ids := NativeSpec.default_ids()
	var target: int = seed_ids.find(native_id)
	for i in _passes.size():
		var pass_entry := _passes[i]
		if not pass_entry is BuiltinPass:
			continue
		var existing_pos: int = seed_ids.find((pass_entry as BuiltinPass).native_id)
		if existing_pos >= 0 and existing_pos > target:
			return i
	return _passes.size()

func _migrate_legacy_passes() -> bool:
	_set_passes(PipelineMigrator.migrate_legacy_passes(
		_passes, NativeSpec.seed_order(), NativeSpec.is_optional_id, _make_native_pass), false)
	return true

func _sync_library(emit: bool) -> bool:
	var changed: bool = LibraryManager.sync(_passes, _synced_library, _synced_library_ids, _deleted_library, _deleted_library_ids)
	if changed:
		_connect_passes()
	if changed and emit:
		emit_changed()
	return changed

func _find_native_index(native_id: int) -> int:
	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry is BuiltinPass and (pass_entry as BuiltinPass).native_id == native_id:
			return i
	return -1

## Records a library entry as already present in this pipeline, so synchronization
## neither adds it again nor reads its removal as an accident. The editor menu marks the
## entry it just inserted; passing the stable id or the template path both work.
func mark_library_pass(path: String) -> void:
	var entry = LibraryManager.manifest_for_path(path)
	if entry != null:
		LibraryManager.mark_synced(entry, _synced_library, _synced_library_ids, _deleted_library, _deleted_library_ids)
	else:
		var normalized := LibraryManager.normalize_library_path(path)
		if not _synced_library.has(normalized):
			_synced_library.append(normalized)
	_connect_passes()
	emit_changed()

func apply(compositor: Compositor) -> void:
	_volume_binding = {}
	_view_plans.clear()
	if compositor == null:
		return
	_ensure_pipeline_initialized(true)
	var candidate_warnings := _validate_schedule()
	_last_validation_warnings = candidate_warnings
	# Do not even derive a candidate effect list for an invalid schedule: binding's
	# fallback intentionally leaves the engine's previous valid schedule untouched.
	var schedule: Dictionary = {}
	var provided := PackedInt32Array()
	var parameters: Dictionary = {}
	var context: Dictionary = {}
	if candidate_warnings.is_empty():
		schedule = _build_schedule()
		for native_id in _provided_native_ids():
			provided.append(native_id)
		provided.sort()
		# A full explicit apply must also observe direct dictionary edits and
		# computed pass defaults, even when a caller did not emit changed.
		_volume_context_cache = {}
		context = _initialized_volume_context()
		parameters = _with_eye_adaptation_state(ParameterResolver.resolve_context(_passes, _volume_parameters, context))
	var result := CompositorBinding.apply(
		compositor,
		_manager,
		_passes,
		schedule,
		candidate_warnings,
		_is_entry_enabled,
		provided,
		parameters
	)
	if result.applied:
		_last_valid_schedule = result["tokens"]
		_volume_binding = {
			"revision": _parameter_revision,
			"compositor": compositor.get_instance_id(),
			"states": _volume_pass_states.duplicate(true),
			"context": context,
			"parameters": _volume_parameters.duplicate(true),
			"resolved": parameters,
			"effects": schedule.effects,
			"tokens": schedule.tokens,
			"names": schedule.names,
			"provided": provided,
		}

## Internal per-camera update. Runtime overrides do not edit author resources or
## emit their changed signal. Public set_volume_parameters retains its protocol.
func apply_volume(compositor: Compositor, parameters: Dictionary, pass_states: Dictionary) -> void:
	if compositor == null:
		return
	_volume_parameters = parameters.duplicate(true)
	_volume_pass_states = pass_states.duplicate(true)
	var can_reuse: bool = not _volume_binding.is_empty() \
			and _volume_binding.revision == _parameter_revision \
			and _volume_binding.compositor == compositor.get_instance_id() \
			and _volume_binding.states == pass_states
	if can_reuse:
		# Fixed presets keep the same resolved upload across boundary crossings.
		if _volume_binding.parameters != _volume_parameters:
			_volume_binding.parameters = _volume_parameters.duplicate(true)
			_volume_binding.resolved = _with_eye_adaptation_state(ParameterResolver.resolve_context(_passes, _volume_parameters, _volume_binding.context))
		# Crossing a boundary switches between authored and runtime effect RIDs.
		# Restore the cached binding even though neither renderer's author changed.
		if compositor.compositor_effects != _volume_binding.effects:
			compositor.compositor_effects = _volume_binding.effects
		CompositorBinding.upload(compositor, _volume_binding.tokens, _volume_binding.names, _volume_binding.provided, _volume_binding.resolved)
		return
	apply(compositor)

## Immutable plan shared by views. Volume switches are evaluated without writing
## into this Renderer or changing any authored effect's enabled RID.
func compile_view_plan(states: Dictionary) -> Dictionary:
	for cached in _view_plans:
		if cached.states == states:
			return cached.plan
	_ensure_pipeline_initialized(false)
	var enabled_fn := func(entry): return ExecutionPlan.is_entry_enabled(entry, states)
	var provided := ExecutionPlan.provided_native_ids(_passes, enabled_fn)
	var declared := ExecutionPlan.declared_provided_ids(_passes, enabled_fn)
	var warnings := ExecutionPlan.validation_warnings(_passes, provided, declared, enabled_fn)
	warnings = _with_bloom_eye_order_warning(warnings, enabled_fn)
	if not warnings.is_empty():
		return {"warnings": warnings}
	# Effect slot zero belongs to each view's texture manager. Build keeps custom
	# token indices based at one even when the manager is omitted here.
	var schedule := ExecutionPlan.build(_passes, null, enabled_fn)
	var provided_ids := PackedInt32Array()
	for native_id in provided:
		provided_ids.append(native_id)
	provided_ids.sort()
	var enabled: Array[bool] = []
	for source in schedule.effects:
		enabled.append(enabled_fn.call(source))
	var plan := {
		"warnings": warnings, "tokens": schedule.tokens, "names": schedule.names,
		"sources": schedule.effects, "enabled": enabled, "provided": provided_ids,
		"context": _initialized_volume_context().duplicate(true),
	}
	if _view_plans.size() == 2:
		_view_plans.pop_front()
	_view_plans.append({"states": states.duplicate(true), "plan": plan})
	return plan

## Compatibility entry point for ViewState. The policy owns the implementation
## classification; this method remains stable for callers and passes the renderer's
## existing stock manifest without copying it.
func is_view_shareable(entry: FengPass) -> bool:
	return ViewExecutionPolicy.is_view_shareable(entry, NATIVE_PASS_SCRIPTS, FengAddonLayout.passes_dir())

## The authored schedule exactly as the engine receives it: one token and one readable
## name per executed entry, in order, with the texture manager first. Both lists come
## from the same walk, so they cannot drift apart.
func _build_schedule() -> Dictionary:
	return ExecutionPlan.build(_passes, _manager, _is_entry_enabled)

func get_execution_tokens() -> PackedInt32Array:
	_ensure_pipeline_initialized(false)
	return _build_schedule()["tokens"]

func get_last_valid_schedule() -> PackedInt32Array:
	return _last_valid_schedule

func get_validation_warnings() -> PackedStringArray:
	return _last_validation_warnings

func _validate_schedule() -> PackedStringArray:
	var warnings := ExecutionPlan.validation_warnings(
		_passes,
		_provided_native_ids(),
		_declared_provided_ids(),
		_is_entry_enabled
	)
	return _with_bloom_eye_order_warning(warnings, _is_entry_enabled)

func _with_bloom_eye_order_warning(warnings: PackedStringArray, is_enabled_fn: Callable) -> PackedStringArray:
	var eye_index := -1
	var bloom_index := -1
	var eye_enabled := false
	var bloom_enabled := false
	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry == null:
			continue
		if pass_entry.stable_id == &"library:eye_adaptation":
			eye_index = i
			eye_enabled = is_enabled_fn.call(pass_entry)
		elif pass_entry is BuiltinPass and (pass_entry as BuiltinPass).native_id == NativeSpec.PASS_BLOOM:
			bloom_index = i
			bloom_enabled = is_enabled_fn.call(pass_entry)
	if eye_enabled and bloom_enabled and eye_index > bloom_index:
		warnings.append("Eye Adaptation must precede native Bloom; authored order was retained and the previous valid schedule remains active.")
	return warnings

func get_configuration_warnings() -> PackedStringArray:
	_ensure_pipeline_initialized(false)
	_last_validation_warnings = _validate_schedule()
	return _last_validation_warnings
