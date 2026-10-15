@tool
extends RefCounted
## Immutable CPU preparation for one loaded streamed page. This keeps resource
## validation, texture packing, and large float-to-byte copies off the main loop.

const Page = preload("feng_magic_gi_page.gd")
const Data = preload("feng_magic_gi_data.gd")

var page: Page
var expected_generation := ""
var expected_page_key := ""
var resource_path := ""
var expected_content_hash := ""
var emission_sources := PackedFloat32Array()
var render_upload: Dictionary = {}
var emission_payload := PackedFloat32Array()
var emission_image: Image
var cpu_bytes := 0
var valid := false
var error := ""

func configure(source_page: Page, generation: String, page_key: String,
		path: String, content_hash: String, source_values: PackedFloat32Array) -> void:
	page = source_page
	expected_generation = generation
	expected_page_key = page_key
	resource_path = path
	expected_content_hash = content_hash
	emission_sources = source_values

func run() -> void:
	valid = false
	error = ""
	if page == null or not is_instance_valid(page) \
			or not page.is_valid(expected_generation, expected_page_key):
		error = "Loaded page failed generation, key, bounds, budget, or Data validation."
		return
	if not expected_content_hash.is_empty() and FileAccess.get_sha256(resource_path) != expected_content_hash:
		error = "Loaded page content hash does not match the manifest."
		return
	var data := page.data
	if not data is Data:
		error = "Loaded page has no supported FMagicGIData payload."
		return
	var packed := data.make_render_upload()
	if packed.is_empty():
		error = "Could not prepare the immutable page render textures and buffers."
		return
	var directional: Variant = data.directional
	if directional != null:
		var transfer: PackedFloat32Array = directional.transfer
		var sky: PackedFloat32Array = directional.sky
		var source_transport: PackedFloat32Array = directional.emission
		if not directional.is_valid(data.probe_count(), data.emitter_count()) \
				or transfer.size() != data.probe_count() * 243 \
				or sky.size() != data.probe_count() * 81 \
				or source_transport.size() != data.probe_count() * data.emitter_count() * 54:
			error = "Directional arrays do not match the immutable page layout."
			return
		packed["directional_transfer_bytes"] = transfer.to_byte_array()
		packed["directional_sky_bytes"] = sky.to_byte_array()
		packed["directional_emission_bytes"] = source_transport.to_byte_array()
	var normal_values := PackedFloat32Array()
	normal_values.resize(data.probe_count() * 4)
	for probe in data.probe_count():
		var normal: Vector3 = data.normals[probe]
		var base := probe * 4
		normal_values[base] = normal.x
		normal_values[base + 1] = normal.y
		normal_values[base + 2] = normal.z
		normal_values[base + 3] = 0.0
	packed["normal_bytes"] = normal_values.to_byte_array()
	var payload := data.compose_emission(emission_sources)
	var dynamic_image := data.make_emission_atlas_image(payload)
	if dynamic_image == null or dynamic_image.is_empty():
		error = "Could not prepare this page's current emissive contribution."
		return
	render_upload = packed
	emission_payload = payload
	emission_image = dynamic_image
	# The bake-side estimate includes the uncompressed packed upload payload as
	# well as the resident Data arrays, so it conservatively covers this bundle.
	cpu_bytes = maxi(page.cpu_bytes,
			data.estimate_cpu_bytes() + data.estimate_gpu_bytes() + data.probe_count() * 3 * 4)
	valid = cpu_bytes > 0 and page.gpu_bytes > 0
