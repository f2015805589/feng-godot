@tool
class_name FMagicGIData
extends Resource
## One baked probe set of a FMagicGIVolume.
##
## Layout: `grid_dims` probes on a regular grid spanning the volume's box, edges
## included, index = ix + iy*dims.x + iz*dims.x*dims.y. `sh` holds 27 floats per
## probe (9 SH basis coefficients times RGB, coefficient-major: c0r,c0g,c0b,
## c1r,...) in the order of `sh_basis`. The coefficients are *radiance* SH (no
## cosine convolution); the apply shader folds in the irradiance weights so the
## same data can later feed glossy reconstruction.
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

## Y_l,m in bake order. Index 0..8, l<=2 (Sloan's convention):
## Y0, Y1-1(y), Y10(z), Y11(x), Y2-2(xy), Y2-1(yz), Y20(3z2-1), Y21(xz), Y22(x2-y2).
## The basis is part of this data's contract: the baker projects with it and the
## editor viz evaluates stored SH with it, so the convention lives in one place.
static func sh_basis(dir: Vector3) -> PackedFloat32Array:
	var c := PackedFloat32Array()
	c.resize(9)
	c[0] = 0.2820947918
	c[1] = 0.4886025119 * dir.y
	c[2] = 0.4886025119 * dir.z
	c[3] = 0.4886025119 * dir.x
	c[4] = 1.0925484306 * dir.x * dir.y
	c[5] = 1.0925484306 * dir.y * dir.z
	c[6] = 0.3153915653 * (3.0 * dir.z * dir.z - 1.0)
	c[7] = 1.0925484306 * dir.x * dir.z
	c[8] = 0.5462742153 * (dir.x * dir.x - dir.y * dir.y)
	return c

func probe_count() -> int:
	return grid_dims.x * grid_dims.y * grid_dims.z

func is_valid() -> bool:
	return grid_dims.x > 0 and grid_dims.y > 0 and grid_dims.z > 0 and \
		sh.size() == probe_count() * 27

## True when this bake also describes `dims`: a volume resized after baking keeps
## a well-formed resource whose probes no longer match its grid.
func fits(dims: Vector3i) -> bool:
	return is_valid() and grid_dims == dims

## This probe's radiance SH evaluated in `dir` (no cosine convolution): what the
## probe "sees" arriving from that direction, in the data's local frame.
func radiance(probe_index: int, dir: Vector3) -> Vector3:
	var y := sh_basis(dir)
	var base := probe_index * 27
	var r := 0.0
	var g := 0.0
	var b := 0.0
	for k in 9:
		r += sh[base + k * 3] * y[k]
		g += sh[base + k * 3 + 1] * y[k]
		b += sh[base + k * 3 + 2] * y[k]
	return Vector3(r, g, b)

## The probe's average incoming light: DC term times Y00, clamped for display.
func dc_color(probe_index: int) -> Color:
	var base := probe_index * 27
	return Color(sh[base] * 0.2820947918, sh[base + 1] * 0.2820947918,
			sh[base + 2] * 0.2820947918).clamp()

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
