// The test runner inserts the production packing methods unchanged. Minimal value
// types let the CPU layout invariant run without initializing a rendering server.
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

#define MAX(a, b) std::max((a), (b))
struct Vector2i { int x = 0, y = 0; };
struct Rect2i {
	Vector2i position, size;
	Rect2i(int x, int y, int w, int h) : position{x, y}, size{w, h} {}
};
class Terrain3DClipmapAtlas {
public:
	enum { PACK_SHELF, PACK_RING_BANDS, PACK_QUADTREE, PACK_COUNT };
	struct Config { int rings, block_size, global_texels; bool spares; };
	struct PackedItem { int size, ring; bool spare, global; };
	Config _config;
	int get_ring_block_count(int p_ring) const;
	int _texels_of_ring(int p_ring) const;
	bool _pack_quadtree(const std::vector<PackedItem> &, int, int, std::vector<Rect2i> &) const;
	void _pack_scheme(int, std::vector<PackedItem> &, std::vector<Rect2i> &, int &, int &) const;
};
#include "packing_methods.inc"

static void require(bool condition, const char *message) {
	if (!condition) { throw std::runtime_error(message); }
}

static bool intersects(const Rect2i &a, const Rect2i &b) {
	return std::max(a.position.x, b.position.x) < std::min(a.position.x + a.size.x, b.position.x + b.size.x) &&
			std::max(a.position.y, b.position.y) < std::min(a.position.y + a.size.y, b.position.y + b.size.y);
}

static void verify(Terrain3DClipmapAtlas::Config config, int scheme) {
	Terrain3DClipmapAtlas atlas{config};
	std::vector<Terrain3DClipmapAtlas::PackedItem> items;
	std::vector<Rect2i> rects;
	int width = 0, height = 0;
	atlas._pack_scheme(scheme, items, rects, width, height);
	const size_t count = size_t(config.rings * (config.spares ? 10 : 9) + 1);
	require(items.size() == count && rects.size() == count, "every requested slot must be placed");
	int globals = 0, spares = 0;
	int64_t area = 0;
	std::vector<int> ring_blocks(size_t(config.rings), 0);
	for (size_t i = 0; i < rects.size(); i++) {
		const auto &rect = rects[i];
		const auto &item = items[i];
		require(rect.size.x == item.size && rect.size.y == item.size, "rect must retain requested dimensions");
		require(rect.position.x >= 0 && rect.position.y >= 0 && rect.position.x + rect.size.x <= width &&
				rect.position.y + rect.size.y <= height, "rect must be inside chosen bounds");
		area += int64_t(rect.size.x) * rect.size.y;
		if (item.global) { globals++; }
		else if (item.spare) { spares++; }
		else { ring_blocks.at(size_t(item.ring))++; }
		for (size_t j = 0; j < i; j++) {
			require(!intersects(rect, rects[j]), "rectangles overlap");
		}
	}
	require(globals == 1 && spares == (config.spares ? config.rings : 0), "slot identities must survive packing");
	for (int blocks : ring_blocks) { require(blocks == 9, "each ring must retain nine blocks"); }
	require(area == int64_t(config.rings) * (config.spares ? 10 : 9) * config.block_size * config.block_size +
			int64_t(config.global_texels) * config.global_texels, "packed coverage must equal the requested texels");
}

int main() {
	int cases = 0, failures = 0;
	for (int scheme = 0; scheme < Terrain3DClipmapAtlas::PACK_COUNT; scheme++) {
		for (int size : {8, 32, 64, 256}) {
			for (int rings : {1, 2, 3, 4, 8, 11, 12}) {
				for (bool spares : {false, true}) {
					for (int global : {1, size / 4, size}) {
						cases++;
						try { verify({rings, size, global, spares}, scheme); }
						catch (const std::exception &error) {
							if (failures++ < 8) {
								std::cerr << "REGRESSION scheme=" << scheme << " block=" << size << " rings=" << rings
										<< " spares=" << spares << " global=" << global << ": " << error.what() << '\n';
							}
						}
					}
				}
			}
		}
	}
	std::cout << (failures ? "FAIL" : "PASS") << " clipmap packing: " << cases << " shapes, " << failures << " failures\n";
	return failures ? 1 : 0;
}
