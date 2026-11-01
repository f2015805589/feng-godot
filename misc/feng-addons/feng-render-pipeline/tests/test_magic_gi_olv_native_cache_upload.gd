extends SceneTree

const Source = preload("res://addons/feng-magic-gi/feng_magic_gi_volume_source_chunk.gd")
const Header = preload("res://addons/feng-magic-gi/feng_magic_gi_prepared_source_header.gd")
const Brick = preload("res://addons/feng-magic-gi/feng_magic_gi_prepared_transfer_brick.gd")
const Labels = preload("res://addons/feng-magic-gi/feng_magic_gi_olv_label_set.gd")
const Domain = preload("res://addons/feng-magic-gi/feng_magic_gi_olv_domain.gd")
const WholeCache = preload("res://addons/feng-render-pipeline/passes/magic_gi_preinterpolated_volume_cache.gd")
const PagedCache = preload("res://addons/feng-render-pipeline/passes/magic_gi_paged_prepared_volume_cache.gd")

const RES := 16
const CELL_COUNT := RES * RES * RES
const SCENE_ID := "native-cache-fixture-scene"
const VOLUME_ID := "native-cache-fixture-volume"
const GEOMETRY_SIGNATURE := 174921
const LAYOUT_SIGNATURE := "native-cache-fixture-layout"
const LAYOUT_REVISION := 3
const SOURCE_ORIGIN := Vector3(-1.875, -1.875, -1.875)
const SOURCE_BOUNDS := AABB(Vector3(-2.0, -2.0, -2.0), Vector3(4.0, 4.0, 4.0))

var checks := 0
var failures := 0
var rd: RenderingDevice
var whole_cache: RefCounted
var paged_cache: RefCounted


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	_check(rd != null, "local RenderingDevice must be available")
	if rd == null:
		_finish()
		return
	var label_set := _make_labels()
	var olv_context := _make_context(label_set)
	var source := _make_whole_source(olv_context)
	_check(source.has_preinterpolated_clv(), "synthetic SH2 source must satisfy the production cache input contract")
	whole_cache = WholeCache.new()
	var whole_ok: bool = whole_cache.create(rd, source, true, 8, Vector3.ZERO,
			Vector3.FORWARD, label_set, olv_context)
	_check(whole_ok, "whole prepared cache create failed: %s" % str(whole_cache.get("_error")))
	if whole_ok:
		_check_resident_upload(whole_cache, 8, Vector3i(16, 16, 64), 0)
		var upload_count := int(whole_cache.get("_olv_upload_count"))
		_check(whole_cache.update_clipmap(rd, source, Vector3.ZERO, false, Vector3.FORWARD),
				"whole cache same-camera update must succeed")
		_check(int(whole_cache.get("_olv_upload_count")) == upload_count,
				"unchanged whole residency must not re-upload the label atlas")

	var header := _make_header()
	var brick := _make_brick()
	_check(header.is_header_valid(), "synthetic paged header must satisfy production validation")
	_check(brick.is_header_valid(), "synthetic resident brick must satisfy production validation")
	paged_cache = PagedCache.new()
	var paged_ok: bool = paged_cache.create_paged(rd, header, [{"brick": brick}], 1,
			Vector3.ZERO, 512.0, label_set, olv_context)
	_check(paged_ok, "paged prepared cache create failed: %s" % str(paged_cache.get("_error")))
	if paged_ok:
		_check_resident_upload(paged_cache, 7, Vector3i(16, 16, 16), 0)
		var upload_count := int(paged_cache.get("_olv_upload_count"))
		_check(paged_cache.update_pages(rd, header, [{"brick": brick}], 1,
				Vector3.ZERO, 512.0, false), "paged unchanged-revision update must succeed")
		_check(int(paged_cache.get("_olv_upload_count")) == upload_count,
				"unchanged paged residency must not re-upload the label atlas")
		_check(paged_cache.update_pages(rd, header, [{"brick": brick}], 2,
				Vector3.ZERO, 512.0, false), "paged generation revision update must succeed")
		_check(int(paged_cache.get("_olv_upload_count")) == upload_count + 1,
				"new paged generation must refresh the resident label atlas once")
		_check_resident_upload(paged_cache, 7, Vector3i(16, 16, 16), 0)
	_finish()


