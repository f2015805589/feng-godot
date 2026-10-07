extends SceneTree
## Matrix over managed-library seed/restore/legacy/tombstone semantics.
## Optional FRP_LIBRARY_SNAPSHOT records deterministic results for before/after
## comparison; no engine or GPU rendering is required after addon import.

const Renderer = preload("res://addons/feng-render-pipeline/renderer.gd")
const Base = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const Library = preload("res://addons/feng-render-pipeline/pipeline/library_manager.gd")
const MANAGED := [&"library:eye_adaptation", &"library:color_grade"]
const FRESH_IDS := ["native:0", "native:1", "native:2", "library:cloud_shadow", "native:3", "library:magic_gi", "native:4", "library:volumetric_cloud", "library:height_fog", "library:cloud_trace", "native:5", "native:6", "library:eye_adaptation", "native:8", "library:color_grade", "native:7", "library:debug_buffers"]
var results: Array = []
var failed := false

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)

func _initialize() -> void:
	call_deferred("run")

func find_entry(entries: Array, key: StringName):
	for entry in entries:
		if entry != null and entry.stable_id == key:
			return entry
	return null

func ids(entries: Array) -> Array:
	var result := []
	for entry in entries:
		result.append(String(entry.stable_id) if entry != null else "null")
	return result

func snapshot(entries: Array) -> Array:
	var result := []
	for entry in entries:
		if entry == null:
			result.append(null)
			continue
		var key := String(entry.stable_id)
		# The loader may give an id-less legacy resource a temporary custom UID.
		# Its source identifies it deterministically until the managed ID is restored.
		if key.begins_with("custom:") and entry.get("shader_file") != null:
			key = "legacy:" + entry.shader_file.resource_path
		var state := {"id": key, "name": entry.resource_name, "enabled": entry.enabled}
		if entry.get("implementation") != null:
			state["implementation_enabled"] = entry.implementation.enabled
		if entry.get("parameters") != null:
			state["parameters"] = str(entry.parameters)
		result.append(state)
	return result

func run() -> void:
	var fresh := Renderer.new()
	check(ids(fresh.passes) == FRESH_IDS, "fresh managed/native order changed")
	for entry in fresh.passes:
		check(entry.enabled == (entry.stable_id != &"library:debug_buffers"), "fresh enabled state changed")
	results.append(snapshot(fresh.passes))
	var cases := 0
	for missing_mask in range(4):
		for has_bloom in [false, true]:
			for tombstones in [false, true]:
				for legacy_grade in [false, true]:
					var renderer := Renderer.new()
					var entries: Array[Base] = renderer.passes.duplicate()
					var kept := {}
					var deleted_ids: Array[String] = []
					var deleted_paths: Array[String] = []
					for index in MANAGED.size():
						var entry = find_entry(entries, MANAGED[index])
						if (missing_mask & (1 << index)) != 0:
							entries.erase(entry)
							if tombstones:
								var definition = Library.manifest_entry(MANAGED[index])
								deleted_ids.append(String(MANAGED[index]))
								deleted_paths.append(definition.path)
						else:
							entry.enabled = false
							if index == 1:
								entry.parameters = Vector4(0.8, 1.2, 1.4, 0.9)
							kept[MANAGED[index]] = entry
							# Intentionally authored placement must not be normalized away.
							entries.erase(entry)
							entries.push_front(entry)
					if not has_bloom:
						entries.erase(find_entry(entries, &"native:8"))
					var custom := Base.new()
					custom.stable_id = &"test:custom"
					custom.enabled = false
					entries.insert(2, custom)
					entries.insert(3, null)
					renderer.passes = entries
					# Treat absent non-tombstoned library entries as unsynchronized,
					# the path used when opening an older resource with new defaults.
					renderer._synced_library = []
					renderer._synced_library_ids = []
					renderer._deleted_library = deleted_paths
					renderer._deleted_library_ids = deleted_ids
					if legacy_grade and kept.has(&"library:color_grade"):
						kept[&"library:color_grade"].stable_id = &""
					var before_custom_index := renderer._passes.find(custom)
					for iteration in 3:
						var actual: Array = renderer.passes
						results.append(snapshot(actual))
						for key in kept:
							check(actual.has(kept[key]) and not kept[key].enabled, "sync replaced an authored resource/switch")
						if kept.has(&"library:color_grade"):
							check(kept[&"library:color_grade"].parameters == Vector4(0.8, 1.2, 1.4, 0.9), "sync changed authored grading")
						for index in MANAGED.size():
							if (missing_mask & (1 << index)) != 0:
								check((find_entry(actual, MANAGED[index]) == null) == tombstones, "sync lost a tombstone or missing default")
						check(actual.has(custom) and actual.has(null), "sync removed custom/null entries")
						check(find_entry(actual, &"native:8") != null if has_bloom else find_entry(actual, &"native:8") == null, "sync changed Bloom ownership")
					check(before_custom_index >= 0, "custom control entry was missing")
					cases += 1
	# Save/load and user deletion still use the same public renderer protocol.
	var saved := Renderer.new()
	find_entry(saved.passes, &"library:color_grade").enabled = false
	find_entry(saved.passes, &"native:6").implementation.enabled = false
	var path := "user://library_placement_saved.tres"
	check(ResourceSaver.save(saved, path) == OK, "placement fixture did not save")
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check(loaded != null, "placement fixture did not reload")
	check(not find_entry(loaded.passes, &"library:color_grade").enabled, "save/load changed authored grade switch")
	check(not find_entry(loaded.passes, &"native:6").implementation.enabled, "save/load changed nested TAA switch")
	results.append(snapshot(loaded.passes))
	var output := OS.get_environment("FRP_LIBRARY_SNAPSHOT")
	if not output.is_empty():
		var file := FileAccess.open(output, FileAccess.WRITE)
		check(file != null, "snapshot file could not be opened")
		if file != null:
			file.store_string(JSON.stringify(results, "\t", true))
	if failed:
		quit(1)
	else:
		print("PASS FRP managed-library placement matrix: %d restore/legacy/tombstone cases, fresh defaults and saved switches" % cases)
		quit(0)
