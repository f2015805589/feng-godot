# Run with a graphical rendering driver; see README.md in this directory.
#
# 1024 texels/m acceptance for the *clipmap material* path.
#
# The requirement this test exists for is stated in `F:/godot/auto-work/plan_final.md` section 1:
# with `vt_delivery_near_material = Clipmap`, the near ground a 1080p view samples must actually
# deliver **1024 texels per metre** - a texel no wider than 1/1024 m (about 0.977 mm) - and it must
# be the *material a fragment samples*, not a parameter that was set or a texture that was
# allocated. The plan's stage 2 adds a detail layer for exactly this: the existing coarse ring
# stays as coverage and fallback, and fine tiles are resident where the view's footprint asks for
# them. This test is written *before* that feature exists, so a run on the pre-merge binary is
# expected to fail; what it must never do is fail to run. Its failures say which half is missing.
#
# The five claims, one reading each:
#
#  1. **The delivered density is measured, not requested.** The probe point is the ground 1.6 m in
#     front of the camera at the project's gameplay pose (1920x1080, 1.7 m eye, 8 degrees down).
#     The *delivered* density is the finest source that can answer that point: a resident detail
#     tile if the report publishes one, otherwise the finest *baked* coarse ring level whose own
#     square contains the point. A level's density is `size / (base_world * 2^level)`, i.e. the
#     reciprocal of the `texel_world` its level report carries. Requested density, delivered
#     density, missing tiles, fallback samples and cache bytes are read from `get_vt_settings()`.
#     The assertion is `delivered >= 1024`. Its failure text is "密度未达标" ("density not met").
#
#  2. **The density holds over the visible near ground, not at one point.** Every on-screen ground
#     point within 8 m of the camera is sampled; the hit rate is the fraction that reaches 1024.
#     The floor is 0.90: at least nine of ten visible near points must be served at the acceptance
#     density, because a single fine patch beside the camera is not the visible region. The reading
#     is repeated after a camera move, which is the other half of "the fine field follows the view".
#
#  3. **The shader probe tells the three sources apart.** One render, read back from the screen,
#     with the palette bound through the material RID's own uniforms. The payload fallback is bound
#     blue through every door it can come from - the region texture array `_texture_array_albedo`,
#     the AVT page array `_surface_material_albedo` and the far field's `_surface_svt_material_albedo`
#     - so a *blue* patch is the payload evaluation (region array or page) serving it. Anything else
#     is the ring's own baked layers; which of the ring's two granularities they are is read from
#     the level and density the report publishes, and from `_clipmap_detail_albedo` (bound green) on
#     a build that gives the detail layer separate samplers - the contract this test imposes on such
#     a build. The probe's calibration is part of the reading: deselecting the ring must show blue
#     and the coarse-only ring must show the ring's own material, or a "detail" reading would mean
#     nothing. The coarse baked layers are deliberately not repainted: `_clipmap_baked_albedo` is
#     bound by the addon as the ring's own two-group array on every uniform republication, and an
#     override of it was measured to sample as black and force the arm's fallback, which would make
#     the probe measure itself. The readings are taken with the terrain's tick frozen, because the
#     far field's page-arrival fade republishes the material's textures every frame it runs.
#
#  4. **The picture is right after the operations the plan names.** A draw edit, a material
#     replacement (the probe patch's albedo updated in place - an asset swap was measured to leave
#     the renderer without a uniform set for several frames, an engine error the harness forbids),
#     a probe patch that straddles a material boundary (the "cross tile boundary" case) and
#     `surface_array_enabled = false` are each exercised, and each is judged against the array
#     path's own render or against the render before the operation - the material the ring serves
#     must be the material the array serves, and an edit or a replacement must reach the screen. A
#     coarse ring point-sampling a different texel, or a stale baked layer, shows up as a patch
#     whose mean channel difference is far above the bound. The probe is unbound for these
#     renders: they compare the real material, not the probe's palette.
#
#  5. **Both far-field configurations are covered.** The plan accepts `Clipmap` with the far field
#     `Direct` (the ring stands alone - the plan's stage 1 case) and with the far field `SVT` (the
#     shared producer is up, which is what bakes the ring today). The source and density probes run
#     in both; the operations of claim 4 run with the far field up, because that is the only
#     configuration in which a bake exists before the stage 1 change.
#
# The scene follows the project's convention (`vt_near_density.gd`): 1920x1080 through the runner's
# `--resolution`, a 1.7 m eye pitched 8 degrees down over blank 64 m regions, the shipped texture
# assets, and the near-field tick left to the product rather than driven by hand. The ring is
# configured at a sane coarse density (256 texels over 256 m, four levels), *not* shrunk to a
# fraction of a metre to fake the number: the plan is explicit that a small `base_world` makes
# level 0 dense but only 0.25 m wide, and the probe point at 1.6 m would fall to a coarse level.
# The density has to come from the detail layer, which is the point of the test.
#
# The material group is (Material=0/Height=1) and the delivery values are
# (Direct=0/AVT=1/Clipmap=2/SVT=3), i.e. the native `TerrainVT` enum values.
extends "res://vt_probe_base.gd"

const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2
const SVT := 3

# The acceptance density and the breadth of the visible near field it has to hold over. See the
# header: 1024 texels/m is the plan's number, and 0.90 is the chosen hit-rate floor.
const TARGET_DENSITY := 1024.0
const DENSITY_FLOOR := 1024.0
const HIT_RATE_FLOOR := 0.90
const NEAR_RADIUS := 8.0
# The plan's probe point: the ground in front of the camera at the gameplay pose.
const PROBE_FORWARD_M := 1.6
# The half-width of the screen patch a reading is taken over, and the mean-channel-difference bound
# an operation may not exceed. Half a step of an 8-bit image is 0.002, so 0.06 is a whole material
# step - a wrong texel, a stale layer or a missing edit is orders of magnitude past it.
const PATCH_RADIUS := 3
const PATCH_DELTA := 0.06