func _make_labels() -> Resource:
	var labels: Resource = Labels.new()
	var configured: Dictionary = labels.configure(SCENE_ID, VOLUME_ID,
			LAYOUT_REVISION, GEOMETRY_SIGNATURE, LAYOUT_SIGNATURE)
	_check(bool(configured.get("ok", false)), "label set binding must configure")
	_check(bool(labels.set_cell_label(_identity(Vector3i.ZERO), Domain.LABEL_EXTERIOR).get("ok", false)),
			"exterior label fixture record must be accepted")
	_check(bool(labels.set_cell_label(_identity(Vector3i(1, 0, 0)), Domain.LABEL_INTERIOR).get("ok", false)),
			"interior label fixture record must be accepted")
	_check(bool(labels.set_cell_label(_identity(Vector3i(-1, 0, 0)), Domain.LABEL_INTERIOR).get("ok", false)),
			"source label outside the SH window is retained for receiver classification")
	for z in 2:
		for y in 2:
			for x in 2:
				labels.set_cell_label(_identity(Vector3i(4+x,4+y,4+z)), Domain.LABEL_INTERIOR)
	labels.refresh_labels_hash()
	_check(bool(labels.validate().get("ok", false)), "sealed label set must validate")
	return labels


func _identity(cell: Vector3i) -> Dictionary:
	return Domain.cell_identity(SCENE_ID, VOLUME_ID, 0, cell, LAYOUT_REVISION)


func _make_context(labels: Resource) -> Dictionary:
	return {"scene_id": SCENE_ID, "volume_id": VOLUME_ID,
		"layout_revision": LAYOUT_REVISION, "layout_signature": LAYOUT_SIGNATURE,
		"grid_origin_world": SOURCE_ORIGIN, "base_cell_spacing_m": 0.25,
		"labels_hash": String(labels.get("labels_hash"))}


func _make_whole_source(context: Dictionary) -> Resource:
	var source: Resource = Source.new()
	source.allocate(Vector3i(RES, RES, RES), PackedStringArray())
	source.validity.fill(Source.RELOCATION_STATUS_VALID)
	source.geometry_signature = GEOMETRY_SIGNATURE
	source.origin_world = SOURCE_ORIGIN
	source.source_transform_world = Transform3D.IDENTITY
	source.source_size_m = Vector3(4.0, 4.0, 4.0)
	source.source_bounds_world = SOURCE_BOUNDS
	source.domain_bounds_world = SOURCE_BOUNDS
	source.trace_distance_m = 8.0
	source.bake_samples = 1
	source.bake_bounces = 1
	source.moment_rays = 256
	source.maximum_relocation_m = 0.0
	source.directional_source_signature = source.make_directional_source_signature()
	source.clv_preparation_revision = Source.CLV_PREPARATION_REVISION_CURRENT
	source.clv_preparation_schema_version = Source.CLV_PREPARATION_SCHEMA_CURRENT
	source.clv_preparation_olv_binding_signature = JSON.stringify([
		String(context.scene_id), String(context.volume_id), int(context.layout_revision),
		String(context.layout_signature), String(context.labels_hash)], "", true, true).sha256_text()
	source.clv_prepared_dimensions = PackedInt32Array([
		16, 16, 16, 8, 8, 8, 4, 4, 4, 2, 2, 2])
	source.clv_prepared_offsets = PackedInt32Array([0, 4096, 4608, 4672])
	source.clv_prepared_validity.resize(4680)
	source.clv_prepared_validity.fill(1)
	source.clv_prepared_operators.resize(4680 * source.prepared_operator_stride())
	source.clv_prepared_operators.fill(0.0)
	source.clv_preparation_stats = {"maximum_operator_row_l1": 1.0}
	source.clv_preparation_signature = source.make_clv_preparation_signature()
	return source


