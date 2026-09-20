extends SceneTree
## Two real views share one pipeline, shader and native definitions while retaining
## independent parameters, enabled RIDs, textures and stateful plugin instances.
const PassBase = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const ViewPass = preload("res://addons/feng-render-pipeline/pipeline/view_pass.gd")

class StatefulPass extends PassBase:
	@export var amount := 0.0
	var observed := -1.0
	var output_texture := RID()
	var output_size := Vector2i.ZERO
	func get_volume_parameter_names() -> PackedStringArray:
		return PackedStringArray(["amount"])
	func _frp_execute(ctx: FRPPassContext) -> void:
		observed = get_resolved_parameters(ctx).get("amount", -1.0)
		var buffers := ctx.get_render_scene_buffers()
		output_texture = buffers.get_texture(&"frp_pipeline", &"view_probe")
		output_size = buffers.get_internal_size()

class ExplicitlyShareablePass extends PassBase:
	## This pass has no per-view mutable execution state and opts in explicitly.
	func can_share_view_execution() -> bool:
		return true

	func _frp_execute(_ctx: FRPPassContext) -> void:
		pass

func _initialize() -> void:
	run.call_deferred()

func settle() -> void:
	for index in 8:
		await process_frame
		await RenderingServer.frame_post_draw

func binding(compositor: FengCompositor, source: FengPass):
	for effect in compositor.compositor_effects:
		if effect is ViewPass and effect.source == source:
			return effect
	return null