# A sane coarse ring: level l covers `256 * 2^l` metres at `2^-l` texels per metre, so level 0 is
# 1 texel/m over +/-128 m and the probe point at 1.6 m is answered by level 0. The detail layer is
# what has to reach 1024; the coarse ring only has to be a correct fallback.
const RING_SIZE := 256
const RING_LEVELS := 4
const RING_BASE_WORLD := 256.0

# The source probe's palette. The payload fallback is blue through every door it can come from; the
# detail layer's own sampler, when a build has one, is green. The real texture assets are
# deliberately neither, so "neither poison colour" means the ring's own baked layers answered.
const ARRAY_COLOR := Color(0.05, 0.05, 0.95, 1.0)
const DETAIL_COLOR := Color(0.05, 0.95, 0.05, 1.0)
const ASSET_RED := Color(0.60, 0.60, 0.60, 1.0)
const ASSET_GREEN := Color(0.85, 0.75, 0.15, 1.0)
const REPLACED_COLOR := Color(0.95, 0.15, 0.85, 1.0)

var target: Node3D
var light: DirectionalLight3D
var painter: Terrain3DEditor
var brush: Image
var mat_rid := RID()
var applied_detail_settings: PackedStringArray = PackedStringArray()

# The bindings the source probe takes over, so the real materials come back unchanged.
var saved_region_albedo: Variant
var saved_page_albedo: Variant
var saved_svt_albedo: Variant
var saved_detail_albedo: Variant
var detail_sampler_present := false
var probe_array_albedo: Texture2DArray
var probe_detail_albedo: Texture2DArray


# ---- stand-ins for Terrain3DEditorPlugin's undo interface ---------------------------------------

func create_undo_action(_name: String) -> void:
	pass


func add_undo_method(_action: Callable) -> void:
	pass


func add_do_method(_action: Callable) -> void:
	pass


func commit_action(_execute: bool) -> void:
	pass


# ---- readings -----------------------------------------------------------------------------------

func settings() -> Dictionary:
	return terrain.get_vt_settings()


func mat_entry() -> Dictionary:
	return settings().get("clipmap", {}).get("material", {})


func preview_group(preview: Dictionary, group_name: String) -> Dictionary:
	for layer: Dictionary in preview.get("layers", []):
		if str(layer.get("group", "")) == group_name:
			return layer
	return {}


func density_series_text(densities: PackedFloat32Array) -> String:
	var values := PackedStringArray()
	for density in densities:
		values.append("%.0f" % float(density))
	return "[" + ",".join(values) + "]"


# Read the layers the native clipmap mechanism actually configured before the render fixture applies
# its deliberately coarse legacy Material shape. This keeps the material and height defaults visible
# in the named density probe instead of relying only on property values or another test family.
func probe_actual_group_ladders() -> void:
	terrain.call("debug_update_vt_clipmap", HEIGHT)
	terrain.call("debug_update_vt_clipmap", MATERIAL)
	var preview := terrain.get_clipmap_layout_preview()
	var material_layer := preview_group(preview, "material")
	var height_layer := preview_group(preview, "height")
	require(not material_layer.is_empty() and not height_layer.is_empty(),
			"the density probe exposes actual Material and Height clipmap layers")
	var material_densities: PackedFloat32Array = material_layer.get("unit_density", PackedFloat32Array())
	var height_densities: PackedFloat32Array = height_layer.get("unit_density", PackedFloat32Array())
	print("CLIPMAP_DENSITY ladders material=%s height=%s" % [
		density_series_text(material_densities), density_series_text(height_densities)])
	var material_ladder_ok := material_densities.size() == 11
	if material_ladder_ok:
		material_ladder_ok = is_equal_approx(material_densities[0], 1024.0) and is_equal_approx(material_densities[10], 1.0)
	require(material_ladder_ok,
			"the actual default Material ladder stays 1024 -> 1 texels/m")
	var height_ladder_ok := height_densities.size() == 7
	if height_ladder_ok:
		height_ladder_ok = is_equal_approx(height_densities[0], 64.0) and is_equal_approx(height_densities[6], 1.0)
	require(height_ladder_ok,
			"the actual default Height ladder is lower density and still ends at 1 texel/m")


func coarse_levels() -> int:
	return int(mat_entry().get("units", RING_LEVELS))


# The units of one layer that are current right now, from the shared per-unit schema: the old
# per-group `valid_levels` counter is gone.
func valid_units(entry: Dictionary) -> int:
	var count := 0
	for report: Dictionary in (entry.get("unit_reports", []) as Array):
		if bool(report.get("valid", false)):
			count += 1
	return count


# The detail layer's own report. The plan (section 3, "get_vt_settings()") asks the report for the
# requested density, the actually-baked sampled density, the missing tile count, the fallback count
# and the cache bytes. The canonical shape is a `detail` dictionary inside the material ring's
# entry; a top-level `clipmap_detail` dictionary and flat `clipmap_detail_*` keys are accepted as
# well, so a build can publish any of the three without this test having to change. An empty
# dictionary means the build has no detail layer at all, which is what a pre-stage-2 run reads -
# and the delivered density is then the coarse ring's own.
func detail_report() -> Dictionary:
	var s := settings()
	var nested: Dictionary = mat_entry().get("detail", {})
	if not nested.is_empty():
		return nested
	var nested_top: Dictionary = s.get("clipmap_detail", {})
	if not nested_top.is_empty():
		return nested_top
	var flat := {}
	for key in s.keys():
		if str(key).begins_with("clipmap_detail_"):
			flat[str(key).substr("clipmap_detail_".length())] = s[key]
	return flat


