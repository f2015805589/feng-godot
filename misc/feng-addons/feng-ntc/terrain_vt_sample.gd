@tool
extends RefCounted
## Compressed GPU residency with an independently bounded decoded-page cache.
const Packing = preload("sample_gpu_data.gd")
var packages: Array[Dictionary] = []
var _rd: RenderingDevice
var _material: RID
var _rids: Array[RID] = []
var _wrappers: Array[RID] = []
var _page_bytes := PackedByteArray()
var _page_texture: RID
var _slots := 0
var _initialized := false
var _dirty := false
var _closed := false
var _error := ""
var gpu_bytes := 0
var cache_pages := 384
var cache_budget_mib := 128
var cache_compression := -1
var max_pages_per_frame := 4
var catalog: Dictionary = {}
var _cache_stats := {}
var _cache: RefCounted
var _entries := {}
var _cached := {}
var _cache_dirty := false
var _cache_bound := false
var _cache_running := false
var _cache_capacity := 0
var _candidates := {}
var _priority_keys: Array = []
var _priorities := {}
var _priority_cursor := -1
var _selection_msec := -100
var _compressed_bytes := 0
var _view := Projection()
var _view_size := Vector2.ZERO
var _anisotropy := 1.0

func update_view(view: Projection, size: Vector2, anisotropy: float) -> void:
	_view = view; _view_size = size; _anisotropy = maxf(1.0, anisotropy)
	_cache_dirty = true

func _cache_priority(entry: Dictionary) -> float:
	var size: float = entry.world.size.x
	if _view_size == Vector2.ZERO: return 1.0/size
	var origin: Vector2 = entry.world.position
	var center := origin + Vector2.ONE*size*0.5
	var clip := _view*Vector4(center.x, 0.0, center.y, 1.0)
	if clip.w <= 0.0: return 0.0
	var dx := _view*Vector4(center.x+size*0.01, 0.0, center.y, 1.0)
	var dy := _view*Vector4(center.x, 0.0, center.y+size*0.01, 1.0)
	if absf(dx.w) < 1e-6 or absf(dy.w) < 1e-6: return 0.0
	var a := (Vector2(dx.x,dx.y)/dx.w-Vector2(clip.x,clip.y)/clip.w)*_view_size/(size*0.02)
	var b := (Vector2(dy.x,dy.y)/dy.w-Vector2(clip.x,clip.y)/clip.w)*_view_size/(size*0.02)
	var aa := a.dot(a); var ab := a.dot(b); var bb := b.dot(b)
	var major := sqrt(maxf(0.5*(aa+bb+sqrt((aa-bb)*(aa-bb)+4.0*ab*ab)), 1e-12))
	var minor := absf(a.cross(b))/major
	var footprint := maxf(1.0/major, 1.0/(maxf(minor,1e-9)*_anisotropy))
	var ratio := size/(float(entry.core)*footprint)
	var low := Vector2(1e6,1e6); var high := Vector2(-1e6,-1e6)
	for corner: Vector2 in [origin,origin+Vector2(size,0),origin+Vector2(0,size),origin+Vector2.ONE*size]:
		var p := _view*Vector4(corner.x,0.0,corner.y,1.0)
		if p.w <= 0.0: low=Vector2(-1,-1); high=Vector2.ONE; break
		var uv := Vector2(p.x,p.y)/p.w
		low=low.min(uv); high=high.max(uv)
	var extent := (high.min(Vector2.ONE)-low.max(Vector2(-1,-1))).max(Vector2.ZERO)
	var area := extent.x*extent.y
	return area/(1.0+pow(absf(log(maxf(ratio,1e-9))/log(2.0)),4.0)*4.0)