func _make_header() -> Resource:
	var header: Resource = Header.new()
	header.dimensions = Vector3i(RES, RES, RES)
	header.origin_world = SOURCE_ORIGIN
	header.spacing_m = 0.25
	header.prepared_level_count = 1
	header.domain_bounds_world = SOURCE_BOUNDS
	header.source_transform_world = Transform3D.IDENTITY
	header.source_size_m = Vector3(4.0, 4.0, 4.0)
	header.directional_source_signature = "native-cache-fixture-source"
	header.geometry_signature = GEOMETRY_SIGNATURE
	header.maximum_operator_row_l1 = 1.0
	header.operator_schema_version = 2
	header.clv_prepared_dimensions = PackedInt32Array([RES, RES, RES])
	return header


func _make_brick() -> Resource:
	var brick: Resource = Brick.new()
	brick.operator_schema_version = 2
	brick.source_origin_world = SOURCE_ORIGIN
	brick.source_spacing_m = 0.25
	brick.level = 0
	brick.cell_origin = Vector3i.ZERO
	brick.dimensions = Vector3i(RES, RES, RES)
	brick.core_cell_origin = Vector3i.ZERO
	brick.core_dimensions = Vector3i(RES, RES, RES)
	brick.operators.resize(CELL_COUNT * brick.operator_stride())
	brick.operators.fill(0.0)
	brick.validity.resize(CELL_COUNT)
	brick.validity.fill(1)
	brick.source_transform_world = Transform3D.IDENTITY
	brick.source_size_m = Vector3(4.0, 4.0, 4.0)
	brick.domain_bounds_world = SOURCE_BOUNDS
	brick.geometry_signature = GEOMETRY_SIGNATURE
	brick.directional_source_signature = "native-cache-fixture-source"
	brick.maximum_operator_row_l1 = 1.0
	brick.probe_count = CELL_COUNT
	return brick


func _check_resident_upload(cache: RefCounted, layout_version: int,
		expected_dimensions: Vector3i, lod_zero_cell_slot: int) -> void:
	var binding: Dictionary = cache.get_olv_binding()
	_check(bool(binding.get("enabled", false)), "cache must publish an enabled OLV binding")
	_check(String(binding.get("labels_hash", "")) == String(cache.get("_olv_labels_hash")),
			"published binding must retain the validated label hash")
	var atlas: RID = binding.get("label_atlas", RID())
	var parameters: RID = binding.get("label_parameters", RID())
	_check(atlas.is_valid() and parameters.is_valid(), "cache must publish both atlas and metadata RIDs")
	if not atlas.is_valid() or not parameters.is_valid(): return
	var format := rd.texture_get_format(atlas)
	_check(format.format == RenderingDevice.DATA_FORMAT_R8_UNORM,
			"runtime domain cache uses one byte per label texel")
	rd.submit()
	rd.sync()
	var metadata := rd.buffer_get_data(parameters, 0, 32).to_int32_array()
	_check(metadata.size() == 8 and metadata[0] == expected_dimensions.x \
			and metadata[1] == expected_dimensions.y and metadata[2] == expected_dimensions.z \
			and metadata[3] == layout_version and metadata[4] == 1 and metadata[5] == 1 \
			and metadata[6] == expected_dimensions.z * 2 and metadata[7] == expected_dimensions.x * 2,
			"native OLV ABI metadata must declare the actual resident atlas and layout")
	var atlas_values := _read_resident_pair(atlas)
	if lod_zero_cell_slot == 0 and atlas_values.size() == 4:
		_check(is_equal_approx(atlas_values[0], float(Domain.LABEL_EXTERIOR)),
				"resident cell (0,0,0) must upload the exterior class")
		_check(is_equal_approx(atlas_values[1], float(Domain.LABEL_INTERIOR)),
				"resident cell (1,0,0) must upload the interior class")
		_check(is_equal_approx(atlas_values[2], float(Domain.LABEL_INTERIOR)),
				"label-only halo keeps a fine label without loading its SH operator")
		_check(is_equal_approx(atlas_values[3], float(Domain.LABEL_INTERIOR)),
				"label bytes contain only indoor/outdoor classes without interpolation flags")
	else:
		_check(false, "fixture's labeled source cells must occupy resident atlas origin x=0, y=0, z=0")
	var response_fields: Array = cache.get("texture_fields")
	var response_format := rd.texture_get_format(response_fields[0])
	_check(response_format.width == RES * 2 and response_format.depth == expected_dimensions.z * 4,
			"indoor/outdoor volumes occupy independent X slabs without increasing texture depth")
	var mapping := rd.buffer_get_data(cache.get("_olv_partition_indices")).to_int32_array()
	var originals: PackedInt32Array = cache.get("_resident_indices")
	_check(mapping.size() == originals.size() * 8, "both partitions have bounded resident mappings")
	_check(mapping[0] == originals[0], "exterior volume retains its original source operator")
	_check(mapping[RES*4] == originals[1] and mapping[(RES+1)*4] == originals[1],
			"interior volume extends its own source across the border without admitting the exterior operator")
	_check(mapping[2*4] == -1, "dilation is bounded to one cell; unsupported exterior space remains unavailable")
	var weights := rd.buffer_get_data(cache.get("_olv_partition_weights")).to_float32_array()
	var target := ((4 * RES + 4) * (RES*2) + RES + 3) * 4
	var sum_weights := 0.0
	for component in 4:
		sum_weights += weights[target+component]
		_check(mapping[target+component] >= 0 and weights[target+component] > 0.0,
				"border reconstruction uses four same-domain neighbors rather than a nearest-copy block")
	_check(absf(sum_weights-1.0)<0.00001, "same-domain border weights preserve constant radiance")


