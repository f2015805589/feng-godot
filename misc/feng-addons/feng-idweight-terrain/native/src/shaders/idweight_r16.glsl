R"(
//INSERT: IDWEIGHT_R16
// R16 IDWeight surface contract and evaluation.
// Bit layout (MSB -> LSB): OverlayId:5 | BackgroundId:5 | Mode:2 | Weight:3 | UV:1
// Weight stores levels 1..8 as raw values 0..7. Equal IDs encode a single
// background material. Must stay bit-exact with TerrainSurfaceIdWeight::encode.
#define IDWEIGHT_OVERLAY_MASK 0xF800u
#define IDWEIGHT_BACKGROUND_MASK 0x07C0u
#define IDWEIGHT_MODE_MASK 0x0030u
#define IDWEIGHT_WEIGHT_MASK 0x000Eu
#define IDWEIGHT_UV_MASK 0x0001u
#define IDWEIGHT_MAX_LAYERS 3
#define IDWEIGHT_MODE_SET 0u
#define IDWEIGHT_MODE_ADD 1u
#define IDWEIGHT_MODE_SUB 2u
#define IDWEIGHT_MODE_MIX 3u
// Slope distance fade: full blend inside 180m, disabled beyond 200m.
#define IDWEIGHT_SLOPE_FULL_DISTANCE_SQ 32400.0
#define IDWEIGHT_SLOPE_MAX_DISTANCE_SQ 40000.0
// Random triplanar defaults matching TerrainRandomTriplanarSettings.Default.
#define IDWEIGHT_DITHER_CELL_SIZE 0.005
#define IDWEIGHT_TRIPLANAR_SEED 0u
#define IDWEIGHT_TRIPLANAR_THRESHOLD 0.8660254037844386 // cos(30 deg)
#define IDWEIGHT_TRIPLANAR_FEATHER 0.0402650422643367 // cos(25) - cos(30)
#define IDWEIGHT_TRIPLANAR_SHARPNESS 4.0

uint idweight_overlay(uint value) { return (value >> 11u) & 0x1Fu; }
uint idweight_background(uint value) { return (value >> 6u) & 0x1Fu; }
uint idweight_mode(uint value) { return (value >> 4u) & 0x3u; }
uint idweight_weight_level(uint value) { return ((value >> 1u) & 0x7u) + 1u; }
uint idweight_uv_variant(uint value) { return value & 0x1u; }
float idweight_weight(uint value) {
	// Equal IDs encode a single background material with zero overlay weight.
	return idweight_overlay(value) == idweight_background(value)
		? 0.0 : float(idweight_weight_level(value)) / 8.0;
}

float idweight_saturate(float v) { return clamp(v, 0.0, 1.0); }

// ── Contribution aggregation (up to six candidates per triangle) ──

struct IdWeightContributions {
	uint id0, id1, id2, id3, id4, id5;
	float w0, w1, w2, w3, w4, w5;
	uint count;
};

float idweight_get_weight(IdWeightContributions values, int index) {
	if (index == 0) return values.w0;
	if (index == 1) return values.w1;
	if (index == 2) return values.w2;
	if (index == 3) return values.w3;
	if (index == 4) return values.w4;
	return values.w5;
}

uint idweight_get_id(IdWeightContributions values, int index) {
	if (index == 0) return values.id0;
	if (index == 1) return values.id1;
	if (index == 2) return values.id2;
	if (index == 3) return values.id3;
	if (index == 4) return values.id4;
	return values.id5;
}

void idweight_add_contribution(uint materialId, float contribution, inout IdWeightContributions values) {
	if (contribution <= 0.0) return;
	if (values.count > 0u && values.id0 == materialId) { values.w0 += contribution; return; }
	if (values.count > 1u && values.id1 == materialId) { values.w1 += contribution; return; }
	if (values.count > 2u && values.id2 == materialId) { values.w2 += contribution; return; }
	if (values.count > 3u && values.id3 == materialId) { values.w3 += contribution; return; }
	if (values.count > 4u && values.id4 == materialId) { values.w4 += contribution; return; }
	if (values.count > 5u && values.id5 == materialId) { values.w5 += contribution; return; }
	if (values.count == 0u) { values.id0 = materialId; values.w0 = contribution; }
	else if (values.count == 1u) { values.id1 = materialId; values.w1 = contribution; }
	else if (values.count == 2u) { values.id2 = materialId; values.w2 = contribution; }
	else if (values.count == 3u) { values.id3 = materialId; values.w3 = contribution; }
	else if (values.count == 4u) { values.id4 = materialId; values.w4 = contribution; }
	else if (values.count == 5u) { values.id5 = materialId; values.w5 = contribution; }
	else { return; }
	values.count++;
}

