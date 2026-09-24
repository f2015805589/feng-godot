# Run with a graphical rendering driver; see README.md in this directory.
#
# The delivery matrix and the assembly that follows from it.
#
# The requirement this test exists for is the assembly rule, not any one method: a method no cell
# selects must own **no object, no array family, no uniform and no shader arm**. That is a claim
# about what exists, so the readings are the live service pointers, the material's own verdict on
# the shader it generated, and the four cells - never a frame time, which would not distinguish
# "cheap" from "absent".
#
# Read `docs/vt_delivery_assembly.md` for the channel inventory and the rule; the cells here are
# (tier, group) with tier Near=0/Far=1 and group Material=0/Height=1, and the methods are
# Direct=0/AVT=1/Clipmap=2/SVT=3, i.e. the native `TerrainVT` enum values, which are also the
# property values.
#
# Two things the test pins that are deliberate policy rather than incidental:
#
#   * **Creation is selection-driven; freeing is at teardown.** The first block builds a terrain
#     whose cells are all `Direct` *before* it enters the tree: that terrain owns nothing at all,
#     which is the requirement. The second block turns every cell direct on a live terrain and
#     asserts the services *stop* rather than that they are freed - the objects are also a residency
#     cache and the pool and producer are shared between views, so a toggle is not a residency
#     reset. The reason is written out in `Terrain3D::_resolve_vt_delivery()`.
#   * **Which channel `Clipmap` can carry, and what a cell may name at all.** The matrix is
#     asymmetric: the diffuse+normal group's methods are AVT and SVT (Clipmap needs a source it has
#     not got, M4), while the height group has exactly two choices - `Direct` and the clipmap ring -
#     because AVT and SVT page the material group rather than the height one. Both of the height
#     group's choices are deliverable, so the refusals this suite pins are the material channel's
#     `Clipmap` and the height channel's `AVT`/`SVT`; a cell naming one of them stays where it was, and
#     the report's published capability is asserted here rather than inferred from a service that is
#     missing.
#   * **The ring is measurable without a delivery claim.** `debug_update_vt_clipmap()` is the
#     mechanism's own entry, and block 3b measures it with every cell `Direct`: it builds the height
#     ring, runs the phase the tick would run, and reports the texels - which is why the ring's own
#     readings (`vt_clipmap`) never need a cell to be selected.
#   * **The debug views follow what exists.** The inspector's AVT layout is gated on a matrix cell
#     and the VT Page's clipmap view on a ring, and each native preview refuses before it scans.
#     Block 6 measures that with the two counter pairs in `get_vt_settings()`, because "the debug
#     view costs nothing when it has nothing to draw" is otherwise a claim about a picture nobody can
#     see the cost of.
extends SceneTree

const NEAR := 0
const FAR := 1
const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const AVT := 1
const CLIPMAP := 2
const SVT := 3
const CLIPMAP_ATLAS := 4

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false


func _initialize() -> void:
	call_deferred("run")


func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true


func cell(p_tier: int, p_group: int) -> int:
	return int(terrain.get_vt_delivery(p_tier, p_group))


func settings() -> Dictionary:
	return terrain.get_vt_settings()


func shader_uses_vt() -> bool:
	return bool(terrain.material.is_shader_using_vt())


func describe() -> String:
	var s := settings()
	return "cells near/material=%d near/height=%d far/material=%d far/height=%d | services avt=%s svt=%s clipmap=%s | objects avt=%s svt=%s ring=%s | shader_arms=%s | array_needed=%s" % [
		cell(NEAR, MATERIAL), cell(NEAR, HEIGHT), cell(FAR, MATERIAL), cell(FAR, HEIGHT),
		str(s.get("avt_service", "?")), str(s.get("svt_service", "?")), str(s.get("clipmap_service", "?")),
		str(terrain.get_surface_vt() != null), str(terrain.get_surface_svt() != null), str(s.get("clipmap_ring", "?")),
		str(s.get("vt_shader_arms", "?")), str(s.get("surface_array_upload_needed", "?"))]


