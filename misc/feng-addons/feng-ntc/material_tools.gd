@tool
extends RefCounted

const NTMaterial = preload("material.gd")
const VTMaterial = preload("virtual_material.gd")
const NeuralMaterial = preload("neural_material.gd")
const SLOT_NAMES := ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture", "ao_texture"]


static func snapshot(material: StandardMaterial3D) -> Dictionary:
	if material == null: return {"ok": false, "error": "请先选择 StandardMaterial3D 材质。"}
	if material is NTMaterial: return {"ok": false, "error": "请选择原始材质，避免反复有损压缩。"}
	if material.ao_on_uv2 and material.ao_enabled and material.ao_texture != null:
		return {"ok": false, "error": "当前材质的 AO 使用 UV2，不能与 UV1 的粗糙度打包。"}
	var images := {}
	var size := Vector2i.ZERO
	for slot: String in SLOT_NAMES:
		var texture: Texture2D = material.get(slot)
		if texture == null: continue
		var img: Image
		# Read original image data where available, so compression does not start from an already lossy BC texture.
		var path := texture.resource_path
		if FileAccess.file_exists(path) and path.get_extension().to_lower() in ["png", "jpg", "jpeg", "tga", "webp", "bmp"]:
			# This is an editor-only source read, not a runtime resource dependency.
			img = Image.load_from_file(ProjectSettings.globalize_path(path))
		else:
			img = texture.get_image()
		if img == null or img.is_empty(): return {"ok": false, "error": "无法读取纹理：" + slot}
		img = img.duplicate()
		if img.is_compressed() and img.decompress() != OK: return {"ok": false, "error": "无法解压源纹理：" + slot}
		if img.get_format() in [Image.FORMAT_RF, Image.FORMAT_RGF, Image.FORMAT_RGBF, Image.FORMAT_RGBAF, Image.FORMAT_RH, Image.FORMAT_RGH, Image.FORMAT_RGBH, Image.FORMAT_RGBAH, Image.FORMAT_RGBE9995]:
			return {"ok": false, "error": "首版仅处理 LDR 材质贴图；HDR 贴图请保留原格式。"}
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
		if size == Vector2i.ZERO: size = img.get_size()
		if img.get_size() != size: return {"ok": false, "error": "这组贴图分辨率不一致，请先统一尺寸；插件不会静默缩放。"}
		if slot == "normal_texture" and FileAccess.file_exists(path + ".import"):
			var config := ConfigFile.new()
			if config.load(path + ".import") == OK and config.get_value("params", "process/normal_map_invert_y", false):
				var bytes := img.get_data()
				for offset in range(1, bytes.size(), 4): bytes[offset] = 255 - bytes[offset]
				img = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, bytes)
		images[slot] = img
	if images.is_empty(): return {"ok": false, "error": "材质没有纹理，无需神经压缩。"}
	if size.x < 4 or size.y < 4 or size.x > 8192 or size.y > 8192 or size.x & (size.x - 1) or size.y & (size.y - 1):
		return {"ok": false, "error": "首版支持 4～8192 像素、2 的幂次方尺寸。"}
	var channels := {"roughness_texture": material.roughness_texture_channel, "metallic_texture": material.metallic_texture_channel, "ao_texture": material.ao_texture_channel}
	return {"ok": true, "images": images, "channels": channels, "size": size}


static func pack(snapshot_data: Dictionary) -> Dictionary:
	var size: Vector2i = snapshot_data["size"]
	var images: Dictionary = snapshot_data.images
	var output := {}
	if images.has("albedo_texture"):
		output.albedo = images.albedo_texture
	else:
		var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
		image.fill(Color.WHITE)
		output.albedo = image
	if images.has("normal_texture"): output.normal = images.normal_texture
	if not images.has("ao_texture") and not images.has("roughness_texture") and not images.has("metallic_texture"):
		return output
	var orm := PackedByteArray()
	orm.resize(size.x * size.y * 4)
	orm.fill(255)
	var targets := {"ao_texture": 0, "roughness_texture": 1, "metallic_texture": 2}
	for slot: String in targets:
		if not images.has(slot): continue
		var bytes: PackedByteArray = images[slot].get_data()
		var channel: int = snapshot_data.channels[slot]
		for pixel in range(size.x * size.y):
			var offset := pixel * 4
			orm[offset + targets[slot]] = bytes[offset + channel] if channel < 4 else int((int(bytes[offset]) + int(bytes[offset + 1]) + int(bytes[offset + 2])) / 3)
	output.orm = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, orm)
	return output


static func copy_material_properties(source: StandardMaterial3D, destination: StandardMaterial3D) -> void:
	for property: Dictionary in source.get_property_list():
		var name: String = property.name
		if not int(property.usage) & PROPERTY_USAGE_STORAGE: continue
		if name in ["script", "resource_path", "resource_name", "texture_set"] or name in SLOT_NAMES: continue
		destination.set(name, source.get(name))
	destination.resource_name = source.resource_name + " NTC"


