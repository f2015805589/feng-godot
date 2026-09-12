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
const PIPELINE_SCHEMA_VERSION := 3
const MANAGER_TOKEN := -1
const NATIVE_PASS_COUNT := 17

## Native FRP operations. These are executable grouped renderer boundaries,
## rather than a list of every draw or GPU dispatch inside the renderer.
const NATIVE_PASS_DEFINITIONS := [
	{"id": 0, "name": "GBuffer"},
	{"id": 1, "name": "Lighting Preparation"},
	{"id": 2, "name": "Deferred Lighting"},
	{"id": 3, "name": "Opaque Forward Fallback"},
	{"id": 4, "name": "Motion Vectors"},
	{"id": 5, "name": "Opaque Resolve"},
	{"id": 6, "name": "Debug Geometry"},
	{"id": 7, "name": "Sky"},
	{"id": 8, "name": "Sky Resolve"},
	{"id": 9, "name": "Subsurface + Specular Merge"},
	{"id": 10, "name": "Screen/Depth Copy"},
	{"id": 11, "name": "Transparent"},
	{"id": 12, "name": "Final Resolve"},
	{"id": 13, "name": "SSIL/SSR History Copy"},
	{"id": 14, "name": "Temporal AA / Upscale"},
	{"id": 15, "name": "Post Process / Tonemap"},
	{"id": 16, "name": "VT Pass"},
]

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

## Native dependencies are order constraints. A disabled optional pass_entry does
## not invalidate another enabled pass_entry; if both entries are enabled, the
## prerequisite must occur first. This lets users disable fallback, motion,
## sky, history, or temporal work without silently adding it back.
const NATIVE_ORDER_EDGES := [
	[16, 0],
	[0, 1], [1, 2],
	[2, 3], [2, 4], [2, 5], [2, 6], [2, 7], [2, 8], [2, 9], [2, 10], [2, 11], [2, 12],
	[3, 5], [4, 5],
	[7, 8],
	[5, 9], [8, 9],
	[9, 10],
	[10, 11],
	[3, 12], [4, 12], [5, 12], [6, 12], [7, 12], [8, 12], [9, 12], [10, 12], [11, 12],
	[12, 13], [12, 14], [12, 15],
	[13, 14],
	[14, 15],
]

const MANDATORY_NATIVE_IDS := [0, 1, 2, 12, 15, 16]

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
	var seeded: Array[PassBase] = []
	seeded.append(_make_native_pass(16, "VT Pass"))
	for definition in NATIVE_PASS_DEFINITIONS:
		if definition["id"] <= 13:
			seeded.append(_make_native_pass(definition["id"], definition["name"]))
	for entry in DEFAULT_LIBRARY_ENTRIES:
		var template = load(LIBRARY_DIR + "/" + entry["path"])
		if template == null or not template is PassBase:
			continue
		var instance := template.duplicate(true) as PassBase
		_configure_library_pass(instance, entry)
		seeded.append(instance)
	for definition in NATIVE_PASS_DEFINITIONS:
		if definition["id"] >= 14 and definition["id"] != 16:
			seeded.append(_make_native_pass(definition["id"], definition["name"]))
	_passes = seeded

func _make_native_pass(native_id: int, display_name: String) -> PassBase:
	var pass_entry := BuiltinPass.new(native_id, display_name) as PassBase
	pass_entry.stable_id = "native:%d" % native_id
	pass_entry.resource_name = display_name
	return pass_entry

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
	if not _has_native_entries():
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
	if _pipeline_schema_version < PIPELINE_SCHEMA_VERSION and not _has_native_entries():
		changed = _migrate_legacy_passes() or changed
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

func _normalize_native_entries() -> bool:
	var changed := false
	var has_vt_pass := false
	for pass_entry in _passes:
		if not pass_entry is BuiltinPass:
			continue
		var native := pass_entry as BuiltinPass
		if native.native_id == 16:
			has_vt_pass = true
		if native.native_id >= 0 and native.native_id < NATIVE_PASS_COUNT:
			if native.stable_id != "native:%d" % native.native_id:
				native.stable_id = "native:%d" % native.native_id
				changed = true
			var definition: Variant = _native_definition(native.native_id)
			if definition != null and native.resource_name == "":
				native.resource_name = definition["name"]
				changed = true
		# Do not silently repair an invalid or duplicate native ID. The warning
		# and last-valid-schedule behavior makes the authored error reviewable.
	if not has_vt_pass:
		# Resources saved with the 16-pass schema already have stable native ids
		# and user-authored custom entries. Add only the new id 16 entry at the
		# GBuffer boundary so those ids and relative custom order remain intact.
		var gbuffer_index := _find_native_index(0)
		_passes.insert(gbuffer_index if gbuffer_index >= 0 else 0, _make_native_pass(16, "VT Pass"))
		changed = true
	return changed

