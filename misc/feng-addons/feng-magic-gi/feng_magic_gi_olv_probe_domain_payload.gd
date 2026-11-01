@tool
class_name FMagicGIOlvProbeDomainPayload
extends Resource
## One byte per logical free-space source probe. This is an offline-only input
## to CLV preinterpolation; the runtime consumes the resulting prepared
## operators and never runs the classifier.

const Domain = preload("feng_magic_gi_olv_domain.gd")
const FORMAT_VERSION := 1
const SCHEMA_ID := "feng_magic_gi_olv_probe_domain_byte_v1"
const MAX_PROBES := 262144
const BYTE_ORDER := "logical_z_y_x_cell_index_v1"
const SOURCE_POSITION_MAPPING_SCHEMA := "exact_source_chunk_world_anchor_per_logical_probe_v1"

@export_storage var schema_id := SCHEMA_ID
@export_storage var format_version := FORMAT_VERSION
@export_storage var scene_id := ""
@export_storage var volume_id := ""
@export_storage var layout_revision := -1
@export_storage var target_layout_signature := ""
@export_storage var target_label_set_sha256 := ""
@export_storage var source_geometry_signature := 0
@export_storage var geometry_triangles_sha256 := ""
@export_storage var source_directional_signature := ""
@export_storage var source_layout_sha256 := ""
@export_storage var probe_position_sha256 := ""
@export_storage var supported_probe_spacing_m := 0.0
@export_storage var supported_target_cell_spacings_m := PackedFloat32Array()
## Exact feature context extent used for each output. This is separate from the
## denser source-probe lattice: an approved 0.5 m model may label probes every
## 0.25 m only when its inference features still use the trained 0.5 m extent.
@export_storage var feature_context_extent_m := Vector3.ZERO
@export_storage var supported_feature_context_extents_m := PackedVector3Array()
@export_storage var model_sha256 := ""
@export_storage var feature_schema_id := ""
@export_storage var feature_schema_sha256 := ""
@export_storage var decision_policy_id := ""
@export_storage var probe_count := 0
var _runtime_revision := 1
var _binding_cache_revision := -1
var _binding_cache_key := ""
var _binding_cache_result := ""
@export_storage var labels := PackedByteArray():
	set(value):
		labels = value
		_runtime_revision += 1
		_binding_cache_revision = -1
		_binding_cache_key = ""
		_binding_cache_result = ""
@export_storage var payload_sha256 := ""
@export_storage var header_sha256 := ""


func get_runtime_revision() -> int:
	return _runtime_revision


## Cheap cache identity for consumers that must notice direct header edits.
## This serializes only the small metadata header; it never hashes labels.
func get_runtime_cache_key() -> String:
	return "%d|%s" % [_runtime_revision, _runtime_header_cache_key()]


func _runtime_header_cache_key() -> String:
	return JSON.stringify(_unsigned_header(), "", true, true) + "|" + header_sha256


## Call this after an intentional in-place edit to labels or a header field.
## PackedByteArray element edits do not invoke the property setter.
func mark_content_changed() -> void:
	_runtime_revision += 1
	_binding_cache_revision = -1
	_binding_cache_key = ""
	_binding_cache_result = ""
	emit_changed()


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}


static func _is_sha256(value: String) -> bool:
	if value.length() != 64 or value != value.to_lower():
		return false
	for character in value:
		if not "0123456789abcdef".contains(character):
			return false
	return true


static func sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


