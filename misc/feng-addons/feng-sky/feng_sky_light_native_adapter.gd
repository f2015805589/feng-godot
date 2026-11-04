@tool
class_name FengSkyLightNativeAdapter
extends RefCounted
## Owns every native RenderingServer call and RID boundary used by FengSkyLight.


static func enable_external_radiance(output_sky: Sky, enabled: bool) -> bool:
	if output_sky == null or not is_instance_valid(output_sky):
		return false
	RenderingServer.sky_set_external_radiance(output_sky.get_rid(), enabled)
	return true


static func set_capture_probe(probe: ReflectionProbe, capture_environment: Environment,
		output_sky: Sky, resolution: int, capture_distance: float, cull_mask: int,
		capture_shadows: bool, capture_fog_effect: CompositorEffect = null) -> bool:
	if probe == null or not is_instance_valid(probe) or capture_environment == null \
			or output_sky == null:
		return false
	var probe_rid: RID = probe.get_base()
	if not probe_rid.is_valid():
		return false
	RenderingServer.reflection_probe_set_capture_environment(probe_rid, capture_environment.get_rid())
	RenderingServer.reflection_probe_set_capture_only(probe_rid, true)
	RenderingServer.reflection_probe_set_capture_output_sky(probe_rid, output_sky.get_rid())
	RenderingServer.reflection_probe_set_capture_resolution(probe_rid, resolution)
	var fog_effect_rid := capture_fog_effect.get_rid() \
			if capture_fog_effect != null and is_instance_valid(capture_fog_effect) else RID()
	RenderingServer.reflection_probe_set_capture_fog_effect(probe_rid, fog_effect_rid)
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
	if probe == null or not is_instance_valid(probe):
		return false
	var probe_rid: RID = probe.get_base()
	if not probe_rid.is_valid():
		return false
	# An invalid output cancels queued capture work before the probe is removed or
	# switched to another source. Clear the effect RID as well so no later capture
	# can dispatch it after its owned pass resources have been released.
	RenderingServer.reflection_probe_set_capture_output_sky(probe_rid, RID())
	RenderingServer.reflection_probe_set_capture_fog_effect(probe_rid, RID())
	return true


static func request_capture(probe: ReflectionProbe) -> bool:
	if probe == null or not is_instance_valid(probe):
		return false
	var probe_rid: RID = probe.get_base()
	if not probe_rid.is_valid():
		return false
	RenderingServer.reflection_probe_request_capture(probe_rid)
	return true


static func set_cubemap_radiance(output_sky: Sky, cubemap: Cubemap) -> bool:
	if output_sky == null or not is_instance_valid(output_sky) \
			or cubemap == null or not is_instance_valid(cubemap):
		return false
	if not enable_external_radiance(output_sky, true):
		return false
	RenderingServer.sky_set_external_radiance_cubemap(
			output_sky.get_rid(), cubemap.get_rid(), 1.0)
	return true


static func external_radiance_ready(output_sky: Sky) -> bool:
	if output_sky == null or not is_instance_valid(output_sky):
		return false
	return RenderingServer.sky_is_external_radiance_ready(output_sky.get_rid())


static func external_radiance_revision(output_sky: Sky) -> int:
	if output_sky == null or not is_instance_valid(output_sky):
		return -1
	return RenderingServer.sky_get_external_radiance_revision(output_sky.get_rid())


static func external_radiance_exposure(output_sky: Sky) -> float:
	if output_sky == null or not is_instance_valid(output_sky):
		return 1.0
	var exposure := RenderingServer.sky_get_external_radiance_exposure(output_sky.get_rid())
	return exposure if is_finite(exposure) and exposure > 0.0 else 1.0


static func bake_world_linear_panorama(output_sky: Sky, size: Vector2i) -> Image:
	if output_sky == null or not is_instance_valid(output_sky):
		return null
	var result: Image = RenderingServer.sky_bake_panorama(
			output_sky.get_rid(), 1.0, false, size)
	return result


static func register_frp_source(render_target: RID, owner_id: int, output_sky: Sky,
		energy: float, rotation: Basis, captured_exposure: float, source_revision: int) -> bool:
	if not render_target.is_valid() or owner_id <= 0 or output_sky == null \
			or not is_instance_valid(output_sky):
		return false
	RenderingServer.frp_set_sky_lighting_source(render_target, owner_id,
			output_sky.get_rid(), energy, rotation, captured_exposure, source_revision)
	return true


static func clear_frp_source(render_target: RID, owner_id: int) -> void:
	if render_target.is_valid() and owner_id > 0:
		RenderingServer.frp_clear_sky_lighting_source(render_target, owner_id)
