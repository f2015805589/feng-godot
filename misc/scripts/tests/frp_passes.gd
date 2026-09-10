extends SceneTree

const FRP_PASS = preload("res://addons/feng-render-pipeline/passes/shader_pass.gd")
const FRP_BASE = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const FRP_TEXTURE = preload("res://addons/feng-render-pipeline/passes/pass_texture.gd")
const FRP_OUTPUT = preload("res://addons/feng-render-pipeline/passes/pass_output.gd")
const FRP_MANAGER = preload("res://addons/feng-render-pipeline/passes/texture_manager.gd")

class PaintPass extends CompositorEffect:
	var color := Color.GREEN
	var calls := 0
	func _init(stage: int, value: Color) -> void:
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

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		quit(1)
		assert(value, message)

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
	var renderer_passes: Array[FRP_BASE] = [raster_pass, blit_pass]
	renderer.passes = renderer_passes
	renderer.apply(compositor)
	image = await frame()
	var raster_pixel := image.get_pixelv(center)
	require(raster_pixel.r > 0.6 and raster_pixel.r < 0.85, "raster pass did not apply 0.5 tint: %s" % raster_pixel)
	# Reordering the renderer list must re-apply effects in the new order.
	var tint2 = load("res://addons/feng-render-pipeline/examples/tint.tres")
	require(tint2 != null, "tint.tres did not load")
	tint2.parameters = Vector4(0.5, 1, 1, 1)
	var reordered: Array[FRP_BASE] = [tint2, raster_pass, blit_pass]
	renderer.passes = reordered
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
	scene.queue_free()
	await process_frame
	quit()
