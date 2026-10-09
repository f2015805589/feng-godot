@tool
class_name FFogBakedLightingVolume
extends Resource
## Immutable adapter for Godot LightmapGI capture probes.
##
## Capture points, BSP planes, and bounds remain in the LightmapGI capture space.
## The caller supplies the transform which maps that space into the rendered
## world. This resource copies only probe data; surface lightmap textures are not
## part of volumetric lighting.

const FORMAT_VERSION := 1
const SH_COEFFICIENTS := 9
const RGB_LANES := 3
const SH_COEFFICIENT_DOMAIN := "godot_lightmapper_incident_radiance_real_sh9_scaled_by_1_over_pi"
const BSP_NODE_STRIDE := 6
const EMPTY_BSP_LEAF := -2147483648
const MAX_BSP_STEPS := 1 << 20
const EXPOSURE_EPSILON := 0.000001

@export_storage var format_version := FORMAT_VERSION
@export_storage var bounds := AABB()
@export_storage var capture_transform := Transform3D.IDENTITY
@export_storage var probe_positions := PackedVector3Array()
## Probe-major SH9, RGB coefficient order: probe * 27 + coefficient * 3 + channel.
@export_storage var probe_sh := PackedFloat32Array()
@export_storage var tetrahedra := PackedInt32Array()
## Six int32 lanes per node. Lanes 0..3 contain float bit patterns for plane
## normal.xyz and d; lanes 4..5 contain signed over/under child indices.
@export_storage var bsp_nodes := PackedInt32Array()
@export_storage var baked_exposure := 1.0
@export_storage var source_lightprobe_hash := 0
@export_storage var source_revision := 0
@export_storage var source_interior := false
## Lightmapper probe rays trace the configured bake environment on a miss. Keep
## the conservative `true` default unless this capture was baked with
## LightmapGI environment contribution disabled.
@export var includes_environment_radiance := true:
	set(value):
		if includes_environment_radiance == value:
			return
		includes_environment_radiance = value
		if _suppress_changed_notifications:
			return
		var previous_revision := revision
		revision += 1
		if revision <= 0:
			revision = 1
		if _validated_revision == previous_revision:
			_validated_revision = revision
		source_revision = hash([source_revision, includes_environment_radiance])
		emit_changed()
@export_storage var contains_surface_direct_radiance := true
@export_storage var bake_mode := "lightmapgi_capture_probes"
@export_storage var revision := 0

@export_group("LightmapGI Probe Import")
## Candidate capture resource for the explicit editor refresh button. Changing
## this field does not replace or move the currently imported probe payload.
@export var source_lightmap_gi_data: LightmapGIData
## Candidate transform from LightmapGI capture-local coordinates to world.
## It is applied only after a successful import.
@export var source_capture_transform := Transform3D.IDENTITY
@export_tool_button("Import / Refresh LightmapGI Probes") var refresh_import_action: Callable = _on_refresh_import_pressed

var _validated_revision := -1
var _cached_valid := false
var _suppress_changed_notifications := false


## Import the selected LightmapGIData candidate atomically. The serialized v1
## payload remains active if the candidate is missing or fails validation.
func refresh_from_selected_source() -> Dictionary:
	return _stage_and_import_data(source_lightmap_gi_data, source_capture_transform)


## Import from a scene node without scanning the SceneTree. LightmapGI capture
## probes and bounds are node-local, so its global transform maps them to world.
func capture_lightmap_gi_node(p_lightmap_gi: LightmapGI) -> Dictionary:
	if p_lightmap_gi == null:
		return _import_failure("No LightmapGI node was supplied.")
	if not p_lightmap_gi.is_inside_tree():
		return _import_failure("The LightmapGI node must be inside a scene tree to read global_transform.")
	var data: LightmapGIData = p_lightmap_gi.get_light_data()
	if data == null:
		return _import_failure("The LightmapGI node has no baked LightmapGIData.")
	var node_transform := p_lightmap_gi.global_transform
	var result := _stage_and_import_data(data, node_transform)
	if bool(result.get("valid", false)):
		source_lightmap_gi_data = data
		source_capture_transform = node_transform
	return result