void idweight_add_vertex(uint packed, float barycentric, inout IdWeightContributions values, inout float interpolatedOverlayWeight) {
	uint baseId = idweight_background(packed);
	uint overlayId = idweight_overlay(packed);
	float overlayWeight = idweight_weight(packed);
	idweight_add_contribution(baseId, barycentric * (1.0 - overlayWeight), values);
	if (overlayId != baseId) {
		idweight_add_contribution(overlayId, barycentric * overlayWeight, values);
	}
	interpolatedOverlayWeight += barycentric * overlayWeight;
}

// ── Budgeted three-layer selection with stochastic residual ──

bool idweight_contribution_is_better(IdWeightContributions values, int candidate, int current) {
	if (current < 0) return true;
	float candidateWeight = idweight_get_weight(values, candidate);
	float currentWeight = idweight_get_weight(values, current);
	uint candidateId = idweight_get_id(values, candidate);
	uint currentId = idweight_get_id(values, current);
	return candidateWeight > currentWeight + 1e-6 ||
		(abs(candidateWeight - currentWeight) <= 1e-6 && candidateId < currentId);
}

void idweight_select_budgeted_3(IdWeightContributions values, float residualSelector,
		out uvec3 materialIds, out vec3 materialWeights, out uint materialCount) {
	int selected0 = -1;
	int selected1 = -1;
	for (int selectionPass = 0; selectionPass < 2; selectionPass++) {
		int best = -1;
		for (int candidate = 0; candidate < 6; candidate++) {
			if (uint(candidate) >= values.count) break;
			if (candidate == selected0 || candidate == selected1) continue;
			if (idweight_contribution_is_better(values, candidate, best)) best = candidate;
		}
		if (selectionPass == 0) selected0 = best;
		else selected1 = best;
	}
	if (selected1 >= 0 && idweight_contribution_is_better(values, selected1, selected0)) {
		int swap = selected0;
		selected0 = selected1;
		selected1 = swap;
	}
	materialIds = uvec3(0u, 0u, 0u);
	materialWeights = vec3(0.0, 0.0, 0.0);
	materialCount = 0u;
	if (selected0 >= 0) {
		materialIds.x = idweight_get_id(values, selected0);
		materialWeights.x = idweight_get_weight(values, selected0);
		materialCount = 1u;
	}
	if (selected1 >= 0) {
		materialIds.y = idweight_get_id(values, selected1);
		materialWeights.y = idweight_get_weight(values, selected1);
		materialCount = 2u;
	}
	float residualWeight = 0.0;
	for (int candidate = 0; candidate < 6; candidate++) {
		if (uint(candidate) >= values.count) break;
		if (candidate == selected0 || candidate == selected1) continue;
		residualWeight += idweight_get_weight(values, candidate);
	}
	if (residualWeight > 0.0) {
		float targetWeight = idweight_saturate(residualSelector) * residualWeight;
		float accumulatedWeight = 0.0;
		int residualCandidate = -1;
		for (int candidate = 0; candidate < 6; candidate++) {
			if (uint(candidate) >= values.count) break;
			if (candidate == selected0 || candidate == selected1) continue;
			residualCandidate = candidate;
			accumulatedWeight += idweight_get_weight(values, candidate);
			if (targetWeight < accumulatedWeight) break;
		}
		if (residualCandidate >= 0) {
			materialIds.z = idweight_get_id(values, residualCandidate);
			// The selected residual represents the complete discarded tail.
			materialWeights.z = residualWeight;
			materialCount = 3u;
		}
	}
}

// ── Deterministic stochastic coverage (Bayer 8x8 with per-macro-tile scramble) ──

uint idweight_bayer8x8_index(uvec2 coord) {
	uint x = coord.x & 7u;
	uint y = coord.y & 7u;
	uint index = 0u;
	for (uint bit = 0u; bit < 3u; bit++) {
		uint xBit = (x >> bit) & 1u;
		uint yBit = (y >> bit) & 1u;
		uint digit = ((xBit ^ yBit) << 1u) | yBit;
		index |= digit << (2u * (2u - bit));
	}
	return index;
}

uint idweight_coverage_tile_hash(ivec2 tile, uint seed) {
	uint value = uint(tile.x) * 0x9e3779b9u;
	value ^= uint(tile.y) * 0x85ebca6bu;
	value ^= seed * 0xc2b2ae35u;
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;
	value ^= value >> 16u;
	return value;
}

