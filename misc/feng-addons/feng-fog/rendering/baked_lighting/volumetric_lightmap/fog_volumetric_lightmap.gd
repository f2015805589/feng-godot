@tool
class_name FFogVolumetricLightmap
extends Resource
## Offline-decoded UE-style adaptive volumetric-lightmap payload.
##
## All active bounds and transforms use meters. `capture_transform` maps the
## meter-space capture coordinates into the FRP world. UE centimeter payloads
## are converted at import; axis/handedness conversion remains explicit in the
## supplied transform and is never guessed by this resource.

const FORMAT_VERSION := 1
const DEFAULT_BRICK_SIZE := 4
const PI := 3.14159265358979323846
const SH2_L1_SCALE := 0.488603 / 0.282095
const SH2_L1_XY_SCALE := 1.092548 / 0.282095
const FLAG_VALID := 1
const FLAG_INCLUDES_ENVIRONMENT_RADIANCE := 2
const FLAG_CONTAINS_STATIC_DIRECT_DIRECTIONAL_LIGHTING := 4
const FLAG_HAS_DIRECTIONAL_SHADOW := 8
const FLAG_STATIC_LIGHT_KEY_MATCH := 16
const FLAG_HAS_SKY_BENT_NORMAL := 32
const MAX_ATLAS_VOXELS := 1 << 28
const ProbeConverter = preload("fog_volumetric_lightmap_probe_converter.gd")

@export_group("Decoded Source")
@export_file("*.json", "*.bin") var decoded_payload_path := ""
@export var source_description := ""
@export var source_lightmap_gi_probe_volume: Resource
@export var probe_indirection_dimensions := Vector3i.ONE
@export_range(1, 32, 1) var probe_brick_size := DEFAULT_BRICK_SIZE
@export_tool_button("Import decoded VLM payload") var import_payload_action: Callable = import_payload_from_path
@export_tool_button("Resample LightmapGI probes to VLM") var resample_probe_action: Callable = resample_lightmapgi_probes
@export var last_import_status := ""

@export_group("Active Capture")
@export_storage var format_version := FORMAT_VERSION
@export var capture_transform := Transform3D.IDENTITY:
	set(value):
		if capture_transform == value:
			return
		capture_transform = value
		if not _applying_payload:
			_touch_payload_revision()
@export var bounds_local := AABB():
	set(value):
		if bounds_local == value:
			return
		bounds_local = value
		if not _applying_payload:
			_touch_payload_revision()
@export_range(1, 64, 1) var brick_size := DEFAULT_BRICK_SIZE:
	set(value):
		var normalized := clampi(value, 1, 64)
		if brick_size == normalized:
			return
		brick_size = normalized
		if not _applying_payload:
			_touch_payload_revision()
@export var indirection_dimensions := Vector3i.ZERO:
	set(value):
		if indirection_dimensions == value:
			return
		indirection_dimensions = value
		if not _applying_payload:
			_touch_payload_revision()
@export var brick_atlas_dimensions := Vector3i.ZERO:
	set(value):
		if brick_atlas_dimensions == value:
			return
		brick_atlas_dimensions = value
		if not _applying_payload:
			_touch_payload_revision()
@export_storage var indirection_rgba8_uint := PackedByteArray()
@export_storage var ambient_rgba16f := PackedByteArray()
## Six RGBA8_UNORM coefficient textures, in UE order 0..5.
@export_storage var sh_coefficients_rgba8_unorm: Array[PackedByteArray] = []
@export_storage var sky_bent_normal_rgba8_unorm := PackedByteArray()
@export_storage var directional_shadow_r8_unorm := PackedByteArray()
@export_group("Baked Source Metadata")
@export_range(0.000001, 1000000.0, 0.001, "or_greater") var baked_exposure := 1.0:
	set(value):
		if not is_finite(value) or value <= 0.000001 or is_equal_approx(baked_exposure, value):
			return
		baked_exposure = value
		if not _applying_payload:
			_touch_payload_revision()
@export var includes_environment_radiance := false:
	set(value):
		if includes_environment_radiance == value:
			return
		includes_environment_radiance = value
		if not _applying_payload:
			_touch_payload_revision()
@export var contains_static_direct_directional_lighting := false:
	set(value):
		if contains_static_direct_directional_lighting == value:
			return
		contains_static_direct_directional_lighting = value
		if not _applying_payload:
			_touch_payload_revision()
@export var has_sky_bent_normal := false:
	set(value):
		if has_sky_bent_normal == value:
			return
		has_sky_bent_normal = value
		if not _applying_payload:
			_touch_payload_revision()
@export var has_directional_shadowing := false:
	set(value):
		if has_directional_shadowing == value:
			return
		has_directional_shadowing = value
		if not _applying_payload:
			_touch_payload_revision()