func _on_refresh_import_pressed() -> void:
	var result := refresh_from_selected_source()
	if not bool(result.get("valid", false)):
		push_warning("Baked volumetric lighting import failed: %s" % result.get("reason", "unknown validation error"))


func _stage_and_import_data(p_data: LightmapGIData, p_capture_transform: Transform3D) -> Dictionary:
	if p_data == null:
		return _import_failure("Select a baked LightmapGIData resource first.")
	if not p_capture_transform.is_finite() \
			or absf(p_capture_transform.basis.determinant()) <= 0.00000001:
		return _import_failure("The staged capture transform is non-finite or singular.")
	var capture_data: Variant = p_data.get("probe_data")
	if not capture_data is Dictionary or capture_data.is_empty():
		return _import_failure("LightmapGIData has no serialized probe_data capture. Bake LightmapGI probes first.")
	return _stage_and_import_capture_data(capture_data, p_capture_transform)


func _stage_and_import_capture_data(p_capture_data: Dictionary,
		p_capture_transform: Transform3D) -> Dictionary:
	if not p_capture_transform.is_finite() \
			or absf(p_capture_transform.basis.determinant()) <= 0.00000001:
		return _import_failure("The staged capture transform is non-finite or singular.")
	if p_capture_data.is_empty():
		return _import_failure("The staged capture dictionary is empty.")
	var candidate = get_script().new()
	candidate.includes_environment_radiance = includes_environment_radiance
	if not candidate.capture_probe_data(p_capture_data, p_capture_transform):
		return _import_failure("LightmapGI probe points, SH, tetrahedra, BSP, bounds, or baked exposure failed validation.")
	var changed := not _active_payload_equals(candidate)
	if changed:
		_copy_active_payload_from(candidate)
	return {"valid": true, "changed": changed, "reason": ""}


func _active_payload_equals(p_candidate: Resource) -> bool:
	return format_version == int(p_candidate.get("format_version")) \
			and bounds == p_candidate.get("bounds") \
			and capture_transform == p_candidate.get("capture_transform") \
			and probe_positions == p_candidate.get("probe_positions") \
			and probe_sh == p_candidate.get("probe_sh") \
			and tetrahedra == p_candidate.get("tetrahedra") \
			and bsp_nodes == p_candidate.get("bsp_nodes") \
			and is_equal_approx(baked_exposure, float(p_candidate.get("baked_exposure"))) \
			and source_lightprobe_hash == int(p_candidate.get("source_lightprobe_hash")) \
			and source_revision == int(p_candidate.get("source_revision")) \
			and source_interior == bool(p_candidate.get("source_interior")) \
			and includes_environment_radiance == bool(p_candidate.get("includes_environment_radiance")) \
			and contains_surface_direct_radiance == bool(p_candidate.get("contains_surface_direct_radiance")) \
			and bake_mode == String(p_candidate.get("bake_mode"))


func _copy_active_payload_from(p_candidate: Resource) -> void:
	_suppress_changed_notifications = true
	format_version = int(p_candidate.get("format_version"))
	bounds = p_candidate.get("bounds")
	capture_transform = p_candidate.get("capture_transform")
	probe_positions = p_candidate.get("probe_positions")
	probe_sh = p_candidate.get("probe_sh")
	tetrahedra = p_candidate.get("tetrahedra")
	bsp_nodes = p_candidate.get("bsp_nodes")
	baked_exposure = float(p_candidate.get("baked_exposure"))
	source_lightprobe_hash = int(p_candidate.get("source_lightprobe_hash"))
	source_revision = int(p_candidate.get("source_revision"))
	source_interior = bool(p_candidate.get("source_interior"))
	includes_environment_radiance = bool(p_candidate.get("includes_environment_radiance"))
	contains_surface_direct_radiance = bool(p_candidate.get("contains_surface_direct_radiance"))
	bake_mode = String(p_candidate.get("bake_mode"))
	revision += 1
	if revision <= 0:
		revision = 1
	_suppress_changed_notifications = false
	_validated_revision = -1
	_cached_valid = false
	resource_name = "Fog Baked Probes (%d)" % probe_positions.size()
	# Resource.set_name() emits `changed`; do not emit a second notification.


