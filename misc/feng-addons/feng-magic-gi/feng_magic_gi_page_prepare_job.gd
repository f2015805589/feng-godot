@tool
extends RefCounted
## Immutable CPU preparation for one loaded streamed page. This keeps resource
## validation, texture packing, and large float-to-byte copies off the main loop.

const Page = preload("feng_magic_gi_page.gd")
const Data = preload("feng_magic_gi_data.gd")
const VolumeSourceChunk = preload("feng_magic_gi_volume_source_chunk.gd")

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
var gpu_bytes := 0
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
			or not page.is_header_valid(expected_generation, expected_page_key):
		error = "Loaded page failed generation, key, bounds, payload header, or budget validation."
		return
	if not expected_content_hash.is_empty() and FileAccess.get_sha256(resource_path) != expected_content_hash:
		error = "Loaded page content hash does not match the manifest."
		return
	if page.free_space_volume_source != null:
		_prepare_free_space_source()
		return
	if page.prepared_transfer_brick != null:
		_prepare_transfer_brick()
		return
	if not page.is_valid(expected_generation, expected_page_key):
		error = "Loaded legacy page failed Data validation."
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
	gpu_bytes = maxi(page.gpu_bytes, data.estimate_gpu_bytes())
	valid = cpu_bytes > 0 and page.gpu_bytes > 0

func _prepare_free_space_source() -> void:
	var chunk: VolumeSourceChunk = page.free_space_volume_source
	if page.data != null or chunk == null \
			or chunk.probe_count != page.probe_count \
			or chunk.geometry_signature != page.geometry_signature \
			or not chunk.is_valid(page.geometry_signature):
		error = "Free-space source page failed deep coefficient, moment, OBB, or geometry-signature validation."
		return
	if emission_sources.size() != chunk.emitter_count * 6:
		error = "Live emissive source snapshot does not match the free-space chunk emitter order."
		return
	for value in emission_sources:
		if not is_finite(value) or value < 0.0:
			error = "Live emissive source snapshot contains a non-finite or negative value."
			return
	# The source resource itself is immutable CPU payload. The runtime cache uploads
	# its matrices directly and accounts generated textures/live buffers separately.
	render_upload.clear()
	emission_payload.clear()
	emission_image = null
	cpu_bytes = maxi(page.cpu_bytes, chunk.estimated_cpu_resident_bytes())
	gpu_bytes = maxi(page.gpu_bytes, chunk.estimated_gpu_payload_bytes())
	valid = cpu_bytes > 0 and gpu_bytes > 0

func _prepare_transfer_brick() -> void:
	var brick: Resource = page.prepared_transfer_brick
	if not page.is_valid(expected_generation, expected_page_key):
		error = "Prepared brick failed deep operator, halo, identity, or bounds validation."
		return
	if emission_sources.size() != brick.emitter_count * 6:
		error = "Prepared brick emitter snapshot has the wrong number of weights."
		return
	for value in emission_sources:
		if not is_finite(value) or value < 0.0:
			error = "Prepared brick emitter snapshot is non-finite or negative."
			return
	cpu_bytes = maxi(page.cpu_bytes, brick.estimated_cpu_resident_bytes())
	# A prepared page is CPU-only. The renderer accounts the bounded resident
	# cell pool, not all matrices in every loaded page a second time.
	gpu_bytes = 0
	valid = cpu_bytes > 0
