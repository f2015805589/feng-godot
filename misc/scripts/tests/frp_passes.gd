extends SceneTree

const FRP_PASS = preload("res://addons/feng-render-pipeline/passes/shader_pass.gd")
const FRP_BASE = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const FRP_TEXTURE = preload("res://addons/feng-render-pipeline/passes/pass_texture.gd")
const FRP_OUTPUT = preload("res://addons/feng-render-pipeline/passes/pass_output.gd")
const FRP_MANAGER = preload("res://addons/feng-render-pipeline/passes/texture_manager.gd")

class PaintPass extends FRP_BASE:
	var color := Color.GREEN
	var calls := 0
	func _init(stage: int, value: Color) -> void:
		self.stage = stage
		effect_callback_type = stage
		color = value

	func _render_callback(_stage: int, data: RenderData) -> void:
		calls += 1
		if calls == 4 and effect_callback_type == EFFECT_CALLBACK_TYPE_POST_GBUFFER:
			var b: RenderSceneBuffersRD = data.get_render_scene_buffers()
			var rd := RenderingServer.get_rendering_device()
			var source := RDShaderSource.new()
			source.source_compute = "#version 450\nlayout(local_size_x=1) in; layout(set=0,binding=0) uniform sampler2D a; layout(set=0,binding=1) uniform sampler2D o; layout(set=0,binding=2) uniform sampler2D n; layout(set=0,binding=3) uniform sampler2D d; layout(set=0,binding=4,std430) buffer Result {vec4 v[4];} result; void main(){ivec2 p=textureSize(a,0)/2; result.v[0]=texelFetch(a,p,0); result.v[1]=texelFetch(o,p,0); result.v[2]=texelFetch(n,p,0); result.v[3]=texelFetch(d,p,0);}"
			var shader := rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(source))
			var pipeline := rd.compute_pipeline_create(shader)
			var sampler := rd.sampler_create(RDSamplerState.new())
			var output := rd.storage_buffer_create(64)
			var bindings: Array[RDUniform] = []
			var inputs = [b.get_texture("frp_clustered", "gbuffer_albedo"), b.get_texture("frp_clustered", "gbuffer_orm"), b.get_texture("frp_clustered", "normal_roughness"), b.get_depth_texture()]
			for i in 4:
				var u := RDUniform.new()
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				u.binding = i
				u.add_id(sampler)
				u.add_id(inputs[i])
				bindings.append(u)
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.binding = 4
			u.add_id(output)
			bindings.append(u)
			var uniform_set := rd.uniform_set_create(bindings, shader, 0)
			var list := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list,pipeline)
			rd.compute_list_bind_uniform_set(list,uniform_set,0)
			rd.compute_list_dispatch(list,1,1,1)
			rd.compute_list_end()
			print("GBUFFER a/o/n/d ", rd.buffer_get_data(output).to_float32_array())
			rd.free_rid(shader)
			rd.free_rid(sampler)
			rd.free_rid(output)
		if effect_callback_type == EFFECT_CALLBACK_TYPE_PRE_LIGHTING:
			var buffers: RenderSceneBuffersRD = data.get_render_scene_buffers()
			var texture := buffers.get_texture("frp_clustered", "gbuffer_albedo")
			var rd := RenderingServer.get_rendering_device()
			var fb := rd.framebuffer_create([texture])
			rd.draw_list_begin(fb, RenderingDevice.DRAW_CLEAR_COLOR_0, [color])
			rd.draw_list_end()
			rd.free_rid(fb)

class GBufferProbePass extends FRP_BASE:
	var captures := 0
	var sample := PackedFloat32Array()

	func _init() -> void:
		stage = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_GBUFFER
		effect_callback_type = stage

	func reset() -> void:
		captures = 0
		sample = PackedFloat32Array()

	func _render_callback(callback_stage: int, data: RenderData) -> void:
		if callback_stage != effect_callback_type or data == null or captures > 0:
			return
		var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
		if buffers == null:
			return
		var rd := RenderingServer.get_rendering_device()
		var albedo := buffers.get_texture("frp_clustered", "gbuffer_albedo")
		var normal := buffers.get_texture("frp_clustered", "normal_roughness")
		var depth := buffers.get_depth_texture()
		if rd == null or not albedo.is_valid() or not normal.is_valid() or not depth.is_valid():
			return

		var source := RDShaderSource.new()
		source.source_compute = "#version 450\nlayout(local_size_x=1) in; layout(set=0,binding=0) uniform sampler2D albedo_tex; layout(set=0,binding=1) uniform sampler2D normal_tex; layout(set=0,binding=2) uniform sampler2D depth_tex; layout(set=0,binding=3,std430) buffer Result {vec4 values[3];} result; void main(){ivec2 p=textureSize(albedo_tex,0)/2; result.values[0]=texelFetch(albedo_tex,p,0); result.values[1]=texelFetch(normal_tex,p,0); result.values[2]=texelFetch(depth_tex,p,0); }"
		var shader := rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(source))
		if not shader.is_valid():
			return
		var pipeline := rd.compute_pipeline_create(shader)
		var sampler := rd.sampler_create(RDSamplerState.new())
		var output := rd.storage_buffer_create(48)
		var bindings: Array[RDUniform] = []
		var inputs := [albedo, normal, depth]
		for i in 3:
			var input := RDUniform.new()
			input.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			input.binding = i
			input.add_id(sampler)
			input.add_id(inputs[i])
			bindings.append(input)
		var result_uniform := RDUniform.new()
		result_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		result_uniform.binding = 3
		result_uniform.add_id(output)
		bindings.append(result_uniform)
		var uniform_set := rd.uniform_set_create(bindings, shader, 0)
		if not pipeline.is_valid() or not uniform_set.is_valid():
			rd.free_rid(uniform_set)
			rd.free_rid(output)
			rd.free_rid(sampler)
			rd.free_rid(pipeline)
			rd.free_rid(shader)
			return
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_dispatch(list, 1, 1, 1)
		rd.compute_list_end()
		sample = rd.buffer_get_data(output).to_float32_array()
		captures = 1
		rd.free_rid(uniform_set)
		rd.free_rid(output)
		rd.free_rid(sampler)
		rd.free_rid(pipeline)
		rd.free_rid(shader)

class ScreenPaintPass extends FRP_BASE:
	var color := Color.GREEN
	var calls := 0

	func _init(stage: int, value: Color) -> void:
		self.stage = stage
		effect_callback_type = stage
		color = value

	func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
		calls += 1
		var target := buffers.get_color_layer(view)
		if not target.is_valid():
			return
		var framebuffer := rd.framebuffer_create([target])
		if not framebuffer.is_valid():
			return
		var list := rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_0, [color])
		rd.draw_list_end()
		rd.free_rid(framebuffer)

