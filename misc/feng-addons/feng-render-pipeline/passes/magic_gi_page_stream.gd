@tool
extends RefCounted
## Spatial ownership and view selection for streamed Magic GI pages.
##
## Page bounds are half-open. Support bounds are deliberately ignored here:
## they let a core page gather neighboring probes, but never acquire pixels.

const MANAGER_BLOCK_XZ := 512.0
const DEFAULT_CORE_PAGE := 32.0
const MAX_PAGE_PROBES := 32768
const GPU_RESIDENT_BUDGET_BYTES := 128 * 1024 * 1024
const GPU_UPLOAD_BUDGET_BYTES_PER_FRAME := 16 * 1024 * 1024
const GPU_GLOBAL_RESERVE_BYTES := 12 * 1024 * 1024


static func owner_index(pages: Array, world: Vector3) -> int:
	var best_key := ""
	var best := -1
	for i in pages.size():
		var page: Variant = pages[i]
		if not page is Dictionary:
			continue
		var bounds: Variant = page.get("core_bounds")
		if not bounds is AABB or not contains_half_open(bounds, world):
			continue
		var key := str(page.get("page_key", ""))
		if best < 0 or key < best_key:
			best = i
			best_key = key
	return best


static func contains_half_open(bounds: AABB, point: Vector3) -> bool:
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return false
	var maximum := bounds.position + bounds.size
	return point.x >= bounds.position.x and point.y >= bounds.position.y \
		and point.z >= bounds.position.z and point.x < maximum.x \
		and point.y < maximum.y and point.z < maximum.z


## Returns a conservative screen rectangle. A core crossing the near plane uses
## the full view so clipping cannot omit a visible core; an entirely-behind core
## is skipped.
static func project_core(bounds: AABB, view_projection: Projection,
		camera: Vector3, extent: Vector2i,
		world_to_view: Transform3D = Transform3D.IDENTITY) -> Dictionary:
	if extent.x <= 0 or extent.y <= 0 or bounds.size.x <= 0.0 \
			or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return {"visible": false, "rect": Rect2i()}
	if contains_half_open(bounds, camera):
		return {"visible": true, "rect": Rect2i(Vector2i.ZERO, extent), "full_view": true}
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	var near_crossing := false
	var uncertain_projection := false
	var front_corner_count := 0
	for z in 2:
		for y in 2:
			for x in 2:
				var world_corner := bounds.position + Vector3(
					bounds.size.x * float(x), bounds.size.y * float(y),
					bounds.size.z * float(z))
				var corner := world_to_view * world_corner
				var clip: Vector4 = view_projection * Vector4(corner.x, corner.y, corner.z, 1.0)
				if not is_finite(clip.w):
					uncertain_projection = true
					continue
				if clip.w <= 0.02:
					near_crossing = true
					continue
				front_corner_count += 1
				var ndc := Vector2(clip.x, clip.y) / clip.w
				if not is_finite(ndc.x) or not is_finite(ndc.y):
					uncertain_projection = true
					continue
				# magic_gi_apply reconstructs clip.y as screen_uv.y * 2 - 1.
				# Keep this projection in the same coordinate convention: do not flip Y.
				var uv := (ndc + Vector2.ONE) * 0.5
				minimum = minimum.min(uv)
				maximum = maximum.max(uv)
	# A convex page whose every corner is behind or inside the near cutoff cannot
	# contribute pixels. Only a volume that crosses the near plane needs the
	# conservative full-view dispatch.
	if front_corner_count == 0 and not uncertain_projection:
		return {"visible": false, "rect": Rect2i()}
	if uncertain_projection or (near_crossing and front_corner_count > 0):
		return {"visible": true, "rect": Rect2i(Vector2i.ZERO, extent), "full_view": true}
	if maximum.x <= 0.0 or maximum.y <= 0.0 or minimum.x >= 1.0 or minimum.y >= 1.0:
		return {"visible": false, "rect": Rect2i()}
	minimum = minimum.clamp(Vector2.ZERO, Vector2.ONE)
	maximum = maximum.clamp(Vector2.ZERO, Vector2.ONE)
	var lower := Vector2i(floor(minimum.x * extent.x), floor(minimum.y * extent.y))
	var upper := Vector2i(ceil(maximum.x * extent.x), ceil(maximum.y * extent.y))
	lower = lower.clamp(Vector2i.ZERO, extent)
	upper = upper.clamp(Vector2i.ZERO, extent)
	if upper.x <= lower.x or upper.y <= lower.y:
		return {"visible": false, "rect": Rect2i()}
	return {"visible": true, "rect": Rect2i(lower, upper - lower), "full_view": false}


