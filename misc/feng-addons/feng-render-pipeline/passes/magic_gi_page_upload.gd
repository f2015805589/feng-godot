@tool
extends RefCounted
## Incrementally creates/uploads one immutable page. Nothing is published to
## the pass cache until every resource and directional transfer is complete.

const DirectionalCache = preload("magic_gi_directional_cache.gd")
const Stream = preload("magic_gi_page_stream.gd")
const ProbeClusters = preload("magic_gi_probe_clusters.gd")

enum UploadResourceState { READY, WAITING_FOR_ALLOCATION, INVALID }

var cache_key := ""
var error := ""
var cache: Dictionary = {}
var _data: Resource
var _upload: Dictionary = {}
var _allocation_tasks: Array[Dictionary] = []
var _allocation_index := 0
var _upload_tasks: Array[Dictionary] = []
var _upload_index := 0
var _upload_offset := 0
var _directional_upload: RefCounted
var _directional_started := false
var _failed := false


func begin(rd: RenderingDevice, page: Dictionary, new_cache_key: String) -> bool:
	cache_key = new_cache_key
	_data = page.get("data") as Resource
	var upload_value: Variant = page.get("render_upload", {})
	# The published page descriptor is immutable and may be shared by several
	# views. Own only the dictionary container; images and packed payloads remain
	# shared read-only values so clearing this staging bundle cannot erase the
	# resident descriptor or duplicate large page data.
	_upload = upload_value.duplicate(false) if upload_value is Dictionary else {}
	# Runtime workers already validate the immutable page and prepare this bundle.
	# The render thread only checks cheap descriptor shape; it must not walk Data's
	# arrays or repack/rehash the page synchronously.
	if _data == null or not is_instance_valid(_data) or not upload_value is Dictionary \
			or not _data.has_method("probe_count") or not _data.has_method("get"):
		return _fail("Page descriptor has no immutable bake and prepacked upload bundle.")
	if _upload.is_empty():
		return _fail("Page descriptor is missing the worker-prepacked render_upload bundle.")
	var dims: Vector3i = _data.get("grid_dims")
	var probe_count := int(_data.call("probe_count"))
	if probe_count <= 0 or dims.x <= 0 or dims.y <= 0 or dims.z <= 0:
		return _fail("Page descriptor has invalid grid dimensions or probe count.")
	if _data.get("directional") != null:
		for packed_key in ["directional_transfer_bytes", "directional_sky_bytes",
				"directional_emission_bytes", "normal_bytes"]:
			if not _upload.has(packed_key) or not _upload[packed_key] is PackedByteArray:
				return _fail("Page worker did not prepack directional field '%s'." % packed_key)
	var images := {
		"transfer": [_upload.get("transfer_image"), RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT],
		"primary_sky": [_upload.get("primary_sky_image"), RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT],
		"geometry": [_upload.get("geometry_image"), RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT],
		"visibility_moments": [_upload.get("visibility_moment_image"), RenderingDevice.DATA_FORMAT_R32G32_SFLOAT],
	}
	var emission_image: Variant = page.get("emission_image", _upload.get("emission_image"))
	images["emission"] = [emission_image, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT]
	for image_name in images:
		var pair: Array = images[image_name]
		if not pair[0] is Image or pair[0].is_empty():
			return _fail("Page render_upload has no non-empty %s image." % image_name)
		var image: Image = pair[0]
		var bytes := Stream.image_byte_count(image)
		if bytes <= 0 or bytes > Stream.GPU_UPLOAD_BUDGET_BYTES_PER_FRAME:
			return _fail("Page %s texture is larger than one bounded texture upload." % image_name)
		_allocation_tasks.append({"kind": "texture", "name": image_name,
			"image": image, "format": int(pair[1])})
		_upload_tasks.append({"kind": "texture", "name": image_name, "image": image})
	var node_bytes: Variant = _upload.get("visibility_node_bytes")
	var triangle_bytes: Variant = _upload.get("visibility_triangle_bytes")
	var index_bytes: Variant = _upload.get("index_bytes")
	var index_entries: Variant = _upload.get("index_entries", PackedInt32Array([0]).to_byte_array())
	if not node_bytes is PackedByteArray or node_bytes.is_empty() or node_bytes.size() % 32 != 0 \
			or not triangle_bytes is PackedByteArray or triangle_bytes.is_empty() or triangle_bytes.size() % 48 != 0 \
			or not index_bytes is PackedByteArray or index_bytes.is_empty() \
			or not index_entries is PackedByteArray or index_entries.is_empty():
		return _fail("Page render_upload has incomplete visibility or index buffers.")
	for spec in [
		["visibility_nodes", node_bytes], ["visibility_triangles", triangle_bytes],
		["index_entries", index_entries],
	]:
		_allocation_tasks.append({"kind": "buffer", "name": spec[0], "size": spec[1].size()})
		_upload_tasks.append({"kind": "buffer", "name": spec[0], "bytes": spec[1]})
	var cluster_value: Variant = page.get("probe_cluster_payload", {})
	var cluster_payload: Dictionary = cluster_value if cluster_value is Dictionary else {}
	var cluster_value_bytes: Variant = cluster_payload.get("bytes")
	var cluster_bytes: PackedByteArray = cluster_value_bytes \
			if cluster_value_bytes is PackedByteArray else PackedByteArray()
	var cluster_enabled := bool(cluster_payload.get("enabled", false))
	if cluster_bytes.size() < ProbeClusters.HEADER_BYTES or cluster_bytes.size() % 4 != 0:
		cluster_payload = ProbeClusters.disabled_payload(str(page.get("probe_cluster_signature", "")),
			dims.x * dims.y * dims.z)
		cluster_bytes = cluster_payload["bytes"]
		cluster_enabled = false
	else:
		var cluster_header := cluster_bytes.to_int32_array()
		if cluster_header.size() < 4 or cluster_header[0] != ProbeClusters.SCHEMA_VERSION \
				or cluster_header[3] != (1 if cluster_enabled else 0):
			cluster_payload = ProbeClusters.disabled_payload(str(page.get("probe_cluster_signature", "")),
				dims.x * dims.y * dims.z)
			cluster_bytes = cluster_payload["bytes"]
			cluster_enabled = false
	_allocation_tasks.append({"kind": "buffer", "name": "probe_clusters", "size": cluster_bytes.size()})
	_upload_tasks.append({"kind": "buffer", "name": "probe_clusters", "bytes": cluster_bytes})
	var sparse_indices := bool(_upload.get("sparse_indices", false))
	var index_texture_size := int(dims.x * (1 if sparse_indices else 8) \
			* dims.y * dims.z * (8 if sparse_indices else 4))
	if index_texture_size != index_bytes.size() or index_texture_size > Stream.GPU_UPLOAD_BUDGET_BYTES_PER_FRAME:
		return _fail("Page index texture is malformed or exceeds the indivisible upload limit.")
	_allocation_tasks.append({"kind": "index_texture", "name": "indices",
		"dims": dims, "sparse": bool(_upload.get("sparse_indices", false))})
	_upload_tasks.append({"kind": "texture_bytes", "name": "indices", "bytes": index_bytes,
		"dims": dims, "sparse": bool(_upload.get("sparse_indices", false))})
	_allocation_tasks.append({"kind": "buffer", "name": "probe_lighting", "size": probe_count * 32})
	var source_bounds_value: Variant = page.get("support_bounds", page.get("core_bounds", AABB()))
	if not source_bounds_value is AABB or source_bounds_value.size == Vector3.ZERO:
		return _fail("Page descriptor has no finite support bounds.")
	var source_bounds: AABB = source_bounds_value
	cache = {
		"data_id": _data.get_instance_id(), "version": int(page.get("version", _data.get("bake_version"))),
		"source_bounds": source_bounds, "grid_dims": dims,
		"spacing": float(_data.get("spacing")), "probe_count": probe_count,
		"exact_visibility": int(_data.get("format_version")) >= 6,
		"emission_identity": str(page.get("identity", "")),
		"emission_revision": int(page.get("emission_revision", page.get("revision", 0))),
		"emission_size": emission_image.get_size(),
		"emission_format": emission_image.get_format(),
		"probe_cluster_enabled": cluster_enabled,
		"probe_cluster_bytes": cluster_bytes.size(),
		"probe_cluster_signature": str(cluster_payload.get("signature", page.get("probe_cluster_signature", ""))),
		"probe_cluster_cell_count": int(cluster_payload.get("cell_count", 0)),
		"probe_cluster_count": int(cluster_payload.get("cluster_count", 0)),
		"probe_cluster_probe_slots": int(cluster_payload.get("probe_slots", 0)),
		"source_gpu_bytes": int(page.get("source_gpu_bytes", page.get("gpu_bytes", 0))),
		"gpu_bytes": int(page.get("gpu_bytes", 0)),
		"last_used": 0, "stream_page": true,
	}
	return true


