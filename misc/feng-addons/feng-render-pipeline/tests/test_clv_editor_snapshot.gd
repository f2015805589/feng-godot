extends SceneTree
## CPU regression for real CLV tensor decoding and the asynchronous editor broker.
## Run with --headless --path <project-with-addons> --script
## res://addons/feng-render-pipeline/tests/test_clv_editor_snapshot.gd
## No RenderingDevice or GPU readback is required.

const Broker = preload("../passes/magic_gi_clv_editor_snapshot.gd")
const RESIDENT_CELLS := [0, 9, 18, 31]
const VOLUME_ID := 123
const TARGET_ID := 99

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func make_fixture(half_fields: bool) -> Dictionary:
	var indices := PackedInt32Array()
	indices.resize(32)
	indices.fill(-1)
	for cell in RESIDENT_CELLS:
		indices[cell] = cell + 100
	var original := PackedFloat32Array()
	for coefficient in 4:
		for channel in 3:
			original.append(float(coefficient + 1) * (0.13 + channel * 0.07)
				* (-1.0 if coefficient % 2 else 1.0))
	# Pack signed L0+L1 coefficients directly into the compact four-field layout.
	var packed := PackedFloat32Array()
	packed.resize(16)
	for component in 12:
		packed[component] = original[component]
	packed[15] = 1.0
	var width := 2 if half_fields else 4
	var data := PackedByteArray()
	data.resize(32 * 4 * 4 * width)
	for cell in RESIDENT_CELLS:
		for field in 4:
			for lane in 4:
				var offset: int = ((int(field) * 32 + int(cell)) * 4 + int(lane)) * width
				var value := packed[field * 4 + lane] / 8.0 if field * 4 + lane != 15 else 1.0
				if half_fields:
					data.encode_half(offset, value)
				else:
					data.encode_float(offset, value)
	return {"data": data, "original": original, "metadata": {
		"dimensions": Vector3i(2, 2, 8), "resident_indices": indices,
		"lod_origins": PackedVector3Array([
			Vector3.ZERO, Vector3(10, 0, 0), Vector3(20, 0, 0), Vector3(30, 0, 0)]),
		"lod_spacings": PackedFloat32Array([0.25, 0.5, 1.0, 2.0]), "decode_scale": 8.0,
		"half_fields": half_fields, "include_sh": true, "layout_key": "fixture",
		"layout_version": 7, "operator_schema_version": 2, "response_field_count": 4}}

func run() -> void:
	for half_fields in [false, true]:
		var fixture := make_fixture(half_fields)
		var result := Broker.decode_snapshot(fixture.data, fixture.metadata)
		check(result.current_available, "decode accepted")
		check(result.positions.size() == 4 and result.response_sh.size() == 48
				and result.response_coefficient_count == 4,
			"four real resident cells")
		check(result.response_sh_semantics == "raw_signed_world_incident_radiance_sh2_l0_l1_coefficient_major_rgb",
			"CLV preview exposes the signed SH2 coefficient contract shared with source preview")
		check(result.lods == PackedInt32Array([0, 1, 2, 3]), "all real lods")
		check(result.positions[3] == Vector3(32, 2, 2),
			"position matches actual origin/grid spacing")
		for probe in 4:
			for component in 12:
				check(absf(result.response_sh[probe * 12 + component] - fixture.original[component])
					< (0.002 if half_fields else 0.00001),
					"signed raw SH2 coefficient decode: half=%s probe=%d component=%d"
					% [half_fields, probe, component])
		var bad: PackedByteArray = fixture.data.slice(0, 8)
		check(not Broker.decode_snapshot(bad, fixture.metadata).current_available,
			"truncated readback rejected")

	var fixture := make_fixture(false)
	Broker.set_request(VOLUME_ID, true, true, 500, TARGET_ID)
	check(Broker.claim(VOLUME_ID, TARGET_ID - 1, "cache", 1, 1).is_empty(),
		"wrong viewport rejected")
	var request := Broker.claim(VOLUME_ID, TARGET_ID, "cache", 1, 1)
	check(not request.is_empty(), "requested viewport claimed")
	check(Broker.claim(VOLUME_ID, TARGET_ID, "cache", 2, 1).is_empty(),
		"single pending readback")
	var metadata: Dictionary = fixture.metadata.duplicate(true)
	metadata.merge(request, true)
	# Exercises receive_readback's direct static Callable through WorkerThreadPool,
	# rather than only calling the decoder synchronously on the main thread.
	Broker.receive_readback(fixture.data, metadata)
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if Broker.get_status(VOLUME_ID).current_available:
			break
	var snapshot := Broker.get_snapshot(VOLUME_ID)
	check(snapshot.get("current_available", false), "worker snapshot published without GPU")
	check(snapshot.get("revision", 0) > 0, "publication revision present")
	check(Broker.claim(VOLUME_ID, TARGET_ID, "cache", 1, 1).is_empty(),
		"identical revision reused")
	Broker.set_request(VOLUME_ID, false)
	check(Broker.get_snapshot(VOLUME_ID).is_empty() and not Broker.has_requests(),
		"disable releases snapshot/request")
	Broker.receive_readback(fixture.data, metadata)
	await process_frame
	check(Broker.get_snapshot(VOLUME_ID).is_empty(), "cancelled callback cannot republish")
	print("[CLV_EDITOR_SNAPSHOT_CPU] checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
