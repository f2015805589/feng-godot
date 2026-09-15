R"(
#version 450
// GPU block encoder for the surface material atlas. One invocation encodes one 4x4
// block of one page layer into the words the compressed atlas stores, so compressing a
// page never runs a block encoder on the CPU and never reads the uncompressed staging
// array back through a texture readback. BC1, BC3, BC4, BC5 and BC7 are produced here.
// BC7 uses mode 6: one subset with per-endpoint parity bits, which carries alpha at the
// same precision as colour and keeps the block layout free of partition tables.

#define BC_CODEC_BC1 0u
#define BC_CODEC_BC3 1u
#define BC_CODEC_BC4 2u
#define BC_CODEC_BC5 3u
#define BC_CODEC_BC7 4u

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2DArray encode_source;

layout(set = 0, binding = 1, std430) writeonly buffer EncodeOutput {
	uint words[];
} encode_output;

layout(push_constant, std430) uniform EncodePush {
	uvec4 params; // x: stored size, y: source layer, z: codec, w: blocks per axis
} encode_push;

// Interpolation weights of the four-bit BC7 index, in sixty-fourths.
const int BC7_WEIGHT4[16] = int[16](0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64);
// Seven mode bits: six zeros followed by the mode number.
const uint BC7_MODE6_PREFIX = 64u;

int bc_error3(ivec3 p_left, ivec3 p_right) {
	const ivec3 difference = p_left - p_right;
	return difference.x * difference.x + difference.y * difference.y + difference.z * difference.z;
}

int bc_error4(ivec4 p_left, ivec4 p_right) {
	const ivec4 difference = p_left - p_right;
	return difference.x * difference.x + difference.y * difference.y +
			difference.z * difference.z + difference.w * difference.w;
}

// A page that is not a multiple of the block size still stores a whole number of blocks,
// so the tail texels read the last real texel instead of out of bounds.
ivec4 bc_load(ivec2 p_texel) {
	const ivec2 size = ivec2(int(encode_push.params.x));
	const ivec2 clamped = clamp(p_texel, ivec2(0), size - ivec2(1));
	const vec4 value = texelFetch(encode_source, ivec3(clamped, int(encode_push.params.y)), 0);
	return ivec4(round(clamp(value, vec4(0.0), vec4(1.0)) * 255.0));
}

// Writes a field of up to thirty-two bits at a bit offset inside the four-word block.
void bc_put(inout uint p_words[4], int p_offset, uint p_value, int p_bits) {
	const uint mask = (p_bits >= 32) ? 0xffffffffu : ((1u << uint(p_bits)) - 1u);
	const uint value = p_value & mask;
	const int word = p_offset >> 5;
	const int shift = p_offset & 31;
	p_words[word] |= value << uint(shift);
	if (shift + p_bits > 32) {
		p_words[word + 1] |= value >> uint(32 - shift);
	}
}

// Expands a five-six-five endpoint to eight bits per channel, the way the hardware does.
ivec3 bc_unpack_565(uint p_value) {
	const ivec3 packed = ivec3(int((p_value >> 11) & 31u), int((p_value >> 5) & 63u), int(p_value & 31u));
	return ivec3((packed.x << 3) | (packed.x >> 2), (packed.y << 2) | (packed.y >> 4), (packed.z << 3) | (packed.z >> 2));
}

uint bc_pack_565(ivec3 p_color) {
	const ivec3 clamped = clamp(p_color, ivec3(0), ivec3(255));
	return (uint(clamped.x >> 3) << 11) | (uint(clamped.y >> 2) << 5) | uint(clamped.z >> 3);
}

