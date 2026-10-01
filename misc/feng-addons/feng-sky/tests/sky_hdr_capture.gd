extends "res://addons/feng-render-pipeline/passes/pass_base.gd"
## Test-only synchronous GPU readback. Never insert this pass in a timing interval.
signal captured(values: PackedFloat32Array)
var requested := false
var last_pre_exposure := 1.0
func _frp_execute(ctx: FRPPassContext) -> void:
	if not requested:
		return
	requested = false
	last_pre_exposure = ctx.get_pre_exposure(0)
	var rd := RenderingServer.get_rendering_device()
	var rb := ctx.get_render_scene_buffers()
	var extent := rb.get_internal_size()
	var source := RDShaderSource.new()
	source.source_compute = """#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(rgba16f,set=0,binding=0) uniform readonly image2D input_color;
layout(set=0,binding=1,std430) writeonly buffer Results { vec4 values[]; } result;
void main() {
 ivec2 p=ivec2(gl_GlobalInvocationID.xy), size=imageSize(input_color);
 if(any(greaterThanEqual(p,size))) return;
 result.values[p.y*size.x+p.x]=imageLoad(input_color,p);
}
"""
	var spirv := rd.shader_compile_spirv_from_source(source)
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var buffer := rd.storage_buffer_create(extent.x * extent.y * 16)
	var input := RDUniform.new()
	input.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	input.binding = 0
	input.add_id(rb.get_color_layer(0))
	var output := RDUniform.new()
	output.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output.binding = 1
	output.add_id(buffer)
	var bindings := rd.uniform_set_create([input, output], shader, 0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, bindings, 0)
	rd.compute_list_dispatch(list, ceili(extent.x / 8.0), ceili(extent.y / 8.0), 1)
	rd.compute_list_end()
	var values := rd.buffer_get_data(buffer).to_float32_array()
	for rid in [bindings, buffer, pipeline, shader]:
		rd.free_rid(rid)
	_deliver.call_deferred(values)
func _deliver(values: PackedFloat32Array) -> void:
	captured.emit(values)
