@tool
class_name FMagicGIPage
extends Resource
## One immutable streamed page. The manifest stores only this resource's path.

const Data = preload("feng_magic_gi_data.gd")
const VolumeSourceChunk = preload("feng_magic_gi_volume_source_chunk.gd")
const PreparedTransferBrick = preload("feng_magic_gi_prepared_transfer_brick.gd")

@export_storage var format_version := 1
@export_storage var generation := ""
@export_storage var page_key := ""
@export_storage var core_bounds := AABB()
@export_storage var support_bounds := AABB()
@export_storage var probe_count := 0
@export_storage var cpu_bytes := 0
@export_storage var gpu_bytes := 0
@export_storage var geometry_signature := 0
@export_storage var settings_signature := 0
@export_storage var baked_indirect_sh_revision := 0
@export_storage var baked_indirect_sh_algorithm := ""
@export_storage var baked_indirect_directional_source_signature := ""
@export_storage var baked_indirect_directional_source_provenance: Dictionary = {}
@export_storage var baked_indirect_sky_provenance: Dictionary = {}
@export_storage var data: Data
## Optional independent regular free-space transport bake for dynamic CLV PRT.
## Legacy pages omit it and continue using their existing surface-probe resource.
@export_storage var free_space_volume_source: VolumeSourceChunk
@export_storage var prepared_transfer_brick: PreparedTransferBrick

func is_header_valid(expected_generation := "", expected_key := "") -> bool:
	if format_version != 1 or generation.is_empty() or page_key.is_empty() \
			or (not expected_generation.is_empty() and generation != expected_generation) \
			or (not expected_key.is_empty() and page_key != expected_key) \
			or not _valid_bounds(core_bounds) or not _valid_bounds(support_bounds) \
			or not _contains(support_bounds, core_bounds):
		return false
	if prepared_transfer_brick != null:
		return data == null and free_space_volume_source == null \
				and prepared_transfer_brick.is_header_valid(geometry_signature) \
				and prepared_transfer_brick.probe_count == probe_count \
				and core_bounds == prepared_transfer_brick.core_bounds() \
				and support_bounds == prepared_transfer_brick.support_bounds() \
				and cpu_bytes >= prepared_transfer_brick.estimated_cpu_resident_bytes() \
				and gpu_bytes >= prepared_transfer_brick.estimated_gpu_payload_bytes()
	if free_space_volume_source != null:
		# A dynamic free-space page stores exactly one transport domain. Keeping the
		# legacy surface payload beside it would load two large coefficient sets.
		var source_gpu_bytes := free_space_volume_source.estimated_gpu_payload_bytes()
		var claims_prepared := free_space_volume_source.format_version == VolumeSourceChunk.FORMAT_VERSION_PACKED \
				or free_space_volume_source.clv_preparation_revision != 0
		if claims_prepared and not free_space_volume_source.has_preinterpolated_clv():
			# A stale derived operator is ignored for raw-source diagnostics. It is
			# rejected by is_valid() below and therefore cannot enter runtime GI.
			source_gpu_bytes = 0
		return data == null and free_space_volume_source.is_header_valid(geometry_signature) \
				and free_space_volume_source.probe_count == probe_count \
				and free_space_volume_source.geometry_signature == geometry_signature \
				and cpu_bytes >= free_space_volume_source.estimated_payload_bytes() \
				and gpu_bytes >= source_gpu_bytes
	return data != null and data.probe_count() == probe_count \
			and cpu_bytes >= data.estimate_cpu_bytes() \
			and gpu_bytes >= data.estimate_gpu_bytes()

func is_valid(expected_generation := "", expected_key := "") -> bool:
	if not is_header_valid(expected_generation, expected_key):
		return false
	if prepared_transfer_brick != null:
		return prepared_transfer_brick.is_valid(geometry_signature)
	if free_space_volume_source != null:
		return free_space_volume_source.is_valid(geometry_signature) \
				and free_space_volume_source.probe_count == probe_count
	return data != null and data.is_valid() and data.probe_count() == probe_count

## Deep-validates the raw source payload for diagnostics that intentionally read
## the original SH9 bake data. It does not validate or enable its prepared CLV
## operators; runtime page admission continues to use is_valid().
func is_source_data_valid(expected_generation := "", expected_key := "") -> bool:
	if not is_header_valid(expected_generation, expected_key) \
			or free_space_volume_source == null:
		return false
	return free_space_volume_source.is_source_data_valid(geometry_signature) \
			and free_space_volume_source.probe_count == probe_count

func has_baked_indirect_sh() -> bool:
	return data != null and is_valid() \
			and baked_indirect_sh_revision == Data.BAKED_INDIRECT_SH_REVISION \
			and data.baked_indirect_sh_revision == baked_indirect_sh_revision \
			and data.has_baked_indirect_sh() \
			and not baked_indirect_sky_provenance.is_empty() \
			and Data.is_valid_baked_indirect_sky_provenance(baked_indirect_sky_provenance) \
			and data.baked_indirect_sky_provenance == baked_indirect_sky_provenance \
			and _resolved_algorithm() == data._resolved_baked_indirect_sh_algorithm() \
			and baked_indirect_directional_source_signature == data.baked_indirect_directional_source_signature \
			and baked_indirect_directional_source_provenance == data.baked_indirect_directional_source_provenance \
			and Data.is_valid_baked_indirect_directional_provenance(
				_resolved_algorithm(), baked_indirect_directional_source_signature,
				baked_indirect_directional_source_provenance)

func _resolved_algorithm() -> String:
	return Data.BAKED_INDIRECT_SH_ALGORITHM_LEGACY if baked_indirect_sh_algorithm.is_empty() \
			else baked_indirect_sh_algorithm

static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
			and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0

static func _contains(outer: AABB, inner: AABB) -> bool:
	return outer.position.x <= inner.position.x and outer.position.y <= inner.position.y \
			and outer.position.z <= inner.position.z and outer.end.x >= inner.end.x \
			and outer.end.y >= inner.end.y and outer.end.z >= inner.end.z