// The eight-bit endpoints of a two-colour block: the block's own extremes, then one
// refinement that pulls each endpoint onto the mean of the texels nearest to it, so a
// block whose texels cluster away from its bounds is not stretched across them.
void bc_color_endpoints(ivec3 p_color[16], out ivec3 r_low, out ivec3 r_high) {
	ivec3 low = p_color[0];
	ivec3 high = p_color[0];
	for (int i = 1; i < 16; ++i) {
		low = min(low, p_color[i]);
		high = max(high, p_color[i]);
	}
	for (int pass = 0; pass < 2; ++pass) {
		const vec3 axis = vec3(high - low);
		const float length_squared = dot(axis, axis);
		if (length_squared < 1.0) {
			break;
		}
		ivec3 low_sum = ivec3(0);
		ivec3 high_sum = ivec3(0);
		int low_count = 0;
		int high_count = 0;
		for (int i = 0; i < 16; ++i) {
			const float t = clamp(dot(vec3(p_color[i] - low), axis) / length_squared, 0.0, 1.0);
			const int level = int(round(t * 3.0));
			if (level == 0) {
				low_sum += p_color[i];
				low_count++;
			} else if (level == 3) {
				high_sum += p_color[i];
				high_count++;
			}
		}
		if (low_count == 0 || high_count == 0) {
			break;
		}
		low = (low_sum + ivec3(low_count / 2)) / low_count;
		high = (high_sum + ivec3(high_count / 2)) / high_count;
	}
	r_low = low;
	r_high = high;
}

// One two-colour block: the colour half of BC1 and BC3. The endpoints are ordered so the
// first is the larger, which keeps the block in the opaque four-colour mode.
uvec2 bc_encode_color(ivec3 p_color[16]) {
	ivec3 low = ivec3(0);
	ivec3 high = ivec3(0);
	bc_color_endpoints(p_color, low, high);
	const uint endpoint0 = bc_pack_565(high);
	const uint endpoint1 = bc_pack_565(low);
	if (endpoint0 == endpoint1) {
		return uvec2(endpoint0 | (endpoint1 << 16), 0u);
	}
	const ivec3 color0 = bc_unpack_565(endpoint0);
	const ivec3 color1 = bc_unpack_565(endpoint1);
	// The four colours the hardware interpolates, in index order.
	const ivec3 color2 = (2 * color0 + color1) / 3;
	const ivec3 color3 = (color0 + 2 * color1) / 3;
	uint indexes = 0u;
	for (int i = 0; i < 16; ++i) {
		int best = 0;
		int best_error = bc_error3(color0, p_color[i]);
		const int error1 = bc_error3(color1, p_color[i]);
		if (error1 < best_error) {
			best_error = error1;
			best = 1;
		}
		const int error2 = bc_error3(color2, p_color[i]);
		if (error2 < best_error) {
			best_error = error2;
			best = 2;
		}
		const int error3 = bc_error3(color3, p_color[i]);
		if (error3 < best_error) {
			best = 3;
		}
		indexes |= uint(best) << uint(2 * i);
	}
	return uvec2(endpoint0 | (endpoint1 << 16), indexes);
}

// One eight-value block from a single channel: the alpha half of BC3, and one half of BC5.
// The larger endpoint comes first, which selects the interpolated eight-value mode.
uvec2 bc_encode_alpha(int p_value[16]) {
	int low = p_value[0];
	int high = p_value[0];
	for (int i = 1; i < 16; ++i) {
		low = min(low, p_value[i]);
		high = max(high, p_value[i]);
	}
	uint indexes = 0u;
	if (low != high) {
		for (int i = 0; i < 16; ++i) {
			int best = 0;
			int best_error = 1 << 30;
			for (int level = 0; level < 8; ++level) {
				const int value = (level == 0) ? high
						: ((level == 1) ? low : ((8 - level) * high + (level - 1) * low + 3) / 7);
				const int error = abs(value - p_value[i]);
				if (error < best_error) {
					best_error = error;
					best = level;
				}
			}
			indexes |= uint(best) << uint(3 * i);
		}
	}
	// The first eight bytes hold the endpoints and the low half of the index stream; the
	// stream's last index crosses into the second word.
	const uint first = uint(high) | (uint(low) << 8) | ((indexes & 0xffffu) << 16);
	const uint second = indexes >> 16;
	return uvec2(first, second);
}

