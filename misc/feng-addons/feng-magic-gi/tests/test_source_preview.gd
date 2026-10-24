extends SceneTree
## CPU-only exact source-Transfer preview contracts. No legacy FMagicGIData or
## scene geometry is required by the worker helper.

const Chunk = preload("../feng_magic_gi_volume_source_chunk.gd")
const Preview = preload("../feng_magic_gi_source_preview.gd")
const SOURCES := [0, 2, 3]
const EMITTER_VALUES := [2, 3, 4, 5, 6, 7, 11, 13, 17, 19, 23, 29]

var checks := 0
var failures := 0
var cancellation_checks := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func run() -> void:
	check(RenderingServer.get_rendering_device() == null,
			"source preview regression must run without GPU or scene resources")
	var chunk := _fixture()
	var lighting := _lighting(false)
	var sky := _lighting(true)
	var zero := PackedFloat32Array()
	zero.resize(27)
	var emitters := PackedFloat32Array(EMITTER_VALUES)
	var zero_emitters := PackedFloat32Array()
	zero_emitters.resize(12)
	var transfer_only := Preview.build(chunk, lighting, zero, zero_emitters)
	var sky_only := Preview.build(chunk, zero, sky, zero_emitters)
	var emission_only := Preview.build(chunk, zero, zero, emitters)
	var combined := Preview.build(chunk, lighting, sky, emitters)
	var black := Preview.build(chunk, zero, zero, zero_emitters)
	check(bool(combined.get("volume_probe_preview", false)) and bool(combined.current_available),
			"source-only Transfer produces an available volume probe snapshot")
	check(combined.source_indices == PackedInt32Array(SOURCES),
			"invalid source cells are filtered without renumbering the immutable source indices")
	check(combined.positions == PackedVector3Array([
		Vector3(10, 20, 30), Vector3(10.03, 20.23, 30.01), Vector3(10.25, 20.25, 30),
	]), "positions preserve world grid centers and the recorded valid relocation")
	check(combined.spacings == PackedFloat32Array([0.25, 0.25, 0.25]) \
			and combined.lods == PackedInt32Array([-1, -1, -1]),
			"source samples keep their pitch and never masquerade as a resident CLV level")
	check(combined.response_sh.size() == 3 * 27,
			"raw output has nine coefficient-major RGB triplets for each valid source")
	check(bool(black.current_available) and black.response_sh == _zeros(81),
			"a valid zero-light source remains available black")
	for probe in SOURCES.size():
		var source: int = SOURCES[probe]
		for outgoing in 9:
			var expected_transfer := _expected_transfer(source, outgoing)
			var expected_sky := _expected_sky(source, outgoing)
			var expected_emission := _expected_emission(source, outgoing)
			var label := "source %d outgoing %d" % [source, outgoing]
			check(_value(transfer_only, probe, outgoing).distance_to(expected_transfer) < 0.0001,
					label + ": RGB transfer selects the correct incoming coefficient")
			check(_value(sky_only, probe, outgoing).distance_to(expected_sky) < 0.0001,
					label + ": achromatic sky transfer multiplies independent primary sky RGB")
			check(_value(emission_only, probe, outgoing).distance_to(expected_emission) < 0.0001,
					label + ": both emitters retain base/textured RGB source channels")
			check(_value(combined, probe, outgoing).distance_to(
					expected_transfer + expected_sky + expected_emission) < 0.0001,
					label + ": signed source families combine before any display projection")
	check(_value(transfer_only, 0, 0).y < 0.0 \
			and _value(sky_only, 0, 8).z < 0.0,
			"negative SH coefficients survive; raw output is not clamped or cosine-convolved")
	var emission_disabled := Preview.build(chunk, lighting, sky, zero_emitters)
	check(_value(emission_disabled, 2, 8).is_equal_approx(
			_expected_transfer(3, 8) + _expected_sky(3, 8)),
			"disabling live emission removes its contribution without changing source transport")
	check(combined.layout_key == emission_disabled.layout_key \
			and combined.layout_key == black.layout_key,
			"live lighting changes leave the source marker layout key stable")
	var source_transfer_before := chunk.transfer.duplicate()
	Preview.build(chunk, lighting, sky, emitters)
	check(chunk.transfer == source_transfer_before,
			"debug relighting leaves immutable source transfer untouched")
	chunk.relocation_offset_m[2] = Vector3(0.04, -0.02, 0.01)
	var relocated := Preview.build(chunk, lighting, sky, emitters)
	check(relocated.layout_key != combined.layout_key \
			and relocated.positions[1].is_equal_approx(Vector3(10.04, 20.23, 30.01)),
			"changed relocation changes the actual layout identity and marker position")
	var missing_lighting := Preview.build(chunk, PackedFloat32Array(), sky, emitters)
	check(not bool(missing_lighting.current_available) \
			and missing_lighting.positions == relocated.positions,
			"unavailable live lighting retains source positions for an unavailable-state display")
	var nonfinite_light := lighting.duplicate()
	nonfinite_light[5] = NAN
	check(not bool(Preview.build(chunk, nonfinite_light, sky, emitters).current_available),
			"non-finite live coefficients cannot become available probe lighting")
	check(not bool(Preview.build(chunk, lighting, sky, PackedFloat32Array()).current_available),
			"emitter array size must match the stable six-value source slots")
	# The removed probe cannot contaminate the valid probes' output.
	chunk.transfer[243] = NAN
	check(bool(Preview.build(chunk, lighting, sky, emitters).current_available),
			"invalid cells are excluded before reading their transport")
	chunk.transfer[0] = NAN
	var invalid_transfer := Preview.build(chunk, lighting, sky, emitters)
	check(not bool(invalid_transfer.current_available) \
			and invalid_transfer.response_sh == _zeros(81),
			"non-finite source output rejects the complete response without publishing NaNs")
	chunk = _fixture()
	chunk.sky.resize(chunk.sky.size() - 1)
	check(not bool(Preview.build(chunk, lighting, sky, emitters).current_available),
			"a truncated source matrix rejects relighting before indexed access")
	check(not bool(Preview.build(null, lighting, sky, emitters).current_available),
			"missing source returns an unavailable empty snapshot")
	chunk = _fixture()
	check(Preview.build(chunk, lighting, sky, emitters, func() -> bool: return true).is_empty(),
			"cancelled work publishes no partial snapshot")
	cancellation_checks = 0
	check(Preview.build(chunk, lighting, sky, emitters, _cancel_after_layout).is_empty() \
			and cancellation_checks == 3,
			"worker cancellation is observed again before the SH batch begins")
	_test_packed_source(lighting, sky, emitters)
	print("MAGIC_GI_SOURCE_PREVIEW checks=", checks, " failures=", failures)
	quit(1 if failures else 0)