## Default native execution order. It is the engine's pass id order: shadow maps
## first (drawing them reads no scene depth and no material page), then the virtual
## textures, the G-buffer, lighting, sky, transparent, temporal AA and post.
const EXPECTED_NATIVE_ORDER := [0, 1, 2, 3, 4, 5, 6, 7]
const EXPECTED_NATIVE_COUNT := 8

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		quit(1)
		assert(value, message)

func _has_property(value: Object, property_name: String) -> bool:
	if value == null:
		return false
	for info in value.get_property_list():
		if str(info.get("name", "")) == property_name:
			return true
	return false

func _read_property(value: Object, property_name: String, fallback = null):
	if not _has_property(value, property_name):
		return fallback
	return value.get(property_name)

func _write_property(value: Object, property_name: String, new_value) -> bool:
	if not _has_property(value, property_name):
		return false
	value.set(property_name, new_value)
	return true

func _native_id(value: Object) -> int:
	var raw = _read_property(value, "native_id", -1)
	if raw is int:
		return raw
	return -1

func _pass_label(value: Object) -> String:
	# Keep this tolerant of the concrete resource implementation. Native pass
	# resources expose display_name, while Resource.resource_name is a useful
	# fallback for saved .tres versions of the same resource.
	for property_name in ["display_name", "pass_name", "label", "resource_name", "name"]:
		var raw = _read_property(value, property_name, "")
		if raw is String or raw is StringName:
			var label := str(raw)
			if not label.is_empty():
				return label
	return ""

func _library_key(value: Object) -> String:
	for property_name in ["library_path", "manifest_path", "source_path"]:
		var raw = _read_property(value, property_name, "")
		if raw is String or raw is StringName:
			if not str(raw).is_empty():
				return str(raw)
	var shader = _read_property(value, "shader_file", null)
	if shader is Resource:
		return shader.resource_path
	return ""

func _library_matches(value: Object, manifest_path: String) -> bool:
	var key := _library_key(value)
	if key.is_empty():
		return false
	var normalized_key := key.replace("\\", "/")
	var normalized_manifest := manifest_path.replace("\\", "/")
	if normalized_key.ends_with(normalized_manifest):
		return true
	# A shader-backed pass normally reports the .glsl path while the persisted
	# manifest records the companion .tres path.
	var shader_manifest := normalized_manifest
	if shader_manifest.ends_with(".tres"):
		shader_manifest = shader_manifest.trim_suffix(".tres") + ".glsl"
	return normalized_key.ends_with(shader_manifest)

func _native_passes(renderer: Object) -> Array[FRP_BASE]:
	var result: Array[FRP_BASE] = []
	for value in renderer.passes:
		if _native_id(value) >= 0:
			result.append(value)
	return result

func _native_schedule_base(renderer: Object) -> Array[FRP_BASE]:
	# Keep the renderer's library resources in the authored list so sync does
	# not treat them as user deletions. Disable them for tests whose output is
	# meant to isolate native scheduling.
	var result: Array[FRP_BASE] = []
	for value in renderer.passes:
		if _native_id(value) < 0:
			value.enabled = false
		result.append(value)
	return result

func _native_pass(renderer: Object, native_id: int):
	for value in renderer.passes:
		if _native_id(value) == native_id:
			return value
	return null

func _set_renderer_passes(renderer: Object, native_values: Array[FRP_BASE], custom_values: Array[FRP_BASE] = []) -> Array[FRP_BASE]:
	var values: Array[FRP_BASE] = []
	for value in native_values:
		# Custom effects need to run while the internal color buffer exists. The
		# temporal and tonemap operations are native 6 and 7, so put them just
		# before those operations by default.
		if _native_id(value) == 6:
			values.append_array(custom_values)
		values.append(value)
	if custom_values.size() > 0 and not values.has(custom_values[0]):
		values.append_array(custom_values)
	renderer.passes = values
	return values

func _clear_frp_pipeline(compositor: Compositor) -> void:
	if RenderingServer.has_method("compositor_set_frp_pipeline"):
		RenderingServer.call("compositor_set_frp_pipeline", compositor.get_rid(), PackedInt32Array())