// The parity bit an eight-bit endpoint carries in its four-bit field. The bit is shared by
// every channel of the endpoint, so it is chosen once over all four channels and each
// channel is then rounded onto that parity.
ivec4 bc7_quantize_endpoint(vec4 p_value, out uint r_parity) {
	ivec4 best = ivec4(0);
	int best_error = 1 << 30;
	r_parity = 0u;
	for (int parity = 0; parity < 2; ++parity) {
		const ivec4 quantized = clamp(ivec4(round((p_value - vec4(float(parity))) * 0.5)) * 2 + ivec4(parity),
				ivec4(0), ivec4(255));
		const vec4 difference = vec4(quantized) - p_value;
		const int error = int(dot(difference, difference));
		if (error < best_error) {
			best_error = error;
			best = quantized;
			r_parity = uint(parity);
		}
	}
	return best;
}

// BC7 mode six: one subset, four-bit indices, seven-bit endpoints carrying a parity bit.
// The endpoints are fitted along the block's principal axis, then refitted against the
// indices that axis produced, so a smooth page is not quantised to its bounding box.
uvec4 bc_encode_bc7(ivec4 p_color[16]) {
	vec4 low = vec4(p_color[0]);
	vec4 high = vec4(p_color[0]);
	for (int i = 1; i < 16; ++i) {
		low = min(low, vec4(p_color[i]));
		high = max(high, vec4(p_color[i]));
	}
	vec4 endpoint0 = high;
	vec4 endpoint1 = low;
	int indexes[16];
	for (int i = 0; i < 16; ++i) {
		indexes[i] = 0;
	}
	for (int pass = 0; pass < 3; ++pass) {
		const vec4 axis = endpoint1 - endpoint0;
		const float length_squared = dot(axis, axis);
		if (length_squared < 0.5) {
			break;
		}
		float weight_sum = 0.0;
		vec4 color_sum = vec4(0.0);
		for (int i = 0; i < 16; ++i) {
			const float t = clamp(dot(vec4(p_color[i]) - endpoint0, axis) / length_squared, 0.0, 1.0);
			indexes[i] = int(round(t * 15.0));
			const float weight = float(indexes[i]) / 15.0;
			weight_sum += weight;
			color_sum += vec4(p_color[i]);
		}
		const float weight_mean = weight_sum / 16.0;
		const vec4 color_mean = color_sum / 16.0;
		vec4 covariance = vec4(0.0);
		float variance = 0.0;
		for (int i = 0; i < 16; ++i) {
			const float weight = float(indexes[i]) / 15.0 - weight_mean;
			covariance += weight * (vec4(p_color[i]) - color_mean);
			variance += weight * weight;
		}
		if (variance < 0.0001) {
			break;
		}
		const vec4 direction = covariance / variance;
		endpoint0 = clamp(color_mean - direction * weight_mean, vec4(0.0), vec4(255.0));
		endpoint1 = clamp(endpoint0 + direction, vec4(0.0), vec4(255.0));
	}
	uint parity0 = 0u;
	uint parity1 = 0u;
	ivec4 quantized0 = bc7_quantize_endpoint(endpoint0, parity0);
	ivec4 quantized1 = bc7_quantize_endpoint(endpoint1, parity1);
	// Final index assignment against the quantised endpoints, which is what the hardware
	// interpolates. Both endpoints are eight-bit values, so the interpolation is exact.
	for (int i = 0; i < 16; ++i) {
		int best = 0;
		int best_error = 1 << 30;
		for (int level = 0; level < 16; ++level) {
			const int weight = BC7_WEIGHT4[level];
			const ivec4 value = (quantized0 * (64 - weight) + quantized1 * weight + ivec4(32)) >> 6;
			const int error = bc_error4(value, p_color[i]);
			if (error < best_error) {
				best_error = error;
				best = level;
			}
		}
		indexes[i] = best;
	}
	// The anchor of the block stores one bit less than the other texels, so a block whose
	// anchor landed on the top half of the index range is written the other way round.
	if (indexes[0] >= 8) {
		const ivec4 swap = quantized0;
		quantized0 = quantized1;
		quantized1 = swap;
		const uint swap_parity = parity0;
		parity0 = parity1;
		parity1 = swap_parity;
		for (int i = 0; i < 16; ++i) {
			indexes[i] = 15 - indexes[i];
		}
	}
	uint words[4] = uint[4](0u, 0u, 0u, 0u);
	bc_put(words, 0, BC7_MODE6_PREFIX, 7);
	bc_put(words, 7, uint(quantized0.x >> 1), 7);
	bc_put(words, 14, uint(quantized1.x >> 1), 7);
	bc_put(words, 21, uint(quantized0.y >> 1), 7);
	bc_put(words, 28, uint(quantized1.y >> 1), 7);
	bc_put(words, 35, uint(quantized0.z >> 1), 7);
	bc_put(words, 42, uint(quantized1.z >> 1), 7);
	bc_put(words, 49, uint(quantized0.w >> 1), 7);
	bc_put(words, 56, uint(quantized1.w >> 1), 7);
	bc_put(words, 63, parity0, 1);
	bc_put(words, 64, parity1, 1);
	int offset = 65;
	for (int i = 0; i < 16; ++i) {
		const int bits = (i == 0) ? 3 : 4;
		bc_put(words, offset, uint(indexes[i]), bits);
		offset += bits;
	}
	return uvec4(words[0], words[1], words[2], words[3]);
}