func _migrate_legacy_passes() -> bool:
	var legacy: Array[PassBase] = _passes.duplicate()
	var buckets := {}
	for anchor in range(-1, NATIVE_PASS_COUNT):
		buckets[anchor] = []
	for ordinal in legacy.size():
		var pass_entry := legacy[ordinal]
		if pass_entry == null:
			continue
		_ensure_custom_identity(pass_entry, ordinal)
		var anchor := _legacy_anchor_for_pass(pass_entry)
		buckets[anchor].append(pass_entry)
	var migrated: Array[PassBase] = []
	for pass_entry in buckets[-1]:
		migrated.append(pass_entry)
	migrated.append(_make_native_pass(16, "VT Pass"))
	for definition in NATIVE_PASS_DEFINITIONS:
		var native_id: int = definition["id"]
		if native_id == 16:
			continue
		migrated.append(_make_native_pass(native_id, definition["name"]))
		for pass_entry in buckets[native_id]:
			migrated.append(pass_entry)
	_set_passes(migrated, false)
	return true

func _legacy_anchor_for_pass(pass_entry: PassBase) -> int:
	# The old stage remains useful only for this one-time migration. Existing
	# relative order within every stage is retained by bucket append order.
	match pass_entry.stage:
		CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_GBUFFER, CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_OPAQUE:
			return -1
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_GBUFFER:
			return 0
		CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_LIGHTING:
			return 1
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_LIGHTING:
			return 2
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE:
			return 5
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_SKY:
			return 8
		CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT:
			return 10
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
			return 13
	return 13

func _native_definition(native_id: int):
	for definition in NATIVE_PASS_DEFINITIONS:
		if definition["id"] == native_id:
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
		if _is_library_synced(entry) and not _has_matching_library_pass(entry):
			var was_deleted := _is_library_deleted(entry)
			_mark_library_deleted(entry)
			if not was_deleted:
				changed = true

	for entry in DEFAULT_LIBRARY_ENTRIES:
		if _is_library_deleted(entry):
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
	# The first native operation after the default library anchor is Temporal
	# AA. Insertions before that boundary preserve every existing entry's
	# relative order and keep default entries ordered while syncing.
	var temporal_index := _find_native_index(14)
	if temporal_index < 0:
		var history_index := _find_native_index(13)
		temporal_index = history_index + 1 if history_index >= 0 else _passes.size()
	var insert_index := temporal_index
	var new_order := _default_library_order(pass_entry.stable_id)
	var next_default := -1
	var next_order := 100000
	var previous_default := -1
	var previous_order := -1
	for i in range(temporal_index):
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
		# Keep the last valid native schedule, but suspend our custom effects
		# until the authored resource contracts are valid again.
		if compositor.compositor_effects.has(_manager):
			for effect in compositor.compositor_effects:
				if effect != _manager:
					RenderingServer.compositor_effect_set_enabled(effect.get_rid(), false)
			_manager.passes.clear()
		for warning in candidate_warnings:
			push_warning("FengRenderer: " + warning)
		return

	for pass_entry in _passes:
		if pass_entry != null:
			# This must happen before compositor effects are uploaded so the native
			# renderer sees accurate attachment requirements immediately.
			pass_entry._refresh_resource_flags()
			RenderingServer.compositor_effect_set_enabled(pass_entry.get_rid(), pass_entry.enabled)

	var effects: Array[CompositorEffect] = []
	effects.append(_manager)
	var custom_effects: Array[CompositorEffect] = []
	for pass_entry in _passes:
		if pass_entry == null or pass_entry is BuiltinPass:
			continue
		custom_effects.append(pass_entry)
		effects.append(pass_entry)
	# Keep disabled custom effects in both arrays. The native scheduler checks
	# enabled at token execution time, while stable effect indices remain valid.
	_manager.passes = custom_effects
	compositor.compositor_effects = effects
	var tokens := _build_schedule_tokens()
	_set_native_schedule(compositor, tokens)
	_last_valid_schedule = tokens

