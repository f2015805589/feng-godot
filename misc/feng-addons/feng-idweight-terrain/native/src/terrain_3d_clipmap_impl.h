// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_IMPL_H
#define TERRAIN3D_CLIPMAP_IMPL_H

// The **one contract** a clipmap implementation answers, and the reason there is one clipmap delivery
// with two implementations rather than two deliveries.
//
// Everything that reaches a fragment, a producer or a debug view is asked through this interface:
// `Terrain3DClipmap` (the toroidal level ring, "LOD") and `Terrain3DClipmapAtlas` (the block atlas)
// both implement it, and nothing above them - the tick, the assembly rule, the material's uniform
// binding, the reports, the debug payload - names either class. What differs between the two is
// storage, upload unit, rolling and layout, and that difference is private to each: no method here is
// "the ring way" or "the atlas way".
//
// The shared half of the contract is not re-declared per implementation, it is *inherited*:
//   * the density ladder and the sampling contract, from `TerrainClipmap::Ladder`;
//   * the bake-queue entry shape, from `TerrainClipmap::BakeRect`;
//   * the per-unit debug schema, from `TerrainClipmap::UnitReport`.
// An implementation supplies the numbers and the storage; it never re-spells the vocabulary.
//
// `terrain_3d_clipmap_layer.h` is the facade that selects one, configures it from the shared
// `TerrainClipmap::Shape` and forwards. Call sites therefore branch nowhere.

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>

#include "terrain_3d_clipmap_common.h"

class Terrain3DClipmapImpl {
public:
	virtual ~Terrain3DClipmapImpl() = default;

	// ---- Identity and shape ---------------------------------------------------------------------
	// Which implementation this is, so the facade, the material's arm binding and the debug view can
	// name the selected one without a downcast.
	virtual TerrainClipmap::Implementation get_implementation() const = 0;
	// The channel's own name ("height", "material"), which is what a report shows beside the shape.
	virtual String get_source_name() const = 0;
	virtual bool is_configured() const = 0;
	// Frees the implementation's storage while keeping it usable: the layer stays configurable and a
	// reconfigure rebuilds what this released. The facade's `clear()` is this, and the facade's
	// `configure()` is what builds it again.
	virtual void clear() = 0;
	virtual int get_channel_count() const = 0;
	virtual Image::Format get_format() const = 0;
	// The shape the layer was configured with, in the shared vocabulary. A report or a test that asks
	// "what is the density at 40 m" needs only this.
	virtual TerrainClipmap::Ladder get_ladder() const = 0;
	virtual int get_unit_count() const = 0;
	// The finest unit's resolution in texels an axis: the LOD ring's level size, the atlas's block
	// size. It is the number `base_world` is divided by, so it is half of the layer's density.
	virtual int get_size() const = 0;
	// The world size one unit covers: the shared ladder's answer, which an implementation states for
	// the units it actually holds (the atlas's unit is a shell of blocks, so its reach is its grid's).
	virtual real_t get_unit_world_size(const int p_unit) const = 0;

	// ---- The sampling contract ------------------------------------------------------------------
	// The unit that serves a world position, or -1 when the layer does not reach it (the LOD ring
	// outside its coarsest square; the atlas outside its grid and its global block). `sample()` answers
	// the stored value through the implementation's own addressing, and `get_texel_world_at()` the
	// density a fragment would be served there - 0 outside.
	virtual int get_unit_for_world(const Vector2 &p_world) const = 0;
	virtual real_t get_texel_world_at(const Vector2 &p_world) const = 0;
	virtual real_t sample(const Vector2 &p_world, const int p_channel = 0) const = 0;

	// ---- The tick -------------------------------------------------------------------------------
	// One update: re-derive what the focus implies, drain it under the budget, publish what drained.
	// Returns the channel texels produced.
	virtual int update(const Vector2 &p_focus, const int p_budget_texels) = 0;
	// The source changed under a world rect: the units the rect touches stop being readable and are
	// queued for re-production. Returns how many rect jobs were queued.
	virtual int invalidate_rect(const Rect2 &p_world) = 0;

	// ---- Storage the shader and the producer name -----------------------------------------------
	virtual RID get_texture_rid() const = 0;
	virtual int get_texture_layer_count() const = 0;
	virtual int get_baked_channel_count() const = 0;
	virtual Image::Format get_baked_format() const = 0;
	virtual RID get_baked_texture_rid(const int p_channel) const = 0;
	virtual RID get_baked_device_rid(const int p_channel) const = 0;

	// ---- The bake queue -------------------------------------------------------------------------
	// The shared `BakeRect` schema: one entry per produced, un-covered rect. The producer copies what
	// it will dispatch and reports each entry back; the implementation decides whether the lease still
	// describes current content.
	virtual int get_pending_bake_count() const = 0;
	virtual const TerrainClipmap::BakeRect &get_pending_bake(const int p_index) const = 0;
	virtual bool acknowledge_bake(const TerrainClipmap::BakeRect &p_rect) = 0;
	// Every unit's baked content is stale, which is what a change to the material list the bake
	// evaluates against is: the payload is untouched, so the units stay readable - only the layers
	// produced from them are. Both implementations answer it, so a material change reaches whichever
	// one is selected.
	virtual void mark_baked_stale() = 0;

	// ---- Readings -------------------------------------------------------------------------------
	// A counter that moves whenever something a *reader's addressing* depends on changed. The material
	// rebinds its arm on this comparison instead of every tick.
	virtual uint64_t get_state_stamp() const = 0;
	virtual uint64_t get_produced_texels() const = 0;
	virtual uint64_t get_upload_bytes() const = 0;
	virtual uint64_t get_update_calls() const = 0;
	virtual uint64_t get_idle_updates() const = 0;
	virtual int get_pending_jobs() const = 0;

	// ---- Debug / report -------------------------------------------------------------------------
	// One unit's entry in the shared schema. Filled by the implementation, assembled by the facade.
	virtual void get_unit_report(const int p_unit, TerrainClipmap::UnitReport &r_report) const = 0;
	// What only this implementation can say: the atlas's rect array, cells and layout schemes; the
	// LOD ring publishes its own per-level addressing here when a *drawing* needs it. The facade nests
	// it under one key, so the shared schema above is not widened by it.
	virtual Dictionary get_impl_payload() const = 0;
	// The shader's copy of this implementation's addressing, in this implementation's own uniform
	// names. The material binds it through one path (`arm["implementation"]` decides which names), so
	// the two arms are plumbing rather than two owners.
	virtual Dictionary get_arm() const = 0;
};

#endif // TERRAIN3D_CLIPMAP_IMPL_H
