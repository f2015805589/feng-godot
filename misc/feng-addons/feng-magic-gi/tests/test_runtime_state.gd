extends SceneTree
## Headless producer/consumer contracts for the per-volume emission cache.

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const State = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime_state.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Binding = preload("res://addons/feng-magic-gi/feng_magic_gi_emitter_binding.gd")

var failures := 0
var checks := 0

func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var volume := Volume.new()
	volume.show_probes = false
	scene.add_child(volume)
	var emitter := MeshInstance3D.new()
	emitter.name = "Emitter"
	emitter.mesh = BoxMesh.new()
	var material := StandardMaterial3D.new()
	material.emission_enabled = true
	material.emission = Color.RED
	if ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false):
		material.emission_intensity = 1.0
	emitter.material_override = material
	scene.add_child(emitter)
	var data := Data.new()
	data.positions = PackedVector3Array([Vector3.ZERO])
	data.emitter_keys = PackedStringArray([Binding.make_key(scene, emitter, 0)])
	data.emitter_static_signatures = PackedInt64Array([Binding.static_signature(emitter, 0, material)])
	data.emitter_transport = PackedFloat32Array([1, 1, 1, 0, 0, 0])
	data.bake_version = 1
	var state := State.new()
	require(state.lighting != null and state.emission_helper != null, "state must own its helpers from construction")
	state.attach(volume)
	require(state.update_emission_snapshot(volume, data, 1), "first emission publication must update")
	require(state.emission_payload == PackedFloat32Array([1, 0, 0]), "live red source must compose one RGB response per probe")
	require(not state.update_emission_snapshot(volume, data, 1), "unchanged source must reuse its cached response")
	material.emission = Color.BLUE
	require(state.update_emission_snapshot(volume, data, 1), "live source change must invalidate the response")
	require(state.emission_payload == PackedFloat32Array([0, 0, 1]), "live blue source must preserve channel order")
	material.emission_enabled = false
	require(state.update_emission_snapshot(volume, data, 1), "disabling a source must invalidate the response")
	require(state.emission_payload == PackedFloat32Array([0, 0, 0]), "disabled source must compose a correctly sized zero response")

	var replacement: Data = data.duplicate(true)
	require(state.update_emission_snapshot(volume, replacement, 1), "replacing bake data must invalidate an unchanged zero response")
	require(state.update_emission_snapshot(volume, replacement, 2), "new bake version must invalidate an unchanged zero response")

	var zero := PackedFloat32Array([0, 0, 0])
	for values in [PackedFloat32Array(), PackedFloat32Array([-1, 0, 0, 0, 0, 0]),
			PackedFloat32Array([NAN, 0, 0, 0, 0, 0]), PackedFloat32Array([INF, 0, 0, 0, 0, 0])]:
		require(data.compose_emission(values) == zero, "invalid external source arrays must return finite zeros with the probe shape")
	data.emitter_transport = PackedFloat32Array([1.0e30, 1, 1, 0, 0, 0])
	require(data.compose_emission(PackedFloat32Array([1.0e30, 0, 0, 0, 0, 0])) == zero,
		"finite source/transport multiplication overflow must return finite zeros")
	data.emitter_transport.clear()
	require(data.compose_emission(PackedFloat32Array([1, 0, 0, 0, 0, 0])) == zero,
		"malformed transport shape must return finite zeros")
	data.emitter_keys.clear()
	require(data.compose_emission(PackedFloat32Array()) == zero,
		"a bake without emitters must still produce one RGB value per probe")
	scene.free()
	require(state.get_volume() == null, "state must not keep an exited volume alive")
	print("MAGIC_GI_RUNTIME_STATE checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
