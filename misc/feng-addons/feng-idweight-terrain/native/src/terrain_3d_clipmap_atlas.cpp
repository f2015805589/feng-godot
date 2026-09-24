// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The clipmap atlas's implementation. Read terrain_3d_clipmap_atlas.h first: it states the ring
// structure and why the four rings tile the 9x9 grid exactly, what rolling does to a slot's *index*
// rather than to its content, how a spare slot and a per-frame bound remove the unload/load flash,
// and why the upload is a block rect rather than a layer.
//
// The one derivation worth repeating here, because every formula below is a consequence of it. A
// block's nominal square is `[b*W - W/2, b*W + W/2)` for an integer block coordinate `b`, and its
// texel `s` has its centre at `b*W - W/2 + (s+0.5)*texel_r`. Ring `r`'s grid origin is the focus
// snapped to the ring's *own* texel (`O_r`), and the ring's **start point** is `m_r * W` with
// `m_r = round(O_r / W)`. A cell `(gx, gy)` of that ring then wants the block
// `(m_r + gx, m_r + gy)`, and the phase `(O_r - m_r*W) / texel_r` is the same whole number of texels
// for every cell of the ring. That is why one start point a ring and a fixed block size are all a
// block's rect lookup and its matrix need - the user's "store only one origin" simplification - and
// why a block's content is a pure function of its coordinate, which is what lets a slot be
// reassigned between cells instead of re-produced.

#include "terrain_3d_clipmap_atlas.h"

#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>

#include <algorithm>
#include <map>

#include "logger.h"

// The smallest and largest block the settings can ask for. Below 8 texels an axis a block stops
// being worth a rect, and above 4096 the atlas cannot be sized for a sane shape.
static constexpr int ATLAS_MIN_BLOCK = 8;
static constexpr int ATLAS_MAX_BLOCK = 4096;
static constexpr int ATLAS_MAX_RINGS = Terrain3DClipmapAtlas::MAX_RINGS;

static int _atlas_bytes_per_texel(const Image::Format p_format) {
	switch (p_format) {
		case Image::FORMAT_R8:
			return 1;
		case Image::FORMAT_RGBA8:
			return 4;
		case Image::FORMAT_RGBAH:
			return 8;
		default:
			return 4;
	}
}

static RenderingDevice::DataFormat _atlas_data_format(const Image::Format p_format) {
	switch (p_format) {
		case Image::FORMAT_R8:
			return RenderingDevice::DATA_FORMAT_R8_UNORM;
		case Image::FORMAT_RGBA8:
			return RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM;
		case Image::FORMAT_RGBAH:
			return RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT;
		default:
			return RenderingDevice::DATA_FORMAT_R32_SFLOAT;
	}
}

Terrain3DClipmapAtlas::Terrain3DClipmapAtlas(std::unique_ptr<Terrain3DClipmapSource> p_source) :
		_source(std::move(p_source)) {
}

Terrain3DClipmapAtlas::~Terrain3DClipmapAtlas() {
	clear();
}

String Terrain3DClipmapAtlas::get_source_name() const {
	return _source != nullptr ? _source->get_source_name() : String("none");
}

// Every ring is the same 3x3 arrangement of its *own* blocks: the centre plus its eight neighbours.
// The centre is inside the ring below and is kept anyway (see the header), so the count is nine for
// every ring and the shell a ring contributes beyond the one inside it is eight blocks.
int Terrain3DClipmapAtlas::get_ring_block_count(const int p_ring) const {
	if (p_ring < 0 || p_ring >= _config.rings) {
		return 0;
	}
	return 9;
}

int Terrain3DClipmapAtlas::get_block_count() const {
	return 9 * _config.rings;
}

// The world size of one unit's blocks: the *shared ladder's* own unit size (`base_world * 2^unit`),
// which is what makes the atlas's unit `r` serve the same density the LOD ring's unit `r` serves at the
// distance unit `r`'s shell stands at. Unit `r`'s blocks are `block_size` texels of *that* span, so the
// texel count a unit costs is constant and only its reach grows.
real_t Terrain3DClipmapAtlas::_block_world_of_ring(const int p_ring) const {
	return _config.base_world * real_t(int64_t(1) << CLAMP(p_ring, 0, 30));
}

int Terrain3DClipmapAtlas::_texels_of_ring(const int p_ring) const {
	(void)p_ring;
	return MAX(1, _config.block_size);
}

real_t Terrain3DClipmapAtlas::_texel_of_ring(const int p_ring) const {
	return _block_world_of_ring(p_ring) / real_t(_texels_of_ring(p_ring));
}

Vector2 Terrain3DClipmapAtlas::_grid_origin_of_ring(const int p_ring, const Vector2 &p_focus) const {
	const real_t texel = _texel_of_ring(p_ring);
	return Vector2(Math::floor(p_focus.x / texel) * texel, Math::floor(p_focus.y / texel) * texel);
}

// The start point: the centre of the grid's centre block, an exact whole number of blocks from the
// frame origin. `round()` rather than `floor()` so the focus sits inside the centre block rather
// than at its edge, which is what keeps the phase in `[-W/2, W/2)`.
Vector2 Terrain3DClipmapAtlas::_ring_start(const int p_ring, const Vector2 &p_focus) const {
	const Vector2 grid_origin = _grid_origin_of_ring(p_ring, p_focus);
	const real_t block_world = _block_world_of_ring(p_ring);
	return Vector2(Math::round(grid_origin.x / block_world) * block_world,
			Math::round(grid_origin.y / block_world) * block_world);
}

Vector2i Terrain3DClipmapAtlas::_ring_phase(const int p_ring, const Vector2 &p_focus) const {
	const Vector2 grid_origin = _grid_origin_of_ring(p_ring, p_focus);
	const Vector2 start = _ring_start(p_ring, p_focus);
	const real_t texel = _texel_of_ring(p_ring);
	const int texels = _texels_of_ring(p_ring);
	int x = int(Math::round((grid_origin.x - start.x) / texel)) % texels;
	int y = int(Math::round((grid_origin.y - start.y) / texel)) % texels;
	if (x < 0) {
		x += texels;
	}
	if (y < 0) {
		y += texels;
	}
	return Vector2i(x, y);
}

Vector2 Terrain3DClipmapAtlas::get_grid_origin(const int p_ring) const {
	if (p_ring < 0 || p_ring >= _config.rings) {
		return Vector2();
	}
	return _grid_origin_of_ring(p_ring, _last_focus);
}

// The cell's first texel *centre* in world XZ: the block's own square, offset by the ring's phase -
// the content's frame, which is what a source fills from and what a reader's inverse subtracts.
Vector2 Terrain3DClipmapAtlas::get_cell_origin(const int p_cell) const {
	if (p_cell < 0 || p_cell >= int(_cells.size())) {
		return Vector2();
	}
	const Cell &cell = _cells[size_t(p_cell)];
	const Vector2 start = _ring_start(cell.ring, _last_focus);
	const real_t texel = _texel_of_ring(cell.ring);
	const real_t block_world = _block_world_of_ring(cell.ring);
	const Vector2 block(start.x + real_t(cell.gx) * block_world,
			start.y + real_t(cell.gy) * block_world);
	return Vector2(block.x - 0.5f * block_world + 0.5f * texel,
			block.y - 0.5f * block_world + 0.5f * texel);
}

// The matrix array's entry. The start matrix carried to this cell's own block: the linear part is
// the light camera's and the origin is the block's centre put through the same matrix. The block
// size is fixed, so nothing else has to be stored per block.
Transform2D Terrain3DClipmapAtlas::get_cell_matrix(const int p_cell) const {
	if (p_cell < 0 || p_cell >= int(_cells.size())) {
		return Transform2D();
	}
	const Cell &cell = _cells[size_t(p_cell)];
	const Vector2 start = _ring_start(cell.ring, _last_focus);
	const real_t block_world = _block_world_of_ring(cell.ring);
	const Vector2 block(start.x + real_t(cell.gx) * block_world,
			start.y + real_t(cell.gy) * block_world);
	return Transform2D(_config.frame.get_rotation(), _config.frame.get_scale(),
			_config.frame.get_skew(), _config.frame.xform(block));
}

void Terrain3DClipmapAtlas::set_frame(const Transform2D &p_frame) {
	if (_config.frame == p_frame) {
		return;
	}
	_config.frame = p_frame;
	_state_stamp++;
}

// The cell index of a unit's own 3x3 arrangement: unit `r` owns cells `[r * 9, (r + 1) * 9)`, and
// inside it the same `(gy + 1) * 3 + (gx + 1)` the shader's own finder computes. One arithmetic, so the
// CPU's cell table and the shader's cannot disagree about which cell a world point falls in.
int Terrain3DClipmapAtlas::get_cell_index(const int p_ring, const int p_gx, const int p_gy) const {
	if (p_ring < 0 || p_ring >= _config.rings || p_gx < -1 || p_gx > 1 || p_gy < -1 || p_gy > 1) {
		return -1;
	}
	return p_ring * 9 + (p_gy + 1) * 3 + (p_gx + 1);
}