func run() -> void:
	var renderer := FengRenderer.new()
	var tint := load("res://addons/feng-render-pipeline/library/tint/tint.tres").duplicate(true) as FengShaderPass
	tint.parameters = Vector4.ONE
	var stateful := StatefulPass.new()
	var explicitly_shareable := ExplicitlyShareablePass.new()
	var output := FengPassOutput.new()
	output.name = &"view_probe"
	stateful.outputs = [output]
	var entries: Array[FengPass] = renderer.passes.duplicate()
	entries.insert(entries.size() - 1, tint)
	entries.insert(entries.size() - 1, stateful)
	entries.insert(entries.size() - 1, explicitly_shareable)
	renderer.passes = entries
	assert(not renderer.is_view_shareable(stateful), "custom passes remain isolated by default")
	assert(renderer.is_view_shareable(explicitly_shareable), "custom opt-in must reach the view policy")
	var taa: FengPass
	for entry in entries:
		if entry is FengBuiltinPass and entry.native_id == 6:
			taa = entry
	var viewports: Array[SubViewport] = []
	var compositors: Array[FengCompositor] = []
	var volumes: Array[FengVolume] = []
	for index in 2:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(96, 96) if index == 0 else Vector2i(128, 128)
		viewport.own_world_3d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		viewports.append(viewport)
		var world := WorldEnvironment.new()
		world.environment = Environment.new()
		world.environment.background_mode = Environment.BG_COLOR
		world.environment.background_color = Color(0.3, 0.3, 0.3)
		viewport.add_child(world)
		var camera := Camera3D.new()
		viewport.add_child(camera)
		camera.current = true
		var compositor := FengCompositor.new()
		compositor.renderer = renderer
		camera.compositor = compositor
		compositors.append(compositor)
		var volume := FengVolume.new()
		volume.unbound = true
		volume.profile = FengVolumeProfile.new()
		var tint_module := FengVolumeModule.from_pass(tint)
		tint_module.set("parameters/parameters", Vector4(0.1, 1, 1, 1) if index == 0 else Vector4(1, 0.1, 1, 1))
		var taa_module := FengVolumeModule.from_pass(taa.implementation)
		taa_module.set("parameters/enabled", index == 0)
		var stateful_module := FengVolumeModule.from_pass(stateful)
		stateful_module.set("parameters/amount", float(index + 1))
		volume.profile.modules = [tint_module, taa_module, stateful_module] as Array[FengVolumeModule]
		viewport.add_child(volume)
		volumes.append(volume)
	await settle()
	var a = binding(compositors[0], tint)
	var b = binding(compositors[1], tint)
	assert(a != null and b != null and a.get_rid() != b.get_rid())
	assert(a.execution == tint and b.execution == tint, "stock shader execution must be shared")
	assert(binding(compositors[0], taa).execution == taa, "stock native definitions must be shared")
	assert(binding(compositors[0], taa).enabled and not binding(compositors[1], taa).enabled,
			"camera switches must not leak through shared native definitions")
	assert(not taa.enabled, "Volume must not edit authored native switches")
	var probe_a = binding(compositors[0], stateful).execution
	var probe_b = binding(compositors[1], stateful).execution
	assert(probe_a != probe_b and probe_a != stateful and probe_b != stateful)
	assert(probe_a.observed == 1.0 and probe_b.observed == 2.0 and stateful.observed == -1.0)
	assert(probe_a.output_texture.is_valid() and probe_b.output_texture.is_valid())
	assert(probe_a.output_texture != probe_b.output_texture, "view output textures must not be shared")
	assert(probe_a.output_size == Vector2i(96, 96) and probe_b.output_size == Vector2i(128, 128))
	var shared_a = binding(compositors[0], explicitly_shareable).execution
	var shared_b = binding(compositors[1], explicitly_shareable).execution
	assert(shared_a == explicitly_shareable and shared_b == explicitly_shareable,
			"an explicitly opted-in custom pass must share its execution resource")
	var pixel_a := viewports[0].get_texture().get_image().get_pixel(48, 48)
	var pixel_b := viewports[1].get_texture().get_image().get_pixel(48, 48)
	assert(pixel_a.r < pixel_a.g * 0.6 and pixel_b.g < pixel_b.r * 0.6,
			"shared shader must use each view's frame parameters")
	var shared_shader: RID = tint._shader
	for index in 4:
		volumes[0].enabled = index % 2 != 0
		await settle()
		var current_b := viewports[1].get_texture().get_image().get_pixel(48, 48)
		assert(absf(current_b.g - pixel_b.g) < 0.02, "enter/exit in another view changed this view")
		assert(tint._shader == shared_shader, "boundary crossing recreated shared shader objects")
	# Author edits rebuild the view plan and isolate new plugin instances.
	tint.parameters = Vector4(0.8, 0.8, 0.8, 1.0)
	await settle()
	assert(binding(compositors[0], stateful).execution != probe_a)
	assert(binding(compositors[1], stateful).execution.observed == 2.0)
	assert(renderer.get_volume_parameters().is_empty())
	var valid_parameters := compositors[0].get_volume_parameters()
	var valid_states := compositors[0].get_volume_pass_states()
	var invalid_states := valid_states.duplicate()
	invalid_states[2] = false
	compositors[0].set_volume_parameters(valid_parameters, invalid_states)
	await settle()
	assert(not compositors[0]._view_state._valid)
	assert(not binding(compositors[0], tint).enabled, "invalid view plan must suspend its custom effects")
	assert(binding(compositors[1], tint).enabled, "invalid view plan must not disable another view")
	compositors[0].set_volume_parameters(valid_parameters, valid_states)
	await settle()
	assert(compositors[0]._view_state._valid and binding(compositors[0], tint).enabled)
	# Post overlays mutate keywords/targets during execution, so these executors
	# must remain per-view even when the surrounding native definition is shared.
	var post: FengPass
	for entry in entries:
		if entry is FengBuiltinPass and entry.native_id == 7:
			post = entry
	var overlay := FengShaderPass.new()
	overlay.mode = FengShaderPass.Mode.RASTER
	overlay.shader_file = load("res://addons/feng-render-pipeline/examples/post_overlay.glsl")
	var post_output := FengPassOutput.new()
	post_output.name = &"post_ldr"
	post_output.data_format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	post_output.usage = FengPassOutput.Usage.SAMPLED | FengPassOutput.Usage.COLOR_ATTACHMENT
	overlay.outputs = [post_output]
	post.implementation.overlay = overlay
	for index in 2:
		var post_module := FengVolumeModule.from_pass(post.implementation)
		post_module.set("parameters/overlay_after_tonemap", index == 0)
		var modules := volumes[index].profile.modules.duplicate()
		modules.append(post_module)
		volumes[index].profile.modules = modules
	await settle()
	var post_a = binding(compositors[0], post).execution
	var post_b = binding(compositors[1], post).execution
	assert(post_a != post_b and post_a != post and post_b != post)
	assert(post_a.implementation.overlay != post_b.implementation.overlay)
	var ldr := viewports[0].get_texture().get_image().get_pixel(48, 48)
	var hdr := viewports[1].get_texture().get_image().get_pixel(48, 48)
	assert(ldr.g > 0.9 and ldr.r < 0.1 and hdr.r > hdr.g + 0.15,
			"per-view overlay placement/keywords must reach different GPU outputs")
	assert(overlay.shader_keywords.is_empty(), "overlay execution wrote into shared author settings")
	print("PASS FRP shared view definitions, two-camera pixels, independent TAA switches, stateful plugin isolation and shader reuse")
	for viewport in viewports:
		viewport.queue_free()
	await process_frame
	quit()
