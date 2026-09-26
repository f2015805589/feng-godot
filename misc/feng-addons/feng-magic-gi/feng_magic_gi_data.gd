@tool
class_name FMagicGIData
extends Resource
## One baked probe set of a FMagicGIVolume.
##
## Layout: `grid_dims` probes on a regular grid spanning the volume's box, edges
## included, index = ix + iy*dims.x + iz*dims.x*dims.y. `sh` holds 27 floats per
## probe (9 SH basis coefficients times RGB, coefficient-major: c0r,c0g,c0b,
## c1r,...) in the order of SH_BASIS in feng_magic_gi_baker.gd. The coefficients
## are *radiance* SH (no cosine convolution); the apply shader folds in the
## irradiance weights so the same data can later feed glossy reconstruction.
##
## `volume_transform` is the volume's global transform at bake time; probes live
## in that space. `world_to_grid` maps a world position straight to grid index
## space (cell coordinates where probe i sits at integer i): it folds the inverse
## volume transform with the -0.5 size offset and the dims-1 scale, so the shader
## only needs one multiply.

const SH_TEXELS_PER_PROBE := 7  # 27 floats -> 7 RGBA32F texels (last 5 floats unused)

## Probes per axis of the volume's box. A zero axis means a single probe there.
@export var grid_dims := Vector3i.ZERO
## global_transform of the volume when the bake ran.
@export var volume_transform := Transform3D.IDENTITY
## world position -> grid index space; see the header comment.
@export var world_to_grid := Transform3D.IDENTITY
## Radiance SH coefficients, 27 floats per probe (9 coeffs x RGB).
@export var sh := PackedFloat32Array()
## Bumped on every bake so consumers can spot a stale texture.
@export var bake_version := 0

func probe_count() -> int:
	return grid_dims.x * grid_dims.y * grid_dims.z

func is_valid() -> bool:
	return grid_dims.x > 0 and grid_dims.y > 0 and grid_dims.z > 0 and \
		sh.size() == probe_count() * 27

## The SH table as a one-row RGBA32F image, 7 texels per probe. The pass uploads
## this verbatim into an RD texture, so the shader fetches texel 7*p + k.
func make_atlas_image() -> Image:
	if not is_valid():
		return null
	var count := probe_count()
	var image := Image.create_empty(count * SH_TEXELS_PER_PROBE, 1, false, Image.FORMAT_RGBAF)
	for p in count:
		var base := p * 27
		for t in SH_TEXELS_PER_PROBE:
			var texel := Color(0, 0, 0, 0)
			for c in 4:
				var index := base + t * 4 + c
				if index < base + 27:
					texel[c] = sh[index]
			image.set_pixel(7 * p + t, 0, texel)
	return image
