@tool
class_name FMagicGIManifest
extends Resource
## Lightweight index for one immutable streamed bake generation.
## Page payloads are stored separately and are never resource references here.

const FORMAT_VERSION := 2
const DEFAULT_MANAGEMENT_BLOCK_SIZE := 512.0
const MAX_INDEXED_BLOCKS := 262144

@export_storage var format_version := FORMAT_VERSION
@export_storage var manifest_key := ""
@export_storage var generation := ""
@export_storage var scene_identity := ""
@export_storage var volume_identity := ""
@export_storage var world_bounds := AABB()
@export_storage var management_block_size := DEFAULT_MANAGEMENT_BLOCK_SIZE
@export_storage var page_core_size := 32.0
@export_storage var bake_geometry_signature := 0
@export_storage var bake_settings_signature := 0
## Persistent scene-content fingerprint captured at bake/load boundaries. The
## page geometry-signature format remains unchanged; old manifests omit this.
@export_storage var scene_watch_signature := 0
## 0 is legacy absolute-path signature; 1 is relative to the scene root.
## Older manifests omit this field and retain the legacy validation path.
@export_storage var scene_watch_signature_schema_version := 0
@export_storage var partial_generation := false
@export_storage var page_entries: Array[Dictionary] = []

var _metadata_by_key: Dictionary = {}
var _block_index: Dictionary = {}
var _core_index: Dictionary = {}
var _index_ready := false
var _index_error := ""

func configure(entries: Array[Dictionary]) -> void:
	page_entries = []
	_metadata_by_key.clear()
	_block_index.clear()
	_core_index.clear()
	_index_ready = false
	_index_error = ""
	for entry in entries:
		page_entries.append(entry.duplicate(true))
	_build_spatial_index()

func is_valid() -> bool:
	if format_version < 1 or format_version > FORMAT_VERSION or generation.is_empty() \
			or not is_finite(management_block_size) or management_block_size <= 0.0 \
			or not is_finite(page_core_size) or page_core_size <= 0.0 \
			or not world_bounds.position.is_finite() or not world_bounds.size.is_finite() \
			or world_bounds.size.x < 0.0 or world_bounds.size.y < 0.0 \
			or world_bounds.size.z < 0.0:
		return false
	if not _index_ready:
		_build_spatial_index()
	return _index_error.is_empty() and _metadata_by_key.size() == page_entries.size()

## Returns page keys whose half-open ownership core intersects a bounded query.
## The first call builds an XZ management-block index; later calls visit only
## intersected blocks, never the complete page list.
func get_page_keys_for_bounds(bounds: AABB) -> PackedStringArray:
	var result := PackedStringArray()
	if not _valid_query_bounds(bounds):
		return result
	if not _index_ready:
		_build_spatial_index()
	if not _index_error.is_empty():
		return result
	var min_block_x := floori(bounds.position.x / management_block_size)
	var min_block_z := floori(bounds.position.z / management_block_size)
	var max_x := bounds.position.x + bounds.size.x
	var max_z := bounds.position.z + bounds.size.z
	var max_block_x := ceili(max_x / management_block_size) - 1
	var max_block_z := ceili(max_z / management_block_size) - 1
	if max_block_x < min_block_x or max_block_z < min_block_z:
		return result
	var block_count := (max_block_x - min_block_x + 1) * (max_block_z - min_block_z + 1)
	if block_count <= 0 or block_count > MAX_INDEXED_BLOCKS:
		return result
	var found: Dictionary = {}
	for block_z in range(min_block_z, max_block_z + 1):
		for block_x in range(min_block_x, max_block_x + 1):
			var block_key := _block_key(block_x, block_z)
			for page_key_variant in _block_index.get(block_key, []):
				var page_key := String(page_key_variant)
				if found.has(page_key):
					continue
				var metadata: Dictionary = _metadata_by_key.get(page_key, {})
				var core: AABB = metadata.get("core_bounds", AABB())
				if _intersects_half_open(core, bounds):
					found[page_key] = true
	var keys: Array = found.keys()
	keys.sort()
	for key in keys:
		result.append(String(key))
	return result

func get_page_keys_for_chunk(chunk_x: int, chunk_z: int) -> PackedStringArray:
	if not _index_ready:
		_build_spatial_index()
	var result := PackedStringArray()
	for key_variant in _block_index.get(_block_key(chunk_x, chunk_z), []):
		result.append(String(key_variant))
	result.sort()
	return result

## Metadata dictionaries are returned as copies, so callers cannot mutate the
## published generation's index through a lookup result.
func get_page_metadata(page_key: String) -> Dictionary:
	if not _index_ready:
		_build_spatial_index()
	var metadata: Dictionary = _metadata_by_key.get(page_key, {})
	return metadata.duplicate(true)

func get_page_path(page_key: String) -> String:
	var metadata := get_page_metadata(page_key)
	return String(metadata.get("resource_path", ""))

func get_page_count() -> int:
	return page_entries.size()

func total_probe_count() -> int:
	var total := 0
	for entry in page_entries:
		if not bool(entry.get("empty", false)):
			total += maxi(int(entry.get("probe_count", 0)), 0)
	return total

func get_index_error() -> String:
	if not _index_ready:
		_build_spatial_index()
	return _index_error

