extends SceneTree
## Exact CPU packet contract: 496-byte UBO, preserving the original 240-byte
## camera/fog prefix and independent forward7×vec4 fog payload. The former
## unused p1.z now carries the perspective observer height for both paths.
const FogPass = preload("res://addons/feng-render-pipeline/passes/height_fog_pass.gd")

class SceneData extends RenderSceneDataExtension:
	var camera := Transform3D.IDENTITY
	var projection := Projection.IDENTITY
	func _get_cam_transform() -> Transform3D:
		return camera
	func _get_cam_projection() -> Projection:
		return projection
	func _get_view_count() -> int:
		return 1
	func _get_view_eye_offset(_view: int) -> Vector3:
		return Vector3.ZERO
	func _get_view_projection(_view: int) -> Projection:
		return projection

class CaptureFog extends FogPass:
	var captured := PackedFloat32Array()
	var declared_bytes := 0
	func _commit_frame_ubo(values: PackedFloat32Array, size: int, _rd: RenderingDevice) -> bool:
		captured = values
		declared_bytes = size
		return values.size() * 4 == size

var failed := false
var snapshots: Array = []

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)

func _initialize() -> void:
	call_deferred("run")

## Kept independently expanded from the pre-refactor field contract.
func reference_observer_y(s: Dictionary, camera: Transform3D, projection: Projection) -> float:
	var camera_y := camera.origin.y
	if projection.is_orthogonal():
		return camera_y
	var cap := INF
	var density := float(s.get("fog_density", 0.0))
	var height := float(s.get("fog_height", 0.0))
	var density2 := float(s.get("second_fog_density", 0.0))
	var height2 := float(s.get("second_fog_height", 0.0))
	if density > 0.0 and is_finite(density) and is_finite(height):
		cap = minf(cap, height + 655.36)
	if density2 > 0.0 and is_finite(density2) and is_finite(height2):
		cap = minf(cap, height2 + 655.36)
	return minf(camera_y, cap) if is_finite(cap) else camera_y

func reference_packet(s: Dictionary, camera: Transform3D, projection: Projection) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for column in 4:
		var axis: Vector4 = projection.inverse()[column]
		values.append_array([axis.x, axis.y, axis.z, axis.w])
	var basis := camera.basis.orthonormalized()
	for axis in [basis.x, basis.y, basis.z]:
		values.append_array([axis.x, axis.y, axis.z, 0.0])
	values.append_array([camera.origin.x, camera.origin.y, camera.origin.z, 1.0])
	var density := float(s.get("fog_density", 0.0))
	var falloff := float(s.get("fog_height_falloff", 0.0))
	var height := float(s.get("fog_height", 0.0))
	var density2 := float(s.get("second_fog_density", 0.0))
	var falloff2 := float(s.get("second_fog_height_falloff", 0.0))
	var height2 := float(s.get("second_fog_height", 0.0))
	var observer_y := reference_observer_y(s, camera, projection)
	values.append_array([camera.origin.x, camera.origin.y, camera.origin.z, 1.0])
	values.append_array([density * pow(2.0, clampf(-falloff * (observer_y - height), -125.0, 126.0)), falloff, observer_y, float(s.get("start_distance", 0.0))])
	values.append_array([density2 * pow(2.0, clampf(-falloff2 * (observer_y - height2), -125.0, 126.0)), falloff2, density2, height2])
	values.append_array([density, height, 0.0, float(s.get("cutoff_distance", 0.0))])
	var color: Variant = s.get("fog_color", Vector3.ZERO)
	var sun: Variant = s.get("sun_direction", Vector3.ZERO)
	var directional: Variant = s.get("inscattering_color", Vector3.ZERO)
	if color is Vector3:
		values.append_array([color.x, color.y, color.z, float(s.get("min_opacity", 0.0))])
	else:
		values.append_array([0.0, 0.0, 0.0, float(s.get("min_opacity", 0.0))])
	if sun is Vector3:
		values.append_array([sun.x, sun.y, sun.z, float(s.get("inscattering_start", -1.0))])
	else:
		values.append_array([0.0, 0.0, 0.0, -1.0])
	if directional is Vector3:
		values.append_array([directional.x, directional.y, directional.z, clampf(float(s.get("inscattering_exponent", 4.0)), 0.000001, 1000.0)])
	else:
		values.append_array([0.0, 0.0, 0.0, 4.0])
	return values

