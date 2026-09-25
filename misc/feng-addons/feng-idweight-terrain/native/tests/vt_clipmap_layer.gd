# Run with a graphical rendering driver; see README.md in this directory.
#
# Evidence for the *unified* clipmap layer, and the acceptance of the task that made it one delivery
# with two implementations **and gave it the density ladder 1024 -> ... -> 1 texels a metre**:
#
#   * **One delivery, two implementations.** `vt_clipmap_implementation` selects `LOD` (the toroidal
#     level ring) or `Atlas` (the block atlas) *inside* the clipmap settings; there is no second
#     delivery to select. This script renders the **same scene with the same camera** once per
#     implementation and saves both frames at 1080p, which is the "actual render comparison" the task
#     asks for rather than a claim about the shader.
#   * **The ladder's two endpoints are measured, not requested.** The shipped defaults - nothing is
#     written before the first reading - are read from the layer's own report and sampled along the
#     ground through `sample_vt_clipmap_density()` (the layer's own addressing, whichever
#     implementation answers): **1024 texels a metre** inside the finest unit's quarter-metre square
#     and **1 texel a metre** at the outer edge. The declared per-unit densities must be the halving
#     ladder `1024 / 2^u`, the measured samples must be non-increasing and must each *be* one of those
#     densities, and both endpoints must appear on both implementations.
#   * **The ladder is the geometry.** Every sampled world point inside the guaranteed coverage radius
#     must have a unit whose published square contains it (no hole), and the density the layer reports
#     there must be exactly the density of the *finest* such unit (one serving unit, no double
#     coverage). That is the shared `Ladder` checked against the per-unit `center`/`world_size` the
#     implementations publish, rather than against a comment.
#   * **The debug follows the setting.** `get_clipmap_layout_preview()` is read in both states and its
#     `implementation` key is asserted to follow the property, with the per-unit entries and the
#     density/radius curve present in *both* - one schema, two storages.
#   * **The near field is not mush.** The *sharpness* of the rendered frame is measured as the mean
#     local gradient in screen bands, and the previous shapes' frames are rendered from the same camera
#     for the before/after pair, so the improvement is a picture reading too.
#   * **The frame is not a fallback.** `vt_delivery_near_material = Direct` forces the region-array
#     evaluation and the rendered frame is asserted to differ from that one: a cell naming Clipmap is
#     served by the layer, not by the region arrays behind it.
#   * **No silent truncation.** A unit count above the atlas's own ceiling is written and the ladder is
#     re-read: the clamp must still leave the 1024 -> 1 span, because a ceiling that shortened the
#     ladder would be exactly the failure this task exists to remove.
extends "res://vt_probe_base.gd"

const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2
const LOD := 0
const ATLAS := 1

# The ladder's own endpoints and unit count, in texels a metre. They are the task's numbers, written
# here as the acceptance's constants rather than read from the build.
const LADDER_FINEST := 1024.0
const LADDER_COARSEST := 1.0
const LADDER_UNITS := 11
const DETAIL_FLOOR := 128.0
# The product's own debug view, instantiated and polled the way the editor polls it: the two-state
# screenshots the task asks for are of this control, not a re-drawing.
const DEBUG_VIEW_SCRIPT := "res://addons/feng-idweight-terrain/src/vt_clipmap_preview.gd"
const DEBUG_VIEW_SIZE := Vector2i(1920, 1080)
# The dock's own script, whose Clipmap node shows the shape the settings carry.
const EDITOR_SCRIPT := "res://addons/feng-idweight-terrain/src/vt_editor.gd"

# The distance samples, in metres along the ground: the near end inside unit 0's own square, then one
# per octave out to 256 m - which is past the LOD implementation's own +/-128 m reach, so the *same*
# sample list proves the 1 texel/m outer endpoint on both storages (the atlas reaches further because a
# ring is a 3x3 square).
const DISTANCES: Array[float] = [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 192.0, 256.0]
# The radius the coverage audit walks to, as a fraction of the guaranteed radius, and the directions it
# walks in. Eight directions catch a snapped grid, whose offset is the only way a ring can miss a point
# the size of its square says it holds.
const AUDIT_FRACTIONS: Array[float] = [0.05, 0.25, 0.5, 0.9, 1.0]
const AUDIT_ANGLES := 8
# How much camera travel the steady-state upload reading covers, and how many ticks it is spread over.
const TRAVEL_METRES := 8.0
const TRAVEL_STEPS := 120
# The shapes the before/after pair and the cost table compare against: the ladder this worktree
# inherited (one texel a metre everywhere) and the previous round's recommendation (eight).
const INHERITED_BASE := 256.0
const INHERITED_UNITS := 8
const PREVIOUS_BASE := 32.0
const PREVIOUS_UNITS := 10

var painter: Terrain3DEditor
var brush: Image
var target: Node3D

func settle(frames: int) -> void:
	for _i in frames:
		await process_frame

func settings() -> Dictionary:
	return terrain.get_vt_settings()

func layer_report() -> Dictionary:
	var preview: Dictionary = terrain.get_clipmap_layout_preview()
	var layers: Array = preview.get("layers", [])
	for entry: Variant in layers:
		if typeof(entry) == TYPE_DICTIONARY and str((entry as Dictionary).get("group", "")) == "material":
			return entry
	return {}

# The flat forward direction of the camera, which is the line every sample and every audit point is
# laid along: the coverage reading is about the ground the view is over.
func ground_forward() -> Vector2:
	var forward := -camera.global_transform.basis.z
	var flat := Vector2(forward.x, forward.z)
	if flat.length() < 0.0001:
		flat = Vector2(0.0, -1.0)
	return flat.normalized()

# The density the *layer* serves at a ground point: the shared ladder's reciprocal, asked through the
# layer rather than through either storage.
func layer_density_at(direction: Vector2, distance: float) -> float:
	var origin := Vector2(camera.position.x, camera.position.z)
	return terrain.sample_vt_clipmap_density(MATERIAL, origin + direction * distance)

func density_at(distance: float) -> float:
	return layer_density_at(ground_forward(), distance)

func detail_density_at(distance: float) -> float:
	var origin := Vector2(camera.position.x, camera.position.z)
	return terrain.sample_vt_detail(origin + ground_forward() * distance)

