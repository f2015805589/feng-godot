extends SceneTree
## Validate the GPU relighting stage against an independent scalar CPU integral.

const RelightShader = preload("res://addons/feng-render-pipeline/library/magic-gi/magic_gi_relight.glsl")
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const COUNT := 65 # Cross both atlas-row and compute-workgroup boundaries.

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Relight validation requires a real RenderingDevice.")
		quit(1)
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 73041
	var transfer := PackedFloat32Array()
	var primary := PackedFloat32Array()
	var emission := PackedFloat32Array()
	transfer.resize(224 * 3 * 4)
	primary.resize(96 * 3 * 4)
	emission.resize(32 * 3 * 4)
	var parameters := PackedFloat32Array()
	parameters.resize(112)
	parameters[51] = COUNT
	for i in 27:
		parameters[56 + i] = rng.randf_range(-2.0, 4.0) * 60000.0
		parameters[84 + i] = rng.randf_range(-1.0, 3.0) * 10000.0
	var expected := PackedFloat64Array()
	expected.resize(COUNT * 8)
	for probe in COUNT:
		var transfer_base := (probe / 32 * 224 + probe % 32 * 7) * 4
		var primary_base := (probe / 32 * 96 + probe % 32 * 3) * 4
		var emission_base := probe * 4
		for k in 9:
			primary[primary_base + k] = rng.randf_range(-1.0, 1.0)
			for channel in 3:
				transfer[transfer_base + k * 3 + channel] = rng.randf_range(-1.0, 1.0)
				expected[probe * 8 + channel] += float(transfer[transfer_base + k * 3 + channel]) * parameters[56 + k * 3 + channel]
				expected[probe * 8 + 4 + channel] += float(primary[primary_base + k]) / PI * parameters[84 + k * 3 + channel]
		for channel in 3:
			emission[emission_base + channel] = rng.randf_range(-1.0, 10.0)
			expected[probe * 8 + channel] = maxf(expected[probe * 8 + channel], 0.0) + maxf(emission[emission_base + channel], 0.0)
			expected[probe * 8 + 4 + channel] = maxf(expected[probe * 8 + 4 + channel], 0.0)
	var textures: Array[RID] = []
	for spec in [[224, transfer], [96, primary], [32, emission]]:
		var format := RDTextureFormat.new()
		format.width = spec[0]
		format.height = 3
		format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		textures.append(rd.texture_create(format, RDTextureView.new(), [spec[1].to_byte_array()]))
	var initial := PackedByteArray()
	initial.resize(128 * 32)
	initial.fill(0xcd)
	var output := rd.storage_buffer_create(initial.size(), initial)
	var ubo := rd.uniform_buffer_create(448, parameters.to_byte_array())
	var sampler := rd.sampler_create(RDSamplerState.new())
	var shader := rd.shader_create_from_spirv(RelightShader.get_spirv())
	var pipeline := rd.compute_pipeline_create(shader)
	var uniform_set := rd.uniform_set_create([
		U.sampled(0, sampler, textures[0]), U.sampled(1, sampler, textures[1]),
		U.sampled(2, sampler, textures[2]), U.uniform_buffer(3, ubo), U.storage_buffer(4, output),
	], shader, 0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, 2, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var bytes := rd.buffer_get_data(output)
	var actual := bytes.to_float32_array()
	var failures := 0
	var maximum_error := 0.0
	for i in expected.size():
		var error := absf(actual[i] - expected[i]) / maxf(1.0, absf(expected[i]))
		maximum_error = maxf(maximum_error, error)
		if not is_finite(actual[i]) or error > 0.0001:
			failures += 1
	if bytes.slice(COUNT * 32) != initial.slice(COUNT * 32):
		failures += 1
	for rid in [uniform_set, pipeline, shader, sampler, ubo, output] + textures:
		rd.free_rid(rid)
	rd.free()
	print("MAGIC_GI_RELIGHT values=", expected.size(), " max_relative_error=", maximum_error, " failures=", failures)
	quit(1 if failures else 0)