## Exact stable key of the primary Sun represented by static directional data.
## Empty means that a consumer must not apply/suppress any live Sun.
@export var static_directional_light_key: StringName = &"":
	set(value):
		if static_directional_light_key == value:
			return
		static_directional_light_key = value
		if not _applying_payload:
			_touch_payload_revision()
@export_storage var coefficient_domain := "ue_vlm_ambient_and_normalized_sh_v1"
@export_storage var source_revision := 0
@export_storage var revision := 0

var _applying_payload := false
var _validated_revision := -1
var _cached_valid := false
var _snapshot_revision := -1
var _snapshot_cache: Dictionary = {}


## Import a decoded v1 dictionary atomically. For `coordinate_units="ue_cm"`,
## only the local bounds are scaled by 0.01; the supplied transform is already
## defined for meter-space coordinates and performs any axis conversion.
func import_decoded_payload(p_payload: Dictionary) -> Dictionary:
	var decoded := _decode_candidate(p_payload)
	if not bool(decoded.get("valid", false)):
		return {"valid": false, "changed": false, "reason": str(decoded.get("reason", "Invalid payload."))}
	var candidate: Dictionary = decoded["payload"]
	if _active_payload_equals(candidate):
		return {"valid": true, "changed": false, "reason": ""}
	_applying_payload = true
	format_version = FORMAT_VERSION
	capture_transform = candidate["capture_transform"]
	bounds_local = candidate["bounds_local"]
	brick_size = int(candidate["brick_size"])
	indirection_dimensions = candidate["indirection_dimensions"]
	brick_atlas_dimensions = candidate["brick_atlas_dimensions"]
	indirection_rgba8_uint = candidate["indirection_rgba8_uint"]
	ambient_rgba16f = candidate["ambient_rgba16f"]
	sh_coefficients_rgba8_unorm = candidate["sh_coefficients_rgba8_unorm"]
	sky_bent_normal_rgba8_unorm = candidate["sky_bent_normal_rgba8_unorm"]
	directional_shadow_r8_unorm = candidate["directional_shadow_r8_unorm"]
	baked_exposure = float(candidate["baked_exposure"])
	includes_environment_radiance = bool(candidate["includes_environment_radiance"])
	contains_static_direct_directional_lighting = bool(candidate["contains_static_direct_directional_lighting"])
	has_sky_bent_normal = bool(candidate["has_sky_bent_normal"])
	has_directional_shadowing = bool(candidate["has_directional_shadowing"])
	static_directional_light_key = StringName(candidate["static_directional_light_key"])
	coefficient_domain = String(candidate["coefficient_domain"])
	source_revision = int(candidate["source_revision"])
	_applying_payload = false
	revision += 1
	if revision <= 0:
		revision = 1
	_validated_revision = revision
	_cached_valid = true
	_snapshot_revision = -1
	_snapshot_cache.clear()
	var next_resource_name := "Fog Volumetric Lightmap (%s)" % str(indirection_dimensions)
	if resource_name == next_resource_name:
		emit_changed()
	else:
		# Resource.set_name() emits changed itself. Do not emit a second signal
		# after changing the visible authoring label.
		resource_name = next_resource_name
	return {"valid": true, "changed": true, "reason": ""}


func import_payload_from_path() -> Dictionary:
	if decoded_payload_path.is_empty():
		last_import_status = "Choose a decoded JSON or binary Variant payload file first."
		return {"valid": false, "changed": false, "reason": last_import_status}
	var result := import_decoded_payload_file(decoded_payload_path)
	if bool(result.get("valid", false)):
		if source_description.is_empty():
			source_description = decoded_payload_path.get_file()
		last_import_status = "Imported %s" % decoded_payload_path.get_file()
	else:
		last_import_status = str(result.get("reason", "Decoded payload import failed."))
	return result


func resample_lightmapgi_probes() -> Dictionary:
	if source_lightmap_gi_probe_volume == null or not is_instance_valid(source_lightmap_gi_probe_volume):
		last_import_status = "Assign an FFogBakedLightingVolume probe adapter first."
		return {"valid": false, "changed": false, "reason": last_import_status}
	var converted := ProbeConverter.build_payload(source_lightmap_gi_probe_volume,
		probe_indirection_dimensions, probe_brick_size)
	if not bool(converted.get("valid", false)):
		last_import_status = str(converted.get("reason", "Probe resampling failed."))
		return converted
	var import_result := import_decoded_payload(converted["payload"])
	if not bool(import_result.get("valid", false)):
		last_import_status = str(import_result.get("reason", "Converted payload import failed."))
		return import_result
	if source_description.is_empty():
		source_description = "LightmapGI tetra probe resample"
	last_import_status = "Resampled LightmapGI probes into an approximate uniform-brick VLM payload."
	converted["changed"] = bool(import_result.get("changed", false))
	return converted