## The fingerprint binds exact logical probe order, positions (after relocation),
## validity, source-grid metadata, and the exact triangle geometry SHA. It is
## intentionally computed from the actual source resource rather than a caller
## supplied path or timestamp.
static func source_binding(source: Resource) -> Dictionary:
	if source == null or not source.has_method("is_source_data_valid") \
			or not source.is_source_data_valid():
		return _fail("invalid_source_chunk")
	if source.probe_count <= 0 or source.probe_count > MAX_PROBES \
			or source.probe_count != source.cell_count() \
			or source.validity.size() != source.probe_count \
			or not _is_sha256(String(source.geometry_triangles_sha256)):
		return _fail("source_layout_or_exact_geometry_hash_missing")
	var positions := HashingContext.new()
	if positions.start(HashingContext.HASH_SHA256) != OK:
		return _fail("position_hash_start_failed")
	for logical_index in source.probe_count:
		var position: Vector3 = source.cell_position(logical_index)
		if not position.is_finite():
			return _fail("non_finite_source_probe_position:%d" % logical_index)
		# Vector3 is serialized as three float32 values by Godot. Hash the exact
		# world anchor bytes alongside index and relocation validity.
		var identity_bytes := PackedInt32Array([logical_index, int(source.validity[logical_index])]).to_byte_array()
		if positions.update(identity_bytes) != OK \
				or positions.update(PackedFloat32Array([position.x, position.y, position.z]).to_byte_array()) != OK:
			return _fail("position_hash_update_failed")
	var position_sha := positions.finish().hex_encode()
	var lattice := {
		"layout": String(source.layout),
		"dimensions": [source.dimensions.x, source.dimensions.y, source.dimensions.z],
		"origin_world": [source.origin_world.x, source.origin_world.y, source.origin_world.z],
		"spacing_m": float(source.spacing_m),
		"global_cell_origin": [source.global_cell_origin.x, source.global_cell_origin.y,
				source.global_cell_origin.z],
		"source_lod": int(source.source_lod),
		"geometry_triangles_sha256": String(source.geometry_triangles_sha256),
		"source_directional_signature": String(source.directional_source_signature),
		"probe_position_sha256": position_sha,
		"source_probe_position_mapping_schema": SOURCE_POSITION_MAPPING_SCHEMA,
		"byte_order": BYTE_ORDER,
	}
	var layout_sha := JSON.stringify(lattice, "", true, true).sha256_text()
	return {"ok": true, "probe_position_sha256": position_sha,
		"source_layout_sha256": layout_sha}


