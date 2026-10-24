@tool
class_name FengReflectProbeData
extends Resource
## Portable HDR source for a FengReflectProbe. Captured bakes store the linear
## base cubemap; the runtime rebuilds the GGX roughness pyramid on the GPU.

const ALL_3D_RENDER_LAYERS := 0xFFFFF

@export var radiance: Cubemap:
	set(value):
		if radiance == value:
			return
		radiance = value
		emit_changed()
@export var capture_position := Vector3.ZERO:
	set(value):
		if capture_position == value:
			return
		capture_position = value
		emit_changed()
## World orientation used by the source cubemap. The probe's OBB remains in the
## FengReflectProbe Node3D transform; this basis only orients the captured radiance.
@export var capture_basis := Basis.IDENTITY:
	set(value):
		if capture_basis == value:
			return
		capture_basis = value
		emit_changed()
@export_range(16, 2048, 1, "suffix:px") var capture_resolution := 128:
	set(value):
		var next := clampi(value, 16, 2048)
		if capture_resolution == next:
			return
		capture_resolution = next
		emit_changed()
## Effective capture mask used for the saved cubemap. -1 marks legacy or
## externally-authored data whose original capture mask is unknown.
@export var captured_cull_mask := -1:
	set(value):
		var next := -1 if value < 0 else value & ALL_3D_RENDER_LAYERS
		if captured_cull_mask == next:
			return
		captured_cull_mask = next
		emit_changed()
@export var source_description := "Specified Cubemap":
	set(value):
		if source_description == value:
			return
		source_description = value
		emit_changed()
@export var capture_generation := 0:
	set(value):
		var next := maxi(value, 0)
		if capture_generation == next:
			return
		capture_generation = next
		emit_changed()

func is_valid() -> bool:
	return radiance != null and is_instance_valid(radiance) \
			and radiance.get_width() > 0 and radiance.get_height() > 0 \
			and capture_position.is_finite() and capture_basis.is_finite() \
			and capture_basis.determinant() != 0.0
