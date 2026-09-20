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
const PIPELINE_SCHEMA_VERSION := 6
const MANAGER_TOKEN := -1

## The addon's pass script for each engine pass. A subclass of FengNativePass runs
## the pass through the Core primitives by default and can be replaced per entry
## (or overridden by the project) without an engine change. The keys are the engine's
## pass ids, which are also the execution order.
const NATIVE_PASS_SCRIPTS := {
	NativeSpec.PASS_SHADOW_PRECOMPUTE: "native/shadow_precompute_pass.gd",
	NativeSpec.PASS_VIRTUAL_TEXTURE: "native/vt_pass.gd",
	NativeSpec.PASS_GBUFFER: "native/gbuffer_pass.gd",
	NativeSpec.PASS_LIGHTING: "native/lighting_pass.gd",
	NativeSpec.PASS_SKY: "native/sky_pass.gd",
	NativeSpec.PASS_TRANSPARENT: "native/transparent_pass.gd",
	NativeSpec.PASS_TEMPORAL_AA: "native/temporal_aa_pass.gd",
	NativeSpec.PASS_POST_PROCESS: "native/post_process_pass.gd",
}

const NativePass = preload("passes/native/native_pass.gd")

## Library entries a fresh pipeline seeds, placed directly before Post Process, so the
## pipeline reads Shadow Precompute, VT, GBuffer, Lighting, Sky, Transparent, Temporal
## AA, Color Grade, Post — the nine passes, in execution order.
## A renderer's complete default list is native work with the library's
## custom effects inserted at the history-copy/temporal-AA boundary.
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

var _manager: CompositorEffect
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
	_manager = TextureManager.new()
	# Fresh custom schedules are current too, even when assigned before the first
	# default-list read. Resource loading restores its serialized version later.
	_pipeline_schema_version = PIPELINE_SCHEMA_VERSION
	# Seed on first use. Loading or duplicating a Renderer restores its own pass
	# list: allocating nine throwaway default passes here needlessly loads shader
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

## The default pass set: every entry in seed order (the one optional entry, Temporal
## AA, listed but disabled), with the library's authoring entries placed directly
## before Post Process, i.e. after Temporal AA.
func _default_seed_list() -> Array[PassBase]:
	var seeded: Array[PassBase] = []
	var library_added := false
	for native_id in NativeSpec.seed_order():
		if not library_added and native_id == NativeSpec.PASS_POST_PROCESS:
			library_added = true
			_append_default_library(seeded)
		var pass_entry := _make_native_pass(native_id)
		if NativeSpec.is_optional_id(native_id):
			pass_entry.enabled = false
		seeded.append(pass_entry)
	if not library_added:
		_append_default_library(seeded)
	return seeded

func _append_default_library(seeded: Array[PassBase]) -> void:
	for entry in DEFAULT_LIBRARY_ENTRIES:
		if not DEFAULT_LIBRARY_SEEDED.has(entry["id"]):
			continue
		var template = LibraryManager.load_template(entry)
		if template == null or not template is PassBase:
			continue
		var instance := template.duplicate(true) as PassBase
		LibraryManager.configure_library_pass(instance, entry)
		# Color Grade is the pipeline's ninth pass, and like Temporal AA it is a
		# quality/look switch: it ships disabled so a fresh renderer's frame is the
		# engine's own passes until the project turns it on.
		instance.enabled = false
		seeded.append(instance)

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

func _set_passes(value: Array, emit: bool) -> void:
	_seed_pending = false
	var next: Array[PassBase] = []
	for value_pass in value:
		if value_pass == null or value_pass is PassBase:
			next.append(value_pass)
	_disconnect_passes()
	_passes = next
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

func _connect_passes() -> void:
	_disconnect_passes()
	for pass_entry in _passes:
		_observe_pass(pass_entry)

## Watches one authored pass and everything it carries. A carried pass (an entry's
## implementation, a native pass's overlay) is a resource of its own, so the inspector
## edits it directly and Godot does not forward its `changed` to the resource holding
## it. Without observing them, editing an exposed parameter or switching the carried
## pass off would only reach the engine on the next unrelated change - and the entry's
## enabled state, which follows the chain, would look stale.
func _observe_pass(pass_entry) -> void:
	if pass_entry == null or _observed_passes.has(pass_entry):
		return
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
	if pass_entry.has_signal("changed") and not pass_entry.changed.is_connected(_on_pass_changed):
		pass_entry.changed.connect(_on_pass_changed)
	if pass_entry.has_method("carried_passes"):
		for carried in pass_entry.carried_passes():
			_observe_pass(carried)

func _disconnect_passes() -> void:
	for pass_entry in _observed_passes:
		if pass_entry != null and pass_entry.has_signal("changed") and pass_entry.changed.is_connected(_on_pass_changed):
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
	if _pipeline_schema_version < PIPELINE_SCHEMA_VERSION and not _has_native_schedule():
		changed = _migrate_legacy_passes() or changed
	elif _pipeline_schema_version < PIPELINE_SCHEMA_VERSION:
		changed = _migrate_native_pass_set() or changed
	else:
		changed = _normalize_native_entries() or changed
	if _pipeline_schema_version < PIPELINE_SCHEMA_VERSION:
		_pipeline_schema_version = PIPELINE_SCHEMA_VERSION
		changed = true
	changed = _sync_library(false) or changed
	_connect_passes()
	_normalizing = false
	if changed and emit:
		emit_changed()
	return changed

