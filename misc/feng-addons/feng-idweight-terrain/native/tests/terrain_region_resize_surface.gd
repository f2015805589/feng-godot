extends SceneTree
## Region layout changes must preserve packed IDs on the authored density grid.
var failed := false
var terrain: Terrain3D
const SOURCE_SIZE := 64
const DENSITY := 2
const LOCATIONS: Array[Vector2i] = [Vector2i(-1, -1), Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
var before: Dictionary = {}
var original_surfaces: Dictionary = {}

func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)

func _initialize() -> void:
	call_deferred("run")

func check_surface(label: String) -> void:
	for location in original_surfaces:
		var image: Image = original_surfaces[location]
		require(image.get_data() == before[location].bytes, label + " changed an external source image")
	for location in LOCATIONS:
		var source_bytes: PackedByteArray = before[location].bytes
		var source_density: int = before[location].density
		for y in SOURCE_SIZE * DENSITY:
			for x in SOURCE_SIZE * DENSITY:
				var payload := location * SOURCE_SIZE * DENSITY + Vector2i(x, y)
				var size := terrain.region_size
				var destination := Vector2i(floori(float(payload.x) / (size * DENSITY)), floori(float(payload.y) / (size * DENSITY)))
				var region := terrain.data.get_region(destination)
				if region == null or region.get_surface_map() == null:
					require(false, "%s lost surface map at %s" % [label, destination])
					return
				if region.get_surface_density() != DENSITY:
					require(false, label + " changed authored density")
					return
				var local := payload - destination * size * DENSITY
				var got := roundi(region.get_surface_map().get_pixelv(local).r * 65535.0)
				var sx := x * source_density / DENSITY
				var sy := y * source_density / DENSITY
				var expected := source_bytes.decode_u16((sy * SOURCE_SIZE * source_density + sx) * 2)
				if got != expected:
					require(false, "%s changed packed surface %s: got %d expected %d" % [label, payload, got, expected])
					return

func run() -> void:
	terrain = Terrain3D.new()
	# No VT service or physics work is needed to test source data redistribution.
	terrain.vt_delivery_near_material = 0
	terrain.vt_delivery_far_material = 0
	terrain.vt_delivery_near_height = 0
	terrain.vt_delivery_far_height = 0
	root.add_child(terrain)
	terrain.region_size = SOURCE_SIZE
	terrain.surface_density = DENSITY
	terrain.vertex_spacing = 1.75
	terrain.collision_mode = 0
	terrain.set_physics_process(false)
	for location in LOCATIONS:
		var region := terrain.data.add_region_blank(location, false)
		if location == Vector2i(1, 1):
			# Legacy-only regions mixed with authored surfaces must still convert their
			# own materials, including when an earlier source creates the destination.
			var word := PackedByteArray()
			word.resize(4)
			word.encode_u32(0, (7 << 27) | (3 << 22) | (64 << 14))
			region.get_control_map().fill(Color(word.decode_float(0), 0, 0, 1))
			var converted := region.duplicate(false) as Terrain3DRegion
			converted.ensure_surface_map()
			before[location] = {"bytes": converted.get_surface_map().get_data(), "density": DENSITY}
			continue
		var density := 4 if location == Vector2i(-1, -1) else (1 if location == Vector2i(0, 1) else DENSITY)
		region.set_surface_density(density)
		var bytes := PackedByteArray()
		bytes.resize(SOURCE_SIZE * SOURCE_SIZE * density * density * 2)
		for y in SOURCE_SIZE * density:
			for x in SOURCE_SIZE * density:
				# Every sub-texel differs, exposing accidental density-1 downsampling.
				bytes.encode_u16((y * SOURCE_SIZE * density + x) * 2, (x * 97 + y * 193 + (location.x + 2) * 31 + (location.y + 2) * 17) & 65535)
		region.set_surface_map(Image.create_from_data(SOURCE_SIZE * density, SOURCE_SIZE * density, false, Image.FORMAT_R16, bytes))
		before[location] = {"bytes": bytes, "density": density}
		original_surfaces[location] = region.get_surface_map()
	terrain.data.change_region_size(128)
	check_surface("merge 64→128")
	if not failed:
		terrain.data.change_region_size(64)
		check_surface("split 128→64")
	terrain.free()
	if not failed:
		print("PASS region resizing preserves authored R16 surface density and bytes")
	quit(1 if failed else 0)