## Import a decoded JSON payload or a binary Variant Dictionary. JSON uses
## base64 strings for texture bytes and explicit arrays for transforms/vectors.
## This is not an Unreal package or `.uasset` reader.
func import_decoded_payload_file(p_path: String) -> Dictionary:
	if p_path.is_empty() or not FileAccess.file_exists(p_path):
		return {"valid": false, "changed": false, "reason": "Decoded payload file does not exist."}
	var file := FileAccess.open(p_path, FileAccess.READ)
	if file == null:
		return {"valid": false, "changed": false, "reason": "Decoded payload file could not be opened."}
	var decoded: Variant
	if p_path.get_extension().to_lower() == "json":
		var parser := JSON.new()
		var parse_error := parser.parse(file.get_as_text())
		if parse_error != OK:
			return {"valid": false, "changed": false, "reason": "JSON parse error at line %d: %s" % [parser.get_error_line(), parser.get_error_message()]}
		if not parser.data is Dictionary:
			return {"valid": false, "changed": false, "reason": "Decoded JSON root must be a Dictionary."}
		var normalized := _coerce_json_payload(parser.data)
		if not bool(normalized.get("valid", false)):
			return {"valid": false, "changed": false, "reason": str(normalized.get("reason", "Invalid JSON payload."))}
		decoded = normalized["payload"]
	else:
		decoded = file.get_var(false)
	if not decoded is Dictionary:
		return {"valid": false, "changed": false, "reason": "Decoded binary Variant root must be a Dictionary."}
	return import_decoded_payload(decoded)


static func _coerce_json_payload(p_json: Dictionary) -> Dictionary:
	var payload := p_json.duplicate()
	var transform_data: Variant = p_json.get("capture_transform", null)
	if not transform_data is Dictionary:
		return _failure("JSON capture_transform must contain basis_columns and origin arrays.")
	var basis_columns: Variant = transform_data.get("basis_columns", null)
	if not basis_columns is Array or basis_columns.size() != 3:
		return _failure("JSON capture_transform.basis_columns must contain exactly three column vectors.")
	var basis_values: Array[Vector3] = []
	for column in basis_columns:
		var vector: Variant = _json_vector3(column)
		if not vector is Vector3:
			return _failure("JSON transform basis columns must contain three finite numbers each.")
		basis_values.append(vector)
	var origin: Variant = _json_vector3(transform_data.get("origin", null))
	if not origin is Vector3:
		return _failure("JSON transform origin must contain three finite numbers.")
	payload["capture_transform"] = Transform3D(Basis(basis_values[0], basis_values[1], basis_values[2]), origin)

	var bounds_data: Variant = p_json.get("bounds_local", null)
	if not bounds_data is Dictionary:
		return _failure("JSON bounds_local must contain position and size arrays.")
	var bounds_position: Variant = _json_vector3(bounds_data.get("position", null))
	var bounds_size: Variant = _json_vector3(bounds_data.get("size", null))
	if not bounds_position is Vector3 or not bounds_size is Vector3:
		return _failure("JSON bounds position and size must contain three finite numbers each.")
	payload["bounds_local"] = AABB(bounds_position, bounds_size)

	for field in ["indirection_dimensions", "brick_atlas_dimensions"]:
		var dimensions: Variant = _json_vector3(p_json.get(field, null), true)
		if not dimensions is Vector3i:
			return _failure("JSON %s must contain three positive integer dimensions." % field)
		payload[field] = dimensions

	for field in ["indirection_rgba8_uint", "ambient_rgba16f", "sky_bent_normal_rgba8_unorm", "directional_shadow_r8_unorm"]:
		var encoded: Variant = p_json.get(field, "")
		var bytes_result := _json_base64_bytes(encoded, field)
		if not bool(bytes_result.get("valid", false)):
			return bytes_result
		payload[field] = bytes_result["bytes"]

	var encoded_layers: Variant = p_json.get("sh_coefficients_rgba8_unorm", null)
	if not encoded_layers is Array or encoded_layers.size() != 6:
		return _failure("JSON sh_coefficients_rgba8_unorm must contain six base64 strings.")
	var layers: Array[PackedByteArray] = []
	for index in encoded_layers.size():
		var layer_result := _json_base64_bytes(encoded_layers[index], "sh_coefficients_rgba8_unorm[%d]" % index)
		if not bool(layer_result.get("valid", false)):
			return layer_result
		layers.append(layer_result["bytes"])
	payload["sh_coefficients_rgba8_unorm"] = layers
	return {"valid": true, "payload": payload}


