extends SceneTree
## CPU-only checks for manual exposure publication and readback races.

const ExposureCache = preload("../passes/editor_preview_exposure_cache.gd")

class FakeExposureProducer extends RefCounted:
	var enabled := true

class FakeViewport extends RefCounted:
	pass

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
	var target_id := 987654321
	var unregistered_target_id := 987654322
	var owner_id := 123456789
	var key := "%d:0" % target_id
	var producer := FakeExposureProducer.new()
	var viewport := FakeViewport.new()
	var manual_white := 1.0 / (1.2 * 32000.0)

	check(ExposureCache.publish_known_scale(target_id, 0, manual_white, producer)
		== ERR_UNAVAILABLE,
		"known exposure cannot publish until an editor render target is registered")
	check(ExposureCache.publish_known_scale(unregistered_target_id, 0, manual_white, producer)
		== ERR_UNAVAILABLE,
		"known exposure cannot publish to an unregistered target")
	check(ExposureCache.publish_known_scale(target_id, 0, 0.0, producer)
		== ERR_INVALID_PARAMETER,
		"known exposure rejects a non-positive scale")

	ExposureCache._mutex.lock()
	ExposureCache._preview_owners[owner_id] = true
	ExposureCache._targets[target_id] = {"wr": weakref(viewport),
		"viewport_id": viewport.get_instance_id(), "owners": {owner_id: true}}
	ExposureCache._target_epochs[target_id] = 7
	ExposureCache._mutex.unlock()

	check(ExposureCache.publish_known_scale(target_id, 0, manual_white, producer) == OK,
		"manual exposure publishes synchronously without a RenderingDevice")
	var manual_snapshot := ExposureCache.get_snapshot(target_id, 0)
	check(bool(manual_snapshot.get("valid", false))
		and is_equal_approx(float(manual_snapshot.get("exposure_scale", 0.0)), manual_white)
		and int(manual_snapshot.get("producer_id", 0)) == producer.get_instance_id(),
		"manual exposure snapshot stores the native normalization factor and its live producer")

	ExposureCache._mutex.lock()
	ExposureCache._inflight[key] = {"token": 7001, "epoch": 7,
		"producer_id": producer.get_instance_id(), "target_id": target_id}
	ExposureCache._mutex.unlock()
	check(ExposureCache.publish_known_scale(target_id, 0, manual_white, producer) == OK,
		"manual mode supersedes an older pending GPU readback")
	ExposureCache._finish_scale_readback(PackedFloat32Array([0.125]).to_byte_array(),
		weakref(producer), target_id, 0, 7001, 7)
	var after_late_readback := ExposureCache.get_snapshot(target_id, 0)
	check(bool(after_late_readback.get("valid", false))
		and is_equal_approx(float(after_late_readback.get("exposure_scale", 0.0)), manual_white),
		"a late async readback cannot overwrite the newer manual exposure snapshot")
	producer.enabled = false
	check(not bool(ExposureCache.get_snapshot(target_id, 0).get("valid", true)),
		"a disabled exposure producer cannot keep its manual snapshot active")
	producer.enabled = true
	check(ExposureCache.publish_known_scale(target_id, 0, manual_white, producer) == OK,
		"an active producer can publish again after the disabled snapshot is retired")

	ExposureCache._mutex.lock()
	ExposureCache._target_epochs[target_id] = int(ExposureCache._target_epochs[target_id]) + 1
	ExposureCache._mutex.unlock()
	check(not bool(ExposureCache.get_snapshot(target_id, 0).get("valid", true)),
		"a snapshot from an earlier target epoch is rejected")

	ExposureCache.publish_known_scale(target_id, 0, manual_white, producer)
	ExposureCache.retire_producer(producer.get_instance_id())
	check(not bool(ExposureCache.get_snapshot(target_id, 0).get("valid", true)),
		"retiring a producer clears snapshots published directly by it")

	ExposureCache._mutex.lock()
	ExposureCache._preview_owners.erase(owner_id)
	ExposureCache._targets.erase(target_id)
	ExposureCache._target_epochs.erase(target_id)
	ExposureCache._snapshots.erase(key)
	ExposureCache._inflight.erase(key)
	ExposureCache._mutex.unlock()
	producer = null
	viewport = null
	print("EDITOR_PREVIEW_EXPOSURE_CACHE_TEST_DONE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
