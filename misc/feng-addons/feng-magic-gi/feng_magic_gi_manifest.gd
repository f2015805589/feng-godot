@tool
class_name FMagicGIManifest
extends Resource
## Lightweight index for one immutable streamed bake generation.
## Page payloads are stored separately and are never resource references here.

const FORMAT_VERSION := 2
const Data = preload("feng_magic_gi_data.gd")
const DEFAULT_MANAGEMENT_BLOCK_SIZE := 512.0
const MAX_INDEXED_BLOCKS := 262144

@export_storage var format_version := FORMAT_VERSION
@export_storage var manifest_key := ""
@export_storage var generation := ""
@export_storage var scene_identity := ""
@export_storage var volume_identity := ""
## Identifies the immutable transport domain without loading page payloads.
## Empty remains the legacy surface-probe page format.
@export_storage var transport_domain := ""
@export_storage var prepared_source_origin_world := Vector3.ZERO
@export_storage var prepared_level_count := 0
@export_storage var prepared_emitter_ids := PackedStringArray()
@export_storage var prepared_emitter_static_signatures := PackedInt64Array()
@export_storage var prepared_source_signature := ""
@export_storage var prepared_source_transform_world := Transform3D.IDENTITY
@export_storage var prepared_source_size_m := Vector3.ZERO
@export_storage var prepared_maximum_operator_row_l1 := 0.0
## Prepared free-space CLV format: four L0+L1 coefficients by 16 inputs.
## Zero marks an unversioned/legacy manifest, which must be rebaked.
@export_storage var prepared_operator_schema_version := 0
@export_storage var prepared_core_axis := 16
@export_storage var prepared_bake_algorithm := ""
## Optional old source page path used only by explicit source-Probe diagnostics.
@export_storage var prepared_debug_source_path := ""
@export_storage var world_bounds := AABB()
@export_storage var management_block_size := DEFAULT_MANAGEMENT_BLOCK_SIZE
@export_storage var page_core_size := 32.0
@export_storage var bake_geometry_signature := 0
@export_storage var bake_settings_signature := 0
## Optional bake provenance. Zero values mean this generation predates the
## metadata or the setting does not apply; never infer them from a live Volume.
@export_storage var bake_samples := 0
@export_storage var bake_bounces := 0
@export_storage var bake_moment_rays := 0
## Persistent scene-content fingerprint captured at bake/load boundaries. The
## page geometry-signature format remains unchanged; old manifests omit this.
@export_storage var scene_watch_signature := 0
## 0 is legacy absolute-path signature; 1 is relative to the scene root.
## Older manifests omit this field and retain the legacy validation path.
@export_storage var scene_watch_signature_schema_version := 0
@export_storage var partial_generation := false
## Marks page generations whose page Data resources contain the persistent
## indirect-radiance SH field. Zero remains the legacy page format.
@export_storage var baked_indirect_sh_revision := 0
@export_storage var baked_indirect_lighting_signature := 0
@export_storage var baked_indirect_sh_algorithm := ""
@export_storage var baked_indirect_directional_source_signature := ""
@export_storage var baked_indirect_directional_source_provenance: Dictionary = {}
## Generation-wide immutable primary-Sky capture provenance. Older manifests
## omit it and remain loadable for legacy transport, but cannot serve backend-1.
@export_storage var baked_indirect_sky_provenance: Dictionary = {}
@export_storage var page_entries: Array[Dictionary] = []

var _metadata_by_key: Dictionary = {}
var _block_index: Dictionary = {}
var _core_index: Dictionary = {}
var _prepared_index: Dictionary = {}
var _index_ready := false
var _index_error := ""
var _sky_provenance_validation_cached := false
var _sky_provenance_validation_result := false
var _cached_total_probe_count := 0
var _baked_indirect_validation_cached := false
var _baked_indirect_validation_result := false

func configure(entries: Array[Dictionary]) -> void:
	page_entries = []
	_invalidate_validation_cache()
	for entry in entries:
		page_entries.append(entry.duplicate(true))
	_build_spatial_index()