func _import_failure(p_reason: String) -> Dictionary:
	return {"valid": false, "changed": false, "reason": p_reason}


func capture_lightmap_gi_data(p_data: LightmapGIData, p_capture_transform: Transform3D) -> bool:
	if p_data == null or not p_capture_transform.is_finite() \
			or absf(p_capture_transform.basis.determinant()) <= 0.00000001:
		clear()
		return false
	var capture_data: Dictionary = p_data.get("probe_data")
	return capture_probe_data(capture_data, p_capture_transform)


## Imports the stable `LightmapGIData.probe_data` dictionary schema. This is
## separately callable for CPU fixtures and serialized probe adapters.
func capture_probe_data(p_capture_data: Dictionary, p_capture_transform: Transform3D) -> bool:
	if not p_capture_transform.is_finite() \
			or absf(p_capture_transform.basis.determinant()) <= 0.00000001:
		clear()
		return false
	var capture_data := p_capture_data
	if capture_data.is_empty():
		clear()
		return false
	var next_points: PackedVector3Array = capture_data.get("points", PackedVector3Array())
	var next_colors: PackedColorArray = capture_data.get("sh", PackedColorArray())
	var next_tetrahedra: PackedInt32Array = capture_data.get("tetrahedra", PackedInt32Array())
	var next_bsp: PackedInt32Array = capture_data.get("bsp", PackedInt32Array())
	var next_bounds: AABB = capture_data.get("bounds", AABB())
	var next_exposure := float(capture_data.get("baked_exposure", 1.0))
	var next_includes_environment := bool(capture_data.get(
			"includes_environment_radiance", includes_environment_radiance))
	if next_points.is_empty() or next_colors.size() != next_points.size() * SH_COEFFICIENTS \
			or next_tetrahedra.is_empty() or next_tetrahedra.size() % 4 != 0 \
			or next_bsp.is_empty() or next_bsp.size() % BSP_NODE_STRIDE != 0 \
		or not next_bounds.has_volume() or not is_finite(next_exposure) \
			or next_exposure <= EXPOSURE_EPSILON:
		clear()
		return false
	var next_sh := PackedFloat32Array()
	next_sh.resize(next_points.size() * SH_COEFFICIENTS * RGB_LANES)
	for probe_index in next_points.size():
		if not next_points[probe_index].is_finite():
			clear()
			return false
		for coefficient in SH_COEFFICIENTS:
			var color: Color = next_colors[probe_index * SH_COEFFICIENTS + coefficient]
			if not _color_is_finite(color):
				clear()
				return false
			var base := (probe_index * SH_COEFFICIENTS + coefficient) * RGB_LANES
			next_sh[base] = color.r
			next_sh[base + 1] = color.g
			next_sh[base + 2] = color.b
	for index in next_tetrahedra:
		if index < 0 or index >= next_points.size():
			clear()
			return false
	if not _validate_bsp(next_bsp, next_tetrahedra.size() / 4):
		clear()
		return false
	bounds = next_bounds
	capture_transform = p_capture_transform
	probe_positions = next_points
	probe_sh = next_sh
	tetrahedra = next_tetrahedra
	bsp_nodes = next_bsp
	baked_exposure = next_exposure
	source_lightprobe_hash = int(capture_data.get("lightprobe_hash", 0))
	includes_environment_radiance = next_includes_environment
	source_revision = hash([next_bounds, next_points, next_colors, next_tetrahedra,
		next_bsp, next_exposure, includes_environment_radiance])
	source_interior = bool(capture_data.get("interior", false))
	format_version = FORMAT_VERSION
	revision += 1
	if revision <= 0:
		revision = 1
	_validated_revision = -1
	resource_name = "Fog Baked Probes (%d)" % probe_positions.size()
	emit_changed()
	return true


