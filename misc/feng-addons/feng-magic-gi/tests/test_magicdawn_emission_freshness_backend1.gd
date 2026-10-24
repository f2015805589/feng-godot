extends SceneTree
## RAM-only regression for backend-1 emissive source freshness.

const Volume = preload("../feng_magic_gi_volume.gd")
const Emission = preload("../feng_magic_gi_emission.gd")

var checks := 0
var failures := 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	check(RenderingServer.get_rendering_device() == null,
		"emission freshness fixture must stay CPU-only")
	var packed: PackedScene = load("res://box_test.tscn")
	check(packed != null, "target scene loads for the RAM-only freshness check")
	if packed == null:
		quit(1)
		return
	var scene_root: Node = packed.instantiate()
	root.add_child(scene_root)
	await process_frame
	var volume: Node = scene_root.get_node_or_null("MagicGIVolume")
	var emitter: MeshInstance3D = scene_root.get_node_or_null("Room/LampPanel_EmissiveFace")
	check(volume is Volume and emitter != null,
		"target scene contains its Magic GI volume and emissive face")
	if not volume is Volume or emitter == null:
		scene_root.queue_free()
		quit(1)
		return
	check(volume.clv_cache_backend == 1 and volume.bake_data != null
			and volume.has_usable_bake() and volume.bake_data.has_baked_indirect_sh(),
		"fixture starts from the current usable backend-1 SH bake")
	if volume.bake_data == null or not volume.has_usable_bake():
		scene_root.queue_free()
		quit(1)
		return
	var saved_data: Resource = volume.bake_data
	var sh_hash_before: int = hash(saved_data.baked_indirect_sh)
	var original_material: BaseMaterial3D = emitter.get_active_material(0)
	check(original_material != null and original_material.emission_enabled,
		"the saved emissive face starts enabled")
	if original_material == null:
		scene_root.queue_free()
		quit(1)
		return
	var original_enabled := original_material.emission_enabled
	var original_energy := original_material.emission_energy_multiplier
	var material_copy: BaseMaterial3D = original_material.duplicate(true)
	emitter.set_surface_override_material(0, material_copy)
	volume._baked_indirect_emission_stale = false
	volume._refresh_baked_indirect_emission_freshness()
	check(not volume._baked_indirect_emission_stale,
		"matching RAM material copy is initially fresh against the saved source snapshot")

	material_copy.emission_enabled = false
	volume._refresh_baked_indirect_emission_freshness()
	check(not material_copy.emission_enabled,
		"the material surface emission switch changes immediately in RAM")
	check(volume._baked_indirect_emission_stale and volume.needs_rebake(),
		"disabling a baked emitter marks backend 1 stale and requests Bake")
	var has_emission_reason := false
	for reason in volume.bake_staleness_reasons():
		if reason.contains("baked emissive inputs changed"):
			has_emission_reason = true
			break
	check(has_emission_reason,
		"the stale status gives a specific emissive Bake reason")
	check(volume.has_usable_bake(),
		"stale emission keeps the previous structurally valid preview available")
	check(hash(saved_data.baked_indirect_sh) == sh_hash_before,
		"polling never mutates or re-lights the saved SH payload")

	material_copy.emission_enabled = true
	material_copy.emission_energy_multiplier = original_energy * 2.0
	volume._refresh_baked_indirect_emission_freshness()
	check(volume._baked_indirect_emission_stale,
		"changing enabled emitter energy marks baked indirect light stale")
	material_copy.emission_energy_multiplier = original_energy
	volume._refresh_baked_indirect_emission_freshness()
	check(not volume._baked_indirect_emission_stale,
		"restoring the captured emitter state clears the stale flag")
	check(hash(saved_data.baked_indirect_sh) == sh_hash_before,
		"restore also leaves the original baked SH bytes unchanged")
	check(original_material.emission_enabled == original_enabled
			and is_equal_approx(original_material.emission_energy_multiplier, original_energy),
		"the shared scene material resource was not edited")

	scene_root.queue_free()
	await process_frame
	print("MAGICDAWN_EMISSION_FRESHNESS checks=%d failures=%d sh_hash=%d" % [
		checks, failures, sh_hash_before])
	quit(1 if failures > 0 else 0)
