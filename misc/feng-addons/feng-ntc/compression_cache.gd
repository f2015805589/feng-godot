@tool
extends RefCounted
const TextureSet = preload("texture_set.gd")
const Decoder = preload("gpu_decoder.gd")
const RECIPE := "feng-ntc-3/libntc-0.10.0-35ec0395/int8/srgb-mips/seed42"

static func fingerprint(images: Dictionary, bpp: float, steps: int) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(("%s/%s/%s" % [RECIPE,bpp,steps]).to_utf8_buffer())
	for name: String in ["albedo","normal","orm"]:
		if not images.has(name): continue
		var image: Image = images[name]
		hash.update(("%s/%s/%s" % [name,image.get_size(),image.get_format()]).to_utf8_buffer())
		hash.update(image.get_data())
	return hash.finish().hex_encode()

static func compress(codec: Object, images: Dictionary, bpp: float, steps: int) -> Dictionary:
	var key := fingerprint(images,bpp,steps)
	var path := "user://feng-ntc/encode-v2/%s.cache" % key
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path,FileAccess.READ)
		if file != null and file.get_length() < 512*1024*1024:
			var record: Variant = file.get_var(false)
			if record is Dictionary and record.get("key") == key and record.get("package") is Dictionary:
				var asset := TextureSet.new()
				asset.package = record.package
				if asset.fingerprint() == record.get("hash") and Decoder.validate(record.package).is_empty():
					return {"ok":true,"package":record.package,"actual_bpp":record.get("actual_bpp",0.0),"psnr":record.get("psnr",0.0),"compression_cache_hit":true}
	var result: Dictionary = codec.compress_material(images,bpp,steps,0)
	if not result.get("ok",false): return result
	var asset := TextureSet.new()
	asset.package = result.package
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir())) == OK:
		var temp := path + ".%s.tmp" % Time.get_ticks_usec()
		var file := FileAccess.open(temp,FileAccess.WRITE)
		if file != null:
			file.store_var({"key":key,"package":result.package,"hash":asset.fingerprint(),"actual_bpp":result.actual_bpp,"psnr":result.psnr},false)
			file.flush()
			var error := file.get_error()
			file.close()
			if error == OK: DirAccess.rename_absolute(temp,path)
	return result