float idweight_stochastic_coverage01_with_salt(vec3 positionWS, uint salt) {
	ivec2 orderedCell = ivec2(floor(positionWS.xz / IDWEIGHT_DITHER_CELL_SIZE));
	uvec2 localCoord = uvec2(uint(orderedCell.x & 7), uint(orderedCell.y & 7));
	ivec2 macroTile = ivec2(orderedCell.x >> 3, orderedCell.y >> 3);
	uint seed = IDWEIGHT_TRIPLANAR_SEED ^ salt;
	uint scramble = idweight_coverage_tile_hash(macroTile, seed);
	if ((scramble & 1u) != 0u) localCoord.x = 7u - localCoord.x;
	if ((scramble & 2u) != 0u) localCoord.y = 7u - localCoord.y;
	if ((scramble & 4u) != 0u) localCoord = localCoord.yx;
	uint index = idweight_bayer8x8_index(localCoord);
	index = (index + ((scramble >> 3u) & 63u)) & 63u;
	return (float(index) + 0.5) * (1.0 / 64.0);
}

float idweight_stochastic_coverage01(vec3 positionWS) {
	return idweight_stochastic_coverage01_with_salt(positionWS, 0u);
}

// ── Random triplanar projection ──

float idweight_get_triplanar_factor(vec3 geometricNormalWS) {
	float upAlignment = abs(normalize(geometricNormalWS).y);
	return 1.0 - smoothstep(
		IDWEIGHT_TRIPLANAR_THRESHOLD,
		idweight_saturate(IDWEIGHT_TRIPLANAR_THRESHOLD + IDWEIGHT_TRIPLANAR_FEATHER),
		upAlignment);
}

vec3 idweight_get_triplanar_weights(vec3 geometricNormalWS) {
	vec3 weights = pow(max(abs(normalize(geometricNormalWS)), vec3(0.0001)), vec3(IDWEIGHT_TRIPLANAR_SHARPNESS));
	return weights / max(weights.x + weights.y + weights.z, 0.0001);
}

uint idweight_select_stochastic_coverage_axis(vec3 positionWS, vec3 blendWeights) {
	float coverageThreshold = idweight_stochastic_coverage01(positionWS);
	if (coverageThreshold < blendWeights.x) return 0u;
	if (coverageThreshold < blendWeights.x + blendWeights.y) return 1u;
	return 2u;
}

vec2 idweight_get_projection_position(vec3 positionWS, uint projectionAxis) {
	// Triplanar convention: uvZY, uvXZ, uvXY.
	if (projectionAxis == 0u) return vec2(positionWS.z, positionWS.y);
	if (projectionAxis == 1u) return vec2(positionWS.x, positionWS.z);
	return vec2(positionWS.x, positionWS.y);
}

// ── Normal decode (BC5-style: scale the sampled tilts, derive out-of-plane) ──

vec3 idweight_decode_normal(vec4 packedNormal, float scale) {
	// This shader keeps Godot's Y-up tangent frame, so the internal vector is
	// (nU, nH, nV): in-plane U tilt, out-of-plane height, in-plane V tilt.
	// `packedNormal.xzy` maps Godot's RGB (x, y, z) to (x, z, y), which moves the
	// encoded green channel (tangent Y, the out-of-plane axis) into the middle
	// slot: a neutral Godot normal map (0.5, 0.5, 1.0) decodes to (0, 1, 0).
	vec3 normalPS = fma(packedNormal.xzy, vec3(2.0), vec3(-1.0));
	// Mirrors TerrainIdWeightFunctions.hlsl::IdWeightDecodeNormal: scale the two
	// *sampled tilts* by the material's normal depth, then re-derive the third
	// component. Scaling the tilts (x and z) rather than x and y is what keeps a
	// neutral map exactly (0, 1, 0) at any normal_depth; scaling the height and
	// re-deriving the V tilt instead invents a tilt that was never authored.
	normalPS.xz *= scale;
	normalPS.y = sqrt(idweight_saturate(1.0 - dot(normalPS.xz, normalPS.xz)));
	return normalPS;
}