func detail_enabled() -> bool:
	var report := detail_report()
	return not report.is_empty() and bool(report.get("enabled", true))


func detail_missing_tiles() -> int:
	return int(detail_report().get("missing_tiles", 0))


func detail_fallback_tiles() -> int:
	return int(detail_report().get("fallback_tiles", 0))


func detail_cache_bytes() -> int:
	return int(detail_report().get("cache_bytes", 0))


# Whether a level's own stored texel range contains a point - `Terrain3DClipmap::_contains_level()`
# and the shader's `clipmap_contains()`: half-open, because the far edge is one texel past the last
# stored one and answering it would name a different world position.
func level_contains(report: Dictionary, world: Vector2) -> bool:
	var world_size := float(report.get("world_size", 0.0))
	var texel := float(report.get("texel_world", 0.0))
	var size := float(report.get("size", 0))
	if world_size <= 0.0 or texel <= 0.0 or size <= 0.0:
		return false
	var center: Vector2 = report.get("center", Vector2.ZERO)
	var local := (world - center + Vector2(world_size, world_size) * 0.5) / texel
	return local.x >= 0.0 and local.y >= 0.0 and local.x < size and local.y < size


# The density of the finest coarse ring level whose square contains the point. With
# `require_baked`, only a level the producer has written counts - which is the fragment's own gate
# for the material arm - so a run with no producer answers 0, i.e. "the ring serves nothing here".
func ring_density_from(entry: Dictionary, world: Vector2, require_baked: bool = true) -> float:
	var best := 0.0
	for report: Dictionary in (entry.get("layout", {}).get("level_reports", []) as Array):
		if require_baked and not bool(report.get("baked", false)):
			continue
		if not level_contains(report, world):
			continue
		var texel := float(report.get("texel_world", 0.0))
		if texel > 0.0:
			best = maxf(best, 1.0 / texel)
	return best


func ring_density_at(world: Vector2, require_baked: bool = true) -> float:
	return ring_density_from(mat_entry(), world, require_baked)


func detail_density_from(report: Dictionary, world: Vector2) -> float:
	if report.is_empty() or not bool(report.get("enabled", true)):
		return 0.0
	var best := 0.0
	for tile: Dictionary in (report.get("tiles", []) as Array):
		var rect: Rect2 = tile.get("world_rect", Rect2())
		if rect.has_point(world) and bool(tile.get("baked", true)):
			best = maxf(best, float(tile.get("density", 0.0)))
	if best > 0.0:
		return best
	return float(report.get("delivered_density", 0.0))


func detail_density_at(world: Vector2) -> float:
	return detail_density_from(detail_report(), world)


# The finest source that can actually answer the point: a resident detail tile, or the coarse ring.
# The array is not one of them at this density - `surface_density` is 1..8 texels per *metre* - but
# it is reported beside them so a reader can see why a fallback cannot meet the number.
func delivered_density_from(entry: Dictionary, report: Dictionary, world: Vector2) -> float:
	return maxf(ring_density_from(entry, world, true), detail_density_from(report, world))


func array_density() -> float:
	return float(terrain.surface_density) / maxf(terrain.vertex_spacing, 0.000001)


# The plan's probe point: the ground `PROBE_FORWARD_M` metres in front of the camera, along the
# view's own horizontal heading.
func probe_world() -> Vector2:
	var forward := -camera.global_transform.basis.z
	var flat := Vector2(forward.x, forward.z)
	if flat.length() < 0.0001:
		flat = Vector2(0.0, -1.0)
	flat = flat.normalized()
	return Vector2(camera.position.x, camera.position.z) + flat * PROBE_FORWARD_M


# Every ground point within `NEAR_RADIUS` of the camera that the view actually samples. This is
# the "visible high-demand region" of the plan: on screen, in front of the camera, on the ground.
func visible_near_points() -> Array[Vector2]:
	var center := Vector2(camera.position.x, camera.position.z)
	var view := Vector2(root.size)
	var points: Array[Vector2] = []
	for dz in range(-int(NEAR_RADIUS), int(NEAR_RADIUS) + 1):
		for dx in range(-int(NEAR_RADIUS), int(NEAR_RADIUS) + 1):
			var point := center + Vector2(float(dx), float(dz))
			if point.distance_to(center) > NEAR_RADIUS:
				continue
			var world := Vector3(point.x, 0.0, point.y)
			if camera.is_position_behind(world):
				continue
			var screen := camera.unproject_position(world)
			if screen.x < 0.0 or screen.y < 0.0 or screen.x >= view.x or screen.y >= view.y:
				continue
			points.append(point)
	return points


# The fraction of the visible near ground whose delivered density reaches the acceptance floor.
# 0.90 is the chosen line: a single fine patch beside the camera is not the visible region, and the
# plan's stage 2 criterion is "the near field high-demand region", not one point.
func near_hit_rate() -> float:
	var points := visible_near_points()
	if points.is_empty():
		return 0.0
	var entry := mat_entry()
	var report := detail_report()
	var hits := 0
	for point in points:
		if delivered_density_from(entry, report, point) >= DENSITY_FLOOR:
			hits += 1
	return float(hits) / float(points.size())


func baked_level_count(entry: Dictionary) -> int:
	var count := 0
	for report: Dictionary in (entry.get("layout", {}).get("level_reports", []) as Array):
		if bool(report.get("baked", false)):
			count += 1
	return count