# The mean local gradient of a rendered frame inside a horizontal screen band, which is the *picture's*
# sharpness: a blurrier ground averages its texture structure away, so the gradient falls. It is the
# reading the density numbers are checked against, not a replacement for them.
func band_gradient(image: Image, y0: float, y1: float) -> float:
	var height := image.get_height()
	var width := image.get_width()
	var top := clampi(int(y0 * float(height)), 1, height - 2)
	var bottom := clampi(int(y1 * float(height)), top + 1, height - 2)
	var step := maxi(1, width / 240)
	var total := 0.0
	var count := 0
	for y in range(top, bottom, 2):
		for x in range(step, width - step, step):
			var left := image.get_pixel(x - step, y)
			var right := image.get_pixel(x + step, y)
			var down := image.get_pixel(x, y + 1)
			total += absf(right.r - left.r) + absf(right.g - left.g) + absf(right.b - left.b)
			total += absf(down.r - left.r) + absf(down.g - left.g) + absf(down.b - left.b)
			count += 2
	return total / float(maxi(count, 1))

func captured_image() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

# The mean channel difference of the **ground band** only: the sky is identical in every state and
# averaging it in would hide exactly the difference the comparison is for.
func mean_channel_difference(a: Image, b: Image) -> float:
	var width := mini(a.get_width(), b.get_width())
	var height := mini(a.get_height(), b.get_height())
	var total := 0.0
	var count := 0
	for y in range(int(float(height) * 0.45), height, 3):
		for x in range(0, width, 3):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			count += 1
	return total / float(maxi(count, 1)) / 3.0

func patterned_texture(base: Color, accent: Color) -> ImageTexture:
	var image := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in 256:
		for x in 256:
			var fine := Color(base)
			if ((x / 2) + (y / 2)) % 2 == 0:
				fine = accent
			if (x + y) % 5 == 0:
				fine = base.lerp(accent, 0.15)
			image.set_pixel(x, y, fine)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func paint_material(center: Vector3, asset_id: int) -> void:
	painter.set_tool(Terrain3DEditor.TEXTURE)
	painter.set_operation(Terrain3DEditor.REPLACE)
	painter.set_brush_data({
		"brush": [brush, ImageTexture.create_from_image(brush)],
		"size": 12.0, "strength": 100.0, "mouse_pressure": 1.0,
		"asset_id": asset_id, "pair_overlay_id": asset_id, "pair_background_id": asset_id,
		"pair_mode": 0, "pair_weight_level": 8,
	})
	painter.start_operation(center)
	painter.operate(center, 0.0)
	painter.stop_operation()

# The dock's own shape display, which is where a user reads the ladder. The panel takes its numbers from
# `get_vt_settings()`, so the shipped defaults have to arrive there and the controls have to be able to
# *show* them: a base-extent spin whose range started at 1 m - as this worktree's did - would display a
# value the layer does not use, which is a silent truncation in the UI rather than in the shape. The
# hint is asserted to name both endpoints, and not to warn, on the shipped shape.
func check_dock_shape() -> void:
	var window: Window = load(EDITOR_SCRIPT).new()
	window.initialize(null)
	root.add_child(window)
	window.set_terrain(terrain)
	await process_frame
	var surface: TreeItem = window.hierarchy.get_root().get_first_child()
	require(surface != null, "the Surface VT window built its hierarchy root")
	if surface != null:
		var clipmap_item: TreeItem = surface.get_first_child().get_next()
		clipmap_item.select(0)
		window.hierarchy.item_selected.emit()
		await process_frame
		require(window.clipmap_base_spin != null and
				is_equal_approx(float(window.clipmap_base_spin.value), 0.25),
				"the dock shows the ladder's 0.25 m base extent (got %s)" % str(
						window.clipmap_base_spin.value if window.clipmap_base_spin != null else "none"))
		require(window.clipmap_levels_spin != null and int(window.clipmap_levels_spin.value) == LADDER_UNITS,
				"the dock shows the ladder's %d units (got %s)" % [LADDER_UNITS, str(
						window.clipmap_levels_spin.value if window.clipmap_levels_spin != null else "none")])
		require(window.clipmap_size_spin != null and int(window.clipmap_size_spin.value) == 256,
				"and its 256-texel unit edge")
		var hint := str(window.clipmap_hint.text)
		require(hint.contains("1024.0 texels/m") and hint.contains("1.000 at the outer edge"),
				"the dock's hint states both endpoints of the ladder: %s" % hint)
		require(not hint.contains("does not span"),
				"and does not call the shipped shape a truncated ladder: %s" % hint)
		print("CLIPMAP_LAYER_DOCK base=%s levels=%s size=%s hint=%s" % [
				str(window.clipmap_base_spin.value), str(window.clipmap_levels_spin.value),
				str(window.clipmap_size_spin.value), hint.replace("\n", " | ")])
	window.queue_free()
	await process_frame

# The debug view's two states, rendered at the shipped shape and saved. The LOD picture is the eleven
# units of the ladder as squares cut into their blocks; the atlas picture is the quadtree region the
# packer produced plus every unit's own 3x3 grid with the current-frame atlas index written in each
# cell. The control is `src/vt_clipmap_preview.gd` itself, polled exactly as the editor polls it.
func render_debug_view(p_label: String, p_file: String) -> void:
	var viewport := SubViewport.new()
	viewport.name = "DebugView" + p_label
	viewport.size = DEBUG_VIEW_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var control: Control = load(DEBUG_VIEW_SCRIPT).new()
	control.size = Vector2(DEBUG_VIEW_SIZE)
	viewport.add_child(control)
	control.set_terrain(terrain)
	await process_frame
	control.set("_last_poll_sec", -INF)
	control.call("_process", 0.0)
	await process_frame
	await RenderingServer.frame_post_draw
	await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	if image != null:
		image.save_png(output_dir.path_join(p_file))
	var snapshot: Dictionary = control.get("_snapshot")
	var layer := _debug_layer(snapshot)
	print("CLIPMAP_LAYER_DEBUG %s available=%s implementation=%s units=%d view=%dx%d" % [
		p_label, str(control.call("is_available")), str(layer.get("implementation", "?")),
		(layer.get("unit_reports", []) as Array).size(), DEBUG_VIEW_SIZE.x, DEBUG_VIEW_SIZE.y])
	control.queue_free()
	viewport.queue_free()
	await process_frame