func _read_resident_pair(atlas: RID) -> PackedFloat32Array:
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = """#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform texture3D label_texture;
layout(set = 0, binding = 1) uniform sampler nearest_sampler;
layout(set = 0, binding = 2, std430) buffer Result { float values[]; } result_data;
void main() {
	uint x = gl_GlobalInvocationID.x;
	if (x < 4u) {
		result_data.values[x] = texelFetch(sampler3D(label_texture, nearest_sampler),
			(x == 3u ? ivec3(4) : ivec3(x == 2u ? -1 : int(x), 0, 0)) + ivec3(textureSize(sampler3D(label_texture, nearest_sampler), 0).x / 4), 0).r * 255.0;
	}
}
"""
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	_check(spirv.compile_error_compute.is_empty(),
			"cache readback shader must compile: " + spirv.compile_error_compute)
	if not spirv.compile_error_compute.is_empty(): return PackedFloat32Array()
	var shader := rd.shader_create_from_spirv(spirv, "OLV Resident Cache Readback")
	var pipeline := rd.compute_pipeline_create(shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	var sampler := rd.sampler_create(sampler_state)
	var output := rd.storage_buffer_create(16)
	var texture_uniform := RDUniform.new()
	texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
	texture_uniform.binding = 0
	texture_uniform.add_id(atlas)
	var sampler_uniform := RDUniform.new()
	sampler_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
	sampler_uniform.binding = 1
	sampler_uniform.add_id(sampler)
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output_uniform.binding = 2
	output_uniform.add_id(output)
	var uniform_set := rd.uniform_set_create([texture_uniform, sampler_uniform,
			output_uniform], shader, 0)
	var values := PackedFloat32Array()
	if shader.is_valid() and pipeline.is_valid() and sampler.is_valid() \
			and output.is_valid() and uniform_set.is_valid():
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_dispatch(list, 4, 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		values = rd.buffer_get_data(output, 0, 16).to_float32_array()
	else:
		_check(false, "compute readback resources must be valid")
	for rid in [uniform_set, output, sampler, pipeline, shader]:
		if rid.is_valid(): rd.free_rid(rid)
	return values


func _finish() -> void:
	print("OLV_NATIVE_CACHE_UPLOAD_RESULT checks=", checks, " failures=", failures)
	if rd != null:
		var freed: Dictionary = {}
		for cache in [paged_cache, whole_cache]:
			if cache == null: continue
			var rids: Array = cache.owned_rids()
			for rid_value in rids:
				var rid: RID = rid_value
				if rid.is_valid() and not freed.has(rid.get_id()):
					freed[rid.get_id()] = true
					rd.free_rid(rid)
		rd.free()
		rd = null
	quit(1 if failures > 0 else 0)