static func shader_code(data: Array[Dictionary]) -> String:
	var code := FileAccess.get_file_as_string("res://addons/feng-ntc/shaders/terrain_sample.gdshaderinc")
	# Fixed activation indices are essential here: dynamic local-array indexing
	# spills the tiny network to per-fragment scratch memory on several drivers.
	var layers := int(data[0].layers)
	var same_shape := true
	var all_narrow := true
	for package: Dictionary in data:
		same_shape = same_shape and int(package.layers) == layers
		all_narrow = all_narrow and not bool(Packing.encode_tensor(package).wide)
	if all_narrow:
		var begin := code.find("    if (!wide)")
		var end := code.find("\n}", begin)
		code = code.substr(0, begin) + "    return floatBitsToUint(ntc_fetch(packet+index))^mask;" + code.substr(end)
	if not same_shape: return code
	code = code.replace("int layers=int(meta.w)", "int layers=%d" % layers)
	code = code.replace("int source=first?(row<layers*2?(row/layers)*4+row%layers:8+row-layers*2):row;",
		"int source=first?(row<%d?(row/%d)*4+row%%%d:8+row-%d):row;" % [layers*2,layers,layers,layers*2])
	code = code.replace("bases.x,layers*2+4,64", "bases.x,%d,64" % (layers*2+4))

	return code

func configure_material(material: RID) -> void: _material = material

func _texture(format: RenderingDevice.DataFormat, width: int, height: int, bytes: PackedByteArray, update := false) -> RID:
	var desc := RDTextureFormat.new()
	desc.width = width; desc.height = height; desc.format = format
	desc.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | (RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT if update else 0)
	var rid := _rd.texture_create(desc, RDTextureView.new(), [bytes])
	if rid.is_valid(): _rids.append(rid); gpu_bytes += bytes.size()
	return rid

func _initialize(slots: int) -> bool:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null or packages.is_empty(): return false
	_slots = slots
	var metadata := PackedVector4Array()
	metadata.resize(packages.size()*12)
	var networks := PackedByteArray()
	var features := PackedByteArray()
	var descriptions: Array[Dictionary] = []
	for data: Dictionary in packages:
		var encoding := Packing.encode_tensor(data)
		descriptions.append(encoding)
	var offset: int = metadata.size()
	for model in range(packages.size()):
		var data: Dictionary = packages[model]
		var encoding: Dictionary = descriptions[model]
		metadata[model*12] = Vector4(data.width, data.height, offset, data.layers)
		metadata[model*12+1] = Vector4(encoding.bases)
		metadata[model*12+2] = Vector4(encoding.mask)
		metadata[model*12+3] = Vector4(1.0 if encoding.wide else 0.0, data.constants.decode_float(4), data.constants.decode_float(8), 0.0)
		var neural := int(data.constants.decode_u32(0))
		for level in range(2):
			for layer in range(int(data.layers)):
				var index := ((neural+level)*int(data.layers)+layer)*4
				var w := int(data.layout[index+1]); var h := int(data.layout[index+2])
				metadata[model*12+4+level*4+layer] = Vector4(features.size()/2, w, h, 0.0)
				for row in range(h):
					var begin := int(data.layout[index])+row*int(data.layout[index+3])
					features.append_array(data.latents.slice(begin, begin+w*2))
		networks.append_array(encoding.bytes)
		offset += encoding.bytes.size()/16
	var tensor := metadata.to_byte_array()
	tensor.append_array(networks)
	var tensor_h := ceili(tensor.size()/1024.0)
	tensor.resize(tensor_h*1024)
	var feature_h := ceili(features.size()/8192.0)
	features.resize(feature_h*8192)
	if feature_h > _rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D):
		_error = "NTC compressed feature store exceeds this GPU's texture limit"; return false
	var tensor_rid := _texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, 64, tensor_h, tensor)
	var features_rid := _texture(RenderingDevice.DATA_FORMAT_R8G8_UNORM, 4096, feature_h, features)
	_page_bytes.resize(64*ceili(slots/64.0)*16)
	_page_texture = _texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, 64, ceili(slots/64.0), _page_bytes, true)
	if not tensor_rid.is_valid() or not features_rid.is_valid() or not _page_texture.is_valid(): return false
	for pair: Array in [["_ntc_tensor", tensor_rid], ["_ntc_latents", features_rid], ["_ntc_pages", _page_texture]]:
		var wrapper := RenderingServer.texture_rd_create(pair[1])
		if not wrapper.is_valid(): return false
		_wrappers.append(wrapper)
		if _material.is_valid(): RenderingServer.material_set_param(_material, pair[0], wrapper)
	return true

