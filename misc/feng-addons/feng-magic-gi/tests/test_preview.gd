extends SceneTree
## CPU-only contracts for current-response and unit-source preview semantics.

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const Preview = preload("res://addons/feng-magic-gi/feng_magic_gi_preview.gd")

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
	var data := Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.positions = PackedVector3Array([Vector3(1.0, 2.0, 3.0)])
	data.transfer.resize(27)
	data.transfer.fill(0.0)
	data.transfer[0] = 1.0
	data.transfer[1] = 0.5
	data.transfer[2] = 0.25
	data.primary_sky_visibility.resize(9)
	data.primary_sky_visibility.fill(0.0)
	data.primary_sky_visibility[0] = PI
	var lighting := PackedFloat32Array()
	lighting.resize(27)
	lighting.fill(0.0)
	lighting[0] = 2.0
	lighting[1] = 4.0
	lighting[2] = 8.0
	var sky_lighting := PackedFloat32Array()
	sky_lighting.resize(27)
	sky_lighting.fill(0.0)
	sky_lighting[0] = 1.0
	sky_lighting[1] = 2.0
	sky_lighting[2] = 3.0
	var emission := PackedFloat32Array([0.5, 1.0, 2.0])
	var complete := Preview.probe_response(data, 0, lighting, sky_lighting, emission, 2.0)
	require(complete.is_equal_approx(Vector3(7.0, 10.0, 14.0)),
			"probe color must combine secondary, primary sky, and emission before gi_strength")
	var without_emission := Preview.probe_response(data, 0, lighting, sky_lighting,
			PackedFloat32Array(), 2.0)
	require(without_emission.is_equal_approx(Vector3(6.0, 8.0, 10.0)),
			"probe response must remain usable without an emitter payload")
	var unit_source := Preview.unit_source_response(data, 0, Vector3.UP)
	var expected_unit := Vector3(0.2820947918, 0.1410473959, 0.07052369795) \
			+ Vector3.ONE * 0.2820947918
	require(unit_source.is_equal_approx(expected_unit),
			"SH unit-source response must include secondary transport and primary visibility divided by PI")
	data.transfer.fill(0.0)
	var primary_only := Preview.unit_source_response(data, 0, Vector3.UP)
	require(primary_only.is_equal_approx(Vector3.ONE * 0.2820947918),
			"primary-only visibility must remain visible in the SH response")
	data.primary_sky_visibility.fill(0.0)
	data.primary_sky_visibility[0] = -PI
	var zero_response := Preview.unit_source_response(data, 0, Vector3.UP)
	require(zero_response == Vector3.ZERO,
			"negative truncated primary lobes must clamp to a true zero response")
	require(Preview.layout_matches(data, PackedVector3Array([Vector3(1.0, 2.0, 3.0)])),
			"bake indices may be used when world probe positions correspond")
	require(not Preview.layout_matches(data, PackedVector3Array([Vector3(1.0, 2.0, 3.01)])),
			"stale bake indices must not map onto moved probes")
	require(not Preview.layout_matches(data, PackedVector3Array()),
			"a different probe count must reject baked index mapping")
	print("MAGIC_GI_PREVIEW checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
