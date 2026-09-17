// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "terrain_3d_vt_feedback.h"

#include "logger.h"

#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

// One invocation per candidate page. Projects the page's four world corners, measures
// the screen extent and picks the local mip that puts about one page texel on one
// screen pixel. `data` is a std430 float array so the layout is alignment safe:
//
//   0..15  view * projection, column major
//   16,17  grid width, grid height
//   18     pages per axis
//   19     region size (world metres)
//   20     page world size at local mip 0 (metres)
//   21     page size in texels
//   22     max local mip
//   23,24  chunk origin x, y
//   25,26  viewport width, height
//   27     minimum screen extent in pixels
// No `#[compute]` marker: that is a directive for Godot's RD shader importer, and
// compiling from source with shader_compile_spirv_from_source() passes the stage
// explicitly, so glslang rejects the marker as an invalid directive.
static const char *VT_FEEDBACK_SHADER = R"(#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32ui) uniform restrict writeonly uimage2D u_output;

layout(set = 0, binding = 1, std430) restrict readonly buffer Params {
	float data[];
} params;

const uint NO_REQUEST = 0xFFFFFFFFu;
// Diagnostic sentinels, so a caller can tell which early-out fired.
const uint REJECT_BEHIND = 0xFFFFFFFEu;
const uint REJECT_OFFSCREEN = 0xFFFFFFFDu;
const uint REJECT_TOO_SMALL = 0xFFFFFFFCu;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(params.data[16]) || id.y >= int(params.data[17])) {
		return;
	}
	int pages_per_axis = int(params.data[18]);
	float region_size = params.data[19];
	float page_world = params.data[20];
	float page_size = params.data[21];
	int max_local_mip = int(params.data[22]);
	ivec2 chunk = ivec2(int(params.data[23]), int(params.data[24])) + id / pages_per_axis;
	ivec2 page = id % pages_per_axis;

	mat4 vp = mat4(
			vec4(params.data[0], params.data[1], params.data[2], params.data[3]),
			vec4(params.data[4], params.data[5], params.data[6], params.data[7]),
			vec4(params.data[8], params.data[9], params.data[10], params.data[11]),
			vec4(params.data[12], params.data[13], params.data[14], params.data[15]));

	vec2 origin = vec2(chunk) * region_size + vec2(page) * page_world;
	vec2 screen_min = vec2(1e9);
	vec2 screen_max = vec2(-1e9);
	for (int i = 0; i < 4; i++) {
		vec2 corner = origin + vec2(float(i & 1), float((i >> 1) & 1)) * page_world;
		vec4 clip = vp * vec4(corner.x, 0.0, corner.y, 1.0);
		if (clip.w <= 0.0) {
			// Any corner behind the camera means the projection is unusable.
			imageStore(u_output, id, uvec4(REJECT_BEHIND));
			return;
		}
		vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;
		screen_min = min(screen_min, uv);
		screen_max = max(screen_max, uv);
	}

	// Off screen entirely.
	if (screen_max.x < 0.0 || screen_max.y < 0.0 || screen_min.x > 1.0 || screen_min.y > 1.0) {
		imageStore(u_output, id, uvec4(REJECT_OFFSCREEN));
		return;
	}

	vec2 extent_px = max(screen_max - screen_min, vec2(0.0)) * vec2(params.data[25], params.data[26]);
	float extent = max(extent_px.x, extent_px.y);
	if (extent < params.data[27]) {
		// Too small on screen for the virtual texture to be worth a page.
		imageStore(u_output, id, uvec4(REJECT_TOO_SMALL));
		return;
	}

	// One page texel per screen pixel is mip 0; every halving of the screen extent
	// needs one coarser mip.
	int mip = int(floor(log2(max(page_size / extent, 1.0))));
	mip = clamp(mip, 0, max_local_mip);
	imageStore(u_output, id, uvec4(uint(mip) + 1u));
}
)";

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DVTFeedback::_free_rd_resources() {
	if (!_rd) {
		return;
	}
	if (_uniform_set.is_valid()) {
		_rd->free_rid(_uniform_set);
		_uniform_set = RID();
	}
	if (_params.is_valid()) {
		_rd->free_rid(_params);
		_params = RID();
	}
	if (_texture.is_valid()) {
		_rd->free_rid(_texture);
		_texture = RID();
	}
	if (_pipeline.is_valid()) {
		_rd->free_rid(_pipeline);
		_pipeline = RID();
	}
	if (_shader.is_valid()) {
		_rd->free_rid(_shader);
		_shader = RID();
	}
}

