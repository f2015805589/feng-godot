// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef GENERATEDTEXTURE_CLASS_H
#define GENERATEDTEXTURE_CLASS_H

#include <godot_cpp/classes/image.hpp>

#include "constants.h"

class GeneratedTexture {
	CLASS_NAME_STATIC("Terrain3DGenTex");

private:
	RID _rid = RID();
	Ref<Image> _image;
	bool _dirty = true;
	// For a Texture2DArray this is the layer count. For a Texture2D created from
	// a single image it is the edge size, as before.
	int _size = 0;
	Vector2i _layer_size = V2I_ZERO;
	Image::Format _layer_format = Image::FORMAT_MAX;
	// Telemetry. Streaming should be all update() and no create(), so a test can
	// assert that adding or removing one region does not reallocate the arrays.
	int _create_count = 0;
	int _update_count = 0;

public:
	void clear();
	bool is_dirty() const { return _dirty; }
	RID create(const TypedArray<Image> &p_layers);
	// Allocates a Texture2DArray with p_layers layers matching p_blank's size and
	// format, or keeps the existing texture when it already matches. Returns true
	// when the texture was (re)created, which means every layer is blank and the
	// caller must upload all of them. Returns false when only changed layers need
	// an update(), so a one-region change costs a one-layer upload.
	bool ensure_layers(const Ref<Image> &p_blank, const int p_layers);
	void update(const Ref<Image> &p_image, const int p_layer);
	RID create(const Ref<Image> &p_image);
	Ref<Image> get_image() const { return _image; }
	RID get_rid() const { return _rid; }
	int size() const { return _size; }
	int get_layer_count() const { return _size; }
	Vector2i get_layer_size() const { return _layer_size; }
	int get_create_count() const { return _create_count; }
	int get_update_count() const { return _update_count; }
	void reset_counters() {
		_create_count = 0;
		_update_count = 0;
	}
};

#endif // GENERATEDTEXTURE_CLASS_H
