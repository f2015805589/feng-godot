@tool
class_name FMagicGIData
extends Resource
## Immutable v3 surface PRT transport. Far-field illumination and receiver
## albedo remain separate; fixed emissive surfaces add runtime-composed transport.

const FORMAT_VERSION := 3
const LEGACY_FORMAT_VERSION := 2
const SAMPLER_REVISION := 2
const MAX_GRID_AXIS := 64
const MAX_EMITTERS := 32
const ATLAS_COLUMNS := 32
const TRANSFER_TEXELS_PER_POINT := 7
const GEOMETRY_TEXELS_PER_POINT := 2
const CELL_CAPACITY := 8
const CELL_BOUNDARY_EPSILON := 0.00001
const SH_Y00 := 0.2820947918
const SH_L1_ABSOLUTE_BOUND := 0.488602512
const SH_L2_ABSOLUTE_BOUND := 0.630783131
const RUNTIME_ATLAS_FILTER_EPSILON := 0.00001

@export_storage var format_version := 0
@export_storage var grid_dims := Vector3i.ZERO
@export_storage var volume_transform := Transform3D.IDENTITY
@export_storage var world_to_grid := Transform3D.IDENTITY
@export_storage var volume_size := Vector3.ZERO
@export_storage var spacing := 1.0
@export_storage var surface_offset := 0.03
@export_storage var bake_samples := 0
@export_storage var bake_bounces := 0
@export_storage var bake_distance := 0.0
@export_storage var terrain_reflectance := 0.0
@export_storage var material_reflectance := 0.0
@export_storage var scene_signature := 0
@export_storage var positions := PackedVector3Array()
@export_storage var normals := PackedVector3Array()
@export_storage var transfer := PackedFloat32Array()
## Stable root-relative NodePath + surface-index bindings, in transport order.
@export_storage var emitter_keys := PackedStringArray()
## Static texture/UV/geometry mapping fingerprints; live emission values are excluded.
@export_storage var emitter_static_signatures := PackedInt64Array()
## Emitter-major: (emitter * probe_count + probe) * 6 + term * 3 + channel.
## term 0 is uniform source radiance; term 1 is static emission-texture modulation.
@export_storage var emitter_transport := PackedFloat32Array()
@export_storage var cell_indices := PackedInt32Array()
@export_storage var bake_version := 0

# Old names are retained only so legacy .tres files still deserialize. Their
# radiance values never masquerade as geometry-only transport.
@export_storage var sh := PackedFloat32Array()
@export_storage var slot_of_probe := PackedInt32Array()

static func sh_basis(dir: Vector3) -> PackedFloat32Array:
	var c := PackedFloat32Array()
	c.resize(9)
	c[0] = SH_Y00
	c[1] = 0.4886025119 * dir.y
	c[2] = 0.4886025119 * dir.z
	c[3] = 0.4886025119 * dir.x
	c[4] = 1.0925484306 * dir.x * dir.y
	c[5] = 1.0925484306 * dir.y * dir.z
	c[6] = 0.3153915653 * (3.0 * dir.z * dir.z - 1.0)
	c[7] = 1.0925484306 * dir.x * dir.z
	c[8] = 0.5462742153 * (dir.x * dir.x - dir.y * dir.y)
	return c

## Wraps the 32-bit geometry fingerprint with the persisted sampler revision.
static func signature_for_geometry(geometry_signature: int) -> int:
	return (SAMPLER_REVISION << 32) | (geometry_signature & 0xffffffff)

func probe_count() -> int:
	return positions.size()

## Reports whether any geometry transport coefficient contributes. Volumes
## cache this O(coefficients) scan alongside full resource validation.
func has_nonzero_transfer() -> bool:
	for value in transfer:
		if value != 0.0:
			return true
	for value in emitter_transport:
		if value != 0.0:
			return true
	return false

func emitter_count() -> int:
	return emitter_keys.size()

func supports_format() -> bool:
	return format_version == LEGACY_FORMAT_VERSION or format_version == FORMAT_VERSION