void Terrain3DVTFeedback::_on_readback(const PackedByteArray &p_data) {
	_readback_pending = false;
	_readback_count++;
	_result = p_data;
	_decode();
}

void Terrain3DVTFeedback::_decode() {
	const int count = _grid_width * _grid_height;
	_mips.assign(count, -1);
	_request_count = 0;
	if (_result.size() < int64_t(count) * 4) {
		LOG(WARN, "Feedback readback is ", _result.size(), " bytes, expected ", int64_t(count) * 4);
		return;
	}
	for (int i = 0; i < count; i++) {
		const uint32_t packed = _result.decode_u32(int64_t(i) * 4);
		if (packed == NO_REQUEST || packed == 0u) {
			continue;
		}
		if (packed >= REJECT_TOO_SMALL) {
			// One of the diagnostic early-outs. The sentinels are the *smallest* of the
			// reserved values, so this single comparison catches all three.
			continue;
		}
		_mips[i] = int(packed) - 1;
		_request_count++;
	}
}

///////////////////////////
// Public Functions
///////////////////////////

Error Terrain3DVTFeedback::initialize(const int p_grid_width, const int p_grid_height) {
	clear();
	if (p_grid_width <= 0 || p_grid_height <= 0) {
		LOG(ERROR, "Feedback grid must be positive, got ", p_grid_width, "x", p_grid_height);
		return ERR_INVALID_PARAMETER;
	}
	_rd = RenderingServer::get_singleton()->create_local_rendering_device();
	if (!_rd) {
		LOG(ERROR, "Could not create a local rendering device for the feedback pass");
		return ERR_CANT_CREATE;
	}

	Ref<RDShaderSource> source;
	source.instantiate();
	source->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
	source->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, VT_FEEDBACK_SHADER);
	Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(source);
	if (spirv.is_null()) {
		LOG(ERROR, "Feedback shader did not compile");
		clear();
		return ERR_CANT_CREATE;
	}
	const String compile_error = spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE);
	if (!compile_error.is_empty()) {
		LOG(ERROR, "Feedback shader compile error: ", compile_error);
		clear();
		return ERR_CANT_CREATE;
	}
	_shader = _rd->shader_create_from_spirv(spirv, "terrain3d_vt_feedback");
	if (!_shader.is_valid()) {
		LOG(ERROR, "Could not create the feedback shader");
		clear();
		return ERR_CANT_CREATE;
	}
	_pipeline = _rd->compute_pipeline_create(_shader);
	if (!_pipeline.is_valid()) {
		LOG(ERROR, "Could not create the feedback compute pipeline");
		clear();
		return ERR_CANT_CREATE;
	}

	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
	format->set_format(RenderingDevice::DATA_FORMAT_R32_UINT);
	format->set_width(uint32_t(p_grid_width));
	format->set_height(uint32_t(p_grid_height));
	format->set_depth(1);
	format->set_array_layers(1);
	format->set_mipmaps(1);
	format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	// Seed with a known pattern: if the readback ever returns these values the compute
	// pass is not writing, and if it returns zeros the readback itself is broken.
	PackedByteArray seed;
	seed.resize(int64_t(p_grid_width) * p_grid_height * 4);
	for (int i = 0; i < p_grid_width * p_grid_height; i++) {
		seed.encode_u32(int64_t(i) * 4, 0x5A5A0000u + uint32_t(i));
	}
	TypedArray<PackedByteArray> initial;
	initial.push_back(seed);
	_texture = _rd->texture_create(format, view, initial);
	if (!_texture.is_valid()) {
		LOG(ERROR, "Could not create the feedback texture");
		clear();
		return ERR_CANT_CREATE;
	}

	// 16 matrix floats + 12 parameters.
	PackedByteArray params;
	params.resize(28 * 4);
	_params = _rd->storage_buffer_create(uint32_t(params.size()), params);
	if (!_params.is_valid()) {
		LOG(ERROR, "Could not create the feedback parameter buffer");
		clear();
		return ERR_CANT_CREATE;
	}

	TypedArray<Ref<RDUniform>> uniforms;
	Ref<RDUniform> image_uniform;
	image_uniform.instantiate();
	image_uniform->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
	image_uniform->set_binding(0);
	image_uniform->add_id(_texture);
	uniforms.push_back(image_uniform);
	Ref<RDUniform> params_uniform;
	params_uniform.instantiate();
	params_uniform->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	params_uniform->set_binding(1);
	params_uniform->add_id(_params);
	uniforms.push_back(params_uniform);
	_uniform_set = _rd->uniform_set_create(uniforms, _shader, 0);
	if (!_uniform_set.is_valid()) {
		LOG(ERROR, "Could not create the feedback uniform set");
		clear();
		return ERR_CANT_CREATE;
	}

	_grid_width = p_grid_width;
	_grid_height = p_grid_height;
	_mips.assign(_grid_width * _grid_height, -1);
	LOG(INFO, "VT feedback initialized: ", _grid_width, "x", _grid_height, " pages");
	return OK;
}

