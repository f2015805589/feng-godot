extends SceneTree

const Packet = preload("res://addons/feng-render-pipeline/passes/atmosphere_packet.gd")
const Parameters = preload("res://addons/feng-sky/feng_sky_parameters.gd")
const ViewPass = preload("res://addons/feng-render-pipeline/pipeline/view_pass.gd")
const BuiltinPass = preload("res://addons/feng-render-pipeline/passes/builtin_pass.gd")
const NativePass = preload("res://addons/feng-render-pipeline/passes/native/native_pass.gd")
class PrepareProbe extends FengPass:
	var calls := 0
	func _frp_prepare(_ctx: FRPPassContext) -> void:
		calls += 1
var failures := 0

func require(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("REGRESSION: " + message)

func _init() -> void:
	var settings := Parameters.sanitize_atmosphere_settings({
		"mie_scattering_coefficients": Vector3(0.002, 0.003, 0.004),
		"mie_extinction_coefficients": Vector3(0.004, 0.006, 0.008),
		"sky_luminance_factor": Vector3(2.0, 3.0, 4.0),
		"sky_only_luminance_factor": Vector3(11.0, 12.0, 13.0),
		"trace_sample_count_scale": 4.0,
	})
	var snapshot := {"settings": settings, "sun_direction": Vector3.RIGHT,
		"sun_color_linear": Vector3(1.0, 0.5, 0.25), "sun_irradiance": 60000.0,
		"secondary_sun_direction": Vector3.LEFT, "secondary_sun_color_linear": Vector3(0.2, 0.4, 0.6),
		"secondary_sun_irradiance": 0.3, "sky_gain": 9.0}
	var packet: PackedFloat32Array = Packet.make(snapshot, Transform3D.IDENTITY, true, false)
	require(packet.size() == 64, "Atmosphere packet must be exactly 16 vec4s")
	require(is_equal_approx(packet[1], 6360.0) and is_equal_approx(packet[3], 6360.0), "Planet centre conversion is not metres to km")
	require(is_equal_approx(packet[8], 0.002) and is_equal_approx(packet[10], 0.004), "RGB Mie scattering collapsed")
	require(is_equal_approx(packet[12], 0.004) and is_equal_approx(packet[14], 0.008), "RGB Mie extinction collapsed")
	require(Vector3(packet[28], packet[29], packet[30]).is_equal_approx(Vector3(2.0, 3.0, 4.0)), "AP must use combined gain without sky-only or native sky gain")
	require(is_equal_approx(packet[31], 32.0), "View samples must follow transport scale")
	require(is_equal_approx(packet[35], 60000.0) and is_equal_approx(packet[43], 0.3), "Two atmospheric light sources not preserved")
	require(packet[48] == 1.0 and packet[49] == 0.0 and packet[50] == 1.0, "LUT/active flags do not match payload")
	var absent: PackedFloat32Array = Packet.make({}, Transform3D.IDENTITY, false, false)
	require(absent.size() == 64 and absent[50] == 0.0, "Absent sky must produce inert packet")
	var pass_resource := load("res://addons/feng-render-pipeline/library/height-fog/height_fog.tres")
	require(pass_resource != null, "Combined fog/AP pass failed to load")
	if pass_resource != null:
		require(pass_resource.has_method("_frp_prepare"), "Atmospheric lighting data has no pre-lighting handoff")
	var probe := PrepareProbe.new()
	var native := NativePass.new()
	native.overlay = probe
	var builtin := BuiltinPass.new()
	builtin.implementation = native
	var wrapper := ViewPass.new()
	wrapper.configure(builtin, builtin, true)
	wrapper._frp_prepare(null)
	require(probe.calls == 1, "View/native/builtin wrappers must forward pre-lighting preparation exactly once")
	probe.enabled = false
	wrapper._frp_prepare(null)
	require(probe.calls == 1, "Disabled carried overlay must not prepare metadata")
	print("feng_aerial_packet tests passed" if failures == 0 else "feng_aerial_packet tests failed")
	quit(0 if failures == 0 else 1)
