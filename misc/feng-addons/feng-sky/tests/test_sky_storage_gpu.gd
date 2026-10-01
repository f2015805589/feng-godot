extends SceneTree
## Execute the production engine's final sky scaling/storage-boundary code in
## float32 storage so a driver that saturates half-float stores cannot hide overflow.
var failed := false
func _initialize() -> void:
	call_deferred("run")
func require(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error("REGRESSION: " + message)
func run() -> void:
	var path := OS.get_environment("FRP_ENGINE_SOURCE_ROOT").path_join("servers/rendering/renderer_rd/shaders/environment/sky.glsl")
	var text := FileAccess.get_file_as_string(path)
	var marker := text.find("// For mobile renderer we're multiplying")
	require(marker >= 0, "production sky storage boundary not found")
	if failed:
		quit(1)
		return
	var footer := text.substr(marker).strip_edges()
	footer = footer.substr(0, footer.rfind("}"))
	var brightness := "frag_color.rgb = frag_color.rgb * params.brightness_multiplier;"
	var scope := "\n#if 1\n" if footer.contains("#endif // Main pass or legacy scaled subpasses.") else ""
	require(text.contains(brightness), "production brightness step changed")
	var rd := RenderingServer.create_local_rendering_device()
	require(rd != null, "requires a real RenderingDevice")
	if failed:
		quit(1)
		return
	var code := RDShaderSource.new()
	code.source_compute = """#version 450
layout(local_size_x=1) in;
layout(set=0,binding=0,std430) readonly buffer Inputs { vec4 input_data[]; };
layout(set=0,binding=1,std430) writeonly buffer Outputs { vec4 output_data[]; };
struct SkyParams {float brightness_multiplier; float luminance_multiplier;};
const bool AT_CUBEMAP_PASS=false, AT_HALF_RES_PASS=false, AT_QUARTER_RES_PASS=false;
void main() {
 uint i=gl_GlobalInvocationID.x;
 vec4 frag_color=vec4(input_data[i*2].rgb,1.0);
 SkyParams params; params.brightness_multiplier=input_data[i*2].a; params.luminance_multiplier=input_data[i*2+1].x;
""" + brightness + scope + footer + "\noutput_data[i]=frag_color;\n}\n"
	var spirv := rd.shader_compile_spirv_from_source(code)
	require(spirv.compile_error_compute.is_empty(), spirv.compile_error_compute)
	if failed:
		rd.free()
		quit(1)
		return
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var inputs := PackedFloat32Array()
	var expected: Array[float] = []
	for gain in [0.0, 0.001, 1.0, 2.0, 65536.0, 1e12]:
		for source in [0.0, 1.0, 100.0, 60000.0]:
			inputs.append_array(PackedFloat32Array([source, source, source, gain, 2.0, 0.0, 0.0, 0.0]))
			expected.append(minf(source * gain * 2.0, 65504.0))
	var input := rd.storage_buffer_create(inputs.size()*4, inputs.to_byte_array())
	var output := rd.storage_buffer_create(expected.size()*16)
	var uniforms: Array[RDUniform] = []
	for i in 2:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = i
		uniform.add_id(input if i == 0 else output)
		uniforms.append(uniform)
	var bindings := rd.uniform_set_create(uniforms, shader, 0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, bindings, 0)
	rd.compute_list_dispatch(list, expected.size(), 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var actual := rd.buffer_get_data(output).to_float32_array()
	var violations := 0
	for i in expected.size():
		for channel in 3:
			var value := actual[i*4+channel]
			if not is_finite(value) or value < 0.0 or value > 65504.0 or absf(value - expected[i]) > maxf(0.01, expected[i]*0.000001):
				violations += 1
	require(violations == 0, "post-scale sky overflow before FP16 write: %d channels" % violations)
	print("SKY STORAGE GPU cases=", expected.size(), " float32_pre_store_violations=", violations)
	for rid in [bindings, output, input, pipeline, shader]:
		rd.free_rid(rid)
	rd.free()
	if not failed:
		print("SKY STORAGE GPU PASS")
	quit(1 if failed else 0)