## Published generations are immutable. Call this when a resource is edited
## directly so its structural index and one-time backend-1 validation rebuild.
func _invalidate_validation_cache() -> void:
	_metadata_by_key.clear()
	_block_index.clear()
	_core_index.clear()
	_prepared_index.clear()
	_index_ready = false
	_index_error = ""
	_sky_provenance_validation_cached = false
	_sky_provenance_validation_result = false
	_cached_total_probe_count = 0
	_baked_indirect_validation_cached = false
	_baked_indirect_validation_result = false

func is_valid() -> bool:
	if format_version < 1 or format_version > FORMAT_VERSION or generation.is_empty() \
			or not is_finite(management_block_size) or management_block_size <= 0.0 \
			or not is_finite(page_core_size) or page_core_size <= 0.0 \
			or not world_bounds.position.is_finite() or not world_bounds.size.is_finite() \
			or world_bounds.size.x < 0.0 or world_bounds.size.y < 0.0 \
			or world_bounds.size.z < 0.0:
		return false
	if transport_domain == "prepared_free_space_bricks_v1" \
			and (prepared_level_count < 1 or prepared_level_count > 10 \
			or prepared_operator_schema_version != 2 \
			or not prepared_source_origin_world.is_finite() \
			or prepared_source_signature.is_empty() \
			or prepared_core_axis < 1 or prepared_core_axis > 32 \
			or prepared_emitter_ids.size() > 32 \
			or prepared_emitter_static_signatures.size() != prepared_emitter_ids.size()):
		return false
	if not _index_ready:
		_build_spatial_index()
	return _index_error.is_empty() and _metadata_by_key.size() == page_entries.size()

func has_baked_indirect_sh() -> bool:
	if not _baked_indirect_validation_cached:
		_baked_indirect_validation_result = _validate_baked_indirect_sh_once()
		_baked_indirect_validation_cached = true
	return _baked_indirect_validation_result \
			and baked_indirect_sh_revision == Data.BAKED_INDIRECT_SH_REVISION \
			and _cached_total_probe_count > 0

func _validate_baked_indirect_sh_once() -> bool:
	if not is_valid() or baked_indirect_sh_revision != Data.BAKED_INDIRECT_SH_REVISION \
			or _cached_total_probe_count <= 0 or not _baked_sky_provenance_is_valid():
		return false
	for entry in page_entries:
		var empty_page := bool(entry.get("empty", false))
		if (not empty_page and int(entry.get("probe_count", 0)) <= 0) \
				or (empty_page and int(entry.get("probe_count", 0)) != 0) \
				or int(entry.get("baked_indirect_sh_revision", 0)) != Data.BAKED_INDIRECT_SH_REVISION \
				or entry.get("baked_indirect_sky_provenance", {}) != baked_indirect_sky_provenance \
				or _resolved_entry_algorithm(entry) != _resolved_algorithm() \
				or String(entry.get("baked_indirect_directional_source_signature", "")) \
				!= baked_indirect_directional_source_signature:
			return false
	if not Data.is_valid_baked_indirect_directional_provenance(_resolved_algorithm(),
			baked_indirect_directional_source_signature,
			baked_indirect_directional_source_provenance):
		return false
	return true

func _resolved_algorithm() -> String:
	return Data.BAKED_INDIRECT_SH_ALGORITHM_LEGACY if baked_indirect_sh_algorithm.is_empty() \
			else baked_indirect_sh_algorithm

func _resolved_entry_algorithm(entry: Dictionary) -> String:
	var algorithm := String(entry.get("baked_indirect_sh_algorithm", ""))
	return Data.BAKED_INDIRECT_SH_ALGORITHM_LEGACY if algorithm.is_empty() else algorithm

func _baked_sky_provenance_is_valid() -> bool:
	if not _sky_provenance_validation_cached:
		_sky_provenance_validation_result = Data.is_valid_baked_indirect_sky_provenance(
				baked_indirect_sky_provenance)
		_sky_provenance_validation_cached = true
	return _sky_provenance_validation_result

## Returns page keys whose half-open ownership core intersects a bounded query.
## The first call builds an XZ management-block index; later calls visit only
## intersected blocks, never the complete page list.
func get_page_keys_for_bounds(bounds: AABB) -> PackedStringArray:
	var result := PackedStringArray()
	if transport_domain == "prepared_free_space_bricks_v1":
		for level in prepared_level_count:
			result.append_array(get_page_keys_for_level_bounds(level, bounds))
		return result
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

