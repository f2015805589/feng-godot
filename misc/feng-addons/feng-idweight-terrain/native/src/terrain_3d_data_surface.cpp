// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DData's virtual texture page production.
//
// One of five files that define Terrain3DData. This one turns a region's R16 surface payload into
// the pages both VT tiers upload. The others: `terrain_3d_data.cpp` (slots, the chunk directory and
// the slot maps), `terrain_3d_data_regions.cpp` (region lifecycle and the region table),
// `terrain_3d_data_maps.cpp` (the map arrays, their upload and the queries) and
// `terrain_3d_data_edit.cpp` (edit bookkeeping, the height range and the bindings), with the
// on-disk path in `terrain_3d_data_io.cpp`.
//
// This file includes what it uses, not the family's old shared block: that block named
// terrain_surface_idweight.h, logger.h, DirAccess, EditorFileSystem, EditorInterface, FileAccess,
// ResourceSaver and <algorithm>, none of which appears in these 262 lines. `terrain_vt.h` is here
// for `TerrainVT::log2_power_of_two()`, the level arithmetic this half shares with the addressing
// contract.

#include "terrain_3d_data.h"
#include "terrain_vt.h"

#include <cstring>
#include <unordered_map>
#include <vector>

// Virtual texture page production. Reads the region's R16 surface map once and
// resamples it into every page of one local mip.
//
// Layout: the sector block is `p_pages_per_axis` pages per axis at local mip 0, so
// mip `m` has `max(1, pages >> m)` pages per axis and each page covers
// `region_size / pages_at_mip` region texels. Sampling is nearest, which is exact
// for a 1:1 crop and a plain point upsample otherwise. Border texels sample the
// adjacent world location so filtering agrees on either side of a page seam.
int Terrain3DData::produce_surface_page_set(const Vector2i &p_region_loc, const int p_pages_per_axis,
		const int p_page_size, const int p_border, const std::vector<Vector3i> &p_requests,
		std::vector<Ref<Image>> &r_pages) {
	r_pages.clear();
	if (_region_size <= 0 || p_page_size <= 0 || p_border < 0 || p_pages_per_axis <= 0) {
		return -1;
	}
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		return -1;
	}
	const int max_local_mip = TerrainVT::log2_power_of_two(p_pages_per_axis);

	// Regions without a surface map produce the blank page, which is what the array
	// path shows too: all-zero packed values are single material 0.
	Ref<Image> source = region->get_surface_map();
	PackedByteArray source_bytes;
	int source_size = _region_size;
	if (source.is_valid() && source->get_format() == IDWEIGHT_IMAGE_FORMAT &&
			source->get_width() == source->get_height()) {
		source_size = source->get_width();
		source_bytes = source->get_data();
	}

	const int stored = p_page_size + 2 * p_border;
	const uint8_t *source_ptr = source_bytes.is_empty() ? nullptr : source_bytes.ptr();
	std::vector<int> columns(size_t(stored), 0);
	auto floor_divide = [](int n, int d) { return n >= 0 ? n / d : -((-n + d - 1) / d); };

	for (const Vector3i &request : p_requests) {
		const int local_mip = request.z;
		if (local_mip < 0 || local_mip > max_local_mip) {
			return -1;
		}
		const int pages_at_mip = MAX(1, p_pages_per_axis >> local_mip);
		// Span in *source* texels, which is region_size * surface_density. The page
		// grid always covers the whole region, so a denser payload simply gives every
		// page more texels to sample from.
		const int span = MAX(1, source_size / pages_at_mip);
		if (request.x < 0 || request.y < 0 || request.x >= pages_at_mip || request.y >= pages_at_mip) {
			return -1;
		}
		const int origin_x = request.x * span;
		const int origin_y = request.y * span;
		PackedByteArray page_bytes;
		page_bytes.resize(int64_t(stored) * stored * 2);
		// This is a nearest-neighbour resample, so a page column's source column does
		// not depend on the row. Resolving the columns once keeps the inner loop to a
		// two-byte load and store: `PackedByteArray::decode_u16`/`encode_u16` are
		// GDExtension builtin-method calls with Variant marshalling, and at 264x264
		// texels per page they were the entire cost of a demand pass.
		for (int x = 0; x < stored; x++) {
			columns[size_t(x)] = origin_x + floor_divide((x - p_border) * span, p_page_size);
		}
		if (source_ptr == nullptr) {
			// `resize` already zero-filled, which is single material 0.
		} else {
			uint8_t *page_ptr = page_bytes.ptrw();
			const real_t vertex_spacing = MAX(0.0001f, _vertex_spacing);
			const real_t region_world = real_t(_region_size) * vertex_spacing;
			const real_t region_origin_x = real_t(p_region_loc.x) * region_world;
			const real_t region_origin_z = real_t(p_region_loc.y) * region_world;
			const real_t payload_texel = vertex_spacing / real_t(MAX(1, region->get_surface_density()));
			for (int y = 0; y < stored; y++) {
				// Floor negative fractional border positions into the adjacent texel.
				const int region_y = origin_y + floor_divide((y - p_border) * span, p_page_size);
				const bool inside_y = region_y >= 0 && region_y < source_size;
				const int64_t row = int64_t(region_y) * source_size;
				uint8_t *out = page_ptr + int64_t(y) * stored * 2;
				for (int x = 0; x < stored; x++) {
					const int region_x = columns[size_t(x)];
					uint16_t value = 0;
					if (inside_y && region_x >= 0 && region_x < source_size) {
						const uint8_t *texel = source_ptr + (row + region_x) * 2;
						value = uint16_t(texel[0]) | (uint16_t(texel[1]) << 8);
					} else {
						// A border texel belongs to a neighbouring region, so sample it by
						// world position rather than replicating this region's edge. The
						// near and far fields then fill their borders the same way.
						value = _sample_payload_world(region_origin_x + real_t(region_x) * payload_texel,
								region_origin_z + real_t(region_y) * payload_texel);
					}
					out[x * 2] = uint8_t(value & 0xFF);
					out[x * 2 + 1] = uint8_t(value >> 8);
				}
			}
		}
		Ref<Image> page = Image::create_from_data(stored, stored, false, IDWEIGHT_IMAGE_FORMAT, page_bytes);
		if (page.is_null()) {
			return -1;
		}
		r_pages.push_back(page);
	}
	return int(r_pages.size());
}

