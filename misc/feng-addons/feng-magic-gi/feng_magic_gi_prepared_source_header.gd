@tool
class_name FMagicGIPreparedSourceHeader
extends Resource
## Small layout/identity descriptor. Never owns world-sized transport arrays.
@export_storage var dimensions := Vector3i.ZERO
@export_storage var origin_world := Vector3.ZERO
@export_storage var spacing_m := 0.25
@export_storage var prepared_level_count := 4
@export_storage var domain_bounds_world := AABB()
@export_storage var source_transform_world := Transform3D.IDENTITY
@export_storage var source_size_m := Vector3.ZERO
@export_storage var emitter_count := 0
@export_storage var emitter_ids := PackedStringArray()
@export_storage var emitter_static_signatures := PackedInt64Array()
@export_storage var directional_source_signature := ""
@export_storage var geometry_signature := 0
@export_storage var maximum_operator_row_l1 := 0.0
@export_storage var operator_schema_version := 0
@export_storage var clv_prepared_dimensions := PackedInt32Array()
## The OLV generation binding that was consumed while preparing this source.
## An empty value is retained for generations baked before OLV was enabled.
@export_storage var olv_binding_signature := ""

func is_header_valid() -> bool:
	if spacing_m != 0.25 or prepared_level_count < 1 or prepared_level_count > 10 \
			or dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0 \
			or not origin_world.is_finite() or not source_transform_world.is_finite() \
			or absf(source_transform_world.basis.determinant()) < 0.00000001 \
			or not source_size_m.is_finite() or minf(source_size_m.x, minf(source_size_m.y, source_size_m.z)) <= 0 \
			or not domain_bounds_world.position.is_finite() or not domain_bounds_world.size.is_finite() \
			or minf(domain_bounds_world.size.x, minf(domain_bounds_world.size.y, domain_bounds_world.size.z)) <= 0 \
			or emitter_count < 0 or emitter_count > 32 or emitter_ids.size() != emitter_count \
			or emitter_static_signatures.size() != emitter_count or directional_source_signature.is_empty() \
			or operator_schema_version != 2 \
			or clv_prepared_dimensions.size() != prepared_level_count * 3 \
			or not is_finite(maximum_operator_row_l1) or maximum_operator_row_l1 < 0.0:
		return false
	for level in prepared_level_count:
		var expected := Vector3i((Vector3(dimensions) / float(1 << level)).ceil())
		for axis in 3:
			if clv_prepared_dimensions[level * 3 + axis] != expected[axis]: return false
	return true

func is_valid() -> bool:
	return is_header_valid()

func has_preinterpolated_clv(expected_olv_binding_signature := "") -> bool:
	return is_header_valid() and (expected_olv_binding_signature.is_empty() \
			or olv_binding_signature == expected_olv_binding_signature)

func is_paged_prepared_source() -> bool:
	return true

static func from_manifest(manifest: Resource) -> Resource:
	if manifest == null or manifest.transport_domain != "prepared_free_space_bricks_v1":
		return null
	var result := new()
	result.origin_world = manifest.prepared_source_origin_world
	result.domain_bounds_world = manifest.world_bounds
	result.dimensions = Vector3i((manifest.world_bounds.size / result.spacing_m).ceil())
	result.prepared_level_count = manifest.prepared_level_count
	result.source_transform_world = manifest.prepared_source_transform_world
	result.source_size_m = manifest.prepared_source_size_m
	result.emitter_ids = manifest.prepared_emitter_ids
	result.emitter_static_signatures = manifest.prepared_emitter_static_signatures
	result.emitter_count = result.emitter_ids.size()
	result.directional_source_signature = manifest.prepared_source_signature
	result.geometry_signature = manifest.bake_geometry_signature
	result.maximum_operator_row_l1 = manifest.prepared_maximum_operator_row_l1
	result.operator_schema_version = int(manifest.get("prepared_operator_schema_version"))
	var olv_context_value: Variant = manifest.get("prepared_olv_context")
	if bool(manifest.get("prepared_olv_filter_enabled")) \
			and olv_context_value is Dictionary:
		var olv_context: Dictionary = olv_context_value
		var olv_scene_id := String(olv_context.get("scene_id", ""))
		var olv_volume_id := String(olv_context.get("volume_id", ""))
		var olv_layout_revision := int(olv_context.get("layout_revision", -1))
		var olv_layout_signature := String(olv_context.get("layout_signature", ""))
		var olv_labels_hash := String(olv_context.get("labels_hash", ""))
		if not olv_scene_id.is_empty() and not olv_volume_id.is_empty() \
				and olv_layout_revision >= 0 and not olv_layout_signature.is_empty() \
				and not olv_labels_hash.is_empty():
			result.olv_binding_signature = JSON.stringify([
				olv_scene_id, olv_volume_id, olv_layout_revision,
				olv_layout_signature, olv_labels_hash], "", true, true).sha256_text()
	for level in result.prepared_level_count:
		var dims := Vector3i((Vector3(result.dimensions) / float(1 << level)).ceil())
		result.clv_prepared_dimensions.append_array(PackedInt32Array([dims.x, dims.y, dims.z]))
	return result if result.is_header_valid() else null
