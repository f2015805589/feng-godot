extends SceneTree

const FengSkyAtmosphere = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
const FengProjectPipeline = preload("res://addons/feng-render-pipeline/project_pipeline.gd")
const FengWorldCompositor = preload("res://addons/feng-render-pipeline/world_compositor.gd")


func _initialize() -> void:
	call_deferred("run")


func require(condition: bool, message: String) -> void:
	if not condition:
		push_error("REGRESSION: " + message)
		quit(1)


func make_viewport(world: World3D) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.world_3d = world
	root.add_child(viewport)
	return viewport


func make_shared_sky() -> Sky:
	var shader := Shader.new()
	shader.code = "shader_type sky;\nuniform float test_gain = 1.0;\nvoid sky() { COLOR = vec3(test_gain); }\n"
	var material := ShaderMaterial.new()
	material.shader = shader
	var sky := Sky.new()
	sky.sky_material = material
	return sky


func run() -> void:
	await run_checks()
	await process_frame
	print("feng_sky_atmosphere tests passed")
	quit()


func run_checks() -> void:
	var shared_environment := Environment.new()
	shared_environment.background_mode = Environment.BG_COLOR
	shared_environment.background_color = Color(0.12, 0.2, 0.3)
	shared_environment.ambient_light_energy = 2.0
	var shared_sky := make_shared_sky()
	var shared_material := shared_sky.sky_material as ShaderMaterial
	shared_environment.sky = shared_sky

	var viewport_a := make_viewport(World3D.new())
	var viewport_b := make_viewport(World3D.new())
	var component_a := FengSkyAtmosphere.new()
	component_a.environment = shared_environment
	viewport_a.add_child(component_a)
	var component_b := FengSkyAtmosphere.new()
	component_b.environment = shared_environment
	viewport_b.add_child(component_b)
	await process_frame

	require(component_a.environment != shared_environment, "component A kept the shared Environment")
	require(component_b.environment != shared_environment, "component B kept the shared Environment")
	require(component_a.environment != component_b.environment, "two World3Ds share the component Environment")
	require(component_a.environment.sky != shared_sky and component_b.environment.sky != shared_sky,
		"a component kept the shared Sky")
	require(component_a.environment.sky != component_b.environment.sky, "two World3Ds share the component Sky")
	require(component_a.environment.sky.sky_material != shared_material,
		"component A kept the shared Sky material")
	require(component_a.environment.sky.sky_material.shader != shared_material.shader,
		"component A kept the shared Shader")
	require(component_a.environment.background_mode == Environment.BG_SKY,
		"component A did not enforce BG_SKY")
	require(component_b.environment.background_mode == Environment.BG_SKY,
		"component B did not enforce BG_SKY")
	require(shared_environment.background_mode == Environment.BG_COLOR,
		"enforcing BG_SKY modified the shared Environment")
	require(shared_environment.ambient_light_energy == 2.0,
		"copying the Environment modified its source settings")
	require(viewport_a.world_3d.get_environment() == component_a.environment,
		"component A did not provide its World3D environment")
	require(viewport_b.world_3d.get_environment() == component_b.environment,
		"component B did not provide its World3D environment")

	var local_material_a := component_a.sky.sky_material as ShaderMaterial
	local_material_a.shader = null
	require(shared_material.shader != null, "editing component A's material changed the shared material")
	require((component_b.sky.sky_material as ShaderMaterial).shader != null,
		"editing component A's material changed component B")
	component_a.environment.sky = shared_sky
	component_a.environment.background_mode = Environment.BG_COLOR
	component_a._sync_environment()
	require(component_a.environment.sky != shared_sky,
		"synchronizing an inspector Sky assignment kept the shared Sky")
	require(component_a.environment.background_mode == Environment.BG_SKY,
		"synchronizing the Environment did not restore BG_SKY")

	var replacement := Sky.new()
	replacement.sky_material = PanoramaSkyMaterial.new()
	component_a.sky = replacement
	require(component_a.sky != replacement, "the replacement Sky was not localized")
	require(component_a.sky.sky_material is PanoramaSkyMaterial,
		"the component did not accept a PanoramaSkyMaterial")
	require(component_a.sky.sky_material != replacement.sky_material,
		"the replacement material was not localized")
	require(component_b.sky.sky_material is ShaderMaterial,
		"replacing component A's Sky changed component B")

	var default_component := FengSkyAtmosphere.new()
	require(default_component.sky != null, "a new component has no default Sky")
	require(default_component.sky.sky_material is PhysicalSkyMaterial,
		"a new component does not default to PhysicalSkyMaterial")
	require(default_component.environment.background_mode == Environment.BG_SKY,
		"a new component does not default to BG_SKY")

	var persistence_root := Node3D.new()
	var persisted_component := FengSkyAtmosphere.new()
	persisted_component.sky = replacement
	persistence_root.add_child(persisted_component)
	persisted_component.owner = persistence_root
	viewport_a.add_child(persistence_root)
	var packed := PackedScene.new()
	require(packed.pack(persistence_root) == OK, "could not pack the replacement Sky scene")
	const SAVE_PATH := "user://feng_sky_persistence_test.tscn"
	require(ResourceSaver.save(packed, SAVE_PATH) == OK, "could not save the replacement Sky scene")
	var reloaded := (load(SAVE_PATH) as PackedScene).instantiate() as Node3D
	var reloaded_component := reloaded.get_child(0) as FengSkyAtmosphere
	require(reloaded_component != null, "the saved scene lost FengSkyAtmosphere")
	require(reloaded_component.sky.sky_material is PanoramaSkyMaterial,
		"the user-selected Panorama sky did not persist through a scene save")
	require(reloaded_component.environment.sky == reloaded_component.sky,
		"the saved Sky slot and Environment sky diverged")

	var viewport_c := make_viewport(World3D.new())
	var first_environment := Environment.new()
	first_environment.background_mode = Environment.BG_COLOR
	var first_world_environment := WorldEnvironment.new()
	first_world_environment.environment = first_environment
	viewport_c.add_child(first_world_environment)
	var later_component := FengSkyAtmosphere.new()
	viewport_c.add_child(later_component)
	await process_frame
	require(viewport_c.world_3d.get_environment() == first_environment,
		"a later FengSkyAtmosphere took over another WorldEnvironment")
	require(first_environment.background_mode == Environment.BG_COLOR,
		"the later component modified the first WorldEnvironment's Environment")
	first_world_environment.free()
	await process_frame
	require(viewport_c.world_3d.get_environment() == later_component.environment,
		"the component did not become active after the first WorldEnvironment left")

	var pipeline_viewport := make_viewport(World3D.new())
	var sky_component := FengSkyAtmosphere.new()
	pipeline_viewport.add_child(sky_component)
	var pipeline_host := Node.new()
	pipeline_viewport.add_child(pipeline_host)
	var project_compositor := Compositor.new()
	const COMPOSITOR_PATH := "user://feng_sky_pipeline_compositor.tres"
	require(ResourceSaver.save(project_compositor, COMPOSITOR_PATH) == OK,
		"could not save the project compositor fixture")
	ProjectSettings.set_setting("rendering/renderer/compositor", COMPOSITOR_PATH)
	require(RenderingServer.get_current_rendering_method() == "frp",
		"the coexistence test is not running with the FRP rendering method")
	var installed_pipeline := FengProjectPipeline.install(pipeline_host, null)
	require(installed_pipeline != null and installed_pipeline.compositor != null,
		"FengProjectPipeline did not install its project compositor")
	require(installed_pipeline.environment == null,
		"the project pipeline unexpectedly installed an Environment")
	require(pipeline_viewport.world_3d.get_environment() == sky_component.environment,
		"the project pipeline WorldEnvironment displaced FengSkyAtmosphere's Environment")
	require(FengWorldCompositor.world_compositor(pipeline_viewport) == installed_pipeline.compositor,
		"the project pipeline compositor did not remain active beside FengSkyAtmosphere")
	FengProjectPipeline.clear(installed_pipeline)
	await process_frame
	require(pipeline_viewport.world_3d.get_environment() == sky_component.environment,
		"clearing the project pipeline also removed FengSkyAtmosphere's Environment")
	require(FengWorldCompositor.world_compositor(pipeline_viewport) == null,
		"clearing the project pipeline left its compositor active")
	ProjectSettings.set_setting("rendering/renderer/compositor", "")

	default_component.free()
	reloaded.free()
	viewport_a.free()
	viewport_b.free()
	viewport_c.free()
	pipeline_viewport.free()