func diag(label: String) -> void:
	var entry := mat_entry()
	var report := detail_report()
	var probe := probe_world()
	print("CLIPMAP_DENSITY %s requested=%.1f delivered=%.1f coarse=%.1f detail=%.1f array=%.1f hit=%.3f points=%d baked_levels=%d valid=%d pending_jobs=%d pending_bake=%d detail_enabled=%s detail_tiles=%d missing=%d fallback=%d cache_bytes=%d texture_layers=%d" % [
		label, float(report.get("requested_density", 0.0)), delivered_density_from(entry, report, probe),
		ring_density_from(entry, probe, true), detail_density_from(report, probe), array_density(),
		near_hit_rate(), visible_near_points().size(),
		baked_level_count(entry), valid_units(entry), int(entry.get("pending_jobs", -1)),
		int(entry.get("pending_bake_rects", -1)), str(detail_enabled()),
		int(report.get("resident_tiles", 0)), detail_missing_tiles(), detail_fallback_tiles(),
		detail_cache_bytes(), int(entry.get("texture_layers", -1))])
	uniform_diag(label)


func shader_code() -> String:
	return RenderingServer.shader_get_code(terrain.material.get_shader_rid())


# The uniforms the material arm's gate is made of, read back from the material: which band each
# group's cell claimed, how many levels the shader sees, and the per-level outstanding rect counts
# (a non-zero count is what turns a fragment away from the baked layers). Read here because "the
# probe read the array" has three possible causes and this separates them.
func uniform_diag(label: String) -> void:
	if not mat_rid.is_valid():
		return
	var bands: Variant = RenderingServer.material_get_param(mat_rid, "_clipmap_band")
	var levels: Variant = RenderingServer.material_get_param(mat_rid, "_clipmap_level_count")
	var counts: Variant = RenderingServer.material_get_param(mat_rid, "_clipmap_outstanding_count")
	var centers: Variant = RenderingServer.material_get_param(mat_rid, "_clipmap_center")
	var baked: Variant = RenderingServer.material_get_param(mat_rid, "_clipmap_baked_albedo")
	var center0 := "?"
	if centers is PackedVector2Array:
		var values: PackedVector2Array = centers
		if values.size() > 0:
			center0 = str(values[0])
	var baked_kind := "null"
	if baked is Array:
		baked_kind = "array"
	elif baked is RID:
		baked_kind = "rid"
	print("CLIPMAP_DENSITY uniform %s band=%s levels=%s outstanding=%s center0=%s baked_binding=%s arm=%s delivery=%s" % [
		label, str(bands), str(levels), str(counts), center0, baked_kind,
		str(shader_code().contains("clipmap_baked_material")), str(settings().get("delivery_names", "?"))])


func mean_color(image: Image, world: Vector2, radius: int = PATCH_RADIUS) -> Color:
	var center := screen_of(world)
	var total := Color(0.0, 0.0, 0.0, 0.0)
	var count := 0
	for y in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			total += image.get_pixel(clampi(x, 0, image.get_width() - 1), clampi(y, 0, image.get_height() - 1))
			count += 1
	return total / float(maxi(count, 1))


# The mean absolute channel difference between two renders over one screen patch: the operation
# judge. The localised form of the recorded `channel_delta` reading, so a change anywhere else in
# the frame (the far field, a shadow) cannot stand in for the patch the claim is about.
func patch_delta(a: Image, b: Image, world: Vector2, radius: int = PATCH_RADIUS) -> float:
	var center := screen_of(world)
	var total := 0.0
	var samples := 0.0
	for y in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			var pa := a.get_pixel(clampi(x, 0, a.get_width() - 1), clampi(y, 0, a.get_height() - 1))
			var pb := b.get_pixel(clampi(x, 0, b.get_width() - 1), clampi(y, 0, b.get_height() - 1))
			for channel in 4:
				total += absf(float(pa[channel]) - float(pb[channel]))
				samples += 1.0
	return total / maxf(samples, 1.0)


# ---- the source probe ---------------------------------------------------------------------------

func solid_texture(color: Color) -> ImageTexture:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func layered_texture(colors: Array, size: int = 4) -> Texture2DArray:
	var images: Array[Image] = []
	for color: Color in colors:
		# RGBA8, not RGBAF: the float format's layered upload was measured to sample as black on
		# this D3D12 device (the arm then read a zero parameter alpha and refused), and the probe
		# only needs a colour, which eight bits a channel carries.
		var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
		image.fill(color)
		images.append(image)
	var texture := Texture2DArray.new()
	texture.create_from_images(images)
	return texture


# Bind the palette that turns a fragment's *source* into a colour on screen.
#
# Two of the three sources are painted: the payload fallback is blue through every door it can come
# from (the region texture array `_texture_array_albedo`, the AVT page array
# `_surface_material_albedo`, the far field's `_surface_svt_material_albedo`), and - when the build
# exposes one - the detail layer's own sampler `_clipmap_detail_albedo` is green, the contract this
# test imposes on a build that gives the detail layer separate samplers.
#
# The coarse ring's baked layers are deliberately *not* painted. `_clipmap_baked_albedo` is bound by
# the addon as the ring's own two-group array on every uniform republication, and an override of it
# was measured to sample as black and force the arm's fallback (`surface_decode_page()` reads the
# parameter layer's alpha as its readiness bit, and the overridden set is not the ring's) - a probe
# that measures itself. So the coarse/detail split is read from *which level and density* the report
# says can answer the point, and the screen only has to separate "the ring's baked layers answered"
# (the real material, neither poison colour) from "the payload evaluation answered" (blue). A
# `_clipmap_detail_albedo` build is painted green so the screen separates all three by colour too.
func bind_source_probe() -> bool:
	mat_rid = terrain.material.get_material_rid()
	if not mat_rid.is_valid():
		return false
	probe_array_albedo = layered_texture([ARRAY_COLOR, ARRAY_COLOR])
	# Two layers: one for the coarse level's sampler if a build routes detail through the same name,
	# and one for a detail sampler that carries more than a single tile.
	probe_detail_albedo = layered_texture([DETAIL_COLOR, DETAIL_COLOR])
	if not probe_array_albedo.get_rid().is_valid() or not probe_detail_albedo.get_rid().is_valid():
		probe_array_albedo = null
		probe_detail_albedo = null
		return false
	saved_region_albedo = RenderingServer.material_get_param(mat_rid, "_texture_array_albedo")
	saved_page_albedo = RenderingServer.material_get_param(mat_rid, "_surface_material_albedo")
	saved_svt_albedo = RenderingServer.material_get_param(mat_rid, "_surface_svt_material_albedo")
	saved_detail_albedo = RenderingServer.material_get_param(mat_rid, "_clipmap_detail_albedo")
	detail_sampler_present = saved_detail_albedo != null
	apply_probe_params()
	print("CLIPMAP_DENSITY probe array_layers=%d detail_sampler=%s coarse_levels=%d" % [
		probe_array_albedo.get_layers(), str(detail_sampler_present), coarse_levels()])
	return true