## Build from already produced labels. This function does not map CLV cells to
## source probes: the caller must supply labels and the exact world anchor for
## every source logical probe. The position array is checked one-for-one against
## the live chunk before bytes are accepted, so a same-sized CLV-cell label list
## cannot be silently treated as source-probe predictions.
func configure_for_source(source: Resource, p_labels: PackedByteArray,
		metadata: Dictionary) -> Dictionary:
	var binding := source_binding(source)
	if not bool(binding.get("ok", false)):
		return _fail(String(binding.get("error", "invalid_source_binding")))
	if p_labels.size() != source.probe_count:
		return _fail("label_byte_count_must_equal_logical_probe_count")
	var required := ["scene_id", "volume_id", "layout_revision", "target_layout_signature",
		"target_label_set_sha256", "geometry_triangles_sha256", "model_sha256",
		"feature_schema_id", "feature_schema_sha256", "decision_policy_id",
		"supported_probe_spacing_m", "supported_target_cell_spacings_m",
		"feature_context_extent_m", "supported_feature_context_extents_m",
		"source_probe_positions"]
	for key in required:
		if not metadata.has(key):
			return _fail("metadata_missing:" + key)
	if String(metadata.scene_id).is_empty() or String(metadata.volume_id).is_empty() \
			or int(metadata.layout_revision) < 0 \
			or String(metadata.target_layout_signature).is_empty() \
			or not _is_sha256(String(metadata.target_label_set_sha256)) \
			or String(metadata.geometry_triangles_sha256) != String(source.geometry_triangles_sha256) \
			or not _is_sha256(String(metadata.model_sha256)) \
			or String(metadata.feature_schema_id).is_empty() \
			or not _is_sha256(String(metadata.feature_schema_sha256)) \
			or String(metadata.decision_policy_id).is_empty() \
			or not is_finite(float(metadata.supported_probe_spacing_m)) \
			or absf(float(metadata.supported_probe_spacing_m) - float(source.spacing_m)) > 0.000001:
		return _fail("metadata_binding_or_supported_probe_scale_mismatch")
	var target_spacings: Variant = metadata.supported_target_cell_spacings_m
	if not target_spacings is PackedFloat32Array and not target_spacings is Array:
		return _fail("supported_target_cell_spacings_m_invalid")
	if target_spacings.is_empty():
		return _fail("supported_target_cell_spacings_m_empty")
	var context_extent: Variant = metadata.feature_context_extent_m
	var supported_context_extents: Variant = metadata.supported_feature_context_extents_m
	if not context_extent is Vector3 or not context_extent.is_finite() \
			or context_extent.x <= 0.0 or context_extent.y <= 0.0 or context_extent.z <= 0.0 \
			or not supported_context_extents is PackedVector3Array \
			or supported_context_extents.is_empty():
		return _fail("feature_context_extent_binding_invalid")
	var context_extent_supported := false
	for supported_extent in supported_context_extents:
		if not supported_extent.is_finite() \
				or supported_extent.x <= 0.0 or supported_extent.y <= 0.0 or supported_extent.z <= 0.0:
			return _fail("supported_feature_context_extent_invalid")
		if (supported_extent - context_extent).length() <= 0.000001:
			context_extent_supported = true
	if not context_extent_supported:
		return _fail("feature_context_extent_not_supported_by_model")
	var source_positions: Variant = metadata.source_probe_positions
	if not source_positions is PackedVector3Array \
			or source_positions.size() != source.probe_count:
		return _fail("source_probe_world_positions_required_in_logical_order")
	for logical_index in source.probe_count:
		if not source_positions[logical_index].is_finite() \
				or source_positions[logical_index] != source.cell_position(logical_index):
			return _fail("source_probe_world_position_mismatch:%d" % logical_index)
	for spacing in target_spacings:
		if not is_finite(float(spacing)) or float(spacing) <= 0.0:
			return _fail("supported_target_cell_spacing_invalid")
	for index in p_labels.size():
		var label := int(p_labels[index])
		if not Domain.is_valid_label(label):
			return _fail("invalid_domain_byte:%d:%d" % [index, label])
		if not source.cell_is_valid(index) and label != Domain.LABEL_UNSET:
			return _fail("invalid_source_slot_must_be_unknown:%d" % index)
	schema_id = SCHEMA_ID
	format_version = FORMAT_VERSION
	scene_id = String(metadata.scene_id)
	volume_id = String(metadata.volume_id)
	layout_revision = int(metadata.layout_revision)
	target_layout_signature = String(metadata.target_layout_signature)
	target_label_set_sha256 = String(metadata.target_label_set_sha256)
	source_geometry_signature = int(source.geometry_signature)
	geometry_triangles_sha256 = String(source.geometry_triangles_sha256)
	source_directional_signature = String(source.directional_source_signature)
	source_layout_sha256 = String(binding.source_layout_sha256)
	probe_position_sha256 = String(binding.probe_position_sha256)
	supported_probe_spacing_m = float(metadata.supported_probe_spacing_m)
	supported_target_cell_spacings_m = PackedFloat32Array()
	for spacing in target_spacings:
		supported_target_cell_spacings_m.append(float(spacing))
	supported_target_cell_spacings_m.sort()
	for index in range(supported_target_cell_spacings_m.size() - 1, 0, -1):
		if is_equal_approx(supported_target_cell_spacings_m[index], supported_target_cell_spacings_m[index - 1]):
			supported_target_cell_spacings_m.remove_at(index)
	feature_context_extent_m = context_extent
	supported_feature_context_extents_m = supported_context_extents.duplicate()
	model_sha256 = String(metadata.model_sha256)
	feature_schema_id = String(metadata.feature_schema_id)
	feature_schema_sha256 = String(metadata.feature_schema_sha256)
	decision_policy_id = String(metadata.decision_policy_id)
	probe_count = source.probe_count
	labels = p_labels.duplicate()
	payload_sha256 = sha256_bytes(labels)
	header_sha256 = _compute_header_sha256()
	return validate_for_source(source)