func settle(frames: int = 6) -> void:
	for _i in frames:
		await process_frame


# The requirement's own scenario: a terrain that never selects a method must never build it.
func run_never_selected_block() -> void:
	var plain := Terrain3D.new()
	plain.surface_svt_auto_bake = false
	# Written before the node is in the tree, so the first resolution of the matrix - which is what
	# `_initialize()` does - sees the all-direct configuration and assembles nothing.
	plain.vt_delivery_near_material = DIRECT
	plain.vt_delivery_near_height = DIRECT
	plain.vt_delivery_far_material = DIRECT
	plain.vt_delivery_far_height = DIRECT
	# A target, because the node warns when it has neither a clipmap target nor a camera - and this
	# terrain deliberately has no VT to demand for.
	plain.set_camera(camera)
	plain.set_clipmap_target(camera)
	var holder := Node3D.new()
	holder.add_child(plain)
	root.add_child(holder)
	plain.data.add_region_blank(Vector2i.ZERO)
	await settle(8)
	var s := plain.get_vt_settings()
	require(plain.get_surface_vt() == null, "a terrain that never selected AVT owns no near view object")
	require(plain.get_surface_svt() == null, "a terrain that never selected SVT owns no far view object")
	require(not bool(s.get("avt_service", true)), "a terrain that never selected AVT reports no AVT service")
	require(not bool(s.get("svt_service", true)), "a terrain that never selected SVT reports no SVT service")
	require(not bool(s.get("clipmap_service", true)), "a terrain that never selected clipmap reports no clipmap service")
	require(not bool(s.get("clipmap_ring", true)), "and owns no ring at all")
	require(plain.is_vt_delivery_supported(HEIGHT, CLIPMAP),
			"and Clipmap is deliverable for the height group, because the shader arm samples the ring")
	require(not plain.is_vt_delivery_used(CLIPMAP), "while a cell that never named it is not a use of it")
	require(plain.get_clipmap_layout_preview().is_empty(), "so its clipmap preview is refused rather than drawn empty")
	require(not bool(s.get("vt_shader_arms", true)), "a terrain that never selected a method compiles no virtual-texture arm")
	require(not bool(plain.material.is_shader_using_vt()), "and its generated shader is the no-VT build")
	require(bool(s.get("surface_array_upload_needed", false)), "the region array carries a group no service delivers")
	print("VT_DELIVERY_NEVER_SELECTED cells near/material=%d near/height=%d far/material=%d far/height=%d | objects avt=%s svt=%s | shader_arms=%s" % [
		int(plain.get_vt_delivery(NEAR, MATERIAL)), int(plain.get_vt_delivery(NEAR, HEIGHT)),
		int(plain.get_vt_delivery(FAR, MATERIAL)), int(plain.get_vt_delivery(FAR, HEIGHT)),
		str(plain.get_surface_vt() != null), str(plain.get_surface_svt() != null),
		str(s.get("vt_shader_arms", "?"))])
	holder.queue_free()
	await settle(2)


