// Copyright © 2026 Feng contributors. MIT license.
#pragma once

#include <godot_cpp/classes/image.hpp>

// Portable authoring-time encoder. Runtime page encoding still runs on the GPU.
godot::Ref<godot::Image> terrain_encode_bc7(const godot::Ref<godot::Image> &p_image, bool p_normal);