// ---- Layout ------------------------------------------------------------------------------------
//
// Both schemes pack the same multiset of power-of-two squares: the rings' blocks, one spare a ring,
// and the global block. They differ in how a block's size and its ring decide where it goes, and the
// report publishes both with their bounding boxes so "the smallest area" is a comparison.
//
// The width is the one free variable, so each scheme searches it: the packer is run for every
// candidate width from the largest block up to eight times it, and the run with the smallest
// bounding area wins. That search *is* the "how do we place these to occupy the least area" answer.
// ---- The quadtree arrangement -------------------------------------------------------------------
//
// A power-of-two root that is recursively subdivided, with each block placed by descending-size
// insertion into the smallest free node that holds it. This is the arrangement the user asked for
// ("the atlas should look like the quadtree"): same-sized blocks end up clustered in the same subtree,
// a node that has been split is visible as the nested border its children sit in, and the picture is
// one of nested squares rather than of shelf rows.
//
// It is also the arrangement the layer's own structure wants. A unit is a 3x3 arrangement of its own
// blocks, so the whole atlas is a set of equal-sized squares: a recursive allocator places one unit's
// nine blocks in one subtree and the next unit's in the next free node, which is the nesting the
// *world* arrangement has. The shelf packer remains implemented because the task asks for the
// comparison, and `get_layout_report()` publishes every scheme's bounding box and efficiency, so the
// choice is a measurement rather than a preference.
//
// The root is a power-of-two *rectangle* rather than a square only because a square root would waste
// more: a root that holds the content at 62% is better than the smallest square, which halves it.
// Both sides are powers of two, so every split is exact and every rect is placed at a power-of-two
// offset of its own size.
bool Terrain3DClipmapAtlas::_pack_quadtree(const std::vector<PackedItem> &p_items, const int p_width,
		const int p_height, std::vector<Rect2i> &r_rects) const {
	struct Node {
		int x = 0;
		int y = 0;
		int w = 0;
		int h = 0;
	};
	std::vector<Node> free_nodes;
	free_nodes.push_back({ 0, 0, p_width, p_height });
	std::vector<Rect2i> placed;
	placed.reserve(p_items.size());
	for (const PackedItem &item : p_items) {
		const int size = MAX(1, item.size);
		// Best fit over the free nodes: the smallest area that holds the item. A first fit would place
		// a small block in a large free node and split the rest for nothing, which is the fragmentation
		// the recursive allocator exists to avoid.
		int best = -1;
		int64_t best_area = 0;
		for (size_t index = 0; index < free_nodes.size(); index++) {
			const Node &node = free_nodes[index];
			if (node.w < size || node.h < size) {
				continue;
			}
			const int64_t area = int64_t(node.w) * int64_t(node.h);
			if (best < 0 || area < best_area) {
				best = int(index);
				best_area = area;
			}
		}
		if (best < 0) {
			return false;
		}
		Node node = free_nodes[size_t(best)];
		free_nodes.erase(free_nodes.begin() + best);
		// Split along both axes until one quadrant is exactly the item's size. Each split keeps one
		// quadrant and returns the others to the free list, so the tree's subdivision *is* the free
		// list - which is what makes the layout nested rather than row-ordered.
		while (node.w > size || node.h > size) {
			const int w1 = MAX(1, node.w / 2);
			const int h1 = MAX(1, node.h / 2);
			const int w2 = node.w - w1;
			const int h2 = node.h - h1;
			if (node.w > size && w1 >= size) {
				free_nodes.push_back({ node.x, node.y + h1, w1, h2 });
				free_nodes.push_back({ node.x + w1, node.y, w2, node.h });
				node.w = w1;
				node.h = h1;
				continue;
			}
			if (node.h > size && h1 >= size) {
				free_nodes.push_back({ node.x + w1, node.y, w2, h1 });
				free_nodes.push_back({ node.x, node.y + h1, node.w, h2 });
				node.h = h1;
				continue;
			}
			// The remaining extent cannot be halved without losing the item - its short side already
			// fits and its long side is not a whole multiple. Keep it whole.
			break;
		}
		placed.push_back(Rect2i(node.x, node.y, size, size));
	}
	r_rects = std::move(placed);
	return true;
}

void Terrain3DClipmapAtlas::_pack_scheme(const int p_packer, std::vector<PackedItem> &r_items,
		std::vector<Rect2i> &r_rects, int &r_width, int &r_height) const {
	std::vector<PackedItem> items;
	for (int ring = 0; ring < _config.rings; ring++) {
		// Every unit's blocks are the same texel count and only their *world* size grows, so the
		// packing sees a single size class per unit: `block_size` for all of them. The quadtree below
		// therefore places them by the order the units are offered in, not by a size ladder - the
		// "coarse outward" of the picture comes from the units' own nesting in the world, and the
		// texture's nested subdivision comes from the quadtree's own splitting.
		const int size = _texels_of_ring(ring);
		for (int index = 0; index < get_ring_block_count(ring); index++) {
			items.push_back({ size, ring, false, false });
		}
		if (_config.spares) {
			items.push_back({ size, ring, true, false });
		}
	}
	items.push_back({ MAX(1, _config.global_texels), -1, false, true });

	// The shelf sequence. `PACK_SHELF` sorts everything by size, so a row is as even as the ladder
	// allows. `PACK_RING_BANDS` keeps one ring's blocks together, in ring order, which costs area
	// but leaves every row inside one ring.
	if (p_packer == PACK_SHELF) {
		std::sort(items.begin(), items.end(), [](const PackedItem &a, const PackedItem &b) {
			if (a.size != b.size) {
				return a.size > b.size;
			}
			// A ring's own blocks before its spare and before the global block, so a row that is
			// cut short cuts the blocks that are interchangeable rather than the odd ones out.
			return int(a.spare) + int(a.global) * 2 < int(b.spare) + int(b.global) * 2;
		});
	} else {
		std::stable_sort(items.begin(), items.end(), [](const PackedItem &a, const PackedItem &b) {
			if (a.global != b.global) {
				return !a.global;
			}
			if (a.ring != b.ring) {
				return a.ring < b.ring;
			}
			return !a.spare && b.spare;
		});
	}

	int64_t total_area = 0;
	int max_size = 1;
	for (const PackedItem &item : items) {
		total_area += int64_t(item.size) * int64_t(item.size);
		max_size = MAX(max_size, item.size);
	}
	if (p_packer == PACK_QUADTREE) {
		// The root search: powers of two from the largest block up, square and 2:1 both, keeping the
		// smallest area that admits the whole content and the squarer root among equals. The first size
		// that admits anything wins, so the search is one doubling rather than a sweep.
		r_items = items;
		int64_t best_area = 0;
		for (int step = max_size; step <= max_size * 16; step *= 2) {
			const int candidates[3][2] = { { step, step }, { step * 2, step }, { step, step * 2 } };
			for (const auto &candidate : candidates) {
				std::vector<Rect2i> rects;
				if (!_pack_quadtree(items, candidate[0], candidate[1], rects)) {
					continue;
				}
				const int64_t area = int64_t(candidate[0]) * int64_t(candidate[1]);
				const bool better = best_area == 0 || area < best_area ||
						(area == best_area && MAX(candidate[0], candidate[1]) < MAX(r_width, r_height));
				if (better) {
					best_area = area;
					r_width = candidate[0];
					r_height = candidate[1];
					r_rects = std::move(rects);
				}
			}
			if (best_area != 0) {
				break;
			}
		}
		return;
	}
	// The candidate widths: at the largest block, then at each step above it. A step of the largest
	// block is the granularity that matters, because the ladder is made of halves of it.
	const int step = MAX(1, max_size / 4);
	int best_width = max_size;
	int best_height = 0;
	int64_t best_area = 0;
	std::vector<Rect2i> best_rects;
	// The area is the objective, but a bounding box within a few percent of it is an equally good
	// answer and the *squarer* one is a far more usable texture: a 256 x 4256 atlas and a 1088 x 1024
	// one hold the same blocks, and only one of them is a texture a reader can look at. The tie-break
	// is therefore explicit - among the widths whose area is within the tolerance of the best, keep
	// the one whose longer side is shortest - and the report publishes every scheme's numbers so the
	// choice is visible rather than implied.
	constexpr double ATLAS_SQUARE_TOLERANCE = 0.03;
	for (int width = max_size; width <= max_size * 8; width += step) {
		std::vector<Rect2i> rects;
		int x = 0;
		int y = 0;
		int shelf = 0;
		for (const PackedItem &item : items) {
			if (x != 0 && x + item.size > width) {
				y += shelf;
				x = 0;
				shelf = 0;
			}
			rects.push_back(Rect2i(x, y, item.size, item.size));
			x += item.size;
			shelf = MAX(shelf, item.size);
		}
		const int height = y + shelf;
		const int64_t area = int64_t(width) * int64_t(height);
		if (best_rects.empty()) {
			best_area = area;
			best_width = width;
			best_height = height;
			best_rects = std::move(rects);
			continue;
		}
		const bool strictly_better = area < best_area;
		const bool square_better = double(area) <= double(best_area) * (1.0 + ATLAS_SQUARE_TOLERANCE) &&
				MAX(width, height) < MAX(best_width, best_height);
		if (strictly_better || square_better) {
			best_area = area;
			best_width = width;
			best_height = height;
			best_rects = std::move(rects);
		}
	}
	r_items = items;
	r_rects = std::move(best_rects);
	r_width = best_width;
	r_height = best_height;
}