func label_for_logical_probe(logical_index: int) -> int:
	if logical_index < 0 or logical_index >= probe_count or labels.size() != probe_count:
		return Domain.LABEL_UNSET
	return int(labels[logical_index])


func binding_sha256() -> String:
	var cache_key := get_runtime_cache_key()
	if _binding_cache_revision == _runtime_revision and _binding_cache_key == cache_key:
		return _binding_cache_result
	_binding_cache_revision = _runtime_revision
	_binding_cache_key = cache_key
	_binding_cache_result = ""
	if labels.size() != probe_count or sha256_bytes(labels) != payload_sha256 \
			or _compute_header_sha256() != header_sha256:
		return _binding_cache_result
	_binding_cache_result = header_sha256
	return _binding_cache_result


func validate_seal(expected_label_set_sha256 := "") -> Dictionary:
	if schema_id != SCHEMA_ID or format_version != FORMAT_VERSION:
		return _fail("unsupported_probe_payload_schema")
	if probe_count <= 0 or probe_count > MAX_PROBES or labels.size() != probe_count \
			or not _is_sha256(payload_sha256) or payload_sha256 != sha256_bytes(labels) \
			or not _is_sha256(header_sha256) or header_sha256 != _compute_header_sha256():
		return _fail("probe_payload_content_hash_mismatch")
	if not expected_label_set_sha256.is_empty() \
			and target_label_set_sha256 != expected_label_set_sha256:
		return _fail("target_label_set_hash_mismatch")
	for label in labels:
		if not Domain.is_valid_label(int(label)): return _fail("invalid_domain_byte")
	return {"ok": true, "error": ""}

func validate_for_source(source: Resource, expected_label_set_sha256 := "") -> Dictionary:
	var sealed := validate_seal(expected_label_set_sha256)
	if not bool(sealed.get("ok",false)): return sealed
	var binding := source_binding(source)
	if not bool(binding.get("ok", false)):
		return binding
	if probe_count != source.probe_count \
			or source_geometry_signature != int(source.geometry_signature) \
			or geometry_triangles_sha256 != String(source.geometry_triangles_sha256) \
			or source_directional_signature != String(source.directional_source_signature) \
			or source_layout_sha256 != String(binding.source_layout_sha256) \
			or probe_position_sha256 != String(binding.probe_position_sha256) \
			or absf(supported_probe_spacing_m - float(source.spacing_m)) > 0.000001:
		return _fail("probe_payload_source_binding_mismatch")
	if supported_target_cell_spacings_m.is_empty():
		return _fail("supported_target_cell_spacings_m_empty")
	for spacing in supported_target_cell_spacings_m:
		if not is_finite(spacing) or spacing <= 0.0:
			return _fail("supported_target_cell_spacing_invalid")
	if not feature_context_extent_m.is_finite() \
			or feature_context_extent_m.x <= 0.0 \
			or feature_context_extent_m.y <= 0.0 \
			or feature_context_extent_m.z <= 0.0 \
			or supported_feature_context_extents_m.is_empty():
		return _fail("feature_context_extent_binding_invalid")
	var context_extent_supported := false
	for supported_extent in supported_feature_context_extents_m:
		if not supported_extent.is_finite() \
				or supported_extent.x <= 0.0 or supported_extent.y <= 0.0 or supported_extent.z <= 0.0:
			return _fail("supported_feature_context_extent_invalid")
		if (supported_extent - feature_context_extent_m).length() <= 0.000001:
			context_extent_supported = true
	if not context_extent_supported:
		return _fail("feature_context_extent_not_supported_by_model")
	for index in probe_count:
		if not Domain.is_valid_label(int(labels[index])):
			return _fail("invalid_domain_byte:%d" % index)
		if not source.cell_is_valid(index) and int(labels[index]) != Domain.LABEL_UNSET:
			return _fail("invalid_source_slot_must_be_unknown:%d" % index)
	return {"ok": true, "error": ""}