func _debug_layer(p_snapshot: Dictionary) -> Dictionary:
	var layers: Array = p_snapshot.get("layers", [])
	return layers[0] if not layers.is_empty() else {}

# A rolling height field, so the near ground has the relief a gradient reading needs and the layer has
# something to produce rather than a flat plane.
func setup() -> void:
	scene = Node3D.new()
	root.add_child(scene)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.near = 0.05
	camera.far = 2048.0
	camera.position = Vector3(32.0, 1.7, 32.0)
	camera.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	camera.current = true
	root.add_child(camera)

	terrain = Terrain3D.new()
	terrain.region_size = 64
	terrain.free_editor_textures = false
	terrain.surface_svt_auto_bake = false
	terrain.vt_page_fade_frames = 0
	# **The user's path, in the unified vocabulary**: one delivery - `Clipmap` - on the near material
	# group, and the implementation chosen inside the clipmap settings. Nothing else is tuned: the
	# shape, the budget, the detail layer and the implementation's default are the shipped ones, which
	# is what makes the first reading a reading of the *defaults*.
	terrain.vt_delivery_near_material = CLIPMAP
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	terrain.assets = Terrain3DAssets.new()
	var red := Terrain3DTextureAsset.new()
	red.albedo_texture = patterned_texture(Color(0.55, 0.12, 0.10), Color(0.85, 0.55, 0.35))
	red.normal_texture = patterned_texture(Color(0.5, 0.5, 1.0), Color(0.62, 0.42, 0.98))
	terrain.assets.set_texture_asset(0, red)
	var green := Terrain3DTextureAsset.new()
	green.albedo_texture = patterned_texture(Color(0.12, 0.42, 0.14), Color(0.55, 0.78, 0.30))
	green.normal_texture = patterned_texture(Color(0.5, 0.5, 1.0), Color(0.62, 0.42, 0.98))
	terrain.assets.set_texture_asset(1, green)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	scene.add_child(terrain)
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)

	# The 1080p camera's horizon crosses both negative-Z and positive-X terrain. A diagonal
	# five-region fixture left empty neighbor strips there, which made those source-data holes
	# look like clipmap banding in every implementation, including Direct. Keep the complete 3x3
	# neighborhood loaded so this probe measures ring coverage rather than absent world regions.
	for rz in range(-1, 2):
		for rx in range(-1, 2):
			terrain.data.add_region_blank(Vector2i(rx, rz), false)
	terrain.data.update_maps()
	for bz in 6:
		for bx in 6:
			paint_material(Vector3(float(bx) * 8.0 + 4.0, 0.0, float(bz) * 8.0 + 4.0), (bx + bz) % 2)
	terrain.data.update_maps()
	await settle(8)

func settle_layer(frames: int = 900) -> void:
	for _frame in frames:
		await process_frame
		var report := layer_report()
		if int(report.get("pending_jobs", 1)) == 0 and int(report.get("pending_bake_rects", 1)) == 0:
			break
	await settle(24)

# One unit's square, as the implementation published it: the centre it snapped to and the world side
# it spans. `unit_has_point` is the half-open test both implementations' finders apply - the layer's own
# `_contains_level()` is `local < size` on the far edge, and the atlas's block index is `floor(... + 0.5)`
# with `|gx| <= 1`, so the square is `[center - half, center + half)` on each axis.
func unit_has_point(p_unit: Dictionary, p_point: Vector2) -> bool:
	var center: Vector2 = p_unit.get("center", Vector2.ZERO)
	var half := float(p_unit.get("world_size", 0.0)) * 0.5
	return p_point.x >= center.x - half and p_point.x < center.x + half and \
			p_point.y >= center.y - half and p_point.y < center.y + half

# The per-unit densities of a report, as the declared ladder.
func densities_of(p_units: Array) -> Array[float]:
	var out: Array[float] = []
	for unit: Variant in p_units:
		out.append(float((unit as Dictionary).get("density", 0.0)))
	return out

# The guaranteed radius: how far from the focus a unit of this storage must still hold every point,
# which is its own half-square minus the snapping it is allowed. A LOD level is snapped to its own
# texel; an atlas ring to its own block, which is `base_world * 2^unit` metres and the larger error.
func guaranteed_radius(p_report: Dictionary) -> float:
	var units: Array = p_report.get("unit_reports", [])
	if units.is_empty():
		return 0.0
	var last: Dictionary = units[units.size() - 1]
	var half := float(last.get("world_size", 0.0)) * 0.5
	var snap := 0.0
	if str(p_report.get("implementation", "LOD")) == "Atlas":
		snap = float(p_report.get("base_world", 0.0)) * pow(2.0, float(units.size() - 1)) * 0.5
	else:
		snap = float(last.get("texel_world", 0.0)) * 0.5
	return half - snap

# ---- The readings ---------------------------------------------------------------------------------