static func _json_vector3(p_value: Variant, p_integer: bool = false) -> Variant:
	if not p_value is Array or p_value.size() != 3:
		return null
	var values := PackedFloat64Array()
	for component in p_value:
		if not (component is int or component is float) or not is_finite(float(component)):
			return null
		var number := float(component)
		if p_integer and absf(number - roundf(number)) > 0.000001:
			return null
		values.append(number)
	if p_integer:
		return Vector3i(roundi(values[0]), roundi(values[1]), roundi(values[2]))
	return Vector3(values[0], values[1], values[2])


static func _json_base64_bytes(p_value: Variant, p_field: String) -> Dictionary:
	if not p_value is String:
		return _failure("JSON %s must be base64 text." % p_field)
	var encoded := String(p_value)
	var bytes := Marshalls.base64_to_raw(encoded)
	if not encoded.is_empty() and Marshalls.raw_to_base64(bytes) != encoded:
		return _failure("JSON %s is not canonical base64." % p_field)
	return {"valid": true, "bytes": bytes}


func mark_payload_changed() -> void:
	_touch_payload_revision()


func _touch_payload_revision() -> void:
	revision += 1
	if revision <= 0:
		revision = 1
	_validated_revision = -1
	_snapshot_revision = -1
	_snapshot_cache.clear()
	emit_changed()


func is_valid() -> bool:
	if _validated_revision == revision:
		return _cached_valid
	var payload := _payload_dictionary()
	var result := validate_payload(payload)
	_cached_valid = bool(result.get("valid", false))
	_validated_revision = revision
	return _cached_valid


## Main-thread boundary. The returned dictionary contains only immutable value
## data and no Node, Resource, WeakRef, RenderingDevice, or RID handles.
func get_rendering_snapshot() -> Dictionary:
	if not is_valid():
		return {}
	if _snapshot_revision != revision:
		_snapshot_cache = _payload_dictionary()
		_snapshot_cache["abi_version"] = FORMAT_VERSION
		_snapshot_cache["valid"] = true
		_snapshot_cache["resource_id"] = get_instance_id()
		_snapshot_cache["revision"] = revision
		_snapshot_cache["world_to_capture"] = capture_transform.affine_inverse()
		_snapshot_cache["world_direction_to_capture"] = capture_transform.basis.orthonormalized().transposed()
		_snapshot_cache["snapshot_thread_contract"] = "main_thread_immutable_values_only"
		_snapshot_revision = revision
	return _snapshot_cache.duplicate(false)


func _payload_dictionary() -> Dictionary:
	return {
		"format_version": format_version,
		"capture_transform": capture_transform,
		"bounds_local": bounds_local,
		"brick_size": brick_size,
		"indirection_dimensions": indirection_dimensions,
		"brick_atlas_dimensions": brick_atlas_dimensions,
		"indirection_rgba8_uint": indirection_rgba8_uint,
		"ambient_rgba16f": ambient_rgba16f,
		"sh_coefficients_rgba8_unorm": sh_coefficients_rgba8_unorm,
		"sky_bent_normal_rgba8_unorm": sky_bent_normal_rgba8_unorm,
		"directional_shadow_r8_unorm": directional_shadow_r8_unorm,
		"baked_exposure": baked_exposure,
		"includes_environment_radiance": includes_environment_radiance,
		"contains_static_direct_directional_lighting": contains_static_direct_directional_lighting,
		"has_sky_bent_normal": has_sky_bent_normal,
		"has_directional_shadowing": has_directional_shadowing,
		"static_directional_light_key": String(static_directional_light_key),
		"coefficient_domain": coefficient_domain,
		"source_revision": source_revision,
	}


static func validate_payload(p_payload: Dictionary) -> Dictionary:
	var decoded := _decode_candidate(p_payload)
	return {"valid": bool(decoded.get("valid", false)), "reason": str(decoded.get("reason", ""))}