## Full validation is O(points + grid cells). Volumes cache the result by
## resource identity and bake_version; render-frame layout checks stay O(1).
func is_valid() -> bool:
	if not supports_format() or bake_version <= 0:
		return false
	if probe_count() == 0 or normals.size() != probe_count():
		return false
	if transfer.size() != probe_count() * 27:
		return false
	if format_version == LEGACY_FORMAT_VERSION:
		# v2 has only far-field SH transport. It remains a valid legacy bake.
		if not emitter_keys.is_empty() or not emitter_static_signatures.is_empty() or not emitter_transport.is_empty():
			return false
	else:
		var source_count := emitter_count()
		if source_count > MAX_EMITTERS or emitter_static_signatures.size() != source_count \
				or emitter_transport.size() != probe_count() * source_count * 6:
			return false
		var seen_keys: Dictionary = {}
		for key in emitter_keys:
			if key.is_empty() or seen_keys.has(key):
				return false
			seen_keys[key] = true
		for value in emitter_transport:
			if not is_finite(value) or value < 0.0:
				return false
	if grid_dims.x <= 0 or grid_dims.y <= 0 or grid_dims.z <= 0:
		return false
	if grid_dims.x > MAX_GRID_AXIS or grid_dims.y > MAX_GRID_AXIS or grid_dims.z > MAX_GRID_AXIS:
		return false
	if cell_indices.size() != grid_dims.x * grid_dims.y * grid_dims.z * CELL_CAPACITY:
		return false
	if not volume_size.is_finite() or minf(volume_size.x, minf(volume_size.y, volume_size.z)) <= 0.0:
		return false
	if not _transform_is_finite(volume_transform) or not _transform_is_finite(world_to_grid):
		return false
	if absf(volume_transform.basis.determinant()) < 0.00000001 or absf(world_to_grid.basis.determinant()) < 0.00000001:
		return false
	if not is_finite(spacing) or spacing <= 0.0 or spacing > 4096.0:
		return false
	if not is_finite(surface_offset) or surface_offset <= 0.0 or surface_offset > 5.0:
		return false
	if not is_finite(bake_distance) or bake_distance <= 0.0 or bake_distance > 4096.0:
		return false
	if bake_samples <= 0 or bake_samples > 65536 or bake_bounces <= 0 or bake_bounces > 8:
		return false
	if not is_finite(terrain_reflectance) or terrain_reflectance < 0.0 or terrain_reflectance > 1.0:
		return false
	if not is_finite(material_reflectance) or material_reflectance < 0.0 or material_reflectance > 1.0:
		return false
	for i in probe_count():
		if not positions[i].is_finite() or not normals[i].is_finite():
			return false
		if absf(normals[i].length_squared() - 1.0) > 0.02:
			return false
	for value in transfer:
		if not is_finite(value):
			return false
	var mapped := PackedByteArray()
	mapped.resize(probe_count())
	mapped.fill(0)
	for index in cell_indices:
		if index < -1 or index >= probe_count():
			return false
		if index >= 0:
			mapped[index] = 1
	for present in mapped:
		if present == 0:
			return false
	return true

func matches_layout(
		size: Vector3,
		probe_spacing: float,
		probe_offset: float,
		transform: Transform3D,
		samples: int,
		bounces: int,
		distance: float,
		terrain_albedo: float,
		fallback_albedo: float) -> bool:
	return supports_format() \
		and volume_size.is_equal_approx(size) \
		and is_equal_approx(spacing, probe_spacing) \
		and is_equal_approx(surface_offset, probe_offset) \
		and volume_transform.is_equal_approx(transform) \
		and bake_samples == samples \
		and bake_bounces == bounces \
		and is_equal_approx(bake_distance, distance) \
		and is_equal_approx(terrain_reflectance, terrain_albedo) \
		and is_equal_approx(material_reflectance, fallback_albedo)

static func cell_coordinates(grid: Vector3, dimensions: Vector3i) -> Vector3i:
	if dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0 or not grid.is_finite():
		return Vector3i(-1, -1, -1)
	var upper := Vector3(dimensions)
	if grid.x < -CELL_BOUNDARY_EPSILON or grid.y < -CELL_BOUNDARY_EPSILON or grid.z < -CELL_BOUNDARY_EPSILON:
		return Vector3i(-1, -1, -1)
	if grid.x > upper.x + CELL_BOUNDARY_EPSILON or grid.y > upper.y + CELL_BOUNDARY_EPSILON or grid.z > upper.z + CELL_BOUNDARY_EPSILON:
		return Vector3i(-1, -1, -1)
	# The positive face belongs to the final cell, matching the placement sampler.
	return Vector3i(grid.floor()).clamp(Vector3i.ZERO, dimensions - Vector3i.ONE)