func register_page(entry: Dictionary, slot: int, slots: int) -> Dictionary:
	if _closed: return {"ok": false}
	if not _initialized:
		_initialized = _initialize(slots)
		if not _initialized: dispose(); return {"ok": false, "error": _error}
	if slots != _slots:
		var old := _page_texture
		var old_bytes := _page_bytes.size()
		_page_bytes.resize(64*ceili(slots/64.0)*16)
		_page_texture = _texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, 64, ceili(slots/64.0), _page_bytes, true)
		if not _page_texture.is_valid(): dispose(); return {"ok": false}
		var wrapper := RenderingServer.texture_rd_create(_page_texture)
		if not wrapper.is_valid(): dispose(); return {"ok": false}
		if _material.is_valid(): RenderingServer.material_set_param(_material, "_ntc_pages", wrapper)
		RenderingServer.free_rid(_wrappers[2]); _wrappers[2] = wrapper
		gpu_bytes -= old_bytes
		if _cache != null: _compressed_bytes += _page_bytes.size()-old_bytes
		_rids.erase(old); _rd.free_rid(old)
		for old_slot: int in _entries.keys():
			if old_slot >= slots:
				_entries.erase(old_slot)
		_slots = slots; _dirty = true
	if slot < 0 or slot >= _slots: return {"ok": false}
	var rect: Rect2i = entry.rect
	var offset := slot*16
	_page_bytes.encode_float(offset, rect.position.x)
	_page_bytes.encode_float(offset+4, rect.position.y)
	_page_bytes.encode_float(offset+8, int(entry.model)+1)
	_page_bytes.encode_float(offset+12, 0.0)
	_entries[slot] = entry
	_dirty = true
	return {"ok": true, "gpu_bytes": gpu_bytes}

func invalidate_slot(slot: int) -> void:
	if slot >= 0 and slot < _slots:
		_page_bytes.encode_float(slot*16+8, 0.0)
		_dirty = true
		_entries.erase(slot)