void Terrain3DVTFeedback::clear() {
	if (_rd) {
		if (_submitted || _dispatched) {
			// Complete any outstanding frame before tearing the resources down.
			_rd->submit();
			_rd->sync();
		}
		_free_rd_resources();
		memdelete(_rd);
		_rd = nullptr;
	}
	_dispatched = false;
	_submitted = false;
	_grid_width = 0;
	_grid_height = 0;
	_readback_pending = false;
	_result.clear();
	_mips.clear();
	_request_count = 0;
}

Error Terrain3DVTFeedback::dispatch(const Projection &p_view_projection, const int p_pages_per_axis,
		const real_t p_region_size, const real_t p_page_world_size, const int p_page_size,
		const int p_max_local_mip, const Vector2i &p_chunk_origin, const Vector2i &p_viewport_size,
		const real_t p_min_screen_extent) {
	if (!is_initialized()) {
		return ERR_UNCONFIGURED;
	}
	// A local device cannot have two submits outstanding: the previous frame has to be
	// completed before another dispatch.
	if (_submitted || _dispatched) {
		sync();
	}
	PackedByteArray params;
	params.resize(28 * 4);
	for (int i = 0; i < 4; i++) {
		const Vector4 column = p_view_projection.columns[i];
		params.encode_float(int64_t(i * 4 + 0) * 4, column.x);
		params.encode_float(int64_t(i * 4 + 1) * 4, column.y);
		params.encode_float(int64_t(i * 4 + 2) * 4, column.z);
		params.encode_float(int64_t(i * 4 + 3) * 4, column.w);
	}
	params.encode_float(16 * 4, real_t(_grid_width));
	params.encode_float(17 * 4, real_t(_grid_height));
	params.encode_float(18 * 4, real_t(p_pages_per_axis));
	params.encode_float(19 * 4, p_region_size);
	params.encode_float(20 * 4, p_page_world_size);
	params.encode_float(21 * 4, real_t(p_page_size));
	params.encode_float(22 * 4, real_t(p_max_local_mip));
	params.encode_float(23 * 4, real_t(p_chunk_origin.x));
	params.encode_float(24 * 4, real_t(p_chunk_origin.y));
	params.encode_float(25 * 4, real_t(p_viewport_size.x));
	params.encode_float(26 * 4, real_t(p_viewport_size.y));
	params.encode_float(27 * 4, p_min_screen_extent);
	_rd->buffer_update(_params, 0, uint32_t(params.size()), params);

	const int64_t list = _rd->compute_list_begin();
	_rd->compute_list_bind_compute_pipeline(list, _pipeline);
	_rd->compute_list_bind_uniform_set(list, _uniform_set, 0);
	_rd->compute_list_dispatch(list, (uint32_t(_grid_width) + 7) / 8, (uint32_t(_grid_height) + 7) / 8, 1);
	_rd->compute_list_end();
	// Deliberately no submit here: request_readback() registers the texture copy as a
	// draw graph node, and a node only runs in _execute_frame. Recording everything
	// first and submitting once in sync() is what makes the copy part of the same
	// executed frame; submitting here would end the graph before the copy is added.
	_dispatched = true;
	_dispatch_count++;
	return OK;
}

Error Terrain3DVTFeedback::request_readback() {
	if (!is_initialized()) {
		return ERR_UNCONFIGURED;
	}
	if (_readback_pending) {
		return OK;
	}
	const Error err = _rd->texture_get_data_async(_texture, 0,
			callable_mp(this, &Terrain3DVTFeedback::_on_readback));
	if (err != OK) {
		LOG(WARN, "Feedback readback request failed: ", err);
		return err;
	}
	_readback_pending = true;
	return OK;
}

Error Terrain3DVTFeedback::sync() {
	if (!is_initialized()) {
		return OK;
	}
	if (!_dispatched && !_readback_pending) {
		return OK;
	}
	// Submit executes the compute dispatch and the texture copy together, then sync
	// stalls the frame, which is where the download is transferred and its callback
	// is invoked.
	_rd->submit();
	_submitted = true;
	_rd->sync();
	_submitted = false;
	_dispatched = false;
	return OK;
}

