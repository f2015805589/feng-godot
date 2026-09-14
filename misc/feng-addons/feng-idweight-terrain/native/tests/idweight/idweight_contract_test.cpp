#include "../../src/terrain_surface_idweight.h"
#include <cstdlib>
#include <iostream>
#include <limits>
using namespace TerrainSurfaceIdWeight;
#define CHECK(condition) do { if (!(condition)) { std::cerr << "FAIL line " << __LINE__ << ": " #condition << '\n'; std::exit(1); } } while (false)

int main() {
	uint16_t packed = 0;
	for (int overlay = 0; overlay < 32; ++overlay) {
		for (int background = 0; background < 32; ++background) {
			for (int mode = 0; mode < 4; ++mode) {
				for (int level = 1; level <= 8; ++level) {
					Pair p = { uint8_t(overlay), uint8_t(background), Mode(mode), uint8_t(level), 0 };
					CHECK(encode(p, packed));
					CHECK(packed == uint16_t(overlay * 2048 + background * 64 + mode * 16 + (level - 1) * 2));
					Pair decoded = decode(packed);
					CHECK(decoded.overlay == overlay && decoded.background == background);
					CHECK(int(decoded.mode) == mode && decoded.level == level && decoded.uv == 0);
					uint8_t bytes[2];
					write_le(packed, bytes);
					CHECK(read_le(bytes) == packed);
				}
			}
		}
	}
	Pair target = { 7, 3, Mode::MIX, 8, 0 };
	CHECK(encode(target, packed) && packed == 0x38fe);
	CHECK(paint(single(3), target, 0.f, packed) && packed == single(3));
	CHECK(paint(single(3), target, .001f, packed));
	CHECK(decode(packed).level == 1 && decode(packed).mode == Mode::MIX);
	CHECK(paint(packed, target, 1.f, packed) && decode(packed).level == 8);
	int level = -1;
	CHECK(quantize(.0625f, level) && level == 0);
	CHECK(quantize(.1875f, level) && level == 2);
	CHECK(!quantize(std::numeric_limits<float>::infinity(), level));
	CHECK(!paint(packed, target, std::numeric_limits<float>::quiet_NaN(), packed));
	target.uv = 1;
	CHECK(!encode(target, packed));
	target.uv = 0;
	target.overlay = 32;
	CHECK(!encode(target, packed));
	CHECK(mode_weight(Mode::SET, .25f, .5f) == .25f);
	CHECK(mode_weight(Mode::ADD, .25f, .5f) == .625f);
	CHECK(mode_weight(Mode::SUB, .25f, .5f) == .125f);
	CHECK(mode_weight(Mode::MIX, .25f, .5f) == .5f);
	CHECK(slope_tangent(1.f, 1, 1000.f) == 0.f);
	CHECK(slope_tangent(0.f, 8, 1000.f) == 1.f);
	CHECK(slope_tangent(.5f, 1, 0.f) == 1.f);
	float weights[3];
	barycentric(.75f, .25f, weights);
	CHECK(weights[0] == .25f && weights[1] == .5f && weights[2] == .25f);
	for (int blend = 0; blend <= 255; ++blend) {
		uint32_t bits = (3u << 27) | (7u << 22) | (uint32_t(blend) << 14) | 0x3fffu;
		LegacyConversion converted = convert_legacy(bits);
		CHECK(converted.metadata == 0x3fffu && converted.needs_auto_material_bake);
		CHECK(converted.weight_error <= .062501f);
		CHECK(decode(converted.packed).background == 3);
	}

	// ── Bit-layout cross-checks: parity with the packed format contract ──
	// Layout parity with the reference encoder (overlay<<11 | background<<6 | mode<<4 | (level-1)<<1)
	{
		Pair p = { 21, 7, Mode::SUB, 5, 0 };
		CHECK(encode(p, packed));
		CHECK(packed == ((21u << 11) | (7u << 6) | (2u << 4) | (4u << 1)));
	}

	// Brush parity: same-pair lerp, different-pair restart,
	// level floor, quantization ties-to-even.
	{
		Pair pair = { 10, 3, Mode::SET, 4, 0 };
		// Fresh pair at low influence keeps at least level 1
		CHECK(paint(single(3), pair, .05f, packed) && decode(packed).level == 1);
		// Continued strokes on the same pair interpolate toward the target.
		// Level 1 (1/8) at half influence toward 4/8 gives 2.5/8, which
		// quantizes ties-to-even to level 2.
		CHECK(paint(packed, pair, .5f, packed) && decode(packed).level == 2);
		// Full influence reaches the target level exactly
		CHECK(paint(packed, pair, 1.f, packed) && decode(packed).level == 4);
		// Equal overlay/background collapses to a single background material
		Pair flat = { 6, 6, Mode::MIX, 8, 0 };
		CHECK(paint(packed, flat, .5f, packed) && packed == single(6));
	}

	// Quantization boundary parity with QuantizeWeightLevel (ties-to-even):
	// contribution n/16 -> level round(n/2), with 0.5 fraction rounding to even.
	{
		struct Sample { float contribution; int level; };
		const Sample samples[] = {
			{ 0.f, 0 }, { .0625f, 0 }, { .125f, 1 }, { .1875f, 2 },
			{ .25f, 2 }, { .5f, 4 }, { .75f, 6 }, { .9375f, 8 }, { 1.f, 8 },
		};
		for (const Sample &s : samples) {
			CHECK(quantize(s.contribution, level) && level == s.level);
		}
	}

	// Slope threshold table parity with IDWEIGHT_SLOPE_THRESHOLDS. Level 1 at
	// full sharpness reaches 1 only at horizon; level 8 starts near-vertical.
	{
		CHECK(slope_tangent(1.f, 1, 1000.f) == 0.f);
		CHECK(slope_tangent(1.f, 8, 1000.f) == 0.f);
		CHECK(slope_tangent(-1.f, 8, 1000.f) == 1.f);
		// Monotone across levels at a fixed normal
		float prev = 2.f;
		for (int lv = 1; lv <= 8; ++lv) {
			float t = slope_tangent(.3f, uint8_t(lv), 1000.f);
			CHECK(t <= prev + 1e-6f);
			prev = t;
		}
	}

	// Legacy zero-blend protection: control weight 0 converts to level 1 (not 0)
	{
		// 0x3ffe keeps every non-material metadata bit set except bit 0 (auto).
		uint32_t bits = (5u << 27) | (9u << 22) | (0u << 14) | 0x3ffeu;
		LegacyConversion converted = convert_legacy(bits);
		CHECK(decode(converted.packed).level == 1);
		CHECK(decode(converted.packed).mode == Mode::SET);
		CHECK(converted.metadata == 0x3ffeu && !converted.needs_auto_material_bake);
		// Equal ids collapse to a single background material regardless of weight
		uint32_t flat = (7u << 27) | (7u << 22) | (200u << 14) | 0x3ffeu;
		CHECK(convert_legacy(flat).packed == single(7));
	}

	std::cout << "PASS: 32768 R16 pairs, byte order, quantization, brush, slope, barycentric, 256 legacy weights and bit-layout parity checks\n";
	return 0;
}