func header_dictionary() -> Dictionary:
	var result := _unsigned_header()
	result["header_sha256"] = header_sha256
	return result


func save_pair(header_path: String, payload_path: String, source: Resource) -> Dictionary:
	var validation := validate_for_source(source)
	if not bool(validation.get("ok", false)):
		return _fail(String(validation.get("error", "invalid_probe_payload")))
	if header_path.is_empty() or payload_path.is_empty() or header_path == payload_path:
		return _fail("header_and_payload_paths_required")
	var payload_file := FileAccess.open(payload_path, FileAccess.WRITE)
	if payload_file == null:
		return _fail("payload_file_open_failed:%d" % FileAccess.get_open_error())
	payload_file.store_buffer(labels)
	payload_file.close()
	var header_file := FileAccess.open(header_path, FileAccess.WRITE)
	if header_file == null:
		return _fail("header_file_open_failed:%d" % FileAccess.get_open_error())
	header_file.store_string(JSON.stringify(header_dictionary(), "", true, true) + "\n")
	header_file.close()
	if FileAccess.get_sha256(payload_path) != payload_sha256:
		return _fail("written_payload_sha256_mismatch")
	return {"ok": true, "probe_count": probe_count, "bytes": labels.size(),
		"payload_sha256": payload_sha256, "header_sha256": header_sha256}


static func load_pair(header_path: String, payload_path: String, source: Resource,
		expected_label_set_sha256 := "") -> Dictionary:
	if not FileAccess.file_exists(header_path) or not FileAccess.file_exists(payload_path):
		return _fail("probe_payload_pair_missing")
	var header_text := FileAccess.get_file_as_string(header_path)
	var parsed: Variant = JSON.parse_string(header_text)
	if not parsed is Dictionary:
		return _fail("probe_payload_header_invalid_json")
	var header: Dictionary = parsed
	var codebook: Variant = header.get("label_codes")
	if String(header.get("schema_id", "")) != SCHEMA_ID \
			or int(header.get("format_version", -1)) != FORMAT_VERSION \
			or String(header.get("byte_order", "")) != BYTE_ORDER \
			or String(header.get("source_probe_position_mapping_schema", "")) \
				!= SOURCE_POSITION_MAPPING_SCHEMA \
			or not codebook is Dictionary \
			or int(codebook.get("unknown", -1)) != 0 \
			or int(codebook.get("exterior", -1)) != 1 \
			or int(codebook.get("interior", -1)) != 2 \
			or int(codebook.get("physical_mixed_abstain", -1)) != 3 \
			or codebook.size() != 4:
		return _fail("probe_payload_header_semantics_mismatch")
	var bytes := FileAccess.get_file_as_bytes(payload_path)
	if bytes.size() != int(header.get("probe_count", -1)) \
			or sha256_bytes(bytes) != String(header.get("payload_sha256", "")):
		return _fail("probe_payload_pair_bytes_mismatch")
	var payload_script := load("res://addons/feng-magic-gi/feng_magic_gi_olv_probe_domain_payload.gd") as Script
	if payload_script == null:
		return _fail("probe_payload_resource_script_missing")
	var resource: Resource = payload_script.new()
	var assign := {
		"schema_id": "schema_id", "format_version": "format_version",
		"scene_id": "scene_id", "volume_id": "volume_id", "layout_revision": "layout_revision",
		"target_layout_signature": "target_layout_signature",
		"target_label_set_sha256": "target_label_set_sha256",
		"source_geometry_signature": "source_geometry_signature",
		"geometry_triangles_sha256": "geometry_triangles_sha256",
		"source_directional_signature": "source_directional_signature",
		"source_layout_sha256": "source_layout_sha256",
		"probe_position_sha256": "probe_position_sha256",
		"supported_probe_spacing_m": "supported_probe_spacing_m",
		"model_sha256": "model_sha256", "feature_schema_id": "feature_schema_id",
		"feature_schema_sha256": "feature_schema_sha256",
		"decision_policy_id": "decision_policy_id", "probe_count": "probe_count",
		"payload_sha256": "payload_sha256", "header_sha256": "header_sha256",
	}
	for key: String in assign:
		if not header.has(key):
			return _fail("probe_payload_header_missing:" + key)
		resource.set(String(assign[key]), header[key])
	var target_spacings: Variant = header.get("supported_target_cell_spacings_m")
	if not target_spacings is Array:
		return _fail("probe_payload_header_target_spacings_invalid")
	resource.supported_target_cell_spacings_m = PackedFloat32Array()
	for spacing in target_spacings:
		resource.supported_target_cell_spacings_m.append(float(spacing))
	var supported_extents: Variant = header.get("supported_feature_context_extents_m")
	if not supported_extents is Array:
		return _fail("probe_payload_header_supported_feature_extents_invalid")
	resource.supported_feature_context_extents_m = PackedVector3Array()
	for extent in supported_extents:
		if not extent is Array or extent.size() != 3:
			return _fail("probe_payload_header_feature_extent_invalid")
		resource.supported_feature_context_extents_m.append(Vector3(
				float(extent[0]), float(extent[1]), float(extent[2])))
	var context_extent: Variant = header.get("feature_context_extent_m")
	if not context_extent is Array or context_extent.size() != 3:
		return _fail("probe_payload_header_feature_context_extent_invalid")
	resource.feature_context_extent_m = Vector3(float(context_extent[0]),
			float(context_extent[1]), float(context_extent[2]))
	resource.labels = bytes
	if resource.header_sha256 != resource._compute_header_sha256():
		return _fail("probe_payload_header_sha256_mismatch")
	var validation: Dictionary = resource.validate_for_source(source, expected_label_set_sha256)
	if not bool(validation.get("ok", false)):
		return validation
	return {"ok": true, "payload": resource}


