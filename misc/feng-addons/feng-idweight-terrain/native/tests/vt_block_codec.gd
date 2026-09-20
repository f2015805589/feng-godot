extends SceneTree
## Real GPU blocks decoded by the engine, including non-correlated endpoint data.
var failed := false
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var sampler: RID
var normal_binding := true

func _initialize() -> void:
	run.call_deferred()

func require(ok: bool, message: String) -> void:
	if not ok:
		push_error("REGRESSION: " + message)
		failed = true

func texture(image: Image) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.width = 4
	format.height = 4
	format.array_layers = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(format, RDTextureView.new(), [image.get_data()])

func encode(source: Image, normal: Image, codec: int, role: int = 0, layout: int = 0) -> Image:
	var src := texture(source)
	var nrm := texture(normal)
	var buffer := rd.storage_buffer_create(16)
	var uniforms: Array[RDUniform] = []
	for binding in ([0, 2] if normal_binding else [0]):
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = binding
		uniform.add_id(sampler)
		uniform.add_id(src if binding == 0 else nrm)
		uniforms.append(uniform)
	var output := RDUniform.new()
	output.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output.binding = 1
	output.add_id(buffer)
	uniforms.append(output)
	var set := rd.uniform_set_create(uniforms, shader, 0)
	var push := PackedByteArray()
	push.resize(32)
	push.encode_u32(0, 4)
	push.encode_u32(8, codec)
	push.encode_u32(12, 1)
	push.encode_u32(24, role)
	push.encode_u32(28, layout)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_set_push_constant(list, push, 32)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var bytes := rd.buffer_get_data(buffer)
	var format := Image.FORMAT_DXT5 if codec == 1 else (Image.FORMAT_RGTC_RG if codec == 3 else Image.FORMAT_BPTC_RGBA)
	var image := Image.create_from_data(4, 4, false, format, bytes)
	require(image.decompress() == OK, "engine must decode GPU block")
	for rid in [set, buffer, src, nrm]:
		rd.free_rid(rid)
	return image

func decode_normal(color: Color, layout: int) -> Vector3:
	var f := Vector2(color.r if layout == 1 else color.a, color.g) * 2.0 - Vector2.ONE
	var n := Vector3(f.x, f.y, 1.0 - absf(f.x) - absf(f.y))
	var t := clampf(-n.z, 0.0, 1.0)
	n.x += -t if n.x >= 0.0 else t
	n.y += -t if n.y >= 0.0 else t
	return Vector3(n.x, n.z, n.y).normalized()

func run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		require(false, "GPU RenderingDevice is required")
		quit(1)
		return
	var source := FileAccess.get_file_as_string("res://bc_encode_source.txt").replace("\r\n", "\n").strip_edges()
	source = source.trim_prefix('R"(').trim_suffix(')"').replace(')"\nR"(', '')
	normal_binding = source.contains("encode_normal_source")
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = source
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	require(spirv.compile_error_compute == "", spirv.compile_error_compute)
	if failed:
		quit(1)
		return
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	sampler = rd.sampler_create(RDSamplerState.new())
	var pattern := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	for y in 4:
		for x in 4:
			var index := y * 4 + x
			pattern.set_pixel(x, y, Color(1.0 if index % 2 else 0.0, 0.0 if index % 2 else 1.0, 0.0, float(index) / 15.0))
	for codec in [1, 4]:
		var decoded := encode(pattern, pattern, codec)
		var rgb_error := 0.0
		var tail_error := 0.0
		for y in 4:
			for x in 4:
				var a := pattern.get_pixel(x, y)
				var b := decoded.get_pixel(x, y)
				rgb_error = maxf(rgb_error, maxf(absf(a.r-b.r), absf(a.g-b.g)))
				if y * 4 + x >= 11:
					tail_error = maxf(tail_error, absf(a.a-b.a))
		print("VT_BLOCK codec=%d anticorrelated_rgb_max=%.5f alpha_tail_max=%.5f" % [codec, rgb_error, tail_error])
		require(rgb_error < 0.10, "opposing colours must not collapse to the bounding-box diagonal")
		if codec == 1:
			require(tail_error < 0.08, "BC3 alpha indices 11-15 must survive the 32-bit boundary")
		else:
			require(tail_error < 0.18, "BC7 must select an independent alpha stream when colour and alpha disagree")
	# A smooth colour ramp should exploit BC7's extra levels rather than looking
	# like the four-colour BC3 palette. The reference is the actual input texels.
	for y in 4:
		for x in 4:
			var t := float(y * 4 + x) / 15.0
			pattern.set_pixel(x, y, Color(0.05 + t * 0.9, 0.8 - t * 0.6, 0.03 + t * 0.7, 1.0))
	var errors := {}
	for codec in [1, 4]:
		var decoded := encode(pattern, pattern, codec)
		var mse := 0.0
		for y in 4:
			for x in 4:
				var a := pattern.get_pixel(x, y)
				var b := decoded.get_pixel(x, y)
				mse += pow(a.r-b.r, 2) + pow(a.g-b.g, 2) + pow(a.b-b.b, 2)
		errors[codec] = mse / 48.0
		print("VT_BLOCK smooth_rgb codec=%d mse=%.8f" % [codec, errors[codec]])
	require(float(errors[4]) < float(errors[1]) * 0.4, "BC7 smooth colour precision must exceed BC3")
	var params := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	params.fill(Color(1.8, 0.65, 0.25, 1.0))
	for y in 4:
		for x in 4:
			pattern.set_pixel(x, y, Color(-0.3, 0.9, -0.2, float(y*4+x)/15.0))
	var packed_params := encode(params, pattern, 4, 2)
	var rough_error := 0.0
	for y in 4:
		for x in 4:
			var value := packed_params.get_pixel(x, y)
			require(value.a >= 0.49, "valid roughness zero must not become a missing page")
			require(absf(value.r * 2.0 - 1.8) < 0.03, "normal depth above one must not clamp during compression")
			rough_error = maxf(rough_error, absf(value.a * 2.0 - 1.0 - pattern.get_pixel(x,y).a))
	print("VT_BLOCK roughness_max=%.5f" % rough_error)
	require(rough_error < 0.08, "roughness must survive two-channel normal storage")
	params.fill(Color(0,0,0,0))
	var invalid := encode(params, pattern, 4, 2)
	require(invalid.get_pixel(2,3).a < 0.49, "invalid material sentinel must survive parameter packing")
	# Positive and negative world components, including the lower hemisphere.
	for direction in [Vector3(-0.6, 0.7, -0.3), Vector3(0.4, 0.5, -0.8), Vector3(-0.3, -0.9, 0.2)]:
		var target: Vector3 = direction.normalized()
		pattern.fill(Color(target.x, target.y, target.z, 0.3))
		for layout in [1, 2]:
			var decoded := encode(pattern, pattern, 3 if layout == 1 else 1, 1, layout)
			var angle := rad_to_deg(acos(clampf(target.dot(decode_normal(decoded.get_pixel(2, 3), layout)), -1.0, 1.0)))
			print("VT_BLOCK normal=%s layout=%d angle_degrees=%.5f" % [target, layout, angle])
			require(angle < 3.0, "compressed signed world normals must preserve their direction")
	for rid in [sampler, pipeline, shader]:
		rd.free_rid(rid)
	rd.free()
	if not failed:
		print("PASS GPU blocks preserve alpha indices, colour direction and signed normals")
	quit(1 if failed else 0)
