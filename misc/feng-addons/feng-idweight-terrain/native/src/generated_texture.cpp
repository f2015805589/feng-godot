// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/rendering_server.hpp>

#include "generated_texture.h"
#include "logger.h"

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
	_size = 0;
	_layer_size = V2I_ZERO;
	_layer_format = Image::FORMAT_MAX;
}

RID GeneratedTexture::create(const TypedArray<Image> &p_layers) {
	clear();
	if (!p_layers.is_empty() && Ref<Image>(p_layers[0]).is_valid()) {
		_rid = RS->texture_2d_layered_create(p_layers, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
		if (_rid.is_valid()) {
			Ref<Image> first = p_layers[0];
			_size = p_layers.size();
			_layer_size = first->get_size();
			_layer_format = first->get_format();
			_create_count++;
		}
	}
	return _rid;
}

bool GeneratedTexture::ensure_layers(const Ref<Image> &p_blank, const int p_layers) {
	if (p_blank.is_null() || p_layers <= 0) {
		clear();
		return false;
	}
	if (_rid.is_valid() && _image.is_null() && _size == p_layers && _layer_size == p_blank->get_size() &&
			_layer_format == p_blank->get_format()) {
		return false;
	}
	// Unmapped slots share the blank payload until their first upload.
	TypedArray<Image> layers;
	layers.resize(p_layers);
	for (int i = 0; i < p_layers; i++) {
		layers[i] = p_blank;
	}
	return create(layers).is_valid();
}

void GeneratedTexture::update(const Ref<Image> &p_image, const int p_layer) {
	LOG(EXTREME, "RenderingServer updating Texture2DArray at index: ", p_layer);
	RS->texture_2d_update(_rid, p_image, p_layer);
	_update_count++;
}

RID GeneratedTexture::create(const Ref<Image> &p_image) {
	// Retain a caller's current backing image across replacement.
	const Ref<Image> image = p_image;
	clear();
	if (image.is_null()) { return _rid; }
	_rid = RS->texture_2d_create(image);
	if (_rid.is_valid()) {
		_image = image;
		_layer_size = image->get_size();
		_layer_format = image->get_format();
		_size = _layer_size.x;
		_create_count++;
	}
	return _rid;
}
