extends SceneTree
## Patterned HDR readback exercises optional library passes, before tonemapping.
const ShaderPass = preload("res://addons/feng-render-pipeline/passes/shader_pass.gd")
const PassBase = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const Library = preload("res://addons/feng-render-pipeline/pipeline/library_manager.gd")
const EXTENT := Vector2i(64, 48)
class Readback extends ShaderPass:
	var pixels: Image
	func _init() -> void:
		shader_file = load("res://readback.glsl")
		var source := TextureInput.new()
		var destination := TextureInput.new()
		destination.binding = 1
		destination.source = TextureInput.Source.CUSTOM
		destination.custom_scope = PIPELINE_SCOPE
		destination.custom_name = &"audit_readback"
		destination.binding_type = TextureInput.BindingType.STORAGE_IMAGE
		inputs = [source,destination]
		var output := OutputDeclaration.new()
		output.name = &"audit_readback"
		output.usage = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		outputs = [output]
	func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
		if pixels == null:
			super._render(buffers,view,rd)
			var size := buffers.get_internal_size()
			var bytes := rd.texture_get_data(inputs[1].get_texture(buffers,view),0)
			if bytes.size() == size.x*size.y*8:
				pixels = Image.create_from_data(size.x,size.y,false,Image.FORMAT_RGBAH,bytes)
var failures := 0
var viewport: SubViewport
var camera: Camera3D
var renderer: FengRenderer
var authored: Array[FengPass]
var pattern: FengShaderPass
var readback: Readback

func _initialize() -> void:
	call_deferred("run")
func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error("REGRESSION: " + label)
func template(name: String) -> FengShaderPass:
	return load("res://addons/feng-render-pipeline/library/" + name).duplicate(true) as FengShaderPass
func pixel_at(point: Vector2i) -> Color:
	var p := point.clamp(Vector2i.ZERO, EXTENT - Vector2i.ONE)
	return Color(0.125 + 0.75 * ((int(p.x / 7) + int(p.y / 5)) % 2),
			0.125 + 0.5 * (int(p.x / 11) % 2), 0.125 + 0.5 * (int(p.y / 13) % 2))
func delta(a: Color, b: Color) -> float:
	return maxf(absf(a.r-b.r), maxf(absf(a.g-b.g), absf(a.b-b.b)))
func capture(passes: Array[FengPass]) -> Image:
	var next := authored.duplicate()
	var index := 0
	for i in next.size():
		if next[i] is FengBuiltinPass and next[i].native_id == 4:
			index = i + 1
			break
	next.insert(index, pattern)
	for pass_entry in passes:
		index += 1
		next.insert(index, pass_entry)
	readback = Readback.new()
	next.insert(index + 1, readback)
	renderer.passes = next
	await process_frame
	for i in 10:
		await process_frame
		await RenderingServer.frame_post_draw
		if readback.pixels != null:
			return readback.pixels
	check(false, "pattern readback was not rendered")
	return Image.create(EXTENT.x, EXTENT.y, false, Image.FORMAT_RGBAH)
