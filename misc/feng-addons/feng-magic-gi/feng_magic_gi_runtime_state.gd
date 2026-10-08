@tool
extends RefCounted
## Mutable main-thread state owned by FMagicGIRuntime for one volume.
## World selection, viewport routing, and publication stay in the Runtime service.

const Lighting = preload("feng_magic_gi_lighting.gd")
const Emission = preload("feng_magic_gi_emission.gd")

var volume_ref: WeakRef
var published_sequence := 0
var data_key := ""
var lighting := Lighting.new()
var emission := Emission.new()

func attach(volume: FMagicGIVolume) -> void:
	volume_ref = weakref(volume)

func get_volume() -> FMagicGIVolume:
	return volume_ref.get_ref() as FMagicGIVolume if volume_ref != null else null