# The probe's parameters, re-applied before every reading: a material-cell write and the far field's
# page-arrival fade both make the addon republish the material's textures, so a palette installed
# once would be overwritten by the very toggles the calibration is made of. The readings themselves
# are taken with the terrain's tick frozen (see `source_calibration_phase`), which is what keeps
# this palette in place through the frame that is read.
func apply_probe_params() -> void:
	if not mat_rid.is_valid() or probe_array_albedo == null:
		return
	RenderingServer.material_set_param(mat_rid, "_texture_array_albedo", probe_array_albedo.get_rid())
	RenderingServer.material_set_param(mat_rid, "_surface_material_albedo", probe_array_albedo.get_rid())
	if saved_svt_albedo != null:
		RenderingServer.material_set_param(mat_rid, "_surface_svt_material_albedo", probe_array_albedo.get_rid())
	if detail_sampler_present:
		RenderingServer.material_set_param(mat_rid, "_clipmap_detail_albedo", probe_detail_albedo.get_rid())


func restore_source_probe() -> void:
	if mat_rid.is_valid() and saved_region_albedo != null:
		RenderingServer.material_set_param(mat_rid, "_texture_array_albedo", saved_region_albedo)
	if mat_rid.is_valid() and saved_page_albedo != null:
		RenderingServer.material_set_param(mat_rid, "_surface_material_albedo", saved_page_albedo)
	if mat_rid.is_valid() and saved_svt_albedo != null:
		RenderingServer.material_set_param(mat_rid, "_surface_svt_material_albedo", saved_svt_albedo)
	if mat_rid.is_valid() and saved_detail_albedo != null:
		RenderingServer.material_set_param(mat_rid, "_clipmap_detail_albedo", saved_detail_albedo)
	saved_region_albedo = null
	saved_page_albedo = null
	saved_svt_albedo = null
	saved_detail_albedo = null
	probe_array_albedo = null
	probe_detail_albedo = null


# Which of the three sources answered the probe patch. Blue is the payload evaluation (region array
# or page) - the only source the palette paints. Anything else is the ring's own baked layers; which
# of the ring's two granularities it is, green says outright on a build with a detail sampler, and
# otherwise the report's delivered density at the point decides: a detail tile is the source exactly
# when a source at or past the acceptance density covers the point.
func probe_source(image: Image) -> String:
	var probe := probe_world()
	var color := mean_color(image, probe)
	if color.b > maxf(color.r, color.g) * 1.25:
		return "array"
	if color.g > maxf(color.r, color.b) * 1.25:
		return "detail"
	if detail_density_at(probe) >= DENSITY_FLOOR:
		return "detail"
	return "coarse"


# ---- driving ------------------------------------------------------------------------------------

func settle(frames: int) -> void:
	for _i in frames:
		await process_frame


func frame_image(wait_frames: int = 6) -> Image:
	for _i in wait_frames:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func ready_pages() -> int:
	var count := 0
	for page: Dictionary in terrain.get_vt_pages():
		if bool(page.get("ready", false)):
			count += 1
	return count


# The far field's own settling: the shared producer only exists once a paged tier is up, and the
# ring's bake is that producer's pass, so this has to precede any baked reading.
func settle_pages(frames: int = 600) -> void:
	for frame in frames:
		await process_frame
		var producer: Dictionary = settings().get("producer", {})
		if frame > 20 and int(producer.get("pending", 1)) == 0 and ready_pages() > 0:
			break
	await RenderingServer.frame_post_draw


# The coarse ring's fill through the mechanism's own entry - the same `Terrain3DClipmap::update()`,
# focus and budget the tick's clipmap phase runs - so a settled ring is the same ring the product
# would have built. The tick's own phase is left on as well; this entry only drains it.
func settle_ring(max_calls: int = 4096) -> void:
	for _i in max_calls:
		var entry := mat_entry()
		if int(entry.get("pending_jobs", 1)) == 0 and valid_units(entry) >= int(entry.get("units", 1)):
			break
		terrain.call("debug_update_vt_clipmap", MATERIAL)
	await process_frame


# The ring settled *and* the producer's bake landed: every current level reports `baked`, nothing
# is left queued, and the frames in between are what let a dispatch reach the layers.
func settle_ring_and_bake(label: String, frames: int = 300) -> void:
	for _frame in frames:
		settle_ring(256)
		await process_frame
		var entry := mat_entry()
		var un_baked := false
		for report: Dictionary in (entry.get("layout", {}).get("level_reports", []) as Array):
			if bool(report.get("valid", false)) and not bool(report.get("baked", false)):
				un_baked = true
		if int(entry.get("pending_jobs", 1)) == 0 and int(entry.get("pending_bake_rects", -1)) == 0 and not un_baked:
			break
	print("CLIPMAP_DENSITY settle %s" % label)
	await process_frame


# ---- fixture ------------------------------------------------------------------------------------