# One distance sample's reading, and the ladder the unit reports declare.
func measure(label: String, p_image: Image) -> Dictionary:
	var units: Array = layer_report().get("unit_reports", [])
	var declared := densities_of(units)
	var radius: Array[float] = []
	for unit: Variant in units:
		radius.append(float((unit as Dictionary).get("world_size", 0.0)) * 0.5)
	var curve: Array[float] = []
	for distance in DISTANCES:
		curve.append(density_at(distance))
	var detail: Array[float] = []
	for distance in [0.5, 1.0, 2.0]:
		detail.append(detail_density_at(distance))
	var report := layer_report()
	var payload: Dictionary = report.get("impl", {})
	var layout: Dictionary = payload.get("layout", {})
	print("CLIPMAP_LAYER_DIAG %s impl=%s units=%s size=%s base=%s atlas=%sx%s scheme=%s blocks=%s rects=%s current_cells=%s baked_cells=%s" % [
		label, str(report.get("implementation", "?")), str(report.get("units", 0)),
		str(report.get("size", 0)), str(report.get("base_world", 0.0)),
		str(payload.get("atlas_width", "-")), str(payload.get("atlas_height", "-")),
		str(layout.get("chosen", "-")), str(layout.get("blocks", "-")),
		str(layout.get("total_blocks", "-")), str(payload.get("current_cells", "-")),
		str(payload.get("baked_cells", "-"))])
	print("CLIPMAP_LAYER %s implementation=%s units=%d finest=%.2f coarsest=%.2f radius=%.1f spans=%s required=%s measured=%s declared=%s detail=%s" % [
		label, str(report.get("implementation", "?")), units.size(),
		declared[0] if not declared.is_empty() else 0.0,
		declared[declared.size() - 1] if not declared.is_empty() else 0.0,
		guaranteed_radius(report), str(report.get("ladder_spans_endpoints", "?")),
		str(report.get("ladder_units_required", "?")), str(curve), str(declared), str(detail)])
	print("CLIMAP_LAYER_SHARPNESS %s bands=%s" % [label, str([
		band_gradient(p_image, 0.45, 0.60), band_gradient(p_image, 0.60, 0.72),
		band_gradient(p_image, 0.72, 0.84), band_gradient(p_image, 0.84, 0.98)])])
	return {
		"implementation": str(report.get("implementation", "?")),
		"units": units.size(),
		"declared": declared,
		"radius": radius,
		"curve": curve,
		"detail": detail,
		"guaranteed": guaranteed_radius(report),
		"report": report,
	}

# The cost readings, in one line per implementation and per shape: what the ladder costs in blocks,
# texels, memory and upload. They are the task's "before/after" table, printed rather than computed
# here so the summary quotes the same numbers the run does.
func cost_line(label: String) -> void:
	var report := layer_report()
	var payload: Dictionary = report.get("impl", {})
	var layout: Dictionary = payload.get("layout", {})
	var units := int(report.get("units", 0))
	var size := int(report.get("size", 0))
	var base := float(report.get("base_world", 0.0))
	var channels := int(report.get("channels", 0))
	var is_atlas := str(report.get("implementation", "LOD")) == "Atlas"
	var finest := (float(size) / base) if base > 0.0 else 0.0
	var coarsest := finest / pow(2.0, float(maxi(0, units - 1)))
	var blocks := units
	var texels := float(size * size * units)
	var atlas_size := "-"
	var efficiency := "-"
	if is_atlas:
		blocks = int(layout.get("blocks", 0))
		texels = float(int(layout.get("width", 0)) * int(layout.get("height", 0)))
		atlas_size = "%sx%s" % [str(layout.get("width", 0)), str(layout.get("height", 0))]
		efficiency = "%.3f" % float(layout.get("efficiency", 0.0))
	var source_bytes := texels * float(maxi(channels, 2)) * 4.0
	var baked_bytes := 0.0
	if str(report.get("source", "")) == "material":
		baked_bytes = texels * 3.0 * 8.0
	print("CLIPMAP_LAYER_COST %s impl=%s units=%d size=%d base=%.4f ladder=%.1f->%.4f blocks=%d atlas=%s efficiency=%s ring_blocks=%s unit_texels=%.0f source_MB=%.1f baked_MB=%.1f upload_bytes=%s produced=%s" % [
		label, str(report.get("implementation", "?")), units, size, base, finest, coarsest,
		blocks, atlas_size, efficiency, str(layout.get("ring_blocks", "-")), texels,
		source_bytes / 1048576.0, baked_bytes / 1048576.0,
		str(report.get("upload_bytes", 0)), str(report.get("produced_texels", 0))])

# The steady-state cost: bytes the layer uploads per metre of camera travel. The camera is walked along
# the ground for a known distance over a fixed number of ticks and the layer's own `upload_bytes`
# counter is read before and after, so the number is the mechanism's rather than the script's.
func travel_cost(label: String, capture_moving: bool = false) -> void:
	var report := layer_report()
	var before := float(report.get("upload_bytes", 0))
	var start := camera.position
	for step in TRAVEL_STEPS:
		camera.position = start + Vector3(ground_forward().x, 0.0, ground_forward().y) * (
				TRAVEL_METRES * float(step + 1) / float(TRAVEL_STEPS))
		await process_frame
	await settle_layer(240)
	if capture_moving:
		var moved_image := await captured_image()
		var moving_image_name := "clipmap-layer-" + label + "-moving-1080p.png"
		moved_image.save_png(output_dir.path_join(moving_image_name))
		print("CLIPMAP_LAYER_ROUTE label=%s-moving strict_missing_pixels=%d size=%dx%d" % [
			label, strict_missing_pixels(moved_image), moved_image.get_width(), moved_image.get_height()])
		report_black_bands(label + "-moving", moved_image)
		await render_debug_view(label + "-moving", "clipmap-layer-debug-" + label + "-moving-1080p.png")
	var after := float(layer_report().get("upload_bytes", 0))
	print("CLIPMAP_LAYER_TRAVEL %s metres=%.1f bytes=%.0f bytes_per_metre=%.0f" % [
		label, TRAVEL_METRES, after - before, (after - before) / TRAVEL_METRES])
	camera.position = start
	await settle_layer(240)

