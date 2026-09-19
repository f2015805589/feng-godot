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

func _init() -> void:
	_manager = TextureManager.new()
	# Seed a new resource for a useful inspector experience. If this object is
	# loaded from disk, Godot restores serialized passes after _init(); migration
	# below then replaces this seed with the legacy list.
	_seed_default_passes()
	_connect_passes()

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
		if pass_entry == null:
			continue
		_observed_passes.append(pass_entry)
		if pass_entry.has_signal("changed") and not pass_entry.changed.is_connected(_on_pass_changed):
			pass_entry.changed.connect(_on_pass_changed)

func _disconnect_passes() -> void:
	for pass_entry in _observed_passes:
		if pass_entry != null and pass_entry.has_signal("changed") and pass_entry.changed.is_connected(_on_pass_changed):
			pass_entry.changed.disconnect(_on_pass_changed)
	_observed_passes.clear()

func _on_pass_changed() -> void:
	if _normalizing:
		return
	# Resource.changed bridges nested pass edits to a Compositor. Native enabled
	# changes also need a new token list, so they are included.
	emit_changed()
	notify_property_list_changed()

func _ensure_pipeline_initialized(emit: bool) -> bool:
	if _normalizing:
		return false
	_normalizing = true
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
	if pass_entry == null:
		return false
	if pass_entry is BuiltinPass:
		return (pass_entry as BuiltinPass).implementation != null
	return true

## Native passes the authored list provides through pass scripts, i.e. the passes the
## engine has no token for. A pass that runs an engine entry's work itself declares
## it in `FengPass.provides_native_ids` (a native entry with an implementation
## provides its own id); the renderer then accepts a schedule where that entry is
## absent, and normalization does not re-add it.
func _provided_native_ids() -> Dictionary:
	var provided := {}
	for pass_entry in _passes:
		if pass_entry == null or not _is_entry_enabled(pass_entry):
			continue
		if pass_entry is BuiltinPass:
			var native := pass_entry as BuiltinPass
			if native.implementation == null:
				# The engine token runs this one.
				continue
			if NativeSpec.is_valid_id(native.native_id):
				provided[native.native_id] = true
			for native_id in _declared_provides(native.implementation):
				provided[int(native_id)] = true
		for native_id in _declared_provides(pass_entry):
			provided[int(native_id)] = true
	return provided

## Native ids custom passes declare they run. Declaring an id whose engine entry is
## also enabled would run the same work twice.
func _declared_provided_ids() -> Dictionary:
	var declared := {}
	for pass_entry in _passes:
		if pass_entry == null or pass_entry is BuiltinPass or not _is_entry_enabled(pass_entry):
			continue
		for native_id in _declared_provides(pass_entry):
			declared[int(native_id)] = true
	return declared

func _declared_provides(pass_entry) -> Array:
	if pass_entry == null:
		return []
	var declared = pass_entry.get("provides_native_ids")
	if declared == null:
		return []
	return declared

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
	var parameters := {}
	for pass_entry in _passes:
		if pass_entry == null:
			continue
		if pass_entry is BuiltinPass:
			var native := pass_entry as BuiltinPass
			if not NativeSpec.is_valid_id(native.native_id):
				continue
			var declared := _declared_parameters(native.implementation)
			declared.merge(native.pass_parameters, true)
			if not declared.is_empty():
				parameters[native.native_id] = declared
			continue
		# A custom pass exposes parameters for the passes it provides itself.
		var own := _declared_parameters(pass_entry)
		own.merge(pass_entry.pass_parameters, true)
		if own.is_empty():
			continue
		for native_id in _declared_provides(pass_entry):
			if not NativeSpec.is_valid_id(int(native_id)):
				continue
			var target: Dictionary = parameters.get(int(native_id), {})
			target.merge(own, true)
			parameters[int(native_id)] = target
	return parameters

## The parameters the schedule carries, with the volume overrides on top (see
## FengVolume): a volume is the runtime override and therefore wins.
func get_pass_parameters() -> Dictionary:
	var parameters := get_authored_pass_parameters()
	return _with_volume_parameters(parameters)

func _with_volume_parameters(parameters: Dictionary) -> Dictionary:
	for native_id in _volume_parameters:
		var volume_values: Dictionary = _volume_parameters[native_id]
		var merged: Dictionary = parameters.get(native_id, {})
		merged.merge(volume_values, true)
		parameters[native_id] = merged
	return parameters

func _declared_parameters(pass_entry) -> Dictionary:
	if pass_entry == null:
		return {}
	var declared = pass_entry.get_frp_parameters()
	if declared == null or not declared is Dictionary:
		return {}
	return (declared as Dictionary).duplicate()

## Pass parameters and pass states a volume resolved for this camera. The compositor
## pushes them before the frame, and they override the authored values (see FengVolume).
func set_volume_parameters(parameters: Dictionary, pass_states: Dictionary = {}) -> void:
	if parameters == _volume_parameters and pass_states == _volume_pass_states:
		return
	_volume_parameters = parameters
	_volume_pass_states = pass_states
	emit_changed()

func get_volume_parameters() -> Dictionary:
	return _volume_parameters

func get_volume_pass_states() -> Dictionary:
	return _volume_pass_states

