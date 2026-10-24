extends SceneTree
## CPU-only regression for frozen directional NEE inputs, transient probe SH,
## final SH composition, and streamed-generation provenance.

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const DirectionalData = preload("res://addons/feng-magic-gi/feng_magic_gi_directional_data.gd")
const Lighting = preload("res://addons/feng-magic-gi/feng_magic_gi_lighting.gd")
const Baker = preload("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
const BakeJob = preload("res://addons/feng-magic-gi/feng_magic_gi_bake_job.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Page = preload("res://addons/feng-magic-gi/feng_magic_gi_page.gd")
const Manifest = preload("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")
const PageStreamer = preload("res://addons/feng-magic-gi/feng_magic_gi_page_streamer.gd")
const Visibility = preload("res://addons/feng-magic-gi/feng_magic_gi_visibility.gd")

var _checks := 0
var _failures := 0
var _eligible_source: Dictionary = {}
var _sky_only_source: Dictionary = {}
var _eligible_direct := PackedFloat32Array()
var _sky_only_direct := PackedFloat32Array()

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	await _test_directional_source_snapshots()
	await _test_runtime_source_relighting()
	_test_source_provenance()
	_test_worker_transient_merge()
	_test_full_compose()
	_test_streamed_generation_contract()
	print("MAGIC_GI_EXACT_DIRECTIONAL_NEE checks=%d failures=%d" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

func _test_directional_source_snapshots() -> void:
	var previous_physical := bool(ProjectSettings.get_setting(
			"rendering/lights_and_shadows/use_physical_light_units", false))
	var nonphysical := await _capture_light_case("nonphysical_positive", false,
		false, DirectionalLight3D.SKY_MODE_LIGHT_ONLY, true, true, true)
	_eligible_source = nonphysical.source
	_eligible_direct = nonphysical.direct
	_check(bool(nonphysical.ready), "nonphysical direct snapshot is ready")
	_check(_radiance_matches(nonphysical.source, nonphysical.expected_radiance),
		"nonphysical Q includes color × energy × indirect energy × PI exactly once")
	_check(nonphysical.direct == nonphysical.expected_direct,
		"nonphysical per-source SH reproduces the existing direct projection exactly")

	var physical := await _capture_light_case("physical_positive", true,
		false, DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY, true, true, true)
	_check(bool(physical.ready), "physical-unit direct snapshot is ready")
	_check(_radiance_matches(physical.source, physical.expected_radiance),
		"physical Q includes correlated color and lux without PI scaling")
	_check(physical.direct == physical.expected_direct,
		"physical per-source SH reproduces the existing direct projection exactly")

	var negative := await _capture_light_case("negative_light", false,
		true, DirectionalLight3D.SKY_MODE_LIGHT_ONLY, true, true, true)
	_check(bool(negative.ready) and _radiance_matches(negative.source,
			negative.expected_radiance), "negative DirectionalLight preserves signed source radiance")
	_check(negative.direct == negative.expected_direct,
		"negative per-source SH retains the existing signed direct projection")

	var sky_only := await _capture_light_case("sky_only_light", false,
		false, DirectionalLight3D.SKY_MODE_SKY_ONLY, true, true, true)
	_sky_only_source = sky_only.source
	_sky_only_direct = sky_only.direct
	_check(bool(sky_only.ready) and int(sky_only.source.get("sky_mode", -1))
			== DirectionalLight3D.SKY_MODE_SKY_ONLY,
		"sky-only source remains recorded in the immutable snapshot")
	var sky_only_sources: Array[Dictionary] = []
	sky_only_sources.append(sky_only.source)
	_check(Baker.new()._eligible_directional_source_count(sky_only_sources) == 0,
		"sky-only source is excluded from exact directional NEE work")
	_check(sky_only.direct == sky_only.expected_direct,
		"sky-only source snapshot uses the same legacy SH projection arithmetic")

	var no_lights := await _capture_light_case("no_directional_lights", false,
		false, DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY, false, false, true)
	_check(bool(no_lights.ready) and no_lights.sources.is_empty()
			and no_lights.direct == _zero_sh(),
		"an explicit empty source snapshot is valid and projects to zero")

	var invisible := await _capture_light_case("invisible_explicit_sun", false,
		false, DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY, true, true, false)
	_check(bool(invisible.ready) and invisible.sources.is_empty()
			and invisible.direct == _zero_sh(),
		"an invisible explicit Sun is omitted consistently from capture and SH")

	var invalid_explicit := await _capture_invalid_explicit_light()
	_check(bool(invalid_explicit.ready) and invalid_explicit.sources.is_empty()
			and invalid_explicit.direct == _zero_sh(),
		"an explicit DirectionalLight outside the Volume World3D is not captured as a source")

	ProjectSettings.set_setting("rendering/lights_and_shadows/use_physical_light_units",
		previous_physical)

func _test_runtime_source_relighting() -> void:
	var previous_physical := bool(ProjectSettings.get_setting(
			"rendering/lights_and_shadows/use_physical_light_units", false))
	ProjectSettings.set_setting("rendering/lights_and_shadows/use_physical_light_units", false)
	var scene := Node3D.new()
	scene.name = "RuntimeRelightDirection"
	root.add_child(scene)
	var volume: Node = Volume.new()
	volume.set("clv_cache_backend", 0)
	scene.add_child(volume)
	var light := _make_test_light("RotatingSun", false,
		DirectionalLight3D.SKY_MODE_LIGHT_ONLY, true, false)
	scene.add_child(light)
	volume.set("sun", light)
	await process_frame
	var lighting := Lighting.new()
	var first_sets: Dictionary = lighting.coefficient_sets(volume)
	var first_direct: PackedFloat32Array = first_sets.get("direct_lighting", _zero_sh())
	light.rotation.y = PI * 0.5
	await process_frame
	var rotated_sets: Dictionary = lighting.coefficient_sets(volume)
	var rotated_direct: PackedFloat32Array = rotated_sets.get("direct_lighting", _zero_sh())
	_check(first_direct != rotated_direct,
		"backend 0 lighting snapshots must detect a live DirectionalLight rotation")

	var directional := DirectionalData.new()
	directional.allocate(1, 0)
	# Route incoming SH coefficient Y11(x) to outgoing DC for red.
	directional.transfer[9] = 1.0
	var zero_sh := _zero_sh()
	var no_sources := PackedFloat32Array()
	var first_relight: PackedFloat32Array = directional.relight(
			0, first_direct, zero_sh, no_sources)
	var rotated_relight: PackedFloat32Array = directional.relight(
			0, rotated_direct, zero_sh, no_sources)
	_check(absf(first_relight[0] - rotated_relight[0]) > 0.1,
		"rotating the sun must change probe radiance through the baked SH transfer matrix")

	# The primary-sky transfer is also source-independent and responds to current Sky SH.
	directional.sky[0] = 1.0
	var sky_a := zero_sh.duplicate()
	var sky_b := zero_sh.duplicate()
	sky_a[0] = 1.0
	sky_b[0] = 2.0
	var primary_a: PackedFloat32Array = directional.relight(0, zero_sh, sky_a, no_sources)
	var primary_b: PackedFloat32Array = directional.relight(0, zero_sh, sky_b, no_sources)
	_check(absf(primary_a[27] - primary_b[27]) > 0.1,
		"changing Sky SH must change visibility-filtered primary-sky probe radiance")
	print("MAGIC_GI_RUNTIME_RELIGHT direction_input_changed=true sun_transfer_changed=true sky_transfer_changed=true")
	scene.free()
	ProjectSettings.set_setting("rendering/lights_and_shadows/use_physical_light_units",
		previous_physical)

func _capture_light_case(case_name: String, physical: bool, negative: bool,
		sky_mode: int, add_light: bool, assign_explicit: bool,
		light_visible: bool) -> Dictionary:
	ProjectSettings.set_setting("rendering/lights_and_shadows/use_physical_light_units", physical)
	var scene := Node3D.new()
	scene.name = "ExactNEE_" + case_name
	root.add_child(scene)
	var volume: Node = Volume.new()
	volume.name = "Volume"
	scene.add_child(volume)
	var light: DirectionalLight3D
	if add_light:
		light = _make_test_light(case_name, negative, sky_mode, light_visible, physical)
		scene.add_child(light)
		if assign_explicit:
			volume.set("sun", light)
	await process_frame
	var lighting := Lighting.new()
	var sets := lighting.coefficient_sets(volume)
	var direct: PackedFloat32Array = sets.get("direct_lighting", _zero_sh())
	var snapshot_sets := {"direct_lighting": direct.duplicate()}
	var capture: Dictionary = lighting._attach_bake_directional_snapshot(volume, snapshot_sets)
	var sources: Array[Dictionary] = []
	var sources_value: Variant = capture.get("directional_sources", null)
	if sources_value is Array:
		for source_value in sources_value:
			if source_value is Dictionary:
				sources.append(source_value)
	var source: Dictionary = sources[0] if sources.size() == 1 else {}
	var expected_radiance := _expected_light_radiance(light, physical) if light != null else Vector3.ZERO
	var expected_direct := _project_one_source(light, physical) if light != null \
		else _zero_sh()
	if not bool(capture.get("ready", false)):
		print("NEE_FIXTURE_CAPTURE case=%s error=%s direct0=%s expected_direct0=%s source_count=%d" % [
			case_name, String(capture.get("error", "")), str(direct[0]),
			str(expected_direct[0]), sources.size()])
	var output := {
		"ready": bool(capture.get("ready", false)),
		"sources": sources,
		"source": source,
		"direct": direct,
		"expected_direct": expected_direct,
		"expected_radiance": expected_radiance,
	}
	if light != null and bool(capture.get("ready", false)):
		var wrong_direct := direct.duplicate()
		wrong_direct[0] += 0.01
		var rejected := lighting._attach_bake_directional_snapshot(volume,
			{"direct_lighting": wrong_direct})
		_check(not bool(rejected.get("ready", false)),
			case_name + " rejects a per-source/direct SH projection mismatch")
		_check(not bool(lighting._attach_bake_directional_snapshot(volume,
			{"direct_lighting": "wrong-variant"}).get("ready", false)),
			case_name + " rejects an invalid direct SH payload type")
	scene.free()
	return output

func _capture_invalid_explicit_light() -> Dictionary:
	ProjectSettings.set_setting("rendering/lights_and_shadows/use_physical_light_units", false)
	var scene := Node3D.new()
	scene.name = "ExactNEE_InvalidExplicit"
	root.add_child(scene)
	var volume: Node = Volume.new()
	volume.name = "Volume"
	scene.add_child(volume)
	var unattached := _make_test_light("Unattached", false,
		DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY, true, false)
	volume.set("sun", unattached)
	await process_frame
	var lighting := Lighting.new()
	var sets := lighting.coefficient_sets(volume)
	var direct: PackedFloat32Array = sets.get("direct_lighting", _zero_sh())
	var capture: Dictionary = lighting._attach_bake_directional_snapshot(volume,
		{"direct_lighting": direct.duplicate()})
	var output := {"ready": bool(capture.get("ready", false)),
		"sources": capture.get("directional_sources", []), "direct": direct}
	scene.free()
	unattached.free()
	return output

func _make_test_light(light_name: String, negative: bool, sky_mode: int,
		light_visible: bool, physical: bool) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.name = light_name
	light.light_color = Color(0.42, 0.71, 0.23, 1.0)
	light.light_energy = 2.25
	light.light_indirect_energy = 0.625
	light.light_negative = negative
	light.sky_mode = sky_mode
	light.visible = light_visible
	light.light_angular_distance = 0.0
	light.set("light_intensity_lux", 13500.0 if physical else 0.0)
	return light

func _expected_light_radiance(light: DirectionalLight3D, physical: bool) -> Vector3:
	var color: Color = light.light_color.srgb_to_linear()
	var temperature: Color = light.get_correlated_color().srgb_to_linear()
	var rgb := Vector3(color.r, color.g, color.b)
	var scale := light.light_energy * light.light_indirect_energy
	if physical:
		rgb = Vector3(rgb.x * temperature.r, rgb.y * temperature.g, rgb.z * temperature.b)
		scale *= float(light.get("light_intensity_lux"))
	else:
		scale *= PI
	if light.light_negative:
		scale = -scale
	return rgb * scale

func _project_one_source(light: DirectionalLight3D, physical: bool) -> PackedFloat32Array:
	var result := _zero_sh()
	var color: Color = light.light_color.srgb_to_linear()
	var energy := light.light_energy * light.light_indirect_energy
	if physical:
		energy *= float(light.get("light_intensity_lux"))
		color *= light.get_correlated_color().srgb_to_linear()
	else:
		energy *= PI
	if light.light_negative:
		energy *= -1.0
	var basis := Data.sh_basis(light.global_basis.z.normalized())
	for coefficient in 9:
		result[coefficient * 3] += color.r * energy * basis[coefficient]
		result[coefficient * 3 + 1] += color.g * energy * basis[coefficient]
		result[coefficient * 3 + 2] += color.b * energy * basis[coefficient]
	return result

func _radiance_matches(source: Dictionary, expected: Vector3) -> bool:
	var value: Variant = source.get("radiance_rgb", null)
	return typeof(value) == TYPE_VECTOR3 and (value as Vector3).is_equal_approx(expected)

func _test_source_provenance() -> void:
	var source := _eligible_source.duplicate(true)
	var sources: Array[Dictionary] = [source]
	var signature := Data.baked_directional_source_signature(sources, false)
	var provenance := _directional_provenance(sources, false)
	var algorithm := Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE
	_check(not signature.is_empty() and Data.is_valid_baked_indirect_directional_provenance(
			algorithm, signature, provenance),
		"sorted source list and exact field signature validate")
	var changed := sources.duplicate(true)
	changed[0]["radiance_rgb"] = Vector3(2.0, 0.0, 0.0)
	_check(Data.baked_directional_source_signature(changed, false) != signature,
		"source radiance changes alter the persisted input signature")
	var invalid_direction := sources.duplicate(true)
	invalid_direction[0]["direction_world"] = Vector3.ZERO
	var invalid_direction_signature := Data.baked_directional_source_signature(invalid_direction, false)
	_check(not Data.is_valid_baked_indirect_directional_provenance(algorithm,
			invalid_direction_signature, _directional_provenance(invalid_direction, false)),
		"zero direction is rejected even when the altered record is re-signed")
	var invalid_type := sources.duplicate(true)
	invalid_type[0]["radiance_rgb"] = "not-a-vector"
	_check(Data.baked_directional_source_signature(invalid_type, false).is_empty(),
		"wrongly typed source radiance cannot be signed")
	var missing_signature := provenance.duplicate(true)
	missing_signature["sources"] = []
	_check(not Data.is_valid_baked_indirect_directional_provenance(algorithm,
			signature, missing_signature), "provenance cannot be paired with another source list")
	var sky_only: Array[Dictionary] = []
	sky_only.append(_sky_only_source.duplicate(true))
	_check(Data.is_valid_baked_indirect_directional_provenance(algorithm,
			Data.baked_directional_source_signature(sky_only, false),
			_directional_provenance(sky_only, false)),
		"sky-only provenance is accepted while its separate NEE candidate count is zero")
	_check(Data.baked_directional_source_signature([], false) != ""
			and Data.is_valid_baked_indirect_directional_provenance(algorithm,
			Data.baked_directional_source_signature([], false), _directional_provenance([], false)),
		"explicitly empty directional snapshot is distinct from missing provenance")

func _test_worker_transient_merge() -> void:
	var data := Data.new()
	data.positions = PackedVector3Array([Vector3.ZERO, Vector3.ONE])
	data.normals = PackedVector3Array([Vector3.UP, Vector3.UP])
	data.transfer.resize(54)
	data.primary_sky_visibility.resize(18)
	data.visibility_moments.resize(2 * Data.VISIBILITY_TEXELS_PER_PROBE * 2)
	data.emitter_transport = PackedFloat32Array()
	data.directional = DirectionalData.new()
	data.directional.allocate(2, 0)
	data.prepare_bake_exact_directional_secondary()
	_check(data.bake_exact_directional_secondary.size() == 54
			and data.bake_exact_directional_secondary_valid == false
			and data.validate_bake_exact_directional_secondary() == false,
		"transient allocation is zeroed but not ready before every probe completes")
	for probe in 2:
		var job := BakeJob.new()
		job.initialize(data, probe)
		var values := PackedFloat32Array()
		values.resize(27)
		for lane in 27:
			values[lane] = float(probe + 1) * float(lane + 1) * 0.125
		job.result.bake_exact_directional_secondary = values
		job.result.bake_exact_directional_secondary_valid = true
		job.valid = true
		job.merge(data, probe)
		if probe == 0:
			_check(not data.validate_bake_exact_directional_secondary(),
				"a partially merged worker set cannot publish an SH field")
	_check(data.validate_bake_exact_directional_secondary()
			and data.bake_exact_directional_secondary[0] == 0.125
			and data.bake_exact_directional_secondary[27] == 0.25,
		"worker merge writes 27 finite lanes into probe-major offsets and marks completion")
	data.bake_exact_directional_secondary[7] = NAN
	_check(not data.validate_bake_exact_directional_secondary(),
		"non-finite transient NEE output invalidates final composition")
	data.clear_bake_exact_directional_secondary()
	_check(data.bake_exact_directional_secondary.is_empty()
			and not data.bake_exact_directional_secondary_valid,
		"worker-only NEE buffer is cleared after composition")

func _test_full_compose() -> void:
	var sky := PackedFloat32Array()
	sky.resize(27)
	sky[0] = 2.0
	sky[1] = 3.0
	sky[2] = 4.0
	var source_array: Array[Dictionary] = [_eligible_source.duplicate(true)]
	var sets := _lighting_sets(source_array, false, _eligible_direct, sky)
	var data := _make_compose_data()
	data.directional.transfer[0] = 0.25
	data.directional.transfer[1] = 0.5
	data.directional.transfer[2] = 0.75
	data.directional.sky[0] = 0.125
	data.directional.sky[1] = 0.25
	data.bake_exact_directional_secondary[0] = 5.0
	data.bake_exact_directional_secondary[1] = 6.0
	data.bake_exact_directional_secondary[2] = 7.0
	data._bake_exact_directional_probe_complete[0] = 1
	var expected := PackedFloat32Array([
		0.25 * 2.0 + 0.125 * 2.0 + 5.0,
		0.5 * 3.0 + 0.125 * 3.0 + 6.0,
		0.75 * 4.0 + 0.125 * 4.0 + 7.0])
	var baker := Baker.new()
	var composed := baker._build_baked_indirect_sh(data, sets, PackedFloat32Array())
	_check(composed and data.baked_indirect_sh_revision == Data.BAKED_INDIRECT_SH_REVISION
			and data.baked_indirect_sh_algorithm == Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE,
		"full compose publishes only after transient and source metadata validate")
	_check(data.baked_indirect_sh.size() == 27 and _first_rgb(data.baked_indirect_sh).is_equal_approx(
			Vector3(expected[0], expected[1], expected[2])),
		"final SH is Sky secondary + Sky primary + exact directional secondary exactly once")
	_check(data.baked_indirect_sh[3] == 0.0 and data.baked_indirect_sh[4] == 0.0
			and data.baked_indirect_sh[5] == 0.0,
		"only fixture-set transport lanes receive energy; source direct SH is not re-added")

	var changed_direct_sets := _lighting_sets(source_array, false,
		_perturb_sh(_eligible_direct, 32.0), sky)
	var changed_direct_data := _make_compose_data()
	changed_direct_data.directional.transfer = data.directional.transfer.duplicate()
	changed_direct_data.directional.sky = data.directional.sky.duplicate()
	changed_direct_data.bake_exact_directional_secondary = data.bake_exact_directional_secondary.duplicate()
	changed_direct_data._bake_exact_directional_probe_complete[0] = 1
	var changed_composed := baker._build_baked_indirect_sh(changed_direct_data,
		changed_direct_sets, PackedFloat32Array())
	_check(changed_composed and changed_direct_data.baked_indirect_sh == data.baked_indirect_sh,
		"composition relights legacy transport from Sky only and does not add direct SH a second time")
	var roundoff_sky := sky.duplicate()
	roundoff_sky[0] += 1.0e-5
	_check(Lighting._sky_snapshot_matches(sky, roundoff_sky, 1.0, 1.0),
		"normal bake end validation accepts observed-scale Sky capture roundoff")
	_check(not Lighting._sky_snapshot_matches(sky, roundoff_sky, 1.0, 1.001),
		"Sky radiance energy changes remain a strict bake rejection")

	var sky_only_sources: Array[Dictionary] = []
	sky_only_sources.append(_sky_only_source.duplicate(true))
	var sky_only_sets := _lighting_sets(sky_only_sources, false, _sky_only_direct, _zero_sh())
	var sky_only_data := _make_compose_data()
	sky_only_data.bake_exact_directional_secondary.fill(0.0)
	sky_only_data._bake_exact_directional_probe_complete[0] = 1
	var sky_only_count_sources: Array[Dictionary] = []
	sky_only_count_sources.append(_sky_only_source)
	_check(baker._eligible_directional_source_count(sky_only_count_sources) == 0
			and baker._build_baked_indirect_sh(sky_only_data, sky_only_sets,
			PackedFloat32Array()) and _all_zero(sky_only_data.baked_indirect_sh),
		"sky-only SH projection is not also baked as exact directional sunlight")

	var previous_payload := PackedFloat32Array()
	previous_payload.resize(27)
	previous_payload.fill(0.75)
	var rejected_data := _make_compose_data()
	rejected_data.baked_indirect_sh_revision = Data.BAKED_INDIRECT_SH_REVISION
	rejected_data.baked_indirect_sh = previous_payload.duplicate()
	rejected_data.baked_indirect_sh_algorithm = Data.BAKED_INDIRECT_SH_ALGORITHM_LEGACY
	rejected_data._invalidate_baked_indirect_sh_validation_cache()
	var invalid_sets := sets.duplicate(true)
	invalid_sets["directional_source_signature"] = "wrong-signature"
	_check(not baker._build_baked_indirect_sh(rejected_data, invalid_sets,
			PackedFloat32Array()) and rejected_data.baked_indirect_sh == previous_payload,
		"invalid source signature fails before replacing a prior saved SH payload")
	var unmerged_data := _make_compose_data()
	unmerged_data._bake_exact_directional_probe_complete[0] = 0
	_check(not baker._build_baked_indirect_sh(unmerged_data, sets, PackedFloat32Array())
			and unmerged_data.baked_indirect_sh_revision == 0,
		"incomplete transient probes fail closed before publication")

func _test_streamed_generation_contract() -> void:
	var data := _make_valid_data()
	data.baked_indirect_sh_revision = Data.BAKED_INDIRECT_SH_REVISION
	data.baked_indirect_sh.resize(27)
	data.baked_indirect_sh.fill(0.25)
	data.baked_indirect_sh_algorithm = Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE
	data.baked_indirect_lighting_signature = 4321
	data.baked_indirect_emission_signature = 8765
	var sources: Array[Dictionary] = [_eligible_source.duplicate(true)]
	var directional_signature := Data.baked_directional_source_signature(sources, false)
	var directional_provenance := _directional_provenance(sources, false)
	var sky_values := PackedFloat32Array()
	sky_values.resize(27)
	sky_values[0] = 1.0
	var sky_provenance := _sky_provenance(sky_values)
	data.baked_indirect_sky_provenance = sky_provenance.duplicate(true)
	data.baked_indirect_directional_source_signature = directional_signature
	data.baked_indirect_directional_source_provenance = directional_provenance.duplicate(true)
	data._invalidate_baked_indirect_sh_validation_cache()
	_check(data.is_valid() and data.has_baked_indirect_sh(),
		"new Data payload validates both baked SH and source provenance")

	var page := _make_page(data, "generation-A", "page-A", "res://fixture_page.res", "content-A")
	_check(page.has_baked_indirect_sh(), "streamed Page agrees with its Data revision and provenance")
	var mismatched_page := _make_page(data, "generation-A", "page-A-mismatch",
			"res://fixture_page_mismatch.res", "content-A")
	mismatched_page.baked_indirect_directional_source_signature = "stale-generation-source"
	_check(not mismatched_page.has_baked_indirect_sh(),
		"Page rejects source provenance that differs from its own Data payload")

	var page_entry := _manifest_entry(page.page_key, page.generation, page.core_bounds,
		page.support_bounds, page.probe_count, page.cpu_bytes, page.gpu_bytes,
		page.resource_path, "content-A", directional_signature, sky_provenance)
	var empty_entry := _manifest_entry("empty-B", page.generation,
		AABB(Vector3(2, 0, 0), Vector3.ONE), AABB(Vector3(2, 0, 0), Vector3.ONE).grow(0.5),
		0, 0, 0, "", "", directional_signature, sky_provenance)
	empty_entry["empty"] = true
	var manifest := _make_manifest(page.generation, directional_signature,
		directional_provenance, sky_provenance, [page_entry, empty_entry])
	_check(manifest.is_valid() and manifest.has_baked_indirect_sh(),
		"stream manifest validates the matching nonempty page and explicitly empty page")
	var bad_entry: Dictionary = page_entry.duplicate(true)
	bad_entry["baked_indirect_sh_algorithm"] = Data.BAKED_INDIRECT_SH_ALGORITHM_LEGACY
	var bad_manifest := _make_manifest(page.generation, directional_signature,
		directional_provenance, sky_provenance, [bad_entry])
	_check(bad_manifest.is_valid() and not bad_manifest.has_baked_indirect_sh(),
		"generic manifest remains readable while mismatched SH generation fails backend readiness")
	var legacy_manifest := _make_manifest("legacy-generation", "", {}, {}, [page_entry])
	legacy_manifest.baked_indirect_sh_algorithm = ""
	legacy_manifest.baked_indirect_sh_revision = Data.BAKED_INDIRECT_SH_REVISION
	_check(legacy_manifest.is_valid() and not legacy_manifest.has_baked_indirect_sh(),
		"legacy revision-2 transport remains structurally readable without backend-1 provenance")
	var legacy_data := Data.new()
	legacy_data.positions = PackedVector3Array([Vector3.ZERO])
	legacy_data.baked_indirect_sh_revision = Data.BAKED_INDIRECT_SH_REVISION
	legacy_data.baked_indirect_sh.resize(27)
	legacy_data.baked_indirect_sh.fill(0.5)
	_check(legacy_data.has_legacy_baked_indirect_sh_payload()
			and not legacy_data.has_baked_indirect_sh(),
		"legacy SH payload keeps its legacy-read route but cannot masquerade as exact-NEE ready")

	var streamer := PageStreamer.new()
	streamer.set_manifest(manifest)
	var record := {"path": page.resource_path, "content_hash": "content-A"}
	_check(streamer._record_matches_current_manifest(page.page_key, record),
		"streamer accepts a page record only when its path and content hash match the generation")
	record["content_hash"] = "other-generation-content"
	_check(not streamer._record_matches_current_manifest(page.page_key, record),
		"streamer rejects stale page content under a current source generation")
	streamer.deactivate()

func _make_compose_data() -> Resource:
	var data: Resource = Data.new()
	data.positions = PackedVector3Array([Vector3.ZERO])
	data.normals = PackedVector3Array([Vector3.UP])
	data.transfer.resize(27)
	data.primary_sky_visibility.resize(9)
	data.emitter_transport = PackedFloat32Array()
	data.directional = DirectionalData.new()
	data.directional.allocate(1, 0)
	data.prepare_bake_exact_directional_secondary()
	data._bake_exact_directional_probe_complete[0] = 1
	return data

func _make_valid_data() -> Resource:
	var data: Resource = Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = Vector3i.ONE
	data.volume_transform = Transform3D.IDENTITY
	data.world_to_grid = Transform3D.IDENTITY
	data.volume_size = Vector3.ONE
	data.spacing = 1.0
	data.adaptive_placement = false
	data.minimum_probe_spacing = 0.25
	data.surface_offset = 0.03
	data.bake_samples = 1
	data.bake_bounces = 1
	data.bake_distance = 1.0
	data.terrain_reflectance = 0.5
	data.material_reflectance = 0.5
	data.bake_version = 1
	data.positions = PackedVector3Array([Vector3(0.5, 0.53, 0.5)])
	data.surface_positions = PackedVector3Array([Vector3(0.5, 0.5, 0.5)])
	data.normals = PackedVector3Array([Vector3.UP])
	data.transfer.resize(27)
	data.primary_sky_visibility.resize(9)
	data.visibility_moments.resize(Data.VISIBILITY_TEXELS_PER_PROBE * 2)
	data.directional = DirectionalData.new()
	data.directional.allocate(1, 0)
	var geometry := Visibility.build(PackedVector3Array([
		Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(0, 0, 1)]))
	data.visibility_nodes = geometry.nodes
	data.visibility_triangles = geometry.triangles
	data.build_cell_indices()
	return data

func _make_page(data: Resource, generation: String, page_key: String,
		page_path: String, content_hash: String) -> Resource:
	var page: Resource = Page.new()
	page.generation = generation
	page.page_key = page_key
	page.core_bounds = AABB(Vector3.ZERO, Vector3.ONE)
	page.support_bounds = page.core_bounds.grow(0.5)
	page.probe_count = data.probe_count()
	page.gpu_bytes = data.estimate_gpu_bytes()
	page.cpu_bytes = data.estimate_cpu_bytes() + page.gpu_bytes
	page.geometry_signature = data.scene_signature
	page.settings_signature = 10
	page.baked_indirect_sh_revision = data.baked_indirect_sh_revision
	page.baked_indirect_sh_algorithm = data.baked_indirect_sh_algorithm
	page.baked_indirect_directional_source_signature = data.baked_indirect_directional_source_signature
	page.baked_indirect_directional_source_provenance = data.baked_indirect_directional_source_provenance.duplicate(true)
	page.baked_indirect_sky_provenance = data.baked_indirect_sky_provenance.duplicate(true)
	page.data = data
	page.resource_path = page_path
	page.set_meta("fixture_content_hash", content_hash)
	return page

func _manifest_entry(page_key: String, generation: String, core: AABB, support: AABB,
		probes: int, cpu_bytes: int, gpu_bytes: int, page_path: String,
		content_hash: String, directional_signature: String,
		sky_provenance: Dictionary) -> Dictionary:
	return {
		"page_key": page_key,
		"page_generation": generation,
		"core_bounds": core,
		"support_bounds": support,
		"influence_bounds": support.grow(1.0),
		"probe_count": probes,
		"cpu_bytes": cpu_bytes,
		"gpu_bytes": gpu_bytes,
		"version": 1,
		"resource_path": page_path,
		"content_hash": content_hash,
		"empty": false,
		"baked_indirect_sh_revision": Data.BAKED_INDIRECT_SH_REVISION,
		"baked_indirect_sh_algorithm": Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE,
		"baked_indirect_directional_source_signature": directional_signature,
		"baked_indirect_sky_provenance": sky_provenance.duplicate(true),
	}

func _make_manifest(generation: String, directional_signature: String,
		directional_provenance: Dictionary, sky_provenance: Dictionary,
		entries: Array) -> Resource:
	var manifest: Resource = Manifest.new()
	manifest.generation = generation
	manifest.manifest_key = "fixture-manifest"
	manifest.world_bounds = AABB(Vector3.ZERO, Vector3(4, 1, 1))
	manifest.management_block_size = 512.0
	manifest.page_core_size = 32.0
	manifest.baked_indirect_sh_revision = Data.BAKED_INDIRECT_SH_REVISION
	manifest.baked_indirect_lighting_signature = 4321
	manifest.baked_indirect_sh_algorithm = Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE
	manifest.baked_indirect_directional_source_signature = directional_signature
	manifest.baked_indirect_directional_source_provenance = directional_provenance.duplicate(true)
	manifest.baked_indirect_sky_provenance = sky_provenance.duplicate(true)
	var typed_entries: Array[Dictionary] = []
	for entry_value in entries:
		var entry: Dictionary = entry_value
		typed_entries.append(entry.duplicate(true))
	manifest.configure(typed_entries)
	return manifest

func _lighting_sets(sources: Array[Dictionary], physical: bool,
		direct: PackedFloat32Array, sky: PackedFloat32Array) -> Dictionary:
	var combined := direct.duplicate()
	for i in 27:
		combined[i] += sky[i]
	return {
		"lighting": combined,
		"sky_lighting": sky.duplicate(),
		"direct_lighting": direct.duplicate(),
		"sky_snapshot_status": "verified_ready_sky",
		"sky_source": "fixture-sky",
		"sky_source_mode": 0,
		"sky_source_revision": 1,
		"sky_radiance_energy": 1.0,
		"sky_radiance_sh": sky.duplicate(),
		"sky_input_signature": Data.baked_sky_input_signature(sky, 1.0),
		"directional_sources": sources.duplicate(true),
		"directional_source_signature": Data.baked_directional_source_signature(sources, physical),
		"directional_physical_units": physical,
	}

func _directional_provenance(sources: Array, physical: bool) -> Dictionary:
	return {
		"schema_version": Data.BAKED_DIRECTIONAL_SOURCE_SCHEMA_VERSION,
		"source_scale_convention": "godot_directional_nee_q_v1",
		"visibility_contract": "all_collected_static_triangles_v1",
		"angular_source_contract": "collimated_directional_v1",
		"light_masks_contract": "recorded_not_applied_to_bvh_v1",
		"physical_units": physical,
		"sources": sources.duplicate(true),
	}

func _sky_provenance(radiance: PackedFloat32Array) -> Dictionary:
	return {
		"schema_version": 1,
		"status": "verified_ready_sky",
		"source": "fixture-sky",
		"source_mode": 0,
		"source_revision": 1,
		"radiance_unit": "scene_linear_radiance",
		"radiance_energy": 1.0,
		"radiance_sh": radiance.duplicate(),
		"input_signature": Data.baked_sky_input_signature(radiance, 1.0),
	}

func _first_rgb(values: PackedFloat32Array) -> Vector3:
	return Vector3(values[0], values[1], values[2]) if values.size() >= 3 else Vector3.ZERO

func _perturb_sh(values: PackedFloat32Array, amount: float) -> PackedFloat32Array:
	var result := values.duplicate()
	if not result.is_empty():
		result[0] += amount
	return result

func _zero_sh() -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(27)
	result.fill(0.0)
	return result

func _all_zero(values: PackedFloat32Array) -> bool:
	for value in values:
		if value != 0.0:
			return false
	return true

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: " + message)
	else:
		_failures += 1
		push_error("FAIL: " + message)
