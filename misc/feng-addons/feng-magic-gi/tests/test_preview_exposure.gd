extends SceneTree
## CPU-only checks for the editor preview's per-viewport exposure uniforms.

const Viz = preload("res://addons/feng-magic-gi/feng_magic_gi_viz.gd")
const ExposureCache = preload("res://addons/feng-render-pipeline/passes/editor_preview_exposure_cache.gd")

class FakeExposureProducer extends RefCounted:
	var enabled := true

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
	var target_id := 987654321
	var owner_id := 123456789
	var cache_key := "987654321:0"
	var producer := FakeExposureProducer.new()
	ExposureCache._mutex.lock()
	ExposureCache._preview_owners[owner_id] = true
	ExposureCache._targets[target_id] = {"owners": {owner_id: true}}
	ExposureCache._snapshots[cache_key] = {
		"target_id": target_id,
		"view": 0,
		"exposure_scale": 0.125,
		"sequence": 1,
		"producer_id": producer.get_instance_id(),
		"producer_ref": weakref(producer),
		"published_usec": Time.get_ticks_usec(),
	}
	ExposureCache._mutex.unlock()
	var active := ExposureCache.get_snapshot(target_id, 0)
	require(bool(active.get("valid", false)) and is_equal_approx(float(active["exposure_scale"]), 0.125),
			"a live Eye producer must return its cached per-view scale")
	active["exposure_scale"] = 99.0
	require(is_equal_approx(float(ExposureCache._snapshots[cache_key]["exposure_scale"]), 0.125),
			"returned snapshots must not mutate the cache's shared dictionary")
	producer.enabled = false
	var inactive := ExposureCache.get_snapshot(target_id, 0)
	require(not bool(inactive.get("valid", true)) and not ExposureCache._snapshots.has(cache_key),
			"disabling Eye must immediately invalidate its exposure scale")
	var late_token := 73
	ExposureCache._mutex.lock()
	var late_epoch := int(ExposureCache._target_epochs.get(target_id, 0))
	ExposureCache._inflight[cache_key] = {"token": late_token, "epoch": late_epoch,
			"producer_id": producer.get_instance_id(), "target_id": target_id}
	ExposureCache._mutex.unlock()
	ExposureCache.set_preview_requested(owner_id, false)
	var callback_data := PackedByteArray()
	callback_data.resize(4)
	callback_data.encode_float(0, 0.5)
	ExposureCache._finish_scale_readback(callback_data, weakref(producer), target_id, 0,
			late_token, late_epoch)
	require(not ExposureCache._snapshots.has(cache_key)
			and not ExposureCache._inflight.has(cache_key),
			"a late Eye callback must be discarded after the preview owner unsubscribes")
	ExposureCache._mutex.lock()
	ExposureCache._preview_owners.erase(owner_id)
	ExposureCache._targets.erase(target_id)
	ExposureCache._target_epochs.erase(target_id)
	ExposureCache._mutex.unlock()

	var views: Array[Dictionary] = []
	for index in 4:
		views.append({
			"origin": Vector3(float(index), 2.0, 3.0),
			"right": Vector3.RIGHT,
			"up": Vector3.UP,
			"back": Vector3.BACK,
			"projection_x": 1.0 + float(index) * 0.1,
			"projection_y": 1.5 + float(index) * 0.1,
			"orthogonal": index == 2,
			"viewport_size": Vector2(640.0 + index * 10.0, 480.0),
			"exposure_scale": 0.25 + float(index) * 0.1,
		})
	var uniforms := Viz._preview_view_uniforms(views)
	var origins: PackedVector4Array = uniforms["preview_camera_origin"]
	var projections: PackedVector4Array = uniforms["preview_camera_projection"]
	var sizes: PackedVector4Array = uniforms["preview_camera_size"]
	var scales: Vector4 = uniforms["preview_eye_scale"]
	require(origins.size() == 4 and is_equal_approx(origins[3].x, 3.0),
			"preview uniforms must retain the live camera pose for all four editor views")
	require(is_equal_approx(projections[2].z, 1.0)
			and is_equal_approx(projections[3].x, 1.3)
			and is_equal_approx(sizes[3].x, 670.0),
			"each view must retain its own projection and viewport size for matching")
	require(is_equal_approx(scales.x, 0.25) and is_equal_approx(scales.y, 0.35)
			and is_equal_approx(scales.z, 0.45) and is_equal_approx(scales.w, 0.55),
			"each editor view must retain its own exposure scale")
	var neutral := ExposureCache.get_snapshot(987654321, 0)
	require(not bool(neutral.get("valid", true))
			and is_equal_approx(float(neutral.get("exposure_scale", 0.0)), 1.0),
			"missing or expired exposure must fall back to a neutral scale")
	require(Callable(ExposureCache, "_finish_scale_readback").is_valid(),
			"the async readback callback must be callable without capturing a volume or viewport")
	print("MAGIC_GI_PREVIEW_EXPOSURE checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