func run() -> void:
	# The camera comes first: both terrains below need a demand target to stay quiet about it.
	camera = Camera3D.new()
	camera.position = Vector3(32, 60, 64)
	camera.current = true
	root.add_child(camera)
	camera.look_at(Vector3(32, 0, 32))

	await run_never_selected_block()

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	# The matrix is this suite's subject, not the 1024 detail layer that selecting `Clipmap` on the
	# material group now brings up by default: it is switched off so a matrix read allocates no detail
	# arrays and the ring's own arm is the material this suite measures.
	terrain.vt_clipmap_detail_enabled = false
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	terrain.data.add_region_blank(Vector2i.ZERO)
	await settle(8)

	# 1. The default matrix is the shipped architecture written in the new vocabulary, so a scene
	#    that never writes a cell loads into the configuration it was authored against.
	require(cell(NEAR, MATERIAL) == AVT, "the near material cell defaults to AVT")
	require(cell(NEAR, HEIGHT) == DIRECT, "the near height cell defaults to Direct")
	require(cell(FAR, MATERIAL) == SVT, "the far material cell defaults to SVT")
	require(cell(FAR, HEIGHT) == DIRECT, "the far height cell defaults to Direct")
	var s := settings()
	require(bool(s.get("avt_service", false)), "the default matrix assembles the AVT service")
	require(bool(s.get("svt_service", false)), "the default matrix assembles the SVT service")
	require(not bool(s.get("clipmap_service", true)), "the default matrix assembles no clipmap")
	require(shader_uses_vt(), "the default matrix compiles the virtual-texture arms")
	require(terrain.get_surface_vt() != null, "the default matrix owns the near view object")
	require(terrain.get_surface_svt() != null, "the default matrix owns the far view object")
	print("VT_DELIVERY_DEFAULTS ", describe())

	# 2. Every cell direct on a live terrain: the services stop. The objects are deliberately not
	#    freed here - see the note in `Terrain3D::_resolve_vt_delivery()` - so what is asserted is
	#    what the requirement is about: no pass, no uniform gate, no shader arm, and the region
	#    array becoming the renderer rather than a fallback.
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	await settle(4)
	s = settings()
	require(not bool(s.get("avt_service", true)), "an all-direct matrix reports no AVT service")
	require(not bool(s.get("svt_service", true)), "an all-direct matrix reports no SVT service")
	require(not bool(s.get("clipmap_service", true)), "an all-direct matrix reports no clipmap service")
	require(not bool(s.get("vt_shader_arms", true)), "an all-direct matrix compiles no virtual-texture arm")
	require(not shader_uses_vt(), "the generated shader is the no-VT build")
	require(bool(s.get("surface_array_upload_needed", false)), "the region array carries a group no service delivers")
	print("VT_DELIVERY_ALL_DIRECT ", describe())

	# 3. What a cell may name. The matrix is asymmetric and this build refuses a method it cannot
	#    deliver: the write leaves the cell where it was, builds nothing, and the report publishes both
	#    the methods each group may name and the sentence for each one it may not. Reading it from the
	#    report rather than from the log is what makes "refused" a number a test can hold.
	require(terrain.is_vt_delivery_supported(MATERIAL, AVT), "the diffuse+normal group can be delivered by AVT")
	require(terrain.is_vt_delivery_supported(MATERIAL, SVT), "and by SVT")
	require(terrain.is_vt_delivery_supported(MATERIAL, CLIPMAP),
			"and by the ring, whose source carries that group's R16 control payload")
	require(terrain.has_clipmap_source(MATERIAL) and terrain.has_clipmap_source(HEIGHT),
			"which is the registry's answer for both channels rather than a table")
	require(terrain.is_vt_delivery_supported(HEIGHT, CLIPMAP),
			"the height group is delivered by Clipmap, whose arm samples the ring")
	# The block atlas is the clipmap layer's second residency unit and is deliverable for exactly the
	# groups the ring is: it carries the same source, and both its arms sample block rects of it.
	require(terrain.is_vt_delivery_supported(MATERIAL, CLIPMAP_ATLAS) and terrain.is_vt_delivery_supported(HEIGHT, CLIPMAP_ATLAS),
			"and by ClipmapAtlas, which is deliverable for either group that has a clipmap source")
	require(not terrain.is_vt_delivery_supported(HEIGHT, AVT) and not terrain.is_vt_delivery_supported(HEIGHT, SVT),
			"while AVT and SVT are not the height channel's methods at all: its choices are Direct and the clipmap layer")
	require(terrain.is_vt_delivery_supported(HEIGHT, DIRECT), "Direct is deliverable for either group, being the fallback")
	var height_reason := terrain.get_vt_delivery_unsupported_reason(HEIGHT, SVT)
	require(height_reason == "the height channel is delivered directly or by the clipmap ring; AVT and SVT page the diffuse+normal group",
			"and the reason names the design rather than a missing arm: %s" % height_reason)
	var supported: Dictionary = settings().get("delivery_supported", {})
	require(str(supported.get("material", [])) == str([DIRECT, AVT, CLIPMAP, SVT, CLIPMAP_ATLAS]) and str(supported.get("height", [])) == str([DIRECT, CLIPMAP, CLIPMAP_ATLAS]),
			"the report publishes the methods each group may name: material %s, height %s" % [
					str(supported.get("material")), str(supported.get("height"))])

	# The writes themselves, on the live terrain, in one step: the refused one is a height cell naming
	# `AVT` (that channel's choices are the array and the ring), and it leaves every cell where it was,
	# so a scene that asks for an undeliverable method loads into the configuration it can actually
	# render rather than into one that reads as working.
	terrain.vt_delivery_far_height = AVT
	await settle(4)
	require(cell(NEAR, HEIGHT) == DIRECT and cell(FAR, HEIGHT) == DIRECT,
			"a height cell naming AVT is refused and stays Direct")
	s = settings()
	require(not bool(s.get("clipmap_service", true)) and not bool(s.get("clipmap_ring", true)),
			"so no clipmap service is selected and no ring is built")
	require(not bool(s.get("avt_service", true)) and not bool(s.get("svt_service", true)),
			"and a refused cell selects no paged service either")
	require(not shader_uses_vt(), "so the arms of a matrix whose only non-direct writes were refused are not compiled")
	print("VT_DELIVERY_REFUSED ", describe())

	# The height cell that *is* deliverable, which is the one write that reaches the shader: selecting it
	# builds the ring and compiles the arm, and deselecting it takes both away. This is the reading that
	# makes "a method nobody selected costs no shader branch" a statement about the *height* arm too, and
	# not only about the material group's.
	terrain.vt_delivery_near_height = CLIPMAP
	await settle(4)
	s = settings()
	require(cell(NEAR, HEIGHT) == CLIPMAP, "the height group accepts Clipmap")
	require(bool(s.get("clipmap_service", false)), "which selects the clipmap service")
	require(bool(s.get("clipmap_ring", false)), "and builds its ring")
	require(shader_uses_vt(), "and the generated shader carries the VT arms")
	# The ring's arm per channel group, published with the group it belongs to rather than in a key of
	# its own, so a build can carry one group's arm without the other's.
	var clipmap: Dictionary = s.get("clipmap", {})
	var ring_entry: Dictionary = clipmap.get("height", {})
	require(bool(ring_entry.get("shader_arm", false)), "including the height ring's own")
	terrain.vt_delivery_near_height = DIRECT
	await settle(4)
	s = settings()
	require(cell(NEAR, HEIGHT) == DIRECT, "deselecting it takes the method back")
	clipmap = s.get("clipmap", {})
	ring_entry = clipmap.get("height", {})
	require(not bool(ring_entry.get("shader_arm", true)), "and the ring's arm leaves the generated shader")
	require(not shader_uses_vt(), "with the rest of the VT arms, no cell naming a service any more")
	require(bool(s.get("clipmap_ring", false)), "while the ring object stays, being a residency cache as well as a renderer")

	# The material cell is the second channel the ring can carry, and its source is the packed `R16`
	# surface payload the group's baked pages are produced *from*: the band the ring serves is therefore
	# the group's source resolution rather than a page. Selecting it builds that group's ring and
	# compiles that group's arm - and the two channels' arms move independently, which is what the
	# deselection above left in place.
	terrain.vt_delivery_near_material = CLIPMAP
	await settle(4)
	s = settings()
	require(cell(NEAR, MATERIAL) == CLIPMAP, "the diffuse+normal group accepts Clipmap")
	require(shader_uses_vt(), "which compiles the VT arms")
	var material_ring: Dictionary = s.get("clipmap", {}).get("material", {})
	require(bool(material_ring.get("configured", false)), "and builds that group's ring")
	require(str(material_ring.get("source", "")) == "material", "whose source names the channel it carries")
	require(bool(material_ring.get("shader_arm", false)), "and whose arm is in the generated shader")
	require(bool(s.get("clipmap_service", false)), "so the clipmap service is selected by that cell alone")
	# What the ring carries for a producer: the three arrays a bake writes out of its payload. This is
	# the *shape* reading only, because a ring this configuration builds has no producer behind it - no
	# cell here takes a page, so no bake runs and the `baked` flag has nothing to be set by. The
	# dispatch-and-mark handshake across ticks, and the material it produces, are `vt_clipmap_render`'s
	# bake block, which brings the far field up for exactly that reason.
	var baked_channels := 0
	for report in (material_ring.get("level_reports", []) as Array):
		baked_channels = int(report.get("baked_channels", 0))
	require(baked_channels == 3, "the material ring carries the three arrays a producer bakes out of it")
	# The height ring's own arm left the code above, so this is the material arm being carried rather
	# than the height one.
	clipmap = s.get("clipmap", {})
	require(not bool((clipmap.get("height", {}) as Dictionary).get("shader_arm", true)),
			"while the height ring's arm is still out of it")
	print("VT_DELIVERY_MATERIAL_CLIPMAP ", describe())
	terrain.vt_delivery_near_material = DIRECT
	await settle(4)
	require(cell(NEAR, MATERIAL) == DIRECT, "and deselecting the material cell takes the method back")

	# 3b. The mechanism's own entry, which is how the ring stays measurable with every cell `Direct`: it
	#     builds the height ring, runs the phase the tick would run for it - the same `update()`, focus
	#     and budget - and reports the texels. `configured` is true while `selected` stays false: the
	#     object exists and nothing delivers it, which is the state a reading of the mechanism wants, and
	#     which `vt_clipmap` drives every one of its counters through.
	terrain.vt_clipmap_size = 16
	terrain.vt_clipmap_levels = 1
	terrain.vt_clipmap_base_world = 16.0
	terrain.vt_clipmap_budget_texels = 4096
	var produced: int = terrain.debug_update_vt_clipmap(HEIGHT)
	require(int(settings().get("clipmap_produced_texels", -1)) == produced,
			"the entry publishes the same number the tick's phase publishes")
	# This terrain ticks normally, so the next tick's own clipmap branch runs - and it is the branch
	# that clears the counter, because no cell selects the method. Both halves are one reading: the
	# entry produced texels, and a tick that enters no clipmap phase reports none. The tick is a
	# *physics* tick - the branch is in `__physics_process()` - so the wait is for that tick rather than
	# for two process frames, which an off-screen window can serve several of without one, the same
	# fixture precondition `vt_pressure` records.
	await physics_frame
	await physics_frame
	s = settings()
	require(int(s.get("clipmap_produced_texels", -1)) == 0,
			"and the tick that follows reports zero, entering no clipmap phase: no cell selects the method")
	var ring: Dictionary = s.get("clipmap", {}).get("height", {})
	require(produced == 256, "the entry fills the 16-texel level whole: %d texels" % produced)
	require(bool(ring.get("configured", false)), "so the ring it built is reported")
	require(not bool(ring.get("selected", false)), "while no cell claims the method")
	require(str(ring.get("source", "")) == "height", "and it names the channel it carries")
	require(bool(s.get("clipmap_ring", false)), "and the report says a ring exists")
	require(terrain.debug_update_vt_clipmap(MATERIAL) >= 0,
			"while the diffuse+normal group's entry steps the ring its own source carries as well")
	require(not terrain.is_vt_delivery_used(CLIPMAP), "and none of this makes the matrix report Clipmap as used")
	print("VT_DELIVERY_CLIPMAP_ENTRY ", describe())

	# 4. The two legacy booleans are views of a cell, not a second source of truth: writing one
	#    writes the cell and reading one asks the cell.
	terrain.vt_delivery_near_height = DIRECT
	terrain.set_surface_vt_enabled(true)
	await settle(2)
	require(cell(NEAR, MATERIAL) == AVT, "set_surface_vt_enabled(true) writes the near material cell")
	require(terrain.is_surface_vt_enabled(), "is_surface_vt_enabled() reads the near material cell")
	terrain.set_surface_vt_enabled(false)
	await settle(2)
	require(cell(NEAR, MATERIAL) == DIRECT, "set_surface_vt_enabled(false) writes the near material cell")
	require(not terrain.is_surface_vt_enabled(), "and the reading follows it")
	terrain.set_surface_svt_enabled(false)
	await settle(2)
	require(cell(FAR, MATERIAL) == DIRECT, "set_surface_svt_enabled(false) writes the far material cell")
	require(not terrain.is_surface_svt_enabled(), "and the reading follows it")
	terrain.set_surface_svt_enabled(true)
	await settle(2)
	require(cell(FAR, MATERIAL) == SVT, "set_surface_svt_enabled(true) writes the far material cell")
	print("VT_DELIVERY_LEGACY ", describe())

	# 5. Reversibility: the matrix is a setting, so returning the cells to their defaults has to
	#    bring the whole assembly back.
	terrain.vt_delivery_near_material = AVT
	await settle(8)
	s = settings()
	require(bool(s.get("avt_service", false)) and bool(s.get("svt_service", false)), "the services come back with the cells")
	require(shader_uses_vt(), "the virtual-texture arms come back with the cells")
	print("VT_DELIVERY_RESTORED ", describe())

	# 6. The two editor previews and the gates in front of them. AVT's gate is a matrix cell and the
	#    clipmap's is a ring object, and each *refuses* an ask rather than answering it with an empty
	#    drawing, so neither the inspector nor the dock spends a scan per poll on something that is not
	#    there. The two counters make that a reading - an ask that is refused moves `*_preview_calls`
	#    and leaves `*_preview_computed` where it was.
	require(terrain.is_vt_delivery_used(AVT), "AVT is reported as used while a cell selects it")
	require(not terrain.is_vt_delivery_used(CLIPMAP), "and Clipmap is not, because no cell names it in this configuration")
	require(not terrain.is_vt_delivery_used(4), "and a value outside the enum is refused rather than clamped")
	var before := settings()
	terrain.get_avt_layout_preview(camera)
	require(not terrain.get_clipmap_layout_preview().is_empty(),
			"the clipmap preview answers, because a ring exists - the entry built one")
	var used := settings()
	require(int(used.get("avt_preview_computed", 0)) - int(before.get("avt_preview_computed", 0)) == 1,
			"the AVT preview did its work, because a cell selects AVT")
	require(int(used.get("clipmap_preview_computed", 0)) - int(before.get("clipmap_preview_computed", 0)) == 1,
			"and the clipmap's did too, because its ring exists")

	# Clearing the two material cells again: the AVT gate closes while the ring's stays open, because
	# the object is kept when nothing selects it. That the two answer differently on one terrain is
	# what "per method" means, and it is the half of the rule the object gate adds.
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	await settle(2)
	require(not terrain.is_vt_delivery_used(AVT), "clearing the AVT cells unsets the question")
	for _i in 2:
		require(terrain.get_avt_layout_preview(camera).is_empty(), "so the AVT preview is empty")
		require(not terrain.get_clipmap_layout_preview().is_empty(),
				"while the clipmap preview still answers: its ring is an object, and a deselection keeps it")
	var refused := settings()
	require(int(refused.get("avt_preview_calls", 0)) - int(used.get("avt_preview_calls", 0)) == 2,
			"two AVT asks were counted")
	require(int(refused.get("avt_preview_computed", 0)) == int(used.get("avt_preview_computed", 0)),
			"and neither of them scanned")
	require(int(refused.get("clipmap_preview_computed", 0)) - int(used.get("clipmap_preview_computed", 0)) == 2,
			"and the two clipmap asks both did their work, because a ring was there to describe")
	print("VT_DELIVERY_PREVIEW_GATE avt_calls=%d avt_computed=%d clipmap_calls=%d clipmap_computed=%d ring=%s" % [
		int(refused.get("avt_preview_calls", 0)), int(refused.get("avt_preview_computed", 0)),
		int(refused.get("clipmap_preview_calls", 0)), int(refused.get("clipmap_preview_computed", 0)),
		str(refused.get("clipmap_ring"))])

	if failed:
		print("REGRESSION: delivery matrix assembly")
		quit(1)
		return
	print("PASS delivery matrix assembly")
	quit(0)