func add_probe_assets() -> void:
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = solid_texture(ASSET_RED if id == 0 else ASSET_GREEN)
		asset.normal_texture = solid_texture(Color(0.5, 0.5, 1.0))
		terrain.assets.set_texture_asset(id, asset)


# The plan's stage 2 settings, applied when the build has them. They are looked up in the property
# list first, so a pre-stage-2 binary is not asked for a property it has not got - and the list of
# names this test will take is printed, which is how a reader knows whether the run even asked.
func apply_detail_settings() -> void:
	var wanted := {
		"vt_clipmap_detail_enabled": true,
		"vt_clipmap_material_detail_enabled": true,
		"vt_clipmap_detail_density": TARGET_DENSITY,
		"vt_clipmap_material_detail_density": TARGET_DENSITY,
		"vt_clipmap_detail_budget_bytes": 256 * 1024 * 1024,
		"vt_clipmap_material_detail_budget_bytes": 256 * 1024 * 1024,
	}
	var present := {}
	for property in terrain.get_property_list():
		present[str(property.get("name", ""))] = true
	for raw_name in wanted:
		var name := str(raw_name)
		if present.has(name):
			terrain.set(name, wanted[name])
			applied_detail_settings.append(name)
	print("CLIPMAP_DENSITY detail_settings applied=%s" % str(applied_detail_settings))


func configure_ring() -> void:
	terrain.vt_clipmap_size = RING_SIZE
	terrain.vt_clipmap_levels = RING_LEVELS
	terrain.vt_clipmap_base_world = RING_BASE_WORLD
	terrain.vt_clipmap_budget_texels = RING_SIZE * RING_SIZE


# The material painting every material reading stands on: alternating ids in eight-metre blocks, so
# a source coarser than the payload has something to get wrong and a boundary patch exists to probe.
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


func setup() -> void:
	scene = Node3D.new()
	root.add_child(scene)

	camera = Camera3D.new()
	camera.fov = 70.0
	camera.near = 0.05
	camera.far = 1024.0
	# The project's gameplay pose: a 1.7 m eye pitched 8 degrees down. The runner's `--resolution`
	# is what makes the footprint 1080p; nothing here pins the window size.
	camera.position = Vector3(32.0, 1.7, 32.0)
	camera.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	camera.current = true
	root.add_child(camera)

	light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)

	terrain = Terrain3D.new()
	terrain.region_size = 64
	terrain.free_editor_textures = false
	terrain.surface_svt_auto_bake = false
	terrain.vt_page_fade_frames = 0
	# The configuration under test: the material group delivered by the ring, the height group
	# direct, and the far field direct to begin with (the "ring stands alone" case). SVT is
	# selected later for the far-field configuration.
	terrain.vt_delivery_near_material = CLIPMAP
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	add_probe_assets()
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	scene.add_child(terrain)
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)
	apply_detail_settings()

	# Blank 64 m regions around the camera, and a material payload with an eight-metre pattern so a
	# coarse source point-samples a different value across a boundary.
	for z in range(-1, 2):
		for x in range(-1, 2):
			terrain.data.add_region_blank(Vector2i(x, z), false)
	terrain.data.update_maps()
	probe_actual_group_ladders()
	configure_ring()
	for bz in 8:
		for bx in 8:
			paint_material(Vector3(float(bx) * 8.0 + 4.0, 0.0, float(bz) * 8.0 + 4.0), (bx + bz) % 2)
	terrain.data.update_maps()

	var painted_a := terrain.data.get_texture_id(Vector3(4.0, 0.0, 4.0))
	var painted_b := terrain.data.get_texture_id(Vector3(12.0, 0.0, 4.0))
	print("CLIPMAP_DENSITY fixture painted_a=%s painted_b=%s" % [str(painted_a), str(painted_b)])
	require(painted_a.x != painted_b.x,
			"fixture painted alternating material ids, so a coarse source has something to get wrong")
	await settle(6)


# ---- the claims ---------------------------------------------------------------------------------

# Claims 1 and 2 at one pose: the delivered density at the plan's probe point and the hit rate over
# the visible near ground. The failure text names "密度未达标" so a reader of a failing log knows
# which acceptance the run is about.
func density_phase(label: String) -> void:
	diag(label)
	var probe := probe_world()
	var entry := mat_entry()
	var report := detail_report()
	var delivered := delivered_density_from(entry, report, probe)
	require(delivered >= DENSITY_FLOOR,
			"密度未达标：%s 目标点 %s 的实际采样密度 %.1f texels/m < %.0f（粗环 %.1f，细层 %.1f，区域数组 %.1f）" % [
				label, str(probe), delivered, DENSITY_FLOOR,
				ring_density_from(entry, probe, true), detail_density_from(report, probe), array_density()])
	var hit := near_hit_rate()
	require(hit >= HIT_RATE_FLOOR,
			"密度未达标：%s 可见近场 8 m 内达到 %.0f texels/m 的命中率 %.3f < %.2f（%d 个采样点）" % [
				label, DENSITY_FLOOR, hit, HIT_RATE_FLOOR, visible_near_points().size()])
	if delivered >= DENSITY_FLOOR and hit >= HIT_RATE_FLOOR:
		print("PASS clipmap density: %s delivers %.1f texels/m at the probe point with hit rate %.3f" % [
			label, delivered, hit])


# A frame captured with the palette applied *after* the frame's own physics step has run and before
# its draw. The terrain's tick is frozen for these readings (see `source_calibration_phase`), but the
# two-step apply is kept anyway: a material write is picked up by the next draw, and one frame of
# slack costs nothing against a reading that must not be a frame early.
func probe_image() -> Image:
	await process_frame
	apply_probe_params()
	await RenderingServer.frame_post_draw
	await process_frame
	apply_probe_params()
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


