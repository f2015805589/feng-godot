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

const LIBRARY_DIR := "res://addons/feng-render-pipeline/library"
const PASS_DIR := "res://addons/feng-render-pipeline/passes/"
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
	0: "native/shadow_precompute_pass.gd",
	1: "native/vt_pass.gd",
	2: "native/gbuffer_pass.gd",
	3: "native/lighting_pass.gd",
	4: "native/sky_pass.gd",
	5: "native/transparent_pass.gd",
	6: "native/temporal_aa_pass.gd",
	7: "native/post_process_pass.gd",
}

const NativePass = preload("passes/native/native_pass.gd")

## Old FRP pass ids mapped to the entry that now owns their work. Ids 4, 3, 5, 8,
## 9, 10, 12 and 13 were absorbed as internal operations of a remaining entry
## (motion vectors into the G-buffer, the forward fallback into transparent, the
## resolves, the screen and depth copies and the specular merge into the entries
## that need them), so a migrated resource drops those entries and keeps their
## behaviour through the entry they map to. The keys are the pre-collapse pass ids,
## which were the operation ids of the 21-entry pipeline.
##
## The pre-collapse ids of the removed entries (6 debug geometry, 17 SSAO, 18 SSIL,
## 19 SSR, 20 global illumination) are deliberately absent: FRP has no such passes,
## so a resource that carries one drops it on load.
const LEGACY_NATIVE_ID_MAP := {
	16: 1, 1: 0, 0: 2, 2: 3, 7: 4, 11: 5, 14: 6, 15: 7,
	4: 2, 3: 5, 5: 7, 8: 4, 9: 3, 10: 5, 12: 7, 13: 7,
}

## Library entries a fresh pipeline seeds, placed directly before Post Process, so
## the pipeline reads Shadow Precompute, VT, GBuffer, Lighting, Sky, Transparent,
## Temporal AA, Color Grade, Post — the nine passes, in execution order.
## Colour grading is a pass rather than an engine entry, so its shader and its
## parameters can be replaced without an engine change.
const TEMPORAL_AA_NATIVE_ID := 6
const POST_PROCESS_NATIVE_ID := 7

## The native pass set is defined once, in the engine (FRPPipelineSpec), and read
## back through this shared accessor. Ids, display names, the mandatory entries,
## the order constraints and the default execution order used to be duplicated
## here and in the engine validator; editing one without the other produced
## schedules the renderer disagreed with.
const NativeSpec = preload("passes/native_spec.gd")

static func native_spec() -> Dictionary:
	return NativeSpec.spec()

## Native FRP operations. Executable grouped renderer boundaries, not one entry
## per draw or GPU dispatch.
static func native_pass_definitions() -> Array:
	return NativeSpec.pass_definitions()

static func native_pass_count() -> int:
	return NativeSpec.pass_count()

## Default execution order, which is the engine's pass id order: shadow maps, virtual
## textures, the G-buffer, lighting, sky, transparent, temporal AA, post. The pipeline
## resource lists entries in this order and the renderer executes the list in order,
## so reordering the entries reorders the frame.
static func native_seed_order() -> Array:
	return NativeSpec.seed_order()

## Ids a fresh pipeline seeds: every non optional pass, in seed order.
static func native_default_ids() -> Array:
	var ids: Array = []
	for native_id in native_seed_order():
		if not is_optional_native_id(int(native_id)):
			ids.append(int(native_id))
	return ids

## Ids a fresh pipeline lists, in seed order. Optional effects are seeded disabled:
## the default enabled set is the default pass set, and enabling the entry is what
## turns the effect on.
static func native_seed_ids() -> Array:
	return native_seed_order()

static func is_valid_native_id(p_native_id: int) -> bool:
	return NativeSpec.is_valid_id(p_native_id)

static func is_optional_native_id(p_native_id: int) -> bool:
	for definition in native_pass_definitions():
		if int(definition["id"]) == p_native_id:
			return bool(definition.get("optional", false))
	return false