func clear() -> void:
	bounds = AABB()
	capture_transform = Transform3D.IDENTITY
	probe_positions = PackedVector3Array()
	probe_sh = PackedFloat32Array()
	tetrahedra = PackedInt32Array()
	bsp_nodes = PackedInt32Array()
	baked_exposure = 1.0
	source_lightprobe_hash = 0
	source_revision = 0
	source_interior = false
	includes_environment_radiance = true
	contains_surface_direct_radiance = true
	bake_mode = "lightmapgi_capture_probes"
	revision += 1
	if revision <= 0:
		revision = 1
	_validated_revision = revision
	_cached_valid = false
	emit_changed()


func is_valid() -> bool:
	if _validated_revision == revision:
		return _cached_valid
	_cached_valid = _compute_validity()
	_validated_revision = revision
	return _cached_valid


func _compute_validity() -> bool:
	if format_version != FORMAT_VERSION or probe_positions.is_empty() \
			or probe_sh.size() != probe_positions.size() * SH_COEFFICIENTS * RGB_LANES \
			or tetrahedra.is_empty() or tetrahedra.size() % 4 != 0 \
			or bsp_nodes.is_empty() or bsp_nodes.size() % BSP_NODE_STRIDE != 0 \
			or not bounds.has_volume() or not capture_transform.is_finite() \
			or absf(capture_transform.basis.determinant()) <= 0.00000001 \
			or not is_finite(baked_exposure) \
			or baked_exposure <= EXPOSURE_EPSILON:
		return false
	for point in probe_positions:
		if not point.is_finite():
			return false
	for value in probe_sh:
		if not is_finite(value):
			return false
	for index in tetrahedra:
		if index < 0 or index >= probe_positions.size():
			return false
	return _validate_bsp(bsp_nodes, tetrahedra.size() / 4)


func get_gpu_payload() -> Dictionary:
	if not is_valid():
		return {}
	return {
		"format_version": FORMAT_VERSION,
		"bounds": bounds,
		"capture_transform": capture_transform,
		"world_to_capture": capture_transform.affine_inverse(),
		"world_bounds": capture_transform * bounds,
		"world_direction_to_capture": capture_transform.basis.orthonormalized().transposed(),
		"capture_scale": capture_transform.basis.get_scale(),
		"directions_use_orthonormalized_basis": true,
		"coordinate_space": "lightmap_capture",
		"probe_positions": probe_positions,
		"probe_sh": probe_sh,
		"coefficient_domain": SH_COEFFICIENT_DOMAIN,
		"coefficient_to_physical_radiance_scale": PI,
		"phase_convolution": "multiply SH band l by g^l then PI; no cosine convolution",
		"tetrahedra": tetrahedra,
		"bsp_nodes": bsp_nodes,
		"baked_exposure": baked_exposure,
		"source_lightprobe_hash": source_lightprobe_hash,
		"source_revision": source_revision,
		"source_interior": source_interior,
		"includes_environment_radiance": includes_environment_radiance,
		"contains_surface_direct_radiance": contains_surface_direct_radiance,
		"includes_probe_origin_direct_lighting": false,
		"baked_direct_semantics": "Lightmapper probe rays evaluate direct lights at hit surfaces; no direct-at-probe term",
		"suppresses_live_direct_lighting": false,
		"bake_mode": bake_mode,
		"revision": revision,
	}