void Terrain3DClipmapAtlas::_build_layout() {
	// Every scheme is measured; the *chosen* one is what the settings ask for (the quadtree by
	// default), because the arrangement is a form requirement and the report is what makes the cost of
	// that form a number rather than a claim. A scheme that cannot place the content at all is skipped,
	// and the smallest-area usable scheme is the fallback, so an atlas always has a layout.
	std::vector<Rect2i> scheme_rects[PACK_COUNT];
	std::vector<PackedItem> scheme_items[PACK_COUNT];
	int64_t best_area = 0;
	int best_index = -1;
	for (int packer = 0; packer < PACK_COUNT; packer++) {
		int width = 0;
		int height = 0;
		_pack_scheme(packer, scheme_items[packer], scheme_rects[packer], width, height);
		int64_t packed = 0;
		for (const Rect2i &rect : scheme_rects[packer]) {
			packed += int64_t(rect.size.x) * int64_t(rect.size.y);
		}
		_schemes[packer].name = packer == PACK_SHELF
				? "shelf"
				: (packer == PACK_RING_BANDS ? "ring_bands" : "quadtree");
		_schemes[packer].width = width;
		_schemes[packer].height = height;
		_schemes[packer].area = int64_t(width) * int64_t(height);
		_schemes[packer].efficiency = _schemes[packer].area > 0
				? double(packed) / double(_schemes[packer].area)
				: 0.0;
		_schemes[packer].chosen = false;
		if (scheme_rects[packer].empty() || _schemes[packer].area <= 0) {
			continue;
		}
		if (best_index < 0 || _schemes[packer].area < best_area) {
			best_area = _schemes[packer].area;
			best_index = packer;
		}
	}
	const int wanted = CLAMP(int(_config.packer), 0, PACK_COUNT - 1);
	const int pick = !scheme_rects[wanted].empty() ? wanted : best_index;
	if (pick < 0) {
		LOG(ERROR, "Clipmap atlas could not lay out any block; the atlas stays empty (", get_source_name(), ")");
		_layout = LayoutScheme();
		_packed.clear();
		_items.clear();
		return;
	}
	_layout = _schemes[pick];
	_packed = scheme_rects[pick];
	_items = scheme_items[pick];
	// Round the bounding box up to the *smallest* block so every rect stays inside the texture, and
	// then round the area the report publishes with it. The alignment is the smallest block and not
	// the largest: a rect is placed at a power-of-two offset of its own size, so nothing needs more
	// than the ladder's finest step. The quadtree's root is already exact - both its sides are powers
	// of two and every rect is placed at a multiple of its own size - so it needs no pass at all.
	if (pick != PACK_QUADTREE) {
		const int align = MAX(1, _texels_of_ring(_config.rings - 1));
		_layout.width = ((_layout.width + align - 1) / align) * align;
		_layout.height = ((_layout.height + align - 1) / align) * align;
		_layout.area = int64_t(_layout.width) * int64_t(_layout.height);
	}
	for (int packer = 0; packer < PACK_COUNT; packer++) {
		_schemes[packer].chosen = packer == pick;
		if (packer == pick) {
			_schemes[packer] = _layout;
			_schemes[packer].chosen = true;
		}
	}
}
void Terrain3DClipmapAtlas::_assign_slots(const std::vector<PackedItem> &p_items,
		const std::vector<Rect2i> &p_rects) {
	_slots.clear();
	_spare_slots.clear();
	const size_t count = MIN(p_items.size(), p_rects.size());
	for (size_t index = 0; index < count; index++) {
		Slot slot;
		slot.rect = p_rects[index];
		slot.ring = p_items[index].ring;
		slot.texels = p_items[index].size;
		slot.spare = p_items[index].spare;
		slot.global = p_items[index].global;
		if (slot.spare) {
			_spare_slots.push_back(int(_slots.size()));
		}
		_slots.push_back(slot);
	}
	if (!_spare_slots.empty()) {
		// A spare is a real slot of its ring, so a replacement can be produced into it before the
		// block it replaces is released. Nothing else to do here: the slot table is complete.
	}
}

void Terrain3DClipmapAtlas::_rebuild_cells() {
	_cells.clear();
	_cells.reserve(size_t(_config.rings) * 9u);
	// Unit `r` is a 3x3 arrangement of *its own* blocks, centred on its own snapped start point: the
	// centre cell plus the eight neighbours. The centre of unit `r` is covered by unit `r - 1`'s square
	// (which is why the finder walks finest first), so the arrangement is a shell with a hole - the
	// nesting the user asked for, and the reason a unit's reach is its own 3x3 and not the whole grid.
	for (int ring = 0; ring < _config.rings; ring++) {
		for (int gy = -1; gy <= 1; gy++) {
			for (int gx = -1; gx <= 1; gx++) {
				Cell cell;
				cell.gx = gx;
				cell.gy = gy;
				cell.chebyshev = MAX(Math::abs(gx), Math::abs(gy));
				cell.ring = ring;
				_cells.push_back(cell);
			}
		}
	}
}

void Terrain3DClipmapAtlas::configure(const Config &p_config) {
	Config config = p_config;
	config.block_size = CLAMP(config.block_size, ATLAS_MIN_BLOCK, ATLAS_MAX_BLOCK);
	// The ring ceiling is a table size, not a preference, and it is above the shipping ladder's eleven
	// units: a request that hit it is reported rather than answered with a shorter 1024 -> 1 span.
	const int requested_rings = config.rings;
	config.rings = CLAMP(config.rings, 1, ATLAS_MAX_RINGS);
	if (requested_rings != config.rings) {
		LOG(WARN, "Clipmap atlas rings ", requested_rings, " clamped to ", config.rings, " of ",
				ATLAS_MAX_RINGS, " (", get_source_name(), ")");
	}
	config.base_world = MAX(real_t(0.001), config.base_world);
	config.channels = CLAMP(config.channels, 1, MAX_CHANNELS);
	if (config.format != Image::FORMAT_RF && config.format != Image::FORMAT_R8) {
		LOG(ERROR, "Clipmap atlas format ", int(config.format), " has no publish path; using RF");
		config.format = Image::FORMAT_RF;
	}
	config.global_texels = CLAMP(config.global_texels, 1, config.block_size);
	config.blocks_per_frame = CLAMP(config.blocks_per_frame, 1, 64);
	if (config.global_world <= 0.f) {
		// The global block covers what the grid does not: the coarsest unit's own 3x3 square, grown so
		// the fragment has a minimal-resolution answer well past it. It is produced once and sampled by
		// a reader that is outside every unit's arrangement.
		const real_t grid_reach = 1.5f * config.base_world *
				real_t(int64_t(1) << CLAMP(config.rings - 1, 0, 30));
		config.global_world = grid_reach * 4.f;
	}
	if (!_cells.empty() && config.block_size == _config.block_size && config.rings == _config.rings &&
			config.channels == _config.channels && config.format == _config.format &&
			Math::is_equal_approx(config.base_world, _config.base_world) &&
			config.global_texels == _config.global_texels &&
			Math::is_equal_approx(config.global_world, _config.global_world) &&
			config.spares == _config.spares && config.blocks_per_frame == _config.blocks_per_frame) {
		return;
	}
	LOG(INFO, "Configuring clipmap atlas (", get_source_name(), "): block ", config.block_size,
			" texels, ", config.rings, " rings, ", config.channels, " channels, block world ",
			config.base_world, " m");
	_config = config;
	_global_world = config.global_world;
	_build_layout();
	_assign_slots(_items, _packed);
	_rebuild_cells();
	_ring_step.assign(size_t(config.rings), Vector2i(INT64_MIN, INT64_MIN));
	_ring_origin.assign(size_t(config.rings), Vector2());
	_ring_phase_value.assign(size_t(config.rings), Vector2i());
	_block_values.assign(size_t(config.block_size) * size_t(config.block_size), 0.f);
	_row_values.assign(size_t(config.block_size) + 1, 0.f);
	_jobs.clear();
	_bake_rects.clear();
	_timeline.clear();
	_free_textures();
	_texture_layers = MAX(config.channels, 2);
	_ensure_texture();
	_global_produced = false;
	_global_origin = Vector2();
	_has_focus = false;
	_last_focus = Vector2();
	_grid_step = Vector2i();
	_shape_serial++;
	_state_stamp++;
}

void Terrain3DClipmapAtlas::clear() {
	_cells.clear();
	_slots.clear();
	_spare_slots.clear();
	_jobs.clear();
	_packed.clear();
	_items.clear();
	_bake_rects.clear();
	_timeline.clear();
	_block_values.clear();
	_row_values.clear();
	_ring_step.clear();
	_ring_origin.clear();
	_ring_phase_value.clear();
	_free_textures();
	_global_produced = false;
	_config.block_size = 0;
	_config.rings = 0;
	_has_focus = false;
	_last_focus = Vector2();
	_shape_serial++;
	_state_stamp++;
}

// ---- Texture -----------------------------------------------------------------------------------

void Terrain3DClipmapAtlas::_free_textures() {
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	for (const RID &rid : _staging_rd) {
		if (rid.is_valid() && rd != nullptr) {
			rd->free_rid(rid);
		}
	}
	_staging_rd.clear();
	if (_texture_rid.is_valid() && server != nullptr) {
		server->free_rid(_texture_rid);
	}
	if (_texture_rd.is_valid() && rd != nullptr) {
		rd->free_rid(_texture_rd);
	}
	_texture_rid = RID();
	_texture_rd = RID();
	_free_baked();
}

