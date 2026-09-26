@tool
class_name FengLibraryManager
extends RefCounted
## The addon's library of pre-packaged passes: its manifest, where a template is
## inserted, and the synchronization that keeps a pipeline resource in step with it.
##
## Every function works on the pipeline's own state — the pass list and the persisted
## sync/tombstone arrays — passed in by the caller. The manager therefore holds no
## reference to the renderer: the renderer and the editor's undo snapshot drive it the
## same way, and nothing reaches into another object's storage.

const NativeSpec = preload("native_spec.gd")
const PassBase = preload("../passes/pass_base.gd")
const BuiltinPass = preload("../passes/builtin_pass.gd")

## The library's manifest of pre-packaged passes, in insertion order.
const DEFAULT_LIBRARY_ENTRIES := [
	{"id": "library:tint", "path": "tint/tint.tres", "name": "Tint"},
	{"id": "library:blur_horizontal", "path": "blur/blur_h.tres", "name": "Blur Horizontal"},
	{"id": "library:blur_vertical", "path": "blur/blur_v.tres", "name": "Blur Vertical"},
	{"id": "library:fxaa", "path": "fxaa/fxaa.tres", "name": "FXAA"},
	{"id": "library:color_grade", "path": "color-grade/color_grade.tres", "name": "Color Grade"},
	{"id": "library:bloom_downsample", "path": "bloom-lite/bloom_downsample.tres", "name": "Bloom Downsample"},
	{"id": "library:bloom_blur", "path": "bloom-lite/bloom_blur.tres", "name": "Bloom Blur"},
	{"id": "library:bloom_composite", "path": "bloom-lite/bloom_composite.tres", "name": "Bloom Composite"},
	{"id": "library:magic_gi", "path": "magic-gi/magic_gi.tres", "name": "Magic GI"},
]

## The library entries a fresh pipeline seeds. The rest are templates the Library menu
## adds: they never enter a pipeline on their own.
const DEFAULT_LIBRARY_SEEDED: Array[String] = [
	"library:color_grade",
]

static func load_template(entry: Dictionary) -> Variant:
	return load(FengAddonLayout.library_dir() + "/" + entry["path"])

## The manifest-relative path of a library template path, so a stored path and a
## manifest entry can be compared.
static func normalize_library_path(path: String) -> String:
	var normalized := path.replace("\\", "/")
	var prefix := FengAddonLayout.library_dir() + "/"
	if normalized.begins_with(prefix):
		return normalized.substr(prefix.length())
	return normalized

## The manifest entry a path (or a stable id) names, or null when the library has no
## such entry — a template a project dropped into the library itself.
static func manifest_for_path(path: String) -> Variant:
	var normalized := normalize_library_path(path)
	for entry in DEFAULT_LIBRARY_ENTRIES:
		if entry["path"] == normalized or entry["id"] == normalized:
			return entry
	return null

## Position of an entry in the manifest, or -1 when it is not a library entry.
static func default_library_order(stable_id: StringName) -> int:
	for i in DEFAULT_LIBRARY_ENTRIES.size():
		if DEFAULT_LIBRARY_ENTRIES[i]["id"] == stable_id:
			return i
	return -1

static func configure_library_pass(pass_entry: PassBase, entry: Dictionary) -> void:
	pass_entry.stable_id = entry["id"]
	pass_entry.resource_name = entry["name"]

## Whether the entry is recorded as already present in the pipeline, by path or by
## stable id.
static func is_synced(entry: Dictionary, synced: Array, synced_ids: Array) -> bool:
	var path: String = entry.get("path", "")
	var stable_id: String = entry.get("id", "")
	return synced.has(path) or synced.has(stable_id) or synced_ids.has(stable_id)

## Whether the entry was explicitly removed from the pipeline. A tombstone keeps
## synchronization from adding it back.
static func is_deleted(entry: Dictionary, deleted: Array, deleted_ids: Array) -> bool:
	var path: String = entry.get("path", "")
	var stable_id: String = entry.get("id", "")
	return deleted.has(path) or deleted.has(stable_id) or deleted_ids.has(stable_id)

static func mark_synced(entry: Dictionary, synced: Array, synced_ids: Array, deleted: Array, deleted_ids: Array) -> void:
	var path: String = entry.get("path", "")
	var stable_id: String = entry.get("id", "")
	_append_unique(synced, path)
	_append_unique(synced_ids, stable_id)
	deleted.erase(path)
	deleted.erase(stable_id)
	deleted_ids.erase(stable_id)

static func mark_deleted(entry: Dictionary, deleted: Array, deleted_ids: Array) -> void:
	_append_unique(deleted, entry.get("path", ""))
	_append_unique(deleted_ids, entry.get("id", ""))

static func _append_unique(values: Array, value: String) -> void:
	if value != "" and not values.has(value):
		values.append(value)