func _has_native_entries() -> bool:
	for pass_entry in _passes:
		if pass_entry is BuiltinPass:
			return true
	return false

## The object that owns a pass entry's resource contract (see FengPass and
## FengBuiltinPass): the pass script that implements the entry, or the overlay it
## delegates to.
func _contract_source(pass_entry):
	if pass_entry == null:
		return null
	if pass_entry.has_method("get_contract_source"):
		var resolved = pass_entry.get_contract_source()
		if resolved != null:
			return resolved
	return pass_entry

## A pass the addon runs: a custom pass, or a native entry whose implementation is a
## pass script. Everything else is executed by the engine's own token.
func _is_scripted(pass_entry) -> bool:
	return ExecutionPlan.is_scripted(pass_entry)

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

func _declared_provides(pass_entry) -> Array:
	return ExecutionPlan.declared_provides(pass_entry)

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
	return ParameterResolver.authored(_passes)

func get_volume_modules() -> Array[FengPass]:
	_ensure_pipeline_initialized(false)
	return ParameterResolver.volume_modules(_passes)

func get_volume_parameter_schema() -> Dictionary:
	_ensure_pipeline_initialized(false)
	return ParameterResolver.volume_schema(_passes)

func get_volume_parameter_aliases() -> Dictionary:
	_ensure_pipeline_initialized(false)
	return ParameterResolver.volume_aliases(_passes)

func get_pass_parameters() -> Dictionary:
	_ensure_pipeline_initialized(false)
	return ParameterResolver.resolve(_passes, _volume_parameters)

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
	var migrated: Array[PassBase] = []
	for p in PipelineMigrator.migrate_native_pass_set(_passes, NativeSpec.default_ids(), _make_native_pass):
		if p is PassBase:
			migrated.append(p)
	_set_passes(migrated, false)
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
			if native.resource_name == "":
				native.resource_name = NativeSpec.pass_name(native.native_id)
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
	var migrated: Array[PassBase] = []
	for p in PipelineMigrator.migrate_legacy_passes(_passes, NativeSpec.seed_order(), NativeSpec.is_optional_id, _make_native_pass):
		if p is PassBase:
			migrated.append(p)
	_set_passes(migrated, false)
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
		parameters = ParameterResolver.resolve_context(_passes, _volume_parameters, context)
	var result := CompositorBinding.apply(
		compositor,
		_manager,
		_passes,
		schedule,
		candidate_warnings,
		_contract_source,
		_is_entry_enabled,
		func(): return provided,
		func(): return parameters
	)
	if result.get("applied", false):
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
			_volume_binding.resolved = ParameterResolver.resolve_context(_passes, _volume_parameters, _volume_binding.context)
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
	var warnings := ExecutionPlan.validation_warnings(_passes, provided, declared, enabled_fn, _contract_source, _is_scripted)
	if not warnings.is_empty():
		return {"warnings": warnings}
	# Effect slot zero belongs to each view's texture manager. Build keeps custom
	# token indices based at one even when the manager is omitted here.
	var schedule := ExecutionPlan.build(_passes, null, _is_scripted, enabled_fn)
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

func _set_native_schedule(compositor: Compositor, tokens: PackedInt32Array, names: PackedStringArray) -> void:
	# Passes a plugin runs itself are reported to the engine: the schedule dropped
	# their engine entries, and the renderer's per-frame feature setup reads this list
	# to know the pass is still part of the frame (it is what keeps the Temporal AA
	# jitter running when a plugin pass owns that entry).
	CompositorBinding.upload(compositor, tokens, names, get_provided_native_ids(), get_pass_parameters())

## The authored schedule exactly as the engine receives it: one token and one readable
## name per executed entry, in order, with the texture manager first. Both lists come
## from the same walk, so they cannot drift apart.
func _build_schedule() -> Dictionary:
	return ExecutionPlan.build(_passes, _manager, _is_scripted, _is_entry_enabled)

func _schedule_name(pass_entry, index: int) -> String:
	return ExecutionPlan.schedule_name(pass_entry, index)

func get_execution_tokens() -> PackedInt32Array:
	_ensure_pipeline_initialized(false)
	return _build_schedule()["tokens"]

func get_last_valid_schedule() -> PackedInt32Array:
	return _last_valid_schedule

func get_validation_warnings() -> PackedStringArray:
	return _last_validation_warnings

func _validate_schedule() -> PackedStringArray:
	return ExecutionPlan.validation_warnings(
		_passes,
		_provided_native_ids(),
		_declared_provided_ids(),
		_is_entry_enabled,
		_contract_source,
		_is_scripted
	)

func get_configuration_warnings() -> PackedStringArray:
	_ensure_pipeline_initialized(false)
	_last_validation_warnings = _validate_schedule()
	return _last_validation_warnings