## Native order constraints. A disabled optional pass_entry does not invalidate
## another enabled pass_entry; if both entries are enabled, the prerequisite must
## occur first. This lets users disable fallback, motion, sky, history, or
## temporal work without silently adding it back.
static func native_order_edges() -> Array:
	return NativeSpec.order_edges()

static func mandatory_native_ids() -> Array:
	return NativeSpec.mandatory_ids()

static func native_name(native_id: int) -> String:
	return NativeSpec.pass_name(native_id)

## A renderer's complete default list is native work with the library's
## custom effects inserted at the history-copy/temporal-AA boundary.
const DEFAULT_LIBRARY_ENTRIES := [
	{"id": "library:tint", "path": "tint/tint.tres", "name": "Tint"},
	{"id": "library:blur_horizontal", "path": "blur/blur_h.tres", "name": "Blur Horizontal"},
	{"id": "library:blur_vertical", "path": "blur/blur_v.tres", "name": "Blur Vertical"},
	{"id": "library:fxaa", "path": "fxaa/fxaa.tres", "name": "FXAA"},
	{"id": "library:color_grade", "path": "color-grade/color_grade.tres", "name": "Color Grade"},
	{"id": "library:bloom_downsample", "path": "bloom-lite/bloom_downsample.tres", "name": "Bloom Downsample"},
	{"id": "library:bloom_blur", "path": "bloom-lite/bloom_blur.tres", "name": "Bloom Blur"},
	{"id": "library:bloom_composite", "path": "bloom-lite/bloom_composite.tres", "name": "Bloom Composite"},
]

## Kept for source compatibility with scripts that used the old path-only
## manifest. New code should use DEFAULT_LIBRARY_ENTRIES so each entry has a
## stable id as well as a path.
const DEFAULT_PASS_PATHS: Array[String] = [
	"tint/tint.tres",
	"blur/blur_h.tres",
	"blur/blur_v.tres",
	"fxaa/fxaa.tres",
	"color-grade/color_grade.tres",
	"bloom-lite/bloom_downsample.tres",
	"bloom-lite/bloom_blur.tres",
	"bloom-lite/bloom_composite.tres",
]

