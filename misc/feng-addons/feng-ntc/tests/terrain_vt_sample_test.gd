extends SceneTree
## Exercise actual RS samplers: signed normals, HDR parameters, BC/raw cache,
## logical slot growth/reuse, and SDK-free cold misses. Compare against CUDA output.
const Sampling = preload("res://addons/feng-ntc/terrain_vt_sample.gd")
signal rendered(report: Dictionary)
var view: SubViewport
var material: ShaderMaterial
var sampler: RefCounted
var references: Array
var asset: Resource

func _init() -> void: _run.call_deferred()
func frames(count: int) -> void:
	for i in range(count): await RenderingServer.frame_post_draw
func fail(message: String) -> void:
	push_error(message); quit(1)
func tick() -> Dictionary:
	RenderingServer.call_on_render_thread(func(): rendered.emit.call_deferred(sampler.flush_pages()))
	return await rendered
func register(entry: Dictionary, slot: int, slots: int) -> Dictionary:
	RenderingServer.call_on_render_thread(func(): rendered.emit.call_deferred(sampler.register_page(entry, slot, slots)))
	return await rendered

func _run() -> void:
	create_timer(120.0).timeout.connect(fail.bind("NTC sampler test timed out"))
	if ClassDB.class_exists(&"FengNTCCodec"): fail("Sampler runtime loaded the NTC SDK"); return
	asset = load("res://vt_pages.res")
	asset.packages.append(asset.packages[0])
	references = FileAccess.open("res://references.bin", FileAccess.READ).get_var(false)
	view = SubViewport.new(); view.size = Vector2i(272,204); view.disable_3d = true
	view.use_hdr_2d = true; view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var panel := ColorRect.new(); panel.size = Vector2(272,204)
	material = ShaderMaterial.new(); var shader := Shader.new()
	shader.code = """shader_type canvas_item;
render_mode unshaded;
struct material { vec4 albedo_height; vec4 normal_rough; float ao; float metal; float wet; float weight; };
""" + Sampling.shader_code(asset.packages) + """
uniform int test_slot=0;
uniform bool reference=false;
uniform sampler2D ref_a : filter_nearest, repeat_disable;
uniform sampler2D ref_n : filter_nearest, repeat_disable;
uniform sampler2D ref_p : filter_nearest, repeat_disable;
void fragment() {
    ivec2 pixel=ivec2(FRAGCOORD.xy); int channel=pixel.x/68, row=pixel.y/68;
    vec2 uv=(vec2(pixel%68)+0.5)/68.0;
    vec4 a,n,p;
    if(reference) {
        a=textureLod(ref_a,uv,0.0); n=textureLod(ref_n,uv,0.0); p=textureLod(ref_p,uv,0.0);
        n.xyz=normalize(n.xyz); n.a=clamp(n.a,0.0,1.0); p.a=step(0.5,p.a);
    } else {
        material m; vec3 normal;
        bool ok=surface_neural_material_slot(test_slot,(uv*68.0-2.0)/64.0,64,2,vec2(0.0),vec2(0.0),m,normal);
        a=m.albedo_height; n=m.normal_rough; p=vec4(m.ao,m.metal,m.wet,ok?1.0:0.0);
        if(!ok) { a=vec4(0.0); n=vec4(0.0); p=vec4(0.0); }
    }
    vec4 value=row==0?a:(row==1?n:p);
    COLOR=vec4(vec3(value[channel]*0.25+0.25),1.0);
}
"""
	material.shader=shader; panel.material=material; view.add_child(panel)
	var entries: Array[Dictionary] = []
	for i in range(16):
		var key := Terrain3DSurfaceBaker.neural_page_key(Rect2(i,0,1,1),64,2,i%2)
		var entry: Dictionary = asset.pages[key].duplicate(); entry.key=key; entry.model=i%2
		entries.append(entry)
	for mode: int in [-1,0,1]:
		sampler = Sampling.new(); sampler.packages = asset.packages; sampler.catalog=asset.pages
		sampler.cache_pages=0 if mode<0 else 16; sampler.cache_compression=maxi(mode,0)
		sampler.max_pages_per_frame=16
		sampler.configure_material(material.get_rid())
		for i in range(16):
			if not (await register(entries[i],i,16)).get("ok",false): fail("Register failed"); return
		var report := {}
		for i in range(120):
			report=await tick(); await frames(1)
			if mode<0 or int(report.cache_ready)==16: break
		if mode>=0 and int(report.cache_ready)!=16:
			print("NTC_SAMPLER_CACHE_FAILURE ", report, " ",sampler._cache_stats)
			fail("Cache never became ready"); return
		var before := report.duplicate()
		for slot: int in [0,7,15]:
			if not await compare(slot,entries[slot],0.016 if mode<1 else 0.04): return
		for i in range(8): report=await tick(); await frames(1)
		if before.cache_decodes!=report.cache_decodes: fail("Static cache decoded repeatedly"); return
		# Expanding the address table must preserve old slots and account for its storage.
		var old_bytes: int = report.gpu_bytes
		if not (await register(entries[1],127,128)).get("ok",false): fail("Page table grow failed"); return
		report=await tick(); await frames(3)
		if int(report.gpu_bytes)<old_bytes+1024: fail("Page table memory unaccounted"); return
		if not await compare(127,entries[1],0.016): return
		await register(entries[1],0,128)
		await tick(); await frames(3)
		if not await compare(0,entries[1],0.04 if mode==1 else 0.016): return
		RenderingServer.call_on_render_thread(func(): sampler.invalidate_slot(0))
		await tick(); await frames(3)
		material.set_shader_parameter("reference",false); material.set_shader_parameter("test_slot",0)
		await frames(3)
		if absf(view.get_texture().get_image().get_pixel(240,170).r-0.25)>0.003: fail("Invalidated page remained visible"); return
		print("NTC_SAMPLER_MODE ",mode," ",report)
		RenderingServer.call_on_render_thread(sampler.dispose)
		await frames(4); sampler=null
		if asset.pages.size()!=16: fail("Releasing a decoder modified the serialized page catalog"); return
	view.queue_free(); material=null; asset=null
	await frames(4)
	print("TERRAIN_VT_SAMPLE_PASS"); quit()

func compare(slot: int, entry: Dictionary, tolerance: float) -> bool:
	var rect: Rect2i=entry.rect
	for spec: Array in [["albedo_height","ref_a"],["normal_roughness","ref_n"],["params","ref_p"]]:
		var source: Dictionary=references[0][spec[0]]
		var image := Image.create_from_data(source.size.x,source.size.y,true,Image.FORMAT_RGBAH,source.pixels).get_region(rect)
		material.set_shader_parameter(spec[1],ImageTexture.create_from_image(image))
	material.set_shader_parameter("test_slot",slot)
	material.set_shader_parameter("reference",true); await frames(3)
	var expected := view.get_texture().get_image()
	material.set_shader_parameter("reference",false); await frames(3)
	var actual := view.get_texture().get_image()
	var squared := 0.0
	for y in range(204):
		for x in range(272): squared+=pow((expected.get_pixel(x,y).r-actual.get_pixel(x,y).r)*4.0,2.0)
	var error := sqrt(squared/(204.0*272.0))
	print("NTC_SAMPLER_PARITY slot=",slot," cache=",sampler.cache_compression," error=",error)
	if error>tolerance:
		actual.save_png("res://sampler_actual.png"); expected.save_png("res://sampler_expected.png")
		fail("Neural material sampler differs from reference: "+str(error)); return false
	return true