// World-aligned page production for the far field. The page's world rect can span
// several regions, so the region behind every texel is resolved through a small grid of
// region pointers built once per page, and each texel takes its owner's payload on the
// density grid. Border texels map outside the page and therefore come from the
// neighbouring region, which is exactly what a bilinear tap at a seam needs. A texel
// with no region behind it stays material 0.
int Terrain3DData::produce_sparse_surface_page(const int p_page_x, const int p_page_y,
		const int p_local_mip, const real_t p_page_world_size, const int p_page_size,
		const int p_border, Ref<Image> &r_page) {
	if (p_local_mip < 0 || p_local_mip > 30 || p_page_world_size <= 0.f) { return -1; }
	const int scale = 1 << p_local_mip;
	return produce_surface_rect_page(Rect2(Vector2((p_page_x >> p_local_mip) * scale, (p_page_y >> p_local_mip) * scale) * p_page_world_size,
			Vector2(scale, scale) * p_page_world_size), p_page_size, p_border, r_page);
}

int Terrain3DData::produce_surface_rect_page(const Rect2 &p_rect, int p_page_size, int p_border, Ref<Image> &r_page) {
	r_page = Ref<Image>();
	if (_region_size <= 0 || p_page_size <= 0 || p_border < 0 || p_rect.size.x <= 0.f) { return -1; }
	const real_t vertex_spacing = MAX(0.0001f, _vertex_spacing);
	const real_t region_world = real_t(_region_size) * vertex_spacing;
	const real_t texel_world = p_rect.size.x / real_t(p_page_size);
	const real_t origin_x = p_rect.position.x;
	const real_t origin_z = p_rect.position.y;
	const int stored = p_page_size + 2 * p_border;

	// Region grid covering the page and its border ring.
	const real_t min_x = origin_x - real_t(p_border) * texel_world;
	const real_t min_z = origin_z - real_t(p_border) * texel_world;
	const real_t max_x = origin_x + real_t(p_page_size + p_border - 1) * texel_world;
	const real_t max_z = origin_z + real_t(p_page_size + p_border - 1) * texel_world;
	const int rx0 = int(Math::floor(min_x / region_world));
	const int rz0 = int(Math::floor(min_z / region_world));
	const int span_x = int(Math::floor(max_x / region_world)) - rx0 + 1;
	const int span_z = int(Math::floor(max_z / region_world)) - rz0 + 1;
	// One cell per region the page and its border ring touch. The payload pointer is
	// resolved once here instead of once per texel: `decode_u16` is a GDExtension
	// builtin-method call with Variant marshalling, and at 264x264 texels per page a
	// pair of those per texel was the entire cost of a page (8.9 ms measured by
	// vt_perf). The `Ref` keeps the image alive, so the pointer stays valid.
	struct SourceCell {
		Ref<Image> image;
		PackedByteArray bytes;
		const uint8_t *data = nullptr;
		int size = 0;
		std::vector<int> columns;
		int previous_dy = -1;
		int previous_y = -1;
		real_t payload_texel = 1.f;
		real_t origin_x = 0.f;
		real_t origin_z = 0.f;
	};
	// A root page can cover hundreds of kilometres. Cache only resident sources,
	// never a dense table proportional to the (mostly empty) world area.
	std::unordered_map<int64_t, SourceCell> cells;
	for (const Vector2i &location : get_region_locations()) {
		const int rx = location.x - rx0;
		const int rz = location.y - rz0;
		if (rx >= 0 && rx < span_x && rz >= 0 && rz < span_z) {
			Terrain3DRegion *region = get_region_ptr(location);
			if (!region || region->is_deleted() || region->get_surface_map().is_null()) {
				continue;
			}
			SourceCell &cell = cells[int64_t(rz) * span_x + rx];
			cell.image = region->get_surface_map();
			cell.size = cell.image->get_width();
			cell.payload_texel = vertex_spacing / real_t(MAX(1, region->get_surface_density()));
			cell.origin_x = real_t(rx0 + rx) * region_world;
			cell.origin_z = real_t(rz0 + rz) * region_world;
			cell.bytes = cell.image->get_data();
			cell.data = cell.bytes.ptr();
			cell.columns.resize(stored);
			for (int x = 0; x < stored; ++x) {
				const real_t world_x = origin_x + (real_t(x - p_border) + 0.5f) * texel_world;
				cell.columns[x] = CLAMP(int(Math::floor((world_x - cell.origin_x) / cell.payload_texel)), 0, cell.size - 1);
			}
		}
	}

	PackedByteArray bytes;
	bytes.resize(int64_t(stored) * stored * 2);
	uint8_t *bytes_ptr = bytes.ptrw();
	// The page column decides which region column a texel belongs to, independent of
	// the row, so both the region index and the world position are resolved once.
	std::vector<int> column_region(size_t(stored), 0);
	std::vector<real_t> column_world_x(size_t(stored), 0.f);
	for (int x = 0; x < stored; x++) {
		column_world_x[size_t(x)] = origin_x + (real_t(x - p_border) + 0.5f) * texel_world;
		column_region[size_t(x)] = int(Math::floor(column_world_x[size_t(x)] / region_world)) - rx0;
	}
	for (int y = 0; y < stored; y++) {
		const real_t world_z = origin_z + (real_t(y - p_border) + 0.5f) * texel_world;
		const int rz = int(Math::floor(world_z / region_world)) - rz0;
		if (rz < 0 || rz >= span_z) {
			continue;
		}
		uint8_t *out = bytes_ptr + int64_t(y) * stored * 2;
		for (int x = 0; x < stored;) {
			const int first = x;
			const int rx = column_region[size_t(x)];
			while (x < stored && column_region[size_t(x)] == rx) { ++x; }
			const auto entry = cells.find(int64_t(rz) * span_x + rx);
			if (rx < 0 || rx >= span_x || entry == cells.end()) { continue; }
			SourceCell &cell = entry->second;
			const int dy = CLAMP(int(Math::floor((world_z - cell.origin_z) / cell.payload_texel)), 0, cell.size - 1);
			if (cell.previous_y == y - 1 && cell.previous_dy == dy) {
				std::memcpy(out + first * 2, out - stored * 2 + first * 2, size_t(x - first) * 2);
			} else {
				const uint8_t *row = cell.data + int64_t(dy) * cell.size * 2;
				for (int column = first; column < x; ++column) {
					const uint8_t *texel = row + cell.columns[column] * 2;
					out[column * 2] = texel[0];
					out[column * 2 + 1] = texel[1];
				}
			}
			cell.previous_dy = dy;
			cell.previous_y = y;
		}
	}
	r_page = Image::create_from_data(stored, stored, false, IDWEIGHT_IMAGE_FORMAT, bytes);
	if (r_page.is_null()) {
		return -1;
	}
	return stored;
}

