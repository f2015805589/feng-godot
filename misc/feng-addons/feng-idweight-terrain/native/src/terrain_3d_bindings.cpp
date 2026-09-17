// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// ClassDB bindings, property registration and the node's exposed groups. Split out
// of terrain_3d.cpp so the class surface can be read without the implementation.

#include "terrain_3d.h"

#include "logger.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_util.h"
#include "terrain_3d_vt_visibility.h"

#include <godot_cpp/classes/compositor.hpp>
#include <godot_cpp/classes/directional_light3d.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/surface_tool.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/world3d.hpp>

void Terrain3D::_bind_methods() {
	_bind_vt_methods();
	BIND_ENUM_CONSTANT(ERROR);
	BIND_ENUM_CONSTANT(INFO);
	BIND_ENUM_CONSTANT(DEBUG);
	BIND_ENUM_CONSTANT(EXTREME);

	BIND_ENUM_CONSTANT(SIZE_64);
	BIND_ENUM_CONSTANT(SIZE_128);
	BIND_ENUM_CONSTANT(SIZE_256);
	BIND_ENUM_CONSTANT(SIZE_512);
	BIND_ENUM_CONSTANT(SIZE_1024);
	BIND_ENUM_CONSTANT(SIZE_2048);

	// The vocabulary the two page compression settings are written in, so a script reads
	// `Terrain3D.SURFACE_PAGE_BC7` instead of a bare 1. It is not the asset array enum: see
	// SurfacePageCompression for why a page has three options and an authored array has more.
	BIND_ENUM_CONSTANT(SURFACE_PAGE_UNCOMPRESSED);
	BIND_ENUM_CONSTANT(SURFACE_PAGE_BC7);
	BIND_ENUM_CONSTANT(SURFACE_PAGE_BC3);
	BIND_ENUM_CONSTANT(SURFACE_PAGE_COUNT);

	ClassDB::bind_method(D_METHOD("get_version"), &Terrain3D::get_version);
	ClassDB::bind_method(D_METHOD("set_debug_level", "level"), &Terrain3D::set_debug_level);
	ClassDB::bind_method(D_METHOD("get_debug_level"), &Terrain3D::get_debug_level);
	ClassDB::bind_method(D_METHOD("set_data_directory", "directory"), &Terrain3D::set_data_directory);
	ClassDB::bind_method(D_METHOD("get_data_directory"), &Terrain3D::get_data_directory);

	// Object references
	ClassDB::bind_method(D_METHOD("get_data"), &Terrain3D::get_data);
	ClassDB::bind_method(D_METHOD("set_material", "material"), &Terrain3D::set_material);
	ClassDB::bind_method(D_METHOD("get_material"), &Terrain3D::get_material);
	ClassDB::bind_method(D_METHOD("set_assets", "assets"), &Terrain3D::set_assets);
	ClassDB::bind_method(D_METHOD("get_assets"), &Terrain3D::get_assets);
	ClassDB::bind_method(D_METHOD("get_collision"), &Terrain3D::get_collision);
	ClassDB::bind_method(D_METHOD("get_instancer"), &Terrain3D::get_instancer);
	ClassDB::bind_method(D_METHOD("get_streamer"), &Terrain3D::get_streamer);
	ClassDB::bind_method(D_METHOD("set_streaming_enabled", "enabled"), &Terrain3D::set_streaming_enabled);
	ClassDB::bind_method(D_METHOD("is_streaming_enabled"), &Terrain3D::is_streaming_enabled);
	ClassDB::bind_method(D_METHOD("get_surface_vt"), &Terrain3D::get_surface_vt);
	ClassDB::bind_method(D_METHOD("set_surface_vt_enabled", "enabled"), &Terrain3D::set_surface_vt_enabled);
	ClassDB::bind_method(D_METHOD("is_surface_vt_enabled"), &Terrain3D::is_surface_vt_enabled);
	ClassDB::bind_method(D_METHOD("set_surface_vt_page_count", "count"), &Terrain3D::set_surface_vt_page_count);
	ClassDB::bind_method(D_METHOD("get_surface_vt_page_count"), &Terrain3D::get_surface_vt_page_count);
	ClassDB::bind_method(D_METHOD("set_surface_vt_page_size", "size"), &Terrain3D::set_surface_vt_page_size);
	ClassDB::bind_method(D_METHOD("get_surface_vt_page_size"), &Terrain3D::get_surface_vt_page_size);
	ClassDB::bind_method(D_METHOD("set_surface_vt_page_border", "border"), &Terrain3D::set_surface_vt_page_border);
	ClassDB::bind_method(D_METHOD("get_surface_vt_page_border"), &Terrain3D::get_surface_vt_page_border);
	ClassDB::bind_method(D_METHOD("set_surface_vt_pages_per_axis", "pages"), &Terrain3D::set_surface_vt_pages_per_axis);
	ClassDB::bind_method(D_METHOD("get_surface_vt_pages_per_axis"), &Terrain3D::get_surface_vt_pages_per_axis);
	ClassDB::bind_method(D_METHOD("set_surface_vt_resolution", "resolution"), &Terrain3D::set_surface_vt_resolution);
	ClassDB::bind_method(D_METHOD("get_surface_vt_resolution"), &Terrain3D::get_surface_vt_resolution);
	ClassDB::bind_method(D_METHOD("set_surface_vt_distance", "distance"), &Terrain3D::set_surface_vt_distance);
	ClassDB::bind_method(D_METHOD("get_surface_vt_distance"), &Terrain3D::get_surface_vt_distance);
	ClassDB::bind_method(D_METHOD("set_surface_vt_region_grid", "grid"), &Terrain3D::set_surface_vt_region_grid);
	ClassDB::bind_method(D_METHOD("get_surface_vt_region_grid"), &Terrain3D::get_surface_vt_region_grid);
	ClassDB::bind_method(D_METHOD("set_surface_vt_selection_mode", "mode"), &Terrain3D::set_surface_vt_selection_mode);
	ClassDB::bind_method(D_METHOD("get_surface_vt_selection_mode"), &Terrain3D::get_surface_vt_selection_mode);
	ClassDB::bind_method(D_METHOD("set_surface_vt_region_offset", "offset"), &Terrain3D::set_surface_vt_region_offset);
	ClassDB::bind_method(D_METHOD("get_surface_vt_region_offset"), &Terrain3D::get_surface_vt_region_offset);
	ClassDB::bind_method(D_METHOD("set_surface_vt_forward_regions", "regions"), &Terrain3D::set_surface_vt_forward_regions);
	ClassDB::bind_method(D_METHOD("get_surface_vt_forward_regions"), &Terrain3D::get_surface_vt_forward_regions);
	ClassDB::bind_method(D_METHOD("set_vt_atlas_compression", "compression"), &Terrain3D::set_vt_atlas_compression);
	ClassDB::bind_method(D_METHOD("get_vt_atlas_compression"), &Terrain3D::get_vt_atlas_compression);
	ClassDB::bind_method(D_METHOD("probe_vt_atlas_compression", "image"), &Terrain3D::probe_vt_atlas_compression);
	ClassDB::bind_method(D_METHOD("set_surface_vt_compression", "compression"), &Terrain3D::set_surface_vt_compression);
	ClassDB::bind_method(D_METHOD("get_surface_vt_compression"), &Terrain3D::get_surface_vt_compression);
	ClassDB::bind_method(D_METHOD("set_surface_svt_compression", "compression"), &Terrain3D::set_surface_svt_compression);
	ClassDB::bind_method(D_METHOD("get_surface_svt_compression"), &Terrain3D::get_surface_svt_compression);
	ClassDB::bind_method(D_METHOD("get_surface_vt_region_rect"), &Terrain3D::get_surface_vt_region_rect);
	ClassDB::bind_method(D_METHOD("set_surface_vt_texels_per_pixel", "value"), &Terrain3D::set_surface_vt_texels_per_pixel);
	ClassDB::bind_method(D_METHOD("get_surface_vt_texels_per_pixel"), &Terrain3D::get_surface_vt_texels_per_pixel);
	ClassDB::bind_method(D_METHOD("set_surface_vt_force_mip", "enabled", "mip"), &Terrain3D::set_surface_vt_force_mip, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("is_surface_vt_force_mip"), &Terrain3D::is_surface_vt_force_mip);
	ClassDB::bind_method(D_METHOD("get_surface_vt_mip"), &Terrain3D::get_surface_vt_mip);
	ClassDB::bind_method(D_METHOD("set_surface_vt_feedback_enabled", "enabled"), &Terrain3D::set_surface_vt_feedback_enabled);
	ClassDB::bind_method(D_METHOD("is_surface_vt_feedback_enabled"), &Terrain3D::is_surface_vt_feedback_enabled);
	ClassDB::bind_method(D_METHOD("set_surface_vt_feedback_interval", "updates"), &Terrain3D::set_surface_vt_feedback_interval);
	ClassDB::bind_method(D_METHOD("get_surface_vt_feedback_interval"), &Terrain3D::get_surface_vt_feedback_interval);
	ClassDB::bind_method(D_METHOD("set_surface_vt_feedback_grid_chunks", "chunks"), &Terrain3D::set_surface_vt_feedback_grid_chunks);
	ClassDB::bind_method(D_METHOD("get_surface_vt_feedback_grid_chunks"), &Terrain3D::get_surface_vt_feedback_grid_chunks);
	ClassDB::bind_method(D_METHOD("set_surface_vt_feedback_min_extent", "extent"), &Terrain3D::set_surface_vt_feedback_min_extent);
	ClassDB::bind_method(D_METHOD("get_surface_vt_feedback_min_extent"), &Terrain3D::get_surface_vt_feedback_min_extent);
	ClassDB::bind_method(D_METHOD("get_surface_vt_feedback"), &Terrain3D::get_surface_vt_feedback);
	ClassDB::bind_method(D_METHOD("update_surface_vt", "max_pages"), &Terrain3D::update_surface_vt, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_surface_svt"), &Terrain3D::get_surface_svt);
	ClassDB::bind_method(D_METHOD("set_surface_svt_enabled", "enabled"), &Terrain3D::set_surface_svt_enabled);
	ClassDB::bind_method(D_METHOD("is_surface_svt_enabled"), &Terrain3D::is_surface_svt_enabled);
	ClassDB::bind_method(D_METHOD("set_surface_vt_texels_per_meter", "value"), &Terrain3D::set_surface_vt_texels_per_meter);
	ClassDB::bind_method(D_METHOD("get_surface_vt_texels_per_meter"), &Terrain3D::get_surface_vt_texels_per_meter);
	ClassDB::bind_method(D_METHOD("set_surface_svt_texels_per_meter", "value"), &Terrain3D::set_surface_svt_texels_per_meter);
	ClassDB::bind_method(D_METHOD("get_surface_svt_texels_per_meter"), &Terrain3D::get_surface_svt_texels_per_meter);
	ClassDB::bind_method(D_METHOD("set_surface_vt_mip_distances", "distances"), &Terrain3D::set_surface_vt_mip_distances);
	ClassDB::bind_method(D_METHOD("get_surface_vt_mip_distances"), &Terrain3D::get_surface_vt_mip_distances);
	ClassDB::bind_method(D_METHOD("get_surface_vt_mip_for_distance", "distance"), &Terrain3D::get_surface_vt_mip_for_distance);
	ClassDB::bind_method(D_METHOD("set_surface_svt_page_world", "size"), &Terrain3D::set_surface_svt_page_world);
	ClassDB::bind_method(D_METHOD("get_surface_svt_page_world"), &Terrain3D::get_surface_svt_page_world);
	ClassDB::bind_method(D_METHOD("set_surface_svt_page_size", "size"), &Terrain3D::set_surface_svt_page_size);
	ClassDB::bind_method(D_METHOD("get_surface_svt_page_size"), &Terrain3D::get_surface_svt_page_size);
	ClassDB::bind_method(D_METHOD("set_surface_svt_page_border", "border"), &Terrain3D::set_surface_svt_page_border);
	ClassDB::bind_method(D_METHOD("get_surface_svt_page_border"), &Terrain3D::get_surface_svt_page_border);
	ClassDB::bind_method(D_METHOD("set_surface_svt_page_count", "count"), &Terrain3D::set_surface_svt_page_count);
	ClassDB::bind_method(D_METHOD("get_surface_svt_page_count"), &Terrain3D::get_surface_svt_page_count);
	ClassDB::bind_method(D_METHOD("set_surface_svt_max_mip", "mip"), &Terrain3D::set_surface_svt_max_mip);
	ClassDB::bind_method(D_METHOD("get_surface_svt_max_mip"), &Terrain3D::get_surface_svt_max_mip);
	ClassDB::bind_method(D_METHOD("set_surface_svt_distance", "distance"), &Terrain3D::set_surface_svt_distance);
	ClassDB::bind_method(D_METHOD("get_surface_svt_distance"), &Terrain3D::get_surface_svt_distance);
	ClassDB::bind_method(D_METHOD("update_surface_svt", "max_pages"), &Terrain3D::update_surface_svt, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_surface_svt_root_mips", "mips"), &Terrain3D::set_surface_svt_root_mips);
	ClassDB::bind_method(D_METHOD("get_surface_svt_root_mips"), &Terrain3D::get_surface_svt_root_mips);
	ClassDB::bind_method(D_METHOD("set_surface_svt_mip_distances", "distances"), &Terrain3D::set_surface_svt_mip_distances);
	ClassDB::bind_method(D_METHOD("get_surface_svt_mip_distances"), &Terrain3D::get_surface_svt_mip_distances);
	ClassDB::bind_method(D_METHOD("get_surface_svt_mip_distance_count"), &Terrain3D::get_surface_svt_mip_distance_count);
	ClassDB::bind_method(D_METHOD("get_surface_svt_mip_for_distance", "distance", "max_mip"), &Terrain3D::get_surface_svt_mip_for_distance, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("get_surface_svt_mip_reach"), &Terrain3D::get_surface_svt_mip_reach);
	ClassDB::bind_method(D_METHOD("set_surface_array_enabled", "enabled"), &Terrain3D::set_surface_array_enabled);
	ClassDB::bind_method(D_METHOD("is_surface_array_enabled"), &Terrain3D::is_surface_array_enabled);
	ClassDB::bind_method(D_METHOD("invalidate_surface_pages", "region_location", "force"), &Terrain3D::invalidate_surface_pages, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("set_editor", "editor"), &Terrain3D::set_editor);
	ClassDB::bind_method(D_METHOD("get_editor"), &Terrain3D::get_editor);
	ClassDB::bind_method(D_METHOD("set_plugin", "plugin"), &Terrain3D::set_plugin);
	ClassDB::bind_method(D_METHOD("get_plugin"), &Terrain3D::get_plugin);

	// Regions
	ClassDB::bind_method(D_METHOD("change_region_size", "size"), &Terrain3D::change_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Terrain3D::get_region_size);
	ClassDB::bind_method(D_METHOD("set_surface_density", "density"), &Terrain3D::set_surface_density);
	ClassDB::bind_method(D_METHOD("get_surface_density"), &Terrain3D::get_surface_density);
	ClassDB::bind_method(D_METHOD("change_surface_density", "density"), &Terrain3D::change_surface_density);
	ClassDB::bind_method(D_METHOD("set_save_16_bit", "enabled"), &Terrain3D::set_save_16_bit);
	ClassDB::bind_method(D_METHOD("get_save_16_bit"), &Terrain3D::get_save_16_bit);
	ClassDB::bind_method(D_METHOD("set_label_distance", "distance"), &Terrain3D::set_label_distance);
	ClassDB::bind_method(D_METHOD("get_label_distance"), &Terrain3D::get_label_distance);
	ClassDB::bind_method(D_METHOD("set_label_size", "size"), &Terrain3D::set_label_size);
	ClassDB::bind_method(D_METHOD("get_label_size"), &Terrain3D::get_label_size);

	// Target Tracking
	ClassDB::bind_method(D_METHOD("set_camera", "camera"), &Terrain3D::set_camera);
	ClassDB::bind_method(D_METHOD("get_camera"), &Terrain3D::get_camera);
	ClassDB::bind_method(D_METHOD("set_clipmap_target", "node"), &Terrain3D::set_clipmap_target);
	ClassDB::bind_method(D_METHOD("get_clipmap_target"), &Terrain3D::get_clipmap_target);
	ClassDB::bind_method(D_METHOD("get_clipmap_target_position"), &Terrain3D::get_clipmap_target_position);
	ClassDB::bind_method(D_METHOD("set_collision_target", "node"), &Terrain3D::set_collision_target);
	ClassDB::bind_method(D_METHOD("get_collision_target"), &Terrain3D::get_collision_target);
	ClassDB::bind_method(D_METHOD("get_collision_target_position"), &Terrain3D::get_collision_target_position);
	ClassDB::bind_method(D_METHOD("set_light_target", "node"), &Terrain3D::set_light_target);
	ClassDB::bind_method(D_METHOD("get_light_target"), &Terrain3D::get_light_target);
	ClassDB::bind_method(D_METHOD("snap"), &Terrain3D::snap);

	// Collision
	ClassDB::bind_method(D_METHOD("set_collision_mode", "mode"), &Terrain3D::set_collision_mode);
	ClassDB::bind_method(D_METHOD("get_collision_mode"), &Terrain3D::get_collision_mode);
	ClassDB::bind_method(D_METHOD("set_collision_shape_size", "size"), &Terrain3D::set_collision_shape_size);
	ClassDB::bind_method(D_METHOD("get_collision_shape_size"), &Terrain3D::get_collision_shape_size);
	ClassDB::bind_method(D_METHOD("set_collision_radius", "radius"), &Terrain3D::set_collision_radius);
	ClassDB::bind_method(D_METHOD("get_collision_radius"), &Terrain3D::get_collision_radius);
	ClassDB::bind_method(D_METHOD("set_collision_layer", "layers"), &Terrain3D::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &Terrain3D::get_collision_layer);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Terrain3D::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Terrain3D::get_collision_mask);
	ClassDB::bind_method(D_METHOD("set_collision_priority", "priority"), &Terrain3D::set_collision_priority);
	ClassDB::bind_method(D_METHOD("get_collision_priority"), &Terrain3D::get_collision_priority);
	ClassDB::bind_method(D_METHOD("set_physics_material", "material"), &Terrain3D::set_physics_material);
	ClassDB::bind_method(D_METHOD("get_physics_material"), &Terrain3D::get_physics_material);

	// Terrain Mesh
	ClassDB::bind_method(D_METHOD("set_cdlod_enabled", "enabled"), &Terrain3D::set_cdlod_enabled);
	ClassDB::bind_method(D_METHOD("is_cdlod_enabled"), &Terrain3D::is_cdlod_enabled);
	ClassDB::bind_method(D_METHOD("set_cdlod_patch_size", "size"), &Terrain3D::set_cdlod_patch_size);
	ClassDB::bind_method(D_METHOD("get_cdlod_patch_size"), &Terrain3D::get_cdlod_patch_size);
	ClassDB::bind_method(D_METHOD("set_cdlod_lod_scale", "scale"), &Terrain3D::set_cdlod_lod_scale);
	ClassDB::bind_method(D_METHOD("get_cdlod_lod_scale"), &Terrain3D::get_cdlod_lod_scale);
	ClassDB::bind_method(D_METHOD("get_cdlod_stats"), &Terrain3D::get_cdlod_stats);
	ClassDB::bind_method(D_METHOD("set_mesh_lods", "count"), &Terrain3D::set_mesh_lods);
	ClassDB::bind_method(D_METHOD("get_mesh_lods"), &Terrain3D::get_mesh_lods);
	ClassDB::bind_method(D_METHOD("set_mesh_size", "size"), &Terrain3D::set_mesh_size);
	ClassDB::bind_method(D_METHOD("get_mesh_size"), &Terrain3D::get_mesh_size);
	ClassDB::bind_method(D_METHOD("set_tessellation_level", "size"), &Terrain3D::set_tessellation_level);
	ClassDB::bind_method(D_METHOD("get_tessellation_level"), &Terrain3D::get_tessellation_level);
	ClassDB::bind_method(D_METHOD("set_vertex_spacing", "scale"), &Terrain3D::set_vertex_spacing);
	ClassDB::bind_method(D_METHOD("get_vertex_spacing"), &Terrain3D::get_vertex_spacing);
	ClassDB::bind_method(D_METHOD("set_cull_margin", "margin"), &Terrain3D::set_cull_margin);
	ClassDB::bind_method(D_METHOD("get_cull_margin"), &Terrain3D::get_cull_margin);
	ClassDB::bind_method(D_METHOD("set_cast_shadows", "shadow_casting_setting"), &Terrain3D::set_cast_shadows);
	ClassDB::bind_method(D_METHOD("get_cast_shadows"), &Terrain3D::get_cast_shadows);
	ClassDB::bind_method(D_METHOD("set_gi_mode", "gi_mode"), &Terrain3D::set_gi_mode);
	ClassDB::bind_method(D_METHOD("get_gi_mode"), &Terrain3D::get_gi_mode);
	ClassDB::bind_method(D_METHOD("set_render_layers", "layers"), &Terrain3D::set_render_layers);
	ClassDB::bind_method(D_METHOD("get_render_layers"), &Terrain3D::get_render_layers);

	// Terrain Displacement
	ClassDB::bind_method(D_METHOD("set_displacement_scale", "scale"), &Terrain3D::set_displacement_scale);
	ClassDB::bind_method(D_METHOD("get_displacement_scale"), &Terrain3D::get_displacement_scale);
	ClassDB::bind_method(D_METHOD("set_displacement_sharpness", "sharpness"), &Terrain3D::set_displacement_sharpness);
	ClassDB::bind_method(D_METHOD("get_displacement_sharpness"), &Terrain3D::get_displacement_sharpness);
	ClassDB::bind_method(D_METHOD("set_buffer_shader_override_enabled", "enabled"), &Terrain3D::set_buffer_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("is_buffer_shader_override_enabled"), &Terrain3D::is_buffer_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_buffer_shader_override", "shader"), &Terrain3D::set_buffer_shader_override);
	ClassDB::bind_method(D_METHOD("get_buffer_shader_override"), &Terrain3D::get_buffer_shader_override);

	// Ocean Mesh
	ClassDB::bind_method(D_METHOD("set_ocean_enabled", "enabled"), &Terrain3D::set_ocean_enabled);
	ClassDB::bind_method(D_METHOD("is_ocean_enabled"), &Terrain3D::is_ocean_enabled);
	ClassDB::bind_method(D_METHOD("set_ocean_mesh_lods", "count"), &Terrain3D::set_ocean_mesh_lods);
	ClassDB::bind_method(D_METHOD("get_ocean_mesh_lods"), &Terrain3D::get_ocean_mesh_lods);
	ClassDB::bind_method(D_METHOD("set_ocean_tessellation_level", "size"), &Terrain3D::set_ocean_tessellation_level);
	ClassDB::bind_method(D_METHOD("get_ocean_tessellation_level"), &Terrain3D::get_ocean_tessellation_level);
	ClassDB::bind_method(D_METHOD("set_ocean_mesh_size", "size"), &Terrain3D::set_ocean_mesh_size);
	ClassDB::bind_method(D_METHOD("get_ocean_mesh_size"), &Terrain3D::get_ocean_mesh_size);
	ClassDB::bind_method(D_METHOD("set_ocean_vertex_spacing", "scale"), &Terrain3D::set_ocean_vertex_spacing);
	ClassDB::bind_method(D_METHOD("get_ocean_vertex_spacing"), &Terrain3D::get_ocean_vertex_spacing);
	ClassDB::bind_method(D_METHOD("set_ocean_cull_margin", "margin"), &Terrain3D::set_ocean_cull_margin);
	ClassDB::bind_method(D_METHOD("get_ocean_cull_margin"), &Terrain3D::get_ocean_cull_margin);
	ClassDB::bind_method(D_METHOD("set_ocean_cast_shadows", "shadow_casting_setting"), &Terrain3D::set_ocean_cast_shadows);
	ClassDB::bind_method(D_METHOD("get_ocean_cast_shadows"), &Terrain3D::get_ocean_cast_shadows);
	ClassDB::bind_method(D_METHOD("set_ocean_gi_mode", "gi_mode"), &Terrain3D::set_ocean_gi_mode);
	ClassDB::bind_method(D_METHOD("get_ocean_gi_mode"), &Terrain3D::get_ocean_gi_mode);
	ClassDB::bind_method(D_METHOD("set_ocean_render_layers", "layers"), &Terrain3D::set_ocean_render_layers);
	ClassDB::bind_method(D_METHOD("get_ocean_render_layers"), &Terrain3D::get_ocean_render_layers);
	ClassDB::bind_method(D_METHOD("set_ocean_material", "material"), &Terrain3D::set_ocean_material);
	ClassDB::bind_method(D_METHOD("get_ocean_material"), &Terrain3D::get_ocean_material);

	// Rendering
	ClassDB::bind_method(D_METHOD("set_mouse_layer", "layer"), &Terrain3D::set_mouse_layer);
	ClassDB::bind_method(D_METHOD("get_mouse_layer"), &Terrain3D::get_mouse_layer);
	ClassDB::bind_method(D_METHOD("set_free_editor_textures"), &Terrain3D::set_free_editor_textures);
	ClassDB::bind_method(D_METHOD("get_free_editor_textures"), &Terrain3D::get_free_editor_textures);
	ClassDB::bind_method(D_METHOD("set_instancer_mode", "mode"), &Terrain3D::set_instancer_mode);
	ClassDB::bind_method(D_METHOD("get_instancer_mode"), &Terrain3D::get_instancer_mode);

	// Overlays
	ClassDB::bind_method(D_METHOD("set_show_region_grid", "enabled"), &Terrain3D::set_show_region_grid);
	ClassDB::bind_method(D_METHOD("get_show_region_grid"), &Terrain3D::get_show_region_grid);
	ClassDB::bind_method(D_METHOD("set_show_instancer_grid", "enabled"), &Terrain3D::set_show_instancer_grid);
	ClassDB::bind_method(D_METHOD("get_show_instancer_grid"), &Terrain3D::get_show_instancer_grid);
	ClassDB::bind_method(D_METHOD("set_show_vertex_grid", "enabled"), &Terrain3D::set_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("get_show_vertex_grid"), &Terrain3D::get_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("set_show_contours", "enabled"), &Terrain3D::set_show_contours);
	ClassDB::bind_method(D_METHOD("get_show_contours"), &Terrain3D::get_show_contours);
	ClassDB::bind_method(D_METHOD("set_show_slope", "enabled"), &Terrain3D::set_show_slope);
	ClassDB::bind_method(D_METHOD("get_show_slope"), &Terrain3D::get_show_slope);
	ClassDB::bind_method(D_METHOD("set_show_navigation", "enabled"), &Terrain3D::set_show_navigation);
	ClassDB::bind_method(D_METHOD("get_show_navigation"), &Terrain3D::get_show_navigation);

	// Debug Views
	ClassDB::bind_method(D_METHOD("set_show_checkered", "enabled"), &Terrain3D::set_show_checkered);
	ClassDB::bind_method(D_METHOD("get_show_checkered"), &Terrain3D::get_show_checkered);
	ClassDB::bind_method(D_METHOD("set_show_grey", "enabled"), &Terrain3D::set_show_grey);
	ClassDB::bind_method(D_METHOD("get_show_grey"), &Terrain3D::get_show_grey);
	ClassDB::bind_method(D_METHOD("set_show_heightmap", "enabled"), &Terrain3D::set_show_heightmap);
	ClassDB::bind_method(D_METHOD("get_show_heightmap"), &Terrain3D::get_show_heightmap);
	ClassDB::bind_method(D_METHOD("set_show_jaggedness", "enabled"), &Terrain3D::set_show_jaggedness);
	ClassDB::bind_method(D_METHOD("get_show_jaggedness"), &Terrain3D::get_show_jaggedness);
	ClassDB::bind_method(D_METHOD("set_show_autoshader", "enabled"), &Terrain3D::set_show_autoshader);
	ClassDB::bind_method(D_METHOD("get_show_autoshader"), &Terrain3D::get_show_autoshader);
	ClassDB::bind_method(D_METHOD("set_show_control_texture", "enabled"), &Terrain3D::set_show_control_texture);
	ClassDB::bind_method(D_METHOD("get_show_control_texture"), &Terrain3D::get_show_control_texture);
	ClassDB::bind_method(D_METHOD("set_show_control_blend", "enabled"), &Terrain3D::set_show_control_blend);
	ClassDB::bind_method(D_METHOD("get_show_control_blend"), &Terrain3D::get_show_control_blend);
	ClassDB::bind_method(D_METHOD("set_show_control_angle", "enabled"), &Terrain3D::set_show_control_angle);
	ClassDB::bind_method(D_METHOD("get_show_control_angle"), &Terrain3D::get_show_control_angle);
	ClassDB::bind_method(D_METHOD("set_show_control_scale", "enabled"), &Terrain3D::set_show_control_scale);
	ClassDB::bind_method(D_METHOD("get_show_control_scale"), &Terrain3D::get_show_control_scale);
	ClassDB::bind_method(D_METHOD("set_show_colormap", "enabled"), &Terrain3D::set_show_colormap);
	ClassDB::bind_method(D_METHOD("get_show_colormap"), &Terrain3D::get_show_colormap);
	ClassDB::bind_method(D_METHOD("set_show_roughmap", "enabled"), &Terrain3D::set_show_roughmap);
	ClassDB::bind_method(D_METHOD("get_show_roughmap"), &Terrain3D::get_show_roughmap);
	ClassDB::bind_method(D_METHOD("set_show_displacement_buffer", "enabled"), &Terrain3D::set_show_displacement_buffer);
	ClassDB::bind_method(D_METHOD("get_show_displacement_buffer"), &Terrain3D::get_show_displacement_buffer);

	// PBR Views
	ClassDB::bind_method(D_METHOD("set_show_texture_albedo", "enabled"), &Terrain3D::set_show_texture_albedo);
	ClassDB::bind_method(D_METHOD("get_show_texture_albedo"), &Terrain3D::get_show_texture_albedo);
	ClassDB::bind_method(D_METHOD("set_show_texture_height", "enabled"), &Terrain3D::set_show_texture_height);
	ClassDB::bind_method(D_METHOD("get_show_texture_height"), &Terrain3D::get_show_texture_height);
	ClassDB::bind_method(D_METHOD("set_show_texture_normal", "enabled"), &Terrain3D::set_show_texture_normal);
	ClassDB::bind_method(D_METHOD("get_show_texture_normal"), &Terrain3D::get_show_texture_normal);
	ClassDB::bind_method(D_METHOD("set_show_texture_rough", "enabled"), &Terrain3D::set_show_texture_rough);
	ClassDB::bind_method(D_METHOD("get_show_texture_rough"), &Terrain3D::get_show_texture_rough);
	ClassDB::bind_method(D_METHOD("set_show_texture_ao", "enabled"), &Terrain3D::set_show_texture_ao);
	ClassDB::bind_method(D_METHOD("get_show_texture_ao"), &Terrain3D::get_show_texture_ao);

	// Utility
	ClassDB::bind_method(D_METHOD("get_intersection", "src_pos", "direction", "gpu_mode"), &Terrain3D::get_intersection, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_raycast_result", "src_pos", "direction", "collision_mask", "exclude_terrain"),
			&Terrain3D::get_raycast_result, DEFVAL(0xFFFFFFFF), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("bake_mesh", "lod", "filter"), &Terrain3D::bake_mesh, DEFVAL(Terrain3DData::HEIGHT_FILTER_NEAREST));
	ClassDB::bind_method(D_METHOD("generate_nav_mesh_source_geometry", "global_aabb", "require_nav"), &Terrain3D::generate_nav_mesh_source_geometry, DEFVAL(true));

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "version", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "debug_level", PROPERTY_HINT_ENUM, "Errors,Info,Debug,Extreme"), "set_debug_level", "get_debug_level");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "data_directory", PROPERTY_HINT_DIR), "set_data_directory", "get_data_directory");

	// Object references
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "material", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DMaterial"), "set_material", "get_material");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "assets", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DAssets"), "set_assets", "get_assets");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "data", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY, "Terrain3DData"), "", "get_data");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "collision", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Terrain3DCollision"), "", "get_collision");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "instancer", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Terrain3DInstancer"), "", "get_instancer");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "streamer", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Terrain3DStreamer"), "", "get_streamer");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "streaming_enabled"), "set_streaming_enabled", "is_streaming_enabled");
	ADD_GROUP("Surface VT", "");
	ADD_SUBGROUP("VT Setting", "vt_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_page_size", PROPERTY_HINT_RANGE, "16,1024,16"), "set_vt_page_size", "get_vt_page_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_page_border", PROPERTY_HINT_RANGE, "1,16,1"), "set_vt_page_border", "get_vt_page_border");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_page_count", PROPERTY_HINT_RANGE, "8,1024,1"), "set_vt_page_count", "get_vt_page_count");
	// Storage format of the three material page arrays, per tier; the live settings are
	// `surface_vt_compression` (near field) and `surface_svt_compression` (far field) inside
	// their own groups below. The list is short on purpose and names exactly what can store a
	// page: BC7 and BC3 (the two RGBA codecs this build's GPU block encoder implements) plus
	// uncompressed, which samples the staging arrays directly. A page carries height,
	// roughness and its validity bit in alpha, so a codec that keeps no alpha cannot hold one,
	// and page compression never runs a CPU block encoder - a codec that no shader here
	// encodes has no producer at all. Both of those used to be inspector entries that resolved
	// to uncompressed; they are not offered any more.
	//
	// They are separate settings because the tiers produce at very different rates. An AVT
	// page is rewritten by every edit that invalidates it; an SVT page is assembled once from
	// a baked cell and then never rewritten, so compressing it is paid once and the memory is
	// saved for the rest of the session.
	//
	// The pre-split name stays a script-visible alias for the near field and is hidden from
	// the inspector, so a scene saved against it keeps working.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_atlas_compression", PROPERTY_HINT_ENUM, "Uncompressed,BC7,BC3 RGBA", PROPERTY_USAGE_NONE), "set_vt_atlas_compression", "get_vt_atlas_compression");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "vt_auto_capacity"), "set_vt_auto_capacity", "get_vt_auto_capacity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_pages_per_update", PROPERTY_HINT_RANGE, "1,16,1"), "set_vt_pages_per_update", "get_vt_pages_per_update");
	// Source threads that assemble pages: 0 = auto (half the machine, 1..4).
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_page_workers", PROPERTY_HINT_RANGE, "0,16,1"), "set_vt_page_workers", "get_vt_page_workers");
	// Motion look-ahead in milliseconds: the demand plans for where the camera will be,
	// so a page is produced before the view reaches it. 0 disables the prediction.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "vt_motion_lead_ms", PROPERTY_HINT_RANGE, "0,1000,1"), "set_vt_motion_lead_ms", "get_vt_motion_lead_ms");
	ClassDB::bind_method(D_METHOD("set_vt_page_fade_frames", "frames"), &Terrain3D::set_vt_page_fade_frames);
	ClassDB::bind_method(D_METHOD("get_vt_page_fade_frames"), &Terrain3D::get_vt_page_fade_frames);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "vt_frame_budget_ms", PROPERTY_HINT_RANGE, "0,16,0.01"), "set_vt_frame_budget_ms", "get_vt_frame_budget_ms");
	// How long a page takes to come in, in ticks. A page that has just arrived is blended
	// against the level it replaced, so a page arrival is a sharpen rather than a
	// rectangular step. 0 disables it, which is what a caller who wants the strict
	// "the page that is published is the page that is drawn" contract sets.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_page_fade_frames", PROPERTY_HINT_RANGE, "0,60,1"), "set_vt_page_fade_frames", "get_vt_page_fade_frames");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "vt_editor_preview"), "set_vt_editor_preview", "is_vt_editor_preview");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "vt_debug_direct_material"), "set_vt_debug_direct_material", "is_vt_debug_direct_material");
	ADD_SUBGROUP("", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_array_enabled"), "set_surface_array_enabled", "is_surface_array_enabled");
	ADD_SUBGROUP("AVT", "surface_vt_");
	// The subgroup strips `surface_vt_`, so the Inspector shows exactly `Feedback`.
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_vt_feedback"), "set_avt_feedback", "get_avt_feedback");
	// Near-field page storage. AVT pages are rewritten by every edit that invalidates them,
	// so this codec is paid per production; the GPU block encoder keeps that cost off the CPU.
	// See the shared comment on `vt_atlas_compression` for why the list has three entries.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_compression", PROPERTY_HINT_ENUM, "Uncompressed,BC7,BC3 RGBA"), "set_surface_vt_compression", "get_surface_vt_compression");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_resolution", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_surface_vt_resolution", "get_surface_vt_resolution");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_vt_texels_per_meter", PROPERTY_HINT_RANGE, "1,8192,1"), "set_surface_vt_texels_per_meter", "get_surface_vt_texels_per_meter");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "surface_vt_mip_distances", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_mip_distances", "get_surface_vt_mip_distances");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_vt_adaptive_enabled"), "set_vt_adaptive_enabled", "is_vt_adaptive_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "surface_vt", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Terrain3DVirtualTexture"), "", "get_surface_vt");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_vt_texels_per_pixel", PROPERTY_HINT_RANGE, "0.25,64,0.25,or_greater"), "set_surface_vt_texels_per_pixel", "get_surface_vt_texels_per_pixel");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_vt_enabled"), "set_surface_vt_enabled", "is_surface_vt_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_page_count", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_page_count", "get_surface_vt_page_count");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_page_size", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_page_size", "get_surface_vt_page_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_page_border", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_page_border", "get_surface_vt_page_border");
	// Derived from the stored page size/count: no competing serialized setting.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_pages_per_axis", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_pages_per_axis", "get_surface_vt_pages_per_axis");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_selection_mode", PROPERTY_HINT_ENUM, "Legacy Region View,Legacy Target Grid,Full AVT (64 m sectors)"), "set_surface_vt_selection_mode", "get_surface_vt_selection_mode");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "surface_vt_region_grid", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_region_grid", "get_surface_vt_region_grid");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "surface_vt_region_offset", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_region_offset", "get_surface_vt_region_offset");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_vt_forward_regions", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_forward_regions", "get_surface_vt_forward_regions");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_vt_distance", PROPERTY_HINT_RANGE, "64,4096,64,or_greater"), "set_surface_vt_distance", "get_surface_vt_distance");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_vt_feedback_enabled", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_feedback_enabled", "is_surface_vt_feedback_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_feedback_interval", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_feedback_interval", "get_surface_vt_feedback_interval");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_feedback_grid_chunks", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_feedback_grid_chunks", "get_surface_vt_feedback_grid_chunks");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_vt_feedback_min_extent", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_feedback_min_extent", "get_surface_vt_feedback_min_extent");
	ADD_SUBGROUP("SVT", "surface_svt_");
	// First in the group on purpose, mirroring the AVT group: this is the far field's
	// fallback switch. On, a miss at the level the distance rule selected is served by a
	// coarser resident level (the baked root pyramid) instead of the diagnostic material.
	// Off restores the strict walk, where a missing page stays visible as the diagnostic.
	// The subgroup strips `surface_svt_`, so this independently also shows `Feedback`.
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_svt_feedback"), "set_svt_feedback", "get_svt_feedback");
	// Far-field page storage. A far-field page is assembled once from a baked cell and then
	// never rewritten, so its compressed copy is final: this is the tier where a codec buys
	// the most memory for the least work.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_compression", PROPERTY_HINT_ENUM, "Uncompressed,BC7,BC3 RGBA"), "set_surface_svt_compression", "get_surface_svt_compression");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_svt_auto_bake"), "set_svt_auto_bake", "is_svt_auto_bake");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_svt_enabled"), "set_surface_svt_enabled", "is_surface_svt_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_svt_page_world", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_svt_page_world", "get_surface_svt_page_world");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_svt_texels_per_meter", PROPERTY_HINT_RANGE, "0.01,8192,0.01", PROPERTY_USAGE_EDITOR), "set_surface_svt_texels_per_meter", "get_surface_svt_texels_per_meter");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_page_size", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_svt_page_size", "get_surface_svt_page_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_page_border", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_svt_page_border", "get_surface_svt_page_border");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_page_count", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_svt_page_count", "get_surface_svt_page_count");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_max_mip"), "set_surface_svt_max_mip", "get_surface_svt_max_mip");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_svt_distance", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_svt_distance", "get_surface_svt_distance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_root_mips", PROPERTY_HINT_RANGE, "0,16,1"), "set_surface_svt_root_mips", "get_surface_svt_root_mips");
	// One entry per world mip level, in metres: the largest camera distance still
	// sampled at that level. Empty = automatic (one level per doubling of the page).
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "surface_svt_mip_distances", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT, "float"), "set_surface_svt_mip_distances", "get_surface_svt_mip_distances");
	ADD_SUBGROUP("CDLOD", "cdlod_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "cdlod_enabled"), "set_cdlod_enabled", "is_cdlod_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cdlod_patch_size", PROPERTY_HINT_ENUM, "8:8,16:16,32:32,64:64,128:128", PROPERTY_USAGE_STORAGE), "set_cdlod_patch_size", "get_cdlod_patch_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cdlod_lod_scale", PROPERTY_HINT_RANGE, "8,32,0.5"), "set_cdlod_lod_scale", "get_cdlod_lod_scale");
	ADD_SUBGROUP("VT Page", "vt_page_");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "vt_page_status", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_vt_settings");
	ADD_GROUP("", "");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "light_target", PROPERTY_HINT_NODE_TYPE, "DirectionalLight3D", PROPERTY_USAGE_DEFAULT, "Node3D"), "set_light_target", "get_light_target");

	ADD_GROUP("Regions", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "64:64,128:128,256:256,512:512,1024:1024,2048:2048", PROPERTY_USAGE_EDITOR), "change_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_density", PROPERTY_HINT_ENUM, "1 texel/m:1,2 texels/m:2,4 texels/m:4,8 texels/m:8", PROPERTY_USAGE_EDITOR), "change_surface_density", "get_surface_density");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "save_16_bit"), "set_save_16_bit", "get_save_16_bit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "label_distance", PROPERTY_HINT_RANGE, "0.0,10000.0,0.5,or_greater"), "set_label_distance", "get_label_distance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "label_size", PROPERTY_HINT_RANGE, "24,128,1"), "set_label_size", "get_label_size");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_grid"), "set_show_region_grid", "get_show_region_grid");

	ADD_GROUP("Collision", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mode", PROPERTY_HINT_ENUM, "Disabled,Dynamic / Game,Dynamic / Editor,Full / Game,Full / Editor"), "set_collision_mode", "get_collision_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_shape_size", PROPERTY_HINT_RANGE, "8,64,8"), "set_collision_shape_size", "get_collision_shape_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_radius", PROPERTY_HINT_RANGE, "16,256,16"), "set_collision_radius", "get_collision_radius");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "collision_target", PROPERTY_HINT_NODE_TYPE, "Node3D", PROPERTY_USAGE_DEFAULT, "Node3D"), "set_collision_target", "get_collision_target");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "collision_priority", PROPERTY_HINT_RANGE, "0.1,256,.1"), "set_collision_priority", "get_collision_priority");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "physics_material", PROPERTY_HINT_RESOURCE_TYPE, "PhysicsMaterial"), "set_physics_material", "get_physics_material");

	ADD_GROUP("Terrain Mesh", "");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "clipmap_target", PROPERTY_HINT_NODE_TYPE, "Node3D", PROPERTY_USAGE_DEFAULT, "Node3D"), "set_clipmap_target", "get_clipmap_target");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_lods", PROPERTY_HINT_RANGE, "1,10,1"), "set_mesh_lods", "get_mesh_lods");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tessellation_level", PROPERTY_HINT_RANGE, "0,6,1"), "set_tessellation_level", "get_tessellation_level");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_size", PROPERTY_HINT_RANGE, "8,256,2"), "set_mesh_size", "get_mesh_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "vertex_spacing", PROPERTY_HINT_RANGE, "0.25,10.0,or_greater"), "set_vertex_spacing", "get_vertex_spacing");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cull_margin", PROPERTY_HINT_RANGE, "0.0,10000.0,.5,or_greater"), "set_cull_margin", "get_cull_margin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cast_shadows", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_cast_shadows", "get_cast_shadows");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "gi_mode", PROPERTY_HINT_ENUM, "Disabled,Static,Dynamic"), "set_gi_mode", "get_gi_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "render_layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_render_layers", "get_render_layers");

	ADD_SUBGROUP("Displacement", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement_scale", PROPERTY_HINT_RANGE, "0.0, 2.0, 0.01"), "set_displacement_scale", "get_displacement_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement_sharpness", PROPERTY_HINT_RANGE, "0.0, 1.0, 0.01"), "set_displacement_sharpness", "get_displacement_sharpness");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "buffer_shader_override_enabled"), "set_buffer_shader_override_enabled", "is_buffer_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "buffer_shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_buffer_shader_override", "get_buffer_shader_override");

	ADD_GROUP("Ocean Mesh", "ocean_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "ocean_enabled"), "set_ocean_enabled", "is_ocean_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_mesh_lods", PROPERTY_HINT_RANGE, "1,10,1"), "set_ocean_mesh_lods", "get_ocean_mesh_lods");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_tessellation_level", PROPERTY_HINT_RANGE, "0,6,1"), "set_ocean_tessellation_level", "get_ocean_tessellation_level");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_mesh_size", PROPERTY_HINT_RANGE, "8,256,2"), "set_ocean_mesh_size", "get_ocean_mesh_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_vertex_spacing", PROPERTY_HINT_RANGE, "0.25,10.0,0.05,or_greater"), "set_ocean_vertex_spacing", "get_ocean_vertex_spacing");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_cull_margin", PROPERTY_HINT_RANGE, "0.0,10000.0,.5,or_greater"), "set_ocean_cull_margin", "get_ocean_cull_margin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_cast_shadows", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_ocean_cast_shadows", "get_ocean_cast_shadows");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_gi_mode", PROPERTY_HINT_ENUM, "Disabled,Static,Dynamic"), "set_ocean_gi_mode", "get_ocean_gi_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_render_layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_ocean_render_layers", "get_ocean_render_layers");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "ocean_material", PROPERTY_HINT_RESOURCE_TYPE, "ShaderMaterial,BaseMaterial3D"), "set_ocean_material", "get_ocean_material");

	ADD_GROUP("Rendering", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mouse_layer", PROPERTY_HINT_RANGE, "21, 32"), "set_mouse_layer", "get_mouse_layer");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "free_editor_textures"), "set_free_editor_textures", "get_free_editor_textures");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "instancer_mode", PROPERTY_HINT_ENUM, "Disabled,Normal"), "set_instancer_mode", "get_instancer_mode");

	ADD_GROUP("Overlays", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_region_grid"), "set_show_region_grid", "get_show_region_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_instancer_grid"), "set_show_instancer_grid", "get_show_instancer_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_vertex_grid"), "set_show_vertex_grid", "get_show_vertex_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_contours"), "set_show_contours", "get_show_contours");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_slope"), "set_show_slope", "get_show_slope");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_navigation"), "set_show_navigation", "get_show_navigation");

	ADD_GROUP("Debug Views", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_checkered"), "set_show_checkered", "get_show_checkered");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_grey"), "set_show_grey", "get_show_grey");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_heightmap"), "set_show_heightmap", "get_show_heightmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_jaggedness"), "set_show_jaggedness", "get_show_jaggedness");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_autoshader"), "set_show_autoshader", "get_show_autoshader");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_texture"), "set_show_control_texture", "get_show_control_texture");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_blend"), "set_show_control_blend", "get_show_control_blend");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_angle"), "set_show_control_angle", "get_show_control_angle");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_scale"), "set_show_control_scale", "get_show_control_scale");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_colormap"), "set_show_colormap", "get_show_colormap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_roughmap"), "set_show_roughmap", "get_show_roughmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_displacement_buffer"), "set_show_displacement_buffer", "get_show_displacement_buffer");

	ADD_SUBGROUP("PBR Maps", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_albedo"), "set_show_texture_albedo", "get_show_texture_albedo");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_height"), "set_show_texture_height", "get_show_texture_height");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_normal"), "set_show_texture_normal", "get_show_texture_normal");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_rough"), "set_show_texture_rough", "get_show_texture_rough");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_ao"), "set_show_texture_ao", "get_show_texture_ao");

	ADD_SIGNAL(MethodInfo("material_changed"));
	ADD_SIGNAL(MethodInfo("assets_changed"));
}
