@tool
class_name FengSkyLightNativeAdapter
extends RefCounted
## Keeps the FengSkyLight GDScript boundary independent from the new renderer
## bindings. This adapter owns every RenderingServer call added for SkyLight.

const REQUIRED_SKY_METHODS := [
	&"sky_set_external_radiance",
	&"sky_set_external_radiance_cubemap",
	&"sky_is_external_radiance_ready",
	&"sky_get_external_radiance_revision",
	&"sky_get_external_radiance_exposure",
	&"sky_bake_panorama",
]


static func supports_external_radiance() -> bool:
	for method_name in REQUIRED_SKY_METHODS:
		if not RenderingServer.has_method(method_name):
			return false
	return true


static func supports_scene_capture() -> bool:
	for method_name in [
		&"reflection_probe_set_capture_environment",
		&"reflection_probe_set_capture_only",
		&"reflection_probe_set_capture_output_sky",
		&"reflection_probe_set_capture_resolution",
		&"reflection_probe_request_capture",
	]:
		if not RenderingServer.has_method(method_name):
			return false
	return supports_external_radiance()


static func supports_frp_registration() -> bool:
	return RenderingServer.has_method(&"frp_set_sky_lighting_source") \
			and RenderingServer.has_method(&"frp_clear_sky_lighting_source")


static func enable_external_radiance(output_sky: Sky, enabled: bool) -> bool:
	if output_sky == null or not is_instance_valid(output_sky) \
			or not RenderingServer.has_method(&"sky_set_external_radiance"):
		return false
	RenderingServer.call(&"sky_set_external_radiance", output_sky.get_rid(), enabled)
	return true


static func set_capture_probe(probe: ReflectionProbe, capture_environment: Environment,
		output_sky: Sky, resolution: int, capture_distance: float, cull_mask: int,
		capture_shadows: bool) -> bool:
	if probe == null or not is_instance_valid(probe) or capture_environment == null \
			or output_sky == null or not supports_scene_capture():
		return false
	var probe_rid: RID = probe.get_base()
	if not probe_rid.is_valid():
		return false
	RenderingServer.call(&"reflection_probe_set_capture_environment", probe_rid, capture_environment.get_rid())
	RenderingServer.call(&"reflection_probe_set_capture_only", probe_rid, true)
	RenderingServer.call(&"reflection_probe_set_capture_output_sky", probe_rid, output_sky.get_rid())
	RenderingServer.call(&"reflection_probe_set_capture_resolution", probe_rid, resolution)
	if not is_equal_approx(probe.max_distance, capture_distance):
		probe.max_distance = capture_distance
	var capture_size := Vector3.ONE * (capture_distance * 2.0)
	if probe.size != capture_size:
		probe.size = capture_size
	if probe.cull_mask != cull_mask:
		probe.cull_mask = cull_mask
	if probe.enable_shadows != capture_shadows:
		probe.enable_shadows = capture_shadows
	return true


static func detach_capture_output(probe: ReflectionProbe) -> bool:
	if probe == null or not is_instance_valid(probe) \
			or not RenderingServer.has_method(&"reflection_probe_set_capture_output_sky"):
		return false
	var probe_rid: RID = probe.get_base()
	if not probe_rid.is_valid():
		return false
	# An invalid output cancels queued capture work before the probe is removed or
	# switched to another source. The output Sky keeps its last completed image.
	RenderingServer.call(&"reflection_probe_set_capture_output_sky", probe_rid, RID())
	return true


static func request_capture(probe: ReflectionProbe) -> bool:
	if probe == null or not is_instance_valid(probe) \
			or not RenderingServer.has_method(&"reflection_probe_request_capture"):
		return false
	var probe_rid: RID = probe.get_base()
	if not probe_rid.is_valid():
		return false
	RenderingServer.call(&"reflection_probe_request_capture", probe_rid)
	return true


static func set_cubemap_radiance(output_sky: Sky, cubemap: Cubemap) -> bool:
	if output_sky == null or not is_instance_valid(output_sky) \
			or cubemap == null or not is_instance_valid(cubemap) \
			or not supports_external_radiance():
		return false
	if not enable_external_radiance(output_sky, true):
		return false
	RenderingServer.call(&"sky_set_external_radiance_cubemap",
			output_sky.get_rid(), cubemap.get_rid(), 1.0)
	return true


static func external_radiance_ready(output_sky: Sky) -> bool:
	if output_sky == null or not is_instance_valid(output_sky) \
			or not RenderingServer.has_method(&"sky_is_external_radiance_ready"):
		return false
	return bool(RenderingServer.call(&"sky_is_external_radiance_ready", output_sky.get_rid()))


static func external_radiance_revision(output_sky: Sky) -> int:
	if output_sky == null or not is_instance_valid(output_sky) \
			or not RenderingServer.has_method(&"sky_get_external_radiance_revision"):
		return -1
	return int(RenderingServer.call(&"sky_get_external_radiance_revision", output_sky.get_rid()))


static func external_radiance_exposure(output_sky: Sky) -> float:
	if output_sky == null or not is_instance_valid(output_sky) \
			or not RenderingServer.has_method(&"sky_get_external_radiance_exposure"):
		return 1.0
	var exposure := float(RenderingServer.call(&"sky_get_external_radiance_exposure", output_sky.get_rid()))
	return exposure if is_finite(exposure) and exposure > 0.0 else 1.0


static func bake_world_linear_panorama(output_sky: Sky, size: Vector2i) -> Image:
	if output_sky == null or not is_instance_valid(output_sky) \
			or not RenderingServer.has_method(&"sky_bake_panorama"):
		return null
	var result: Variant = RenderingServer.call(&"sky_bake_panorama",
			output_sky.get_rid(), 1.0, false, size)
	return result as Image


static func register_frp_source(render_target: RID, owner_id: int, output_sky: Sky,
		energy: float, rotation: Basis, captured_exposure: float, source_revision: int) -> bool:
	if not render_target.is_valid() or owner_id <= 0 or output_sky == null \
			or not is_instance_valid(output_sky) or not supports_frp_registration():
		return false
	RenderingServer.call(&"frp_set_sky_lighting_source", render_target, owner_id,
			output_sky.get_rid(), energy, rotation, captured_exposure, source_revision)
	return true


static func clear_frp_source(render_target: RID, owner_id: int) -> void:
	if render_target.is_valid() and owner_id > 0 \
			and RenderingServer.has_method(&"frp_clear_sky_lighting_source"):
		RenderingServer.call(&"frp_clear_sky_lighting_source", render_target, owner_id)