func _fixture() -> Chunk:
	var chunk := Chunk.new()
	check(chunk.allocate(Vector3i(2, 2, 1), PackedStringArray(["a", "b"])),
			"source fixture allocates the versioned transfer matrices")
	chunk.origin_world = Vector3(10, 20, 30)
	chunk.validity = PackedByteArray([1, 0, 2, 1])
	chunk.relocation_offset_m[2] = Vector3(0.03, -0.02, 0.01)
	for source in 4:
		for outgoing in 9:
			var incoming := (outgoing * 2 + source) % 9
			var base := source * 243 + outgoing * 27 + incoming * 3
			chunk.transfer[base] = float(source + 1)
			chunk.transfer[base + 1] = -20.0 * float(source + 1)
			chunk.transfer[base + 2] = 0.5 * float(source + 1)
			incoming = (outgoing + source + 3) % 9
			chunk.sky[source * 81 + outgoing * 9 + incoming] = float(outgoing + 1) / 8.0
			for emitter in 2:
				base = (emitter * 4 + source) * 54 + outgoing * 6
				var factor := float(emitter + 1)
				var coefficients := [source + 1, outgoing + 1, 2, 0.5, -1, 3]
				for channel in 6:
					chunk.emission[base + channel] = float(coefficients[channel]) * factor
	return chunk

func _test_packed_source(lighting: PackedFloat32Array, sky_light: PackedFloat32Array,
		emitters: PackedFloat32Array) -> void:
	var dense := _fixture()
	var expected := Preview.build(dense, lighting, sky_light, emitters)
	var compact := dense.duplicate(true) as Chunk
	compact.format_version = 2
	compact.source_storage_count = SOURCES.size()
	compact.source_storage_indices = PackedInt32Array([0, -1, 1, 2])
	compact.transfer.clear()
	compact.sky.clear()
	compact.emission.clear()
	compact.receiver_visibility_moments.clear()
	for source in SOURCES:
		compact.transfer.append_array(dense.transfer.slice(source * 243, (source + 1) * 243))
		compact.sky.append_array(dense.sky.slice(source * 81, (source + 1) * 81))
		compact.receiver_visibility_moments.append_array(
			dense.receiver_visibility_moments.slice(source * 128, (source + 1) * 128))
	for emitter in 2:
		for source in SOURCES:
			var start: int = (emitter * 4 + source) * 54
			compact.emission.append_array(dense.emission.slice(start, start + 54))
	var actual := Preview.build(compact, lighting, sky_light, emitters)
	check(bool(actual.current_available), "packed source preview is available")
	check(actual.positions == expected.positions and actual.source_indices == expected.source_indices,
		"packed storage retains original logical indices and relocated positions")
	check(actual.response_sh == expected.response_sh,
		"packed two-emitter strides reproduce every signed SH coefficient exactly")
	compact.source_storage_indices[2] = 400
	check(not bool(Preview.build(compact, lighting, sky_light, emitters).current_available),
		"out-of-range packed sample cannot produce a partial available response")

func _lighting(primary: bool) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	for incoming in 9:
		var value := float(incoming + 1)
		result.append_array(PackedFloat32Array([value * 2, value * 3, -value]) if primary \
				else PackedFloat32Array([value, value * 0.5, value * 2]))
	return result

func _expected_transfer(source: int, outgoing: int) -> Vector3:
	var incoming := (outgoing * 2 + source) % 9
	var value := float((source + 1) * (incoming + 1))
	return Vector3(value, -10.0 * value, value)

func _expected_sky(source: int, outgoing: int) -> Vector3:
	var incoming := (outgoing + source + 3) % 9
	var value := float((incoming + 1) * (outgoing + 1)) / 8.0
	return Vector3(2 * value, 3 * value, -value)

func _expected_emission(source: int, outgoing: int) -> Vector3:
	# Distinct emitter/channel values make transposed strides and source slots fail.
	return Vector3((source + 1) * (2 + 2 * 11) + 0.5 * (5 + 2 * 19),
		(outgoing + 1) * (3 + 2 * 13) - (6 + 2 * 23),
		2 * (4 + 2 * 17) + 3 * (7 + 2 * 29))

func _value(snapshot: Dictionary, probe: int, outgoing: int) -> Vector3:
	var values: PackedFloat32Array = snapshot.response_sh
	var base := probe * 27 + outgoing * 3
	return Vector3(values[base], values[base + 1], values[base + 2])

func _zeros(count: int) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(count)
	return values

func _cancel_after_layout() -> bool:
	cancellation_checks += 1
	return cancellation_checks >= 3