## Calculates the ordered insert index for a library pass: placed before Post Process,
## preserving relative order among library passes.
static func calculate_insert_index(passes: Array, stable_id: StringName) -> int:
	var post_process_index := passes.size()
	for i in passes.size():
		var pass_entry = passes[i]
		if pass_entry is BuiltinPass and pass_entry.native_id == NativeSpec.PASS_POST_PROCESS:
			post_process_index = i
			break

	var new_order := default_library_order(stable_id)
	if new_order < 0:
		return post_process_index

	var next_default := -1
	var next_order := 100000
	var previous_default := -1
	var previous_order := -1

	for i in range(post_process_index):
		var existing = passes[i]
		if existing == null:
			continue
		var existing_order := default_library_order(existing.stable_id)
		if existing_order < 0:
			continue
		if existing_order > new_order and existing_order < next_order:
			next_default = i
			next_order = existing_order
		if existing_order < new_order and existing_order > previous_order:
			previous_default = i
			previous_order = existing_order

	if next_default >= 0:
		return next_default
	elif previous_default >= 0:
		return previous_default + 1
	return post_process_index

## The custom pass an entry already has in the list: matched by stable id, or by the
## shader the template points at for a pass that predates stable ids.
static func find_matching_library_pass(passes: Array, entry: Dictionary, template = null):
	var stable_id: String = entry["id"]
	var shader_path := ""
	if template != null:
		var template_shader = template.get("shader_file")
		if template_shader != null:
			shader_path = template_shader.resource_path
	for pass_entry in passes:
		if pass_entry == null or pass_entry is BuiltinPass:
			continue
		if pass_entry.stable_id == stable_id:
			return pass_entry
		if shader_path != "":
			var pass_shader = pass_entry.get("shader_file")
			if pass_shader != null and pass_shader.resource_path == shader_path:
				return pass_entry
	return null

static func has_matching_library_pass(passes: Array, entry: Dictionary) -> bool:
	return _find_synced_library_pass(passes, entry) != null

## Current resources carry a stable ID. Loading a shader template just to find an
## already identified entry repeats import/resource work during camera setup.
## Legacy resources still use the original shader-path fallback.
static func _find_synced_library_pass(passes: Array, entry: Dictionary):
	var existing = find_matching_library_pass(passes, entry)
	if existing != null:
		return existing
	return find_matching_library_pass(passes, entry, load_template(entry))

## Brings the pass list in step with the manifest.
##
## An entry the pipeline was seeded with or has explicitly synced stays present (its
## identity and display name are repaired if needed), a tombstoned entry is left alone,
## and a template that is neither is left to the Library menu. Returns whether the list
## or the recorded state changed.
static func sync(passes: Array, synced: Array, synced_ids: Array, deleted: Array, deleted_ids: Array) -> bool:
	var changed := false

	# A managed entry whose pass is gone was removed by hand: record the tombstone, so
	# the pass below does not decide it is merely missing and add it back.
	for entry in DEFAULT_LIBRARY_ENTRIES:
		if not is_managed(entry, synced, synced_ids):
			continue
		if is_synced(entry, synced, synced_ids) and not has_matching_library_pass(passes, entry):
			var was_deleted := is_deleted(entry, deleted, deleted_ids)
			mark_deleted(entry, deleted, deleted_ids)
			if not was_deleted:
				changed = true

	for entry in DEFAULT_LIBRARY_ENTRIES:
		if is_deleted(entry, deleted, deleted_ids) or not is_managed(entry, synced, synced_ids):
			continue
		if is_synced(entry, synced, synced_ids):
			var synced_existing = _find_synced_library_pass(passes, entry)
			if synced_existing != null:
				if synced_existing.stable_id != entry["id"]:
					synced_existing.stable_id = entry["id"]
					changed = true
				if synced_existing.resource_name == "":
					synced_existing.resource_name = entry["name"]
					changed = true
			continue
		var template = load_template(entry)
		if template == null or not template is PassBase:
			continue
		var existing = find_matching_library_pass(passes, entry, template)
		if existing == null:
			var instance := template.duplicate(true) as PassBase
			configure_library_pass(instance, entry)
			instance.enabled = false
			passes.insert(calculate_insert_index(passes, instance.stable_id), instance)
			changed = true
		else:
			if existing.stable_id == "":
				existing.stable_id = entry["id"]
				changed = true
			if existing.resource_name == "":
				existing.resource_name = entry["name"]
				changed = true
		mark_synced(entry, synced, synced_ids, deleted, deleted_ids)
	return changed

## Whether synchronization owns an entry: one a fresh pipeline seeds, or one it recorded
## as added. The other templates belong to the Library menu alone.
static func is_managed(entry: Dictionary, synced: Array, synced_ids: Array) -> bool:
	return DEFAULT_LIBRARY_SEEDED.has(entry["id"]) or is_synced(entry, synced, synced_ids)