## The library entries a fresh pipeline seeds. Color Grade is the pipeline's ninth
## pass, so it is seeded (disabled, like Temporal AA: a look is a switch). The other
## entries are authoring templates: they are not pushed into a renderer at all, and
## reach a project only through the inspector's "Add Pass from Library".
const DEFAULT_LIBRARY_SEEDED: Array[String] = [
	"library:color_grade",
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

## Legacy path manifest. Paths remain persisted so resources authored by the
## first plugin version continue to load; `_synced_library_ids` is the stable
## identity manifest used by new entries.
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
var _warned_missing_native_api := false
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
	for native_id in native_seed_ids():
		if not library_added and native_id == POST_PROCESS_NATIVE_ID:
			library_added = true
			_append_default_library(seeded)
		var pass_entry := _make_native_pass(native_id, native_name(native_id))
		if is_optional_native_id(native_id):
			pass_entry.enabled = false
		seeded.append(pass_entry)
	if not library_added:
		_append_default_library(seeded)
	return seeded

func _append_default_library(seeded: Array[PassBase]) -> void:
	for entry in DEFAULT_LIBRARY_ENTRIES:
		if not DEFAULT_LIBRARY_SEEDED.has(entry["id"]):
			continue
		var template = load(LIBRARY_DIR + "/" + entry["path"])
		if template == null or not template is PassBase:
			continue
		var instance := template.duplicate(true) as PassBase
		_configure_library_pass(instance, entry)
		# Color Grade is the pipeline's ninth pass, and like Temporal AA it is a
		# quality/look switch: it ships disabled so a fresh renderer's frame is the
		# engine's own passes until the project turns it on.
		instance.enabled = false
		seeded.append(instance)

func _make_native_pass(native_id: int, display_name: String) -> PassBase:
	var pass_entry := BuiltinPass.new(native_id, display_name) as PassBase
	pass_entry.stable_id = "native:%d" % native_id
	pass_entry.resource_name = display_name
	# The default pipeline is implemented by the addon; an entry an author leaves
	# without an implementation falls back to the engine's own pass.
	pass_entry.implementation = _make_default_implementation(native_id)
	return pass_entry

## The addon's pass script for one engine pass, or a plain FengNativePass when a
## project's addon copy does not ship that script.
func _make_default_implementation(native_id: int) -> PassBase:
	var script_path: String = NATIVE_PASS_SCRIPTS.get(native_id, "")
	if script_path != "":
		var script = load(PASS_DIR + script_path)
		if script != null:
			var instance = script.new()
			if instance is PassBase:
				return instance
	var fallback := NativePass.new() as PassBase
	fallback.native_id = native_id
	fallback.resource_name = native_name(native_id)
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
			if is_valid_native_id(native.native_id):
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
	for native_id in mandatory_native_ids():
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
			if not is_valid_native_id(native.native_id):
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
			if not is_valid_native_id(int(native_id)):
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
	var carried := {}
	var carried_before := []
	var legacy_enabled := {}
	var legacy_seen := {}
	var legacy_order: Array = []
	var last_anchor := -1
	for pass_entry in _passes:
		if pass_entry is BuiltinPass:
			var old_id: int = (pass_entry as BuiltinPass).native_id
			if not LEGACY_NATIVE_ID_MAP.has(old_id):
				continue
			var new_id: int = LEGACY_NATIVE_ID_MAP[old_id]
			last_anchor = new_id
			if not legacy_seen.has(new_id):
				legacy_seen[new_id] = true
				legacy_order.append(new_id)
				legacy_enabled[new_id] = pass_entry.enabled
			continue
		if pass_entry == null:
			continue
		_ensure_custom_identity(pass_entry, carried_before.size() + carried.size())
		if last_anchor < 0:
			carried_before.append(pass_entry)
			continue
		if not carried.has(last_anchor):
			carried[last_anchor] = []
		carried[last_anchor].append(pass_entry)

	var migrated: Array[PassBase] = []
	for pass_entry in carried_before:
		migrated.append(pass_entry)
	var emitted := {}
	for native_id in native_default_ids():
		migrated.append(_make_migrated_native(native_id, legacy_seen, legacy_enabled))
		emitted[native_id] = true
		for pass_entry in carried.get(native_id, []):
			migrated.append(pass_entry)
	# Optional entries the resource had are kept, in the order it had them.
	for native_id in legacy_order:
		if emitted.has(native_id):
			continue
		migrated.append(_make_migrated_native(native_id, legacy_seen, legacy_enabled))
		emitted[native_id] = true
		for pass_entry in carried.get(native_id, []):
			migrated.append(pass_entry)
	_set_passes(migrated, false)
	return true

func _make_migrated_native(native_id: int, legacy_seen: Dictionary, legacy_enabled: Dictionary) -> PassBase:
	var pass_entry := _make_native_pass(native_id, native_name(native_id))
	if legacy_seen.has(native_id):
		pass_entry.enabled = legacy_enabled[native_id]
	return pass_entry

func _normalize_native_entries() -> bool:
	var changed := false
	for pass_entry in _passes:
		if not pass_entry is BuiltinPass:
			continue
		var native := pass_entry as BuiltinPass
		if native.native_id >= 0 and native.native_id < native_pass_count():
			if native.stable_id != "native:%d" % native.native_id:
				native.stable_id = "native:%d" % native.native_id
				changed = true
			if native.resource_name == "":
				native.resource_name = native_name(native.native_id)
				changed = true
		# Do not silently repair an invalid or duplicate native ID. The warning
		# and last-valid-schedule behavior makes the authored error reviewable.
	# A mandatory entry is re-added in seed order when a resource is missing one:
	# without it the frame is incomplete rather than merely different. A custom pass
	# that declares the entry provides it, so it stays absent on purpose.
	var provided := _provided_native_ids()
	for native_id in native_default_ids():
		if not mandatory_native_ids().has(native_id) or _find_native_index(native_id) >= 0:
			continue
		if provided.has(native_id):
			continue
		_passes.insert(_seed_insert_index(native_id), _make_native_pass(native_id, native_name(native_id)))
		changed = true
	return changed

## Position the seed order gives an entry, relative to the entries already present.
func _seed_insert_index(native_id: int) -> int:
	var seed_ids := native_default_ids()
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
	var legacy: Array[PassBase] = _passes.duplicate()
	var buckets := {}
	for anchor in range(-1, native_pass_count()):
		buckets[anchor] = []
	for ordinal in legacy.size():
		var pass_entry := legacy[ordinal]
		if pass_entry == null:
			continue
		_ensure_custom_identity(pass_entry, ordinal)
		var anchor := _legacy_anchor_for_pass(pass_entry)
		if not buckets.has(anchor):
			anchor = -1
		buckets[anchor].append(pass_entry)
	var migrated: Array[PassBase] = []
	for pass_entry in buckets[-1]:
		migrated.append(pass_entry)
	# Only the engine entries are seeded here: the library is reconciled separately by
	# _sync_library, which is what records a tombstone for an entry the resource
	# already knew about and no longer contains.
	for native_id in native_seed_ids():
		var pass_entry := _make_native_pass(native_id, native_name(native_id))
		if is_optional_native_id(native_id):
			pass_entry.enabled = false
		migrated.append(pass_entry)
		for carried in buckets.get(native_id, []):
			migrated.append(carried)
	_set_passes(migrated, false)
	return true

func _legacy_anchor_for_pass(pass_entry: PassBase) -> int:
	# The old stage remains useful only for this one-time migration. Existing
	# relative order within every stage is retained by bucket append order.
	match pass_entry.stage:
		CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_GBUFFER, CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_OPAQUE:
			return -1
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_GBUFFER:
			return 2
		CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_LIGHTING:
			return 1
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_LIGHTING:
			return 3
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE:
			return 3
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_SKY:
			return 4
		CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT, CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
			return 5
	return 5

func _native_definition(native_id: int):
	for definition in native_pass_definitions():
		if int(definition["id"]) == native_id:
			return definition
	return null

func _library_entry_for_path(path: String):
	var normalized := path
	var prefix := LIBRARY_DIR + "/"
	if normalized.begins_with(prefix):
		normalized = normalized.substr(prefix.length())
	for entry in DEFAULT_LIBRARY_ENTRIES:
		if entry["path"] == normalized or entry["id"] == normalized:
			return entry
	return null

func _is_library_synced(entry: Dictionary) -> bool:
	return _synced_library.has(entry["path"]) or _synced_library.has(entry["id"]) or _synced_library_ids.has(entry["id"])

func _is_library_deleted(entry: Dictionary) -> bool:
	return _deleted_library.has(entry["path"]) or _deleted_library.has(entry["id"]) or _deleted_library_ids.has(entry["id"])

func _mark_library_synced(entry: Dictionary) -> void:
	var path: String = entry["path"]
	var stable_id: String = entry["id"]
	if not _synced_library.has(path):
		_synced_library.append(path)
	if not _synced_library_ids.has(stable_id):
		_synced_library_ids.append(stable_id)
	# Explicit re-add from the editor clears a prior tombstone.
	_deleted_library.erase(path)
	_deleted_library.erase(stable_id)
	_deleted_library_ids.erase(stable_id)

func _mark_library_deleted(entry: Dictionary) -> void:
	var path: String = entry["path"]
	var stable_id: String = entry["id"]
	if not _deleted_library.has(path):
		_deleted_library.append(path)
	if not _deleted_library_ids.has(stable_id):
		_deleted_library_ids.append(stable_id)

func _sync_library(emit: bool) -> bool:
	var changed := false
	# A synced entry that is no longer present was removed by the user. Record
	# that fact before considering new entries, preventing a re-add on refresh.
	for entry in DEFAULT_LIBRARY_ENTRIES:
		if not DEFAULT_LIBRARY_SEEDED.has(entry["id"]) and not _is_library_synced(entry):
			continue
		if _is_library_synced(entry) and not _has_matching_library_pass(entry):
			var was_deleted := _is_library_deleted(entry)
			_mark_library_deleted(entry)
			if not was_deleted:
				changed = true

	for entry in DEFAULT_LIBRARY_ENTRIES:
		if _is_library_deleted(entry):
			continue
		# Only the seeded entries are pushed into a renderer. The other templates are
		# opt-in: they reach a project through "Add Pass from Library", which marks them
		# synced, and until then they are left out of every existing renderer.
		if not DEFAULT_LIBRARY_SEEDED.has(entry["id"]) and not _is_library_synced(entry):
			continue
		if _is_library_synced(entry):
			# Older resources only persisted the path manifest. Normalize the
			# matching pass's stable identity and readable name when it is found.
			var synced_template = load(LIBRARY_DIR + "/" + entry["path"])
			var synced_existing = _find_matching_library_pass(entry, synced_template)
			if synced_existing != null:
				if synced_existing.stable_id != entry["id"]:
					synced_existing.stable_id = entry["id"]
					changed = true
				if synced_existing.resource_name == "":
					synced_existing.resource_name = entry["name"]
					changed = true
			continue
		var template = load(LIBRARY_DIR + "/" + entry["path"])
		if template == null or not template is PassBase:
			continue
		var existing = _find_matching_library_pass(entry, template)
		if existing == null:
			var instance := template.duplicate(true) as PassBase
			_configure_library_pass(instance, entry)
			# A template that appears after an addon update arrives disabled, exactly
			# like the ones a fresh pipeline seeds.
			instance.enabled = false
			_insert_library_pass(instance)
			changed = true
		else:
			# Preserve a user-customized display name while filling in identity on
			# resources created by the earlier plugin version.
			if existing.stable_id == "":
				existing.stable_id = entry["id"]
				changed = true
			if existing.resource_name == "":
				existing.resource_name = entry["name"]
				changed = true
		_mark_library_synced(entry)
	if changed:
		_connect_passes()
	if changed and emit:
		emit_changed()
	return changed

func _configure_library_pass(pass_entry: PassBase, entry: Dictionary) -> void:
	pass_entry.stable_id = entry["id"]
	pass_entry.resource_name = entry["name"]

func _find_matching_library_pass(entry: Dictionary, template = null):
	var stable_id: String = entry["id"]
	var shader_path := ""
	if template != null:
		var template_shader = template.get("shader_file")
		if template_shader != null:
			shader_path = template_shader.resource_path
	for pass_entry in _passes:
		if pass_entry == null or pass_entry is BuiltinPass:
			continue
		if pass_entry.stable_id == stable_id:
			return pass_entry
		if shader_path != "":
			var pass_shader = pass_entry.get("shader_file")
			if pass_shader != null and pass_shader.resource_path == shader_path:
				return pass_entry
	return null

func _has_matching_library_pass(entry: Dictionary) -> bool:
	var template = load(LIBRARY_DIR + "/" + entry["path"])
	return _find_matching_library_pass(entry, template) != null

func _insert_library_pass(pass_entry: PassBase) -> void:
	# The first native entry after the default library anchor is Post Process.
	# Insertions before that boundary preserve every existing entry's relative
	# order and keep default entries ordered while syncing.
	var library_end := _find_native_index(POST_PROCESS_NATIVE_ID)
	if library_end < 0:
		library_end = _passes.size()
	var insert_index := library_end
	var new_order := _default_library_order(pass_entry.stable_id)
	var next_default := -1
	var next_order := 100000
	var previous_default := -1
	var previous_order := -1
	for i in range(library_end):
		var existing := _passes[i]
		if existing == null:
			continue
		var existing_order := _default_library_order(existing.stable_id)
		if existing_order < 0:
			continue
		if existing_order > new_order and existing_order < next_order:
			next_default = i
			next_order = existing_order
		if existing_order < new_order and existing_order > previous_order:
			previous_default = i
			previous_order = existing_order
	if next_default >= 0:
		insert_index = next_default
	elif previous_default >= 0:
		insert_index = previous_default + 1
	_passes.insert(insert_index, pass_entry)

func _default_library_order(stable_id: StringName) -> int:
	for i in DEFAULT_LIBRARY_ENTRIES.size():
		if DEFAULT_LIBRARY_ENTRIES[i]["id"] == stable_id:
			return i
	return -1

func _find_native_index(native_id: int) -> int:
	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry is BuiltinPass and (pass_entry as BuiltinPass).native_id == native_id:
			return i
	return -1

## Marks a library pass as already present. Used by the editor menu and kept
## public for scripts written against the original path-only implementation.
func mark_library_pass(path: String) -> void:
	var entry = _library_entry_for_path(path)
	if entry != null:
		_mark_library_synced(entry)
	else:
		var normalized := path
		var prefix := LIBRARY_DIR + "/"
		if normalized.begins_with(prefix):
			normalized = normalized.substr(prefix.length())
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
			contract._refresh_resource_flags()
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

func _set_native_schedule(compositor: Compositor, tokens: PackedInt32Array, names: PackedStringArray) -> bool:
	if not RenderingServer.has_method("compositor_set_frp_pipeline"):
		if not _warned_missing_native_api:
			push_warning("FengRenderer: native FRP schedule API is unavailable; custom effects use legacy callback stages until the engine is rebuilt.")
			_warned_missing_native_api = true
		return false
	# Passes a plugin runs itself are reported to the engine: the schedule dropped
	# their engine entries, and the renderer's per-frame feature setup reads this list
	# to know the pass is still part of the frame (it is what keeps the Temporal AA
	# jitter running when a plugin pass owns that entry).
	var provided := get_provided_native_ids()
	var parameters := get_pass_parameters()
	# The addon may reload while an older editor binary is still running.
	for method in RenderingServer.get_method_list():
		if method.name == "compositor_set_frp_pipeline":
			if method.args.size() >= 5:
				RenderingServer.call("compositor_set_frp_pipeline", compositor.get_rid(), tokens, names, provided, parameters)
			elif method.args.size() >= 4:
				RenderingServer.call("compositor_set_frp_pipeline", compositor.get_rid(), tokens, names, provided)
			elif method.args.size() >= 3:
				RenderingServer.call("compositor_set_frp_pipeline", compositor.get_rid(), tokens, names)
			else:
				RenderingServer.call("compositor_set_frp_pipeline", compositor.get_rid(), tokens)
			break
	return true

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

func _build_schedule_tokens() -> PackedInt32Array:
	return _build_schedule()["tokens"]

func get_execution_tokens() -> PackedInt32Array:
	_ensure_pipeline_initialized(false)
	return _build_schedule_tokens()

func get_last_valid_schedule() -> PackedInt32Array:
	return _last_valid_schedule

func get_validation_warnings() -> PackedStringArray:
	return _last_validation_warnings

func get_enabled_passes() -> Array[PassBase]:
	var result: Array[PassBase] = []
	for pass_entry in _passes:
		if pass_entry != null and pass_entry.enabled:
			result.append(pass_entry)
	return result

func _validate_schedule() -> PackedStringArray:
	var warnings := PackedStringArray()
	var native_positions := {}
	var native_states := {}
	# Native ids an engine token actually runs (a native entry with a pass script is
	# dispatched by the addon instead).
	var native_tokens := {}
	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry == null:
			warnings.append("Pass list contains an empty entry.")
			continue
		if _is_entry_enabled(pass_entry):
			for warning in pass_entry.get_configuration_warnings():
				warnings.append(warning)
			# The pass script (and its overlay) own the resource contract, so their
			# warnings belong to this entry too.
			var contract = _contract_source(pass_entry)
			if contract != null and contract != pass_entry:
				for warning in contract.get_configuration_warnings():
					warnings.append("Pass '%s': %s" % [_pass_display_name(pass_entry), warning])
		if pass_entry is BuiltinPass:
			var native := pass_entry as BuiltinPass
			if native.native_id < 0 or native.native_id >= native_pass_count():
				warnings.append("Native pass '%s' has invalid native id %d." % [native.resource_name, native.native_id])
				continue
			# A resource authored against an older pass set keeps its old numbering, and
			# the entry name is the only evidence of it that survives: the entry that was
			# pass 0 is still called "VT Pass" while the engine's pass 0 is something
			# else. Nothing renumbers a schedule silently, so say which entry disagrees
			# with the engine's set - the alternative is a frame that runs a pass in a
			# slot the author never meant.
			if not native.resource_name.is_empty():
				for definition in native_pass_definitions():
					if int(definition["id"]) != native.native_id and String(definition["name"]) == native.resource_name:
						warnings.append("Native entry id %d is named '%s', which is the engine's pass %d: this renderer was authored against an older pass set. Build the pass list on a current FENG renderer instead of editing this one." % [native.native_id, native.resource_name, int(definition["id"])])
						break
			if native_positions.has(native.native_id):
				warnings.append("Native pass id %d appears more than once; schedule was not changed." % native.native_id)
			else:
				native_positions[native.native_id] = i
				native_states[native.native_id] = _is_entry_enabled(native)
				if _is_entry_enabled(native) and not _is_scripted(native):
					native_tokens[native.native_id] = true

	# A pass script may run a mandatory entry's work itself and declare it in
	# provides_native_ids; such an entry is provided rather than missing.
	var provided_natives := _provided_native_ids()
	for mandatory_id in mandatory_native_ids():
		if provided_natives.has(mandatory_id):
			continue
		if not native_positions.has(mandatory_id):
			warnings.append("Required native pass '%s' (id %d) is missing; re-add the entry or declare it in a custom pass's provides_native_ids." % [native_name(mandatory_id), mandatory_id])
		elif not native_states[mandatory_id]:
			warnings.append("Required native pass '%s' (id %d) is disabled; enable it or declare it in a custom pass's provides_native_ids." % [native_name(mandatory_id), mandatory_id])

	# Only ids declared by a custom pass are checked here: a native entry providing
	# its own id through a pass script is the normal case, not duplicated work.
	for provided_id in _declared_provided_ids():
		if not is_valid_native_id(provided_id):
			warnings.append("A custom pass declares provides_native_ids %d, which is not a native pass id." % provided_id)
		elif native_tokens.has(provided_id):
			# Both the entry and a custom pass would run the same work.
			warnings.append("Native pass '%s' (id %d) is declared as provided by a custom pass but its own entry is still enabled; disable the entry or drop the declaration." % [native_name(provided_id), provided_id])

	# Only enabled entries participate in dependency order checks. Disabled
	# optional operations can therefore be removed from a frame intentionally.
	for edge in native_order_edges():
		var before_id: int = edge[0]
		var after_id: int = edge[1]
		if not native_positions.has(before_id) or not native_positions.has(after_id):
			continue
		if not native_states[before_id] or not native_states[after_id]:
			continue
		if native_positions[before_id] > native_positions[after_id]:
			warnings.append("Native pass '%s' must precede '%s'; authored order was retained and the previous valid schedule remains active." % [native_name(before_id), native_name(after_id)])

	warnings.append_array(_validate_custom_contracts(native_positions, native_states))
	return _unique_warnings(warnings)

func _native_name(native_id: int) -> String:
	return native_name(native_id)

func _validate_custom_contracts(native_positions: Dictionary, native_states: Dictionary) -> PackedStringArray:
	var warnings := PackedStringArray()
	# Only a custom declaration can stand in for a native entry here: a native entry
	# with a pass script still has a list position, which is what the checks below
	# compare against.
	var provided_natives := _declared_provided_ids()
	var output_producers := {}
	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry == null or pass_entry is BuiltinPass or not pass_entry.enabled:
			continue
		for output in pass_entry.outputs:
			if output == null or output.name == &"":
				continue
			if output_producers.has(output.name):
				warnings.append("Output texture '%s' is produced by more than one pass." % output.name)
			else:
				output_producers[output.name] = {"index": i, "enabled": pass_entry.enabled}

	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry == null or pass_entry is BuiltinPass or not pass_entry.enabled:
			continue
		if not pass_entry.enabled:
			continue
		for input in pass_entry.inputs:
			if input == null:
				continue
			if input.source == PassBase.TextureInput.Source.PIPELINE:
				if not output_producers.has(input.custom_name):
					warnings.append("Pass '%s' references pipeline texture '%s', but no pass produces it." % [_pass_display_name(pass_entry), input.custom_name])
				else:
					var producer: Dictionary = output_producers[input.custom_name]
					if not producer["enabled"]:
						warnings.append("Pass '%s' reads pipeline texture '%s' from a disabled producer." % [_pass_display_name(pass_entry), input.custom_name])
					elif producer["index"] >= i and not (producer["index"] == i and input.binding_type == PassBase.TextureInput.BindingType.STORAGE_IMAGE):
						# A storage image declaration may double as this pass's output
						# binding; sampled self reads remain invalid.
						warnings.append("Pass '%s' reads pipeline texture '%s' before its producer; reorder the authored list." % [_pass_display_name(pass_entry), input.custom_name])
			var required_native := _required_native_for_input(input)
			if required_native < 0:
				continue
			if provided_natives.has(required_native):
				# The pass declares it provides this entry itself, so its own list
				# position is the contract rather than the built-in entry's.
				pass
			elif not native_positions.has(required_native) or not native_states.get(required_native, false):
				warnings.append("Pass '%s' requires native '%s' for its texture input, but that operation is disabled or missing." % [_pass_display_name(pass_entry), _native_name(required_native)])
			elif native_positions[required_native] >= i:
				warnings.append("Pass '%s' reads a texture before native '%s'; move it after that operation." % [_pass_display_name(pass_entry), _native_name(required_native)])
			if input.source == PassBase.TextureInput.Source.COLOR and native_positions.has(15) and native_states.get(15, false) and native_positions[15] < i:
				warnings.append("Pass '%s' reads Color after Post Process / Tonemap; writes to the internal HDR color are no longer presented." % _pass_display_name(pass_entry))
	return warnings

func _required_native_for_input(input) -> int:
	match input.source:
		PassBase.TextureInput.Source.COLOR:
			return 2
		PassBase.TextureInput.Source.DEPTH, PassBase.TextureInput.Source.NORMAL_ROUGHNESS, PassBase.TextureInput.Source.ALBEDO, PassBase.TextureInput.Source.ORM, PassBase.TextureInput.Source.EMISSION:
			return 0
	return -1

func _pass_display_name(pass_entry: PassBase) -> String:
	if pass_entry.resource_name != "":
		return pass_entry.resource_name
	return pass_entry.get_class()

func _ensure_custom_identity(pass_entry: PassBase, ordinal: int) -> void:
	if pass_entry.stable_id != "":
		return
	var shader = pass_entry.get("shader_file")
	var identity := ""
	if shader != null and shader.resource_path != "":
		identity = shader.resource_path
	elif pass_entry.resource_path != "":
		identity = pass_entry.resource_path
	else:
		identity = "instance:%d" % pass_entry.get_instance_id()
	pass_entry.stable_id = "custom:%s:%d" % [identity, ordinal]

func _unique_warnings(warnings: PackedStringArray) -> PackedStringArray:
	var result := PackedStringArray()
	var seen := {}
	for warning in warnings:
		if warning == "" or seen.has(warning):
			continue
		seen[warning] = true
		result.append(warning)
	return result

func get_configuration_warnings() -> PackedStringArray:
	_ensure_pipeline_initialized(false)
	_last_validation_warnings = _validate_schedule()
	return _last_validation_warnings