## Whether a pass runs in this frame: the entry's authored `enabled`, overridden by a
## volume. A custom pass follows the states of the passes it provides, so a volume can
## switch an effect on or off wherever the pass lives.
func _is_entry_enabled(pass_entry) -> bool:
	if pass_entry == null:
		return false
	if pass_entry is BuiltinPass:
		var native := pass_entry as BuiltinPass
		if _volume_pass_states.has(native.native_id):
			return bool(_volume_pass_states[native.native_id])
		return pass_entry.enabled
	for native_id in _declared_provides(pass_entry):
		if _volume_pass_states.has(int(native_id)):
			return bool(_volume_pass_states[int(native_id)])
	return pass_entry.enabled

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
	if compositor == null:
		return
	_ensure_pipeline_initialized(true)
	var candidate_warnings := _validate_schedule()
	_last_validation_warnings = candidate_warnings
	if not candidate_warnings.is_empty():
		# Enabled is a live native property. A producer may already have been
		# disabled when validation finds that another effect still needs it.
		# Keep the last valid schedule, but stop the project's own effects until the
		# authored resource contracts are valid again. The native entries keep running:
		# they are the schedule the frame is built from, and they are also pass scripts
		# now, so suspending them would void the frame instead of the authoring.
		if compositor.compositor_effects.has(_manager):
			for effect in compositor.compositor_effects:
				if effect == _manager or effect is BuiltinPass:
					continue
				RenderingServer.compositor_effect_set_enabled(effect.get_rid(), false)
			_manager.passes.clear()
		for warning in candidate_warnings:
			push_warning("FengRenderer: " + warning)
		return

	for pass_entry in _passes:
		if pass_entry != null:
			# This must happen before compositor effects are uploaded so the native
			# renderer sees accurate attachment requirements immediately. The contract
			# lives in the pass script that implements the entry (and in its overlay),
			# while the engine reads the flags from the effect, so they are copied over.
			var contract = _contract_source(pass_entry)
			contract.refresh_resource_flags()
			if contract != pass_entry:
				pass_entry.access_resolved_color = contract.access_resolved_color
				pass_entry.access_resolved_depth = contract.access_resolved_depth
				pass_entry.needs_motion_vectors = contract.needs_motion_vectors
				pass_entry.needs_normal_roughness = contract.needs_normal_roughness
				pass_entry.needs_separate_specular = contract.needs_separate_specular
			RenderingServer.compositor_effect_set_enabled(pass_entry.get_rid(), _is_entry_enabled(pass_entry))

	var effects: Array[CompositorEffect] = []
	effects.append(_manager)
	var scripted_effects: Array[CompositorEffect] = []
	for pass_entry in _passes:
		if pass_entry == null or not _is_scripted(pass_entry):
			continue
		scripted_effects.append(pass_entry)
		effects.append(pass_entry)
	# Keep disabled scripted passes in both arrays. The native scheduler checks
	# enabled at token execution time, while stable effect indices remain valid.
	_manager.passes = scripted_effects
	compositor.compositor_effects = effects
	var schedule := _build_schedule()
	_set_native_schedule(compositor, schedule["tokens"], schedule["names"])
	_last_valid_schedule = schedule["tokens"]

func _set_native_schedule(compositor: Compositor, tokens: PackedInt32Array, names: PackedStringArray) -> void:
	# Passes a plugin runs itself are reported to the engine: the schedule dropped
	# their engine entries, and the renderer's per-frame feature setup reads this list
	# to know the pass is still part of the frame (it is what keeps the Temporal AA
	# jitter running when a plugin pass owns that entry).
	var provided := get_provided_native_ids()
	var parameters := get_pass_parameters()
	RenderingServer.compositor_set_frp_pipeline(compositor.get_rid(), tokens, names, provided, parameters)

## The authored schedule exactly as the engine receives it: one token and one readable
## name per executed entry, in order, with the texture manager first. Both lists come
## from the same walk, so they cannot drift apart.
func _build_schedule() -> Dictionary:
	var tokens: Array[int] = [MANAGER_TOKEN]
	var names := PackedStringArray(["Texture Preparation"])
	var effect_index := 1 # compositor_effects[0] is the manager.
	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry == null:
			continue
		if _is_scripted(pass_entry):
			# Every scripted pass occupies an effect slot, including disabled entries:
			# the engine checks enabled at token execution time.
			tokens.append(-(effect_index + 1))
			effect_index += 1
			names.append(_schedule_name(pass_entry, i))
			continue
		# A native entry without an implementation is the engine's own pass.
		var native := pass_entry as BuiltinPass
		if _is_entry_enabled(native):
			tokens.append(native.native_id)
			names.append(_schedule_name(pass_entry, i))
	return {"tokens": PackedInt32Array(tokens), "names": names}

func _schedule_name(pass_entry, index: int) -> String:
	var display_name: String = pass_entry.resource_name
	if display_name.is_empty():
		display_name = str(pass_entry.stable_id) if not pass_entry.stable_id.is_empty() else "Custom Pass"
	return "%02d %s" % [index, display_name]

func get_execution_tokens() -> PackedInt32Array:
	_ensure_pipeline_initialized(false)
	return _build_schedule()["tokens"]

func get_last_valid_schedule() -> PackedInt32Array:
	return _last_valid_schedule

func get_validation_warnings() -> PackedStringArray:
	return _last_validation_warnings

func _validate_schedule() -> PackedStringArray:
	return PipelineValidator.validate_schedule(
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