func run() -> void:
	var fog := CaptureFog.new()
	var scene := SceneData.new()
	var cases := [{}, {
		"fog_density": 0.002, "fog_height_falloff": 0.02, "fog_height": 3.0,
		"second_fog_density": 0.004, "second_fog_height_falloff": 0.12, "second_fog_height": -2.0,
		"fog_color": Vector3(0.13, 0.32, 0.57), "min_opacity": 0.25,
		"sun_direction": Vector3(0.2, 0.8, -0.4), "inscattering_color": Vector3(13.0, 2.0, 0.3),
		"inscattering_exponent": 12.0, "inscattering_start": 15.0, "start_distance": 2.0, "cutoff_distance": 4000.0,
	}, {"fog_color": Color.RED, "sun_direction": null, "inscattering_color": "invalid", "min_opacity": 0.3}, {
		"fog_density": 0.1, "fog_height_falloff": 10.0, "fog_height": -100.0,
		"second_fog_density": 0.2, "second_fog_height_falloff": 20.0, "second_fog_height": 100.0,
		"inscattering_exponent": -5.0,
	}, {"inscattering_exponent": 2000.0}]
	var cameras := [Transform3D.IDENTITY, Transform3D(Basis.from_euler(Vector3(0.2, 0.3, 0.4)).scaled(Vector3(1.2, 0.8, 2.0)), Vector3(12.0, 23.0, -34.0))]
	var projections := [Projection.create_perspective(70.0, 1.6, 0.05, 4000.0), Projection.create_orthogonal(-6.4, 6.4, -4.0, 4.0, 0.05, 4000.0)]
	var count := 0
	for settings in cases:
		for camera in cameras:
			for projection in projections:
				scene.camera = camera
				scene.projection = projection
				check(fog._update_frame_ubo(settings, scene, 0, null), "compute packet builder failed")
				check(fog.declared_bytes == 496 and fog.captured.size() == 124, "compute packet layout changed")
				check(fog.captured.slice(0, 60).to_byte_array() == reference_packet(settings, camera, projection).to_byte_array(), "original camera/fog fields/order differ")
				var neutral_atmosphere := PackedFloat32Array()
				neutral_atmosphere.resize(64)
				check(fog.captured.slice(60).to_byte_array() == neutral_atmosphere.to_byte_array(), "absent atmosphere must append 64 neutral floats")
				for scale in [-2.0, 0.0, 1.0, 2.75]:
					var forward := fog._make_forward_parameters(settings, camera, scale, projection)
					check(forward.size() == 28 and forward[14] == scale, "forward packet scale/layout changed")
					forward[14] = 0.0
					check(forward.to_byte_array() == fog.captured.slice(32, 60).to_byte_array(), "forward/compute packet fields differ")
					snapshots.append(fog.captured.slice(0, 60).to_byte_array().hex_encode())
					count += 1
	# A live spectral atmosphere must not change independently authored fog
	# colours, sun direction, start/cutoff depth, opacity, or the forward payload.
	fog._atmosphere_snapshot = {"settings": {
		"rayleigh_scattering_per_km": Vector3(0.005, 0.013, 0.033),
		"mie_scattering_coefficients": Vector3(0.002, 0.003, 0.004),
		"mie_extinction_coefficients": Vector3(0.003, 0.005, 0.007),
		"sky_luminance_factor": Vector3(2.0, 3.0, 4.0)},
		"sun_direction": Vector3.UP, "sun_color_linear": Vector3(0.7, 0.5, 0.2), "sun_irradiance": 60000.0}
	for settings in cases:
		check(fog._update_frame_ubo(settings, scene, 0, null), "atmosphere+fog packet builder failed")
		check(fog.captured.slice(0, 60).to_byte_array() == reference_packet(settings, scene.camera, scene.projection).to_byte_array(), "atmosphere mutated original fog fields")
		check(fog.captured[110] == 1.0 and fog.captured[95] == 60000.0, "live atmosphere packet lost source/active data")
		check(fog._make_forward_parameters(settings, scene.camera, 0.0, scene.projection).to_byte_array() == fog.captured.slice(32, 60).to_byte_array(), "live atmosphere altered forward fog contract")
	# Both density layers independently cap perspective observers; the minimum
	# cap wins. Compute's reserved strength lane must not affect observerY or the
	# camera-density terms. Orthographic projection has no UE target-distance
	# equivalent and therefore retains the true camera height.
	var high_camera := Transform3D.IDENTITY
	high_camera.origin.y = 1200.0
	var layered := {
		"fog_density": 0.002, "fog_height_falloff": 0.02, "fog_height": 3.0,
		"second_fog_density": 0.004, "second_fog_height_falloff": 0.12, "second_fog_height": -2.0}
	var perspective := Projection.create_perspective(70.0, 1.6, 0.05, 4000.0)
	var forward_cap := fog._make_forward_parameters(layered, high_camera, 1.0, perspective)
	var compute_cap := fog._make_forward_parameters(layered, high_camera, 0.0, perspective)
	check(is_equal_approx(forward_cap[6], 653.36) and is_equal_approx(compute_cap[6], 653.36), "two-layer perspective observer cap diverged by packet scale")
	check(is_equal_approx(forward_cap[4], compute_cap[4]) and is_equal_approx(forward_cap[8], compute_cap[8]), "compute/forward camera-density terms differ")
	check(forward_cap[1] == high_camera.origin.y and compute_cap[1] == high_camera.origin.y, "observer cap replaced the actual camera position")
	for i in forward_cap.size():
		if i != 14:
			check(is_equal_approx(forward_cap[i], compute_cap[i]), "packet scale changed non-scale field %d" % i)
	check(forward_cap[14] == 1.0 and compute_cap[14] == 0.0, "compute/forward strength lanes changed")
	var one_active_layer := layered.duplicate()
	one_active_layer["second_fog_density"] = 0.0
	var one_layer_packet := fog._make_forward_parameters(one_active_layer, high_camera, 1.0, perspective)
	check(is_equal_approx(one_layer_packet[6], 658.36), "inactive second layer affected the perspective observer cap")
	var ordinary_camera := Transform3D.IDENTITY
	ordinary_camera.origin.y = 120.0
	var ordinary_packet := fog._make_forward_parameters(layered, ordinary_camera, 1.0, perspective)
	check(ordinary_packet[1] == ordinary_camera.origin.y and ordinary_packet[6] == ordinary_camera.origin.y, "camera below the cap was moved")
	var orthographic := Projection.create_orthogonal(-6.4, 6.4, -4.0, 4.0, 0.05, 4000.0)
	var orthographic_packet := fog._make_forward_parameters(layered, high_camera, 1.0, orthographic)
	check(orthographic_packet[6] == high_camera.origin.y, "orthographic fog unexpectedly applied perspective observer cap")
	var no_density := fog._make_forward_parameters({}, high_camera, 1.0, perspective)
	check(no_density[6] == high_camera.origin.y, "empty fog layers unexpectedly applied observer cap")
	scene.camera = high_camera
	scene.projection = perspective
	check(fog._update_frame_ubo(layered, scene, 0, null), "capped perspective UBO build failed")
	var capped_ubo_fog := fog.captured.slice(32, 60)
	check(capped_ubo_fog[1] == high_camera.origin.y and is_equal_approx(capped_ubo_fog[6], 653.36), "compute UBO camera/observer fields do not match contract")
	check(is_equal_approx(capped_ubo_fog[4], compute_cap[4]) and is_equal_approx(capped_ubo_fog[8], compute_cap[8]), "compute UBO density terms disagree with the shared packet")
	check(capped_ubo_fog[14] == 0.0, "compute UBO no longer reserves the strength lane")
	check(not fog._update_frame_ubo({}, null, 0, null) and not fog._update_frame_ubo({}, scene, 1, null), "invalid view guard changed")
	scene.free()
	var output := OS.get_environment("FRP_FOG_PACKET_SNAPSHOT")
	if not output.is_empty():
		var file := FileAccess.open(output, FileAccess.WRITE)
		check(file != null, "packet snapshot could not open")
		if file != null:
			file.store_string(JSON.stringify(snapshots))
	if failed:
		quit(1)
	else:
		print("PASS FRP fog packet equivalence: %d exact240-byte preserved fog prefixes within496-byte packets and scaledforward cases" % count)
		quit(0)
