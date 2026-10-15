extends SceneTree
## CPU-only routing tests for Eye Adaptation's camera and Volume sources.

const EyeAdaptation = preload("../passes/eye_adaptation_pass.gd")
const ParameterResolver = preload("../pipeline/parameter_resolver.gd")

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
		"exposure source routing can be checked without a RenderingDevice")
	var eye_pass := EyeAdaptation.new()
	check(eye_pass.get_volume_parameter_names().has("exposure_source"),
		"Volume schema exposes the Eye Adaptation source selector")
	check(EyeAdaptation.resolve_exposure_route(
		EyeAdaptation.EXPOSURE_SOURCE_AUTOMATIC, false, true)
		== EyeAdaptation.EXPOSURE_ROUTE_CAMERA_ATTRIBUTES,
		"Automatic uses camera attributes when no scene Volume explicitly overrides Eye Adaptation")
	check(EyeAdaptation.resolve_exposure_route(
		EyeAdaptation.EXPOSURE_SOURCE_AUTOMATIC, true, true)
		== EyeAdaptation.EXPOSURE_ROUTE_PASS_SETTINGS,
		"an ordinary explicit scene Volume exposure override takes priority in Automatic mode")
	check(EyeAdaptation.resolve_exposure_route(
		EyeAdaptation.EXPOSURE_SOURCE_CAMERA_ATTRIBUTES, true, true)
		== EyeAdaptation.EXPOSURE_ROUTE_CAMERA_ATTRIBUTES,
		"explicit Camera Attributes remains selected when a Volume overrides other exposure values")
	check(EyeAdaptation.resolve_exposure_route(
		EyeAdaptation.EXPOSURE_SOURCE_AUTOMATIC, false, false)
		== EyeAdaptation.EXPOSURE_ROUTE_PASS_SETTINGS,
		"Automatic retains pass settings when no camera attributes exist")
	check(EyeAdaptation.resolve_exposure_route(
		EyeAdaptation.EXPOSURE_SOURCE_CAMERA_ATTRIBUTES, false, true)
		== EyeAdaptation.EXPOSURE_ROUTE_CAMERA_ATTRIBUTES
		and EyeAdaptation.resolve_exposure_route(
			EyeAdaptation.EXPOSURE_SOURCE_CAMERA_ATTRIBUTES, false, false)
			== EyeAdaptation.EXPOSURE_ROUTE_PASS_SETTINGS,
		"explicit Camera Attributes falls back safely when a camera source is unavailable")
	check(EyeAdaptation.resolve_exposure_route(
		EyeAdaptation.EXPOSURE_SOURCE_PASS_SETTINGS, false, true)
		== EyeAdaptation.EXPOSURE_ROUTE_PASS_SETTINGS,
		"explicit Pass Settings ignores camera attributes")

	var base := {"library:eye_adaptation": {"exposure_source": 0, "metering_mode": 0}}
	var schema := {"library:eye_adaptation": {
		"exposure_source": {"type": TYPE_INT},
		"metering_mode": {"type": TYPE_INT}}}
	var context := {"base": base, "schema": schema, "bindings": []}
	var untouched := ParameterResolver.resolve_context([], {}, context)
	var untouched_eye: Dictionary = untouched["library:eye_adaptation"]
	check(not untouched_eye.has("_frp_volume_eye_exposure_override"),
		"authored Eye defaults do not masquerade as an explicit Volume override")
	var explicit_same_value := ParameterResolver.resolve_context([], {
		"library:eye_adaptation": {"metering_mode": 0}}, context)
	var explicit_eye: Dictionary = explicit_same_value["library:eye_adaptation"]
	check(bool(explicit_eye.get("_frp_volume_eye_exposure_override", false)),
		"a same-as-default explicit Volume setting still carries its private source marker")
	check(EyeAdaptation.resolve_exposure_route(
		EyeAdaptation.EXPOSURE_SOURCE_AUTOMATIC,
		bool(explicit_eye.get("_frp_volume_eye_exposure_override", false)), true)
		== EyeAdaptation.EXPOSURE_ROUTE_PASS_SETTINGS,
		"Automatic selects pass settings when a regular exposure value is overridden by Volume")
	var explicit_camera := ParameterResolver.resolve_context([], {
		"library:eye_adaptation": {"exposure_source": EyeAdaptation.EXPOSURE_SOURCE_CAMERA_ATTRIBUTES,
			"metering_mode": 2}}, context)
	var explicit_camera_eye: Dictionary = explicit_camera["library:eye_adaptation"]
	check(int(explicit_camera_eye.get("exposure_source", -1))
		== EyeAdaptation.EXPOSURE_SOURCE_CAMERA_ATTRIBUTES
		and bool(explicit_camera_eye.get("_frp_volume_eye_exposure_override", false))
		and EyeAdaptation.resolve_exposure_route(
			int(explicit_camera_eye["exposure_source"]),
			bool(explicit_camera_eye["_frp_volume_eye_exposure_override"]), true)
			== EyeAdaptation.EXPOSURE_ROUTE_CAMERA_ATTRIBUTES,
		"Volume source selection is resolved and explicit Camera Attributes wins over other Volume values")
	var explicit_pass := ParameterResolver.resolve_context([], {
		"library:eye_adaptation": {"exposure_source": EyeAdaptation.EXPOSURE_SOURCE_PASS_SETTINGS}}, context)
	var explicit_pass_eye: Dictionary = explicit_pass["library:eye_adaptation"]
	check(int(explicit_pass_eye.get("exposure_source", -1))
		== EyeAdaptation.EXPOSURE_SOURCE_PASS_SETTINGS
		and EyeAdaptation.resolve_exposure_route(
			int(explicit_pass_eye["exposure_source"]),
			bool(explicit_pass_eye.get("_frp_volume_eye_exposure_override", false)), true)
			== EyeAdaptation.EXPOSURE_ROUTE_PASS_SETTINGS,
		"Volume can explicitly select Pass Settings")
	var explicit_auto_only := ParameterResolver.resolve_context([], {
		"library:eye_adaptation": {"exposure_source": EyeAdaptation.EXPOSURE_SOURCE_AUTOMATIC}}, context)
	var explicit_auto_eye: Dictionary = explicit_auto_only["library:eye_adaptation"]
	check(not bool(explicit_auto_eye.get("_frp_volume_eye_exposure_override", false))
		and EyeAdaptation.resolve_exposure_route(
			int(explicit_auto_eye["exposure_source"]), false, true)
			== EyeAdaptation.EXPOSURE_ROUTE_CAMERA_ATTRIBUTES,
		"selecting Automatic alone does not count as a pass-settings override")
	var unknown_only := ParameterResolver.resolve_context([], {
		"library:eye_adaptation": {"not_a_volume_field": 1}}, context)
	var unknown_eye: Dictionary = unknown_only["library:eye_adaptation"]
	check(not unknown_eye.has("_frp_volume_eye_exposure_override"),
		"unknown keys rejected by the Volume schema do not select the Volume exposure route")
	var non_exposure_only := ParameterResolver.resolve_context([], {
		"library:eye_adaptation": {"pre_exposure": false,
			"extend_default_luminance_range": true}}, context)
	var non_exposure_eye: Dictionary = non_exposure_only["library:eye_adaptation"]
	check(not non_exposure_eye.has("_frp_volume_eye_exposure_override"),
		"pre-exposure and luminance-range settings alone do not select pass exposure")
	print("EXPOSURE_ROUTING_TEST_DONE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