static func _decode_candidate(p_payload: Dictionary) -> Dictionary:
	if int(p_payload.get("format_version", 0)) != FORMAT_VERSION:
		return _failure("Only decoded volumetric-lightmap payload version 1 is supported.")
	var units := String(p_payload.get("coordinate_units", "m"))
	var unit_scale := 1.0
	if units == "ue_cm":
		unit_scale = 0.01
	elif units != "m":
		return _failure("coordinate_units must be 'm' or 'ue_cm'.")
	var transform: Variant = p_payload.get("capture_transform", Transform3D.IDENTITY)
	var bounds: Variant = p_payload.get("bounds_local", AABB())
	var dims: Variant = p_payload.get("indirection_dimensions", Vector3i.ZERO)
	var atlas_dims: Variant = p_payload.get("brick_atlas_dimensions", Vector3i.ZERO)
	var brick := int(p_payload.get("brick_size", DEFAULT_BRICK_SIZE))
	if not transform is Transform3D or not transform.is_finite() \
			or absf(transform.basis.determinant()) <= 0.00000001:
		return _failure("capture_transform is non-finite or singular.")
	if not bounds is AABB or not bounds.position.is_finite() or not bounds.size.is_finite() \
			or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return _failure("bounds_local must be a finite positive-volume AABB in meters.")
	if not dims is Vector3i or not atlas_dims is Vector3i:
		return _failure("Indirection and padded atlas dimensions must be positive Vector3i values.")
	var dimensions: Vector3i = dims
	var atlas_dimensions: Vector3i = atlas_dims
	if dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0 \
			or atlas_dimensions.x <= 0 or atlas_dimensions.y <= 0 or atlas_dimensions.z <= 0:
		return _failure("Indirection and padded atlas dimensions must be positive Vector3i values.")
	if brick <= 0 or brick > 64:
		return _failure("brick_size must be between 1 and 64.")
	var indirection: Variant = p_payload.get("indirection_rgba8_uint", PackedByteArray())
	var ambient: Variant = p_payload.get("ambient_rgba16f", PackedByteArray())
	var sh_layers: Variant = p_payload.get("sh_coefficients_rgba8_unorm", [])
	var bent: Variant = p_payload.get("sky_bent_normal_rgba8_unorm", PackedByteArray())
	var shadow: Variant = p_payload.get("directional_shadow_r8_unorm", PackedByteArray())
	if not indirection is PackedByteArray or not ambient is PackedByteArray \
			or not sh_layers is Array or not bent is PackedByteArray or not shadow is PackedByteArray:
		return _failure("Payload texture bytes have invalid types.")
	var indirection_voxels: int = dimensions.x * dimensions.y * dimensions.z
	var atlas_voxels: int = atlas_dimensions.x * atlas_dimensions.y * atlas_dimensions.z
	if indirection_voxels <= 0 or atlas_voxels <= 0 or atlas_voxels > MAX_ATLAS_VOXELS:
		return _failure("Payload texture dimensions exceed supported limits.")
	if indirection.size() != indirection_voxels * 4:
		return _failure("RGBA8_UINT indirection byte count does not match its dimensions.")
	var has_bent := bool(p_payload.get("has_sky_bent_normal", not bent.is_empty()))
	var has_shadow := bool(p_payload.get("has_directional_shadowing", not shadow.is_empty()))
	if ambient.size() != atlas_voxels * 8:
		return _failure("Ambient RGBA16F byte count does not match the padded atlas.")
	if bent.is_empty():
		if has_bent:
			return _failure("has_sky_bent_normal is true but no bent-normal texture was supplied.")
		bent = _neutral_bent_bytes(atlas_voxels)
	elif bent.size() != atlas_voxels * 4:
		return _failure("Bent-normal byte count does not match the padded atlas.")
	if shadow.is_empty():
		if has_shadow:
			return _failure("has_directional_shadowing is true but no shadow texture was supplied.")
		shadow = _neutral_shadow_bytes(atlas_voxels)
	elif shadow.size() != atlas_voxels:
		return _failure("Directional-shadow byte count does not match the padded atlas.")
	if sh_layers.size() != 6:
		return _failure("Exactly six RGBA8_UNORM SH coefficient layers are required.")
	for layer in sh_layers:
		if not layer is PackedByteArray or layer.size() != atlas_voxels * 4:
			return _failure("Each SH coefficient layer must contain one RGBA8_UNORM texel per atlas voxel.")
	for offset in range(0, ambient.size(), 2):
		if not is_finite(ambient.decode_half(offset)):
			return _failure("Ambient RGBA16F data contains a non-finite value.")
	for z in dimensions.z:
		for y in dimensions.y:
			for x in dimensions.x:
				var entry: int = ((z * dimensions.y + y) * dimensions.x + x) * 4
				var covered := int(indirection[entry + 3])
				if covered == 0:
					continue
				var ox := int(indirection[entry])
				var oy := int(indirection[entry + 1])
				var oz := int(indirection[entry + 2])
				if covered > max(dimensions.x, max(dimensions.y, dimensions.z)) \
						or ox * (brick + 1) + brick >= atlas_dimensions.x \
						or oy * (brick + 1) + brick >= atlas_dimensions.y \
						or oz * (brick + 1) + brick >= atlas_dimensions.z:
					return _failure("Indirection entry references a brick outside the padded atlas.")
	var exposure := float(p_payload.get("baked_exposure", 1.0))
	if not is_finite(exposure) or exposure <= 0.000001:
		return _failure("baked_exposure must be finite and positive.")
	var scaled_bounds := bounds
	scaled_bounds.position *= unit_scale
	scaled_bounds.size *= unit_scale
	var key := String(p_payload.get("static_directional_light_key", ""))
	var domain := String(p_payload.get("coefficient_domain", "ue_vlm_ambient_and_normalized_sh_v1"))
	if domain != "ue_vlm_ambient_and_normalized_sh_v1":
		return _failure("Unknown coefficient_domain; this decoder only accepts UE VLM normalized-SH v1.")
	var candidate := {
		"format_version": FORMAT_VERSION,
		"capture_transform": transform,
		"bounds_local": scaled_bounds,
		"brick_size": brick,
		"indirection_dimensions": dimensions,
		"brick_atlas_dimensions": atlas_dimensions,
		"indirection_rgba8_uint": indirection.duplicate(),
		"ambient_rgba16f": ambient.duplicate(),
		"sh_coefficients_rgba8_unorm": sh_layers.duplicate(true),
		"sky_bent_normal_rgba8_unorm": bent.duplicate(),
		"directional_shadow_r8_unorm": shadow.duplicate(),
		"baked_exposure": exposure,
		"includes_environment_radiance": bool(p_payload.get("includes_environment_radiance", false)),
		"contains_static_direct_directional_lighting": bool(p_payload.get("contains_static_direct_directional_lighting", false)),
		"has_sky_bent_normal": has_bent,
		"has_directional_shadowing": has_shadow,
		"static_directional_light_key": key,
		"coefficient_domain": domain,
		"source_revision": int(p_payload.get("source_revision", 0)),
	}
	return {"valid": true, "payload": candidate, "reason": ""}