vec3 idweight_projection_normal_to_world(vec3 normalPS, uint projectionAxis, vec3 geometricNormalWS) {
	// Composes the sampled detail in the *selected projection plane*, expressed
	// in this shader's Y-up normal convention (normalPS = nU, nH, nV): the
	// in-plane tilts are ADDED to the geometric normal's in-plane projection,
	// while the out-of-plane component MULTIPLIES it. The previous additive
	// `g + normalPS` composition added the height too, which biased every slope
	// normal toward straight up: a 45-degree ramp measured nDotUp = 0.92 instead
	// of 0.707, so the slope blend under-reported the slope and barely engaged.
	// Multiplying restores the invariant the slope evaluator depends on -- a
	// neutral normal map (nU = nV = 0, nH = 1) reproduces the geometric normal
	// exactly on every projection axis.
	// An `axisSign` carried through the swizzle would multiply the depth
	// component on the way in and again on the way out, so it cancels; it is
	// omitted here.
	vec3 g = normalize(geometricNormalWS);
	if (projectionAxis == 0u) {
		// ZY plane: U -> world Z, V -> world Y, height -> world X
		return normalize(vec3(g.x * normalPS.y, g.y + normalPS.z, g.z + normalPS.x));
	}
	if (projectionAxis == 1u) {
		// XZ plane: U -> world X, V -> world Z, height -> world Y
		return normalize(vec3(g.x + normalPS.x, g.y * normalPS.y, g.z + normalPS.z));
	}
	// XY plane: U -> world X, V -> world Y, height -> world Z
	return normalize(vec3(g.x + normalPS.x, g.y + normalPS.z, g.z * normalPS.y));
}

// ── Slope evaluation ──

float idweight_slope_threshold(uint packed) {
	uint rawWeight = (packed >> 1u) & 7u;
	if (rawWeight == 0u) return 0.0;
	if (rawWeight == 1u) return 0.125;
	if (rawWeight == 2u) return 0.25;
	if (rawWeight == 3u) return 0.375;
	if (rawWeight == 4u) return 0.5;
	if (rawWeight == 5u) return 0.625;
	if (rawWeight == 6u) return 0.75;
	return 0.98;
}

float idweight_compute_slope_tangent(vec3 normalWS, float lowThreshold, float blendSharpness) {
	float nDotUp = idweight_saturate(dot(normalize(normalWS), vec3(0.0, 1.0, 0.0)));
	float x = acos(nDotUp);
	float x2 = x * x;
	float x3 = x2 * x;
	float x5 = x3 * x2;
	float tangentApprox = idweight_saturate(x + x3 / 3.0 + 2.0 * x5 / 15.0);
	float highThreshold = idweight_saturate(lowThreshold + blendSharpness);
	return idweight_saturate((tangentApprox - lowThreshold) / max(highThreshold - lowThreshold, 1e-5));
}

float idweight_pair_corner_coverage(uint packed, uint targetBackgroundId, uint targetOverlayId) {
	uint backgroundId = idweight_background(packed);
	uint overlayId = idweight_overlay(packed);
	float overlayWeight = idweight_weight(packed);
	return targetBackgroundId != targetOverlayId &&
		backgroundId == targetBackgroundId &&
		overlayId == targetOverlayId
		? overlayWeight : 0.0;
}

float idweight_bilinear_pair_coverage(uint packedBottomLeft, uint packedBottomRight,
		uint packedTopLeft, uint packedTopRight, uint targetPair, vec2 local) {
	uint targetBackgroundId = idweight_background(targetPair);
	uint targetOverlayId = idweight_overlay(targetPair);
	float bottomLeftCoverage = idweight_pair_corner_coverage(packedBottomLeft, targetBackgroundId, targetOverlayId);
	float bottomRightCoverage = idweight_pair_corner_coverage(packedBottomRight, targetBackgroundId, targetOverlayId);
	float topLeftCoverage = idweight_pair_corner_coverage(packedTopLeft, targetBackgroundId, targetOverlayId);
	float topRightCoverage = idweight_pair_corner_coverage(packedTopRight, targetBackgroundId, targetOverlayId);
	float bottomCoverage = mix(bottomLeftCoverage, bottomRightCoverage, local.x);
	float topCoverage = mix(topLeftCoverage, topRightCoverage, local.x);
	return mix(bottomCoverage, topCoverage, local.y);
}

float idweight_slope_interior_blend(float pairCoverage) {
	return smoothstep(0.0, 0.2, idweight_saturate(pairCoverage));
}

float idweight_resolve_mode_target_weight(uint mode, float linearWeight, float slopeWeight) {
	if (mode == IDWEIGHT_MODE_ADD) return idweight_saturate(linearWeight + slopeWeight * (1.0 - linearWeight));
	if (mode == IDWEIGHT_MODE_SUB) return idweight_saturate(linearWeight * (1.0 - slopeWeight));
	if (mode == IDWEIGHT_MODE_MIX) return slopeWeight;
	return linearWeight;
}
//INSERT: END_IDWEIGHT_R16
)"