func _unsigned_header() -> Dictionary:
	return {
		"schema_id": schema_id,
		"format_version": format_version,
		"scene_id": scene_id,
		"volume_id": volume_id,
		"layout_revision": layout_revision,
		"target_layout_signature": target_layout_signature,
		"target_label_set_sha256": target_label_set_sha256,
		"source_geometry_signature": source_geometry_signature,
		"geometry_triangles_sha256": geometry_triangles_sha256,
		"source_directional_signature": source_directional_signature,
		"source_layout_sha256": source_layout_sha256,
		"probe_position_sha256": probe_position_sha256,
		"source_probe_position_mapping_schema": SOURCE_POSITION_MAPPING_SCHEMA,
		"supported_probe_spacing_m": supported_probe_spacing_m,
		"supported_target_cell_spacings_m": Array(supported_target_cell_spacings_m),
		"feature_context_extent_m": [feature_context_extent_m.x,
			feature_context_extent_m.y, feature_context_extent_m.z],
		"supported_feature_context_extents_m": _vector3_array_to_json(
				supported_feature_context_extents_m),
		"model_sha256": model_sha256,
		"feature_schema_id": feature_schema_id,
		"feature_schema_sha256": feature_schema_sha256,
		"decision_policy_id": decision_policy_id,
		"probe_count": probe_count,
		"byte_order": BYTE_ORDER,
		"label_codes": {"unknown": 0, "exterior": 1, "interior": 2,
			"physical_mixed_abstain": 3},
		"payload_sha256": payload_sha256,
	}


func _compute_header_sha256() -> String:
	return JSON.stringify(_unsigned_header(), "", true, true).sha256_text()


static func _vector3_array_to_json(values: PackedVector3Array) -> Array:
	var result: Array = []
	for value in values:
		result.append([value.x, value.y, value.z])
	return result