// The atlas is one `Texture2DArray` of `channels` layers, each layer a whole 2D atlas for one value
// of a texel. Two layers are allocated whatever the channel count: the renderer refuses to wrap a
// one-layer array as a layered texture (`texture_rd_create()` fails on `array_layers == 1`), and one
// unused layer of one value is cheaper than a second publish path for a one-channel group.
//
// `CAN_COPY_TO` is the flag the whole organisation rests on: it is what lets a block rect be written
// by `texture_copy()` out of a block-sized staging texture, so the transfer is one block and not the
// atlas - which is exactly the whole-layer cost this mechanism exists to remove.
void Terrain3DClipmapAtlas::_ensure_texture() {
	if (_texture_rd.is_valid() || _layout.width <= 0 || !is_configured()) {
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	if (rd == nullptr) {
		return;
	}
	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
	format->set_format(_atlas_data_format(_config.format));
	format->set_width(uint32_t(_layout.width));
	format->set_height(uint32_t(_layout.height));
	format->set_depth(1);
	format->set_array_layers(uint32_t(_texture_layers));
	format->set_mipmaps(1);
	format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	TypedArray<PackedByteArray> initial;
	_texture_rd = rd->texture_create(format, view, initial);
	if (!_texture_rd.is_valid()) {
		LOG(ERROR, "Could not allocate clipmap atlas (", get_source_name(), ")");
		_free_textures();
		return;
	}
	rd->set_resource_name(_texture_rd, "Terrain3D Clipmap atlas " + get_source_name());
	_texture_rid = server->texture_rd_create(_texture_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
	if (!_texture_rid.is_valid()) {
		LOG(ERROR, "Could not wrap clipmap atlas (", get_source_name(), ")");
		_free_textures();
		return;
	}
	_ensure_staging();
	// The baked arrays the material arm samples are sized by the same layout, so they are allocated
	// where the layout is known: a device that appears after `configure()` gets them here.
	_ensure_baked();
}

// One staging texture per (ring, channel), each exactly that ring's block size: `texture_update()`
// demands a whole layer's worth of bytes, so a staging texture that matched the largest block would
// make a 32-texel block cost a 256-texel transfer - the very cost this organisation removes.
void Terrain3DClipmapAtlas::_ensure_staging() {
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	if (rd == nullptr || _config.rings <= 0) {
		return;
	}
	const size_t wanted = size_t(_config.rings) * size_t(_config.channels) + size_t(_config.channels);
	if (_staging_rd.size() == wanted && !_staging_rd.empty() && _staging_rd[0].is_valid()) {
		return;
	}
	for (const RID &rid : _staging_rd) {
		if (rid.is_valid()) {
			rd->free_rid(rid);
		}
	}
	_staging_rd.clear();
	// One entry per (ring, channel), then one per channel for the global block: the global block is
	// its own size, and a staging texture that matched a ring's would make the one-time upload a
	// mismatch rather than a transfer.
	for (int ring = 0; ring < _config.rings; ring++) {
		for (int channel = 0; channel < _config.channels; channel++) {
			_staging_rd.push_back(_create_staging(_texels_of_ring(ring)));
		}
	}
	for (int channel = 0; channel < _config.channels; channel++) {
		_staging_rd.push_back(_create_staging(MAX(1, _config.global_texels)));
	}
}

// One block-sized staging texture. `texture_update()` demands a whole layer's worth of bytes, so its
// size is what makes a transfer the block's own bytes.
RID Terrain3DClipmapAtlas::_create_staging(const int p_texels) {
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	if (rd == nullptr) {
		return RID();
	}
	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
	format->set_format(_atlas_data_format(_config.format));
	format->set_width(uint32_t(p_texels));
	format->set_height(uint32_t(p_texels));
	format->set_depth(1);
	format->set_array_layers(1);
	format->set_mipmaps(1);
	format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	TypedArray<PackedByteArray> initial;
	RID staging = rd->texture_create(format, view, initial);
	if (!staging.is_valid()) {
		LOG(ERROR, "Could not allocate clipmap atlas staging (", get_source_name(), ")");
	}
	return staging;
}

// ---- The baked arrays --------------------------------------------------------------------------
//
// The three material arrays a producer writes out of a block's source texels, sized to the whole
// atlas so a block's output is a *rect* of one array rather than a layer: the producer dispatches
// one rect per block, exactly the way it dispatches one rect per ring level. The source landing is
// what makes a block readable; the producer's dispatch is what makes it a material, and a slot whose
// bake has not landed reports `baked` false so the arm falls back instead of sampling a rect no
// dispatch has written.
//
// The array has at least two layers whatever the channel count, for the same reason the ring's does:
// the renderer refuses to wrap a one-layer array as a layered texture, and the arm samples these as
// an array. Only layer 0 is ever written or read; the second is the wrapper's price.
void Terrain3DClipmapAtlas::_ensure_baked() {
	if (get_baked_channel_count() <= 0 || _layout.width <= 0 || _layout.height <= 0 || !is_configured()) {
		return;
	}
	if (!_baked_rd.empty() && _baked_rd[0].is_valid()) {
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	if (rd == nullptr) {
		// No device yet: `_ensure_texture()` calls this again on the first publish, which is the
		// first moment a device is certain.
		return;
	}
	_free_baked();
	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
	format->set_format(RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT);
	format->set_width(uint32_t(_layout.width));
	format->set_height(uint32_t(_layout.height));
	format->set_depth(1);
	format->set_array_layers(2);
	format->set_mipmaps(1);
	// Storage, so a producer writes a rect; sampling, so the arm reads it; update, because the
	// producer's pass is issued against the same texture the material binds.
	format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_STORAGE_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	TypedArray<PackedByteArray> initial;
	for (int channel = 0; channel < get_baked_channel_count(); channel++) {
		RID device = rd->texture_create(format, view, initial);
		RID shader = device.is_valid()
				? server->texture_rd_create(device, RenderingServer::TEXTURE_LAYERED_2D_ARRAY)
				: RID();
		if (!shader.is_valid()) {
			if (device.is_valid()) {
				rd->free_rid(device);
			}
			LOG(ERROR, "Could not allocate clipmap atlas baked channel ", channel, " (", get_source_name(), ")");
			_free_baked();
			return;
		}
		rd->set_resource_name(device, "Terrain3D Clipmap atlas " + get_source_name() + " baked " +
						String::num_int64(channel));
		_baked_rd.push_back(device);
		_baked_rs.push_back(shader);
	}
}

void Terrain3DClipmapAtlas::_free_baked() {
	if (_baked_rd.empty() && _baked_rs.empty()) {
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	for (const RID &rid : _baked_rs) {
		if (rid.is_valid() && server != nullptr) {
			server->free_rid(rid);
		}
	}
	for (const RID &rid : _baked_rd) {
		if (rid.is_valid() && rd != nullptr) {
			rd->free_rid(rid);
		}
	}
	_baked_rd.clear();
	_baked_rs.clear();
}

RID Terrain3DClipmapAtlas::get_baked_device_rid(const int p_channel) const {
	if (p_channel < 0 || p_channel >= int(_baked_rd.size())) {
		return RID();
	}
	return _baked_rd[size_t(p_channel)];
}

RID Terrain3DClipmapAtlas::get_baked_texture_rid(const int p_channel) const {
	if (p_channel < 0 || p_channel >= int(_baked_rs.size())) {
		return RID();
	}
	return _baked_rs[size_t(p_channel)];
}

// The block's world square origin: the corner before the first texel's centre, which is what the
// producer's job carries as its policy origin. `get_slot_texel_world()` is the ring's own texel, so
// the two numbers together are the whole of the affine map from a content index to a world position.
Vector2 Terrain3DClipmapAtlas::get_slot_block_origin(const int p_slot) const {
	if (p_slot < 0 || p_slot >= int(_slots.size())) {
		return Vector2();
	}
	const Slot &slot = _slots[size_t(p_slot)];
	const real_t block_world = _block_world_of_ring(slot.ring);
	return Vector2(real_t(slot.block_x) * block_world - 0.5f * block_world,
			real_t(slot.block_y) * block_world - 0.5f * block_world);
}

real_t Terrain3DClipmapAtlas::get_slot_texel_world(const int p_slot) const {
	if (p_slot < 0 || p_slot >= int(_slots.size())) {
		return 1.f;
	}
	return _texel_of_ring(_slots[size_t(p_slot)].ring);
}

// One block produced: queue its baked rect and stop claiming it is baked. A block re-produced into
// the same slot (an invalidation) queues a second rect, and the previous dispatch's acknowledgment is
// then refused by the serial below - the content the first bake read is gone.
void Terrain3DClipmapAtlas::_queue_bake(const int p_slot) {
	if (get_baked_channel_count() <= 0 || p_slot < 0 || p_slot >= int(_slots.size())) {
		return;
	}
	Slot &slot = _slots[size_t(p_slot)];
	slot.baked = false;
	// A slot's bake queue holds at most its *latest* production: an older rect describes content the
	// slot no longer holds, so a dispatch of it could only be refused, and leaving it queued would
	// keep `pending_bake_rects` from ever reaching zero.
	for (size_t index = 0; index < _bake_rects.size();) {
		if (_bake_rects[index].unit == p_slot) {
			_bake_rects.erase(_bake_rects.begin() + ptrdiff_t(index));
			continue;
		}
		index++;
	}
	// The **shared** queue entry: `unit` is this slot, `lease` the slot's serial. The ring/texel/block
	// numbers the producer also needs are read back off the slot it names (`get_slot_ring()`,
	// `get_slot_texels()`, `get_slot_block_origin()`), so one producer queue serves both
	// implementations instead of one shape per storage layout.
	BakeRect rect;
	rect.unit = p_slot;
	rect.x0 = slot.rect.position.x;
	rect.y0 = slot.rect.position.y;
	rect.x1 = slot.rect.position.x + slot.rect.size.x;
	rect.y1 = slot.rect.position.y + slot.rect.size.y;
	rect.lease = slot.serial;
	_bake_rects.push_back(rect);
}

bool Terrain3DClipmapAtlas::acknowledge_bake(const TerrainClipmap::BakeRect &p_rect) {
	const int p_slot = p_rect.unit;
	const uint64_t p_serial = p_rect.lease;
	if (p_slot < 0 || p_slot >= int(_slots.size())) {
		return false;
	}
	Slot &slot = _slots[size_t(p_slot)];
	// The slot has been reused since the rect was taken: the dispatch read content the slot no
	// longer holds, so its acknowledgment describes nothing the atlas serves now. Any rect still
	// queued for the slot up to this serial is stale for the same reason and is dropped.
	if (slot.serial != p_serial) {
		for (size_t index = 0; index < _bake_rects.size();) {
			const BakeRect &rect = _bake_rects[index];
			if (rect.unit == p_slot && rect.lease <= p_serial) {
				_bake_rects.erase(_bake_rects.begin() + ptrdiff_t(index));
				continue;
			}
			index++;
		}
		return false;
	}
	slot.baked = true;
	for (size_t index = 0; index < _bake_rects.size();) {
		const BakeRect &rect = _bake_rects[index];
		if (rect.unit == p_slot && rect.lease == p_serial) {
			_bake_rects.erase(_bake_rects.begin() + ptrdiff_t(index));
			continue;
		}
		index++;
	}
	_state_stamp++;
	return true;
}

// One block's rect, one channel at a time: a block-sized `texture_update()` into the ring's staging
// texture, then a `texture_copy()` of exactly that rect into the atlas layer. The byte counter sees
// the block's own bytes and nothing else.
void Terrain3DClipmapAtlas::_upload_rect(const int p_staging, const Rect2i &p_rect, const int p_texels,
		const int p_channel, const std::vector<float> &p_values) {
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	if (rd == nullptr || !_texture_rd.is_valid() || p_staging < 0 || p_texels <= 0) {
		return;
	}
	if (p_staging >= int(_staging_rd.size())) {
		return;
	}
	const int bytes_per_texel = _atlas_bytes_per_texel(_config.format);
	PackedByteArray bytes;
	bytes.resize(int64_t(p_texels) * int64_t(p_texels) * int64_t(bytes_per_texel));
	uint8_t *dst = bytes.ptrw();
	if (_config.format == Image::FORMAT_RF) {
		float *values = reinterpret_cast<float *>(dst);
		for (int64_t index = 0; index < int64_t(p_texels) * int64_t(p_texels); index++) {
			values[index] = p_values[size_t(index)];
		}
	} else {
		for (int64_t index = 0; index < int64_t(p_texels) * int64_t(p_texels); index++) {
			const float value = p_values[size_t(index)];
			dst[index] = uint8_t(CLAMP(value, 0.f, 1.f) * 255.f + 0.5f);
		}
	}
	if (rd->texture_update(_staging_rd[size_t(p_staging)], 0, bytes) != OK) {
		LOG(WARN, "Clipmap atlas staging update failed (", get_source_name(), ")");
		return;
	}
	if (rd->texture_copy(_staging_rd[size_t(p_staging)], _texture_rd,
				Vector3(0, 0, 0), Vector3(p_rect.position.x, p_rect.position.y, 0),
				Vector3(p_texels, p_texels, 1), 0, 0, 0, CLAMP(p_channel, 0, _texture_layers - 1)) != OK) {
		LOG(WARN, "Clipmap atlas block copy failed (", get_source_name(), ")");
		return;
	}
	_upload_bytes += uint64_t(p_texels) * uint64_t(p_texels) * uint64_t(bytes_per_texel);
	_block_uploads++;
}

// ---- Production --------------------------------------------------------------------------------

void Terrain3DClipmapAtlas::_fill_job_row(const Job &p_job, const int p_channel, const int p_y,
		const int p_x0, const int p_x1) {
	if (_source == nullptr) {
		return;
	}
	const Slot &slot = _slots[size_t(p_job.slot)];
	Terrain3DClipmapSource::Row row;
	row.level = p_job.ring;
	row.channel = p_channel;
	row.y = p_y;
	row.x0 = p_x0;
	row.x1 = p_x1;
	row.size = slot.texels;
	row.texel_world = _texel_of_ring(p_job.ring);
	// The block's own world origin: its square is `[b*W - W/2, b*W + W/2)`, so the first texel's
	// centre is half a texel inside it. A block's content is a function of the world position, which
	// is what lets a slot move between cells without being re-produced.
	const real_t job_block_world = _block_world_of_ring(p_job.ring);
	row.origin = Vector2(real_t(p_job.block_x) * job_block_world - 0.5f * job_block_world +
						 0.5f * row.texel_world,
			real_t(p_job.block_y) * job_block_world - 0.5f * job_block_world +
					0.5f * row.texel_world);
	_source->fill_row(row, _row_values.data());
	for (int x = p_x0; x < p_x1; x++) {
		_block_values[size_t(p_y) * size_t(slot.texels) + size_t(x)] = _row_values[size_t(x)];
	}
}

// A block is produced *whole*: it is the unit of work rather than a fraction of one, which is what
// makes "a frame loads a block" the mechanism's own shape rather than a budget's side effect.
bool Terrain3DClipmapAtlas::_produce_job(Job &p_job) {
	const Slot &slot = _slots[size_t(p_job.slot)];
	const int texels = slot.texels;
	for (int channel = 0; channel < _config.channels; channel++) {
		for (int y = 0; y < texels; y++) {
			_fill_job_row(p_job, channel, y, 0, texels);
			_produced_texels += uint64_t(texels);
		}
		_upload_rect(p_job.ring * _config.channels + channel, slot.rect, texels, channel, _block_values);
	}
	p_job.cursor_row = texels;
	return true;
}

// The global block: one minimal-resolution square covering everything outside the grid, produced
// once. "One-time loaded" is literal here - the upload counter moves for it exactly once.
void Terrain3DClipmapAtlas::_publish_global() {
	if (_source == nullptr || _global_produced) {
		return;
	}
	const int texels = MAX(1, _config.global_texels);
	const real_t texel_world = _global_world / real_t(texels);
	std::vector<float> values(size_t(texels) * size_t(texels), 0.f);
	for (int channel = 0; channel < _config.channels; channel++) {
		for (int y = 0; y < texels; y++) {
			Terrain3DClipmapSource::Row row;
			row.level = _config.rings;
			row.channel = channel;
			row.y = y;
			row.x0 = 0;
			row.x1 = texels;
			row.size = texels;
			row.texel_world = texel_world;
			row.origin = _global_origin - Vector2(_global_world, _global_world) * 0.5f +
					Vector2(0.5f * texel_world, 0.5f * texel_world);
			_source->fill_row(row, _row_values.data());
			for (int x = 0; x < texels; x++) {
				values[size_t(y) * size_t(texels) + size_t(x)] = _row_values[size_t(x)];
			}
		}
		// The global rect is the layout's own; it goes out through the staging textures the global
		// block's own size reserved, which is why the one-time upload costs its own bytes too.
		_upload_rect(_config.rings * _config.channels + channel, _global_rect, texels, channel, values);
		_produced_texels += uint64_t(texels) * uint64_t(texels);
	}
	_global_produced = true;
	_state_stamp++;
}

// ---- Rolling -----------------------------------------------------------------------------------

int Terrain3DClipmapAtlas::_slot_owner(const int p_slot, const bool p_include_pending) const {
	for (size_t index = 0; index < _cells.size(); index++) {
		if (_cells[index].slot == p_slot) {
			return int(index);
		}
		if (p_include_pending && _cells[index].pending_slot == p_slot) {
			return int(index);
		}
	}
	return -1;
}

int Terrain3DClipmapAtlas::_find_slot(const int p_ring, const int64_t p_block_x, const int64_t p_block_y) const {
	for (size_t index = 0; index < _slots.size(); index++) {
		const Slot &slot = _slots[index];
		if (slot.global || slot.ring != p_ring || !slot.resident) {
			continue;
		}
		if (slot.block_x == p_block_x && slot.block_y == p_block_y) {
			return int(index);
		}
	}
	return -1;
}

// A slot of the right ring that no cell claims. The spares are the reason a replacement can be
// started *before* the block it replaces is released - the arrangement the user asked for, and the
// one that has no frame in which a cell holds nothing.
int Terrain3DClipmapAtlas::_take_free_slot(const int p_ring) {
	for (size_t index = 0; index < _slots.size(); index++) {
		Slot &slot = _slots[index];
		if (slot.global || slot.ring != p_ring || slot.spare) {
			continue;
		}
		if (_slot_owner(int(index), true) < 0) {
			slot.resident = false;
			slot.baked = false;
			return int(index);
		}
	}
	for (const int spare : _spare_slots) {
		if (_slots[size_t(spare)].ring != p_ring) {
			continue;
		}
		if (_slot_owner(spare, true) < 0) {
			_slots[size_t(spare)].resident = false;
			_slots[size_t(spare)].baked = false;
			return spare;
		}
	}
	return -1;
}

void Terrain3DClipmapAtlas::_queue_block(const int p_cell, const int p_slot) {
	Cell &cell = _cells[size_t(p_cell)];
	Job job(p_slot, cell.ring, cell.want_x, cell.want_y, cell.offset.x);
	_jobs.push_back(job);
	cell.pending_slot = p_slot;
	cell.current = false;
}

// The relabelling of one ring. Every cell of the ring wants the block its neighbour inward held, so
// a slot that already holds that coordinate is *reassigned* rather than re-produced; only the row
// and column that entered at the edge have no predecessor, and those are the jobs. That is the
// whole of "only the edge data reloads", and the counters below are its evidence.
void Terrain3DClipmapAtlas::_relabel_ring(const int p_ring, const bool p_first) {
	const Vector2 start = _ring_start(p_ring, _last_focus);
	const real_t block_world = _block_world_of_ring(p_ring);
	const int64_t m_x = int64_t(Math::round(start.x / block_world));
	const int64_t m_y = int64_t(Math::round(start.y / block_world));
	const int texels = _texels_of_ring(p_ring);
	const Vector2i phase = _ring_phase(p_ring, _last_focus);
	for (Cell &cell : _cells) {
		if (cell.ring != p_ring) {
			continue;
		}
		cell.want_x = m_x + cell.gx;
		cell.want_y = m_y + cell.gy;
		cell.offset = phase;
		// The cell has not been re-established against the new coordinates yet. Clearing it here is
		// what makes the three passes below a *derivation* of which cells still hold what they want
		// rather than an update that can leave a cell pointing at the block of a coordinate it no
		// longer covers. Nothing catches that afterwards: the cell would read a rect that holds a
		// different world block, which is exactly the stale-content failure a relabelling must not
		// have - and the slot keeps its content across it, which is the whole point of the ordering.
		cell.current = false;
	}
	// Pass one: a cell whose own slot already holds what it wants keeps it. This is what a phase
	// turn inside a block looks like - the content does not move, only the ring's phase does.
	uint64_t retained = 0;
	for (Cell &cell : _cells) {
		if (cell.ring != p_ring || cell.pending_slot >= 0 || cell.slot < 0) {
			continue;
		}
		const Slot &slot = _slots[size_t(cell.slot)];
		if (slot.ring == p_ring && slot.resident && slot.block_x == cell.want_x && slot.block_y == cell.want_y) {
			cell.have_x = cell.want_x;
			cell.have_y = cell.want_y;
			cell.current = true;
			retained++;
		}
	}
	// Pass two: the coordinate moved between cells. The slot that holds it is reassigned, which is
	// the whole of what rolling costs for the 64 blocks that did not enter at the edge. Ownership is
	// deliberately not consulted: a block's content *is* its coordinate, so handing cell `(i,j)` the
	// slot that held cell `(i-1,j)`'s block is the relabelling, not a conflict - and two cells of one
	// ring never want the same coordinate, so each slot goes to exactly one cell.
	for (Cell &cell : _cells) {
		if (cell.ring != p_ring || cell.pending_slot >= 0 || cell.current) {
			continue;
		}
		const int found = _find_slot(p_ring, cell.want_x, cell.want_y);
		if (found < 0) {
			continue;
		}
		cell.slot = found;
		cell.have_x = cell.want_x;
		cell.have_y = cell.want_y;
		cell.current = true;
		cell.pending_slot = -1;
		retained++;
	}
	// Pass three is not here: allocating a slot and queuing a block belongs to `_reconcile_cells()`,
	// which runs on *every* update rather than only on the one that relabelled. A relabelling that
	// entered more blocks than the atlas has free slots - which is the normal case, because a shell is
	// one block thick and a scroll replaces most of it - would otherwise strand the cells it could not
	// place until the *next* grid step, which may be a block away. The progressive recycling is what
	// makes the per-frame bound a bound rather than a stall.
	_last_scroll_retained += retained;
	if (!p_first) {
		_interior_blocks_retained += retained;
	}
}

// Every cell that is neither serving a block nor waiting for one asks for a free slot. Slots become
// free as replacements land - the block a cell stopped pointing at is released the moment it flips -
// so a relabelling drains over a few updates at exactly `blocks_per_frame` a frame, and no cell is
// ever left with nothing to read: it keeps its old slot, marked not current, until the new one lands.
void Terrain3DClipmapAtlas::_reconcile_cells() {
	uint64_t loaded = 0;
	// The dependency order, and it is the ring's own rule with the atlas's structure: **finest ring
	// first**, so the ground under the camera is the first to be right, and the coarse shells - whose
	// blocks are the small ones - fill afterwards while the fragment falls back to the one-time global
	// block. The alternative, coarsest first, would make the near field the *last* thing to arrive,
	// which is the opposite of what the mechanism is for. Rings are walked in order and each ring's
	// cells in index order, so the sequence is deterministic and the timeline is readable.
	for (int ring = 0; ring < _config.rings; ring++) {
		for (Cell &cell : _cells) {
			if (cell.ring != ring || cell.current || cell.pending_slot >= 0) {
				continue;
			}
			// A block another cell of the same ring is already waiting for is shared rather than
			// loaded twice: one block is one coordinate, and the second cell flips to it when it lands.
			bool shared = false;
			for (const Job &job : _jobs) {
				if (job.ring == cell.ring && job.block_x == cell.want_x && job.block_y == cell.want_y) {
					cell.pending_slot = job.slot;
					shared = true;
					break;
				}
			}
			if (shared) {
				continue;
			}
			const int slot = _take_free_slot(cell.ring);
			if (slot < 0) {
				continue;
			}
			_queue_block(get_cell_index(cell.ring, cell.gx, cell.gy), slot);
			loaded++;
		}
	}
	if (loaded > 0) {
		_last_scroll_loaded += loaded;
		_edge_blocks_loaded += loaded;
	}
}

int Terrain3DClipmapAtlas::update(const Vector2 &p_focus, const int p_budget_texels) {
	_update_calls++;
	_frame_counter++;
	if (!is_configured() || _source == nullptr) {
		return 0;
	}
	_ensure_texture();
	_last_focus = p_focus;
	// A ring whose start point moved by a whole block relabels; a ring whose start point did not is
	// a phase turn and costs one uniform rebind. The two are told apart by the block step, which is
	// what the user's "9x9 blocks have their own ordering index" is for.
	const bool first = !_has_focus;
	bool relabelled = false;
	for (int ring = 0; ring < _config.rings; ring++) {
		_ring_origin[size_t(ring)] = _ring_start(ring, p_focus);
		_ring_phase_value[size_t(ring)] = _ring_phase(ring, p_focus);
		// The step is in the unit's *own* blocks: a unit whose blocks are `base_world * 2^r` metres
		// relabels when the focus crosses one of them, so the fine units follow the camera closely and
		// the coarse ones hardly ever move - which is the whole reason a shell only ever reloads its
		// edge.
		const real_t block_world = _block_world_of_ring(ring);
		const Vector2i step(int64_t(Math::round(_ring_origin[size_t(ring)].x / block_world)),
				int64_t(Math::round(_ring_origin[size_t(ring)].y / block_world)));
		if (_ring_step[size_t(ring)] != step || first) {
			// A new scroll starts its own count: `last_scroll_loaded` is what *this* grid step cost,
			// and the recycled blocks the updates after it queue are added to it. The reset is here,
			// before the first ring relabels, because the relabelling is what produces the retained
			// half of the count - zeroing afterwards would erase it.
			if (!relabelled) {
				_last_scroll_loaded = 0;
				_last_scroll_retained = 0;
			}
			_ring_step[size_t(ring)] = step;
			_grid_step = step;
			_relabel_ring(ring, first);
			relabelled = true;
		}
	}
	_has_focus = true;
	_state_stamp++;
	if (first) {
		// The global block is a one-time resource centred on the first focus, which is the only
		// moment its extent can be chosen without a second upload.
		_global_origin = _ring_origin[0];
		_publish_global();
	}
	if (relabelled && !first) {
		_scroll_events++;
	}
	// The progressive recycling runs every update, so a relabelling that entered more blocks than the
	// atlas had free slots finishes over the next few updates instead of stranding those cells.
	_reconcile_cells();
	if (_jobs.empty()) {
		_idle_updates++;
		return 0;
	}
	// One block a frame by default. The queue is drained from the front and a block is produced
	// whole, so the per-frame timeline is one row per update.
	int produced = 0;
	int drained = 0;
	const int limit = MAX(1, _config.blocks_per_frame);
	while (!_jobs.empty() && drained < limit) {
		Job job = _jobs.front();
		_jobs.erase(_jobs.begin());
		const uint64_t before = _produced_texels;
		if (!_produce_job(job)) {
			_jobs.insert(_jobs.begin(), job);
			break;
		}
		produced += int(_produced_texels - before);
		drained++;
		// The block landed: the slot describes the coordinate, and every cell waiting on it flips to
		// it. That flip is the atomic publication the spare slot exists for - there is no frame at
		// which a cell has no content, only frames at which it has coarser content.
		Slot &slot = _slots[size_t(job.slot)];
		slot.block_x = job.block_x;
		slot.block_y = job.block_y;
		slot.phase = job.phase;
		slot.serial = _serial();
		slot.resident = true;
		slot.baked = false;
		// The source is in the atlas and the slot names the coordinate, so the block is ready to be
		// *baked*: the producer's rect is queued here, and the slot stays unbaked until its dispatch
		// lands and acknowledges this serial.
		_queue_bake(job.slot);
		for (Cell &cell : _cells) {
			if (cell.pending_slot != job.slot) {
				continue;
			}
			cell.slot = job.slot;
			cell.have_x = job.block_x;
			cell.have_y = job.block_y;
			cell.current = true;
			cell.pending_slot = -1;
		}
		TimelineEntry entry;
		entry.frame = _frame_counter;
		entry.slot = job.slot;
		entry.ring = job.ring;
		entry.texels = int64_t(slot.texels) * int64_t(slot.texels) * int64_t(_config.channels);
		entry.bytes = int64_t(slot.texels) * int64_t(slot.texels) *
				int64_t(_atlas_bytes_per_texel(_config.format)) * int64_t(_config.channels);
		_timeline.push_back(entry);
		_state_stamp++;
	}
	(void)p_budget_texels;
	return produced;
}

int Terrain3DClipmapAtlas::invalidate_rect(const Rect2 &p_world) {
	if (!is_configured() || !_has_focus) {
		return 0;
	}
	const Rect2 rect = p_world.abs();
	if (rect.size.x <= 0.f || rect.size.y <= 0.f) {
		return 0;
	}
	int queued = 0;
	// The block is the invalidation unit: a cell whose block the rect touches is re-produced whole,
	// into a free slot, and stays not-current until it lands.
	for (Cell &cell : _cells) {
		const real_t block_world = _block_world_of_ring(cell.ring);
		const Vector2 origin(real_t(cell.have_x) * block_world - 0.5f * block_world,
				real_t(cell.have_y) * block_world - 0.5f * block_world);
		const Rect2 block_rect(origin, Vector2(block_world, block_world));
		if (!block_rect.intersects(rect)) {
			continue;
		}
		if (cell.pending_slot >= 0) {
			cell.current = false;
			continue;
		}
		const int slot = _take_free_slot(cell.ring);
		if (slot < 0) {
			cell.current = false;
			continue;
		}
		_queue_block(get_cell_index(cell.ring, cell.gx, cell.gy), slot);
		cell.current = false;
		queued++;
	}
	if (queued > 0) {
		_state_stamp++;
	}
	return queued;
}

// ---- Addressing --------------------------------------------------------------------------------

int Terrain3DClipmapAtlas::cell_for_world(const Vector2 &p_world) const {
	if (!is_configured() || _cells.empty()) {
		return -1;
	}
	// The finest unit whose own start point puts the point in one of its nine cells - the ring class's
	// `level_for_world()` rule with a 3x3 arrangement instead of a square, and the mirror of the
	// shader's arm. Finest first is what keeps a shell's inner hole from answering for a finer unit.
	for (int ring = 0; ring < _config.rings; ring++) {
		const int cell = cell_for_ring(ring, p_world);
		if (cell >= 0 && _cells[size_t(cell)].current) {
			return cell;
		}
	}
	return -1;
}

// The cell of *one* unit that holds a world point, or -1 when that unit's own 3x3 does not. It is the
// addressing rule in one place, so `cell_for_world()`, `get_unit_for_world()` and `sample()` cannot
// disagree about which cell answers - and the shader's finder is this same arithmetic.
int Terrain3DClipmapAtlas::cell_for_ring(const int p_ring, const Vector2 &p_world) const {
	if (p_ring < 0 || p_ring >= _config.rings) {
		return -1;
	}
	const Vector2 start = _ring_start(p_ring, _last_focus);
	const real_t block_world = _block_world_of_ring(p_ring);
	// A block is a half-open square, so the index is `floor((world - start) / W + 0.5)` rather than
	// `round(...)`: GLSL's `round()` is implementation-defined at a tie, and at a boundary it picked the
	// block below the point, whose clamped edge texel is one block away from the array's.
	const int gx = int(Math::floor((p_world.x - start.x) / block_world + 0.5f));
	const int gy = int(Math::floor((p_world.y - start.y) / block_world + 0.5f));
	if (Math::abs(gx) > 1 || Math::abs(gy) > 1) {
		return -1;
	}
	return get_cell_index(p_ring, gx, gy);
}

// The stored value at a world position through the atlas's own addressing, with the fallback chain a
// fragment sees: the cell the addressing picks, then the next coarser ring whose own grid contains
// the point, then the one-time global block. A reading of what the atlas *addresses*, which is the
// CPU's answer; the GPU's content is the atlas texture, and a test compares the two by rendering.
real_t Terrain3DClipmapAtlas::sample(const Vector2 &p_world, const int p_channel) const {
	if (!is_configured() || _cells.empty() || _source == nullptr) {
		return NAN;
	}
	const int channel = CLAMP(p_channel, 0, _config.channels - 1);
	for (int ring = 0; ring < _config.rings; ring++) {
		const int cell_index = cell_for_ring(ring, p_world);
		if (cell_index < 0) {
			continue;
		}
		const Cell &cell = _cells[size_t(cell_index)];
		if (!cell.current) {
			continue;
		}
		const Vector2 start = _ring_start(ring, _last_focus);
		const real_t block_world = _block_world_of_ring(ring);
		const real_t texel = _texel_of_ring(ring);
		const int texels = _texels_of_ring(ring);
		const Vector2 block(start.x + real_t(cell.gx) * block_world,
				start.y + real_t(cell.gy) * block_world);
		const Vector2 origin(block.x - 0.5f * block_world, block.y - 0.5f * block_world);
		const int logical_x = int(Math::floor((p_world.x - origin.x) / texel));
		const int logical_y = int(Math::floor((p_world.y - origin.y) / texel));
		const int stored_x = ((logical_x + cell.offset.x) % texels + texels) % texels;
		const int stored_y = ((logical_y + cell.offset.y) % texels + texels) % texels;
		// The world position the *logical* texel names, which is what the cell's block was produced
		// from - the content, not the view. Reading the source here is exact because a block's texels
		// are the source's values at exactly these positions.
		const Vector2 named = origin + Vector2(real_t(logical_x) + 0.5f, real_t(logical_y) + 0.5f) * texel;
		Terrain3DClipmapSource::Row row;
		row.level = ring;
		row.channel = channel;
		row.y = 0;
		row.x0 = 0;
		row.x1 = 1;
		row.size = texels;
		row.texel_world = texel;
		row.origin = named;
		(void)stored_x;
		(void)stored_y;
		_source->fill_row(row, _row_values.data());
		return _row_values[0];
	}
	if (!_global_produced) {
		return NAN;
	}
	const real_t texel_world = _global_world / real_t(MAX(1, _config.global_texels));
	const Vector2 origin = _global_origin - Vector2(_global_world, _global_world) * 0.5f;
	const int gx = CLAMP(int(Math::floor((p_world.x - origin.x) / texel_world)), 0, _config.global_texels - 1);
	const int gy = CLAMP(int(Math::floor((p_world.y - origin.y) / texel_world)), 0, _config.global_texels - 1);
	Terrain3DClipmapSource::Row row;
	row.level = _config.rings;
	row.channel = channel;
	row.y = 0;
	row.x0 = 0;
	row.x1 = 1;
	row.size = _config.global_texels;
	row.texel_world = texel_world;
	row.origin = origin + Vector2(real_t(gx) + 0.5f, real_t(gy) + 0.5f) * texel_world;
	_source->fill_row(row, _row_values.data());
	return _row_values[0];
}

// ---- Reports -----------------------------------------------------------------------------------

Array Terrain3DClipmapAtlas::get_ring_reports() const {
	Array reports;
	for (int ring = 0; ring < _config.rings; ring++) {
		Dictionary report;
		report["ring"] = ring;
		report["shape"] = UNIT_SIDE;
		report["blocks"] = get_ring_block_count(ring);
		report["texels"] = _texels_of_ring(ring);
		report["texel_world"] = _texel_of_ring(ring);
		// The ring's coverage: its own 3x3 square of blocks, which is the side a reader halves for the
		// radius the ring serves at its density.
		report["extent"] = real_t(UNIT_SIDE) * _block_world_of_ring(ring);
		report["spare"] = _config.spares;
		report["origin"] = ring < int(_ring_origin.size()) ? _ring_origin[size_t(ring)] : Vector2();
		report["phase"] = ring < int(_ring_phase_value.size()) ? _ring_phase_value[size_t(ring)] : Vector2i();
		int cells = 0;
		int current = 0;
		int pending = 0;
		for (const Cell &cell : _cells) {
			if (cell.ring != ring) {
				continue;
			}
			cells++;
			current += cell.current ? 1 : 0;
			pending += cell.pending_slot >= 0 ? 1 : 0;
		}
		report["cells"] = cells;
		report["current"] = current;
		report["pending"] = pending;
		reports.push_back(report);
	}
	// One more entry for the global block, so a reader sees the whole structure in one array.
	Dictionary global;
	global["ring"] = _config.rings;
	global["blocks"] = 1;
	global["texels"] = get_global_texels();
	global["texel_world"] = _global_world / real_t(MAX(1, get_global_texels()));
	global["extent"] = _global_world;
	global["resident"] = _global_produced;
	global["origin"] = _global_origin;
	reports.push_back(global);
	return reports;
}

Dictionary Terrain3DClipmapAtlas::get_layout_report() const {
	Dictionary report;
	report["block_size"] = _config.block_size;
	report["rings"] = _config.rings;
	report["base_world"] = _config.base_world;
	report["grid_side"] = UNIT_SIDE;
	report["blocks"] = get_block_count();
	report["total_blocks"] = get_slot_count();
	Array counts;
	for (int ring = 0; ring < _config.rings; ring++) {
		counts.push_back(get_ring_block_count(ring));
	}
	report["ring_blocks"] = counts;
	report["width"] = _layout.width;
	report["height"] = _layout.height;
	report["area"] = _layout.area;
	report["chosen"] = String(_layout.name);
	report["channels"] = _config.channels;
	report["format_bytes"] = _atlas_bytes_per_texel(_config.format);
	report["bytes"] = _layout.area * _atlas_bytes_per_texel(_config.format) * MAX(_config.channels, 1);
	Array schemes;
	for (int packer = 0; packer < PACK_COUNT; packer++) {
		Dictionary scheme;
		scheme["name"] = String(_schemes[packer].name);
		scheme["width"] = _schemes[packer].width;
		scheme["height"] = _schemes[packer].height;
		scheme["area"] = _schemes[packer].area;
		scheme["efficiency"] = _schemes[packer].efficiency;
		scheme["chosen"] = _schemes[packer].chosen;
		schemes.push_back(scheme);
	}
	report["schemes"] = schemes;
	int64_t packed = 0;
	for (const Rect2i &rect : _packed) {
		packed += int64_t(rect.size.x) * int64_t(rect.size.y);
	}
	report["packed_texels"] = packed;
	report["efficiency"] = _layout.area > 0 ? double(packed) / double(_layout.area) : 0.0;
	// The lower bound every scheme is measured against: the area the blocks need with no padding.
	int64_t bound = 1;
	while (bound * bound < packed) {
		bound++;
	}
	report["lower_bound_side"] = bound;
	report["lower_bound_area"] = bound * bound;
	// The rect array itself, in atlas pixels, so a debug view draws the layout the shader reads.
	Array rects;
	for (const Slot &slot : _slots) {
		Dictionary entry;
		entry["rect"] = Rect2(slot.rect);
		entry["ring"] = slot.ring;
		entry["texels"] = slot.texels;
		entry["spare"] = slot.spare;
		entry["global"] = slot.global;
		entry["resident"] = slot.resident;
		rects.push_back(entry);
	}
	report["rects"] = rects;
	// The grid itself: what each cell points at this frame, which is what a debug view labels.
	Array cells;
	for (const Cell &cell : _cells) {
		Dictionary entry;
		entry["gx"] = cell.gx;
		entry["gy"] = cell.gy;
		entry["ring"] = cell.ring;
		entry["slot"] = cell.slot;
		entry["pending_slot"] = cell.pending_slot;
		entry["current"] = cell.current;
		entry["offset"] = cell.offset;
		entry["block"] = Vector2i(int(cell.have_x), int(cell.have_y));
		entry["want"] = Vector2i(int(cell.want_x), int(cell.want_y));
		cells.push_back(entry);
	}
	report["cells"] = cells;
	return report;
}

Array Terrain3DClipmapAtlas::get_load_timeline() const {
	Array entries;
	for (const TimelineEntry &entry : _timeline) {
		Dictionary row;
		row["frame"] = int64_t(entry.frame);
		row["slot"] = entry.slot;
		row["ring"] = entry.ring;
		row["texels"] = entry.texels;
		row["bytes"] = entry.bytes;
		entries.push_back(row);
	}
	return entries;
}

void Terrain3DClipmapAtlas::clear_load_timeline() {
	_timeline.clear();
}

///////////////////////////
// The shared contract: the sampling rule, the debug schema and the arm
///////////////////////////

// The ring whose grid holds a world point, whether or not the cell is current: the *coverage* answer
// the shared contract asks for. Finest first, exactly like `cell_for_world()` and the shader's own
// finder, so a shell's inner hole never answers for a finer ring.
int Terrain3DClipmapAtlas::get_unit_for_world(const Vector2 &p_world) const {
	if (!is_configured() || _cells.empty()) {
		return -1;
	}
	for (int ring = 0; ring < _config.rings; ring++) {
		if (cell_for_ring(ring, p_world) >= 0) {
			return ring;
		}
	}
	return -1;
}

// The texel size a fragment is served at that point, which is the density's own reciprocal: the slot's
// texel when a cell answers, and the global block's when the point is outside the grid. Zero means the
// layer does not reach it.
real_t Terrain3DClipmapAtlas::get_texel_world_at(const Vector2 &p_world) const {
	const int ring = get_unit_for_world(p_world);
	if (ring < 0) {
		return _global_produced ? _global_world / real_t(MAX(1, _config.global_texels)) : 0.f;
	}
	return _texel_of_ring(ring);
}

// Every block's baked content is stale. The source texels are untouched, so every cell stays current -
// only the three arrays the bake produces from them are out of date, which is exactly the statement
// the ring's `mark_baked_stale()` makes. Clearing the flags without a queue leaves the material arm
// falling back forever, so each resident slot that carries content is queued as well.
void Terrain3DClipmapAtlas::mark_baked_stale() {
	if (get_baked_channel_count() <= 0) {
		return;
	}
	_bake_rects.clear();
	for (int slot = 0; slot < int(_slots.size()); slot++) {
		Slot &entry = _slots[size_t(slot)];
		if (!entry.resident) {
			entry.baked = false;
			continue;
		}
		_queue_bake(slot);
	}
	_state_stamp++;
}

// One ring in the *shared* schema. A ring is a 3x3 arrangement of its own blocks around the rings
// inside it, so it has no single centre: `world_size` is the square it spans, `valid` is "every cell of
// the ring has the block it wants", and the per-cell detail travels in `get_impl_payload()`.
void Terrain3DClipmapAtlas::get_unit_report(const int p_unit, TerrainClipmap::UnitReport &r_report) const {
	r_report = TerrainClipmap::UnitReport();
	if (p_unit < 0 || p_unit >= _config.rings) {
		return;
	}
	int cells = 0;
	int current = 0;
	int pending = 0;
	int resident = 0;
	for (const Cell &cell : _cells) {
		if (cell.ring != p_unit) {
			continue;
		}
		cells++;
		current += cell.current ? 1 : 0;
		pending += cell.pending_slot >= 0 ? 1 : 0;
		if (cell.slot >= 0 && cell.current) {
			resident++;
		}
	}
	r_report.index = p_unit;
	r_report.kind = "ring";
	r_report.texels = _texels_of_ring(p_unit);
	r_report.world_size = real_t(UNIT_SIDE) * _block_world_of_ring(p_unit);
	r_report.texel_world = _texel_of_ring(p_unit);
	r_report.density = r_report.texel_world > 0.f ? 1.f / r_report.texel_world : 0.f;
	r_report.valid = cells > 0 && current == cells;
	r_report.baked = r_report.valid;
	r_report.pending = pending;
	r_report.blocks = cells;
	r_report.resident = resident;
	r_report.offset = p_unit < int(_ring_phase_value.size()) ? _ring_phase_value[size_t(p_unit)] : Vector2i();
	r_report.center = p_unit < int(_ring_origin.size()) ? _ring_origin[size_t(p_unit)] : Vector2();
	return;
}

// What only the atlas can say: the rect array, the cells' current-frame indices, the packing schemes
// and the rolling counters. The facade nests it under one key, so a debug view draws the quadtree
// arrangement without the shared schema above growing an atlas branch.
Dictionary Terrain3DClipmapAtlas::get_impl_payload() const {
	Dictionary payload;
	payload["storage"] = "packed_block_atlas";
	payload["layout"] = get_layout_report();
	payload["ring_reports"] = get_ring_reports();
	payload["timeline"] = get_load_timeline();
	payload["atlas_width"] = _layout.width;
	payload["atlas_height"] = _layout.height;
	payload["global_world"] = _global_world;
	payload["global_texels"] = _config.global_texels;
	payload["global_produced"] = _global_produced;
	payload["block_uploads"] = int64_t(_block_uploads);
	payload["scroll_events"] = int64_t(_scroll_events);
	payload["blocks_loaded"] = int64_t(_edge_blocks_loaded);
	payload["blocks_retained"] = int64_t(_interior_blocks_retained);
	payload["last_scroll_loaded"] = int64_t(_last_scroll_loaded);
	payload["last_scroll_retained"] = int64_t(_last_scroll_retained);
	int baked_cells = 0;
	for (int cell = 0; cell < get_cell_count(); cell++) {
		baked_cells += is_cell_baked(cell) ? 1 : 0;
	}
	payload["baked_cells"] = baked_cells;
	return payload;
}

// The atlas's arm: the rect array, the per-ring start points and phases, the grid's shape and the cell
// table. The shader's copy of the block addressing has to be the *same* numbers the CPU's is, so the
// two are one publish - the same rule the LOD ring's arm follows.
Dictionary Terrain3DClipmapAtlas::get_arm() const {
	Dictionary arm;
	if (!is_configured()) {
		return arm;
	}
	const int rings = _config.rings;
	const int cells = get_cell_count();
	const int slots = get_slot_count();
	PackedVector2Array starts;
	PackedVector4Array rects;
	PackedInt32Array cell_slots;
	PackedVector2Array cell_offsets;
	PackedFloat32Array cell_current;
	PackedFloat32Array cell_baked;
	starts.resize(rings);
	rects.resize(slots);
	cell_slots.resize(cells);
	cell_offsets.resize(cells);
	cell_current.resize(cells);
	cell_baked.resize(cells);
	for (int ring = 0; ring < rings; ring++) {
		starts[ring] = get_ring_start(ring);
	}
	for (int slot = 0; slot < slots; slot++) {
		const Rect2i rect = get_slot_rect(slot);
		rects[slot] = Vector4(real_t(rect.position.x), real_t(rect.position.y),
				real_t(rect.size.x), real_t(rect.size.y));
	}
	for (int cell = 0; cell < cells; cell++) {
		cell_slots[cell] = get_cell_slot(cell);
		const Vector2i offset = get_cell_offset(cell);
		cell_offsets[cell] = Vector2(real_t(offset.x), real_t(offset.y));
		cell_current[cell] = is_cell_current(cell) ? 1.f : 0.f;
		cell_baked[cell] = is_cell_baked(cell) ? 1.f : 0.f;
	}
	arm["implementation"] = String(TerrainClipmap::implementation_name(TerrainClipmap::Implementation::Atlas));
	arm["configured"] = true;
	arm["texture"] = get_texture_rid();
	arm["block_size"] = _config.block_size;
	arm["block_world"] = _config.base_world;
	arm["rings"] = rings;
	arm["grid_side"] = UNIT_SIDE;
	arm["cells"] = cells;
	arm["slots"] = slots;
	arm["channels"] = _config.channels;
	arm["width"] = _layout.width;
	arm["height"] = _layout.height;
	arm["starts"] = starts;
	arm["rects"] = rects;
	arm["cell_slots"] = cell_slots;
	arm["cell_offsets"] = cell_offsets;
	arm["cell_current"] = cell_current;
	arm["cell_baked"] = cell_baked;
	arm["pending_bake_rects"] = get_pending_bake_count();
	if (get_baked_channel_count() >= 3) {
		arm["baked_albedo"] = get_baked_texture_rid(0);
		arm["baked_normal"] = get_baked_texture_rid(1);
		arm["baked_params"] = get_baked_texture_rid(2);
	}
	return arm;
}