func _build_spatial_index() -> void:
	_metadata_by_key.clear()
	_block_index.clear()
	_core_index.clear()
	_index_error = ""
	_index_ready = true
	if not is_finite(management_block_size) or management_block_size <= 0.0:
		_index_error = "Invalid management block size."
		return
	for entry in page_entries:
		var page_key := String(entry.get("page_key", ""))
		var core: AABB = entry.get("core_bounds", AABB())
		var support: AABB = entry.get("support_bounds", AABB())
		var influence: AABB = entry.get("influence_bounds", support)
		var empty_page := bool(entry.get("empty", false))
		var path := String(entry.get("resource_path", ""))
		if page_key.is_empty() or _metadata_by_key.has(page_key) \
				or not _valid_query_bounds(core) or not _valid_query_bounds(support) \
				or not _contains_aabb(support, core) \
				or (format_version >= 2 and (not _valid_query_bounds(influence) \
				or not _contains_aabb(influence, support))) \
				or (empty_page and not path.is_empty()) \
				or (not empty_page and path.is_empty()):
			_index_error = "Invalid or duplicate page metadata: %s" % page_key
			_metadata_by_key.clear()
			_block_index.clear()
			return
		var indexed_entry := entry.duplicate(true)
		# v1 was only used by pre-release local builds and did not serialize the
		# influence extent. Keep it readable; the baker derives a conservative
		# extent from support and the unchanged bake settings when rebaking.
		if not indexed_entry.has("influence_bounds"):
			indexed_entry["influence_bounds"] = support
		_metadata_by_key[page_key] = indexed_entry
		var min_x := floori(core.position.x / management_block_size)
		var min_z := floori(core.position.z / management_block_size)
		var end_x := core.position.x + core.size.x
		var end_z := core.position.z + core.size.z
		var max_x := ceili(end_x / management_block_size) - 1
		var max_z := ceili(end_z / management_block_size) - 1
		if max_x < min_x or max_z < min_z:
			_index_error = "Page core does not cover a management block: %s" % page_key
			_metadata_by_key.clear()
			_block_index.clear()
			return
		var block_count := (max_x - min_x + 1) * (max_z - min_z + 1)
		if block_count > 4:
			_index_error = "A page core crosses too many management blocks: %s" % page_key
			_metadata_by_key.clear()
			_block_index.clear()
			return
		for block_z in range(min_z, max_z + 1):
			for block_x in range(min_x, max_x + 1):
				var key := _block_key(block_x, block_z)
				var keys: Array = _block_index.get(key, [])
				keys.append(page_key)
				_block_index[key] = keys
		if core.size.x > page_core_size + _boundary_epsilon(page_core_size) \
				or core.size.y > page_core_size + _boundary_epsilon(page_core_size) \
				or core.size.z > page_core_size + _boundary_epsilon(page_core_size):
			_index_error = "Page core exceeds the indexed page size: %s" % page_key
			_metadata_by_key.clear()
			_block_index.clear()
			_core_index.clear()
			return
		var min_cx := floori(core.position.x / page_core_size)
		var min_cy := floori(core.position.y / page_core_size)
		var min_cz := floori(core.position.z / page_core_size)
		var max_cx := ceili(core.end.x / page_core_size) - 1
		var max_cy := ceili(core.end.y / page_core_size) - 1
		var max_cz := ceili(core.end.z / page_core_size) - 1
		for cy in range(min_cy, max_cy + 1):
			for cz in range(min_cz, max_cz + 1):
				for cx in range(min_cx, max_cx + 1):
					var core_bucket := _core_bucket_key(cx, cy, cz)
					var existing_keys: Array = _core_index.get(core_bucket, [])
					for existing_key in existing_keys:
						var existing: Dictionary = _metadata_by_key[String(existing_key)]
						var existing_core: AABB = existing.get("core_bounds", AABB())
						if _intersects_half_open(existing_core, core):
							_index_error = "Page ownership cores overlap: %s and %s" % [page_key, existing_key]
							_metadata_by_key.clear()
							_block_index.clear()
							_core_index.clear()
							return
					existing_keys.append(page_key)
					_core_index[core_bucket] = existing_keys

func _valid_query_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
			and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0

func _contains_aabb(outer: AABB, inner: AABB) -> bool:
	var epsilon := maxf(0.00001, management_block_size * 0.0000001)
	return outer.position.x <= inner.position.x + epsilon \
			and outer.position.y <= inner.position.y + epsilon \
			and outer.position.z <= inner.position.z + epsilon \
			and outer.end.x + epsilon >= inner.end.x \
			and outer.end.y + epsilon >= inner.end.y \
			and outer.end.z + epsilon >= inner.end.z

func _intersects_half_open(a: AABB, b: AABB) -> bool:
	return a.position.x < b.end.x and b.position.x < a.end.x \
			and a.position.y < b.end.y and b.position.y < a.end.y \
			and a.position.z < b.end.z and b.position.z < a.end.z

func _boundary_epsilon(value: float) -> float:
	return maxf(0.000001, absf(value) * 0.000000001)

func _block_key(x: int, z: int) -> String:
	return "%d,%d" % [x, z]

func _core_bucket_key(x: int, y: int, z: int) -> String:
	return "%d,%d,%d" % [x, y, z]
