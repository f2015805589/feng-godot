#[compute]
#version 450
// Rebuild only when CLV residency changes. Each partition retains its own
// source texels and a one-cell dilation border for hardware trilinear filtering.
// No lighting values or categorical labels are averaged here.
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, std430) readonly buffer SourceIndices { int values[]; } source_indices;
layout(set = 0, binding = 1) uniform texture3D label_atlas;
layout(set = 0, binding = 2) uniform sampler nearest_sampler;
layout(set = 0, binding = 3, std430) writeonly buffer PartitionIndices { ivec4 values[]; } partition_indices;
layout(set = 0, binding = 4, std430) writeonly buffer PartitionWeights { vec4 values[]; } partition_weights;
layout(push_constant, std430) uniform Config {
	int resolution; int lod_count; int label_side; int label_encoding;
	int lod_mask;
} config;

int source_at(ivec3 cell, int lod, int domain) {
	int r = config.resolution;
	if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(r)))) return -1;
	int halo = (config.label_side - r) / 2;
	ivec3 label_cell = cell + ivec3(halo);
	label_cell.z += lod * config.label_side;
	int label = int(round(texelFetch(sampler3D(label_atlas, nearest_sampler), label_cell, 0).r * 255.0));
	if (config.label_encoding == 2) label &= 3;
	if (label != domain) return -1;
	return source_indices.values[((lod * r + cell.z) * r + cell.y) * r + cell.x];
}

void main() {
	int r = config.resolution;
	int width = r * 2;
	int index = int(gl_GlobalInvocationID.x);
	if (index >= width * r * r * config.lod_count) return;
	ivec3 cell = ivec3(index % width, (index / width) % r, index / (width * r));
	int domain = cell.x / r + 1;
	int lod = cell.z / r;
	if ((config.lod_mask & (1 << lod)) == 0) return;
	cell.x %= r;
	cell.z %= r;
	int source = source_at(cell, lod, domain);
	ivec4 sources = ivec4(source, -1, -1, -1);
	vec4 weights = vec4(source >= 0 ? 1.0 : 0.0, 0.0, 0.0, 0.0);
	if (source < 0) {
		ivec4 distances = ivec4(4);
		for (int z = -1; z <= 1; z++) for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
			int distance_squared = x*x + y*y + z*z;
			if (distance_squared <= 0 || distance_squared >= distances.w) continue;
			int candidate = source_at(cell + ivec3(x,y,z), lod, domain);
			if (candidate >= 0) {
				for (int slot = 0; slot < 4; slot++) {
					if (distance_squared >= distances[slot]) continue;
					for (int tail = 3; tail > slot; tail--) {
						distances[tail] = distances[tail-1];
						sources[tail] = sources[tail-1];
					}
					distances[slot] = distance_squared;
					sources[slot] = candidate;
					break;
				}
			}
		}
		for (int slot = 0; slot < 4; slot++) {
			weights[slot] = sources[slot] >= 0 ? 1.0 / float(distances[slot]) : 0.0;
		}
		float total = dot(weights, vec4(1.0));
		if (total > 0.0) weights /= total;
	}
	partition_indices.values[index] = sources;
	partition_weights.values[index] = weights;
}
