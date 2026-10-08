@tool
extends "native_pass.gd"
## Post Process / Tonemap: the frame's final resolve, depth of field, auto exposure
## and tone mapping. The separate Bloom native entry prepares the Environment Glow
## texture before this pass; Tonemap composites it here when that entry ran.
##
## Post-processing and tone mapping are two separate Core primitives, so this pass
## decides where its own overlay runs:
##
##   * before tone mapping: the overlay works on the HDR image the tone mapper reads
##     (that is what `resolve_final()` / `copy_history()` leave in place);
##   * after tone mapping: the tone mapping runs without the engine's present step
##     (`ctx.tonemap_deferred()`), the overlay works on the toned image, and the pass
##     presents the result itself (`ctx.present()`).
##
## `overlay_after_tonemap` selects the position. It is a per-pass parameter
## (`get_frp_parameters()`), so the pipeline resource - or a FengVolume at runtime -
## can switch it, and the overlay shader receives it as the shader keyword
## `POST_AFTER_TONEMAP` (specialization constant 0), so one shader can serve both
## positions and still know whether it is reading HDR or LDR data.
##
## The default implementation runs the engine's own pass through ctx.run_pass(), so
## replacing the entry with this script renders the same frame. Override
## _frp_execute() to take the pass over with the granular Core primitives.

## Specialization constant id an overlay shader declares for the position keyword:
## `layout(constant_id = 0) const bool POST_AFTER_TONEMAP = false;`
const POST_AFTER_TONEMAP_KEYWORD := 0

## The FRP tone mapper for this pass. -1 keeps the current Environment choice;
## Unreal Filmic uses the fixed UE 5.8 SDR/Rec.709 profile.
@export_enum("Inherit Environment:-1", "Linear:0", "Reinhard:1", "Filmic:2", "ACES:3", "AgX:4", "Unreal Filmic (ACES):5") var tonemap_mode: int = 5:
	set(value):
		if tonemap_mode == value:
			return
		tonemap_mode = value
		emit_changed()

## Which side of the tone mapping this pass runs its overlay on. It is an exposed
## parameter, so the setter notifies (an `@export` member does not emit on its own) and
## the overlay's shader keyword follows the authored value.
@export var overlay_after_tonemap := false:
	set(value):
		if overlay_after_tonemap == value:
			return
		overlay_after_tonemap = value
		emit_changed()

func get_frp_parameters() -> Dictionary:
	return {"overlay_after_tonemap": overlay_after_tonemap, "tonemap_mode": tonemap_mode}

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["overlay_after_tonemap", "tonemap_mode"])

func _frp_execute(ctx: FRPPassContext) -> void:
	if ctx == null:
		return
	var resolved_parameters := get_resolved_parameters(ctx)
	var resolved_mode := int(resolved_parameters.get("tonemap_mode", tonemap_mode))
	if resolved_mode < -1 or resolved_mode > 5:
		resolved_mode = 5
	ctx.set_tonemap_mode_override(resolved_mode)

	ctx.resolve_final()
	ctx.copy_history()
	ctx.post_process()

	# An overlay that is switched off is simply not there (see
	# FengNativePass.active_overlay): the pass still resolves, post-processes and tone
	# maps the frame.
	if active_overlay() == null:
		ctx.tonemap()
		return

	var ldr_target := _overlay_ldr_target()
	if bool(resolved_parameters.get("overlay_after_tonemap", overlay_after_tonemap)):
		if ldr_target == &"":
			# An after-tonemap overlay has to own its output: the pass presents what it
			# wrote, so it cannot write into the frame's colour buffer.
			ctx.tonemap()
			run_overlay(ctx)
			return
		# The toned image lands in the engine's intermediate texture; the overlay works
		# on it and writes its own texture, which the pass then presents.
		_configure_overlay(ldr_target, true)
		ctx.tonemap_deferred()
		run_overlay(ctx)
		ctx.present(ldr_target)
	else:
		# The overlay writes into the frame's HDR colour buffer, which the tone mapper
		# then reads.
		_configure_overlay(&"", false)
		run_overlay(ctx)
		ctx.tonemap()

## Tells the overlay which side of the tone mapping it is on, and where it writes:
## into its own texture after the tone mapping (so the pass can present it), or into
## the frame's colour buffer before it.
func _configure_overlay(ldr_target: StringName, after_tonemap: bool) -> void:
	if overlay.has_method("set_shader_keyword"):
		overlay.set_shader_keyword(POST_AFTER_TONEMAP_KEYWORD, after_tonemap)
	if overlay.get("target_name") != null:
		overlay.target_name = ldr_target
	if overlay.get("raster_target") != null:
		overlay.raster_target = ldr_target

## The overlay's own output texture, taken from its declarations: it has to be a named
## pipeline texture for the pass to present it.
func _overlay_ldr_target() -> StringName:
	for declaration in overlay.outputs:
		if declaration != null and declaration.name != &"":
			return declaration.name
	return &""

func _native_pass_id() -> int:
	return NativeSpec.PASS_POST_PROCESS
