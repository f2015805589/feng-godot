// Copyright © 2026 Feng contributors. MIT license.
#include "terrain_3d_texture_encoder.h"

#include <ConvectionKernels.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <thread>
#include <vector>

using namespace godot;

Ref<Image> terrain_encode_bc7(const Ref<Image> &p_image, const bool p_normal) {
	if (p_image.is_null() || p_image->get_format() != Image::FORMAT_RGBA8) {
		return Ref<Image>();
	}
	cvtt::Options options;
	options.flags |= cvtt::Flags::BC7_RespectPunchThrough;
	if (p_normal) { options.flags |= cvtt::Flags::Uniform; }
	cvtt::BC7EncodingPlan plan;
	cvtt::Kernels::ConfigureBC7EncodingPlanFromQuality(plan, 3);
	const PackedByteArray input = p_image->get_data();
	PackedByteArray output;
	const int mip_count = p_image->get_mipmap_count() + 1;
	int64_t bytes = 0;
	for (int mip = 0; mip < mip_count; ++mip) {
		bytes += int64_t((std::max(1, p_image->get_width() >> mip) + 3) / 4) *
				((std::max(1, p_image->get_height() >> mip) + 3) / 4) * 16;
	}
	output.resize(bytes);
	struct Row { const uint8_t *source; uint8_t *destination; int width, height, y; };
	std::vector<Row> rows;
	uint8_t *destination = output.ptrw();
	for (int mip = 0; mip < mip_count; ++mip) {
		const int width = std::max(1, p_image->get_width() >> mip);
		const int height = std::max(1, p_image->get_height() >> mip);
		const uint8_t *source = input.ptr() + p_image->get_mipmap_offset(mip);
		for (int y = 0; y < height; y += 4) {
			rows.push_back({source, destination, width, height, y});
			destination += ((width + 3) / 4) * 16;
		}
	}
	std::atomic<size_t> next{0};
	auto work = [&]() {
		cvtt::PixelBlockU8 blocks[cvtt::NumParallelBlocks];
		uint8_t encoded[16 * cvtt::NumParallelBlocks];
		for (size_t index = next.fetch_add(1); index < rows.size(); index = next.fetch_add(1)) {
			const Row &row = rows[index];
			for (int x = 0; x < row.width; x += 4 * cvtt::NumParallelBlocks) {
				for (unsigned int block = 0; block < cvtt::NumParallelBlocks; ++block) {
					for (int by = 0; by < 4; ++by) {
						for (int bx = 0; bx < 4; ++bx) {
							const int px = std::min(row.width - 1, x + int(block) * 4 + bx);
							const int py = std::min(row.height - 1, row.y + by);
							std::memcpy(blocks[block].m_pixels[by * 4 + bx],
									row.source + (int64_t(py) * row.width + px) * 4, 4);
						}
					}
				}
				cvtt::Kernels::EncodeBC7(encoded, blocks, options, plan);
				const int count = std::min(int(cvtt::NumParallelBlocks), (row.width - x + 3) / 4);
				std::memcpy(row.destination + (x / 4) * 16, encoded, count * 16);
			}
		}
	};
	const unsigned int workers = std::max(1u, std::min(4u, std::thread::hardware_concurrency()));
	std::vector<std::thread> threads;
	for (unsigned int worker = 1; worker < workers; ++worker) { threads.emplace_back(work); }
	work();
	for (auto &thread : threads) { thread.join(); }
	return Image::create_from_data(p_image->get_width(), p_image->get_height(), p_image->has_mipmaps(),
			Image::FORMAT_BPTC_RGBA, output);
}
