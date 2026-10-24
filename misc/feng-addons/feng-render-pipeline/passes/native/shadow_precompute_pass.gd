@tool
extends "native_pass.gd"
## Shadow Pass: draw shadow maps before virtual textures and the G-buffer.
## Directional CSM, filtering and bias are configured here. The engine reads this
## pass's settings before caster culling, not only when the draw callback runs.
##
## This is the one preparation step that depends on nothing else in the frame: it
## renders from each light's point of view, so it reads no scene depth, no G-buffer
## and no material page. That is why it is the pipeline's first pass, before virtual
## texture updates and the G-buffer.
##
## The light and cluster buffers are *not* here: they are consumed by the Lighting
## pass, so they are prepared there.
##
## The default implementation runs the engine's own pass through ctx.run_pass(), so
## replacing the entry with this script renders the same frame. Override
## _frp_execute() to take the pass over with the granular Core primitives.

const SHADOW_DEFAULTS := {
	"shadow_settings_enabled": true,
	"cascade_count": 4,
	"cascade_resolution": 4096,
	"cascade_1_distance": 10.0,
	"cascade_2_distance": 25.0,
	"cascade_3_distance": 50.0,
	"cascade_4_distance": 100.0,
	"blend_cascades": true,
	"shadow_fade_start": 0.8,
	"shadow_pancake_size": 20.0,
	"reserve_object_shadow_slot": false,
	"shadow_filter": 2,
	"pcss_angular_diameter": 0.5,
	"shadow_blur": 1.0,
	"shadow_filter_quality": 2,
	"shadow_bias": 0.1,
	"shadow_normal_bias": 2.0,
	"shadow_transmittance_bias": 0.05,
	"shadow_opacity": 1.0,
}

@export_group("Directional CSM")
## Use this pass's directional shadow settings for this renderer's cameras.
## Disabled retains the individual light and project shadow settings.
@export var shadow_settings_enabled := true:
	set(value):
		shadow_settings_enabled = value
		emit_changed()
## Total shadow slots. Reserving an object slot leaves one fewer CSM cascade.
@export_range(1, 4, 1) var cascade_count := 4:
	set(value):
		cascade_count = clampi(value, 1, 4)
		notify_property_list_changed()
## Resolution of EACH cascade (and the optional object slot), not the whole atlas.
@export_enum("256:256", "512:512", "1024:1024", "2048:2048", "4096:4096", "8192:8192") var cascade_resolution := 4096:
	set(value):
		cascade_resolution = value
		emit_changed()
## View-depth endpoint in meters. Each active endpoint must exceed the previous.
@export_range(0.01, 10000.0, 0.01, "or_greater", "suffix:m") var cascade_1_distance := 10.0:
	set(value):
		cascade_1_distance = value
		emit_changed()
@export_range(0.01, 10000.0, 0.01, "or_greater", "suffix:m") var cascade_2_distance := 25.0:
	set(value):
		cascade_2_distance = value
		emit_changed()
@export_range(0.01, 10000.0, 0.01, "or_greater", "suffix:m") var cascade_3_distance := 50.0:
	set(value):
		cascade_3_distance = value
		emit_changed()
@export_range(0.01, 10000.0, 0.01, "or_greater", "suffix:m") var cascade_4_distance := 100.0:
	set(value):
		cascade_4_distance = value
		emit_changed()
@export var blend_cascades := true:
	set(value):
		blend_cascades = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var shadow_fade_start := 0.8:
	set(value):
		shadow_fade_start = value
		emit_changed()
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:m") var shadow_pancake_size := 20.0:
	set(value):
		shadow_pancake_size = value
		emit_changed()
## Reserves the final slot for the DirectionalLight3D's object shadow target.
@export var reserve_object_shadow_slot := false:
	set(value):
		reserve_object_shadow_slot = value
		notify_property_list_changed()