func build_cell_indices() -> bool:
	if grid_dims.x <= 0 or grid_dims.y <= 0 or grid_dims.z <= 0 \
			or grid_dims.x > MAX_GRID_AXIS or grid_dims.y > MAX_GRID_AXIS or grid_dims.z > MAX_GRID_AXIS:
		cell_indices.clear()
		return false
	cell_indices.resize(grid_dims.x * grid_dims.y * grid_dims.z * CELL_CAPACITY)
	cell_indices.fill(-1)
	var cell_counts := PackedByteArray()
	cell_counts.resize(grid_dims.x * grid_dims.y * grid_dims.z)
	cell_counts.fill(0)
	for i in probe_count():
		var surface := positions[i] - normals[i] * surface_offset
		var grid := world_to_grid * surface
		if not grid.is_finite():
			cell_indices.clear()
			return false
		var cell_coord := cell_coordinates(grid, grid_dims)
		if cell_coord.x < 0:
			cell_indices.clear()
			return false
		var cell := cell_coord.x + cell_coord.y * grid_dims.x + cell_coord.z * grid_dims.x * grid_dims.y
		var slot := int(cell_counts[cell])
		if slot >= CELL_CAPACITY:
			cell_indices.clear()
			return false
		cell_indices[cell * CELL_CAPACITY + slot] = i
		cell_counts[cell] = slot + 1
	return true

static func _transform_is_finite(value: Transform3D) -> bool:
	return value.origin.is_finite() \
		and value.basis.x.is_finite() \
		and value.basis.y.is_finite() \
		and value.basis.z.is_finite()

func evaluate(index: int, lighting: PackedFloat32Array) -> Vector3:
	if index < 0 or index >= probe_count() or lighting.size() != 27:
		return Vector3.ZERO
	var result := Vector3.ZERO
	for k in 9:
		for channel in 3:
			result[channel] += transfer[index * 27 + k * 3 + channel] * lighting[k * 3 + channel]
	return result.max(Vector3.ZERO)

## Evaluates the baked geometry response to a unit directional source.
func transport_response(index: int, dir: Vector3) -> Vector3:
	if index < 0 or index >= probe_count():
		return Vector3.ZERO
	var y := sh_basis(dir.normalized())
	var result := Vector3.ZERO
	for k in 9:
		for channel in 3:
			result[channel] += transfer[index * 27 + k * 3 + channel] * y[k]
	return result

func transport_preview_color(index: int) -> Color:
	var value := transport_response(index, Vector3.UP).max(Vector3.ZERO)
	return Color(value.x, value.y, value.z, 1.0)

func make_atlas_image() -> Image:
	return _make_atlas_image(false)

## Builds the runtime lookup atlas with a per-probe/channel positivity filter.
## Serialized transfer remains untouched: only l>=1 is scaled when the SH9
## reconstruction could go negative. The DC term, and therefore response to
## uniform lighting, is preserved exactly. This conservative window reduces
## directional contrast and sharpness while avoiding negative lobes.
func make_runtime_atlas_image() -> Image:
	return _make_atlas_image(true)

## Validates a saved bake once and creates all immutable textures/bytes needed by
## the renderer. The public individual packers retain their own validation.
func make_render_upload() -> Dictionary:
	if not is_valid():
		return {}
	var transfer_image := _pack_atlas_image(true)
	var geometry_image := _pack_geometry_image()
	var index_bytes := _pack_index_bytes()
	var emission_image := make_emission_atlas_image(PackedFloat32Array())
	if transfer_image == null or geometry_image == null or index_bytes.is_empty() \
			or emission_image == null:
		return {}
	return {
		"transfer_image": transfer_image,
		"geometry_image": geometry_image,
		"index_bytes": index_bytes,
		"emission_image": emission_image
	}

## Packs already-composed per-probe RGB emission into one RGBAF texel per probe.
## An empty payload is an all-zero atlas, which also covers legacy v2 resources.
func make_emission_atlas_image(payload: PackedFloat32Array) -> Image:
	if probe_count() <= 0:
		return null
	var expected := probe_count() * 3
	if not payload.is_empty() and payload.size() != expected:
		return null
	for value in payload:
		if not is_finite(value) or value < 0.0:
			return null
	var image := Image.create_empty(ATLAS_COLUMNS,
			ceili(float(probe_count()) / ATLAS_COLUMNS), false, Image.FORMAT_RGBAF)
	for p in probe_count():
		var color := Color(0.0, 0.0, 0.0, 0.0)
		if not payload.is_empty():
			color.r = payload[p * 3]
			color.g = payload[p * 3 + 1]
			color.b = payload[p * 3 + 2]
		image.set_pixel(p % ATLAS_COLUMNS, p / ATLAS_COLUMNS, color)
	return image