int Terrain3DVTFeedback::get_mip(const int p_grid_x, const int p_grid_y) const {
	if (p_grid_x < 0 || p_grid_y < 0 || p_grid_x >= _grid_width || p_grid_y >= _grid_height) {
		return -1;
	}
	const size_t index = size_t(p_grid_y) * _grid_width + p_grid_x;
	if (index >= _mips.size()) {
		return -1;
	}
	return _mips[index];
}

uint32_t Terrain3DVTFeedback::get_raw(const int p_grid_x, const int p_grid_y) const {
	if (p_grid_x < 0 || p_grid_y < 0 || p_grid_x >= _grid_width || p_grid_y >= _grid_height) {
		return NO_REQUEST;
	}
	const size_t index = size_t(p_grid_y) * _grid_width + p_grid_x;
	if (index >= _mips.size() || _result.size() < int64_t(index + 1) * 4) {
		return NO_REQUEST;
	}
	return _result.decode_u32(int64_t(index) * 4);
}

int Terrain3DVTFeedback::get_mip_for_page(const Vector2i &p_chunk, const int p_pages_per_axis,
		const int p_page_x, const int p_page_y, const Vector2i &p_chunk_origin) const {
	const Vector2i local = p_chunk - p_chunk_origin;
	if (local.x < 0 || local.y < 0 || p_page_x < 0 || p_page_y < 0) {
		return -1;
	}
	const int gx = local.x * p_pages_per_axis + p_page_x;
	const int gy = local.y * p_pages_per_axis + p_page_y;
	return get_mip(gx, gy);
}

Dictionary Terrain3DVTFeedback::get_stats() const {
	Dictionary stats;
	stats["grid_width"] = _grid_width;
	stats["grid_height"] = _grid_height;
	stats["initialized"] = is_initialized();
	stats["dispatch_count"] = _dispatch_count;
	stats["readback_count"] = _readback_count;
	stats["readback_pending"] = _readback_pending;
	stats["has_result"] = has_result();
	stats["request_count"] = _request_count;
	stats["grid_cells"] = _grid_width * _grid_height;
	return stats;
}

void Terrain3DVTFeedback::reset_stats() {
	_dispatch_count = 0;
	_readback_count = 0;
}

///////////////////////////
// Bindings
///////////////////////////

void Terrain3DVTFeedback::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initialize", "grid_width", "grid_height"), &Terrain3DVTFeedback::initialize);
	ClassDB::bind_method(D_METHOD("clear"), &Terrain3DVTFeedback::clear);
	ClassDB::bind_method(D_METHOD("is_initialized"), &Terrain3DVTFeedback::is_initialized);
	ClassDB::bind_method(D_METHOD("dispatch", "view_projection", "pages_per_axis", "region_size",
								 "page_world_size", "page_size", "max_local_mip", "chunk_origin",
								 "viewport_size", "min_screen_extent"),
			&Terrain3DVTFeedback::dispatch, DEFVAL(DEFAULT_MIN_SCREEN_EXTENT));
	ClassDB::bind_method(D_METHOD("request_readback"), &Terrain3DVTFeedback::request_readback);
	ClassDB::bind_method(D_METHOD("sync"), &Terrain3DVTFeedback::sync);
	ClassDB::bind_method(D_METHOD("is_readback_pending"), &Terrain3DVTFeedback::is_readback_pending);
	ClassDB::bind_method(D_METHOD("has_result"), &Terrain3DVTFeedback::has_result);
	ClassDB::bind_method(D_METHOD("get_mip", "grid_x", "grid_y"), &Terrain3DVTFeedback::get_mip);
	ClassDB::bind_method(D_METHOD("get_raw", "grid_x", "grid_y"), &Terrain3DVTFeedback::get_raw);
	ClassDB::bind_method(D_METHOD("get_mip_for_page", "chunk", "pages_per_axis", "page_x", "page_y", "chunk_origin"),
			&Terrain3DVTFeedback::get_mip_for_page);
	ClassDB::bind_method(D_METHOD("get_request_count"), &Terrain3DVTFeedback::get_request_count);
	ClassDB::bind_method(D_METHOD("get_grid_width"), &Terrain3DVTFeedback::get_grid_width);
	ClassDB::bind_method(D_METHOD("get_grid_height"), &Terrain3DVTFeedback::get_grid_height);
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DVTFeedback::get_stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &Terrain3DVTFeedback::reset_stats);
}