@export_group("Shadow Filtering")
@export_enum("Hard", "PCF", "PCSS") var shadow_filter := 2:
	set(value):
		shadow_filter = clampi(value, 0, 2)
		notify_property_list_changed()
## Angular light diameter used only for PCSS penumbra, without changing the sun's
## visible disk or material highlights.
@export_range(0.0, 20.0, 0.01, "suffix:°") var pcss_angular_diameter := 0.5:
	set(value):
		pcss_angular_diameter = value
		emit_changed()
@export_range(0.0, 4.0, 0.01, "or_greater") var shadow_blur := 1.0:
	set(value):
		shadow_blur = value
		emit_changed()
@export_enum("Hard", "Very Low", "Low", "Medium", "High", "Ultra") var shadow_filter_quality := 2:
	set(value):
		shadow_filter_quality = clampi(value, 0, 5)
		emit_changed()

@export_group("Shadow Bias")
@export_range(0.0, 10.0, 0.001, "or_greater") var shadow_bias := 0.1:
	set(value):
		shadow_bias = value
		emit_changed()
@export_range(0.0, 10.0, 0.01, "or_greater") var shadow_normal_bias := 2.0:
	set(value):
		shadow_normal_bias = value
		emit_changed()
@export_range(0.0, 10.0, 0.001, "or_greater") var shadow_transmittance_bias := 0.05:
	set(value):
		shadow_transmittance_bias = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var shadow_opacity := 1.0:
	set(value):
		shadow_opacity = value
		emit_changed()

func _init() -> void:
	resource_name = "Shadow Pass"

func _native_pass_id() -> int:
	return NativeSpec.PASS_SHADOW_PRECOMPUTE

func get_frp_parameters() -> Dictionary:
	var result := {}
	for key in SHADOW_DEFAULTS:
		result[key] = get(key)
	return result

func get_csm_cascade_count() -> int:
	return maxi(1, cascade_count - int(reserve_object_shadow_slot and cascade_count > 1))

## The pipeline entry forwards these controls directly, while the implementation
## remains the single serialized owner of their values.
func get_shadow_settings_property_list() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for property in get_property_list():
		if SHADOW_DEFAULTS.has(String(property.name)) or String(property.name) in ["Directional CSM", "Shadow Filtering", "Shadow Bias"]:
			result.append(property.duplicate())
	return result

func is_shadow_setting(property: StringName) -> bool:
	return SHADOW_DEFAULTS.has(String(property))

func get_shadow_setting_default(property: StringName) -> Variant:
	return SHADOW_DEFAULTS.get(String(property))

func ensure_frp_contract() -> bool:
	if resource_name in ["", "Shadow Precompute"]:
		resource_name = "Shadow Pass"
		return true
	return false

func _validate_property(property: Dictionary) -> void:
	var key := String(property.name)
	if key.begins_with("cascade_") and key.ends_with("_distance"):
		if int(key.get_slice("_", 1)) > get_csm_cascade_count():
			property.usage = PROPERTY_USAGE_STORAGE
	if key == "pcss_angular_diameter" and shadow_filter != 2:
		property.usage = PROPERTY_USAGE_STORAGE
	if key in ["shadow_blur", "shadow_filter_quality"] and shadow_filter == 0:
		property.usage = PROPERTY_USAGE_STORAGE

func get_configuration_warnings() -> PackedStringArray:
	var warnings := super.get_configuration_warnings()
	if not shadow_settings_enabled:
		return warnings
	var previous := 0.0
	for i in get_csm_cascade_count():
		var endpoint: float = get("cascade_%d_distance" % (i + 1))
		if endpoint <= previous:
			warnings.append("CSM cascade distances must increase. The renderer clamps invalid endpoints for safety.")
			break
		previous = endpoint
	if reserve_object_shadow_slot and cascade_count == 1:
		warnings.append("An object shadow needs at least two slots: one CSM cascade and one object slot.")
	return warnings
