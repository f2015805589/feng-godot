@tool
extends RefCounted
## Mutable main-thread state owned by FMagicGIRuntime for one volume.
## World selection, viewport routing, and publication stay in the Runtime service.

const Lighting = preload("feng_magic_gi_lighting.gd")
const Emission = preload("feng_magic_gi_emission.gd")
const Data = preload("feng_magic_gi_data.gd")

var volume_ref: WeakRef
var published_sequence := 0
var data_key := ""
var lighting := Lighting.new()
var emission_helper := Emission.new()
var emission_identity := ""
var emission_source_values := PackedFloat32Array()
var emission_payload := PackedFloat32Array()
var emission_revision := 0
var emission_warning := ""

func attach(volume: FMagicGIVolume) -> void:
	volume_ref = weakref(volume)

func get_volume() -> FMagicGIVolume:
	return volume_ref.get_ref() as FMagicGIVolume if volume_ref != null else null

func refresh_emission_diagnostics(volume: FMagicGIVolume, data: Data) -> String:
	if volume == null or not is_instance_valid(volume) or data == null or not is_instance_valid(data):
		emission_warning = ""
		return emission_warning
	_read_emission_sources(volume, data)
	return emission_warning

## Refreshes the live emission payload. Returns true only when a new payload must
## receive a globally unique revision from FMagicGIRuntime.
func update_emission_snapshot(volume: FMagicGIVolume, data: Data, bake_version: int) -> bool:
	if volume == null or not is_instance_valid(volume) or data == null or not is_instance_valid(data):
		return false
	var source_values := _read_emission_sources(volume, data)
	var identity := "%d:%d:%d" % [volume.get_instance_id(), data.get_instance_id(), bake_version]
	if identity == emission_identity and source_values == emission_source_values:
		return false

	# Data owns composition validation and returns finite RGB for every probe.
	emission_payload = data.compose_emission(source_values)

	emission_identity = identity
	emission_source_values = source_values
	return true

func _read_emission_sources(volume: FMagicGIVolume, data: Data) -> PackedFloat32Array:
	var source_values := emission_helper.read_source_values(volume, data)
	emission_warning = emission_helper.get_warning()
	# The helper fixes the array shape. Check the packed values because a finite
	# GDScript float can overflow when stored as float32.
	var finite := true
	for value in source_values:
		if not is_finite(value):
			finite = false
			break
	if not finite:
		source_values.fill(0.0)
		emission_warning += " Magic GI emissive values were non-finite and have been disabled."
	return source_values
