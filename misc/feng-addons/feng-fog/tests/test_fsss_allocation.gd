extends SceneTree
## Fault-inject the production allocator without a GPU or native FRP classes.

class Handle extends RefCounted:
	var live := true
	func is_valid() -> bool: return live

class Device extends RefCounted:
	var handles := []
	var sizes := []
	var fail_at := -1
	var double_free := false
	func make():
		var handle := Handle.new()
		handles.append(handle)
		return handle
	func uniform_buffer_create(size):
		sizes.append(size)
		var handle = make()
		if sizes.size() == fail_at: handle.live = false
		return handle
	func free_rid(handle):
		if not handle.live: double_free = true
		handle.live = false


func _initialize() -> void:
	var source := FileAccess.get_file_as_string(
			"res://addons/feng-fog/rendering/feng_fsss_gpu_service.gd")
	var start := source.find("func _ensure_state(")
	var end := source.find("func _create_mip_chain(", start)
	var allocator := source.substr(start, end - start)
	allocator = allocator.replace("buffers: RenderSceneBuffersRD", "buffers") \
			.replace("rd: RenderingDevice", "rd").replace("Array[RID]", "Array") \
			.replace(":=", "=")
	var script := GDScript.new()
	script.source_code = """extends RefCounted
const FRAME_BYTES = 288
const ANALYTIC_BYTES = 96
const ATMOSPHERE_BYTES = 256
const CLOUD_VISIBILITY_BYTES = 592
var _states = {}
func mip_count_for_size(_size): return 1
func _create_mip_chain(rd, _size, _count, allocated):
	var handle = rd.make()
	allocated.append(handle)
	return {"texture": handle, "views": []}
func _create_depth_texture(rd, _size): return rd.make()
func _free_rids(handles, rd):
	for handle in handles: rd.free_rid(handle)
func _free_state(state, rd):
	for handle in state.get("old_handles", []): rd.free_rid(handle)
""" + allocator
	if script.reload() != OK:
		quit(1)
		return
	var buffers := RefCounted.new()
	var expected_sizes := [288, 96, 256, 592, 16, 288, 96, 256, 592, 16]
	var failures := 0
	for failure in range(1, 11):
		var service = script.new()
		var rd := Device.new()
		rd.fail_at = failure
		service._states[buffers.get_instance_id()] = {
			"size": Vector2i.ONE, "view_count": 1, "mip_count": 1,
			"old_handles": [rd.make()],
		}
		var state: Dictionary = service._ensure_state(buffers, rd, Vector2i(8, 8), 2)
		var valid: bool = state.is_empty() and not rd.double_free \
				and not service._states.has(buffers.get_instance_id()) \
				and rd.sizes == expected_sizes.slice(0, failure)
		for handle in rd.handles:
			valid = valid and not handle.live
		if not valid:
			push_error("FSSS allocation cleanup failed at UBO %d" % failure)
			failures += 1
	var service = script.new()
	var rd := Device.new()
	var state: Dictionary = service._ensure_state(buffers, rd, Vector2i(8, 8), 2)
	if state.is_empty() or rd.sizes != expected_sizes:
		failures += 1
	else:
		for name in ["frame_ubos", "analytic_ubos", "atmosphere_ubos", "cloud_visibility_ubos", "upsample_ubos"]:
			if state[name].size() != 2: failures += 1
		if state.history_valid or state.history_index != 0 or state.previous_exposures != PackedFloat32Array([1, 1]):
			failures += 1
	print("FSSS allocation failures: %d" % failures)
	quit(1 if failures else 0)