func frame() -> Image:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	print("START Deferred GPU tests")
	var scene := Node3D.new()
	root.add_child(scene)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(0, 0, 5)
	camera.current = true
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	scene.add_child(box)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.RED
	box.material_override = material
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.02, 0.02, 0.02)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 1.0
	scene.add_child(environment)
	var compositor := Compositor.new()
	camera.compositor = compositor
	var green := PaintPass.new(CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_LIGHTING, Color.GREEN)
	var blue := PaintPass.new(CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_LIGHTING, Color.BLUE)
	var pre := PaintPass.new(CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_GBUFFER, Color.WHITE)
	var post := PaintPass.new(CompositorEffect.EFFECT_CALLBACK_TYPE_POST_GBUFFER, Color.WHITE)
	var lit := PaintPass.new(CompositorEffect.EFFECT_CALLBACK_TYPE_POST_LIGHTING, Color.WHITE)
	compositor.compositor_effects = [post]
	var image := await frame()
	print("FRAME opaque baseline")
	var center := Vector2i(image.get_width() / 2, image.get_height() / 2)
	require(image.get_pixelv(center).r > image.get_pixelv(center).g + 0.1, "opaque GBuffer material missing: %s" % image.get_pixelv(center))
	compositor.compositor_effects = [pre, post, green, blue, lit]
	image = await frame()
	require(image.get_pixelv(center).b > image.get_pixelv(center).g + 0.1, "last pass must write blue")
	require(pre.calls > 0 and post.calls > 0 and lit.calls > 0, "deferred callback stage not invoked")
	compositor.compositor_effects = [pre, post, blue, green, lit]
	image = await frame()
	require(image.get_pixelv(center).g > image.get_pixelv(center).b + 0.1, "reordered pass must write green")
	green.enabled = false
	image = await frame()
	require(image.get_pixelv(center).b > image.get_pixelv(center).g + 0.1, "disabled pass still runs")
	print("PASS Deferred stages, GBuffer access, ordered execution and disabled passes")
	compositor.compositor_effects = []
	for projection in [Camera3D.PROJECTION_PERSPECTIVE, Camera3D.PROJECTION_ORTHOGONAL]:
		camera.projection = projection
		camera.size = 4
		for msaa in [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X]:
			root.msaa_3d = msaa
			image = await frame()
			var pixel := image.get_pixelv(center)
			require(pixel.r > pixel.g + 0.1, "MSAA GBuffer material lost: %s/%s %s" % [projection, msaa, pixel])
			require(image.get_pixel(0, 0).r < 0.2, "background incorrectly lit")
	print("PASS perspective/orthographic, background, MSAA disabled/2x/4x")
	# Positional light falloff depends on reconstructed view-space depth.
	root.msaa_3d = Viewport.MSAA_DISABLED
	environment.environment.ambient_light_energy = 0.0
	var omni := OmniLight3D.new()
	omni.position = Vector3(0, 0, 3)
	omni.omni_range = 10.0
	omni.light_energy = 4.0
	scene.add_child(omni)
	for projection in [Camera3D.PROJECTION_PERSPECTIVE, Camera3D.PROJECTION_ORTHOGONAL]:
		camera.projection = projection
		image = await frame()
		require(image.get_pixelv(center).r > 0.1, "point light missing with reconstructed depth")
	omni.free()
	var area := AreaLight3D.new()
	area.position = Vector3(0, 0, 3)
	area.area_range = 10.0
	area.light_energy = 4.0
	scene.add_child(area)
	image = await frame()
	require(image.get_pixelv(center).r > 0.1, "area light specialization disabled")
	area.free()
	image = await frame()
	require(image.get_pixelv(center).r < 0.05, "removed lights still illuminate scene")
	environment.environment.ambient_light_energy = 1.0
	print("PASS point/area lights, reconstructed depth and removing lights")

	# Exercise the resource-authored helper and an imported project shader.
	root.msaa_3d = Viewport.MSAA_DISABLED
	var tint = load("res://addons/feng-render-pipeline/examples/tint.tres")
	require(tint != null, "configurable compute pass did not load")
	tint.parameters = Vector4(0, 1, 1, 1)
	compositor.compositor_effects = [tint]
	image = await frame()
	require(image.get_pixelv(center).r < 0.05, "compute tint did not consume configured parameters")
	tint.enabled = false
	image = await frame()
	require(image.get_pixelv(center).r > 0.1, "disabled compute pass still writes color")
	print("PASS configurable compute pass shader, bindings, parameters and enabled state")

	# M1: intermediate texture production-consumption chain through FengTextureManager.
	var chain_shader = load("res://addons/feng-render-pipeline/examples/copy_chain.glsl")
	require(chain_shader != null, "copy_chain shader did not load")
	var producer = FRP_PASS.new()
	producer.stage = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	producer.shader_file = chain_shader
	producer.parameters = Vector4(0.5, 0.5, 0.5, 1.0)
	producer.dispatch_target = &"chain_a"
	var src_in = FRP_TEXTURE.new()
	src_in.binding = 0
	src_in.source = FRP_TEXTURE.Source.COLOR
	src_in.binding_type = FRP_TEXTURE.BindingType.SAMPLED_TEXTURE
	var dst_out = FRP_TEXTURE.new()
	dst_out.binding = 1
	dst_out.source = FRP_TEXTURE.Source.PIPELINE
	dst_out.custom_name = &"chain_a"
	dst_out.binding_type = FRP_TEXTURE.BindingType.STORAGE_IMAGE
	var producer_inputs: Array[FRP_TEXTURE] = [src_in, dst_out]
	producer.inputs = producer_inputs
	var chain_out = FRP_OUTPUT.new()
	chain_out.name = &"chain_a"
	chain_out.data_format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	chain_out.usage = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var producer_outputs: Array[FRP_OUTPUT] = [chain_out]
	producer.outputs = producer_outputs
	var consumer = FRP_PASS.new()
	consumer.stage = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	consumer.shader_file = chain_shader
	consumer.parameters = Vector4(1, 1, 1, 1)
	var chain_in = FRP_TEXTURE.new()
	chain_in.binding = 0
	chain_in.source = FRP_TEXTURE.Source.PIPELINE
	chain_in.custom_name = &"chain_a"
	chain_in.binding_type = FRP_TEXTURE.BindingType.SAMPLED_TEXTURE
	var color_out = FRP_TEXTURE.new()
	color_out.binding = 1
	color_out.source = FRP_TEXTURE.Source.COLOR
	color_out.binding_type = FRP_TEXTURE.BindingType.STORAGE_IMAGE
	var consumer_inputs: Array[FRP_TEXTURE] = [chain_in, color_out]
	consumer.inputs = consumer_inputs
	var manager = FRP_MANAGER.new()
	var manager_passes: Array[CompositorEffect] = [producer, consumer]
	manager.passes = manager_passes
	compositor.compositor_effects = [manager, producer, consumer]
	image = await frame()
	var chain_pixel := image.get_pixelv(center)
	# get_image() returns sRGB-encoded values; 0.5 linear maps to ~0.735 sRGB.
	require(chain_pixel.r > 0.6 and chain_pixel.r < 0.85, "intermediate texture chain did not apply 0.5 tint: %s" % chain_pixel)
	# Resolution switch must rebuild pipeline textures without breaking the chain.
	root.size = Vector2i(160, 120)
	image = await frame()
	root.size = Vector2i(320, 240)
	image = await frame()
	image = await frame()
	chain_pixel = image.get_pixelv(center)
	require(chain_pixel.r > 0.6 and chain_pixel.r < 0.85, "chain broken after resolution switch: %s" % chain_pixel)
	compositor.compositor_effects = []
	manager = null
	producer = null
	consumer = null
	print("PASS intermediate texture production-consumption chain and resolution rebuild")

	# M2: FengRenderer composition layer + raster mode.
	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	require(renderer_script != null, "renderer.gd did not load")
	var raster_shader = load("res://addons/feng-render-pipeline/examples/raster_tint.glsl")
	require(raster_shader != null, "raster_tint shader did not load")
	var raster_pass = FRP_PASS.new()
	raster_pass.stage = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	raster_pass.mode = FRP_PASS.Mode.RASTER
	raster_pass.shader_file = raster_shader
	raster_pass.parameters = Vector4(0.5, 0.5, 0.5, 1.0)
	raster_pass.raster_target = &"chain_b"
	var raster_in = FRP_TEXTURE.new()
	raster_in.binding = 0
	raster_in.source = FRP_TEXTURE.Source.ALBEDO
	raster_in.binding_type = FRP_TEXTURE.BindingType.SAMPLED_TEXTURE
	var raster_inputs: Array[FRP_TEXTURE] = [raster_in]
	raster_pass.inputs = raster_inputs
	var chain_b_out = FRP_OUTPUT.new()
	chain_b_out.name = &"chain_b"
	chain_b_out.data_format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	chain_b_out.usage = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var raster_outputs: Array[FRP_OUTPUT] = [chain_b_out]
	raster_pass.outputs = raster_outputs
	var blit_pass = FRP_PASS.new()
	blit_pass.stage = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	blit_pass.shader_file = chain_shader
	blit_pass.parameters = Vector4(1, 1, 1, 1)
	var blit_in = FRP_TEXTURE.new()
	blit_in.binding = 0
	blit_in.source = FRP_TEXTURE.Source.PIPELINE
	blit_in.custom_name = &"chain_b"
	blit_in.binding_type = FRP_TEXTURE.BindingType.SAMPLED_TEXTURE
	var blit_out = FRP_TEXTURE.new()
	blit_out.binding = 1
	blit_out.source = FRP_TEXTURE.Source.COLOR
	blit_out.binding_type = FRP_TEXTURE.BindingType.STORAGE_IMAGE
	var blit_inputs: Array[FRP_TEXTURE] = [blit_in, blit_out]
	blit_pass.inputs = blit_inputs
	var renderer = renderer_script.new()
	# The renderer now owns the native FRP operations as resources too. Keep
	# those entries in this legacy composition test while replacing only the
	# library shader entries with the two purpose-built passes below.
	var renderer_native_passes := _native_schedule_base(renderer)
	var renderer_custom_passes: Array[FRP_BASE] = [raster_pass, blit_pass]
	var renderer_passes: Array[FRP_BASE] = _set_renderer_passes(renderer, renderer_native_passes, renderer_custom_passes)
	renderer.apply(compositor)
	image = await frame()
	var raster_pixel := image.get_pixelv(center)
	require(raster_pixel.r > 0.6 and raster_pixel.r < 0.85, "raster pass did not apply 0.5 tint: %s" % raster_pixel)
	# Reordering the renderer list must re-apply effects in the new order while
	# retaining the native operation resources.
	var tint2 = load("res://addons/feng-render-pipeline/examples/tint.tres")
	require(tint2 != null, "tint.tres did not load")
	tint2.parameters = Vector4(0.5, 1, 1, 1)
	var reordered_custom: Array[FRP_BASE] = [tint2, raster_pass, blit_pass]
	_set_renderer_passes(renderer, renderer_native_passes, reordered_custom)
	renderer.apply(compositor)
	image = await frame()
	raster_pixel = image.get_pixelv(center)
	require(raster_pixel.r > 0.6 and raster_pixel.r < 0.85, "renderer reorder did not apply: %s" % raster_pixel)
	# Disabling a pass must take effect without re-applying (native enabled flag).
	tint2.enabled = false
	image = await frame()
	raster_pixel = image.get_pixelv(center)
	require(raster_pixel.r > 0.6 and raster_pixel.r < 0.85, "disabled pass still writes color")
	tint2.enabled = true
	renderer = null
	print("PASS renderer composition, raster mode, reorder and native enabled toggle")

	# M3: built-in library passes.
	# The following checks intentionally exercise the legacy explicit effect
	# list. Clear the unified native schedule before replacing that list.
	_clear_frp_pipeline(compositor)
	compositor.compositor_effects = []
	image = await frame()
	var baseline_pixel := image.get_pixelv(center)
	var lib_manager = FRP_MANAGER.new()
	var lib_tint = load("res://addons/feng-render-pipeline/library/tint/tint.tres")
	require(lib_tint != null, "library tint.tres did not load")
	var lib_manager_passes: Array[CompositorEffect] = [lib_tint]
	lib_manager.passes = lib_manager_passes
	compositor.compositor_effects = [lib_manager, lib_tint]
	image = await frame()
	var lib_pixel := image.get_pixelv(center)
	require(lib_pixel.r > lib_pixel.g + 0.1, "library tint did not apply: %s" % lib_pixel)
	compositor.compositor_effects = []
	image = await frame()
	var lib_blur_h = load("res://addons/feng-render-pipeline/library/blur/blur_h.tres")
	var lib_blur_v = load("res://addons/feng-render-pipeline/library/blur/blur_v.tres")
	require(lib_blur_h != null and lib_blur_v != null, "library blur did not load")
	var blur_passes: Array[CompositorEffect] = [lib_blur_h, lib_blur_v]
	lib_manager.passes = blur_passes
	compositor.compositor_effects = [lib_manager, lib_blur_h, lib_blur_v]
	image = await frame()
	# The background just outside the box edge picks up red from the blurred box.
	var edge_pixel := image.get_pixelv(Vector2i(center.x, center.y - 25))
	require(edge_pixel.r > 0.05, "library blur did not bleed into the background: %s" % edge_pixel)
	compositor.compositor_effects = []
	image = await frame()
	var lib_fxaa = load("res://addons/feng-render-pipeline/library/fxaa/fxaa.tres")
	require(lib_fxaa != null, "library fxaa did not load")
	var fxaa_passes: Array[CompositorEffect] = [lib_fxaa]
	lib_manager.passes = fxaa_passes
	compositor.compositor_effects = [lib_manager, lib_fxaa]
	image = await frame()
	lib_pixel = image.get_pixelv(center)
	require(lib_pixel.r > 0.05, "library fxaa produced a black image: %s" % lib_pixel)
	compositor.compositor_effects = []
	image = await frame()
	var lib_grade = load("res://addons/feng-render-pipeline/library/color-grade/color_grade.tres")
	require(lib_grade != null, "library color-grade did not load")
	var grade_passes: Array[CompositorEffect] = [lib_grade]
	lib_manager.passes = grade_passes
	compositor.compositor_effects = [lib_manager, lib_grade]
	image = await frame()
	# The box edge interior is mid-tone; contrast 1.05 must push it brighter.
	var mid_pixel := image.get_pixelv(Vector2i(center.x, center.y - 15))
	require(mid_pixel.r > 0.5, "library color-grade did not brighten mid-tones: %s" % mid_pixel)
	compositor.compositor_effects = []
	image = await frame()
	var lib_bs = load("res://addons/feng-render-pipeline/library/bloom-lite/bloom_downsample.tres")
	var lib_bb = load("res://addons/feng-render-pipeline/library/bloom-lite/bloom_blur.tres")
	var lib_bc = load("res://addons/feng-render-pipeline/library/bloom-lite/bloom_composite.tres")
	require(lib_bs != null and lib_bb != null and lib_bc != null, "library bloom-lite did not load")
	var bloom_passes: Array[CompositorEffect] = [lib_bs, lib_bb, lib_bc]
	lib_manager.passes = bloom_passes
	compositor.compositor_effects = [lib_manager, lib_bs, lib_bb, lib_bc]
	image = await frame()
	# Bloom spreads the bright box into the dark background.
	var bloom_edge := image.get_pixelv(Vector2i(center.x, center.y - 25))
	require(bloom_edge.r > 0.05, "library bloom-lite did not spread brightness: %s" % bloom_edge)
	compositor.compositor_effects = []
	lib_manager = null
	print("PASS built-in library passes (tint, blur, fxaa, color-grade, bloom-lite)")

	# M4: editor-time validation warnings on the renderer resource.
	var renderer_script2 = load("res://addons/feng-render-pipeline/renderer.gd")
	var bad_renderer = renderer_script2.new()
	var bad_pass = FRP_PASS.new()
	bad_pass.stage = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	bad_pass.shader_file = chain_shader
	var missing_in = FRP_TEXTURE.new()
	missing_in.binding = 0
	missing_in.source = FRP_TEXTURE.Source.PIPELINE
	missing_in.custom_name = &"does_not_exist"
	missing_in.binding_type = FRP_TEXTURE.BindingType.SAMPLED_TEXTURE
	var bad_inputs: Array[FRP_TEXTURE] = [missing_in]
	bad_pass.inputs = bad_inputs
	var bad_passes: Array[FRP_BASE] = [bad_pass]
	bad_renderer.passes = bad_passes
	var warnings = bad_renderer.get_configuration_warnings()
	var found_missing := false
	for w in warnings:
		if w.contains("does_not_exist"):
			found_missing = true
	require(found_missing, "renderer validation did not flag a missing pipeline texture")
	bad_renderer = null
	print("PASS editor-time renderer validation warnings")

	# M5: unified native + resource-authored schedule. The native operations
	# are represented by FengBuiltinPass entries, while library and user shader
	# passes remain CompositorEffect-backed entries in the same list.
	var unified_renderer = renderer_script2.new()
	require(RenderingServer.has_method("compositor_set_frp_pipeline"), "engine does not expose compositor_set_frp_pipeline")
	require(RenderingServer.has_method("get_frp_pipeline_spec"), "engine does not expose get_frp_pipeline_spec")
	var spec: Dictionary = RenderingServer.call("get_frp_pipeline_spec")
	require(spec.get("passes", []).size() == EXPECTED_NATIVE_COUNT, "engine native pass spec does not list %d passes" % EXPECTED_NATIVE_COUNT)
	require(int(spec.get("pass_count", 0)) == EXPECTED_NATIVE_COUNT, "engine native pass spec reports the wrong pass count")
	require(spec.get("mandatory", []) == [0, 1, 2, 3, 7], "engine native pass spec does not list the five mandatory passes: %s" % [spec.get("mandatory", [])])
	require(not spec.get("edges", []).is_empty(), "engine native pass spec has no dependency edges")
	require(spec.get("default_order", []).size() == EXPECTED_NATIVE_COUNT, "engine native pass spec default order is incomplete")
	require(RenderingServer.has_method("virtual_texture_set_update_callback"), "engine does not expose virtual texture callback registration")
	require(RenderingServer.has_method("virtual_texture_remove_update_callback"), "engine does not expose virtual texture callback removal")
	require(RenderingServer.has_method("execute_virtual_texture_updates"), "engine does not expose virtual texture callback execution")
	var native_values: Array[FRP_BASE] = _native_passes(unified_renderer)
	require(native_values.size() == EXPECTED_NATIVE_COUNT, "renderer must expose all %d native FRP passes, got %d" % [EXPECTED_NATIVE_COUNT, native_values.size()])
	var expected_native_names := [
		"precompute", "vt pass", "gbuffer", "lighting", "sky", "transparent",
		"temporal", "tonemap",
	]
	var native_ids := {}
	for value in native_values:
		var id := _native_id(value)
		require(id >= 0 and id < EXPECTED_NATIVE_COUNT, "native pass id out of range: %s" % id)
		require(not native_ids.has(id), "duplicate native pass id: %s" % id)
		native_ids[id] = value
	for id in EXPECTED_NATIVE_COUNT:
		require(native_ids.has(id), "missing native pass id %d" % id)
		var label := _pass_label(native_ids[id]).to_lower()
		require(not label.is_empty(), "native pass %d has no display name" % id)
		require(label.contains(expected_native_names[id]), "native pass %d has wrong display name '%s'" % [id, label])
	# Id order is execution order: the shadow maps first, then virtual textures, the
	# G-buffer, lighting, sky, transparent, temporal AA and post.
	require(native_values.size() == EXPECTED_NATIVE_ORDER.size(), "unexpected native pass count: %d" % native_values.size())
	for i in native_values.size():
		require(_native_id(native_values[i]) == EXPECTED_NATIVE_ORDER[i], "default native order changed at index %d: got %d, expected %d" % [i, _native_id(native_values[i]), EXPECTED_NATIVE_ORDER[i]])
	# The engine's default order (used when no pipeline resource is configured) is the
	# same list, so a project with and without the addon runs the same frame.
	var spec_default_order: Array = spec.get("default_order", [])
	require(spec_default_order == EXPECTED_NATIVE_ORDER, "the engine's default pass order is not the id order: %s" % [spec_default_order])
	# The default enabled set is the default pass set: every non optional entry is
	# enabled and the one optional entry (Temporal AA) ships disabled, so a fresh
	# pipeline runs the default passes and the user opts into TAA by enabling it.
	var enabled_native_ids := []
	for value in native_values:
		if value.enabled:
			enabled_native_ids.append(_native_id(value))
	require(enabled_native_ids == [0, 1, 2, 3, 4, 5, 7], "default enabled pass set changed: %s" % [enabled_native_ids])

	var manifest_property := ""
	for candidate in ["_synced_library", "library_manifest", "_library_manifest"]:
		if _has_property(unified_renderer, candidate):
			manifest_property = candidate
			break
	require(not manifest_property.is_empty(), "renderer has no persisted library manifest")
	var manifest: Array = _read_property(unified_renderer, manifest_property, [])
	require(manifest.has("color-grade/color_grade.tres") or manifest.has("library:color_grade"),
		"renderer library manifest lost Color Grade: %s" % [manifest])
	# The seeded library set is Color Grade only: the default pipeline is the engine's
	# eight entries plus that ninth pass, and the other templates are opt-in.
	var library_entries := []
	for value in unified_renderer.passes:
		if _native_id(value) < 0 and not _library_key(value).is_empty():
			library_entries.append(value)
	require(library_entries.size() == 1, "the default pipeline must seed only Color Grade, got %d library entries" % library_entries.size())
	require(unified_renderer.passes.size() == EXPECTED_NATIVE_COUNT + 1,
		"the default pipeline must be the engine's passes plus Color Grade, got %d entries" % unified_renderer.passes.size())

	# Save and load a renderer, then simulate an older resource whose final
	# library entry was absent. Applying it must insert the missing template
	# exactly once and preserve all native resources.
	var sync_path := "user://frp_unified_schedule_%s.tres" % Time.get_ticks_usec()
	var save_error := ResourceSaver.save(unified_renderer, sync_path)
	require(save_error == OK, "unified renderer resource did not save: %s" % save_error)
	var loaded_renderer = ResourceLoader.load(sync_path)
	require(loaded_renderer != null, "unified renderer resource did not load")
	var loaded_manifest: Array = _read_property(loaded_renderer, manifest_property, [])
	require(not loaded_manifest.is_empty(), "loaded renderer library manifest is empty")
	var missing_library_path := "color-grade/color_grade.tres"
	var loaded_values: Array[FRP_BASE] = []
	var removed_library := false
	var missing_library_id := ""
	for value in loaded_renderer.passes:
		if not removed_library and _native_id(value) < 0 and _library_matches(value, missing_library_path):
			removed_library = true
			missing_library_id = str(value.stable_id)
			continue
		loaded_values.append(value)
	require(removed_library, "could not find persisted library pass '%s' to remove" % missing_library_path)
	# Remove both generations of the identity marker before replacing the list.
	# The new renderer uses the stable ID array to recognize a deliberate
	# deletion; clearing it first models a library entry introduced after this
	# resource was saved. Do this before touching `passes` again because the
	# lazy getter/setter may synchronize the library immediately.
	loaded_manifest.erase(missing_library_path)
	require(_write_property(loaded_renderer, manifest_property, loaded_manifest), "could not edit loaded library manifest")
	for identity_property in ["_synced_library_ids", "_deleted_library", "_deleted_library_ids"]:
		if not _has_property(loaded_renderer, identity_property):
			continue
		var identities: Array = _read_property(loaded_renderer, identity_property, [])
		identities.erase(missing_library_path)
		if not missing_library_id.is_empty():
			identities.erase(missing_library_id)
		_write_property(loaded_renderer, identity_property, identities)
	var before_sync_count := 0
	for value in loaded_values:
		if _library_matches(value, missing_library_path):
			before_sync_count += 1
	loaded_renderer.passes = loaded_values
	loaded_renderer.apply(compositor)
	var after_sync_count := 0
	for value in loaded_renderer.passes:
		if _library_matches(value, missing_library_path):
			after_sync_count += 1
	require(before_sync_count == 0 and after_sync_count == 1, "library sync did not insert one missing pass: %d -> %d" % [before_sync_count, after_sync_count])
	var surviving: Array[FRP_BASE] = []
	var inserted_index := -1
	var temporal_index := -1
	var post_index := -1
	for i in loaded_renderer.passes.size():
		var entry = loaded_renderer.passes[i]
		if _library_matches(entry, missing_library_path):
			inserted_index = i
		else:
			surviving.append(entry)
		if _native_id(entry) == 6:
			temporal_index = i
		if _native_id(entry) == 7:
			post_index = i
	require(surviving == loaded_values, "library sync reordered existing entries")
	# Color Grade is the pipeline's ninth pass: sync has to put it back between
	# Temporal AA and Post Process, not at the end of the list.
	require(inserted_index >= 0 and temporal_index < inserted_index and inserted_index < post_index,
		"the re-synced Color Grade pass was not anchored between Temporal AA and Post Process (temporal %d, color grade %d, post %d)" % [temporal_index, inserted_index, post_index])
	print("PASS unified native ids/names/order and saved library sync")

	# A newly authored resource must persist native enabled state and the
	# position of the seeded library pass across a save/load boundary.
	var persisted_renderer = renderer_script2.new()
	var persisted_values: Array[FRP_BASE] = _native_schedule_base(persisted_renderer)
	var persisted_grade = null
	for value in persisted_values:
		if _native_id(value) < 0 and _library_matches(value, "color-grade/color_grade.tres"):
			persisted_grade = value
			break
	require(persisted_grade != null, "could not find the library Color Grade pass in a new renderer")
	persisted_grade.enabled = true
	var persisted_lighting = _native_pass(persisted_renderer, 4)
	require(persisted_lighting != null, "could not find native sky pass for persistence test")
	persisted_lighting.enabled = false
	persisted_renderer.passes = persisted_values
	var persisted_path := "user://frp_persisted_schedule_%s.tres" % Time.get_ticks_usec()
	require(ResourceSaver.save(persisted_renderer, persisted_path) == OK, "new renderer resource did not save state")
	var reloaded_renderer = ResourceLoader.load(persisted_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	require(reloaded_renderer != null, "new renderer resource did not reload state")
	var reloaded_sky = _native_pass(reloaded_renderer, 4)
	require(reloaded_sky != null and not reloaded_sky.enabled, "native enabled state was not persisted")
	var reloaded_grade_index := -1
	var reloaded_temporal_index := -1
	var reloaded_post_index := -1
	for i in reloaded_renderer.passes.size():
		var value = reloaded_renderer.passes[i]
		if _native_id(value) < 0 and _library_matches(value, "color-grade/color_grade.tres"):
			reloaded_grade_index = i
		if _native_id(value) == 6:
			reloaded_temporal_index = i
		if _native_id(value) == 7:
			reloaded_post_index = i
	require(reloaded_grade_index >= 0 and reloaded_temporal_index >= 0 and reloaded_post_index >= 0, "could not locate the library pass or the temporal/post entries")
	require(reloaded_temporal_index < reloaded_grade_index and reloaded_grade_index < reloaded_post_index, "the library pass position was not persisted between temporal AA and post")
	print("PASS renderer save/load preserves native state and custom order")

	# Load a hand-authored legacy .tres with no schema version, only one custom
	# pass and the old path manifest. Loading must leave the serialized list
	# untouched until apply() performs migration; apply then adds native entries,
	# assigns names, syncs new library entries, and keeps a deleted entry gone.
	var legacy_path := "user://frp_legacy_renderer_%s.tres" % Time.get_ticks_usec()
	var legacy_text := """[gd_resource type="Resource" script_class="FengRenderer" load_steps=4 format=3]

[ext_resource type="Script" path="res://addons/feng-render-pipeline/renderer.gd" id="1_renderer"]
[ext_resource type="Script" path="res://addons/feng-render-pipeline/passes/pass_base.gd" id="2_pass_base"]
[ext_resource type="Resource" path="res://addons/feng-render-pipeline/library/tint/tint.tres" id="3_tint"]

[resource]
script = ExtResource("1_renderer")
passes = Array[ExtResource("2_pass_base")]([ExtResource("3_tint")])
_synced_library = Array[String](["fxaa/fxaa.tres"])
"""
	var legacy_file := FileAccess.open(legacy_path, FileAccess.WRITE)
	require(legacy_file != null, "could not create hand-authored legacy renderer resource")
	legacy_file.store_string(legacy_text)
	legacy_file = null
	var legacy_renderer = ResourceLoader.load(legacy_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	require(legacy_renderer != null, "hand-authored legacy renderer did not load")
	legacy_renderer.apply(compositor)
	var migrated_native: Array[FRP_BASE] = _native_passes(legacy_renderer)
	require(migrated_native.size() == EXPECTED_NATIVE_COUNT, "legacy renderer migration did not restore native passes")
	require(_native_id(migrated_native[0]) == 0, "legacy migration did not place Shadow Precompute first")
	for i in migrated_native.size():
		var native_id := _native_id(migrated_native[i])
		require(native_id == EXPECTED_NATIVE_ORDER[i], "legacy migration changed native order at %d: got %d, expected %d" % [i, native_id, EXPECTED_NATIVE_ORDER[i]])
		var migrated_label := _pass_label(migrated_native[i]).to_lower()
		require(migrated_label.contains(expected_native_names[native_id]), "legacy native pass %d name was not restored: '%s'" % [native_id, migrated_label])
	var migrated_tint = null
	var migrated_blur_h := 0
	for value in legacy_renderer.passes:
		if _library_matches(value, "tint/tint.tres"):
			migrated_tint = value
		if _library_matches(value, "fxaa/fxaa.tres"):
			migrated_blur_h += 1
	require(migrated_tint != null and _pass_label(migrated_tint).to_lower().contains("tint"), "legacy library pass did not receive its display name")
	require(migrated_blur_h == 0, "deleted legacy library pass was re-added during sync")
	var deleted_manifest: Array = _read_property(legacy_renderer, "_deleted_library", [])
	require(deleted_manifest.has("fxaa/fxaa.tres"), "legacy deleted library entry was not recorded")
	print("PASS legacy renderer migration, names, library sync and deletion tombstone")

	# A disabled custom pass remains in the compositor effect list on initial
	# apply. Enabling its native CompositorEffect flag must make it run on the
	# next frame without another renderer.apply() call.
	var toggle_renderer = renderer_script2.new()
	var toggle_native: Array[FRP_BASE] = _native_schedule_base(toggle_renderer)
	var toggle_pass := ScreenPaintPass.new(CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_LIGHTING, Color.MAGENTA)
	toggle_pass.enabled = false
	var toggle_custom: Array[FRP_BASE] = [toggle_pass]
	_set_renderer_passes(toggle_renderer, toggle_native, toggle_custom)
	toggle_renderer.apply(compositor)
	await frame()
	var disabled_calls := toggle_pass.calls
	require(disabled_calls == 0, "custom pass disabled before initial apply still ran (%d calls)" % disabled_calls)
	toggle_pass.enabled = true
	await frame()
	require(toggle_pass.calls > disabled_calls, "custom pass did not run after enabling without re-apply")
	print("PASS disabled custom pass initial apply and native enable toggle")

	# FengCompositor listens to the renderer resource. Replacing the pass list
	# after binding it must update the compositor's native schedule and effect
	# slots without an explicit apply call.
	var feng_compositor_script = load("res://addons/feng-render-pipeline/compositor.gd")
	require(feng_compositor_script != null, "FengCompositor script did not load")
	var reactive_compositor = feng_compositor_script.new()
	var reactive_renderer = renderer_script2.new()
	var reactive_native: Array[FRP_BASE] = _native_schedule_base(reactive_renderer)
	var reactive_first := ScreenPaintPass.new(CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_LIGHTING, Color.YELLOW)
	var reactive_initial: Array[FRP_BASE] = [reactive_first]
	_set_renderer_passes(reactive_renderer, reactive_native, reactive_initial)
	reactive_compositor.renderer = reactive_renderer
	camera.compositor = reactive_compositor
	await frame()
	var reactive_second := ScreenPaintPass.new(CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_LIGHTING, Color.CYAN)
	var reactive_edited: Array[FRP_BASE] = [reactive_first, reactive_second]
	_set_renderer_passes(reactive_renderer, reactive_native, reactive_edited)
	await frame()
	require(reactive_second.calls > 0, "FengCompositor did not react to renderer pass-list edit")
	print("PASS compositor notification on renderer list edit")

	# The forward fallback is an internal operation of the Transparent entry now, and
	# that entry's resource switch still changes real draws.
	var native_toggle_renderer = renderer_script2.new()
	_native_schedule_base(native_toggle_renderer)
	reactive_compositor.renderer = native_toggle_renderer
	camera.compositor = reactive_compositor
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var lit_image := await frame()
	require(lit_image.get_pixelv(center).r > 0.8, "native fallback baseline missing")
	var fallback_entry = _native_pass(native_toggle_renderer, 5)
	require(fallback_entry != null, "renderer does not expose the Transparent entry")
	fallback_entry.enabled = false
	var unlit_image := await frame()
	require(unlit_image.get_pixelv(center).r < 0.1, "disabled native transparent entry still draws the fallback")
	fallback_entry.enabled = true
	var restored_image := await frame()
	require(restored_image.get_pixelv(center).r > 0.8, "re-enabled native fallback did not draw")
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	camera.compositor = compositor
	print("PASS native transparent/forward fallback entry disable/enable changes GPU output")

	# Two consecutive color passes must preserve both writes under MSAA.
	var msaa_renderer = renderer_script2.new()
	var msaa_native := _native_schedule_base(msaa_renderer)
	var half_a = load("res://addons/feng-render-pipeline/examples/tint.tres").duplicate(true)
	half_a.enabled = true
	half_a.parameters = Vector4(0.5, 1, 1, 1)
	var half_b = half_a.duplicate(true)
	var half_passes: Array[FRP_BASE] = [half_a, half_b]
	_set_renderer_passes(msaa_renderer, msaa_native, half_passes)
	msaa_renderer.apply(compositor)
	for samples in [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X]:
		root.msaa_3d = samples
		image = await frame()
		var pixel := image.get_pixelv(center)
		require(pixel.r > 0.45 and pixel.r < 0.62, "MSAA custom chain lost a write: %s %s" % [samples, pixel])
	root.msaa_3d = Viewport.MSAA_DISABLED
	print("PASS unified custom color chain with MSAA disabled/2x/4x")
	var valid_order = msaa_renderer.passes.duplicate()
	var valid_tokens = msaa_renderer.get_last_valid_schedule()
	# Moving the lighting pass in front of the G-buffer it reads is a dependency
	# violation, whatever the surrounding entries are: the schedule has to be
	# rejected and the custom effects suspended.
	var invalid_order = valid_order.duplicate()
	var gbuffer_index := -1
	var lighting_index := -1
	for i in invalid_order.size():
		var entry_native_id := _native_id(invalid_order[i])
		if entry_native_id == 2:
			gbuffer_index = i
		elif entry_native_id == 3:
			lighting_index = i
	require(gbuffer_index >= 0 and lighting_index >= 0, "could not find the GBuffer and Lighting entries to reorder")
	var swapped_native = invalid_order[gbuffer_index]
	invalid_order[gbuffer_index] = invalid_order[lighting_index]
	invalid_order[lighting_index] = swapped_native
	msaa_renderer.passes = invalid_order
	msaa_renderer.apply(compositor)
	image = await frame()
	require(msaa_renderer.get_last_valid_schedule() == valid_tokens, "Invalid order replaced the native schedule")
	require(image.get_pixelv(center).r > 0.8, "Invalid configuration did not suspend custom effects: %s warnings=%s" % [image.get_pixelv(center), msaa_renderer.get_validation_warnings()])
	msaa_renderer.passes = valid_order
	msaa_renderer.apply(compositor)
	image = await frame()
	require(image.get_pixelv(center).r > 0.45 and image.get_pixelv(center).r < 0.62, "Correcting the order did not restore custom effects")
	print("PASS invalid dependency order is rejected and recovers")

	# A custom color write before deferred lighting is overwritten by the
	# lighting pass; the same write after it changes the final opaque color.
	# This proves that custom resources move with their list position across a
	# real native operation without claiming current-frame color data before it
	# exists.
	var order_renderer = renderer_script2.new()
	var order_native: Array[FRP_BASE] = _native_schedule_base(order_renderer)
	_set_renderer_passes(order_renderer, order_native)
	order_renderer.apply(compositor)
	var order_baseline := await frame()
	var baseline_order_pixel := order_baseline.get_pixelv(center)
	var order_paint := ScreenPaintPass.new(CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_LIGHTING, Color.GREEN)
	var paint_after: Array[FRP_BASE] = [order_paint]
	_set_renderer_passes(order_renderer, order_native, paint_after)
	order_renderer.apply(compositor)
	var after_lighting_image := await frame()
	var after_lighting_pixel := after_lighting_image.get_pixelv(center)
	require(after_lighting_pixel.r < baseline_order_pixel.r - 0.05, "custom write after lighting did not change GPU output: %s -> %s" % [baseline_order_pixel, after_lighting_pixel])
	var paint_before_lighting: Array[FRP_BASE] = []
	for value in order_native:
		if _native_id(value) == 3:
			paint_before_lighting.append(order_paint)
		paint_before_lighting.append(value)
	order_renderer.passes = paint_before_lighting
	order_renderer.apply(compositor)
	var before_lighting_image := await frame()
	var before_lighting_pixel := before_lighting_image.get_pixelv(center)
	require(before_lighting_pixel.r > after_lighting_pixel.r + 0.05 or before_lighting_pixel.g > after_lighting_pixel.g + 0.05 or before_lighting_pixel.b > after_lighting_pixel.b + 0.05, "moving custom write before deferred lighting had no GPU scheduling effect: %s -> %s" % [after_lighting_pixel, before_lighting_pixel])
	print("PASS custom reorder across native deferred lighting")

	# A custom CompositorEffect authored between VT Pass and GBuffer must run at
	# that exact list position. Its stage selects the callback contract, while
	# the renderer list controls execution order.
	var schedule_renderer = renderer_script2.new()
	var schedule_native: Array[FRP_BASE] = _native_schedule_base(schedule_renderer)
	var pre_gbuffer_probe := PaintPass.new(CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_GBUFFER, Color.WHITE)
	var post_gbuffer_probe := GBufferProbePass.new()
	var authored_schedule: Array[FRP_BASE] = []
	var gbuffer_entry = _native_pass(schedule_renderer, 2)
	for value in schedule_native:
		if _native_id(value) == 2:
			authored_schedule.append(pre_gbuffer_probe)
		authored_schedule.append(value)
		if _native_id(value) == 2:
			authored_schedule.append(post_gbuffer_probe)
	schedule_renderer.passes = authored_schedule
	schedule_renderer.apply(compositor)
	var pre_position := authored_schedule.find(pre_gbuffer_probe)
	var gbuffer_position := authored_schedule.find(gbuffer_entry)
	require(pre_position >= 0 and pre_position < gbuffer_position, "PRE_GBUFFER effect was not authored before GBuffer")
	await frame()
	require(pre_gbuffer_probe.calls > 0 and post_gbuffer_probe.captures == 1, "explicit PRE_GBUFFER effect was not executed around GBuffer")
	print("PASS explicit CompositorEffect scheduling before GBuffer")

	# A material that writes both VERTEX and NORMAL remains in the GBuffer. The
	# probe reads the actual attachments so a forward fallback cannot satisfy
	# this test merely by producing the expected final color.
	_clear_frp_pipeline(compositor)
	var vertex_probe := GBufferProbePass.new()
	compositor.compositor_effects = [vertex_probe]
	box.material_override = material
	await frame()
	require(vertex_probe.captures == 1 and vertex_probe.sample.size() >= 12, "GBuffer probe could not read the opaque baseline")
	var baseline_gbuffer := vertex_probe.sample
	vertex_probe.reset()
	var displaced_shader := Shader.new()
	displaced_shader.code = """
shader_type spatial;
render_mode cull_back;
void vertex() {
	VERTEX.z += 0.75;
	NORMAL = vec3(0.0, 1.0, 0.0);
}
void fragment() {
	ALBEDO = vec3(0.1, 0.8, 0.2);
	ROUGHNESS = 0.5;
}
"""
	var displaced_material := ShaderMaterial.new()
	displaced_material.shader = displaced_shader
	box.material_override = displaced_material
	await frame()
	require(vertex_probe.captures == 1 and vertex_probe.sample.size() >= 12, "custom vertex material did not reach GBuffer")
	require(vertex_probe.sample[1] > 0.6 and vertex_probe.sample[3] > 0.5, "custom vertex material albedo is missing from GBuffer: %s" % vertex_probe.sample)
	require(vertex_probe.sample[5] > 0.9, "custom vertex normal is missing from GBuffer: %s" % vertex_probe.sample)
	require(abs(vertex_probe.sample[8] - baseline_gbuffer[8]) > 0.00001, "custom vertex displacement did not change GBuffer depth")
	print("PASS custom vertex displacement and normal in GBuffer")

	_clear_frp_pipeline(compositor)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(sync_path))
	scene.queue_free()
	await process_frame
	quit()