static func gpu_relevant(core: AABB, projection: Dictionary, cache_prefetch_bounds: AABB) -> bool:
	return bool(projection.get("visible", false)) or core.intersects(cache_prefetch_bounds)


static func descriptor_for_key(manifest: Object, page_key: String) -> Dictionary:
	if manifest == null or not is_instance_valid(manifest) \
			or not manifest.has_method("get_page_metadata"):
		return {}
	var value: Variant = manifest.call("get_page_metadata", page_key)
	if not value is Dictionary:
		return {}
	var result: Dictionary = value.duplicate()
	result["page_key"] = page_key
	return result


static func normalize_streamed_snapshot(snapshot: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var pages: Variant = snapshot.get("pages", [])
	if pages is Array:
		for value in pages:
			if value is Dictionary and value.get("data") is Resource \
					and value.get("core_bounds") is AABB:
				result.append(value)
		result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return str(a.get("page_key", "")) < str(b.get("page_key", "")))
	return result


static func upload_image_bytes(upload: Dictionary) -> int:
	var total := 0
	for key in ["transfer_image", "primary_sky_image", "geometry_image",
			"visibility_moment_image", "emission_image"]:
		var image: Variant = upload.get(key)
		if image is Image:
			total += image_byte_count(image)
	return total


static func bytes_per_image_are_uploadable(upload: Dictionary) -> bool:
	for key in ["transfer_image", "primary_sky_image", "geometry_image",
			"visibility_moment_image", "emission_image"]:
		var image: Variant = upload.get(key)
		if image is Image and image_byte_count(image) > GPU_UPLOAD_BUDGET_BYTES_PER_FRAME:
			return false
	return true


static func image_byte_count(image: Image) -> int:
	if image == null or image.is_empty():
		return 0
	var bytes_per_pixel := 0
	match image.get_format():
		Image.FORMAT_R8: bytes_per_pixel = 1
		Image.FORMAT_RG8: bytes_per_pixel = 2
		Image.FORMAT_RGB8: bytes_per_pixel = 3
		Image.FORMAT_RGBA8: bytes_per_pixel = 4
		Image.FORMAT_RH: bytes_per_pixel = 2
		Image.FORMAT_RGH: bytes_per_pixel = 4
		Image.FORMAT_RGBH: bytes_per_pixel = 6
		Image.FORMAT_RGBAH: bytes_per_pixel = 8
		Image.FORMAT_RF: bytes_per_pixel = 4
		Image.FORMAT_RGF: bytes_per_pixel = 8
		Image.FORMAT_RGBF: bytes_per_pixel = 12
		Image.FORMAT_RGBAF: bytes_per_pixel = 16
	return image.get_width() * image.get_height() * bytes_per_pixel


static func stable_version_key(manifest_key: String, page: Dictionary) -> String:
	return "%s/%s/%d/%s" % [manifest_key, str(page.get("page_key", "")),
		int(page.get("version", -1)), str(page.get("identity", ""))]


static func page_snapshot(root: Dictionary, page: Dictionary, cache_key: String) -> Dictionary:
	var result := root.duplicate(false)
	for key in page:
		result[key] = page[key]
	result["cache_key"] = cache_key
	result["streamed"] = false
	return result


static func obb_contains(owner_transform: Transform3D, owner_size: Vector3, world: Vector3) -> bool:
	if not owner_size.is_finite() or owner_size.x <= 0.0 or owner_size.y <= 0.0 or owner_size.z <= 0.0:
		return false
	var local := owner_transform.affine_inverse() * world
	var half := owner_size * 0.5
	return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z