static func _neutral_bent_bytes(p_voxels: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(p_voxels * 4)
	for voxel in p_voxels:
		var offset := voxel * 4
		bytes[offset] = 128
		bytes[offset + 1] = 128
		bytes[offset + 2] = 255
		bytes[offset + 3] = 255
	return bytes


static func _neutral_shadow_bytes(p_voxels: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(p_voxels)
	bytes.fill(255)
	return bytes


func _active_payload_equals(p_candidate: Dictionary) -> bool:
	return format_version == int(p_candidate["format_version"]) \
			and capture_transform == p_candidate["capture_transform"] \
			and bounds_local == p_candidate["bounds_local"] \
			and brick_size == int(p_candidate["brick_size"]) \
			and indirection_dimensions == p_candidate["indirection_dimensions"] \
			and brick_atlas_dimensions == p_candidate["brick_atlas_dimensions"] \
			and indirection_rgba8_uint == p_candidate["indirection_rgba8_uint"] \
			and ambient_rgba16f == p_candidate["ambient_rgba16f"] \
			and sh_coefficients_rgba8_unorm == p_candidate["sh_coefficients_rgba8_unorm"] \
			and sky_bent_normal_rgba8_unorm == p_candidate["sky_bent_normal_rgba8_unorm"] \
			and directional_shadow_r8_unorm == p_candidate["directional_shadow_r8_unorm"] \
			and is_equal_approx(baked_exposure, float(p_candidate["baked_exposure"])) \
			and includes_environment_radiance == bool(p_candidate["includes_environment_radiance"]) \
			and contains_static_direct_directional_lighting == bool(p_candidate["contains_static_direct_directional_lighting"]) \
			and has_sky_bent_normal == bool(p_candidate["has_sky_bent_normal"]) \
			and has_directional_shadowing == bool(p_candidate["has_directional_shadowing"]) \
			and String(static_directional_light_key) == String(p_candidate["static_directional_light_key"]) \
			and coefficient_domain == String(p_candidate["coefficient_domain"]) \
			and source_revision == int(p_candidate["source_revision"])


static func sample_cpu(p_snapshot: Dictionary, p_world_position: Vector3,
		p_world_camera_vector: Vector3, p_g: float,
		p_static_directional_light_key: String = "") -> Dictionary:
	if not bool(p_snapshot.get("valid", false)) or not p_world_position.is_finite() \
			or not p_world_camera_vector.is_finite() or p_world_camera_vector.length_squared() <= 1e-12 \
			or not is_finite(p_g):
		return _invalid_sample(p_snapshot)
	var capture: Transform3D = p_snapshot.get("capture_transform", Transform3D.IDENTITY)
	var world_to_capture: Transform3D = capture.affine_inverse()
	var bounds: AABB = p_snapshot.get("bounds_local", AABB())
	var local := world_to_capture * p_world_position
	var uv := Vector3(
		clampf((local.x - bounds.position.x) / bounds.size.x, 0.0, 0.99),
		clampf((local.y - bounds.position.y) / bounds.size.y, 0.0, 0.99),
		clampf((local.z - bounds.position.z) / bounds.size.z, 0.0, 0.99))
	var dims: Vector3i = p_snapshot["indirection_dimensions"]
	var ind_coord := Vector3(uv.x * dims.x, uv.y * dims.y, uv.z * dims.z)
	var cell := Vector3i(clampi(int(floor(ind_coord.x)), 0, dims.x - 1),
		clampi(int(floor(ind_coord.y)), 0, dims.y - 1),
		clampi(int(floor(ind_coord.z)), 0, dims.z - 1))
	var indirection: PackedByteArray = p_snapshot["indirection_rgba8_uint"]
	var entry_offset := ((cell.z * dims.y + cell.y) * dims.x + cell.x) * 4
	var brick_offset := Vector3i(indirection[entry_offset], indirection[entry_offset + 1], indirection[entry_offset + 2])
	var covered := int(indirection[entry_offset + 3])
	if covered == 0:
		return _invalid_sample(p_snapshot)
	var fractional := Vector3(
		ind_coord.x / float(covered) - floor(ind_coord.x / float(covered)),
		ind_coord.y / float(covered) - floor(ind_coord.y / float(covered)),
		ind_coord.z / float(covered) - floor(ind_coord.z / float(covered)))
	var brick_size := int(p_snapshot["brick_size"])
	var atlas_dims: Vector3i = p_snapshot["brick_atlas_dimensions"]
	var brick_uv := Vector3(
		(float(brick_offset.x * (brick_size + 1)) + fractional.x * brick_size + 0.5) / atlas_dims.x,
		(float(brick_offset.y * (brick_size + 1)) + fractional.y * brick_size + 0.5) / atlas_dims.y,
		(float(brick_offset.z * (brick_size + 1)) + fractional.z * brick_size + 0.5) / atlas_dims.z)
	var ambient: Vector4 = _sample_rgba16(p_snapshot["ambient_rgba16f"], atlas_dims, brick_uv)
	var sh_layers: Array = p_snapshot["sh_coefficients_rgba8_unorm"]
	var red_l1: Vector4 = _sample_rgba8(sh_layers[0], atlas_dims, brick_uv) * 2.0 - Vector4.ONE
	var green_l1: Vector4 = _sample_rgba8(sh_layers[2], atlas_dims, brick_uv) * 2.0 - Vector4.ONE
	var blue_l1: Vector4 = _sample_rgba8(sh_layers[4], atlas_dims, brick_uv) * 2.0 - Vector4.ONE
	var scales := Vector4(SH2_L1_SCALE, SH2_L1_SCALE, SH2_L1_SCALE, SH2_L1_XY_SCALE)
	red_l1 *= ambient.x * scales
	green_l1 *= ambient.y * scales
	blue_l1 *= ambient.z * scales
	var world_to_direction: Basis = capture.basis.orthonormalized().transposed()
	var direction := (world_to_direction * p_world_camera_vector).normalized()
	var phase := Vector4(1.0, direction.y, direction.z, direction.x) * Vector4(1.0, clampf(p_g, -0.999, 0.999), clampf(p_g, -0.999, 0.999), clampf(p_g, -0.999, 0.999))
	var irradiance_over_pi := Vector3(
		maxf(Vector4(ambient.x, red_l1.x, red_l1.y, red_l1.z).dot(phase), 0.0),
		maxf(Vector4(ambient.y, green_l1.x, green_l1.y, green_l1.z).dot(phase), 0.0),
		maxf(Vector4(ambient.z, blue_l1.x, blue_l1.y, blue_l1.z).dot(phase), 0.0)) / PI
	var flags := FLAG_VALID
	if bool(p_snapshot.get("includes_environment_radiance", false)):
		flags |= FLAG_INCLUDES_ENVIRONMENT_RADIANCE
	if bool(p_snapshot.get("contains_static_direct_directional_lighting", false)):
		flags |= FLAG_CONTAINS_STATIC_DIRECT_DIRECTIONAL_LIGHTING
	var sky_visibility := 1.0
	if bool(p_snapshot.get("has_sky_bent_normal", false)):
		var bent: Vector4 = _sample_rgba8(p_snapshot["sky_bent_normal_rgba8_unorm"], atlas_dims, brick_uv)
		var bent_xyz := Vector3(bent.x, bent.y, bent.z) * 2.0 - Vector3.ONE
		sky_visibility = bent_xyz.length()
		flags |= FLAG_HAS_SKY_BENT_NORMAL
	var directional_shadow := 1.0
	var source_key := String(p_snapshot.get("static_directional_light_key", ""))
	var key_matches := not source_key.is_empty() and source_key == p_static_directional_light_key
	if bool(p_snapshot.get("has_directional_shadowing", false)):
		flags |= FLAG_HAS_DIRECTIONAL_SHADOW
		if key_matches:
			directional_shadow = _sample_r8(p_snapshot["directional_shadow_r8_unorm"], atlas_dims, brick_uv)
	if key_matches:
		flags |= FLAG_STATIC_LIGHT_KEY_MATCH
	return {
		"valid": true,
		"irradiance_over_pi": irradiance_over_pi,
		"sky_visibility": sky_visibility,
		"directional_shadow": directional_shadow,
		"baked_exposure": float(p_snapshot.get("baked_exposure", 1.0)),
		"source_flags": flags,
		"static_light_key_match": key_matches,
		"indirection_cell": cell,
		"brick_uv": brick_uv,
	}


static func _invalid_sample(p_snapshot: Dictionary) -> Dictionary:
	return {
		"valid": false,
		"irradiance_over_pi": Vector3.ZERO,
		"sky_visibility": 1.0,
		"directional_shadow": 1.0,
		"baked_exposure": float(p_snapshot.get("baked_exposure", 1.0)),
		"source_flags": 0,
		"static_light_key_match": false,
	}


static func _sample_rgba8(p_bytes: PackedByteArray, p_dims: Vector3i, p_uv: Vector3) -> Vector4:
	var position := Vector3(p_uv.x * p_dims.x - 0.5, p_uv.y * p_dims.y - 0.5, p_uv.z * p_dims.z - 0.5)
	var base := Vector3i(int(floor(position.x)), int(floor(position.y)), int(floor(position.z)))
	var f := position - Vector3(base)
	var result := Vector4.ZERO
	for z in 2:
		for y in 2:
			for x in 2:
				var coordinate := Vector3i(clampi(base.x + x, 0, p_dims.x - 1), clampi(base.y + y, 0, p_dims.y - 1), clampi(base.z + z, 0, p_dims.z - 1))
				var weight := (f.x if x == 1 else 1.0 - f.x) * (f.y if y == 1 else 1.0 - f.y) * (f.z if z == 1 else 1.0 - f.z)
				var value := _rgba8_texel(p_bytes, p_dims, coordinate)
				result += value * weight
	return result


static func _sample_rgba16(p_bytes: PackedByteArray, p_dims: Vector3i, p_uv: Vector3) -> Vector4:
	var position := Vector3(p_uv.x * p_dims.x - 0.5, p_uv.y * p_dims.y - 0.5, p_uv.z * p_dims.z - 0.5)
	var base := Vector3i(int(floor(position.x)), int(floor(position.y)), int(floor(position.z)))
	var f := position - Vector3(base)
	var result := Vector4.ZERO
	for z in 2:
		for y in 2:
			for x in 2:
				var coordinate := Vector3i(clampi(base.x + x, 0, p_dims.x - 1), clampi(base.y + y, 0, p_dims.y - 1), clampi(base.z + z, 0, p_dims.z - 1))
				var weight := (f.x if x == 1 else 1.0 - f.x) * (f.y if y == 1 else 1.0 - f.y) * (f.z if z == 1 else 1.0 - f.z)
				var value := _rgba16_texel(p_bytes, p_dims, coordinate)
				result += value * weight
	return result


static func _sample_r8(p_bytes: PackedByteArray, p_dims: Vector3i, p_uv: Vector3) -> float:
	var position := Vector3(p_uv.x * p_dims.x - 0.5, p_uv.y * p_dims.y - 0.5, p_uv.z * p_dims.z - 0.5)
	var base := Vector3i(int(floor(position.x)), int(floor(position.y)), int(floor(position.z)))
	var f := position - Vector3(base)
	var result := 0.0
	for z in 2:
		for y in 2:
			for x in 2:
				var coordinate := Vector3i(clampi(base.x + x, 0, p_dims.x - 1), clampi(base.y + y, 0, p_dims.y - 1), clampi(base.z + z, 0, p_dims.z - 1))
				var weight := (f.x if x == 1 else 1.0 - f.x) * (f.y if y == 1 else 1.0 - f.y) * (f.z if z == 1 else 1.0 - f.z)
				var index := (coordinate.z * p_dims.y + coordinate.y) * p_dims.x + coordinate.x
				result += float(p_bytes[index]) / 255.0 * weight
	return result


static func _rgba8_texel(p_bytes: PackedByteArray, p_dims: Vector3i, p_coordinate: Vector3i) -> Vector4:
	var offset := ((p_coordinate.z * p_dims.y + p_coordinate.y) * p_dims.x + p_coordinate.x) * 4
	return Vector4(float(p_bytes[offset]), float(p_bytes[offset + 1]), float(p_bytes[offset + 2]), float(p_bytes[offset + 3])) / 255.0


static func _rgba16_texel(p_bytes: PackedByteArray, p_dims: Vector3i, p_coordinate: Vector3i) -> Vector4:
	var offset := ((p_coordinate.z * p_dims.y + p_coordinate.y) * p_dims.x + p_coordinate.x) * 8
	return Vector4(p_bytes.decode_half(offset), p_bytes.decode_half(offset + 2), p_bytes.decode_half(offset + 4), p_bytes.decode_half(offset + 6))


static func _failure(p_reason: String) -> Dictionary:
	return {"valid": false, "reason": p_reason}
