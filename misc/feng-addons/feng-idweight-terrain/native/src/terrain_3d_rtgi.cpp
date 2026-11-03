// Immutable RTGI input. Built only after a terrain edit, independent of raster
// clipmap/VT residency. The primary hit still uses the full raster material;
// secondary diffuse hits use a filtered world-space albedo atlas per region.
#include "terrain_3d.h"
#include "terrain_surface_idweight.h"

#include <godot_cpp/classes/base_material3d.hpp>

#include <cstring>
#include <vector>

Dictionary Terrain3D::capture_rtgi_geometry() const {
	Dictionary result;
	if (!_data || !_data->get_region_count()) {
		result["unsupported_reason"] = "terrain_regions_not_loaded";
		return result;
	}
	Ref<Image> textures[32];
	Color tints[32];
	float scales[32];
	for (int i = 0; i < 32; ++i) {
		tints[i] = Color(0.5, 0.5, 0.5);
		scales[i] = 1;
		Ref<Terrain3DTextureAsset> asset = _assets.is_valid() ? _assets->get_texture_asset(i) : Ref<Terrain3DTextureAsset>();
		if (asset.is_null()) {
			continue;
		}
		tints[i] = asset->get_albedo_color();
		scales[i] = asset->get_uv_scale();
		if (asset->get_albedo_texture().is_valid()) {
			textures[i] = asset->get_albedo_texture()->get_image();
			if (textures[i].is_valid()) {
				textures[i] = textures[i]->duplicate();
				if (textures[i]->is_compressed() && textures[i]->decompress() != OK) {
					textures[i].unref();
					continue;
				}
				// Diffuse secondary rays integrate a footprint; avoid aliasing high frequency
				// terrain detail into the low-resolution secondary-hit atlas.
				textures[i]->clear_mipmaps();
				textures[i]->resize(128, 128, Image::INTERPOLATE_LANCZOS);
			}
		}
	}
	auto sample = [&](int id, float x, float z) -> Color {
		if (textures[id].is_null()) {
			return tints[id];
		}
		int u = int(Math::floor(x * scales[id] * 128)) % 128, v = int(Math::floor(z * scales[id] * 128)) % 128;
		return textures[id]->get_pixel((u + 128) % 128, (v + 128) % 128) * tints[id];
	};
	PackedByteArray vertex_bytes, index_bytes;
	Array surfaces, materials;
	const int size = int(_region_size), side = size + 1;
	const float spacing = _vertex_spacing;
	for (const Vector2i &location : _data->get_region_locations()) {
		const Vector2i origin = location * size;
		std::vector<float> heights(side * side);
		std::vector<bool> holes(side * side);
		for (int z = 0; z <= size; ++z) {
			for (int x = 0; x <= size; ++x) {
				Vector2i grid = origin + Vector2i(x, z);
				float height = _data->get_mesh_vertex_height(0, Terrain3DData::HEIGHT_FILTER_NEAREST, grid);
				if (!Math::is_finite(height)) {
					grid = origin + Vector2i(MIN(x, size - 1), MIN(z, size - 1));
					height = _data->get_mesh_vertex_height(0, Terrain3DData::HEIGHT_FILTER_NEAREST, grid);
				}
				uint32_t ctrl = _data->get_control(Vector3(grid.x * spacing, 0, grid.y * spacing));
				holes[z * side + x] = !Math::is_finite(height) || (ctrl != UINT32_MAX && is_hole(ctrl));
				heights[z * side + x] = Math::is_finite(height) ? height : 0;
			}
		}
		PackedFloat32Array vertices;
		vertices.resize(side * side * 8);
		float *dst = vertices.ptrw();
		for (int z = 0; z <= size; ++z) {
			for (int x = 0; x <= size; ++x) {
				const float dx = (heights[z * side + MIN(x + 1, size)] - heights[z * side + MAX(x - 1, 0)]) / (spacing * (x == 0 || x == size ? 1 : 2));
				const float dz = (heights[MIN(z + 1, size) * side + x] - heights[MAX(z - 1, 0) * side + x]) / (spacing * (z == 0 || z == size ? 1 : 2));
				Vector3 n = Vector3(-dx, 1, -dz).normalized();
				int i = (z * side + x) * 8;
				dst[i] = (origin.x + x) * spacing;
				dst[i + 1] = heights[z * side + x];
				dst[i + 2] = (origin.y + z) * spacing;
				dst[i + 3] = n.x;
				dst[i + 4] = n.y;
				dst[i + 5] = n.z;
				dst[i + 6] = float(x) / size;
				dst[i + 7] = float(z) / size;
			}
		}
		PackedInt32Array indices;
		indices.resize(size * size * 6);
		int *idx = indices.ptrw();
		int count = 0;
		for (int z = 0; z < size; ++z) {
			for (int x = 0; x < size; ++x) {
				int a = z * side + x, b = a + 1, c = a + side, d = c + 1;
				if (!holes[a] && !holes[d] && !holes[c]) {
					idx[count++] = a;
					idx[count++] = d;
					idx[count++] = c;
				}
				if (!holes[a] && !holes[b] && !holes[d]) {
					idx[count++] = a;
					idx[count++] = b;
					idx[count++] = d;
				}
			}
		}
		indices.resize(count);
		if (!count) {
			continue;
		}
		Ref<Image> albedo = Image::create_empty(size, size, false, Image::FORMAT_RGBA8);
		for (int z = 0; z < size; ++z) {
			for (int x = 0; x < size; ++x) {
				float wx = (origin.x + x + 0.5f) * spacing, wz = (origin.y + z + 0.5f) * spacing;
				uint16_t packed = uint16_t(_data->get_surface_texel_nearest(Vector2(wx, wz)));
				auto pair = TerrainSurfaceIdWeight::decode(packed);
				float w = TerrainSurfaceIdWeight::contribution(packed);
				Color color(0, 0, 0, 0);
				for (int tap = 0; tap < 4; ++tap) {
					float sx = wx + ((tap & 1) ? 0.25f : -0.25f) * spacing, sz = wz + ((tap & 2) ? 0.25f : -0.25f) * spacing;
					color += sample(pair.background, sx, sz).srgb_to_linear().lerp(sample(pair.overlay, sx, sz).srgb_to_linear(), w) * 0.25f;
				}
				color = color.linear_to_srgb();
				color.a = 1;
				albedo->set_pixel(x, z, color);
			}
		}
		Dictionary material, texture, surface;
		const int material_id = materials.size();
		texture["id"] = int64_t(albedo->get_instance_id());
		texture["width"] = size;
		texture["height"] = size;
		texture["format"] = Image::FORMAT_RGBA8;
		texture["data"] = albedo->get_data();
		texture["repeat"] = false;
		texture["filter"] = BaseMaterial3D::TEXTURE_FILTER_LINEAR;
		material["supported"] = true;
		material["source_material_id"] = texture["id"];
		material["material_signature"] = texture["id"];
		material["albedo"] = Color(1, 1, 1);
		material["metallic"] = 0.0;
		material["roughness"] = 1.0;
		material["specular"] = 0.5;
		material["emission_enabled"] = false;
		material["emission"] = Color(0, 0, 0);
		material["emission_energy_multiplier"] = 0.0;
		material["uv_transform"] = Vector4(1, 1, 0, 0);
		material["cull_mode"] = BaseMaterial3D::CULL_BACK;
		material["flags"] = 1;
		material["albedo_texture"] = texture;
		surface["vertex_base_byte"] = vertex_bytes.size();
		surface["index_base_byte"] = index_bytes.size();
		surface["vertex_count"] = side * side;
		surface["index_count"] = count;
		surface["surface_index"] = material_id;
		surface["material_index"] = material_id;
		surface["flags"] = 1;
		surface["source_geometry_signature"] = int64_t(albedo->get_instance_id());
		vertex_bytes.append_array(vertices.to_byte_array());
		index_bytes.append_array(indices.to_byte_array());
		surfaces.push_back(surface);
		materials.push_back(material);
	}
	result["source_mesh_id"] = int64_t(get_instance_id());
	result["vertex_stride_bytes"] = 32;
	result["vertex_bytes"] = vertex_bytes;
	result["index_bytes"] = index_bytes;
	result["surfaces"] = surfaces;
	result["materials"] = materials;
	if (surfaces.is_empty()) {
		result["unsupported_reason"] = "terrain_has_no_solid_triangles";
	}
	return result;
}
