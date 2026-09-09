extends SceneTree

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
			var inputs = [b.get_texture("deferred_clustered", "gbuffer_albedo"), b.get_texture("deferred_clustered", "gbuffer_orm"), b.get_texture("deferred_clustered", "normal_roughness"), b.get_depth_texture()]
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
			var texture := buffers.get_texture("deferred_clustered", "gbuffer_albedo")
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
	scene.queue_free()
	await process_frame
	quit()
