@tool
extends RefCounted
## Main-thread scheduler + render-thread decoder. No SDK, disk cache, GPU readback or SceneTree traversal.
signal changed
const Decoder = preload("gpu_decoder.gd")
const Runtime = preload("runtime.gd")
const Allocation = preload("gpu_allocation.gd")
const GPUTexture = preload("gpu_texture.gd")
const TILE := 64
const LOAD_TILE := 256
const BORDER := 2
const STRIDE := TILE + 2 * BORDER
var package: Dictionary
var virtual := false
var cache_axis := 8
var textures: Dictionary = {}
var page_texture: Texture2DRD
var ready := false
var last_error := ""
var stats := {"dispatches": 0, "decoded_texels": 0, "resident_pages": 0, "evictions": 0, "requests": 0}
var _decoder: RefCounted
var _allocation := Allocation.new()
var _rd_pages := RID()
var _page_size := Vector2i.ZERO
var _page_bytes := PackedByteArray()
var _rows: Array[int] = []
var _queue: Array[Vector3i] = []
var _resident: Dictionary = {}
var _slots: Array[Vector3i] = []
var _last_used: Dictionary = {}
var _pinned: Dictionary = {}
var _wanted: Dictionary = {}
var _clock := 0
var _inflight := false
var _closed := false


func start(data: Dictionary, use_virtual := false, axis := 8) -> void:
	package = data
	virtual = use_virtual
	cache_axis = clampi(axis, 4, 16)
	last_error = Decoder.validate(data)
	if not last_error.is_empty(): return
	if virtual:
		var pages := 0
		for mip in range(int(data.mips)):
			var grid := _grid(mip)
			pages += grid.x*grid.y
		cache_axis=mini(cache_axis,ceili(sqrt(float(pages))))
	var texture_bytes := 0
	if virtual:
		texture_bytes=cache_axis*cache_axis*STRIDE*STRIDE*4*data.maps.size()
	else:
		for mip in range(int(data.mips)): texture_bytes+=maxi(1,int(data.width)>>mip)*maxi(1,int(data.height)>>mip)*4*data.maps.size()
	stats.texture_bytes=texture_bytes
	stats.placeholder_bytes=(3-data.maps.size())*4
	stats.source_cpu_bytes=data.constants.size()+data.weights.size()+data.latents.size()+data.layout.size()*4
	if RenderingServer.get_rendering_device() == null:
		last_error = "NTC 通用 GPU 解码需要 Forward+ / Mobile / FRP；Compatibility 和 WebGL 不支持 Compute。"
		return
	var height := 0
	for mip in range(int(data.mips)):
		_rows.append(height)
		height += _grid(mip).y
	_page_size = Vector2i(_grid(0).x, height)
	if virtual:
		_page_bytes.resize(_page_size.x * _page_size.y * 16)
		_page_bytes.fill(0)
		stats.page_table_bytes = _page_bytes.size()
		# Coarse mip tail is never evicted. Request coarsest first for a valid fallback.
		for mip in range(int(data.mips)-1, -1, -1):
			if _grid(mip) != Vector2i.ONE: continue
			var key := Vector3i(0,0,mip)
			_pinned[key] = true
			_queue.append(key)
	else:
		# Finish coarse mip levels first; only publish the material once all levels are ready.
		for mip in range(int(data.mips)-1, -1, -1):
			var grid := _grid(mip)
			for y in range(grid.y):
				for x in range(grid.x): _queue.append(Vector3i(x,y,mip))
	Runtime.register(self)


func _grid(mip: int) -> Vector2i:
	var tile := TILE if virtual else LOAD_TILE
	return Vector2i(maxi(1,ceili(float(int(package.width)>>mip)/tile)), maxi(1,ceili(float(int(package.height)>>mip)/tile)))


func request_uv_rect(rect: Rect2, mip: int) -> void:
	if not virtual or _closed or not last_error.is_empty(): return
	_clock += 1
	mip = clampi(mip,0,int(package.mips)-1)
	var desired_mip := mip
	# Repeat coordinates are allowed. Never thrash if a request exceeds the cache: choose a coarser mip.
	var keys: Array[Vector3i] = []
	while true:
		keys = _keys(rect,mip)
		if keys.size() + _pinned.size() <= cache_axis*cache_axis or mip >= int(package.mips)-1: break
		mip += 1
	_wanted.clear()
	for key in keys:
		_wanted[key] = true
		_last_used[key] = _clock
		if not _resident.has(key) and not _queue.has(key): _queue.append(key)
	stats.requests += 1
	stats.requested_mip = mip
	stats.desired_mip = desired_mip
	stats.capacity_limited = mip > desired_mip
	stats.requested_resolution = Vector2i(maxi(1,int(package.width)>>mip),maxi(1,int(package.height)>>mip))


func _keys(rect: Rect2, mip: int) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var grid := _grid(mip)
	var begin := Vector2i(floor(rect.position.x*grid.x),floor(rect.position.y*grid.y))
	var end := Vector2i(ceil(rect.end.x*grid.x),ceil(rect.end.y*grid.y))
	for y in range(begin.y, mini(begin.y+grid.y,maxi(begin.y+1,end.y))):
		for x in range(begin.x, mini(begin.x+grid.x,maxi(begin.x+1,end.x))):
			result.append(Vector3i(posmod(x,grid.x),posmod(y,grid.y),mip))
	return result