func _update_cache() -> void:
	if cache_pages <= 0 or _entries.is_empty(): return
	if _cache == null:
		var first: Dictionary = _entries.values()[0]
		var parts: PackedStringArray = first.key.split("/")
		var decoder := preload("terrain_vt_decoder.gd").new()
		decoder.packages = packages
		_cache = ClassDB.instantiate(&"Terrain3DSurfaceBaker")
		_cache.set_tier_compression(0, 4)
		_cache.set_tier_compression(1, 4)
		_cache.set_materials(RID(), RID(), PackedColorArray(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedVector2Array(), PackedVector3Array())
		_cache.set_neural_codec({"decoder": decoder, "pages": catalog.duplicate(true), "source_signature": "ntc-resident-cache", "cache_compression": cache_compression, "max_pages_per_frame": max_pages_per_frame})
		var stored := int(parts[1])+2*int(parts[2])
		# Keep RGBA16F fallback bounded too, on devices without BC support.
		var compressed := int(_cache.get_tier_compression_info(0).available) != 0
		# Three RGBA16F channels plus the producer's R16/R32 source arrays.
		var page_bytes := ceili(stored/4.0)*ceili(stored/4.0)*48 if compressed else stored*stored*30
		var scratch_bytes := stored*stored*30*8 if compressed else 0
		_cache_capacity = maxi(2, mini(cache_pages, (cache_budget_mib*1048576-scratch_bytes)/page_bytes))
		_cache.configure(int(parts[1]), int(parts[2]), _cache_capacity)
		_compressed_bytes = gpu_bytes
		# Cached layers are keyed by immutable virtual page identity, not by the
		# terrain's recyclable logical slots. Reassigning a slot need not re-decode.
		for key: String in catalog:
			var fields := key.split("/")
			_candidates[key] = {"world": Rect2(float(fields[3]),float(fields[4]),float(fields[5]),float(fields[6])), "core": int(fields[1]), "tier": int(fields[0])}
		_cache_dirty = true
	if _cache_dirty and _priority_cursor < 0 and Time.get_ticks_msec()-_selection_msec>=100:
		_priority_keys = _candidates.keys()
		_priority_cursor = 0; _cache_dirty = false
		_selection_msec = Time.get_ticks_msec()
	if _priority_cursor >= 0:
		# Cache pages matching the visible projected pixel footprint. Other virtual
		# pages retain their full resolution. Spread scoring over several frames;
		# hysteresis avoids evicting good pages for tiny changes at the cutoff.
		var end := mini(_priority_cursor+128,_priority_keys.size())
		for i in range(_priority_cursor,end):
			var key: String = _priority_keys[i]
			var score := _cache_priority(_candidates[key])
			_priorities[key] = score*1.15+1e-12 if _cached.has(key) else score
		_priority_cursor = end if end<_priority_keys.size() else -1
		if _priority_cursor < 0: _select_cache()
	if _cache_running:
		_cache.render_pending()
		_cache_stats = _cache.get_stats()
		gpu_bytes = _compressed_bytes + int(_cache_stats.material_bytes) + int(_cache_stats.neural_gpu_bytes)
		_cache_running = int(_cache_stats.pending)+int(_cache_stats.encode_pending) > 0
		_dirty = true
	if _dirty:
		for slot: int in _entries:
			var key: String = _entries[slot].key
			var layer := int(_cached.get(key,-1))
			var value := float(layer+1) if layer>=0 and _cache.is_page_ready(layer) else 0.0
			_page_bytes.encode_float(slot*16+12, value)
	if not _cache_bound and _material.is_valid() and _cache.get_albedo_rid().is_valid():
		RenderingServer.material_set_param(_material, "_ntc_cache_albedo", _cache.get_albedo_rid())
		RenderingServer.material_set_param(_material, "_ntc_cache_normal", _cache.get_normal_rid())
		RenderingServer.material_set_param(_material, "_ntc_cache_params", _cache.get_params_rid())
		var info: Dictionary = _cache.get_tier_compression_info(0)
		RenderingServer.material_set_param(_material, "_ntc_cache_normal_encoding", int(info.normal_applied))
		RenderingServer.material_set_param(_material, "_ntc_cache_params_encoded", bool(info.params_encoded))
		_cache_bound = true

func _select_cache() -> void:
	# Native packed-array sort avoids thousands of GDScript comparator callbacks.
	var ranked := PackedInt64Array()
	for i in range(_priority_keys.size()):
		var key: String = _priority_keys[i]
		var rank := int(float(_priorities[key])*1e9)*2+int(_cached.has(key))
		ranked.append((rank<<24)|i)
	ranked.sort(); ranked.reverse()
	var wanted := {}
	for i in range(mini(_cache_capacity,ranked.size())): wanted[_priority_keys[ranked[i]&0xffffff]]=true
	var free: Array[int] = []
	var used := {}
	for key: String in _cached.keys():
		if not wanted.has(key):
			_cache.invalidate_slot(_cached[key]); _cached.erase(key)
			_dirty = true
		else: used[_cached[key]] = true
	for layer in range(_cache_capacity-1,-1,-1):
		if not used.has(layer): free.append(layer)
	for key: String in wanted:
		if _cached.has(key): continue
		var layer: int = free.pop_back()
		var candidate: Dictionary = _candidates[key]
		if _cache.queue_neural_page(layer,candidate.world,candidate.tier,"ntc-resident-cache"): _cached[key]=layer
		_cache_running = true

func flush_pages() -> Dictionary:
	if _closed: return {}
	_update_cache()
	if _dirty and _page_texture.is_valid():
		_rd.texture_update(_page_texture, 0, _page_bytes)
		if _material.is_valid(): RenderingServer.material_set_param(_material, "_ntc_ready", true)
		_dirty = false
	return {"gpu_bytes": gpu_bytes, "compressed_bytes": _compressed_bytes if _cache != null else gpu_bytes,
		"decoded_bytes": _cache_stats.get("material_bytes", 0), "decoder_working_bytes": _cache_stats.get("neural_gpu_bytes", 0),
		"cache_capacity": _cache_capacity, "cache_pending": int(_cache_stats.get("pending", 0))+int(_cache_stats.get("encode_pending", 0))+int(cache_pages>0 and (_priority_cursor>=0 or _cache_dirty)),
		"cache_decodes": _cache_stats.get("neural_decodes", 0), "cache_ready": _cache_stats.get("ready_pages", 0)}

func dispose() -> void:
	_closed = true
	if _cache != null: _cache.clear(); _cache = null
	if _rd == null: return
	for wrapper: RID in _wrappers: RenderingServer.free_rid(wrapper)
	for rid: RID in _rids: _rd.free_rid(rid)
	_wrappers.clear(); _rids.clear(); _rd = null