void main() {
	const uint block_axis = encode_push.params.w;
	const uint block = gl_GlobalInvocationID.x;
	if (block >= block_axis * block_axis) {
		return;
	}
	const ivec2 corner = ivec2(int(block % block_axis), int(block / block_axis)) * 4;
	ivec4 color[16];
	for (int i = 0; i < 16; ++i) {
		color[i] = bc_load(corner + ivec2(i % 4, i / 4));
	}
	const uint codec = encode_push.params.z;
	uint words[4] = uint[4](0u, 0u, 0u, 0u);
	uint word_count = 4u;
	if (codec == BC_CODEC_BC1) {
		ivec3 rgb[16];
		for (int i = 0; i < 16; ++i) {
			rgb[i] = color[i].xyz;
		}
		const uvec2 packed = bc_encode_color(rgb);
		words[0] = packed.x;
		words[1] = packed.y;
		word_count = 2u;
	} else if (codec == BC_CODEC_BC3) {
		ivec3 rgb[16];
		int alpha[16];
		for (int i = 0; i < 16; ++i) {
			rgb[i] = color[i].xyz;
			alpha[i] = color[i].w;
		}
		const uvec2 packed_alpha = bc_encode_alpha(alpha);
		const uvec2 packed_color = bc_encode_color(rgb);
		words[0] = packed_alpha.x;
		words[1] = packed_alpha.y;
		words[2] = packed_color.x;
		words[3] = packed_color.y;
	} else if (codec == BC_CODEC_BC4) {
		int red[16];
		for (int i = 0; i < 16; ++i) {
			red[i] = color[i].x;
		}
		const uvec2 packed = bc_encode_alpha(red);
		words[0] = packed.x;
		words[1] = packed.y;
		word_count = 2u;
	} else if (codec == BC_CODEC_BC5) {
		int red[16];
		int green[16];
		for (int i = 0; i < 16; ++i) {
			red[i] = color[i].x;
			green[i] = color[i].y;
		}
		const uvec2 packed_red = bc_encode_alpha(red);
		const uvec2 packed_green = bc_encode_alpha(green);
		words[0] = packed_red.x;
		words[1] = packed_red.y;
		words[2] = packed_green.x;
		words[3] = packed_green.y;
	} else {
		const uvec4 packed = bc_encode_bc7(color);
		words[0] = packed.x;
		words[1] = packed.y;
		words[2] = packed.z;
		words[3] = packed.w;
	}
	const uint base = block * word_count;
	for (uint i = 0u; i < word_count; ++i) {
		encode_output.words[base + i] = words[i];
	}
}
)"