func run() -> void:
	_test_legacy_upgrade()
	if OS.get_cmdline_user_args().has("--migration-only"):
		if failures == 0: print("PASS optional library stored-resource migration")
		quit(0 if failures == 0 else 1)
		return
	viewport = SubViewport.new()
	viewport.size = EXTENT
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	camera = Camera3D.new()
	camera.current = true
	viewport.add_child(camera)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	viewport.add_child(environment)
	renderer = FengRenderer.new()
	for entry in renderer.passes:
		if not entry is FengBuiltinPass or entry.native_id in [6,8]:
			entry.enabled = false
	authored = renderer.passes.duplicate()
	var compositor := FengCompositor.new()
	compositor.renderer = renderer
	camera.compositor = compositor
	pattern = ShaderPass.new()
	pattern.shader_file = load("res://pattern.glsl")
	var target := PassBase.TextureInput.new()
	target.binding_type = PassBase.TextureInput.BindingType.STORAGE_IMAGE
	pattern.inputs = [target]
	var plain := await capture([])
	var plain_error := 0.0
	for y in EXTENT.y:
		for x in EXTENT.x:
			plain_error = maxf(plain_error, delta(plain.get_pixel(x,y), pixel_at(Vector2i(x,y))))
	check(plain_error < 0.002, "HDR pattern control mismatch %f" % plain_error)
	var horizontal := template("blur/blur_h.tres")
	var vertical := template("blur/blur_v.tres")
	horizontal.parameters = Vector4.ZERO
	vertical.parameters = Vector4.ZERO
	var blurred := await capture([horizontal, vertical])
	var blur_error := 0.0
	for y in EXTENT.y:
		for x in EXTENT.x:
			var expected := pixel_at(Vector2i(int(x/2)*2+1, int(y/2)*2+1))
			blur_error = maxf(blur_error, delta(blurred.get_pixel(x,y), expected))
	check(blur_error < 0.002, "half-resolution blur full-frame mapping mismatch %f" % blur_error)
	var down := template("bloom-lite/bloom_downsample.tres")
	var bloom_blur := template("bloom-lite/bloom_blur.tres")
	var composite := template("bloom-lite/bloom_composite.tres")
	down.parameters = Vector4.ZERO
	bloom_blur.parameters = Vector4.ZERO
	composite.parameters = Vector4(1,0,0,0)
	var bloom := await capture([down,bloom_blur,composite])
	var bloom_error := 0.0
	for y in EXTENT.y:
		for x in EXTENT.x:
			var expected := pixel_at(Vector2i(x,y)) + pixel_at(Vector2i(int(x/2)*2+1, int(y/2)*2+1))
			bloom_error = maxf(bloom_error, delta(bloom.get_pixel(x,y), expected))
	check(bloom_error < 0.003, "bloom downsample full-frame mapping mismatch %f" % bloom_error)
	var fxaa := template("fxaa/fxaa.tres")
	check(fxaa.inputs[0].source != PassBase.TextureInput.Source.COLOR, "FXAA must sample an immutable source copy")
	var result := await capture([fxaa])
	var fxaa_error := 0.0
	for y in EXTENT.y:
		for x in EXTENT.x:
			var p := Vector2i(x,y)
			var colors := [pixel_at(p+Vector2i(-1,-1)),pixel_at(p+Vector2i(1,-1)),pixel_at(p+Vector2i(-1,1)),pixel_at(p+Vector2i(1,1))]
			var center := pixel_at(p)
			var minimum := center.get_luminance()
			var maximum := minimum
			var average := Color(0,0,0,0)
			# Match the optional shader's documented luma weights exactly.
			minimum = center.r*0.299+center.g*0.587+center.b*0.114
			maximum = minimum
			for color in colors:
				var luma: float = color.r*0.299+color.g*0.587+color.b*0.114
				minimum = minf(minimum,luma)
				maximum = maxf(maximum,luma)
				average += color*0.25
			var contrast := maximum-minimum
			var expected := center
			if contrast >= 0.1 and maximum >= 0.05:
				expected = center.lerp(average,clampf((contrast-0.1)/maxf(contrast,0.00001)*2.0,0.0,1.0)*0.5)
			fxaa_error = maxf(fxaa_error,delta(result.get_pixel(x,y),expected))
	check(fxaa_error < 0.002, "FXAA immutable-neighborhood CPU oracle mismatch %f" % fxaa_error)
	print("OPTIONAL_LIBRARY errors=",plain_error,"/",blur_error,"/",bloom_error,"/",fxaa_error," failures=",failures)
	camera.compositor = null
	renderer.passes = []
	viewport.queue_free()
	await process_frame
	if failures == 0: print("PASS FRP optional library patterned HDR mapping, immutable FXAA and legacy migration")
	quit(0 if failures == 0 else 1)
func _test_legacy_upgrade() -> void:
	var legacy := ShaderPass.new()
	legacy.shader_file = load("res://addons/feng-render-pipeline/library/fxaa/fxaa.glsl")
	legacy.stable_id = &"library:fxaa"
	legacy.resource_name = "Authored FXAA"
	legacy.enabled = false
	legacy.parameters = Vector4(0.2,0.07,3,4)
	legacy.pass_parameters = {"parameters":Vector4(0.3,0.09,5,6)}
	var input := PassBase.TextureInput.new()
	var output := PassBase.TextureInput.new()
	output.binding = 1
	output.binding_type = PassBase.TextureInput.BindingType.STORAGE_IMAGE
	legacy.inputs = [input,output]
	var entries: Array = [legacy]
	var library: Script = load("res://addons/feng-render-pipeline/pipeline/library_manager.gd")
	if library.has_method("_upgrade_legacy_fxaa"):
		check(library.call("_upgrade_legacy_fxaa", entries), "released generic FXAA contract migrates")
		var upgraded = entries[0]
		check(upgraded != legacy and upgraded.inputs[0].source != PassBase.TextureInput.Source.COLOR, "migration replaces only the list entry")
		for property in ["resource_name","enabled","parameters","pass_parameters","stable_id"]:
			check(upgraded.get(property) == legacy.get(property), "migration preserves "+property)
		check(legacy.inputs[0].source == PassBase.TextureInput.Source.COLOR, "shared legacy resource remains untouched")
		check(not library.call("_upgrade_legacy_fxaa", entries), "migration is idempotent")
		check(ResourceSaver.save(legacy, "user://legacy_fxaa.tres") == OK, "legacy generic FXAA saves")
		var restored := ResourceLoader.load("user://legacy_fxaa.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
		var before := PassBase.new()
		var after := PassBase.new()
		entries = [before, restored, after]
		# Exercise the public synchronization entry point after a disk roundtrip.
		var deleted_ids: Array = ["library:color_grade", "library:magic_gi", "library:height_fog", "library:eye_adaptation", "library:debug_buffers"]
		check(library.call("sync", entries, [], [], [], deleted_ids), "stored legacy resource migrates during synchronization")
		check(entries.size() == 3 and entries[0] == before and entries[2] == after, "migration retains authored list position")
		check(entries[1] != restored and entries[1].parameters == legacy.parameters and not entries[1].enabled, "stored migration retains authored values")
		legacy.shader_file = load("res://pattern.glsl")
		entries = [legacy]
		check(not library.call("_upgrade_legacy_fxaa", entries), "custom shader is not replaced")
		legacy.shader_file = load("res://addons/feng-render-pipeline/library/fxaa/fxaa.glsl")
		legacy.inputs[0].binding = 4
		entries = [legacy]
		check(not library.call("_upgrade_legacy_fxaa", entries), "authored texture contracts are not replaced")