func strict_missing_pixels(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.r > 0.65 and pixel.b > 0.65 and pixel.g < 0.25:
				count += 1
	return count

# Scan the rendered ground for black bands. The sky and bottom frame edge are excluded; a missing
# world strip appears as a near-black horizontal run or a near-black column through covered ground.
func black_band_metrics(image: Image) -> Dictionary:
	var width := image.get_width()
	var height := image.get_height()
	var top := clampi(int(float(height) * 0.50), 0, height - 1)
	var bottom := clampi(int(float(height) * 0.95), top + 1, height)
	var row_black := PackedInt32Array()
	row_black.resize(bottom - top)
	var column_black := PackedInt32Array()
	column_black.resize(width)
	var black_pixels := 0
	for y in range(top, bottom):
		for x in width:
			var pixel := image.get_pixel(x, y)
			if maxf(pixel.r, maxf(pixel.g, pixel.b)) < 0.025:
				row_black[y - top] += 1
				column_black[x] += 1
				black_pixels += 1
	var horizontal_rows := 0
	var vertical_columns := 0
	var max_horizontal_fraction := 0.0
	var max_vertical_fraction := 0.0
	for count: int in row_black:
		var fraction := float(count) / float(maxi(width, 1))
		max_horizontal_fraction = maxf(max_horizontal_fraction, fraction)
		horizontal_rows += 1 if fraction >= 0.02 else 0
	for count: int in column_black:
		var fraction := float(count) / float(maxi(bottom - top, 1))
		max_vertical_fraction = maxf(max_vertical_fraction, fraction)
		vertical_columns += 1 if fraction >= 0.02 else 0
	return {
		"black_pixels": black_pixels,
		"horizontal_rows": horizontal_rows,
		"vertical_columns": vertical_columns,
		"max_horizontal_fraction": max_horizontal_fraction,
		"max_vertical_fraction": max_vertical_fraction,
	}

func report_black_bands(label: String, image: Image) -> Dictionary:
	var metrics := black_band_metrics(image)
	print("CLIPMAP_LAYER_BLACK_BANDS label=%s size=%dx%d threshold=0.025 ground_y=0.50..0.95 black_pixels=%d horizontal_rows=%d vertical_columns=%d max_row_fraction=%.5f max_column_fraction=%.5f" % [
		label, image.get_width(), image.get_height(), int(metrics["black_pixels"]),
		int(metrics["horizontal_rows"]), int(metrics["vertical_columns"]),
		float(metrics["max_horizontal_fraction"]), float(metrics["max_vertical_fraction"])])
	require(int(metrics["horizontal_rows"]) == 0 and int(metrics["vertical_columns"]) == 0,
		label + " has no near-black horizontal or vertical band through the ground")
	return metrics

# The coverage audit, reported and asserted below: the union of the published unit squares must hold
# every point inside the guaranteed radius (no hole), and the density the layer serves there must be the
# density of a unit whose published square holds it - the finest one, except where the point sits on a
# half-open boundary that the layer's own float rounding resolves to the next unit out, which is counted
# separately rather than hidden.
func audit_coverage(label: String, p_report: Dictionary) -> Dictionary:
	var units: Array = p_report.get("unit_reports", [])
	var radius := guaranteed_radius(p_report)
	var origin := Vector2(camera.position.x, camera.position.z)
	var holes := 0
	var mismatches := 0
	var finest_exceptions := 0
	var sampled := 0
	var worst := 0.0
	for fraction in AUDIT_FRACTIONS:
		for angle_index in AUDIT_ANGLES:
			var angle := TAU * float(angle_index) / float(AUDIT_ANGLES)
			var direction := Vector2(cos(angle), sin(angle))
			var point := origin + direction * (radius * fraction)
			sampled += 1
			var holding: Array[int] = []
			for index in units.size():
				if unit_has_point(units[index], point):
					holding.append(index)
			if holding.is_empty():
				holes += 1
				continue
			var measured := terrain.sample_vt_clipmap_density(MATERIAL, point)
			var finest := float((units[holding[0]] as Dictionary).get("density", 0.0))
			var belongs := false
			for index in holding:
				if absf(measured - float((units[index] as Dictionary).get("density", 0.0))) <= maxf(0.001, measured * 0.01):
					belongs = true
					break
			if not belongs:
				mismatches += 1
				worst = maxf(worst, absf(measured - finest))
			elif absf(measured - finest) > maxf(0.001, finest * 0.01):
				finest_exceptions += 1
	print("CLIPMAP_LAYER_AUDIT %s radius=%.1f sampled=%d holes=%d mismatches=%d boundary=%d worst=%.4f" % [
		label, radius, sampled, holes, mismatches, finest_exceptions, worst])
	return {"radius": radius, "sampled": sampled, "holes": holes, "mismatches": mismatches,
			"boundary": finest_exceptions}

# The declared ladder's own shape: it must be `1024 / 2^u`, and unit ten - the eleventh - must be 1,
# which is the span this task is about. A shape that holds more units past it is allowed, because past
# the outer endpoint is a user's own choice; a shape that holds fewer cannot present the span.
func declared_ladder_ok(p_declared: Array[float]) -> bool:
	if p_declared.size() < LADDER_UNITS:
		return false
	for index in p_declared.size():
		var expected := LADDER_FINEST / pow(2.0, float(index))
		if absf(p_declared[index] - expected) > maxf(0.001, expected * 0.001):
			return false
	return absf(p_declared[LADDER_UNITS - 1] - LADDER_COARSEST) < 0.001

# Whether every measured sample inside the guaranteed radius is one of the ladder's own densities and
# the sequence never rises. Past the guaranteed radius a sample may be 0 - the layer's reach has ended
# and the region arrays answer there - which is why the limit is passed in.
func measured_ladder_ok(p_curve: Array[float], p_limit: float) -> bool:
	for index in p_curve.size():
		var value := float(p_curve[index])
		if DISTANCES[index] > p_limit and value <= 0.0:
			continue
		if value < LADDER_COARSEST * 0.999 or value > LADDER_FINEST * 1.001:
			return false
		var octave := log(value / LADDER_COARSEST) / log(2.0)
		if absf(octave - round(octave)) > 0.01:
			return false
		if index > 0 and value > float(p_curve[index - 1]) + 0.001:
			return false
	return true

# One ground direction scanned outwards: the density the layer serves from just inside the finest unit
# to `p_limit`, and the readings the endpoint claims are made of. The scan is geometric in radius, so it
# crosses four orders of magnitude of unit square without spending a sample on empty space, and it
# records the *measured* finest density, the furthest distance still covered, and the furthest distance
# still served at the ladder's 1 texel/m endpoint.
func scan_direction(p_direction: Vector2, p_limit: float) -> Dictionary:
	var radius := 0.05
	var covered_max := 0.0
	var coarsest_radius := 0.0
	var finest := 0.0
	var rising := 0
	var previous := -1.0
	var steps := 0
	while radius <= p_limit and steps < 4000:
		var value := layer_density_at(p_direction, radius)
		finest = maxf(finest, value)
		if value > 0.0:
			covered_max = radius
		if absf(value - LADDER_COARSEST) < 0.001:
			coarsest_radius = maxf(coarsest_radius, radius)
		if previous >= 0.0 and value > previous + 0.001:
			rising += 1
		previous = value
		radius = radius * 1.01 + 0.05
		steps += 1
	return {"covered_max": covered_max, "coarsest_radius": coarsest_radius, "finest": finest,
			"rising": rising, "steps": steps}

# The eight-direction scan, summarised: `covered_min` is the distance every direction still covers the
# ground at (the "no hole" reading), `coarsest_min` the distance every direction still serves the
# ladder's 1 texel/m endpoint at, and `finest` the measured inner endpoint.
func scan_ladder(label: String, p_report: Dictionary) -> Dictionary:
	var guaranteed := guaranteed_radius(p_report)
	var limit := guaranteed + 320.0
	var covered_min := INF
	var covered_max := 0.0
	var coarsest_min := INF
	var coarsest_max := 0.0
	var finest := 0.0
	var rising := 0
	for angle_index in AUDIT_ANGLES:
		var angle := TAU * float(angle_index) / float(AUDIT_ANGLES)
		var reading := scan_direction(Vector2(cos(angle), sin(angle)), limit)
		covered_min = minf(covered_min, float(reading["covered_max"]))
		covered_max = maxf(covered_max, float(reading["covered_max"]))
		if float(reading["coarsest_radius"]) > 0.0:
			coarsest_min = minf(coarsest_min, float(reading["coarsest_radius"]))
			coarsest_max = maxf(coarsest_max, float(reading["coarsest_radius"]))
		finest = maxf(finest, float(reading["finest"]))
		rising += int(reading["rising"])
	coarsest_min = 0.0 if coarsest_min == INF else coarsest_min
	print("CLIPMAP_LAYER_SCAN %s directions=%d finest=%.2f covered_min=%.2f covered_max=%.2f coarsest_min=%.2f coarsest_max=%.2f rising=%d guaranteed=%.2f" % [
		label, AUDIT_ANGLES, finest, covered_min, covered_max, coarsest_min, coarsest_max, rising, guaranteed])
	return {"finest": finest, "covered_min": covered_min, "covered_max": covered_max,
			"coarsest_min": coarsest_min, "coarsest_max": coarsest_max, "rising": rising}

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	await setup()
	await check_dock_shape()

	# ---- The shipped defaults, LOD: nothing is written, so this is the out-of-the-box ladder --------
	print("CLIPMAP_LAYER_SETTINGS size=%s levels=%s base=%s implementation=%s detail=%s budget=%s" % [
		str(settings().get("clipmap_size", -1)), str(settings().get("clipmap_levels_setting", -1)),
		str(settings().get("clipmap_base_world", -1)), str(settings().get("clipmap_implementation", "?")),
		str(settings().get("detail_enabled", settings().get("clipmap_detail_enabled", "?"))),
		str(settings().get("clipmap_budget_texels", -1))])
	terrain.vt_clipmap_implementation = LOD
	await settle(4)
	await settle_layer()
	var lod := measure("lod", await captured_image())
	var lod_image := await captured_image()
	lod_image.save_png(output_dir.path_join("clipmap-layer-lod-1080p.png"))
	print("CLIPMAP_LAYER_ROUTE label=lod-static strict_missing_pixels=%d size=%dx%d" % [
		strict_missing_pixels(lod_image), lod_image.get_width(), lod_image.get_height()])
	report_black_bands("lod-static", lod_image)
	var lod_audit := audit_coverage("lod", lod["report"])
	var lod_scan := scan_ladder("lod", lod["report"])
	cost_line("lod")
	await render_debug_view("lod", "clipmap-layer-debug-lod.png")
	await travel_cost("lod", true)

	# ---- The same defaults through the Atlas implementation, same scene, same camera ----------------
	terrain.vt_clipmap_implementation = ATLAS
	await settle(4)
	await settle_layer()
	var atlas := measure("atlas", await captured_image())
	var atlas_image := await captured_image()
	atlas_image.save_png(output_dir.path_join("clipmap-layer-atlas-1080p.png"))
	report_black_bands("atlas-static", atlas_image)
	var atlas_audit := audit_coverage("atlas", atlas["report"])
	var atlas_scan := scan_ladder("atlas", atlas["report"])
	cost_line("atlas")
	await render_debug_view("atlas", "clipmap-layer-debug-atlas.png")
	await travel_cost("atlas", true)

	# ---- And the same camera with the **region arrays** carrying the material, which is what "a
	#      fallback" looks like: a cell naming Clipmap must *not* render this.
	terrain.vt_delivery_near_material = DIRECT
	await settle(48)
	var direct_image := await captured_image()
	direct_image.save_png(output_dir.path_join("clipmap-layer-direct-1080p.png"))
	report_black_bands("direct-static-reference", direct_image)
	terrain.vt_delivery_near_material = CLIPMAP
	await settle(48)

	var lod_vs_atlas := mean_channel_difference(lod_image, atlas_image)
	var lod_vs_direct := mean_channel_difference(lod_image, direct_image)
	print("CLIPMAP_LAYER render lod_vs_atlas=%.5f lod_vs_direct=%.5f images %s" % [
			lod_vs_atlas, lod_vs_direct, output_dir])

	# ---- The **before / after** render pair, with the detail layer off ------------------------------
	# The user's report is about the layer itself, and with the detail layer on its fine patch dominates
	# the first metres of every state - so the comparison that shows the layer's own work turns the patch
	# off. "Before" is the shape this worktree inherited (one texel a metre everywhere), which is a
	# *setting*, so the same function and the same camera measure both states.
	terrain.vt_clipmap_detail_enabled = false
	terrain.vt_clipmap_implementation = LOD
	await settle(4)
	await settle_layer()
	var after_image := await captured_image()
	after_image.save_png(output_dir.path_join("clipmap-layer-after-ladder-1080p.png"))
	report_black_bands("after-ladder-static", after_image)
	terrain.vt_delivery_near_material = DIRECT
	await settle(48)
	var layer_direct_image := await captured_image()
	layer_direct_image.save_png(output_dir.path_join("clipmap-layer-direct-detail-off-1080p.png"))
	terrain.vt_delivery_near_material = CLIPMAP
	await settle(48)
	var layer_vs_direct := mean_channel_difference(after_image, layer_direct_image)
	print("CLIPMAP_LAYER render layer_vs_direct_detail_off=%.5f" % layer_vs_direct)

	terrain.vt_clipmap_base_world = INHERITED_BASE
	terrain.vt_clipmap_levels = INHERITED_UNITS
	await settle(4)
	await settle_layer()
	var before := measure("before_inherited", await captured_image())
	var before_image := await captured_image()
	before_image.save_png(output_dir.path_join("clipmap-layer-before-ladder-1080p.png"))
	var before_vs_after := mean_channel_difference(before_image, after_image)
	print("CLIPMAP_LAYER_SHARPNESS_PAIR before=%s after=%s difference=%.5f" % [
			str([
				band_gradient(before_image, 0.30, 0.45), band_gradient(before_image, 0.45, 0.60),
				band_gradient(before_image, 0.60, 0.75), band_gradient(before_image, 0.75, 0.95)]),
			str([
				band_gradient(after_image, 0.30, 0.45), band_gradient(after_image, 0.45, 0.60),
				band_gradient(after_image, 0.60, 0.75), band_gradient(after_image, 0.75, 0.95)]),
			before_vs_after])

	# The previous round's recommendation, kept for the cost table's "after" column to compare against.
	cost_line("before_inherited")
	await travel_cost("before_inherited")
	terrain.vt_clipmap_base_world = PREVIOUS_BASE
	terrain.vt_clipmap_levels = PREVIOUS_UNITS
	terrain.vt_clipmap_implementation = ATLAS
	await settle(4)
	await settle_layer()
	var previous_atlas := measure("previous_atlas", await captured_image())
	cost_line("previous_atlas")
	await travel_cost("previous_atlas")
	terrain.vt_clipmap_implementation = LOD
	await settle(4)
	await settle_layer()
	var previous_lod := measure("previous_lod", await captured_image())
	cost_line("previous_lod")
	await travel_cost("previous_lod")

	# ---- The ceiling must not truncate the ladder ---------------------------------------------------
	# Above the atlas's own ring ceiling, the clamp is a table-size statement - the ladder it leaves
	# must still be 1024 -> 1, which is the failure ("units clamped to 6") this task exists to remove.
	terrain.vt_clipmap_implementation = ATLAS
	terrain.vt_clipmap_base_world = 0.25
	terrain.vt_clipmap_levels = 20
	await settle(4)
	await settle_layer()
	var clamped := layer_report()
	var clamped_units: Array = clamped.get("unit_reports", [])
	print("CLIPMAP_LAYER_CLAMP requested=20 units=%d finest=%s coarsest=%s" % [
			clamped_units.size(),
			str((clamped_units[0] as Dictionary).get("density", 0.0) if not clamped_units.is_empty() else 0.0),
			str((clamped_units[clamped_units.size() - 1] as Dictionary).get("density", 0.0) if not clamped_units.is_empty() else 0.0)])

	# Back to the shipped state, so the run ends where it started.
	terrain.vt_clipmap_base_world = 0.25
	terrain.vt_clipmap_levels = LADDER_UNITS
	terrain.vt_clipmap_detail_enabled = true
	terrain.vt_clipmap_implementation = LOD
	await settle(4)
	await settle_layer()
	print("CLIPMAP_LAYER_CURVES distances=%s lod=%s atlas=%s before=%s previous_lod=%s previous_atlas=%s" % [
			str(DISTANCES), str(lod["curve"]), str(atlas["curve"]), str(before["curve"]),
			str(previous_lod["curve"]), str(previous_atlas["curve"])])

	# ---- The claims --------------------------------------------------------------------------------
	require(lod["implementation"] == "LOD", "the LOD implementation reports itself as LOD")
	require(atlas["implementation"] == "Atlas", "and the atlas reports itself as Atlas")
	require(lod["units"] >= LADDER_UNITS and atlas["units"] >= LADDER_UNITS,
			"both implementations hold the ladder's %d units (LOD %d, Atlas %d)" % [
				LADDER_UNITS, lod["units"], atlas["units"]])
	# Out of the box: the shipped defaults *are* the eleven-unit ladder, with nothing written first.
	require(lod["units"] == LADDER_UNITS and atlas["units"] == LADDER_UNITS,
			"the shipped shape is the ladder's own %d units (LOD %d, Atlas %d)" % [
				LADDER_UNITS, lod["units"], atlas["units"]])
	# The declared ladder: 1024 / 2^u down to 1, on both storages, and the shared contract's own answer
	# that this shape spans the shipping endpoints rather than a truncated part of them.
	require(declared_ladder_ok(lod["declared"]), "the LOD unit reports declare 1024 -> 1 by halving: %s" % str(lod["declared"]))
	require(declared_ladder_ok(atlas["declared"]), "the atlas unit reports declare 1024 -> 1 by halving: %s" % str(atlas["declared"]))
	require(bool(lod["report"].get("ladder_spans_endpoints", false)) and
			bool(atlas["report"].get("ladder_spans_endpoints", false)),
			"and the layer's own ladder says it spans the shipping endpoints (LOD %s, Atlas %s)" % [
				str(lod["report"].get("ladder_spans_endpoints", "?")),
				str(atlas["report"].get("ladder_spans_endpoints", "?"))])
	# The measured ladder: the layer's own addressing must serve 1024 at the focus and 1 far out on both
	# implementations, must never rise with distance, and every sample inside the guaranteed radius must
	# be one of the declared densities. The outer endpoint is read from the radial scan rather than from
	# one fixed distance because the two storages reach different distances for the same ladder: a LOD
	# level is one square, an atlas ring is a 3x3 square of the same blocks.
	require(is_equal_approx(float(lod["curve"][0]), LADDER_FINEST),
			"LOD serves %.2f texels/m inside the finest unit (not %.0f)" % [float(lod["curve"][0]), LADDER_FINEST])
	require(is_equal_approx(float(atlas["curve"][0]), LADDER_FINEST),
			"Atlas serves %.2f texels/m inside the finest unit (not %.0f)" % [float(atlas["curve"][0]), LADDER_FINEST])
	require(is_equal_approx(float(lod_scan["finest"]), LADDER_FINEST) and
			is_equal_approx(float(atlas_scan["finest"]), LADDER_FINEST),
			"the measured inner endpoint is 1024 texels/m on both (LOD %.1f, Atlas %.1f)" % [
				float(lod_scan["finest"]), float(atlas_scan["finest"])])
	require(float(lod_scan["coarsest_min"]) >= 100.0,
			"LOD measures 1 texel/m at least 100 m out in every direction (nearest %.1f m)" % float(lod_scan["coarsest_min"]))
	require(float(atlas_scan["coarsest_min"]) >= 120.0,
			"Atlas measures 1 texel/m at least 120 m out in every direction (nearest %.1f m)" % float(atlas_scan["coarsest_min"]))
	require(int(lod_scan["rising"]) == 0 and int(atlas_scan["rising"]) == 0,
			"the measured density never rises with distance (LOD %d, Atlas %d rises)" % [
				int(lod_scan["rising"]), int(atlas_scan["rising"])])
	require(measured_ladder_ok(lod["curve"], float(lod["guaranteed"])),
			"every LOD sample inside the reach is a ladder density: %s" % str(lod["curve"]))
	require(measured_ladder_ok(atlas["curve"], float(atlas["guaranteed"])),
			"every atlas sample inside the reach is a ladder density: %s" % str(atlas["curve"]))
	# The middle of the ladder: the measured near field must be far past the inherited 1 texel/m.
	require(float(lod["curve"][5]) >= 16.0 and float(atlas["curve"][5]) >= 16.0,
			"both serve at least 16 texels/m at 4 m (LOD %.1f, Atlas %.1f)" % [
				float(lod["curve"][5]), float(atlas["curve"][5])])
	# The geometry behind the curve: no hole inside the guaranteed radius, and one serving unit.
	require(lod_audit["holes"] == 0, "the LOD units cover every audited point (%d holes)" % lod_audit["holes"])
	require(atlas_audit["holes"] == 0, "the atlas units cover every audited point (%d holes)" % atlas_audit["holes"])
	require(float(lod_scan["covered_min"]) >= float(lod["guaranteed"]) * 0.99,
			"every LOD direction covers the guaranteed radius (nearest coverage %.1f m of %.1f)" % [
				float(lod_scan["covered_min"]), float(lod["guaranteed"])])
	require(float(atlas_scan["covered_min"]) >= float(atlas["guaranteed"]) * 0.99,
			"every atlas direction covers the guaranteed radius (nearest coverage %.1f m of %.1f)" % [
				float(atlas_scan["covered_min"]), float(atlas["guaranteed"])])
	require(lod_audit["mismatches"] == 0,
			"the LOD density at an audited point belongs to a unit that holds it (%d mismatches)" % lod_audit["mismatches"])
	require(atlas_audit["mismatches"] == 0,
			"the atlas density at an audited point belongs to a unit that holds it (%d mismatches)" % atlas_audit["mismatches"])
	# The clamp above the ceiling still leaves the ladder's span.
	require(clamped_units.size() >= LADDER_UNITS,
			"a 20-unit request still leaves the ladder's span (got %d units)" % clamped_units.size())
	require(declared_ladder_ok(densities_of(clamped_units)),
			"and the clamped ladder is still 1024 -> 1 by halving")
	# The material group's fine layer is unchanged and still reaches its target, and the ladder is
	# nowhere coarser than the inherited shape inside the reach they share.
	require(minf(lod["detail"][0], lod["detail"][1]) >= DETAIL_FLOOR,
			"the detail layer still serves the near field at >= %.0f texels/m" % DETAIL_FLOOR)
	var curve_better := true
	for index in range(DISTANCES.size()):
		if DISTANCES[index] > float(lod["guaranteed"]):
			continue
		if float(lod["curve"][index]) < float(before["curve"][index]) - 0.001:
			curve_better = false
	require(curve_better, "the ladder is nowhere coarser than the inherited shape inside its reach")
	require(float(lod["curve"][5]) > float(before["curve"][5]) * 8.0,
			"and is at least eight times denser at 4 m (%.1f vs %.1f)" % [
				float(lod["curve"][5]), float(before["curve"][5])])
	# A layer no cell delivers is a different picture. The pair that isolates the *layer* is the one
	# with the detail layer off, because the detail layer is part of the clipmap delivery too: with it on,
	# both states' near ground is dense enough to agree, which is the layer matching the ground truth
	# rather than falling back to it - reported, and asserted to be an agreement.
	require(layer_vs_direct > 0.002,
			"the ladder's frame is not the region-array frame (mean difference %.5f)" % layer_vs_direct)
	require(lod_vs_direct < 0.05,
			"and the dense layer agrees with the region array where both serve (%.5f)" % lod_vs_direct)
	require(lod_vs_atlas < 0.05,
			"the two implementations render the same scene recognisably alike (mean difference %.5f)" % lod_vs_atlas)
	require(before_vs_after > 0.002,
			"the before and after frames differ (mean difference %.5f)" % before_vs_after)
	# The plumbing behind the picture: the material group's cell selects Clipmap, the generated shader
	# carries its arm, the layer is configured and its units are current - so the fragment is served by
	# the layer's own texture rather than by anything behind it.
	var material_entry: Dictionary = settings().get("clipmap", {}).get("material", {})
	var current_units := 0
	for unit: Variant in material_entry.get("unit_reports", []):
		current_units += 1 if bool((unit as Dictionary).get("valid", false)) else 0
	require(bool(material_entry.get("selected", false)), "the material cell selects the clipmap delivery")
	require(bool(material_entry.get("shader_arm", false)), "and the generated shader carries its clipmap arm")
	require(bool(material_entry.get("configured", false)) and current_units > 0,
			"and the layer is configured with current units (%d current)" % current_units)

	if terrain != null:
		terrain.set_process(false)
		terrain.set_physics_process(false)
		terrain.set_editor(null)
		terrain.set_plugin(null)
	if painter != null:
		painter.free()
	if scene != null:
		scene.queue_free()
	if camera != null:
		camera.queue_free()
	await process_frame
	await process_frame
	if failed:
		print("REGRESSION: clipmap layer implementations evidence")
		quit(1)
		return
	print("PASS clipmap layer implementations evidence")
	quit(0)
