@tool
class_name FMagicGILighting
extends RefCounted
## Projects dynamic distant sources into world-space SH. Primary SkyLight
## radiance is published separately from the combined secondary lighting.

const Data = preload("feng_magic_gi_data.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const SKY_LIGHT_RUNTIME_PATH := "res://addons/feng-sky/feng_sky_light_runtime.gd"
const SCENE_SCAN_MSEC := 500
const SKY_BAKE_READY_TIMEOUT_MSEC := 30000
const SKY_SNAPSHOT_EXPLICIT_NO_SKY := "explicit_no_sky"
const SKY_SNAPSHOT_VERIFIED_READY := "verified_ready_sky"
const SKY_SNAPSHOT_UNAVAILABLE := "unavailable_or_invalid"

var _lights: Array[DirectionalLight3D] = []
var _world: World3D
var _next_scan := 0
var _lighting_signature := 0
var revision := 0
var _sky_sh := PackedFloat32Array()
var _cached_result := PackedFloat32Array()
var _cached_direct_result := PackedFloat32Array()
var _sky_light_runtime: Script


func _init() -> void:
	if ResourceLoader.exists(SKY_LIGHT_RUNTIME_PATH):
		_sky_light_runtime = load(SKY_LIGHT_RUNTIME_PATH) as Script

func coefficients(volume: Node3D) -> PackedFloat32Array:
	return coefficient_sets(volume).get("lighting", PackedFloat32Array())

## Returns secondary lighting (SkyLight + DirectionalLight) and the SkyLight-only
## source SH used by v4 primary transport. Both are cached from one world snapshot.
func coefficient_sets(volume: Node3D, sky_snapshot_override: Variant = null) -> Dictionary:
	if volume == null or not is_instance_valid(volume):
		return {"lighting": _zero_sh(), "sky_lighting": _zero_sh(), "direct_lighting": _zero_sh()}
	var world := volume.get_world_3d()
	var now := Time.get_ticks_msec()
	if world != _world or now >= _next_scan:
		_scan_scene(volume)
		_next_scan = now + SCENE_SCAN_MSEC

	var lights: Array[DirectionalLight3D] = []
	var explicit_light: Variant = volume.get("sun")
	if explicit_light is DirectionalLight3D and explicit_light.is_inside_tree() \
			and explicit_light.get_world_3d() == world:
		lights.append(explicit_light)
	else:
		lights = _lights
	var physical_units := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))
	var current_lighting_signature := hash([_source_fingerprint(lights, world), physical_units])
	var sky_only := _read_sky_light(world, sky_snapshot_override)
	if current_lighting_signature == _lighting_signature and sky_only == _sky_sh and not _cached_result.is_empty():
		return {"lighting": _cached_result, "sky_lighting": _sky_sh,
			"direct_lighting": _cached_direct_result}
	_lighting_signature = current_lighting_signature
	var previous_sky := _sky_sh
	_sky_sh = sky_only

	var result := PackedFloat32Array()
	result.resize(27)
	for light in lights:
		if not is_instance_valid(light) or not light.is_inside_tree() or not light.is_visible_in_tree() \
				or light.get_world_3d() != world:
			continue
		# Godot's renderer uses local +Z as the source direction, which is also
		# the receiver-to-source direction expected by the transport SH.
		var source_direction := light.global_basis.z.normalized()
		var color: Color = light.light_color.srgb_to_linear()
		var energy := light.light_energy * light.light_indirect_energy
		if physical_units:
			energy *= float(light.get("light_intensity_lux"))
			color *= light.get_correlated_color().srgb_to_linear()
		else:
			energy *= PI # Matches light_storage.cpp's non-physical DirectionalLightData scale.
		if light.light_negative:
			energy *= -1.0
		var basis := Data.sh_basis(source_direction)
		for k in 9:
			result[k * 3] += color.r * energy * basis[k]
			result[k * 3 + 1] += color.g * energy * basis[k]
			result[k * 3 + 2] += color.b * energy * basis[k]
	var direct_result: PackedFloat32Array = result.duplicate()
	for i in 27:
		result[i] += sky_only[i]
	if _cached_result != result or previous_sky != sky_only:
		revision += 1
	_cached_result = result
	_cached_direct_result = direct_result
	return {"lighting": _cached_result, "sky_lighting": _sky_sh,
		"direct_lighting": _cached_direct_result}