func tick() -> bool:
	if _closed or _inflight or not last_error.is_empty(): return false
	while not _queue.is_empty():
		var key: Vector3i = _queue.pop_front()
		if virtual and (_resident.has(key) or (not _pinned.has(key) and not _wanted.has(key))): continue
		var slot := -1
		if virtual:
			if _slots.size() < cache_axis*cache_axis:
				slot = _slots.size(); _slots.append(key)
			else:
				var oldest := 2147483647
				for i in range(_slots.size()):
					var old: Vector3i = _slots[i]
					if _pinned.has(old) or _wanted.has(old): continue
					if int(_last_used.get(old,-1)) < oldest:
						oldest = int(_last_used.get(old,-1)); slot = i
				if slot < 0: continue
				var evicted := _slots[slot]
				_resident.erase(evicted); _last_used.erase(evicted)
				_refresh_pages(evicted)
				_slots[slot] = key; stats.evictions += 1
			_resident[key] = slot
			_refresh_pages(key)
		_inflight = true
		RenderingServer.call_on_render_thread(_render_step.bind(key,slot,_page_bytes.duplicate()))
		return true
	return false


func _refresh_pages(changed_page: Vector3i) -> void:
	# Only descendants of this page can change fallback. A fine page updates one cell,
	# rather than rebuilding the entire virtual texture on every cache miss.
	for mip in range(changed_page.z,-1,-1):
		var grid := _grid(mip)
		var shift := changed_page.z-mip
		var begin := Vector2i(changed_page.x<<shift,changed_page.y<<shift)
		var end := Vector2i((changed_page.x+1)<<shift,(changed_page.y+1)<<shift).min(grid)
		for y in range(begin.y,end.y):
			for x in range(begin.x,end.x):
				var key := Vector3i(x,y,mip)
				var offset := ((_rows[mip]+y)*_page_size.x+x)*16
				if _resident.has(key):
					var slot: int=_resident[key]
					var atlas := float(cache_axis*STRIDE)
					_page_bytes.encode_float(offset,((slot%cache_axis)*STRIDE+BORDER-x*TILE)/atlas)
					_page_bytes.encode_float(offset+4,((slot/cache_axis)*STRIDE+BORDER-y*TILE)/atlas)
					_page_bytes.encode_float(offset+8,maxi(1,int(package.width)>>mip)/atlas)
					_page_bytes.encode_float(offset+12,maxi(1,int(package.height)>>mip)/atlas)
				elif mip+1<int(package.mips):
					var parent := ((_rows[mip+1]+y/2)*_page_size.x+x/2)*16
					for component in range(4): _page_bytes.encode_u32(offset+component*4,_page_bytes.decode_u32(parent+component*4))


func _render_step(key: Vector3i, slot: int, table: PackedByteArray) -> void:
	var rd := RenderingServer.get_rendering_device()
	var error := ""
	if _decoder == null:
		_decoder = Decoder.new()
		_allocation.decoder = _decoder
		var size := Vector2i.ONE * (cache_axis*STRIDE) if virtual else Vector2i(package.width,package.height)
		if not _decoder.initialize(rd,package,size,1 if virtual else int(package.mips),virtual):
			error = _decoder.last_error
		elif virtual:
			var format := RDTextureFormat.new()
			format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
			format.width = _page_size.x; format.height = _page_size.y
			format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
			_rd_pages = rd.texture_create(format,RDTextureView.new(),[table])
			_allocation.pages = _rd_pages
			if not _rd_pages.is_valid(): error = "Cannot allocate NTC page table"
	if error.is_empty():
		var tile := TILE if virtual else LOAD_TILE
		var source := Rect2i(key.x*tile,key.y*tile,tile,tile)
		var destination := source.position
		if virtual:
			var extent := Vector2i(maxi(1,int(package.width)>>key.z),maxi(1,int(package.height)>>key.z))
			source.size=source.size.min(extent-source.position)+Vector2i.ONE*(BORDER*2)
			source.position -= Vector2i.ONE*BORDER
			destination = Vector2i(slot%cache_axis,slot/cache_axis)*STRIDE
		else:
			source.size = source.size.min(Vector2i(maxi(1,int(package.width)>>key.z),maxi(1,int(package.height)>>key.z))-source.position)
		if not _decoder.dispatch(source,destination,key.z,0 if virtual else key.z): error = "Invalid NTC page dispatch"
		if virtual: rd.texture_update(_rd_pages,0,table)
	_complete.call_deferred(error, _decoder.textures.duplicate(), _rd_pages, _decoder.dispatch_count, _decoder.decoded_texels, _decoder.gpu_compressed_bytes)


func _complete(error: String, rids: Dictionary, pages: RID, dispatches: int, texels: int, compressed_bytes: int) -> void:
	_inflight = false
	if _closed: return
	last_error = error
	if not error.is_empty(): changed.emit(); return
	stats.dispatches = dispatches; stats.decoded_texels = texels; stats.resident_pages = _resident.size()
	stats.gpu_compressed_bytes=compressed_bytes
	if textures.is_empty():
		for name: String in package.maps:
			var texture := GPUTexture.new()
			texture.allocation = _allocation
			texture.texture_rd_rid = rids[name]
			textures[name] = texture
		if virtual:
			page_texture = GPUTexture.new()
			page_texture.allocation = _allocation
			page_texture.texture_rd_rid = pages
	ready = virtual or _queue.is_empty()
	if ready and not virtual:
		RenderingServer.call_on_render_thread(_decoder.release_network)
		stats.gpu_compressed_bytes=0
	changed.emit()


func close() -> void:
	if _closed: return
	_closed = true
	if not ready and last_error.is_empty(): last_error = "NTC loading was cancelled."
	textures.clear(); page_texture = null
	# Keep the allocation until prior submissions finish, then let texture references own it.
	RenderingServer.call_on_render_thread(func(): _release_main.call_deferred())


func _release_main() -> void:
	_decoder = null; _allocation = null; _rd_pages = RID()
