extends SceneTree
## CPU-only regression for the configured probe offset, geometric safety, and
## stale-layout rejection after changing placement semantics.

const Placement = preload("res://addons/feng-magic-gi/feng_magic_gi_placement.gd")
const ProbeLayout = preload("res://addons/feng-magic-gi/feng_magic_gi_probe_layout.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")

var _checks := 0
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_preferred_offsets()
	_test_safe_offset_against_foreign_faces()
	_test_old_layout_stales()
	print("MAGIC_GI_SURFACE_OFFSET_POLICY checks=%d failures=%d" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

func _test_preferred_offsets() -> void:
	var volume := Volume.new()
	volume.probe_spacing = 0.25
	volume.surface_offset = 0.03
	_check(is_equal_approx(Placement._preferred_probe_offset(volume), 0.03),
		"the configured 0.03m offset is honored at 0.25m spacing")
	volume.surface_offset = 0.2
	_check(is_equal_approx(Placement._preferred_probe_offset(volume), 0.125),
		"extreme requested offset remains bounded to half a spacing cell")
	volume.surface_offset = 0.001
	_check(is_equal_approx(Placement._preferred_probe_offset(volume), 0.00625),
		"small requested offsets retain the existing base-cell minimum")
	volume.free()

func _test_safe_offset_against_foreign_faces() -> void:
	var clamped := _placement_with_foreign_plane(0.04)
	var clamped_offset := clamped._safe_probe_offset(Vector3.ZERO, Vector3.UP, 0.125)
	_check(clamped_offset > 0.0 and clamped_offset < 0.02,
		"a nearby foreign face clamps the half-cell preferred offset")
	clamped = null

	var rejected := _placement_with_foreign_plane(0.0004)
	var rejected_offset := rejected._safe_probe_offset(Vector3.ZERO, Vector3.UP, 0.125)
	_check(rejected_offset == 0.0,
		"a gap below the minimum safe clearance rejects the offset")
	rejected = null

func _placement_with_foreign_plane(height: float) -> Placement:
	var placement := Placement.new()
	placement._probe_spacing = 0.25
	placement._volume_size = Vector3(4.0, 4.0, 4.0)
	placement._inverse = Transform3D.IDENTITY
	placement.bvh = TriangleMesh.new()
	var faces := PackedVector3Array([
		Vector3(-1.0, height, -1.0),
		Vector3(1.0, height, -1.0),
		Vector3(0.0, height, 1.0),
	])
	placement.bvh_ready = placement.bvh.create_from_faces(faces)
	_check(placement.bvh_ready, "foreign-face safety fixture BVH is valid")
	return placement

func _test_old_layout_stales() -> void:
	_check(ProbeLayout.PLACEMENT_LAYOUT_REVISION == 3,
		"placement semantics are persisted as revision 3")
	var volume := Volume.new()
	volume.clv_cache_backend = 0
	var legacy := Data.new()
	legacy.format_version = Data.FORMAT_VERSION
	legacy.bake_version = 1
	legacy.placement_layout_revision = 2
	legacy.scene_signature = int(Data.SAMPLER_REVISION) << 32
	legacy.bake_samples = volume.bake_samples
	volume.bake_data = legacy
	var reasons := volume.bake_staleness_reasons()
	_check(reasons.has("probe placement layout revision changed; rebake to refresh points"),
		"a revision-2 bake reports the placement change and requires rebaking")
	volume.bake_data = null
	legacy = null
	volume.free()

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	push_error("SURFACE_OFFSET_POLICY: " + message)