static func make_portable(source: NTMaterial) -> StandardMaterial3D:
	if source == null or source.texture_set == null: return null
	var textures: Dictionary = await source.texture_set.prepare_async()
	if textures.is_empty(): return null
	if not ClassDB.class_exists(&"FengNTCCodec"): return null
	var raw := {}
	for name: String in textures: raw[name] = textures[name].get_image()
	var codec: Object = ClassDB.instantiate(&"FengNTCCodec")
	var encoded: Dictionary = codec.encode_bc7_material(raw)
	if not encoded.get("ok",false): return null
	textures = {}
	for name: String in encoded.images: textures[name] = ImageTexture.create_from_image(encoded.images[name])
	var material := StandardMaterial3D.new()
	copy_material_properties(source, material)
	material.resource_name = source.resource_name + " BC7"
	material.albedo_texture = textures.get("albedo")
	material.normal_texture = textures.get("normal")
	material.ao_texture = textures.get("orm")
	material.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.roughness_texture = textures.get("orm")
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	material.metallic_texture = textures.get("orm")
	material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	return material


static func virtual_unsupported(source: StandardMaterial3D) -> String:
	if source.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or source.shading_mode != BaseMaterial3D.SHADING_MODE_PER_PIXEL or source.cull_mode != BaseMaterial3D.CULL_BACK:
		return "VT 当前支持不透明、背面剔除的 PBR 材质；此材质请用通用 GPU 完整加载。"
	for property in ["emission_enabled","rim_enabled","clearcoat_enabled","anisotropy_enabled","heightmap_enabled","subsurf_scatter_enabled","backlight_enabled","refraction_enabled","detail_enabled","uv1_triplanar","uv2_triplanar","vertex_color_use_as_albedo","billboard_keep_scale","grow","proximity_fade_enabled","distance_fade_mode","uv1_world_triplanar"]:
		if source.get(property): return "VT 尚不支持 %s；请选择通用 GPU 完整加载。" % property
	if not source.texture_repeat or source.next_pass != null: return "VT 使用重复 UV1，暂不支持禁用 Repeat / Next Pass。"
	return ""


static func make_virtual(source: StandardMaterial3D, asset: Resource) -> ShaderMaterial:
	var material := VTMaterial.new()
	material.resource_name = source.resource_name + " NTC VT"
	_configure_sampler(material,source,asset)
	return material


static func make_neural(source: StandardMaterial3D, asset: Resource) -> ShaderMaterial:
	var material := NeuralMaterial.new()
	material.resource_name = source.resource_name + " NTC"
	_configure_sampler(material,source,asset)
	material.set_shader_parameter("trilinear",true)
	material.set_shader_parameter("exact_texels",false)
	return material


static func _configure_sampler(material: ShaderMaterial, source: StandardMaterial3D, asset: Resource) -> void:
	for mapping in [["albedo","albedo_color"],["roughness","roughness"],["metallic","metallic"],["specular","metallic_specular"],["ao_light_affect","ao_light_affect"]]:
		material.set_shader_parameter(mapping[0],source.get(mapping[1]))
	material.set_shader_parameter("normal_scale",source.normal_scale if source.normal_enabled else 0.0)
	material.set_shader_parameter("ao_enabled",source.ao_enabled)
	material.set_shader_parameter("uv_scale",Vector2(source.uv1_scale.x,source.uv1_scale.y))
	material.set_shader_parameter("uv_offset",Vector2(source.uv1_offset.x,source.uv1_offset.y))
	material.texture_set = asset


static func sampler_template(source: Material) -> StandardMaterial3D:
	var template := StandardMaterial3D.new()
	if source is StandardMaterial3D:
		copy_material_properties(source,template)
	else:
		template.resource_name=source.resource_name
		for mapping in [["albedo","albedo_color"],["roughness","roughness"],["metallic","metallic"],["specular","metallic_specular"],["ao_light_affect","ao_light_affect"],["normal_scale","normal_scale"],["ao_enabled","ao_enabled"]]:
			var value: Variant=source.get_shader_parameter(mapping[0])
			if value!=null: template.set(mapping[1],value)
		template.normal_enabled=source.texture_set!=null and source.texture_set.package.maps.has("normal") and template.normal_scale!=0.0
		var scale: Vector2=source.get_shader_parameter("uv_scale") if source.get_shader_parameter("uv_scale")!=null else Vector2.ONE
		var offset: Vector2=source.get_shader_parameter("uv_offset") if source.get_shader_parameter("uv_offset")!=null else Vector2.ZERO
		template.uv1_scale=Vector3(scale.x,scale.y,1)
		template.uv1_offset=Vector3(offset.x,offset.y,0)
	return template