# Claim 3: one render with the probe bound, read back from the screen. The reading is the colour,
# which is the shader's own source selection; the density side of the same claim is the report.
func source_phase(label: String) -> String:
	var probe := probe_world()
	var image := await probe_image()
	var source := probe_source(image)
	print("CLIPMAP_DENSITY source %s=%s color=%s" % [label, source, str(mean_color(image, probe))])
	uniform_diag(label)
	# If the ring read the array, separate the two causes a probe can: the readiness gate saying a
	# texel is outstanding, or the baked arm being answered by something else. Zeroing the counts is
	# a reading, not a fix - it is restored right after - and it is what tells an implementer which
	# half to look at when this fails.
	if source == "array" and mat_rid.is_valid():
		var entry := mat_entry()
		if int(entry.get("pending_bake_rects", -1)) == 0 and baked_level_count(entry) > 0:
			var saved: Variant = RenderingServer.material_get_param(mat_rid, "_clipmap_outstanding_count")
			var zero := PackedInt32Array()
			zero.resize(32)
			RenderingServer.material_set_param(mat_rid, "_clipmap_outstanding_count", zero)
			var forced := await probe_image()
			print("CLIPMAP_DENSITY source %s_gate_opened=%s" % [label, probe_source(forced)])
			if saved != null:
				RenderingServer.material_set_param(mat_rid, "_clipmap_outstanding_count", saved)
	if source == "coarse":
		require(ring_density_at(probe, true) < DENSITY_FLOOR,
				"探针读到粗环，但粗环密度 %.1f 已达到验收线，这是读数而不是目标配置" % ring_density_at(probe, true))
	if source == "detail":
		require(detail_density_at(probe) >= DENSITY_FLOOR,
				"探针读到细层，但细层报告的密度 %.1f 未达到验收线" % detail_density_at(probe))
	return source


# The three-source reading: the fallback must be observable (deselect the ring), the ring's baked
# layers must be observable, and the detail layer must be observable. The first two are the probe's
# own calibration - a probe that cannot show the fallback or the ring proves nothing about a detail
# reading.
#
# The readings are taken with the terrain's own tick frozen. The addon republishes the material's
# textures whenever the far field's page-arrival fade or a page arrival touches the material
# (`Terrain3DMaterial::update()` -> `_update_vt_uniforms()`), and that write lands on top of the
# probe's palette: measured without the freeze, the palette was overwritten every frame. Nothing
# read here needs the tick - the ring is settled and the probe is a reading, not a production - and
# the palette is applied after the frame's physics step and before its draw inside `probe_image()`.
func source_calibration_phase(far_svt: bool) -> void:
	# The cell writes and the settle happen with the tick on, so the ring is built and baked by the
	# product path exactly as it would be in a session.
	terrain.vt_delivery_near_material = CLIPMAP
	await settle(6)
	if far_svt:
		await settle_ring_and_bake("source_calibration")
	else:
		await settle_ring()
	terrain.set_process(false)
	terrain.set_physics_process(false)
	# Array: the cell deselected, so the payload evaluation is the only source.
	terrain.vt_delivery_near_material = DIRECT
	await settle(6)
	var array_source := await source_phase("array")
	require(array_source == "array",
			"着色器探针的数组读数失败：未选中环时目标点应为区域数组/页回退，读到 %s" % array_source)
	terrain.vt_delivery_near_material = CLIPMAP
	await settle(6)
	var ring_source := await source_phase("ring")
	if far_svt:
		require(ring_source == "coarse",
				"着色器探针的粗环读数失败：远场 SVT 提供烘焙器时目标点应读到粗环烘焙层，读到 %s" % ring_source)
	var detail_source := await source_phase("detail")
	require(detail_source == "detail",
			"着色器探针的细层读数失败：目标点应读到细层烘焙层，读到 %s（细层报告 %s）" % [
				detail_source, str(detail_report())])
	terrain.set_process(true)
	terrain.set_physics_process(true)


