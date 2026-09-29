@tool
extends "native_pass.gd"
## Bloom: prepares the Environment's native Gaussian Glow texture. The Post Process /
## Tonemap entry later composites it with the Environment's blend and intensity settings.

func _native_pass_id() -> int:
	return NativeSpec.PASS_BLOOM
