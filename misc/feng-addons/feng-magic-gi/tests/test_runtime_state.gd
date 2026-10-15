extends SceneTree
## Headless producer/consumer contracts for the per-volume emission cache.

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const State = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime_state.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Binding = preload("res://addons/feng-magic-gi/feng_magic_gi_emitter_binding.gd")
const SceneTracker = preload("res://addons/feng-magic-gi/feng_magic_gi_scene_tracker.gd")

class SkyRuntime:
	static var snapshot: Dictionary = {}
	static func snapshot_for_world(_id: int) -> Dictionary:
		return snapshot

class CountingData extends FMagicGIData:
	var validations := 0
	func is_valid() -> bool:
		validations += 1
		return false

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
	var absolute_binding := Binding.resolve_binding(scene,
			str(emitter.get_path()) + "#surface=0")
	require(absolute_binding.get("node") == emitter,
		"legacy absolute emitter paths must resolve from the active SceneTree root")
	var detached_binding_root := Node3D.new()
	require(Binding.resolve_binding(detached_binding_root,
			"/root/Detached/Emitter#surface=0").is_empty(),
		"absolute emitter paths must be ignored while their scene root is detached")
	detached_binding_root.free()
	var data := Data.new()
	data.positions = PackedVector3Array([Vector3.ZERO])
	data.emitter_keys = PackedStringArray([Binding.make_key(scene, emitter, 0)])
	data.emitter_static_signatures = PackedInt64Array([Binding.static_signature(emitter, 0, material)])
	data.emitter_transport = PackedFloat32Array([1, 1, 1, 0, 0, 0])
	data.bake_version = 1
	var placement := FMagicGIPlacement.new()
	require(placement.collect(volume, true, true, true), "emitter geometry must collect")
	var emitters := placement.emitters
	require(emitters.keys == data.emitter_keys and emitters.static_signatures == data.emitter_static_signatures,
		"placement must expose the bake owner's bindings without a second copy")
	material.emission_enabled = false
	require(placement.collect(volume, true, true, true) and placement.emitters.keys.is_empty(),
		"recollection must replace the emitter owner and discard removed sources")
	require(emitters.keys.size() == 1, "recollection must not mutate a retained bake's emitter set")
	material.emission_enabled = true
	# Persisted source identity must survive editor reloads, where equivalent
	# Resource instances receive different ObjectIDs and signal revisions.
	var persisted_source_signature := SceneTracker.stable_scene_signature(volume)
	var archived_sampler_signature := (3 << 32) | 31
	require(Data.geometry_signature_matches(archived_sampler_signature, 31),
		"the persisted geometry word must remain comparable across sampler revisions")
	require(Data.sampler_revision_for_signature(archived_sampler_signature) == 3,
		"the persisted signature must retain its independent sampler revision")
	var current_sampler_signature := Data.signature_for_geometry(31)
	require(Data.sampler_revision_for_signature(current_sampler_signature) == Data.SAMPLER_REVISION,
		"new bake signatures must stamp the current sampler revision")
	require(not Data.geometry_signature_matches(archived_sampler_signature, 32),
		"the legacy signature comparison must still reject changed placement geometry")
	var original_mesh: Mesh = emitter.mesh
	var original_material: Material = emitter.material_override
	emitter.mesh = original_mesh.duplicate(true) as Mesh
	emitter.material_override = original_material.duplicate(true) as Material
	require(SceneTracker.stable_scene_signature(volume) == persisted_source_signature,
		"equivalent reloaded mesh/material resources must keep the stable source signature")
	var changed_box := emitter.mesh as BoxMesh
	changed_box.size.x += 0.25
	require(SceneTracker.stable_scene_signature(volume) != persisted_source_signature,
		"stable source signature must include actual mesh arrays, not only resource identity")
	changed_box.size.x -= 0.25
	var albedo_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	albedo_image.fill(Color(0.2, 0.4, 0.6, 1.0))
	var first_texture := ImageTexture.create_from_image(albedo_image)
	(emitter.material_override as BaseMaterial3D).albedo_texture = first_texture
	var textured_signature := SceneTracker.stable_scene_signature(volume)
	var equivalent_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	equivalent_image.fill(Color(0.2, 0.4, 0.6, 1.0))
	(emitter.material_override as BaseMaterial3D).albedo_texture = ImageTexture.create_from_image(equivalent_image)
	require(SceneTracker.stable_scene_signature(volume) == textured_signature,
		"equivalent ImageTexture instances must keep the stable source signature")
	var updated_texture := (emitter.material_override as BaseMaterial3D).albedo_texture as ImageTexture
	var quick_texture_signature := SceneTracker.quick_source_signature_uncached(volume)
	var changed_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	changed_image.fill(Color(0.8, 0.1, 0.3, 1.0))
	updated_texture.update(changed_image)
	require(SceneTracker.quick_source_signature_uncached(volume) != quick_texture_signature,
		"the session watcher must see ImageTexture.update change signals")
	(emitter.material_override as BaseMaterial3D).albedo_texture = ImageTexture.create_from_image(changed_image)
	require(SceneTracker.stable_scene_signature(volume) != textured_signature,
		"stable source signature must include ImageTexture pixel content")
	emitter.mesh = original_mesh
	emitter.material_override = original_material
	var checked := Volume.new()
	var counted := CountingData.new()
	checked.bake_data = counted
	checked.has_usable_bake()
	checked.bake_samples += 1
	checked.size *= 2.0
	checked.has_usable_bake()
	require(counted.validations == 1, "volume layout and bake quality must not revalidate unchanged saved data")
	counted.emit_changed()
	checked.has_usable_bake()
	require(counted.validations == 2, "resource changes must invalidate validation independently of layout")
	checked.free()
	var anchored_volume := Volume.new()
	anchored_volume.show_probes = false
	scene.add_child(anchored_volume)
	anchored_volume.bake_data = Data.new()
	anchored_volume.probe_positions = PackedVector3Array([Vector3(2.0, 3.0, 4.0)])
	var anchored_probe_positions := anchored_volume.probe_positions.duplicate()
	anchored_volume.position = Vector3(1.0, 0.0, 0.0)
	require(anchored_volume.probe_positions == anchored_probe_positions
			and anchored_volume.is_layout_stale(),
		"transform edits must preserve old baked world-space probe anchors and mark them stale")

	var state := State.new()
	require(state.lighting != null and state.emission != null, "state must own its helpers from construction")
	state.attach(volume)
	require(state.emission.update_snapshot(volume, data), "first emission publication must update")
	require(state.emission.payload == PackedFloat32Array([1, 0, 0]), "live red source must compose one RGB response per probe")
	require(not state.emission.update_snapshot(volume, data), "unchanged source must reuse its cached response")
	var published := state.emission.payload
	material.emission = Color.BLUE
	state.emission.read_source_values(volume, data)
	require(state.emission.payload == published, "diagnostics must not modify the published response")
	require(state.emission.update_snapshot(volume, data), "live source change must invalidate the response")
	require(state.emission.payload == PackedFloat32Array([0, 0, 1]), "live blue source must preserve channel order")
	require(published == PackedFloat32Array([1, 0, 0]), "later publication must not mutate an older snapshot")
	material.emission_enabled = false
	require(state.emission.update_snapshot(volume, data), "disabling a source must invalidate the response")
	require(state.emission.payload == PackedFloat32Array([0, 0, 0]), "disabled source must compose a correctly sized zero response")

	var replacement: Data = data.duplicate(true)
	require(state.emission.update_snapshot(volume, replacement), "replacing bake data must invalidate an unchanged zero response")
	replacement.bake_version = 2
	state.emission.read_source_values(volume, replacement)
	require(state.emission.update_snapshot(volume, replacement), "diagnostics must not consume a new bake's publication")
	require(not state.emission.update_snapshot(volume, replacement), "new bake must settle after one publication")
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	state.emission.read_source_values(volume, replacement)
	require(state.emission.get_warning().contains("sidedness"), "static changes must still diagnose a disabled source")
	material.cull_mode = BaseMaterial3D.CULL_BACK
	state.emission.read_source_values(volume, replacement)
	require(state.emission.get_warning().is_empty(), "restored static source must clear its diagnostic")

	# A standalone reader may be reused across volumes without retaining old scene keys.
	var other_scene := Node3D.new()
	root.add_child(other_scene)
	var other_volume := Volume.new()
	other_volume.show_probes = false
	other_scene.add_child(other_volume)
	require(state.emission.update_snapshot(other_volume, replacement), "changing volume must invalidate identical source values")
	require(state.emission.get_warning().contains("no longer exists"), "bindings must resolve against the current scene")
	require(state.emission.update_snapshot(volume, replacement), "returning to a volume must publish its identity")
	other_scene.free()

	# Source weights must remain finite on both single- and double-precision builds.
	var physical: bool = ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)
	ProjectSettings.set_setting("rendering/lights_and_shadows/use_physical_light_units", true)
	material.emission_enabled = true
	material.emission = Color.BLACK
	material.emission_energy_multiplier = 1.0e30
	material.emission_intensity = 1.0e30
	var overflow := state.emission.read_source_values(volume, replacement)
	require(overflow == PackedFloat32Array([0, 0, 0, 0, 0, 0]), "live source overflow must be disabled at the producer boundary")
	require(not state.emission.get_warning().is_empty(), "source overflow must remain diagnosable")
	ProjectSettings.set_setting("rendering/lights_and_shadows/use_physical_light_units", physical)

	state.lighting._sky_light_runtime = SkyRuntime
	var sky := PackedFloat32Array()
	sky.resize(27)
	sky.fill(1.0)
	SkyRuntime.snapshot = {"ready": true, "radiance_sh": sky}
	var lit := state.lighting.coefficient_sets(volume)
	require(lit.lighting == sky and lit.sky_lighting == sky, "ready SkyLight must populate both lighting sets")
	var changed_sky := sky.duplicate()
	changed_sky[0] = 2.0
	SkyRuntime.snapshot.radiance_sh = changed_sky
	require(state.lighting.coefficients(volume) == changed_sky, "actual SH changes must invalidate lighting without metadata changes")
	require(lit.sky_lighting == sky, "new lighting must not mutate an old snapshot")
	for snapshot in [{"ready": false, "radiance_sh": sky}, {"ready": true, "radiance_sh": [1.0]}]:
		SkyRuntime.snapshot = snapshot
		require(state.lighting.coefficients(volume).count(0.0) == 27, "unready or malformed SkyLight must clear cached radiance")
	SkyRuntime.snapshot = {}

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