## Bake-only capture contract. The live renderer keeps the historical zero fallback,
## but a bake may use zero only when the active World3D has no primary ambient source.
## A present FengSky provider must produce a finite, ready SH snapshot first.
func _capture_bake_coefficient_sets(volume: Node3D, cancelled: Callable = Callable()) -> Dictionary:
	if volume == null or not is_instance_valid(volume) or not volume.is_inside_tree():
		return {"ready": false, "error": "The MagicGI Volume left the scene before Sky capture."}
	var world := volume.get_world_3d()
	if world == null:
		return {"ready": false, "error": "The MagicGI Volume has no World3D for bake-time Sky capture."}
	var provider_info := _find_sky_provider(volume, world)
	if provider_info.has("error"):
		return {"ready": false, "error": String(provider_info.get("error", "FengSkyLight provider is outside the bake scope.")),
			"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
	var sky_provider_path := String(provider_info.get("path", ""))
	var provider_candidates: Array = provider_info.get("candidates", [])
	var ambient_contract := _world_ambient_contract(world)
	if not bool(ambient_contract.get("supported", false)):
		return {"ready": false, "error": String(ambient_contract.get("error", "Unsupported Environment ambient source.")),
			"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
	if sky_provider_path.is_empty() and provider_candidates.is_empty():
		if bool(ambient_contract.get("requires_sky", false)):
			return {"ready": false, "error": "World3D has a Sky ambient source but no FengSkyLight capture provider; bake was rejected instead of storing zero Sky SH.",
				"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
		var no_sky_sets := coefficient_sets(volume, {})
		var directional_capture := _attach_bake_directional_snapshot(volume, no_sky_sets)
		if not bool(directional_capture.get("ready", false)):
			return directional_capture
		no_sky_sets["sky_snapshot_status"] = SKY_SNAPSHOT_EXPLICIT_NO_SKY
		no_sky_sets["sky_source"] = "none"
		no_sky_sets["sky_source_mode"] = -1
		no_sky_sets["sky_source_revision"] = -1 # Diagnostic only; never part of the stable signature.
		no_sky_sets["sky_radiance_energy"] = 0.0
		no_sky_sets["sky_radiance_sh"] = _zero_sh()
		no_sky_sets["sky_input_signature"] = Data.baked_sky_input_signature(
				no_sky_sets["sky_radiance_sh"], 0.0)
		return {"ready": true, "coefficient_sets": no_sky_sets,
			"sky_snapshot_status": SKY_SNAPSHOT_EXPLICIT_NO_SKY,
			"runtime_snapshot": {}}
	if _sky_light_runtime == null or not _sky_light_runtime.has_method("active_for_world") \
			or not _sky_light_runtime.has_method("snapshot_for_world"):
		return {"ready": false, "error": "A FengSkyLight provider exists, but its runtime snapshot API is unavailable.",
			"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
	var deadline := Time.get_ticks_msec() + SKY_BAKE_READY_TIMEOUT_MSEC
	var tree := volume.get_tree()
	var capture_provider_id := 0
	var source_revision_before_capture := -1
	var capture_position_before: Variant = null
	var source_mode_before_capture := -1
	var requires_fresh_capture := false
	var source_was_bake_loaded := false
	while Time.get_ticks_msec() < deadline:
		if not is_instance_valid(volume) or not volume.is_inside_tree():
			return {"ready": false, "error": "The MagicGI Volume left the scene while waiting for FengSkyLight.",
				"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
		if cancelled.is_valid() and bool(cancelled.call()):
			return {"ready": false, "error": "Bake was cancelled while waiting for FengSkyLight.",
				"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
		var active_provider: Variant = _sky_light_runtime.call("active_for_world", world.get_instance_id())
		if active_provider is Object and is_instance_valid(active_provider):
			var active_info := _sky_provider_scope_info(volume, world, active_provider)
			if active_info.has("error"):
				return {"ready": false, "error": String(active_info.get("error")),
					"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
			var active_provider_id: int = active_provider.get_instance_id()
			if capture_provider_id == 0:
				if not active_provider.has_method("_feng_sky_light_bake_capture_state"):
					return {"ready": false, "error": "The active FengSkyLight lacks the read-only bake capture handshake.",
						"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
				var initial_state: Variant = active_provider.call("_feng_sky_light_bake_capture_state")
				if not initial_state is Dictionary \
						or int(initial_state.get("provider_id", 0)) != active_provider_id:
					return {"ready": false, "error": "FengSkyLight returned invalid bake capture state.",
						"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
				capture_provider_id = active_provider_id
				source_was_bake_loaded = bool(initial_state.get("bake_loaded", false))
				requires_fresh_capture = not source_was_bake_loaded
				source_revision_before_capture = int(initial_state.get("source_revision", -1))
				source_mode_before_capture = int(initial_state.get("source_mode", -1))
				capture_position_before = initial_state.get("capture_position")
				if requires_fresh_capture:
					if not active_provider.has_method("recapture"):
						return {"ready": false, "error": "The active FengSkyLight cannot request a fresh bake capture.",
							"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
					active_provider.call("recapture")
					if tree == null:
						break
					await tree.process_frame
					continue
			elif active_provider_id != capture_provider_id:
				return {"ready": false, "error": "The active FengSkyLight provider changed while refreshing the bake capture.",
					"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
			var snapshot: Variant = _sky_light_runtime.call("snapshot_for_world", world.get_instance_id())
			if snapshot is Dictionary and not snapshot.is_empty() \
					and bool(snapshot.get("ready", false)) and not _valid_sky_snapshot(snapshot):
				return {"ready": false, "error": "FengSkyLight marked its bake-time snapshot ready but supplied invalid radiance metadata.",
					"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
			if _valid_sky_snapshot(snapshot):
				var capture_state: Variant = active_provider.call("_feng_sky_light_bake_capture_state")
				if not capture_state is Dictionary \
						or int(capture_state.get("provider_id", 0)) != active_provider_id \
						or not bool(capture_state.get("ready", false)) \
						or not bool(capture_state.get("projection_current", false)):
					return {"ready": false, "error": "FengSkyLight's ready bake snapshot does not match its completed radiance projection.",
						"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
				if requires_fresh_capture:
					if int(capture_state.get("source_revision", -1)) <= source_revision_before_capture \
							or bool(capture_state.get("dirty", false)) \
							or bool(capture_state.get("pending", false)) \
							or bool(capture_state.get("in_flight", false)):
						if tree == null:
							break
						await tree.process_frame
						continue
					var verify_start_position := source_mode_before_capture == 0 \
							and int(snapshot.get("source_mode", -1)) == 0
					if not _bake_capture_position_matches(capture_position_before,
							capture_state.get("capture_position"), verify_start_position):
						return {"ready": false, "error": "FengSkyLight captured-scene position changed while waiting for the fresh bake capture.",
							"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
				elif not bool(capture_state.get("bake_loaded", false)):
					return {"ready": false, "error": "The loaded FengSkyLight bake source changed while capturing MagicGI inputs.",
						"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
				var captured_sets := coefficient_sets(volume, snapshot)
				var directional_capture := _attach_bake_directional_snapshot(volume, captured_sets)
				if not bool(directional_capture.get("ready", false)):
					return directional_capture
				var sky_sh: PackedFloat32Array = snapshot["radiance_sh"]
				var energy := float(snapshot.get("energy", 1.0))
				if captured_sets["sky_lighting"] != sky_sh or not is_finite(energy) or energy < 0.0 \
						or int(snapshot.get("provider_id", active_provider.get_instance_id())) != active_provider.get_instance_id():
					return {"ready": false, "error": "FengSkyLight returned an inconsistent bake-time SH snapshot.",
						"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}
				captured_sets["sky_snapshot_status"] = SKY_SNAPSHOT_VERIFIED_READY
				captured_sets["sky_source"] = String(active_info.get("path", ""))
				captured_sets["sky_source_mode"] = int(snapshot.get("source_mode", -1))
				captured_sets["sky_source_revision"] = int(snapshot.get("source_revision", -1))
				captured_sets["sky_radiance_energy"] = energy
				captured_sets["sky_radiance_sh"] = sky_sh.duplicate()
				captured_sets["sky_capture_requires_fresh"] = requires_fresh_capture
				captured_sets["sky_capture_source_was_bake_loaded"] = source_was_bake_loaded
				captured_sets["sky_capture_provider_id"] = active_provider_id
				captured_sets["sky_capture_revision_before"] = source_revision_before_capture
				captured_sets["sky_capture_input_revision"] = int(capture_state.get("input_revision", -1))
				captured_sets["sky_capture_source_identity"] = capture_state.get("source_identity", [])
				captured_sets["sky_capture_position"] = capture_position_before
				# SkySH is already in world axes and includes radiance_energy. Keep energy
				# in the stable input key as an auditable source configuration value.
				captured_sets["sky_input_signature"] = Data.baked_sky_input_signature(sky_sh, energy)
				return {"ready": true, "coefficient_sets": captured_sets,
					"sky_snapshot_status": SKY_SNAPSHOT_VERIFIED_READY,
					"runtime_snapshot": snapshot.duplicate(true)}
		if tree == null:
			break
		await tree.process_frame
	return {"ready": false, "error": "FengSkyLight did not produce a valid ready radiance SH snapshot within %d ms." % SKY_BAKE_READY_TIMEOUT_MSEC,
		"sky_snapshot_status": SKY_SNAPSHOT_UNAVAILABLE}

func _valid_sky_snapshot(snapshot: Variant) -> bool:
	if not snapshot is Dictionary or not bool(snapshot.get("ready", false)):
		return false
	var coefficients: Variant = snapshot.get("radiance_sh")
	if not coefficients is PackedFloat32Array or coefficients.size() != 27:
		return false
	for value in coefficients:
		if not is_finite(value):
			return false
	var energy := float(snapshot.get("energy", NAN))
	return is_finite(energy) and energy >= 0.0 \
			and int(snapshot.get("source_mode", -1)) >= 0 \
			and int(snapshot.get("source_revision", -1)) >= 0

static func _sky_snapshot_matches(captured_value: Variant, current_value: Variant,
		captured_energy: float, current_energy: float) -> bool:
	if not is_finite(captured_energy) or not is_finite(current_energy) \
			or captured_energy != current_energy:
		return false
	if not captured_value is PackedFloat32Array or not current_value is PackedFloat32Array:
		return false
	var captured: PackedFloat32Array = captured_value
	var current: PackedFloat32Array = current_value
	if captured.size() != 27 or current.size() != 27:
		return false
	var reference_max := 0.0
	var reference_l2_squared := 0.0
	var delta_max := 0.0
	var delta_l2_squared := 0.0
	for i in 27:
		var reference_value := float(captured[i])
		var current_coefficient := float(current[i])
		if not is_finite(reference_value) or not is_finite(current_coefficient):
			return false
		var delta := absf(current_coefficient - reference_value)
		reference_max = maxf(reference_max, absf(reference_value))
		reference_l2_squared += reference_value * reference_value
		delta_max = maxf(delta_max, delta)
		delta_l2_squared += delta * delta
	if reference_max <= 1.0e-6:
		return delta_max <= 1.0e-6
	var relative_l2 := sqrt(delta_l2_squared / reference_l2_squared)
	var max_scaled_error := delta_max / reference_max
	return is_finite(relative_l2) and is_finite(max_scaled_error) \
			and relative_l2 <= 1.0e-4 and max_scaled_error <= 1.0e-4

static func _bake_capture_position_matches(captured: Variant, current: Variant,
		requires_fresh_scene_capture: bool) -> bool:
	if not requires_fresh_scene_capture:
		return true
	return captured is Vector3 and current is Vector3 and captured == current

static func _direct_lighting_matches(captured: Variant, current: Variant) -> bool:
	if not captured is PackedFloat32Array or not current is PackedFloat32Array:
		return false
	var captured_coefficients: PackedFloat32Array = captured
	var current_coefficients: PackedFloat32Array = current
	return captured_coefficients.size() == 27 and current_coefficients.size() == 27 \
			and captured_coefficients == current_coefficients

## Synchronous end-of-bake verification. This never waits and never replaces the
## frozen bake inputs; it only rejects a generation whose Sky source changed.
func _validate_bake_coefficient_capture(volume: Node3D, captured_sets: Dictionary) -> Dictionary:
	if volume == null or not is_instance_valid(volume) or not volume.is_inside_tree():
		return {"ready": false, "error": "The MagicGI Volume left the scene during bake."}
	var world := volume.get_world_3d()
	if world == null:
		return {"ready": false, "error": "The MagicGI Volume lost its World3D during bake."}
	var expected_status := String(captured_sets.get("sky_snapshot_status", ""))
	var ambient_contract := _world_ambient_contract(world)
	if not bool(ambient_contract.get("supported", false)):
		return {"ready": false, "error": String(ambient_contract.get("error", "Environment ambient source changed during bake."))}
	var provider_info := _find_sky_provider(volume, world)
	if expected_status == SKY_SNAPSHOT_EXPLICIT_NO_SKY:
		if _sky_light_runtime != null and _sky_light_runtime.has_method("active_for_world"):
			var active_provider: Variant = _sky_light_runtime.call("active_for_world", world.get_instance_id())
			if active_provider != null and is_instance_valid(active_provider):
				return {"ready": false, "error": "A FengSkyLight provider became active during an explicit-no-Sky bake."}
		if not String(provider_info.get("path", "")).is_empty() \
				or not Array(provider_info.get("candidates", [])).is_empty() \
				or bool(ambient_contract.get("requires_sky", false)):
			return {"ready": false, "error": "A Sky source appeared during bake; the explicit-no-Sky snapshot is stale."}
		var current_sets := coefficient_sets(volume, {})
		var directional_capture := _attach_bake_directional_snapshot(volume, current_sets)
		if not bool(directional_capture.get("ready", false)):
			return directional_capture
		if String(directional_capture.get("directional_source_signature", "")) \
				!= String(captured_sets.get("directional_source_signature", "")):
			return {"ready": false, "error": "DirectionalLight source configuration changed during bake."}
		return {"ready": true, "coefficient_sets": captured_sets}
	if expected_status != SKY_SNAPSHOT_VERIFIED_READY:
		return {"ready": false, "error": "Bake has no validated Sky snapshot provenance."}
	if provider_info.has("error") \
			or String(provider_info.get("path", "")) != String(captured_sets.get("sky_source", "")) \
			or _sky_light_runtime == null \
			or not _sky_light_runtime.has_method("active_for_world") \
			or not _sky_light_runtime.has_method("snapshot_for_world"):
		return {"ready": false, "error": "The FengSkyLight provider changed during bake."}
	var active_provider: Variant = _sky_light_runtime.call("active_for_world", world.get_instance_id())
	var active_info := _sky_provider_scope_info(volume, world, active_provider)
	var snapshot: Variant = _sky_light_runtime.call("snapshot_for_world", world.get_instance_id())
	if active_provider == null or not is_instance_valid(active_provider) \
			or active_info.has("error") \
			or String(active_info.get("path", "")) != String(captured_sets.get("sky_source", "")) \
			or not _valid_sky_snapshot(snapshot):
		return {"ready": false, "error": "FengSkyLight became unavailable or invalid before bake publication."}
	if not active_provider.has_method("_feng_sky_light_bake_capture_state"):
		return {"ready": false, "error": "The active FengSkyLight lost its read-only bake capture handshake."}
	var capture_state: Variant = active_provider.call("_feng_sky_light_bake_capture_state")
	if not capture_state is Dictionary \
			or int(capture_state.get("provider_id", 0)) != active_provider.get_instance_id() \
			or not bool(capture_state.get("ready", false)) \
			or not bool(capture_state.get("projection_current", false)):
		return {"ready": false, "error": "FengSkyLight source configuration changed or its completed radiance projection became invalid during bake."}
	if bool(capture_state.get("bake_loaded", false)) \
			!= bool(captured_sets.get("sky_capture_source_was_bake_loaded", false)):
		return {"ready": false, "error": "FengSkyLight switched between loaded bake data and live capture during bake."}
	var verify_capture_position := bool(captured_sets.get("sky_capture_requires_fresh", false)) \
			and int(captured_sets.get("sky_source_mode", -1)) == 0
	if not _bake_capture_position_matches(captured_sets.get("sky_capture_position"),
			capture_state.get("capture_position"), verify_capture_position):
		return {"ready": false, "error": "FengSkyLight captured-scene position changed during bake."}
	if bool(captured_sets.get("sky_capture_requires_fresh", false)):
		var periodic_capture_active := bool(capture_state.get("pending", false)) \
				or bool(capture_state.get("in_flight", false))
		if bool(capture_state.get("dirty", false)) and not periodic_capture_active:
			return {"ready": false, "error": "FengSkyLight has unapplied source configuration changes at bake publication."}
		if int(capture_state.get("source_revision", -1)) \
				<= int(captured_sets.get("sky_capture_revision_before", -1)):
			return {"ready": false, "error": "FengSkyLight did not retain a newer completed capture for this bake generation."}
		if int(capture_state.get("input_revision", -1)) \
				!= int(captured_sets.get("sky_capture_input_revision", -2)) \
				or capture_state.get("source_identity", []) \
				!= captured_sets.get("sky_capture_source_identity", []):
			return {"ready": false, "error": "FengSkyLight source configuration changed during bake."}
	if int(snapshot.get("provider_id", active_provider.get_instance_id())) != active_provider.get_instance_id() \
			or int(snapshot.get("source_mode", -1)) != int(captured_sets.get("sky_source_mode", -2)):
		return {"ready": false, "error": "FengSkyLight source identity or mode changed during bake."}
	var current_sh: PackedFloat32Array = snapshot["radiance_sh"]
	var current_energy := float(snapshot.get("energy", NAN))
	var captured_energy := float(captured_sets.get("sky_radiance_energy", NAN))
	var captured_sh: Variant = captured_sets.get("sky_radiance_sh", PackedFloat32Array())
	var frozen_signature := ""
	if captured_sh is PackedFloat32Array:
		frozen_signature = Data.baked_sky_input_signature(captured_sh, captured_energy)
	if frozen_signature.is_empty() \
			or frozen_signature != String(captured_sets.get("sky_input_signature", "")):
		return {"ready": false, "error": "The frozen Sky input signature is invalid; bake was rejected."}
	if not _sky_snapshot_matches(captured_sh, current_sh, captured_energy, current_energy):
		return {"ready": false, "error": "Sky radiance changed beyond capture tolerance during bake; the frozen indirect field was discarded."}
	var current_sets := coefficient_sets(volume, snapshot)
	var directional_capture := _attach_bake_directional_snapshot(volume, current_sets)
	if not bool(directional_capture.get("ready", false)):
		return directional_capture
	var captured_direct: Variant = captured_sets.get("direct_lighting", PackedFloat32Array())
	var current_direct: Variant = current_sets.get("direct_lighting", PackedFloat32Array())
	if not _direct_lighting_matches(captured_direct, current_direct):
		return {"ready": false, "error": "Directional lighting changed during bake; the frozen indirect field was discarded."}
	if String(directional_capture.get("directional_source_signature", "")) \
			!= String(captured_sets.get("directional_source_signature", "")):
		return {"ready": false, "error": "DirectionalLight source configuration changed during bake; the frozen indirect field was discarded."}
	# The current projection may differ by harmless capture noise, but composition
	# and provenance always keep the exact SH snapshot captured before tracing.
	return {"ready": true, "coefficient_sets": captured_sets}

## Bake-only immutable directional-source snapshot. This intentionally runs only
## at capture/publication boundaries; runtime coefficient polling does not hash
## source records or walk the light list for provenance.
func _attach_bake_directional_snapshot(volume: Node3D, lighting_sets: Dictionary) -> Dictionary:
	if volume == null or not is_instance_valid(volume) or not volume.is_inside_tree():
		return {"ready": false, "error": "The MagicGI Volume left the scene during DirectionalLight capture."}
	var world := volume.get_world_3d()
	if world == null:
		return {"ready": false, "error": "The MagicGI Volume has no World3D for DirectionalLight capture."}
	_scan_scene(volume)
	_next_scan = Time.get_ticks_msec() + SCENE_SCAN_MSEC
	var lights: Array[DirectionalLight3D] = []
	var explicit_light: Variant = volume.get("sun")
	if explicit_light is DirectionalLight3D and explicit_light.is_inside_tree() \
			and explicit_light.get_world_3d() == world:
		lights.append(explicit_light)
	else:
		lights = _lights.duplicate()
	var physical_units := bool(ProjectSettings.get_setting(
			"rendering/lights_and_shadows/use_physical_light_units", false))
	var sources: Array[Dictionary] = []
	var direct := _zero_sh()
	for light in lights:
		if not is_instance_valid(light) or not light.is_inside_tree() \
				or not light.is_visible_in_tree() or light.get_world_3d() != world:
			continue
		var path := SceneTracker.scene_relative_path(light)
		var direction := light.global_basis.z.normalized()
		var color: Color = light.light_color.srgb_to_linear()
		var temperature_color: Color = light.get_correlated_color().srgb_to_linear()
		var color_linear := Vector3(color.r, color.g, color.b)
		var temperature_linear := Vector3(temperature_color.r, temperature_color.g, temperature_color.b)
		var energy := float(light.light_energy)
		var indirect_energy := float(light.light_indirect_energy)
		var intensity_lux := float(light.get("light_intensity_lux"))
		var angular_distance := float(light.light_angular_distance)
		var scale := energy * indirect_energy
		# Keep the historical scalar projection operation order exactly. The
		# immutable radiance_rgb below is still the NEE source value, but rounding
		# a Vector3 product before multiplying the SH basis differs by a few ULPs.
		var projection_color: Color = color
		var projection_energy := scale
		if physical_units:
			scale *= intensity_lux
			projection_energy *= intensity_lux
			projection_color *= temperature_color
			color_linear = Vector3(color_linear.x * temperature_linear.x,
					color_linear.y * temperature_linear.y,
					color_linear.z * temperature_linear.z)
		else:
			scale *= PI
			projection_energy *= PI
		if light.light_negative:
			scale = -scale
			projection_energy *= -1.0
		var radiance := color_linear * scale
		if path.is_empty() or not direction.is_finite() or direction.length_squared() < 0.999 \
				or not radiance.is_finite() or not color_linear.is_finite() \
				or not temperature_linear.is_finite() or not is_finite(energy) \
				or not is_finite(indirect_energy) or not is_finite(intensity_lux) \
				or not is_finite(angular_distance):
			return {"ready": false, "error": "A DirectionalLight source has non-finite or invalid bake inputs."}
		var source := {
			"path": path,
			"direction_world": direction,
			"radiance_rgb": radiance,
			"sky_mode": int(light.sky_mode),
			"light_negative": bool(light.light_negative),
			"light_cull_mask": int(light.light_cull_mask),
			"shadow_caster_mask": int(light.shadow_caster_mask),
			"shadow_enabled": bool(light.shadow_enabled),
			"angular_distance": angular_distance,
			"bake_mode": int(light.light_bake_mode),
			"physical_units": physical_units,
			"color_linear": color_linear,
			"temperature_linear": temperature_linear,
			"light_energy": energy,
			"light_indirect_energy": indirect_energy,
			"intensity_lux": intensity_lux,
		}
		sources.append(source)
		var basis := Data.sh_basis(direction)
		for k in 9:
			direct[k * 3] += projection_color.r * projection_energy * basis[k]
			direct[k * 3 + 1] += projection_color.g * projection_energy * basis[k]
			direct[k * 3 + 2] += projection_color.b * projection_energy * basis[k]
	sources.sort_custom(Callable(self, "_directional_source_less"))
	for i in range(1, sources.size()):
		if String(sources[i - 1].path) == String(sources[i].path):
			return {"ready": false, "error": "DirectionalLight bake snapshot has duplicate scene-relative paths."}
	var expected_direct: Variant = lighting_sets.get("direct_lighting", null)
	if not expected_direct is PackedFloat32Array or expected_direct.size() != 27 \
			or expected_direct != direct:
		return {"ready": false, "error": "DirectionalLight SH projection disagrees with the frozen per-source snapshot."}
	var signature := Data.baked_directional_source_signature(sources, physical_units)
	if signature.is_empty():
		return {"ready": false, "error": "DirectionalLight source provenance could not be signed."}
	lighting_sets["directional_sources"] = sources
	lighting_sets["directional_source_signature"] = signature
	lighting_sets["directional_physical_units"] = physical_units
	return {"ready": true, "directional_sources": sources,
		"directional_source_signature": signature, "physical_units": physical_units}

static func _directional_source_less(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("path", "")) < String(b.get("path", ""))

func _read_sky_light(world: World3D, snapshot_override: Variant = null) -> PackedFloat32Array:
	if _sky_light_runtime != null and world != null:
		var snapshot: Variant = snapshot_override
		if not snapshot is Dictionary:
			snapshot = _sky_light_runtime.call("snapshot_for_world", world.get_instance_id())
		if snapshot is Dictionary and bool(snapshot.get("ready", false)):
			var coefficients: Variant = snapshot.get("radiance_sh")
			if coefficients is PackedFloat32Array and coefficients.size() == 27:
				return coefficients
	return _zero_sh()

func _find_sky_provider(volume: Node3D, world: World3D) -> Dictionary:
	var root := SceneTracker.scene_root(volume)
	var candidates: Array[Node] = []
	_collect_sky_providers_recursive(root, root, world, candidates)
	var active_provider: Variant = null
	if _sky_light_runtime != null and _sky_light_runtime.has_method("active_for_world"):
		active_provider = _sky_light_runtime.call("active_for_world", world.get_instance_id())
	if active_provider != null and is_instance_valid(active_provider):
		var active_info := _sky_provider_scope_info(volume, world, active_provider)
		active_info["candidates"] = candidates
		return active_info
	return {"node": null, "path": "", "candidates": candidates}

func _collect_sky_providers_recursive(node: Node, root: Node, world: World3D,
		result: Array[Node]) -> void:
	if SceneTracker.should_skip_world_boundary(node, root, world):
		return
	if node.has_method("_feng_sky_light_runtime_snapshot"):
		result.append(node)
	for child in node.get_children():
		_collect_sky_providers_recursive(child, root, world, result)

func _sky_provider_scope_info(volume: Node3D, world: World3D, provider: Variant) -> Dictionary:
	if not provider is Node or not is_instance_valid(provider) or not provider.is_inside_tree():
		return {"error": "The active FengSkyLight provider is not a live scene Node."}
	var root := SceneTracker.scene_root(volume)
	if provider != root and not root.is_ancestor_of(provider):
		return {"error": "An active FengSkyLight provider exists outside the Volume's scene scope; the bake was rejected."}
	var current: Node = provider
	while current != null and current != root:
		if SceneTracker.should_skip_world_boundary(current, root, world):
			return {"error": "An active FengSkyLight provider crosses a World3D boundary outside the Volume's scene scope."}
		current = current.get_parent()
	if current != root:
		return {"error": "An active FengSkyLight provider is not owned by the Volume's scene root."}
	var provider_world: World3D
	if provider is Node3D:
		provider_world = (provider as Node3D).get_world_3d()
	else:
		var viewport: Viewport = (provider as Node).get_viewport()
		provider_world = viewport.find_world_3d() if viewport != null else null
	if provider_world != world:
		return {"error": "The active FengSkyLight provider belongs to a different World3D."}
	return {"node": provider, "path": SceneTracker.scene_relative_path(provider)}

func _world_ambient_contract(world: World3D) -> Dictionary:
	var environment: Environment = world.environment if world.environment != null else world.fallback_environment
	if environment == null:
		return {"supported": true, "requires_sky": false}
	var ambient_source := int(environment.ambient_light_source)
	var ambient_energy := float(environment.ambient_light_energy)
	if not is_finite(ambient_energy) or ambient_energy < 0.0:
		return {"supported": false, "requires_sky": false,
			"error": "Environment ambient energy is invalid; MagicGI bake was rejected."}
	var ambient_color: Color = environment.ambient_light_color.srgb_to_linear()
	var ambient_color_nonzero := ambient_energy > 0.0 and maxf(ambient_color.r,
			maxf(ambient_color.g, ambient_color.b)) > 0.0
	var sky_background := environment.background_mode == Environment.BG_SKY and environment.sky != null
	match ambient_source:
		Environment.AMBIENT_SOURCE_DISABLED:
			return {"supported": true, "requires_sky": false}
		Environment.AMBIENT_SOURCE_SKY:
			if ambient_color_nonzero and environment.ambient_light_sky_contribution < 1.0:
				return {"supported": false, "requires_sky": true,
					"error": "World3D mixes non-zero Environment ambient color with Sky ambient; this bake path cannot represent that mix."}
			return {"supported": true, "requires_sky": true}
		Environment.AMBIENT_SOURCE_COLOR:
			if ambient_color_nonzero:
				return {"supported": false, "requires_sky": false,
					"error": "Non-zero Environment color ambient is not captured by FengSkyLight; MagicGI bake was rejected."}
			return {"supported": true, "requires_sky": false}
		Environment.AMBIENT_SOURCE_BG:
			if sky_background:
				if ambient_color_nonzero and environment.ambient_light_sky_contribution < 1.0:
					return {"supported": false, "requires_sky": true,
						"error": "World3D mixes non-zero Environment ambient color with the Sky; this bake path cannot represent that mix."}
				return {"supported": true, "requires_sky": true}
			var background_color: Color
			if environment.background_mode == Environment.BG_CLEAR_COLOR:
				background_color = RenderingServer.get_default_clear_color().srgb_to_linear()
			elif environment.background_mode == Environment.BG_COLOR:
				background_color = environment.background_color.srgb_to_linear()
			else:
				return {"supported": false, "requires_sky": false,
					"error": "World3D Environment ambient source is not a supported Sky/Color source."}
			var background_energy := float(environment.background_energy_multiplier)
			if not is_finite(background_energy) or background_energy < 0.0:
				return {"supported": false, "requires_sky": false,
					"error": "Environment background energy is invalid; MagicGI bake was rejected."}
			var background_nonzero := background_energy > 0.0 \
					and maxf(background_color.r, maxf(background_color.g, background_color.b)) > 0.0
			if background_nonzero:
				return {"supported": false, "requires_sky": false,
					"error": "Non-zero World3D background/color ambient is not captured by FengSkyLight; MagicGI bake was rejected."}
			return {"supported": true, "requires_sky": false}
	return {"supported": false, "requires_sky": false,
		"error": "Unknown Environment ambient source; MagicGI bake was rejected."}

func _scan_scene(volume: Node3D) -> void:
	_lights.clear()
	_world = volume.get_world_3d()
	_scan(SceneTracker.scene_root(volume), _world)

func _scan(node: Node, world: World3D) -> void:
	if node is Viewport and node.find_world_3d() != world:
		return
	if node is Node3D and node.get_world_3d() != world:
		return
	if node is DirectionalLight3D:
		_lights.append(node)
	for child in node.get_children():
		_scan(child, world)

static func _source_fingerprint(lights: Array[DirectionalLight3D], world: World3D) -> int:
	var values: Array = []
	for light in lights:
		if not is_instance_valid(light) or not light.is_inside_tree() or light.get_world_3d() != world:
			continue
		values.append([light.global_transform, light.light_color, light.get_correlated_color(), light.light_energy,
				light.light_indirect_energy, light.get("light_intensity_lux"), light.light_negative,
				light.is_visible_in_tree()])
	return hash(values)

static func _zero_sh() -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(27)
	return values

static func project_panorama(image: Image, local_to_world := Basis.IDENTITY) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(27)
	if image == null or image.is_empty():
		return result
	var width := image.get_width()
	var height := image.get_height()
	var total := 0.0
	for y in height:
		var theta := PI * (y + 0.5) / height
		var row_weight := sin(theta) * PI * TAU / (width * height)
		total += row_weight * width
		for x in width:
			var phi := TAU * (x + 0.5) / width
			# Matches Godot SkyRD::Sky::bake_panorama's equirectangular direction.
			var local_direction := Vector3(
					-sin(phi) * sin(theta),
					cos(theta),
					-cos(phi) * sin(theta))
			var world_direction := (local_to_world * local_direction).normalized()
			var basis := Data.sh_basis(world_direction)
			var color := image.get_pixel(x, y)
			for k in 9:
				for channel in 3:
					result[k * 3 + channel] += color[channel] * basis[k] * row_weight
	if total > 0.0:
		var normalization := 4.0 * PI / total
		for i in 27:
			result[i] *= normalization
	return result