## Composes dynamic source weights with the immutable per-emitter transport.
## The returned RGB values are outgoing indirect radiance before receiver albedo.
func compose_emission(source_values: PackedFloat32Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(probe_count() * 3)
	result.fill(0.0)
	if source_values.size() != emitter_count() * 6 \
			or emitter_transport.size() != probe_count() * emitter_count() * 6:
		return result
	for value in source_values:
		if not is_finite(value) or value < 0.0:
			return result
	for emitter in emitter_count():
		for probe in probe_count():
			var transport_base := (emitter * probe_count() + probe) * 6
			var output_base := probe * 3
			var source_base := emitter * 6
			for channel in 3:
				result[output_base + channel] += emitter_transport[transport_base + channel] \
						* source_values[source_base + channel] \
						+ emitter_transport[transport_base + 3 + channel] \
						* source_values[source_base + 3 + channel]
	for value in result:
		if not is_finite(value) or value < 0.0:
			result.fill(0.0)
			return result
	return result

func _make_atlas_image(regularize_transport: bool) -> Image:
	if not is_valid():
		return null
	return _pack_atlas_image(regularize_transport)

func _pack_atlas_image(regularize_transport: bool) -> Image:
	var image := Image.create_empty(ATLAS_COLUMNS * TRANSFER_TEXELS_PER_POINT,
			ceili(float(probe_count()) / ATLAS_COLUMNS), false, Image.FORMAT_RGBAF)
	for p in probe_count():
		var x0 := (p % ATLAS_COLUMNS) * TRANSFER_TEXELS_PER_POINT
		var y := p / ATLAS_COLUMNS
		var high_band_scale := _runtime_high_band_scale(p) if regularize_transport else Vector3.ONE
		for t in TRANSFER_TEXELS_PER_POINT:
			var texel := Color(0.0, 0.0, 0.0, 0.0)
			for channel in 4:
				var coefficient := t * 4 + channel
				if coefficient < 27:
					var value := transfer[p * 27 + coefficient]
					if regularize_transport and coefficient >= 3:
						value *= high_band_scale[coefficient % 3]
					texel[channel] = value
			image.set_pixel(x0 + t, y, texel)
	return image

func _runtime_high_band_scale(probe: int) -> Vector3:
	var scale := Vector3.ZERO
	var base := probe * 27
	for channel in 3:
		var dc := SH_Y00 * transfer[base + channel]
		var l1_squared := 0.0
		for coefficient in range(1, 4):
			var value := transfer[base + coefficient * 3 + channel]
			l1_squared += value * value
		var l2_squared := 0.0
		for coefficient in range(4, 9):
			var value := transfer[base + coefficient * 3 + channel]
			l2_squared += value * value
		# By the spherical-harmonic addition theorem, these constants bound
		# |sum(l=1) T_k Y_k(n)| and |sum(l=2) T_k Y_k(n)| for every unit n.
		# Scaling all higher bands by dc/(A1+A2) therefore keeps dc + higher >= 0.
		var anisotropy_bound := SH_L1_ABSOLUTE_BOUND * sqrt(l1_squared) \
				+ SH_L2_ABSOLUTE_BOUND * sqrt(l2_squared)
		if dc > 0.0:
			# A tiny relative margin absorbs f32 atlas rounding. If dc is zero,
			# suppress higher bands too rather than inventing a constant floor.
			scale[channel] = 1.0 if anisotropy_bound <= 0.0 else clampf(
				dc * (1.0 - RUNTIME_ATLAS_FILTER_EPSILON) / anisotropy_bound, 0.0, 1.0)
	return scale

func make_geometry_image() -> Image:
	if not is_valid():
		return null
	return _pack_geometry_image()

func _pack_geometry_image() -> Image:
	var image := Image.create_empty(ATLAS_COLUMNS * GEOMETRY_TEXELS_PER_POINT,
			ceili(float(probe_count()) / ATLAS_COLUMNS), false, Image.FORMAT_RGBAF)
	for p in probe_count():
		var x := (p % ATLAS_COLUMNS) * GEOMETRY_TEXELS_PER_POINT
		var y := p / ATLAS_COLUMNS
		var surface := positions[p] - normals[p] * surface_offset
		var normal := normals[p]
		image.set_pixel(x, y, Color(surface.x, surface.y, surface.z, 1.0))
		image.set_pixel(x + 1, y, Color(normal.x, normal.y, normal.z, 0.0))
	return image

func make_index_bytes() -> PackedByteArray:
	if not is_valid():
		return PackedByteArray()
	return _pack_index_bytes()

func _pack_index_bytes() -> PackedByteArray:
	return cell_indices.to_byte_array()
