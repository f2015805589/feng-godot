extends SceneTree
## Inspector aliases must persist on the real implementation and reach native ID 0.

const ShadowPass = preload("res://addons/feng-render-pipeline/passes/native/shadow_precompute_pass.gd")
const BuiltinPass = preload("res://addons/feng-render-pipeline/passes/builtin_pass.gd")
const Resolver = preload("res://addons/feng-render-pipeline/pipeline/parameter_resolver.gd")

var checks := 0
var failures := 0
var changes := 0

func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func editable(resource: Resource, key: String) -> bool:
	for property in resource.get_property_list():
		if property.name == key:
			return (int(property.usage) & PROPERTY_USAGE_EDITOR) != 0
	return false

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var implementation := ShadowPass.new()
	var entry := BuiltinPass.new(0, "Shadow Precompute")
	entry.implementation = implementation
	entry.changed.connect(func(): changes += 1)
	require(entry.ensure_frp_contract(), "Old stock wrapper label migrates")
	require(entry.resource_name == "Shadow Pass", "Pipeline shows Shadow Pass")
	require(implementation.resource_name == "Shadow Pass", "Implementation has same name")
	require(not editable(entry, "implementation"), "No extra implementation expansion required")
	for key in ShadowPass.SHADOW_DEFAULTS:
		require(editable(entry, key), "Direct editable shadow field: " + key)
		require(entry.get(key) == ShadowPass.SHADOW_DEFAULTS[key], "Default: " + key)
		require(entry.property_can_revert(key), "Revert available: " + key)
		require(entry.property_get_revert(key) == ShadowPass.SHADOW_DEFAULTS[key], "Revert value: " + key)
	entry.set("cascade_4_distance", 160.0)
	entry.set("shadow_bias", 0.23)
	entry.set("pcss_angular_diameter", 0.75)
	require(changes >= 3, "Direct Inspector changes notify the renderer")
	require(implementation.cascade_4_distance == 160.0, "Alias edits implementation")
	var parameters := Resolver.authored([entry])
	require(parameters.has(0), "Settings address native pass 0")
	require(parameters[0]["cascade_4_distance"] == 160.0, "Meter endpoint reaches renderer")
	require(parameters[0]["shadow_bias"] == 0.23, "Bias reaches renderer")
	require(parameters[0]["pcss_angular_diameter"] == 0.75, "PCSS reaches renderer")
	entry.set("reserve_object_shadow_slot", true)
	require(implementation.get_csm_cascade_count() == 3, "Reserve one of four slots")
	require(not editable(entry, "cascade_4_distance"), "Reserved slot is not a CSM distance")
	require(editable(entry, "cascade_3_distance"), "Third CSM distance stays visible")
	entry.set("cascade_count", 2)
	require(implementation.get_csm_cascade_count() == 1, "Two slots leave one CSM")
	require(not editable(entry, "cascade_2_distance"), "Inactive cascade hidden")
	entry.set("shadow_filter", 1)
	require(not editable(entry, "pcss_angular_diameter"), "PCF hides PCSS-only angle")
	require(editable(entry, "shadow_blur"), "PCF filter size stays editable")
	entry.set("shadow_filter", 0)
	require(not editable(entry, "shadow_blur"), "Hard shadows hide soft filtering")
	require(editable(entry, "shadow_bias"), "Hard shadows retain depth bias")
	var path := "res://shadow_pass_roundtrip.tres"
	require(ResourceSaver.save(entry, path) == OK, "Save settings")
	var saved := FileAccess.get_file_as_string(path)
	require(saved.count("shadow_bias =") == 1, "No duplicate serialized aliases")
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	require(loaded != null, "Reload settings")
	if loaded != null:
		require(loaded.get("shadow_bias") == 0.23, "Bias survives reload")
		require(loaded.get("cascade_4_distance") == 160.0, "Hidden distance survives reload")
		require(loaded.get("reserve_object_shadow_slot"), "Reservation survives reload")
		require(not editable(loaded, "cascade_2_distance"), "Reload preserves conditional visibility")
	entry.resource_name = "My Character Shadows"
	require(not entry.ensure_frp_contract(), "Custom pass label preserved")
	entry.implementation = null
	require(not editable(entry, "shadow_bias"), "Cleared implementation removes aliases")
	require(editable(entry, "implementation"), "Custom implementation remains assignable")
	print("SHADOW_PASS_SETTINGS checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