func _fail(message: String) -> bool:
	error = message
	_failed = true
	# Stop advertising work immediately. The caller rolls the ledger reservation
	# back and frees every partially-created RID returned by owned_rids().
	_allocation_tasks.clear()
	_allocation_index = 0
	_upload_tasks.clear()
	_upload_index = 0
	_upload_offset = 0
	_upload.clear()
	if _directional_upload != null and _directional_upload.has_method("abort"):
		_directional_upload.call("abort")
	return false


func failed() -> bool:
	return _failed


func has_pending_allocations() -> bool:
	return not _failed and (_allocation_index < _allocation_tasks.size() \
		or (_directional_upload != null and _directional_upload.has_pending_allocations())
	)


func allocate_step(rd: RenderingDevice, max_allocations := 2) -> int:
	if _failed:
		return -1
	if max_allocations <= 0:
		return 0
	var allocated := 0
	while _allocation_index < _allocation_tasks.size() and allocated < max_allocations:
		var task: Dictionary = _allocation_tasks[_allocation_index]
		var name := String(task["name"])
		var rid := RID()
		if task["kind"] == "texture":
			var image: Image = task["image"]
			rid = _create_texture(rd, image.get_size(), int(task["format"]),
				RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
		elif task["kind"] == "index_texture":
			var dims: Vector3i = task["dims"]
			var size := Vector2i(dims.x * (1 if task["sparse"] else 8), dims.y * dims.z)
			rid = _create_texture(rd, size,
				RenderingDevice.DATA_FORMAT_R32G32_SINT if task["sparse"] else RenderingDevice.DATA_FORMAT_R32_SINT,
				RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
		else:
			rid = rd.storage_buffer_create(maxi(4, int(task["size"])))
			if not rid.is_valid() and name == "probe_clusters":
				var fallback_dims: Vector3i = cache.get("grid_dims", Vector3i.ZERO)
				var fallback := ProbeClusters.disabled_payload(
					str(cache.get("probe_cluster_signature", "")),
					fallback_dims.x * fallback_dims.y * fallback_dims.z)
				var fallback_bytes: PackedByteArray = fallback["bytes"]
				rid = rd.storage_buffer_create(fallback_bytes.size(), fallback_bytes)
				if rid.is_valid():
					var previous_size := int(cache.get("probe_cluster_bytes", int(task["size"])))
					cache["probe_cluster_enabled"] = false
					cache["probe_cluster_bytes"] = fallback_bytes.size()
					cache["probe_cluster_cell_count"] = fallback["cell_count"]
					cache["probe_cluster_count"] = 0
					cache["probe_cluster_probe_slots"] = 0
					cache["gpu_bytes"] = maxi(0, int(cache.get("gpu_bytes", 0))
						- previous_size + fallback_bytes.size())
					for upload_index in _upload_tasks.size():
						if str(_upload_tasks[upload_index].get("name", "")) == "probe_clusters":
							var upload_task: Dictionary = _upload_tasks[upload_index]
							upload_task["bytes"] = fallback_bytes
							_upload_tasks[upload_index] = upload_task
		if not rid.is_valid():
			_fail("RenderingDevice could not allocate page resource '%s'." % name)
			return -1
		cache[name] = rid
		_allocation_index += 1
		allocated += 1
	if _allocation_index >= _allocation_tasks.size() and not _directional_started \
			and _data.get("directional") != null:
		_directional_upload = DirectionalCache.new()
		if not _directional_upload.begin_create(rd, _data, _upload):
			_fail("RenderingDevice could not prepare directional page buffers.")
			return -1
		_directional_started = true
	if _directional_upload != null and _directional_upload.has_pending_allocations() \
			and allocated < max_allocations:
		var extra: int = _directional_upload.allocate_step(rd, max_allocations - allocated)
		if extra < 0:
			_fail("RenderingDevice could not allocate directional page buffers.")
			return -1
		allocated += extra
	return allocated


func has_pending_uploads() -> bool:
	return not _failed and (_upload_index < _upload_tasks.size() \
		or (_directional_upload != null and _directional_upload.has_pending_uploads())
	)


func upload_step(rd: RenderingDevice, byte_budget: int) -> int:
	if _failed:
		return -1
	var consumed := 0
	while _upload_index < _upload_tasks.size() and byte_budget > 0:
		var task: Dictionary = _upload_tasks[_upload_index]
		var task_name := str(task.get("name", ""))
		var resource_state := _upload_resource_state(task_name)
		if resource_state == UploadResourceState.WAITING_FOR_ALLOCATION:
			# Allocation is deliberately spread across frames. Preserve this task and
			# its budget until the matching RID is available.
			break
		if resource_state != UploadResourceState.READY:
			_fail("Page upload task '%s' has no valid allocated RID." % task_name)
			return -1
		if task["kind"] == "texture":
			var image: Image = task["image"]
			var bytes := image.get_data()
			if bytes.size() > byte_budget:
				break
			if rd.texture_update(cache[task_name], 0, bytes) != OK:
				_fail("RenderingDevice could not upload page texture '%s'." % task["name"])
				return -1
			consumed += bytes.size()
			byte_budget -= bytes.size()
			_upload_index += 1
			continue
		var payload: PackedByteArray = task["bytes"]
		if task["kind"] == "texture_bytes":
			if payload.size() > byte_budget:
				break
			if rd.texture_update(cache[task_name], 0, payload) != OK:
				_fail("RenderingDevice could not upload the page lookup texture.")
				return -1
			consumed += payload.size()
			byte_budget -= payload.size()
			_upload_index += 1
			continue
		var remaining := payload.size() - _upload_offset
		var count := mini(remaining, byte_budget)
		count -= count % 4
		if count <= 0:
			break
		var slice := payload.slice(_upload_offset, _upload_offset + count)
		if rd.buffer_update(cache[task_name], _upload_offset, count, slice) != OK:
			_fail("RenderingDevice could not upload page buffer '%s'." % task["name"])
			return -1
		_upload_offset += count
		consumed += count
		byte_budget -= count
		if _upload_offset == payload.size():
			_upload_index += 1
			_upload_offset = 0
	if _upload_index >= _upload_tasks.size():
		_upload_tasks.clear()
		_upload_index = 0
		_upload_offset = 0
		# DirectionalCache begins only after the final surface allocation is
		# complete. Keep its prepacked payload available if surface uploads finish
		# first; begin_create takes its own shallow references before we release it.
		if _data == null or _data.get("directional") == null or _directional_started:
			_upload.clear()
	if _directional_upload != null and byte_budget > 0 and _directional_upload.has_pending_uploads():
		var extra: int = _directional_upload.upload_step(rd, byte_budget)
		if extra < 0:
			_fail("RenderingDevice could not upload directional page buffers.")
			return -1
		consumed += extra
	return consumed


func _upload_resource_state(resource_name: String) -> UploadResourceState:
	if resource_name.is_empty():
		return UploadResourceState.INVALID
	if cache.has(resource_name):
		var rid: RID = cache[resource_name]
		return UploadResourceState.READY if rid.is_valid() else UploadResourceState.INVALID
	for index in range(_allocation_index, _allocation_tasks.size()):
		if str(_allocation_tasks[index].get("name", "")) == resource_name:
			return UploadResourceState.WAITING_FOR_ALLOCATION
	return UploadResourceState.INVALID


func is_ready() -> bool:
	return not _failed and _allocation_index >= _allocation_tasks.size() \
		and not has_pending_allocations() and not has_pending_uploads() \
		and (_directional_upload == null or _directional_upload.is_ready())


func directional() -> RefCounted:
	return _directional_upload


## Transfer all completed RIDs to the pass only after the last upload succeeds.
## The uploader then stops claiming ownership so eviction/destruction cannot
## double-free a published cache entry.
func take_ready_cache() -> Dictionary:
	if not is_ready():
		return {}
	cache["directional"] = _directional_upload
	var result := cache
	cache = {}
	_data = null
	_upload.clear()
	_allocation_tasks.clear()
	_upload_tasks.clear()
	_directional_upload = null
	return result


func owned_rids() -> Array[RID]:
	var result: Array[RID] = []
	for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
			"visibility_nodes", "visibility_triangles", "indices", "index_entries",
			"emission", "probe_lighting", "probe_clusters"]:
		var rid: RID = cache.get(name, RID())
		if rid.is_valid():
			result.append(rid)
	if _directional_upload != null:
		result.append_array(_directional_upload.owned_rids())
	return result


func gpu_bytes() -> int:
	return int(cache.get("gpu_bytes", 0))


func _create_texture(rd: RenderingDevice, size: Vector2i, format_id: int, extra_usage := 0) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = format_id
	format.width = size.x
	format.height = size.y
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | extra_usage
	return rd.texture_create(format, RDTextureView.new(), [])