# Claim 4: the operations the plan names, each judged against the array path or against the render
# before it. Runs with the probe unbound: these compare the real material.
func correctness_phase() -> void:
	var probe := probe_world()

	# The array path's own render, which is what "the picture is correct" means for a material.
	terrain.vt_delivery_near_material = DIRECT
	await settle(6)
	var array_image := await frame_image()
	terrain.vt_delivery_near_material = CLIPMAP
	await settle(6)
	await settle_ring_and_bake("correctness")
	var ring_image := await frame_image()
	var ring_delta := patch_delta(array_image, ring_image, probe)
	print("CLIPMAP_DENSITY correctness array_vs_ring=%.6f" % ring_delta)
	require(ring_delta <= PATCH_DELTA,
			"环与区域数组在目标点的画面不一致：平均通道差 %.6f > %.3f" % [ring_delta, PATCH_DELTA])

	# Cross tile boundary: a patch straddling a material block edge. The same comparison, at points
	# the eight-metre pattern puts on a boundary, is the "no crack or stale texel at an edge" half.
	var boundary_worst := 0.0
	for offset in [-0.4, 0.0, 0.4]:
		var boundary := Vector2(probe.x + offset, probe.y - 4.0)
		boundary_worst = maxf(boundary_worst, patch_delta(array_image, ring_image, boundary))
	print("CLIPMAP_DENSITY correctness boundary_worst=%.6f" % boundary_worst)
	require(boundary_worst <= PATCH_DELTA,
			"跨 tile/材质边界画面不一致：平均通道差 %.6f > %.3f" % [boundary_worst, PATCH_DELTA])

	# A draw edit: the picture must follow the stroke once the ring has drained. The id is read
	# first and the other one painted, so the stroke is guaranteed to change the stored payload.
	var before_edit := await frame_image()
	var stored_id := int(terrain.data.get_texture_id(Vector3(probe.x, 0.0, probe.y)).x)
	paint_material(Vector3(probe.x, 0.0, probe.y), 0 if stored_id != 0 else 1)
	terrain.data.update_maps()
	await settle(4)
	await settle_ring_and_bake("edit")
	var after_edit := await frame_image()
	var edit_delta := patch_delta(before_edit, after_edit, probe)
	print("CLIPMAP_DENSITY correctness edit_delta=%.6f" % edit_delta)
	require(edit_delta > PATCH_DELTA,
			"绘制编辑未传到目标点：平均通道差 %.6f，画面没有跟随笔刷" % edit_delta)

	# A material replacement: the albedo the probe patch carries is changed and the ring's own render
	# has to follow it. A baked layer that was not invalidated keeps the old colour and fails here -
	# which is the plan's stage 3 rule that a material asset replacement invalidates the bake.
	#
	# The texture is updated in place rather than the asset swapped. A `set_texture_asset()` swap
	# with the far field up was measured to leave the renderer without a material uniform set for
	# several frames (`ERROR: Parameter "uniform_set" is null.`), and the harness fails any run whose
	# log carries an engine error - so the swap would make this test unpassable for a reason that is
	# not the claim. Updating the image keeps the same texture RID and the same asset identity, and
	# the render still has to follow it.
	var probe_asset := int(terrain.data.get_texture_id(Vector3(probe.x, 0.0, probe.y)).x)
	var asset: Terrain3DTextureAsset = terrain.assets.get_texture_asset(probe_asset)
	var replaced_texture: ImageTexture = null
	if asset != null:
		replaced_texture = asset.albedo_texture as ImageTexture
	if replaced_texture != null:
		var replaced_image := replaced_texture.get_image()
		replaced_image.fill(REPLACED_COLOR)
		replaced_texture.update(replaced_image)
	else:
		asset = asset if asset != null else Terrain3DTextureAsset.new()
		asset.albedo_texture = solid_texture(REPLACED_COLOR)
		terrain.assets.set_texture_asset(probe_asset, asset)
	await settle(8)
	await settle_ring_and_bake("replace")
	var replaced := await frame_image()
	var replaced_color := mean_color(replaced, probe)
	# The new colour is magenta: red and blue both well above green.
	var replaced_ok := replaced_color.r > replaced_color.g * 1.25 and replaced_color.b > replaced_color.g * 1.25
	print("CLIPMAP_DENSITY correctness replace_asset=%d in_place=%s color=%s" % [
		probe_asset, str(replaced_texture != null), str(replaced_color)])
	require(replaced_ok, "材质替换未传到环的画面：目标点颜色 %s 不是替换后的洋红" % str(replaced_color))

	# `surface_array_enabled = false`: the ring (and the far field) must carry the material alone.
	# The probe patch is inside the ring's band, so the reading is that it neither goes missing nor
	# changes; the far field's own picture covers outside it.
	var before_disable := await frame_image()
	terrain.surface_array_enabled = false
	await settle(8)
	await settle_ring_and_bake("array_off")
	var array_off := await frame_image()
	var array_off_delta := patch_delta(before_disable, array_off, probe)
	print("CLIPMAP_DENSITY correctness array_off_delta=%.6f" % array_off_delta)
	require(array_off_delta <= PATCH_DELTA,
			"surface_array_enabled=false 后目标点画面改变：平均通道差 %.6f > %.3f（未烘焙片元回退到已停更的数组）" % [
				array_off_delta, PATCH_DELTA])
	terrain.surface_array_enabled = true
	await settle(4)


# The teardown convention every VT fixture follows: enabling delivery turns the terrain's own tick
# on, so it has to be stopped before the camera it reads is freed, or the tick logs a missing
# camera as an engine error after every assertion has passed.
func teardown() -> void:
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


# ---- the run ------------------------------------------------------------------------------------

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute("user://vt_clipmap_density")
	await setup()
	# The probe bindings are installed once and left in place through the source readings: every
	# source reading below is taken with them, so the picture always says which source served the
	# patch. They are unbound before the correctness phase, which compares real materials.
	if not bind_source_probe():
		require(false, "无法创建/绑定着色器探针纹理：材质 RID 无效或数组创建失败")

	# ---- configuration A: the material ring alone, the far field direct ----
	terrain.vt_delivery_far_material = DIRECT
	terrain.surface_svt_enabled = false
	await settle(8)
	await settle_ring()
	diag("config_a_cold")
	await source_calibration_phase(false)
	density_phase("config_a_cold")
	var first_probe := probe_world()

	# The view moves, and the fine field has to follow it: the same density reading at the new pose.
	camera.position = Vector3(camera.position.x + 3.0, camera.position.y, camera.position.z - 4.0)
	await settle(20)
	await settle_ring()
	await settle(4)
	density_phase("config_a_moved")
	print("CLIPMAP_DENSITY moved probe %s -> %s" % [str(first_probe), str(probe_world())])

	# ---- configuration B: the far field SVT, so the shared producer bakes the ring ----
	terrain.surface_svt_enabled = true
	terrain.surface_svt_page_world = 32.0
	terrain.surface_svt_distance = 512.0
	terrain.vt_page_size = 32
	terrain.vt_page_border = 2
	terrain.vt_page_count = 64
	terrain.vt_pages_per_update = 8
	await settle_pages()
	require(ready_pages() > 0, "远场未产生页面，共享烘焙器不存在，环不可能被烘焙")
	terrain.vt_delivery_near_material = CLIPMAP
	await settle(8)
	await settle_ring_and_bake("config_b")
	await source_calibration_phase(true)
	density_phase("config_b_cold")
	diag("config_b_final")

	# The operations compare the real material, so the palette comes off first.
	restore_source_probe()
	await settle(4)
	await correctness_phase()

	await teardown()
	if failed:
		print("REGRESSION: clipmap material density acceptance")
		quit(1)
		return
	print("PASS clipmap material density acceptance")
	quit(0)