Ref<Image> Terrain3DData::make_sparse_surface_page(const int p_page_x, const int p_page_y,
		const int p_local_mip, const real_t p_page_world_size, const int p_page_size,
		const int p_border) {
	Ref<Image> page;
	produce_sparse_surface_page(p_page_x, p_page_y, p_local_mip, p_page_world_size, p_page_size,
			p_border, page);
	return page;
}

// One payload texel, by nearest, in the form the shader's own corner read takes it
// (`get_surface_texel()`): the grid is the *stored payload's*, so the index is
// `floor(world * density / vertex_spacing)` on the region's own density - the one the image was
// written at - and is reduced into that image. A region with no surface map, or an image that cannot
// hold the texel, reads 0 - the value an array sample outside a filled layer gives, so a hole and a
// region blend stay decisions of whoever reads the ring rather than of the source.
uint32_t Terrain3DData::get_surface_texel_nearest(const Vector2 &p_world_xz) const {
	const real_t spacing = MAX(0.0001f, _vertex_spacing);
	// The region first, on the vertex grid: the payload's grid belongs to the region that owns it
	// (its image is `region_size * that region's density` texels an axis), so the density is not known
	// until the region is.
	const Vector2i vgrid(int(Math::floor(p_world_xz.x / spacing)), int(Math::floor(p_world_xz.y / spacing)));
	const Terrain3DRegion *region = get_region_ptr(V2I_DIVIDE_FLOOR(vgrid, _region_size));
	if (region == nullptr || region->is_deleted()) {
		return 0u;
	}
	const Ref<Image> map = region->get_surface_map();
	if (map.is_null()) {
		return 0u;
	}
	const int size = map->get_width();
	if (size <= 0) {
		return 0u;
	}
	const int density = MAX(1, region->get_surface_density());
	const Vector2i payload(int(Math::floor(p_world_xz.x * real_t(density) / spacing)),
			int(Math::floor(p_world_xz.y * real_t(density) / spacing)));
	const Vector2i texel(Math::posmod(payload.x, size), Math::posmod(payload.y, size));
	const PackedByteArray bytes = map->get_data();
	if (bytes.size() < int64_t(size) * int64_t(size) * 2) {
		return 0u;
	}
	const uint8_t *packed = bytes.ptr() + (int64_t(texel.y) * int64_t(size) + int64_t(texel.x)) * 2;
	return uint32_t(packed[0]) | (uint32_t(packed[1]) << 8);
}
