// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/rendering_server.hpp>

#include "generated_texture.h"
#include "logger.h"
#include "terrain_3d.h"

///////////////////////////
// Public Functions
///////////////////////////

void GeneratedTexture::clear() {
	if (_rid.is_valid()) {
		LOG(EXTREME, "GeneratedTexture freeing ", _rid);
		RS->free_rid(_rid);
	}
	if (_image.is_valid()) {
		LOG(EXTREME, "GeneratedTexture unref image", _image);
		_image.unref();
	}
	_rid = RID();
	_dirty = true;
	_size = 0;
	_layer_size = V2I_ZERO;
	_layer_format = Image::FORMAT_MAX;
}

RID GeneratedTexture::create(const TypedArray<Image> &p_layers) {
	if (!p_layers.is_empty()) {
		if (Terrain3D::debug_level >= DEBUG) {
			LOG(EXTREME, "RenderingServer creating Texture2DArray, layers size: ", p_layers.size());
			for (int i = 0; i < p_layers.size(); i++) {
				Ref<Image> img = p_layers[i];
				LOG(EXTREME, i, ": ", img, ", empty: ", img->is_empty(), ", size: ", img->get_size(), ", format: ", img->get_format());
			}
		}
		_rid = RS->texture_2d_layered_create(p_layers, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
		_dirty = false;
		_size = p_layers.size();
		_create_count++;
		Ref<Image> first = p_layers[0];
		if (first.is_valid()) {
			_layer_size = first->get_size();
			_layer_format = first->get_format();
		}
	} else {
		clear();
	}
	return _rid;
}

// Slot based layout: the layer count is owned by Terrain3DData's slot table, not
// by the current region count, so a region entering or leaving memory only needs
// one layer uploaded instead of reallocating the whole array.
bool GeneratedTexture::ensure_layers(const Ref<Image> &p_blank, const int p_layers) {
	if (p_blank.is_null() || p_layers <= 0) {
		clear();
		return false;
	}
	const Vector2i layer_size = p_blank->get_size();
	const Image::Format layer_format = p_blank->get_format();
	if (_rid.is_valid() && _size == p_layers && _layer_size == layer_size && _layer_format == layer_format) {
		return false;
	}
	LOG(EXTREME, "RenderingServer creating Texture2DArray, layers: ", p_layers, ", size: ", layer_size,
			", format: ", layer_format, " (was layers: ", _size, ", size: ", _layer_size, ", format: ", _layer_format, ")");
	if (_rid.is_valid()) {
		RS->free_rid(_rid);
	}
	// Free slots are never addressed by the region map, so every layer can start
	// as the same blank image; it only has to match size and format.
	TypedArray<Image> layers;
	layers.resize(p_layers);
	for (int i = 0; i < p_layers; i++) {
		layers[i] = p_blank;
	}
	_rid = RS->texture_2d_layered_create(layers, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
	_dirty = false;
	_size = p_layers;
	_layer_size = layer_size;
	_layer_format = layer_format;
	_create_count++;
	return true;
}

void GeneratedTexture::update(const Ref<Image> &p_image, const int p_layer) {
	LOG(EXTREME, "RenderingServer updating Texture2DArray at index: ", p_layer);
	RS->texture_2d_update(_rid, p_image, p_layer);
	_update_count++;
}

RID GeneratedTexture::create(const Ref<Image> &p_image) {
	LOG(EXTREME, "RenderingServer creating Texture2D");
	_image = p_image;
	_rid = RS->texture_2d_create(_image);
	_dirty = false;
	if (_image.is_valid()) {
		_layer_size = _image->get_size();
		_layer_format = _image->get_format();
		_size = _layer_size.x;
	}
	_create_count++;
	return _rid;
}
