extends SceneTree
func _initialize():
	call_deferred("run")
func check(value, message):
	if not value:
		push_error(message)
		quit(1)
		assert(value,message)
func run():
	var scene=Node3D.new()
	var terrain=Terrain3D.new()
	scene.add_child(terrain)
	terrain.free_editor_textures=false
	terrain.assets=Terrain3DAssets.new()
	terrain.assets.texture_array_size=16
	var sources=[]
	for id in 2:
		var asset=Terrain3DTextureAsset.new()
		asset.id=id
		var image=Image.create(16,16,false,Image.FORMAT_RGBA8)
		image.fill(Color(0.3+id*0.3,0.5,0.7,0.4+id*0.3))
		asset.albedo_texture=ImageTexture.create_from_image(image)
		asset.normal_texture=asset.albedo_texture
		sources.append(image.get_data())
		terrain.assets.set_texture_asset(id,asset)
	var camera=Camera3D.new()
	root.add_child(camera)
	camera.current=true
	terrain.set_camera(camera)
	root.add_child(scene)
	terrain.region_size=64
	terrain.data.add_region_blank(Vector2i.ZERO)
	for i in 4:
		await process_frame
	var formats=[Image.FORMAT_RGBA8,Image.FORMAT_BPTC_RGBA,Image.FORMAT_DXT1,Image.FORMAT_DXT5,Image.FORMAT_RGTC_R,Image.FORMAT_RGTC_RG,Image.FORMAT_BPTC_RGBFU,Image.FORMAT_ETC,Image.FORMAT_ETC2_RGB8,Image.FORMAT_ETC2_RGBA8,Image.FORMAT_ETC2_R11,Image.FORMAT_ETC2_RG11,Image.FORMAT_ASTC_4x4,Image.FORMAT_ASTC_8x8,Image.FORMAT_ASTC_4x4_HDR,Image.FORMAT_ASTC_8x8_HDR]
	var astc8_bytes=0
	for mipmaps in [true,false]:
		terrain.assets.texture_array_mipmaps=mipmaps
		for codec in formats.size():
			terrain.assets.texture_array_compression=codec
			await process_frame
			var info=terrain.assets.get_texture_array_info()
			print("CODEC=",codec," info=",info)
			check(not info.is_empty(),"array info missing")
			# encoder_missing marks a build without the codec's encoder (e.g. no
			# cvtt for BC7): the array falls back to uncompressed instead of
			# staying empty, so only the format check relaxes.
			var format_ok=info.albedo_image_format==formats[codec] or info.get("encoder_missing",false)
			check(format_ok,"wrong encoded format for "+str(codec))
			if codec==13:
				astc8_bytes=info.encoded_bytes
			if codec==15:
				check(info.encoded_bytes==astc8_bytes,"ASTC 8x8 HDR block sizes differ from LDR")
			for rid in [terrain.assets.get_albedo_array_rid(),terrain.assets.get_normal_array_rid()]:
				for layer in 2:
					var image=RenderingServer.texture_2d_layer_get(rid,layer)
					check(image!=null and image.has_mipmaps()==mipmaps,"GPU upload failed")
					check(image.get_format()==info.albedo_upload_format,"wrong GPU format")
					if image.is_compressed():
						check(image.decompress()==OK,"decode failed")
					if codec in [0,1,3,9,12,13,14,15]:
						check(abs(image.get_pixel(0,0).a-(0.4+layer*0.3))<0.12,"packed alpha lost")
	for id in 2:
		check(terrain.assets.get_texture_asset(id).albedo_texture.get_image().get_data()==sources[id],"source mutated")
	var hdr_assets: Array[Terrain3DTextureAsset] = []
	for id in 2:
		var asset = Terrain3DTextureAsset.new()
		asset.id = id
		var image = Image.create(16, 16, false, Image.FORMAT_RGBAF)
		image.fill(Color(2.0 + id, 0.5, 0.7, 0.4 + id * 0.3))
		asset.albedo_texture = ImageTexture.create_from_image(image)
		asset.normal_texture = asset.albedo_texture
		hdr_assets.append(asset)
	terrain.assets.set_texture_list(hdr_assets)
	for codec in [0, 6, 14, 15]:
		terrain.assets.texture_array_compression = codec
		await process_frame
		for layer in 2:
			var image = RenderingServer.texture_2d_layer_get(terrain.assets.get_albedo_array_rid(), layer)
			if image.is_compressed():
				check(image.decompress() == OK, "HDR decode failed")
			check(abs(image.get_pixel(0, 0).r - (2.0 + layer)) < 0.15, "HDR source was clamped")
	print("PASS all array compression formats, layers, mipmaps, alpha, HDR and original images")
	terrain.queue_free()
	await process_frame
	quit(0)