## Resolves the competing environment sources for one froxel. A valid probe
## sample replaces the live sky only when the bake includes environment
## radiance and static volumetric scattering is enabled. Live direct lights
## are always kept because this LightmapGI probe data has no direct-at-probe
## term.
static func resolve_source_usage(p_sample_valid: bool, p_includes_environment_radiance: bool,
		p_static_lighting_scattering_intensity: float) -> Dictionary:
	var intensity := p_static_lighting_scattering_intensity \
			if is_finite(p_static_lighting_scattering_intensity) else 0.0
	var use_baked_probe := p_sample_valid and intensity > 0.0
	var suppress_live_sky := use_baked_probe and p_includes_environment_radiance
	return {
		"apply_baked_probe_radiance": use_baked_probe,
		"suppress_live_sky": suppress_live_sky,
		"apply_live_sky": not suppress_live_sky,
		"apply_live_direct_lights": true,
		"source_includes_environment_radiance": p_includes_environment_radiance,
		"static_lighting_scattering_intensity": maxf(intensity, 0.0),
	}


## Evaluates incident-radiance SH convolved with a normalized Henyey-Greenstein
## phase function. p_capture_direction uses the same direction convention as
## LightmapperRD's sampled ray_dir; the caller maps its scattering axis to it.
func evaluate_hg_incident_radiance(p_coefficients: PackedFloat32Array,
		p_capture_direction: Vector3, p_g: float) -> Vector3:
	return _evaluate_hg_incident_radiance_max_band(p_coefficients,
			p_capture_direction, p_g, 2)


## Mirrors UE's VolumetricFog `GetVolumetricLightmapSH2` path, which uses only
## the L0/L1 coefficients. Generic callers can retain the full SH9 evaluation.
func evaluate_hg_incident_radiance_ue_two_band(p_coefficients: PackedFloat32Array,
		p_capture_direction: Vector3, p_g: float) -> Vector3:
	return _evaluate_hg_incident_radiance_max_band(p_coefficients,
			p_capture_direction, p_g, 1)


func _evaluate_hg_incident_radiance_max_band(p_coefficients: PackedFloat32Array,
		p_capture_direction: Vector3, p_g: float, p_max_band: int) -> Vector3:
	if p_coefficients.size() != SH_COEFFICIENTS * RGB_LANES \
			or not p_capture_direction.is_finite() or p_capture_direction.length_squared() <= 0.00000001 \
			or not is_finite(p_g):
		return Vector3.ZERO
	var direction := p_capture_direction.normalized()
	var x := direction.x
	var y := direction.y
	var z := direction.z
	var basis := PackedFloat32Array([
		0.282095,
		0.488603 * y,
		0.488603 * z,
		0.488603 * x,
		1.092548 * x * y,
		1.092548 * y * z,
		0.315392 * (3.0 * z * z - 1.0),
		1.092548 * x * z,
		0.546274 * (x * x - y * y),
	])
	var anisotropy := clampf(p_g, -0.999, 0.999)
	var result := Vector3.ZERO
	var max_band := clampi(p_max_band, 0, 2)
	for coefficient in SH_COEFFICIENTS:
		var band := 0 if coefficient == 0 else 1 if coefficient <= 3 else 2
		if band > max_band:
			continue
		var band_weight := 1.0 if band == 0 else anisotropy if band == 1 else anisotropy * anisotropy
		var scale := basis[coefficient] * band_weight
		var offset := coefficient * RGB_LANES
		result.x += p_coefficients[offset] * scale
		result.y += p_coefficients[offset + 1] * scale
		result.z += p_coefficients[offset + 2] * scale
	return result * PI


## CPU reference for the same BSP leaf selection and tetrahedral SH interpolation
## used by the native LightmapGI probe sampler.
func sample_sh9(p_world_position: Vector3) -> PackedFloat32Array:
	return sample_sh9_with_validity(p_world_position).get("coefficients", PackedFloat32Array())