func _set_native_schedule(compositor: Compositor, tokens: PackedInt32Array) -> bool:
	if not RenderingServer.has_method("compositor_set_frp_pipeline"):
		if not _warned_missing_native_api:
			push_warning("FengRenderer: native FRP schedule API is unavailable; custom effects use legacy callback stages until the engine is rebuilt.")
			_warned_missing_native_api = true
		return false
	var names := PackedStringArray(["Texture Preparation"])
	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry == null or (pass_entry is BuiltinPass and not pass_entry.enabled):
			continue
		var display_name := pass_entry.resource_name
		if display_name.is_empty():
			display_name = str(pass_entry.stable_id) if not pass_entry.stable_id.is_empty() else "Custom Pass"
		names.append("%02d %s" % [i, display_name])
	# The addon may reload while an older editor binary is still running.
	for method in RenderingServer.get_method_list():
		if method.name == "compositor_set_frp_pipeline":
			if method.args.size() >= 3:
				RenderingServer.call("compositor_set_frp_pipeline", compositor.get_rid(), tokens, names)
			else:
				RenderingServer.call("compositor_set_frp_pipeline", compositor.get_rid(), tokens)
			break
	return true

func _build_schedule_tokens() -> PackedInt32Array:
	var tokens: Array[int] = [MANAGER_TOKEN]
	var custom_index := 1 # compositor_effects[0] is the manager.
	for pass_entry in _passes:
		if pass_entry == null:
			continue
		if pass_entry is BuiltinPass:
			var native := pass_entry as BuiltinPass
			if native.enabled:
				tokens.append(native.native_id)
			continue
		# Every custom pass_entry occupies an effect slot, including disabled entries.
		tokens.append(-(custom_index + 1))
		custom_index += 1
	return PackedInt32Array(tokens)

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
	for i in _passes.size():
		var pass_entry := _passes[i]
		if pass_entry == null:
			warnings.append("Pass list contains an empty entry.")
			continue
		if pass_entry.enabled:
			for warning in pass_entry.get_configuration_warnings():
				warnings.append(warning)
		if pass_entry is BuiltinPass:
			var native := pass_entry as BuiltinPass
			if native.native_id < 0 or native.native_id >= NATIVE_PASS_COUNT:
				warnings.append("Native pass '%s' has invalid native id %d." % [native.resource_name, native.native_id])
				continue
			if native_positions.has(native.native_id):
				warnings.append("Native pass id %d appears more than once; schedule was not changed." % native.native_id)
			else:
				native_positions[native.native_id] = i
				native_states[native.native_id] = native.enabled

	for mandatory_id in MANDATORY_NATIVE_IDS:
		if not native_positions.has(mandatory_id):
			warnings.append("Required native pass '%s' (id %d) is missing; schedule was not changed." % [_native_name(mandatory_id), mandatory_id])
		elif not native_states[mandatory_id]:
			warnings.append("Required native pass '%s' (id %d) is disabled; this renderer requires this operation to remain enabled." % [_native_name(mandatory_id), mandatory_id])

	# Only enabled entries participate in dependency order checks. Disabled
	# optional operations can therefore be removed from a frame intentionally.
	for edge in NATIVE_ORDER_EDGES:
		var before_id: int = edge[0]
		var after_id: int = edge[1]
		if not native_positions.has(before_id) or not native_positions.has(after_id):
			continue
		if not native_states[before_id] or not native_states[after_id]:
			continue
		if native_positions[before_id] > native_positions[after_id]:
			warnings.append("Native pass '%s' must precede '%s'; authored order was retained and the previous valid schedule remains active." % [_native_name(before_id), _native_name(after_id)])

	warnings.append_array(_validate_custom_contracts(native_positions, native_states))
	return _unique_warnings(warnings)

func _native_name(native_id: int) -> String:
	var definition: Variant = _native_definition(native_id)
	return "native id %d" % native_id if definition == null else definition["name"]

func _validate_custom_contracts(native_positions: Dictionary, native_states: Dictionary) -> PackedStringArray:
	var warnings := PackedStringArray()
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
			if not native_positions.has(required_native) or not native_states.get(required_native, false):
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
