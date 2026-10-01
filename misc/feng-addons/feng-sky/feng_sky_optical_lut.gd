@tool
extends RefCounted
## Immutable-by-convention optical columns, shared only as copy-on-write bytes.
## Each provider creates its own Image/Texture from these bytes. No sun, color,
## extinction, exposure or world state is part of the table.
## RGB stores Rayleigh, Mie and piecewise-linear ozone density columns.

const WIDTH := 128
const HEIGHT := 64
const SUN_SAMPLES := 6
static var _cached_signature: Array = []
static var _cached_bytes := PackedByteArray()
static var _build_count := 0
# Extremely thin density layers create narrow grazing features that this compact
# table cannot resolve. Keep the exact six-step path for those authored profiles.
const MAX_HEIGHT_TO_SCALE := 64.0


static func supports_settings(settings: Dictionary) -> bool:
	var height: float = settings["atmosphere_height_km"]
	var exponential_supported := height / minf(settings["rayleigh_scale_height_km"], settings["mie_scale_height_km"]) <= MAX_HEIGHT_TO_SCALE
	var maximum_absorption_slope := maxf(absf(settings["absorption_layer0_linear_term"]), absf(settings["absorption_layer1_linear_term"]))
	return exponential_supported and height * maximum_absorption_slope <= MAX_HEIGHT_TO_SCALE


static func geometry_signature(settings: Dictionary) -> Array:
	return [settings["planet_radius_km"], settings["atmosphere_height_km"],
		settings["rayleigh_scale_height_km"], settings["mie_scale_height_km"],
		settings["absorption_density_layer_width_km"], settings["absorption_layer0_linear_term"],
		settings["absorption_layer0_constant_term"], settings["absorption_layer1_linear_term"],
		settings["absorption_layer1_constant_term"]]


static func make_image(settings: Dictionary) -> Image:
	var signature := geometry_signature(settings)
	if signature != _cached_signature:
		_cached_bytes = _build_columns(signature).to_byte_array()
		_cached_signature = signature
		_build_count += 1
	return Image.create_from_data(WIDTH, HEIGHT, false, Image.FORMAT_RGBF, _cached_bytes)


static func _build_columns(signature: Array) -> PackedFloat32Array:
	var radius: float = signature[0]
	var height: float = signature[1]
	var rayleigh_height: float = signature[2]
	var mie_height: float = signature[3]
	# Factored squares keep the near-ground mapping numerically stable.
	var top_radius := radius + height
	var horizon_length := sqrt(height * (2.0 * radius + height))
	var columns := PackedFloat32Array()
	columns.resize(WIDTH * HEIGHT * 3)
	for y in HEIGHT:
		var rho := horizon_length * float(y) / float(HEIGHT - 1)
		var r := sqrt(radius * radius + rho * rho)
		var minimum_distance := maxf(top_radius - r, 0.0)
		var maximum_distance := rho + horizon_length
		for x in WIDTH:
			var u := 1.0 - float(x) / float(WIDTH - 1)
			var distance := lerpf(minimum_distance, maximum_distance, 1.0 - u * u)
			var r_mu := 0.0
			if distance > 0.000001:
				r_mu = ((top_radius - r) * (top_radius + r) - distance * distance) / (2.0 * distance)
			var rayleigh_column := 0.0
			var mie_column := 0.0
			var absorption_column := 0.0
			for i in SUN_SAMPLES:
				var start := float(i) / float(SUN_SAMPLES)
				var end := float(i + 1) / float(SUN_SAMPLES)
				start *= start
				end *= end
				var step_length := (end - start) * distance
				var t := (start + end) * 0.5 * distance
				var sample_radius := sqrt(maxf(r * r + t * (2.0 * r_mu + t), 0.0))
				var altitude := maxf(sample_radius - radius, 0.0)
				rayleigh_column += exp(-altitude / rayleigh_height) * step_length
				mie_column += exp(-altitude / mie_height) * step_length
				var absorption_density := float(signature[5]) * altitude + float(signature[6]) if altitude < float(signature[4]) else float(signature[7]) * altitude + float(signature[8])
				absorption_column += clampf(absorption_density, 0.0, 1.0) * step_length
			var offset := (y * WIDTH + x) * 3
			columns[offset] = rayleigh_column
			columns[offset + 1] = mie_column
			columns[offset + 2] = absorption_column
	return columns