func sample_sh9_with_validity(p_world_position: Vector3) -> Dictionary:
	var result := PackedFloat32Array()
	result.resize(SH_COEFFICIENTS * RGB_LANES)
	result.fill(0.0)
	if not is_valid() or not p_world_position.is_finite():
		return {"valid": false, "coefficients": result}
	var capture_position := capture_transform.affine_inverse() * p_world_position
	if not bounds.has_point(capture_position):
		return {"valid": false, "coefficients": result}
	var node := 0
	var steps := 0
	var node_count := bsp_nodes.size() / BSP_NODE_STRIDE
	while node >= 0:
		if node >= node_count or steps >= node_count or steps >= MAX_BSP_STEPS:
			return {"valid": false, "coefficients": result}
		var offset := node * BSP_NODE_STRIDE
		var plane_normal := Vector3(
			_int_bits_to_float(bsp_nodes[offset]),
			_int_bits_to_float(bsp_nodes[offset + 1]),
			_int_bits_to_float(bsp_nodes[offset + 2]))
		var plane_d := _int_bits_to_float(bsp_nodes[offset + 3])
		if not plane_normal.is_finite() or not is_finite(plane_d):
			return {"valid": false, "coefficients": result}
		node = bsp_nodes[offset + 4] if plane_normal.dot(capture_position) > plane_d else bsp_nodes[offset + 5]
		steps += 1
	if node == EMPTY_BSP_LEAF:
		return {"valid": false, "coefficients": result}
	var tetrahedron_index := -node - 1
	if tetrahedron_index < 0 or tetrahedron_index >= tetrahedra.size() / 4:
		return {"valid": false, "coefficients": result}
	var tetra_offset := tetrahedron_index * 4
	var a := probe_positions[tetrahedra[tetra_offset]]
	var b := probe_positions[tetrahedra[tetra_offset + 1]]
	var c := probe_positions[tetrahedra[tetra_offset + 2]]
	var d := probe_positions[tetrahedra[tetra_offset + 3]]
	var barycentric := _tetrahedron_barycentric(a, b, c, d, capture_position)
	if not _color_is_finite(barycentric):
		return {"valid": false, "coefficients": result}
	for corner in 4:
		var weight := clampf(barycentric[corner], 0.0, 1.0)
		var probe_index := tetrahedra[tetra_offset + corner]
		for coefficient in SH_COEFFICIENTS:
			var base := (probe_index * SH_COEFFICIENTS + coefficient) * RGB_LANES
			var result_base := coefficient * RGB_LANES
			for channel in RGB_LANES:
				result[result_base + channel] += probe_sh[base + channel] * weight
	return {"valid": true, "coefficients": result}


func _validate_bsp(p_nodes: PackedInt32Array, p_tetrahedron_count: int) -> bool:
	if p_nodes.is_empty() or p_nodes.size() % BSP_NODE_STRIDE != 0 or p_tetrahedron_count <= 0:
		return false
	var node_count := p_nodes.size() / BSP_NODE_STRIDE
	for node_index in node_count:
		var base := node_index * BSP_NODE_STRIDE
		for lane in 4:
			if not is_finite(_int_bits_to_float(p_nodes[base + lane])):
				return false
		for child_offset in [4, 5]:
			var child := p_nodes[base + child_offset]
			if child >= node_count or (child < 0 and child != EMPTY_BSP_LEAF \
					and -child - 1 >= p_tetrahedron_count):
				return false
	return true


func _int_bits_to_float(p_bits: int) -> float:
	var bytes := PackedInt32Array([p_bits]).to_byte_array()
	return bytes.decode_float(0)


func _color_is_finite(p_color: Color) -> bool:
	return is_finite(p_color.r) and is_finite(p_color.g) \
			and is_finite(p_color.b) and is_finite(p_color.a)


func _tetrahedron_barycentric(a: Vector3, b: Vector3, c: Vector3,
		d: Vector3, p: Vector3) -> Color:
	var vap := p - a
	var vbp := p - b
	var vab := b - a
	var vac := c - a
	var vad := d - a
	var vbc := c - b
	var vbd := d - b
	var determinant := vab.dot(vac.cross(vad))
	if absf(determinant) <= 0.00000001:
		return Color(-1.0, -1.0, -1.0, -1.0)
	return Color(
		vbp.dot(vbd.cross(vbc)) / determinant,
		vap.dot(vac.cross(vad)) / determinant,
		vap.dot(vad.cross(vab)) / determinant,
		vap.dot(vab.cross(vac)) / determinant)
