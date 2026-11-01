## In-memory OLV target-layout revision and legacy-scene migration checks.
## Uses PackedScene.pack/instantiate only; it never saves project files.

extends SceneTree

const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Chunk = preload("res://addons/feng-magic-gi/feng_magic_gi_volume_source_chunk.gd")
const Manifest = preload("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")
const LabelSet = preload("res://addons/feng-magic-gi/feng_magic_gi_olv_label_set.gd")
const SourceBaker = preload("res://addons/feng-magic-gi/feng_magic_gi_volume_source_baker.gd")

var _checks := 0
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene_root := Node3D.new()
	scene_root.name = "OLVLayoutRevisionLifecycle"
	root.add_child(scene_root)
	current_scene = scene_root
	var volume := Volume.new()
	volume.name = "MagicGIVolume"
	scene_root.add_child(volume)
	volume.owner = scene_root
	var initial_revision := volume.layout_revision()
	var stored_property := false
	for property_info in volume.get_property_list():
		if String(property_info.get("name", "")) == "_layout_epoch":
			stored_property = (int(property_info.get("usage", 0)) & PROPERTY_USAGE_STORAGE) != 0
	_check(stored_property, "target-layout revision is a serialized Volume property")

	var packed := PackedScene.new()
	var pack_error := packed.pack(scene_root)
	_check(pack_error == OK, "PackedScene.pack succeeds without writing a file")
	if pack_error != OK:
		_finish(scene_root)
		return
	var reloaded_root := packed.instantiate() as Node3D
	_check(reloaded_root != null, "PackedScene.instantiate succeeds in memory")
	if reloaded_root == null:
		_finish(scene_root)
		return
	root.add_child(reloaded_root)
	current_scene = reloaded_root
	var reloaded_volume := reloaded_root.get_node_or_null("MagicGIVolume") as FMagicGIVolume
	_check(reloaded_volume != null and reloaded_volume.layout_revision() == initial_revision,
		"the target-layout revision survives an in-memory scene round trip")
	if reloaded_volume == null:
		_finish(scene_root)
		return

	var source := Chunk.new()
	source.geometry_signature = 90210
	source.origin_world = Vector3(-0.375, 0.125, -0.625)
	source.dimensions = Vector3i(4, 3, 2)
	source.source_transform_world = reloaded_volume.global_transform
	source.source_size_m = reloaded_volume.size
	source.source_bounds_world = reloaded_volume.global_transform * AABB(-reloaded_volume.size * 0.5,
		reloaded_volume.size)
	const LEGACY_REVISION := 7
	var expected_context: Dictionary = SourceBaker.make_olv_layout_context(reloaded_volume,
		source.geometry_signature, source.origin_world, source.dimensions, 4, LEGACY_REVISION)
	var label_set := LabelSet.new()
	var configured: Dictionary = label_set.configure(String(expected_context.get("scene_id", "")),
		String(expected_context.get("volume_id", "")), LEGACY_REVISION,
		source.geometry_signature, String(expected_context.get("target_layout_signature", "")))
	_check(bool(configured.get("ok", false)), "synthetic legacy LabelSet binds to the sealed layout")
	var legacy_context := expected_context.duplicate(true)
	legacy_context["layout_signature"] = String(expected_context.get("target_layout_signature", ""))
	legacy_context["grid_origin_world"] = source.origin_world
	legacy_context["base_cell_spacing_m"] = Chunk.CELL_SPACING_M
	reloaded_volume._layout_epoch = initial_revision
	var recovered: Dictionary = reloaded_volume._recover_legacy_olv_layout_revision(source,
		label_set, legacy_context)
	_check(bool(recovered.get("ok", false)) and bool(recovered.get("recovered", false))
		and reloaded_volume.layout_revision() == LEGACY_REVISION,
		"an older scene with no saved epoch recovers it only from the exact sealed source layout")

	reloaded_volume._layout_epoch = initial_revision
	var bad_context := legacy_context.duplicate(true)
	bad_context["grid_origin_world"] = source.origin_world + Vector3(0.25, 0.0, 0.0)
	var rejected: Dictionary = reloaded_volume._recover_legacy_olv_layout_revision(source,
		label_set, bad_context)
	_check(not bool(rejected.get("ok", false)) and reloaded_volume.layout_revision() == initial_revision,
		"a changed source lattice cannot migrate an old revision or silently reuse its labels")

	var unchanged_revision := reloaded_volume.layout_revision()
	reloaded_volume.bake_samples += 1
	_check(reloaded_volume.layout_revision() == unchanged_revision,
		"changing transport sample count invalidates the bake without changing the target lattice revision")
	reloaded_volume.bake_bounces += 1
	_check(reloaded_volume.layout_revision() == unchanged_revision,
		"changing transport bounces does not change the target lattice revision")
	reloaded_volume.bake_manifest = Manifest.new()
	_check(reloaded_volume.layout_revision() == unchanged_revision,
		"assigning a new manifest generation does not change the target lattice revision")
	reloaded_volume.size += Vector3(0.1, 0.0, 0.0)
	_check(reloaded_volume.layout_revision() == unchanged_revision + 1,
		"changing Volume bounds advances the target lattice revision")
	reloaded_volume.clv_cell_size = 0.5
	_check(reloaded_volume.layout_revision() == unchanged_revision + 2,
		"changing CLV cell spacing advances the target lattice revision")
	_finish(scene_root)

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: " + message)
	else:
		_failures += 1
		push_error("FAIL: " + message)

func _finish(scene_root: Node) -> void:
	print("OLV_LAYOUT_REVISION_LIFECYCLE_RESULT failures=%d checks=%d" % [_failures, _checks])
	scene_root.queue_free()
	if OS.get_cmdline_user_args().has("--hold-for-token-probe"):
		OS.delay_msec(5000)
	quit(1 if _failures > 0 else 0)