## O(number of requested lattice bricks), independent of other levels and the
## total world page count. Runtime queries each resident CLV level separately.
func get_page_keys_for_level_bounds(level: int, bounds: AABB) -> PackedStringArray:
	var result := PackedStringArray()
	if transport_domain != "prepared_free_space_bricks_v1" or level < 0 \
			or level >= prepared_level_count or not _valid_query_bounds(bounds): return result
	if not _index_ready: _build_spatial_index()
	if not _index_error.is_empty() or prepared_core_axis <= 0: return result
	var step := 0.25 * float(1 << level)
	var first := Vector3i(((bounds.position - prepared_source_origin_world) / step + Vector3.ONE * 0.5).floor())
	var last := Vector3i(((bounds.end - prepared_source_origin_world) / step + Vector3.ONE * 0.5).ceil()) - Vector3i.ONE
	var first_brick := Vector3i((Vector3(first) / float(prepared_core_axis)).floor())
	var last_brick := Vector3i((Vector3(last) / float(prepared_core_axis)).floor())
	var count := last_brick - first_brick + Vector3i.ONE
	if count.x <= 0 or count.y <= 0 or count.z <= 0 \
			or float(count.x) * count.y * count.z > MAX_INDEXED_BLOCKS: return result
	for z in range(first_brick.z, last_brick.z + 1):
		for y in range(first_brick.y, last_brick.y + 1):
			for x in range(first_brick.x, last_brick.x + 1):
				var key := "%d:%d,%d,%d" % [level, x, y, z]
				var page_key := String(_prepared_index.get(key, ""))
				if not page_key.is_empty(): result.append(page_key)
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
	if not _index_ready:
		_build_spatial_index()
	return _cached_total_probe_count

func get_index_error() -> String:
	if not _index_ready:
		_build_spatial_index()
	return _index_error

func _build_spatial_index() -> void:
	_metadata_by_key.clear()
	_block_index.clear()
	_core_index.clear()
	_prepared_index.clear()
	_index_error = ""
	_index_ready = true
	_cached_total_probe_count = 0
	_baked_indirect_validation_cached = false
	_baked_indirect_validation_result = false
	_sky_provenance_validation_cached = false
	_sky_provenance_validation_result = false
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
		var prepared_level := int(entry.get("prepared_level", -1))
		if transport_domain == "prepared_free_space_bricks_v1" \
				and (prepared_level < 0 or prepared_level >= prepared_level_count \
				or String(entry.get("prepared_source_signature", "")) != prepared_source_signature \
				or int(entry.get("prepared_operator_schema_version", 0)) != prepared_operator_schema_version):
			_index_error = "Invalid prepared brick identity/level: %s" % page_key
			return
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
		if not empty_page:
			_cached_total_probe_count += maxi(int(entry.get("probe_count", 0)), 0)
		if transport_domain == "prepared_free_space_bricks_v1":
			var origin: Vector3i = entry.get("core_cell_origin", Vector3i(-1, -1, -1))
			var dims: Vector3i = entry.get("core_dimensions", Vector3i.ZERO)
			var valid_core := prepared_core_axis > 0
			for axis in 3:
				valid_core = valid_core and origin[axis] >= 0 and origin[axis] % maxi(prepared_core_axis, 1) == 0 \
						and dims[axis] > 0 and dims[axis] <= prepared_core_axis
			var coord := origin / maxi(prepared_core_axis, 1)
			var prepared_key := "%d:%d,%d,%d" % [prepared_level, coord.x, coord.y, coord.z]
			var step := 0.25 * float(1 << prepared_level)
			var expected_core := AABB(prepared_source_origin_world + Vector3(origin) * step - Vector3.ONE * step * 0.5, Vector3(dims) * step)
			if not valid_core or _prepared_index.has(prepared_key) \
					or not core.position.is_equal_approx(expected_core.position) or not core.size.is_equal_approx(expected_core.size):
				_index_error = "Invalid or duplicate prepared brick ownership: %s" % page_key
				return
			_prepared_index[prepared_key] = page_key
			continue
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
					if transport_domain == "prepared_free_space_bricks_v1":
						core_bucket = str(prepared_level) + ":" + core_bucket
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
