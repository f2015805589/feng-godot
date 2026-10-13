@tool
extends RefCounted
## CPU texture filtering shared by static albedo and emissive transport.

static func sample(image: Image, uv: Vector2, repeat: bool, filter_mode: int) -> Vector3:
	if repeat:
		uv = Vector2(fposmod(uv.x, 1.0), fposmod(uv.y, 1.0))
	else:
		uv = uv.clamp(Vector2.ZERO, Vector2.ONE)
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return Vector3.ZERO
	var nearest := filter_mode in [BaseMaterial3D.TEXTURE_FILTER_NEAREST,
			BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS,
			BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC]
	if nearest:
		var px := int(floor(uv.x * width))
		var py := int(floor(uv.y * height))
		return pixel_linear(image, _wrap_texel(px, width, repeat), _wrap_texel(py, height, repeat))
	var fx := uv.x * width - 0.5
	var fy := uv.y * height - 0.5
	var x0 := floori(fx)
	var y0 := floori(fy)
	var tx: float = fx - floor(fx)
	var ty: float = fy - floor(fy)
	var c00 := pixel_linear(image, _wrap_texel(x0, width, repeat), _wrap_texel(y0, height, repeat))
	var c10 := pixel_linear(image, _wrap_texel(x0 + 1, width, repeat), _wrap_texel(y0, height, repeat))
	var c01 := pixel_linear(image, _wrap_texel(x0, width, repeat), _wrap_texel(y0 + 1, height, repeat))
	var c11 := pixel_linear(image, _wrap_texel(x0 + 1, width, repeat), _wrap_texel(y0 + 1, height, repeat))
	return c00.lerp(c10, tx).lerp(c01.lerp(c11, tx), ty)

static func _wrap_texel(value: int, extent: int, repeat: bool) -> int:
	return posmod(value, extent) if repeat else clampi(value, 0, extent - 1)

static func pixel_linear(image: Image, x: int, y: int) -> Vector3:
	var color := image.get_pixel(x, y)
	var format := image.get_format()
	var linear_format := format in [Image.FORMAT_RF, Image.FORMAT_RGF, Image.FORMAT_RGBF,
			Image.FORMAT_RGBAF, Image.FORMAT_RH, Image.FORMAT_RGH, Image.FORMAT_RGBH,
			Image.FORMAT_RGBAH, Image.FORMAT_RGBE9995, Image.FORMAT_BPTC_RGBF,
			Image.FORMAT_BPTC_RGBFU, Image.FORMAT_ASTC_4x4_HDR, Image.FORMAT_ASTC_8x8_HDR]
	if not linear_format:
		color = color.srgb_to_linear()
	var linear_rgb := Vector3(color.r, color.g, color.b)
	return linear_rgb.max(Vector3.ZERO) if linear_rgb.is_finite() else Vector3.ZERO
