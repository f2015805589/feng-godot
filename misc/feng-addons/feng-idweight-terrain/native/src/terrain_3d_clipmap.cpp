// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The clipmap delivery's implementation. Read terrain_3d_clipmap.h first: it states the ring's
// invariant and why the stored content never moves, the production budget, what the upload
// accounting is for, and why the channel a level carries lives behind `Terrain3DClipmapSource`
// rather than in this file.

#include "terrain_3d_clipmap.h"

#include <chrono>

#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include "logger.h"

namespace {

uint64_t clipmap_clock_ns() {
	return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
			std::chrono::steady_clock::now().time_since_epoch()).count());
}

} // namespace

// The smallest and largest ring the settings can ask for. A level below 8 texels an axis stops
// being a clipmap (there is no strip left to update); above 4096 the array is larger than any
// budget the addon can produce under.
static constexpr int CLIPMAP_MIN_SIZE = 8;
static constexpr int CLIPMAP_MAX_SIZE = 4096;
// The most scalars one texel may hold, and therefore the ceiling on what a source may declare
// (`Terrain3DClipmapSource::get_channel_count()`). A level's CPU side is `size * size * channels`
// floats and its GPU side is the same count in `format`, so this is a memory statement rather than
// an arbitrary limit: at the shape the settings default to (256 texels an axis, 8 levels, four
// bytes a value) one channel is 2 MB and this ceiling is 32 MB, while at the largest ring the
// settings allow (4096 texels, 16 levels) one channel alone is 1 GB. A multi-component value is not
// a channel at all: it is a *baked* channel, a whole layer a producer writes, so this ceiling never
// sees the material group's three arrays.
static constexpr int CLIPMAP_MAX_CHANNELS = 16;

// One value per texel per layer, so a *channel's* format is the value's format. A baked channel is
// the exception and the reason the two are separate: its layer is a whole texel - albedo and height,
// an octahedral normal and roughness, the parameters - so it carries four components and the shared
// `TerrainClipmap::bytes_per_texel()` is where its bytes are counted.

// The device format of a baked channel: the one the bake shader's `rgba16f` storage images write.
// `configure()` accepts no other request, so there is nothing to translate.
static RenderingDevice::DataFormat _clipmap_baked_data_format() {
	return RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT;
}

// The world rect a rect of *logical* texels covers. Logical index (0,0)'s texel *centre* is
// `center - world_size / 2 + texel_world / 2`, so a logical rect `[x0, x1) x [y0, y1)` starts half a
// texel before its first centre and is `(x1 - x0) x (y1 - y0)` texels wide. The ring is not applied
// here: a rect of logical texels covers contiguous world either way, which is the whole point of the
// logical/physical split.
static Rect2 _clipmap_logical_rect_world(const Terrain3DClipmap::Level &p_level, const int p_x0,
		const int p_y0, const int p_x1, const int p_y1) {
	const Vector2 origin = p_level.center - Vector2(p_level.world_size, p_level.world_size) * 0.5f +
			Vector2(p_level.texel_world, p_level.texel_world) * 0.5f;
	return Rect2(origin + Vector2(float(p_x0) - 0.5f, float(p_y0) - 0.5f) * p_level.texel_world,
			Vector2(float(p_x1 - p_x0), float(p_y1 - p_y0)) * p_level.texel_world);
}

Terrain3DClipmap::Terrain3DClipmap(std::unique_ptr<Terrain3DClipmapSource> p_source) :
		_source(std::move(p_source)) {
}

Terrain3DClipmap::~Terrain3DClipmap() {
	clear();
}

String Terrain3DClipmap::get_source_name() const {
	return _source != nullptr ? _source->get_source_name() : String("none");
}

void Terrain3DClipmap::configure(const Config &p_config) {
	Config config = p_config;
	config.size = CLAMP(config.size, CLIPMAP_MIN_SIZE, CLIPMAP_MAX_SIZE);
	// The ceiling is a table size, not a preference: a ring past it has no shader array to live in.
	// It is above the shipping ladder's eleven units, so this clamp cannot shorten 1024 -> 1 - but a
	// request that *did* hit either end says so rather than quietly answering a shorter ladder.
	const int requested_levels = config.levels;
	config.levels = CLAMP(config.levels, 1, Terrain3DClipmap::MAX_LEVELS);
	if (requested_levels != config.levels) {
		LOG(WARN, "Clipmap levels ", requested_levels, " clamped to ", config.levels, " of ",
				Terrain3DClipmap::MAX_LEVELS, " (", get_source_name(), ")");
	}
	config.base_world = MAX(real_t(0.001), config.base_world);
	config.channels = CLAMP(config.channels, 1, CLIPMAP_MAX_CHANNELS);
	if (config.format != Image::FORMAT_RF && config.format != Image::FORMAT_R8) {
		LOG(ERROR, "Clipmap format ", int(config.format), " has no publish path; using RF");
		config.format = Image::FORMAT_RF;
	}
	config.baked_channels = CLAMP(config.baked_channels, 0, CLIPMAP_MAX_CHANNELS);
	// One producer, one format. The bake shader writes `rgba16f` storage images, so a baked layer is
	// half float: a ring asked for anything else is refused here rather than carrying a format no
	// pass can fill, which is the same rule `format` above follows.
	if (config.baked_channels > 0 && config.baked_format != Image::FORMAT_RGBAH) {
		LOG(ERROR, "Clipmap baked format ", int(config.baked_format), " has no producer; using RGBAH");
		config.baked_format = Image::FORMAT_RGBAH;
	}
	if (!_levels.empty() && config.size == _config.size && config.levels == int(_levels.size()) &&
			config.channels == _config.channels && config.format == _config.format &&
			config.baked_channels == _config.baked_channels && config.baked_format == _config.baked_format &&
			Math::is_equal_approx(config.base_world, _config.base_world)) {
		return;
	}	LOG(INFO, "Configuring clipmap (", get_source_name(), "): ", config.size, " texels, ", config.levels,
			" levels, ", config.channels, " channels, ", config.baked_channels, " baked, base ",
			config.base_world, " m");
	_config = config;
	_levels.assign(size_t(config.levels), Level());
	for (int level = 0; level < config.levels; level++) {
		Level &entry = _levels[size_t(level)];
		entry.world_size = config.base_world * real_t(int64_t(1) << level);
		entry.texel_world = entry.world_size / real_t(config.size);
		entry.center = Vector2();
		entry.ring = Vector2i();
		entry.texels.assign(size_t(config.size) * size_t(config.size) * size_t(config.channels), 0.f);
		entry.valid = false;
		entry.baked = false;
	}
	_row_values.assign(size_t(config.size), 0.f);
	// A lease names a level of *this* shape, so a fresh shape is what makes every lease taken before
	// it stale.
	_content_serial.assign(size_t(config.levels), 0);
	_shape_serial++;
	// Content cannot survive a different shape, and neither can the texture the last shape was
	// published into: the layer size and the layer count both changed. The baked channels are the
	// same statement a fortiori - their layers are the levels - so they are freed and reallocated.
	_jobs.clear();
	_texture.clear();
	_free_baked();
	_ensure_baked();
	// The layers a fresh shape holds are empty, so every level owes a bake: a ring that reported them
	// baked before anything wrote them would serve whatever the allocation left behind.
	_bake_rects.clear();
	for (int level = 0; level < config.levels; level++) {
		_queue_bake_rect(level, 0, 0, config.size, config.size);
	}
	_layer_image.unref();
	_has_focus = false;
	_state_stamp++;
}

void Terrain3DClipmap::clear() {
	_levels.clear();
	_jobs.clear();
	_bake_rects.clear();
	_row_values.clear();
	_content_serial.clear();
	_texture.clear();
	_free_baked();
	_layer_image.unref();
	_config.size = 0;
	_config.levels = 0;
	_has_focus = false;
	_shape_serial++;
	_state_stamp++;
}

real_t Terrain3DClipmap::get_texel_world(const int p_level) const {
	if (p_level < 0 || p_level >= int(_levels.size())) {
		return 1.f;
	}
	return _levels[size_t(p_level)].texel_world;
}

bool Terrain3DClipmap::covers(const Vector2 &p_world) const {
	if (_levels.empty()) {
		return false;
	}
	return _contains_level(int(_levels.size()) - 1, p_world);
}

// Whether a level's own texel range contains a point. Deliberately not `abs(point - centre) <= half`:
// that includes the far edge, which is one texel *past* the last stored one (`floor()` of exactly
// `size`), so a reader that clamps - the shader's `texelFetch`, and `sample()` below - would answer it
// with the edge texel and therefore with the height of a world position one texel away. The range is
// half-open on both ends, which is exactly the set of texels the level stores.
bool Terrain3DClipmap::_contains_level(const int p_level, const Vector2 &p_world) const {
	const Level &entry = _levels[size_t(p_level)];
	const real_t half = entry.world_size * 0.5f;
	const Vector2 local = (p_world - entry.center + Vector2(half, half)) / entry.texel_world;
	return local.x >= 0.f && local.y >= 0.f && local.x < real_t(_config.size) && local.y < real_t(_config.size);
}

// The level a fragment at `p_world` reads: the finest one whose own texel range contains the point,
// and the coarsest when none does. A level's centre is snapped to its own texel size, so two levels'
// coverage is not concentric - which is why this is a search and not a log2 of the distance from a
// shared centre.
int Terrain3DClipmap::level_for_world(const Vector2 &p_world) const {
	for (int level = 0; level < int(_levels.size()); level++) {
		if (_contains_level(level, p_world)) {
			return level;
		}
	}
	return int(_levels.size()) - 1;
}

real_t Terrain3DClipmap::sample(const Vector2 &p_world, const int p_channel) const {
	if (_levels.empty()) {
		return NAN;
	}
	const int level_index = level_for_world(p_world);
	const Level &entry = _levels[size_t(level_index)];
	// The texel whose centre the point is nearest, i.e. the one `floor(local / texel)` names. Going
	// through the *logical* index is what undoes the ring; the physical index alone names a different
	// world position after every wrap.
	const Vector2 half(entry.world_size * 0.5f, entry.world_size * 0.5f);
	const Vector2 local = p_world - entry.center + half;
	const Vector2i logical(CLAMP(int(Math::floor(local.x / entry.texel_world)), 0, _config.size - 1),
			CLAMP(int(Math::floor(local.y / entry.texel_world)), 0, _config.size - 1));
	const Vector2i physical = physical_of_logical(level_index, logical);
	return entry.texels[(size_t(physical.y) * size_t(_config.size) + size_t(physical.x)) * size_t(_config.channels) +
			size_t(CLAMP(p_channel, 0, _config.channels - 1))];
}

int Terrain3DClipmap::_wrap(const int p_value) const {
	return TerrainClipmap::wrap_texel(p_value, _config.size);
}

Vector2i Terrain3DClipmap::physical_of_logical(const int p_level, const Vector2i &p_logical) const {
	const Vector2i ring = _levels[size_t(p_level)].ring;
	return Vector2i(_wrap(p_logical.x + ring.x), _wrap(p_logical.y + ring.y));
}

// The source changed under a world rect. The texels that cover it are queued per level against the
// centre and ring the level has *right now*, and the levels that touch it stop being current at
// once - which is what makes the reader's fallback correct without waiting for the re-production.
//
// Converting to logical indices here rather than at drain time is sound because the mapping a job
// was converted against cannot move while the queue is not empty: `update()` re-derives the jobs of
// a new focus only from an empty queue, so every level's centre stands still until this rect (and
// whatever was queued before it) has drained. A world rect retained until then would have to be
// re-converted on every rebuild and could not be re-converted while the level is mid-rect anyway.
//
// Two cases cost nothing: a level that is already being produced whole already covers the rect (the
// values it has not written yet are read from the source after the edit), and a rect entirely
// outside a level's own coverage names none of its texels.
int Terrain3DClipmap::invalidate_rect(const Rect2 &p_world) {
	if (!is_configured()) {
		return 0;
	}
	const Rect2 rect = p_world.abs();
	if (rect.size.x <= 0.f || rect.size.y <= 0.f) {
		return 0;
	}
	_invalidation_calls++;
	// Before the first focus nothing has been produced, and the first fill reads the source as it
	// stands - edit included - so there is no stale texel to find.
	if (!_has_focus) {
		return 0;
	}
	int queued = 0;
	for (int level = 0; level < int(_levels.size()); level++) {
		Level &entry = _levels[size_t(level)];
		bool filled = false;
		for (const Job &job : _jobs) {
			if (job.level == level && job.x0 == 0 && job.y0 == 0 && job.x1 == _config.size && job.y1 == _config.size) {
				filled = true;
				break;
			}
		}
		if (filled) {
			continue;
		}
		const Vector2 half(entry.world_size * 0.5f, entry.world_size * 0.5f);
		const Vector2 local_begin = (rect.position - entry.center + half) / entry.texel_world;
		const Vector2 local_end = (rect.position + rect.size - entry.center + half) / entry.texel_world;
		if (local_end.x <= 0.f || local_end.y <= 0.f ||
				local_begin.x >= real_t(_config.size) || local_begin.y >= real_t(_config.size)) {
			continue;
		}
		// The floor/ceil pair is the rect's own texels: a rect that starts inside a texel covers it,
		// and one that ends inside a texel covers it too, so the two edges round outward.
		const int x0 = CLAMP(int(Math::floor(local_begin.x)), 0, _config.size - 1);
		const int y0 = CLAMP(int(Math::floor(local_begin.y)), 0, _config.size - 1);
		const int x1 = CLAMP(int(Math::ceil(local_end.x)), x0 + 1, _config.size);
		const int y1 = CLAMP(int(Math::ceil(local_end.y)), y0 + 1, _config.size);
		entry.valid = false;
		entry.baked = false;
		_content_serial[size_t(level)]++;
		_jobs.push_back(Job(level, x0, y0, x1, y1));
		_invalidated_texels += uint64_t(x1 - x0) * uint64_t(y1 - y0);
		queued++;
	}
	// A level that stopped being current is exactly the state a reader must stop serving.
	if (queued > 0) {
		_state_stamp++;
	}
	return queued;
}

int Terrain3DClipmap::update(const Vector2 &p_focus, const int p_budget_texels) {
	const uint64_t update_started_ns = clipmap_clock_ns();
	_last_update_diagnostics = UpdateDiagnostics();
	_last_update_diagnostics.levels_configured = int(_levels.size());
	_last_update_diagnostics.jobs_before = int(_jobs.size());
	_last_update_diagnostics.jobs_after = int(_jobs.size());
	_update_calls++;
	if (!is_configured() || _source == nullptr) {
		_last_update_diagnostics.update_ns = clipmap_clock_ns() - update_started_ns;
		return 0;
	}
	// Jobs already queued describe the mapping the levels were advanced to. Re-deriving them from
	// the focus now would discard a partially produced level and produce a rect the ring no longer
	// matches, so the queue is only rebuilt once it is empty.
	if (_jobs.empty()) {
		const uint64_t rebuild_started_ns = clipmap_clock_ns();
		_rebuild_jobs(p_focus);
		_last_update_diagnostics.rebuild_schedule_ns += clipmap_clock_ns() - rebuild_started_ns;
		_last_update_diagnostics.jobs_scheduled = int(_jobs.size());
	}
	if (_jobs.empty()) {
		_idle_updates++;
		_last_update_diagnostics.jobs_after = int(_jobs.size());
		_last_update_diagnostics.update_ns = clipmap_clock_ns() - update_started_ns;
		return 0;
	}
	int budget = MAX(0, p_budget_texels);
	int produced = 0;
	std::vector<Job> remaining;
	remaining.reserve(_jobs.size());
	for (size_t index = 0; index < _jobs.size(); index++) {
		Job job = _jobs[index];
		const int before = budget;
		const bool finished = _produce_rect(job, budget);
		produced += before - budget;
		if (!finished) {
			remaining.push_back(job);
			// Everything behind an unfinished job is untouched, so it stays queued verbatim.
			for (size_t rest = index + 1; rest < _jobs.size(); rest++) {
				remaining.push_back(_jobs[rest]);
			}
			break;
		}
		_last_update_diagnostics.jobs_completed++;
		// The rect is whole, so a bake has something to cover: the *rect*, not the level, because the
		// texels outside it still describe the world positions they described before - which is the
		// whole reason the baked layers are indexed logically.
		_queue_bake_rect(job.level, job.x0, job.y0, job.x1, job.y1);
	}
	// A level that had work and has none left is now whole: it becomes valid and is published. A
	// level the budget left half-produced stays invalid, which is what tells a reader it still
	// holds the level it replaces.
	for (int level = 0; level < int(_levels.size()); level++) {
		bool was_queued = false;
		for (const Job &job : _jobs) {
			if (job.level == level) {
				was_queued = true;
				break;
			}
		}
		if (!was_queued) {
			continue;
		}
		bool still_queued = false;
		for (const Job &job : remaining) {
			if (job.level == level) {
				still_queued = true;
				break;
			}
		}
		if (!still_queued) {
			_levels[size_t(level)].valid = true;
			_last_update_diagnostics.levels_completed++;
			_publish_level(level);
			// A level that just became current is a level a reader may now serve, which is addressing
			// state like any other.
			_state_stamp++;
		}
	}
	_jobs = std::move(remaining);
	_last_update_diagnostics.produced_texels = uint64_t(produced);
	_last_update_diagnostics.jobs_after = int(_jobs.size());
	_last_update_diagnostics.update_ns = clipmap_clock_ns() - update_started_ns;
	return produced;
}

bool Terrain3DClipmap::needs_update_at(const Vector2 &p_focus) const {
	if (!is_configured() || _source == nullptr) {
		return false;
	}
	if (!_has_focus || !_jobs.empty()) {
		return true;
	}
	for (const Level &entry : _levels) {
		if (!entry.valid) {
			return true;
		}
		const Vector2 snapped(Math::floor(p_focus.x / entry.texel_world) * entry.texel_world,
				Math::floor(p_focus.y / entry.texel_world) * entry.texel_world);
		if (snapped != entry.center) {
			return true;
		}
	}
	return false;
}

// What the new focus costs, and the mapping it costs it under. Every level is advanced *here* -
// centre and ring both - because a job's rect is a rect of *logical* texels and its world positions
// come from the centre and ring the level has after this call. Producing a rect against the old
// mapping and advancing afterwards is the one way to get a strip that looks right for a frame.
//
// The order is the plan's: a level that has to be filled whole is filled coarsest first, so the
// fallback every coarser read depends on exists soonest, and a level that only lost and gained
// strips is streamed finest first, so the ground under the camera is the first to be right.
void Terrain3DClipmap::_rebuild_jobs(const Vector2 &p_focus) {
	_jobs.clear();
	std::vector<Job> fills;
	std::vector<Job> streams;
	const bool first_fill = !_has_focus;
	for (int level = 0; level < int(_levels.size()); level++) {
		Level &entry = _levels[size_t(level)];
		const Vector2 snapped(Math::floor(p_focus.x / entry.texel_world) * entry.texel_world,
				Math::floor(p_focus.y / entry.texel_world) * entry.texel_world);
		if (first_fill || !entry.valid) {
			entry.center = snapped;
			entry.valid = false;
			entry.baked = false;
			_content_serial[size_t(level)]++;
			fills.push_back({ level, 0, 0, _config.size, _config.size });
			_full_productions++;
			continue;
		}
		const Vector2i delta(int(Math::round((snapped.x - entry.center.x) / entry.texel_world)),
				int(Math::round((snapped.y - entry.center.y) / entry.texel_world)));
		if (delta.x == 0 && delta.y == 0) {
			continue;
		}
		entry.center = snapped;
		// The level stops being valid the moment it has work queued, not when the budget finally
		// drains it: between the two it holds the level it replaces, and `valid` is what says so.
		entry.valid = false;
		entry.baked = false;
		_content_serial[size_t(level)]++;
		if (Math::abs(delta.x) >= _config.size || Math::abs(delta.y) >= _config.size) {
			// The focus left the level's own coverage: nothing of the old content belongs to the new
			// one, so the level is rebuilt whole rather than edge by edge.
			fills.push_back({ level, 0, 0, _config.size, _config.size });
			_full_productions++;
			continue;
		}
		// The content does not move: only the ring turns, so a *logical* index keeps naming the same
		// world position and the new strips are the logical indices the level just gained.
		entry.ring = Vector2i(_wrap(entry.ring.x + delta.x), _wrap(entry.ring.y + delta.y));
		if (delta.x > 0) {
			streams.push_back({ level, _config.size - delta.x, 0, _config.size, _config.size });
		} else if (delta.x < 0) {
			streams.push_back({ level, 0, 0, -delta.x, _config.size });
		}
		// The band is the full width and is allowed to overlap the columns above: the corner would
		// otherwise need a third rect, and writing a texel the deterministic rule already gave a
		// value is free of consequence. Section 6 of the assembly doc records the overlap.
		if (delta.y > 0) {
			streams.push_back({ level, 0, _config.size - delta.y, _config.size, _config.size });
		} else if (delta.y < 0) {
			streams.push_back({ level, 0, 0, _config.size, -delta.y });
		}
	}
	_has_focus = true;
	// Coarsest first for the fills, finest first for the strips.
	for (int level = int(_levels.size()) - 1; level >= 0; level--) {
		for (const Job &job : fills) {
			if (job.level == level) {
				_jobs.push_back(job);
			}
		}
	}
	for (int level = 0; level < int(_levels.size()); level++) {
		for (const Job &job : streams) {
			if (job.level == level) {
				_jobs.push_back(job);
			}
		}
	}
	// Every level that was advanced - centre, ring and `valid` alike - is addressing state a reader
	// has to follow, so a rebuild that queued anything moves the stamp.
	if (!fills.empty() || !streams.empty()) {
		_state_stamp++;
	}
}

// Produces as much of `p_job` as the budget allows and leaves `p_job`'s cursor naming what is left,
// so a level that does not fit one call is continued exactly where it stopped. Production is
// charged and resumed per *run of a row*, not per texel: the source is asked once for a run of a
// row, which is where its own lookup cost is, and the run is cut at the budget so a call still
// spends what it was given.
//
// The rect and the cursor are separate on purpose. A strip is a rect (a column, a row, or both
// bands), and every row of it must be produced; only the *resume point* is a position inside the
// rect, and reading `x0` as "the first row is partial" is the mistake that makes a one-texel move
// produce the whole level one row short.
bool Terrain3DClipmap::_produce_rect(Job &p_job, int &r_budget) {
	for (int y = p_job.cursor_y; y < p_job.y1; y++) {
		const bool first_row = y == p_job.cursor_y;
		for (int channel = first_row ? p_job.cursor_channel : 0; channel < _config.channels; channel++) {
			int x = first_row && channel == p_job.cursor_channel ? p_job.cursor_x : p_job.x0;
			while (x < p_job.x1) {
				if (r_budget <= 0) {
					p_job.cursor_y = y;
					p_job.cursor_channel = channel;
					p_job.cursor_x = x;
					return false;
				}
				const int count = MIN(p_job.x1 - x, r_budget);
				_fill_row(p_job, channel, y, x, x + count);
				r_budget -= count;
				_produced_texels += uint64_t(count);
				x += count;
			}
		}
	}
	return true;
}

void Terrain3DClipmap::_fill_row(const Job &p_job, const int p_channel, const int p_y, const int p_x0, const int p_x1) {
	Level &entry = _levels[size_t(p_job.level)];
	Terrain3DClipmapSource::Row row;
	row.level = p_job.level;
	row.channel = p_channel;
	row.y = p_y;
	row.x0 = p_x0;
	row.x1 = p_x1;
	row.size = _config.size;
	row.texel_world = entry.texel_world;
	// The world position of the centre of logical texel (0, 0), which is the same addressing
	// `sample()` inverts: the two agree on where a logical texel is.
	const real_t half = entry.world_size * 0.5f;
	const real_t centre_of_first = 0.5f * entry.texel_world;
	row.origin = Vector2(entry.center.x - half + centre_of_first, entry.center.y - half + centre_of_first);
	const uint64_t source_started_ns = clipmap_clock_ns();
	_source->fill_row(row, _row_values.data());
	const uint64_t source_finished_ns = clipmap_clock_ns();
	_last_update_diagnostics.source_fill_ns += source_finished_ns - source_started_ns;
	_last_update_diagnostics.source_row_calls++;
	// The source never sees a physical index: the ring is undone here, per value, so a wrap cannot
	// reach the producer.
	const uint64_t scatter_started_ns = source_finished_ns;
	for (int x = p_x0; x < p_x1; x++) {
		const Vector2i physical = physical_of_logical(p_job.level, Vector2i(x, p_y));
		entry.texels[(size_t(physical.y) * size_t(_config.size) + size_t(physical.x)) * size_t(_config.channels) +
				size_t(p_channel)] = _row_values[size_t(x)];
	}
	_last_update_diagnostics.ring_scatter_ns += clipmap_clock_ns() - scatter_started_ns;
}

void Terrain3DClipmap::_ensure_texture() {
	const int bytes_per_texel = TerrainClipmap::bytes_per_texel(_config.format);
	const int64_t texels = int64_t(_config.size) * int64_t(_config.size);
	if (_layer_image.is_null() || _layer_image->get_width() != _config.size || _layer_image->get_format() != _config.format) {
		PackedByteArray blank;
		blank.resize(texels * bytes_per_texel);
		_layer_image = Image::create_from_data(_config.size, _config.size, false, _config.format, blank);
	}
	_texture.ensure_layers(_layer_image, int(_levels.size()) * _config.channels);
	// A ring configured before a device was reachable allocates its baked channels here instead, so
	// the producer finds storage rather than having to ask for a reconfigure.
	_ensure_baked();
}

void Terrain3DClipmap::_publish_level(const int p_level) {
	const uint64_t ensure_started_ns = clipmap_clock_ns();
	_ensure_texture();
	_last_update_diagnostics.gpu_publish_ns += clipmap_clock_ns() - ensure_started_ns;
	if (!_texture.get_rid().is_valid()) {
		return;
	}
	const Level &entry = _levels[size_t(p_level)];
	const int64_t texels = int64_t(_config.size) * int64_t(_config.size);
	const int bytes_per_texel = TerrainClipmap::bytes_per_texel(_config.format);
	const uint64_t allocation_started_ns = clipmap_clock_ns();
	PackedByteArray bytes;
	bytes.resize(texels * bytes_per_texel);
	uint8_t *dst = bytes.ptrw();
	_last_update_diagnostics.full_level_pack_ns += clipmap_clock_ns() - allocation_started_ns;
	for (int channel = 0; channel < _config.channels; channel++) {
		const uint64_t pack_started_ns = clipmap_clock_ns();
		if (_config.format == Image::FORMAT_RF) {
			float *values = reinterpret_cast<float *>(dst);
			for (int64_t texel = 0; texel < texels; texel++) {
				values[texel] = entry.texels[size_t(texel) * size_t(_config.channels) + size_t(channel)];
			}
		} else {
			for (int64_t texel = 0; texel < texels; texel++) {
				const float value = entry.texels[size_t(texel) * size_t(_config.channels) + size_t(channel)];
				dst[texel] = uint8_t(CLAMP(value, 0.f, 1.f) * 255.f + 0.5f);
			}
		}
		// A fresh image per layer, not a reused one: `texture_2d_update()` queues the image it was
		// given, so a shared buffer would be rewritten before the queue flushes.
		Ref<Image> image = Image::create_from_data(_config.size, _config.size, false, _config.format, bytes);
		_last_update_diagnostics.full_level_pack_ns += clipmap_clock_ns() - pack_started_ns;
		_last_update_diagnostics.packed_texels += uint64_t(texels);
		const uint64_t gpu_started_ns = clipmap_clock_ns();
		_texture.update(image, p_level * _config.channels + channel);
		_last_update_diagnostics.gpu_publish_ns += clipmap_clock_ns() - gpu_started_ns;
		_last_update_diagnostics.published_layers++;
		_last_update_diagnostics.published_bytes += uint64_t(texels * bytes_per_texel);
		_upload_bytes += uint64_t(texels * bytes_per_texel);
	}
}

RID Terrain3DClipmap::get_baked_device_rid(const int p_channel) const {
	if (p_channel < 0 || p_channel >= int(_baked_rd.size())) {
		return RID();
	}
	return _baked_rd[size_t(p_channel)];
}

RID Terrain3DClipmap::get_baked_texture_rid(const int p_channel) const {
	if (p_channel < 0 || p_channel >= int(_baked_rs.size())) {
		return RID();
	}
	return _baked_rs[size_t(p_channel)];
}

void Terrain3DClipmap::mark_baked_stale() {
	// Every level, because what a bake writes is a function of the level's payload *and* of the
	// surface material list it is evaluated against (`Terrain3DSurfaceBaker::set_materials()`), and an
	// asset edit changes the list for the whole ring at once. The payload is untouched by that - the
	// source still holds exactly these texels - so this is not an invalidation of `valid`: it is the
	// bake's own staleness, and every level is queued whole for the next offer.
	for (int level = 0; level < int(_levels.size()); level++) {
		_queue_bake_rect(level, 0, 0, _config.size, _config.size);
	}
}

// One produced rect joins its level's queue, translated into the level's *stored* frame.
//
// The produced rect is a rect of logical texels - the ones whose content the level's own movement
// changed - and the baked layer is indexed the way the payload layer is, by the *stored* texel,
// because the stored frame is the one that keeps naming the same world position as the level turns:
// the centre moves and the ring offset turns with it, so a texel the movement did not touch still
// describes the world position it described. That is what makes a strip's bake sufficient, and a layer
// indexed in the level's own (moving) frame would leave the rest of the level describing world
// positions it no longer covers. A rect that crosses the wrap is two rects, because a stored rect is
// contiguous.
void Terrain3DClipmap::_queue_bake_rect(const int p_level, const int p_x0, const int p_y0, const int p_x1,
		const int p_y1) {
	if (p_level < 0 || p_level >= int(_levels.size()) || p_x1 <= p_x0 || p_y1 <= p_y0) {
		return;
	}
	const int size = _config.size;
	const int width = p_x1 - p_x0;
	const int height = p_y1 - p_y0;
	// A whole level is the whole stored square whatever the ring is: that keeps a first fill and a
	// material change one rect rather than the two the wrap would make of it.
	if (width >= size && height >= size) {
		_queue_stored_bake_rect(p_level, 0, 0, size, size);
		return;
	}
	const Vector2i ring = _levels[size_t(p_level)].ring;
	const int x_start = _wrap(p_x0 + ring.x);
	const int y_start = _wrap(p_y0 + ring.y);
	// One interval an axis, or two when that interval runs off the end of the stored square.
	const int x_starts[2] = { x_start, 0 };
	const int x_ends[2] = { MIN(x_start + width, size), x_start + width - size };
	const int x_count = x_start + width <= size ? 1 : 2;
	const int y_starts[2] = { y_start, 0 };
	const int y_ends[2] = { MIN(y_start + height, size), y_start + height - size };
	const int y_count = y_start + height <= size ? 1 : 2;
	for (int xi = 0; xi < x_count; xi++) {
		for (int yi = 0; yi < y_count; yi++) {
			if (x_ends[xi] <= x_starts[xi] || y_ends[yi] <= y_starts[yi]) {
				continue;
			}
			_queue_stored_bake_rect(p_level, x_starts[xi], y_starts[yi], x_ends[xi], y_ends[yi]);
		}
	}
}

void Terrain3DClipmap::_queue_stored_bake_rect(const int p_level, const int p_x0, const int p_y0,
		const int p_x1, const int p_y1) {
	// The rect's own content, which is the level's content *now*: what the CPU side has produced into
	// this rect is exactly what a bake of it will read, and a later production into the same rect is
	// what takes the lease away again.
	const uint64_t lease = take_bake_lease(p_level);
	for (BakeRect &rect : _bake_rects) {
		if (rect.unit != p_level) {
			continue;
		}
		// Disjoint: a second entry for the level, which is the honest shape - two strips that do not
		// touch are two rects, and a producer may bake one and not the other.
		if (rect.x1 <= p_x0 || rect.x0 >= p_x1 || rect.y1 <= p_y0 || rect.y0 >= p_y1) {
			continue;
		}
		rect.x0 = MIN(rect.x0, p_x0);
		rect.y0 = MIN(rect.y0, p_y0);
		rect.x1 = MAX(rect.x1, p_x1);
		rect.y1 = MAX(rect.y1, p_y1);
		// The merged rect covers content the in-flight bake never read, so its lease moves with it: the
		// dispatch that covered the smaller rect is refused and the larger one is baked instead.
		rect.lease = lease;
		_refresh_baked(p_level);
		_state_stamp++;
		return;
	}
	BakeRect queued;
	queued.unit = p_level;
	queued.x0 = p_x0;
	queued.y0 = p_y0;
	queued.x1 = p_x1;
	queued.y1 = p_y1;
	queued.lease = lease;
	_bake_rects.push_back(queued);
	_refresh_baked(p_level);
	_state_stamp++;
}

// What a reader must not serve right now: everything un-baked plus everything still being produced.
// The two are the same statement at different stages - "the stored texels here do not match the layers
// yet" - and the second is what lets a reader keep serving the rest of a level while a strip is filled.
int Terrain3DClipmap::get_outstanding_rects(const int p_level, BakeRect *r_rects, const int p_max) const {
	if (p_level < 0 || p_level >= int(_levels.size()) || r_rects == nullptr || p_max <= 0) {
		return 0;
	}
	int count = 0;
	bool overflow = false;
	// The stored image of a rect of *logical* texels, which is what a job holds. The conversion is the
	// same one the bake queue takes, including the split a rect crossing the wrap needs.
	auto append_logical = [&](const int p_x0, const int p_y0, const int p_x1, const int p_y1) {
		const int size = _config.size;
		const int width = p_x1 - p_x0;
		const int height = p_y1 - p_y0;
		if (width <= 0 || height <= 0) {
			return;
		}
		if (width >= size && height >= size) {
			if (count >= p_max) {
				overflow = true;
				return;
			}
			r_rects[count++] = BakeRect{ p_level, 0, 0, size, size, 0 };
			return;
		}
		const Vector2i ring = _levels[size_t(p_level)].ring;
		const int x_start = _wrap(p_x0 + ring.x);
		const int y_start = _wrap(p_y0 + ring.y);
		const int x_starts[2] = { x_start, 0 };
		const int x_ends[2] = { MIN(x_start + width, size), x_start + width - size };
		const int x_count = x_start + width <= size ? 1 : 2;
		const int y_starts[2] = { y_start, 0 };
		const int y_ends[2] = { MIN(y_start + height, size), y_start + height - size };
		const int y_count = y_start + height <= size ? 1 : 2;
		for (int xi = 0; xi < x_count; xi++) {
			for (int yi = 0; yi < y_count; yi++) {
				if (x_ends[xi] <= x_starts[xi] || y_ends[yi] <= y_starts[yi]) {
					continue;
				}
				if (count >= p_max) {
					overflow = true;
					return;
				}
				r_rects[count++] = BakeRect{ p_level, x_starts[xi], y_starts[yi], x_ends[xi], y_ends[yi], 0 };
			}
		}
	};
	// The rects still being produced come first: they are the ones a reader has no baked content for at
	// all, so a table that has to cut something keeps those.
	for (const Job &job : _jobs) {
		if (job.level == p_level) {
			append_logical(job.x0, job.y0, job.x1, job.y1);
		}
	}
	for (const BakeRect &rect : _bake_rects) {
		if (rect.unit != p_level) {
			continue;
		}
		if (count >= p_max) {
			overflow = true;
			break;
		}
		r_rects[count++] = rect;
	}
	if (overflow) {
		r_rects[0] = BakeRect{ p_level, 0, 0, _config.size, _config.size, 0 };
		return 1;
	}
	return count;
}

// One writer for the flag the arm and the report read: a level is baked when nothing of it is queued.
// A level whose rects are all still queued - or which has never been baked - is not baked, and the arm
// falls back for it.
void Terrain3DClipmap::_refresh_baked(const int p_level) {
	if (p_level < 0 || p_level >= int(_levels.size())) {
		return;
	}
	bool queued = false;
	for (const BakeRect &rect : _bake_rects) {
		if (rect.unit == p_level) {
			queued = true;
			break;
		}
	}
	Level &entry = _levels[size_t(p_level)];
	if (entry.baked == !queued) {
		return;
	}
	entry.baked = !queued;
	// A reader's addressing depends on it, so this is a state change like a centre or a ring.
	_state_stamp++;
}

bool Terrain3DClipmap::acknowledge_bake(const TerrainClipmap::BakeRect &p_rect) {
	const int p_level = p_rect.unit;
	const int p_x0 = p_rect.x0;
	const int p_y0 = p_rect.y0;
	const int p_x1 = p_rect.x1;
	const int p_y1 = p_rect.y1;
	const uint64_t p_lease = p_rect.lease;
	if (p_level < 0 || p_level >= int(_levels.size())) {
		_bake_rejects++;
		return false;
	}
	for (size_t index = 0; index < _bake_rects.size(); index++) {
		const BakeRect &rect = _bake_rects[index];
		if (rect.unit != p_level || rect.x0 != p_x0 || rect.y0 != p_y0 || rect.x1 != p_x1 ||
				rect.y1 != p_y1) {
			continue;
		}
		// The rect's *own* lease, not the level's: a rect that was not produced into since it was queued
		// holds exactly the texels the bake read, however many times the level moved around it - which is
		// the whole reason a focused camera can be baked at all. A rect that grew over new content since
		// carries a newer lease, so the dispatch that covered the smaller rect is refused and the larger
		// one is baked instead.
		if (rect.lease != p_lease) {
			_bake_rejects++;
			return false;
		}
		_bake_rects.erase(_bake_rects.begin() + int64_t(index));
		_baked_texels += uint64_t(p_x1 - p_x0) * uint64_t(p_y1 - p_y0) *
				uint64_t(MAX(1, _config.baked_channels));
		_bake_dispatches++;
		_refresh_baked(p_level);
		_state_stamp++;
		return true;
	}
	// No such rect: the queue was cleared under the dispatch (a reconfigure), or the rect was merged
	// into another one. Both mean the bake describes texels this ring no longer queues.
	_bake_rejects++;
	return false;
}

uint64_t Terrain3DClipmap::take_bake_lease(const int p_level) const {
	if (p_level < 0 || p_level >= int(_content_serial.size())) {
		return 0;
	}
	// The shape in the high half, the level's content in the low one. One number so a producer stores
	// one value per rect it dispatches, and `0` is not a lease: a level that has no content counter
	// has no lease to take.
	return (_shape_serial << 32) | (_content_serial[size_t(p_level)] & 0xFFFFFFFFull);
}

Rect2 Terrain3DClipmap::get_level_world_bounds(const int p_level) const {
	if (p_level < 0 || p_level >= int(_levels.size())) {
		return Rect2();
	}
	return _clipmap_logical_rect_world(_levels[size_t(p_level)], 0, 0, _config.size, _config.size);
}

// One device texture per baked channel, `levels` layers each, plus its `RenderingServer` wrapper.
// The producer writes the device texture as a storage image and the arm samples the wrapper, so
// the two are created together and freed together: a wrapper with no producer would be a sampler
// over memory nobody wrote, and a producer with no wrapper would bake into something nothing can
// read.
void Terrain3DClipmap::_ensure_baked() {
	if (_config.baked_channels <= 0 || _levels.empty()) {
		return;
	}
	if (!_baked_rd.empty() && _baked_rd[0].is_valid()) {
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	if (rd == nullptr) {
		// No device yet - a headless run, or a configure before the first frame. `_ensure_texture()`
		// calls this again on the first publish, which is the first moment a device is certain.
		return;
	}
	_free_baked();
	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
	format->set_format(_clipmap_baked_data_format());
	format->set_width(uint32_t(_config.size));
	format->set_height(uint32_t(_config.size));
	format->set_depth(1);
	// At least two layers, whatever the ring's level count: the renderer refuses to wrap a one-layer
	// array as a layered texture (`texture_rd_create()` fails on `array_layers == 1`), and the arm
	// samples these as an array. A one-level ring therefore allocates one layer that is never written
	// and never read - one layer of one level is cheaper than a second publish path for that shape.
	format->set_array_layers(uint32_t(MAX(_levels.size(), size_t(2))));
	format->set_mipmaps(1);
	// Storage, so a producer writes a level; sampling, so the arm reads it; update, because the
	// producer's pass is issued against the same texture the material binds. Neither copy direction
	// is asked for: nothing moves a baked layer, because the CPU has no copy of one by construction.
	format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_STORAGE_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	// Created uninitialised: every texel of every layer belongs to a producer, and a level is only
	// ever read while it is `baked`. Seeding a blank layer per level here would cost a transfer per
	// configure and buy nothing a reader uses.
	TypedArray<PackedByteArray> initial;
	for (int channel = 0; channel < _config.baked_channels; channel++) {
		RID device = rd->texture_create(format, view, initial);
		RID shader = device.is_valid()
				? server->texture_rd_create(device, RenderingServer::TEXTURE_LAYERED_2D_ARRAY)
				: RID();
		if (!shader.is_valid()) {
			if (device.is_valid()) {
				rd->free_rid(device);
			}
			LOG(ERROR, "Could not allocate clipmap baked channel ", channel, " (", get_source_name(), ")");
			_free_baked();
			return;
		}
		rd->set_resource_name(device, "Terrain3D Clipmap " + get_source_name() + " baked " +
						String::num_int64(channel));
		_baked_rd.push_back(device);
		_baked_rs.push_back(shader);
	}
}

void Terrain3DClipmap::_free_baked() {
	if (_baked_rd.empty() && _baked_rs.empty()) {
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	// The wrapper first and the device texture second: the wrapper is what a material holds, and it
	// is the device texture's lifetime that has to outlast every reader of it.
	for (const RID &rid : _baked_rs) {
		if (rid.is_valid() && server != nullptr) {
			server->free_rid(rid);
		}
	}
	for (const RID &rid : _baked_rd) {
		if (rid.is_valid() && rd != nullptr) {
			rd->free_rid(rid);
		}
	}
	_baked_rd.clear();
	_baked_rs.clear();
}

Array Terrain3DClipmap::get_level_reports() const {
	Array reports;
	for (int level = 0; level < int(_levels.size()); level++) {
		const Level &entry = _levels[size_t(level)];
		Dictionary report;
		report["level"] = level;
		report["size"] = _config.size;
		report["channels"] = _config.channels;
		report["world_size"] = entry.world_size;
		report["texel_world"] = entry.texel_world;
		report["center"] = entry.center;
		report["ring"] = entry.ring;
		report["valid"] = entry.valid;
		report["baked_channels"] = _config.baked_channels;
		report["baked"] = entry.baked;
		// What the level still owes the device, and in the same unit the production budget is charged
		// in - channel texels - so "how much of this level is unbaked" is a number rather than a flag.
		int pending_rects = 0;
		int64_t pending_texels = 0;
		for (const BakeRect &rect : _bake_rects) {
			if (rect.unit != level) {
				continue;
			}
			pending_rects++;
			pending_texels += int64_t(rect.x1 - rect.x0) * int64_t(rect.y1 - rect.y0) *
					int64_t(MAX(1, _config.baked_channels));
		}
		report["pending_bake_rects"] = pending_rects;
		report["pending_bake_texels"] = pending_texels;
		reports.push_back(report);
	}
	return reports;
}

///////////////////////////
// The shared contract's debug and arm halves
///////////////////////////

// One level in the *shared* schema (`TerrainClipmap::UnitReport`). A level has one square, so its
// centre and offset are the ring's own addressing; a level with no bake (the height channel) reports
// `baked == valid`, because "the layers the material samples" and "the texels the source filled" are
// the same content when nothing bakes.
void Terrain3DClipmap::get_unit_report(const int p_unit, TerrainClipmap::UnitReport &r_report) const {
	r_report = TerrainClipmap::UnitReport();
	if (p_unit < 0 || p_unit >= int(_levels.size())) {
		return;
	}
	const Level &entry = _levels[size_t(p_unit)];
	r_report.index = p_unit;
	r_report.kind = "level";
	r_report.texels = _config.size;
	r_report.world_size = entry.world_size;
	r_report.texel_world = entry.texel_world;
	r_report.density = entry.texel_world > 0.f ? 1.f / entry.texel_world : 0.f;
	r_report.valid = entry.valid;
	r_report.baked = _config.baked_channels > 0 ? entry.baked : entry.valid;
	r_report.center = entry.center;
	r_report.offset = entry.ring;
	r_report.resident = entry.valid ? 1 : 0;
	r_report.blocks = 1;
	// The rects the *level* still owes, in world space: the queued job rects and the un-baked rects,
	// which are two different statements - where production stopped, and what the device has not been
	// told yet - and a debug view draws both.
	for (const Job &job : _jobs) {
		if (job.level != p_unit) {
			continue;
		}
		const int open_x0 = job.cursor_channel == 0 ? job.cursor_x : job.x0;
		if (open_x0 == job.x0) {
			r_report.pending_rects.push_back(
					_clipmap_logical_rect_world(entry, job.x0, job.cursor_y, job.x1, job.y1));
			continue;
		}
		r_report.pending_rects.push_back(
				_clipmap_logical_rect_world(entry, open_x0, job.cursor_y, job.x1, job.cursor_y + 1));
		if (job.cursor_y + 1 < job.y1) {
			r_report.pending_rects.push_back(
					_clipmap_logical_rect_world(entry, job.x0, job.cursor_y + 1, job.x1, job.y1));
		}
	}
	r_report.pending = int(r_report.pending_rects.size());
}

// What only the ring can say. The shared schema above describes a level as a square; a drawing that
// needs the level rule's own arithmetic - the outstanding stored rects the material's gate is built
// from - reads it here, so the shared schema is not widened by this implementation's frame.
Dictionary Terrain3DClipmap::get_impl_payload() const {
	Dictionary payload;
	payload["storage"] = "toroidal_level_array";
	payload["layers"] = _texture.get_layer_count();
	payload["level_reports"] = get_level_reports();
	payload["full_level_productions"] = int64_t(_full_productions);
	payload["bake_dispatches"] = int64_t(_bake_dispatches);
	payload["bake_rejects"] = int64_t(_bake_rejects);
	payload["invalidation_calls"] = int64_t(_invalidation_calls);
	payload["invalidated_texels"] = int64_t(_invalidated_texels);
	Dictionary update_diagnostics;
	update_diagnostics["update_us"] = double(_last_update_diagnostics.update_ns) / 1000.0;
	update_diagnostics["rebuild_schedule_us"] = double(_last_update_diagnostics.rebuild_schedule_ns) / 1000.0;
	update_diagnostics["source_fill_us"] = double(_last_update_diagnostics.source_fill_ns) / 1000.0;
	update_diagnostics["ring_scatter_us"] = double(_last_update_diagnostics.ring_scatter_ns) / 1000.0;
	update_diagnostics["full_level_pack_us"] = double(_last_update_diagnostics.full_level_pack_ns) / 1000.0;
	// This is the synchronous time spent ensuring storage and submitting layer updates through
	// RenderingServer. It does not include later render-thread transfer or GPU completion time.
	update_diagnostics["gpu_publish_us"] = double(_last_update_diagnostics.gpu_publish_ns) / 1000.0;
	update_diagnostics["jobs_before"] = _last_update_diagnostics.jobs_before;
	update_diagnostics["jobs_scheduled"] = _last_update_diagnostics.jobs_scheduled;
	update_diagnostics["jobs_completed"] = _last_update_diagnostics.jobs_completed;
	update_diagnostics["jobs_after"] = _last_update_diagnostics.jobs_after;
	update_diagnostics["source_row_calls"] = _last_update_diagnostics.source_row_calls;
	update_diagnostics["levels_configured"] = _last_update_diagnostics.levels_configured;
	update_diagnostics["produced_texels"] = int64_t(_last_update_diagnostics.produced_texels);
	update_diagnostics["packed_texels"] = int64_t(_last_update_diagnostics.packed_texels);
	update_diagnostics["published_bytes"] = int64_t(_last_update_diagnostics.published_bytes);
	update_diagnostics["levels_completed"] = _last_update_diagnostics.levels_completed;
	update_diagnostics["published_layers"] = _last_update_diagnostics.published_layers;
	payload["update_diagnostics"] = update_diagnostics;
	return payload;
}

// The ring's arm: the per-level centres, rings and validity, the outstanding-rect table the material's
// per-tap gate reads, and the level rule. It lives here because it *is* this implementation's
// addressing - the shader arm computes with exactly these numbers - so the binding above it is one
// forward rather than a copy per owner.
Dictionary Terrain3DClipmap::get_arm() const {
	Dictionary arm;
	if (!is_configured()) {
		return arm;
	}
	const int levels = get_level_count();
	PackedVector2Array centers;
	PackedVector2Array rings;
	PackedFloat32Array valid;
	PackedVector4Array outstanding;
	PackedInt32Array outstanding_counts;
	centers.resize(MAX_LEVELS);
	rings.resize(MAX_LEVELS);
	valid.resize(MAX_LEVELS);
	outstanding_counts.resize(MAX_LEVELS);
	outstanding.resize(MAX_LEVELS * MAX_OUTSTANDING_RECTS);
	for (int level = 0; level < levels; level++) {
		const Level &entry = _levels[size_t(level)];
		centers[level] = entry.center;
		rings[level] = Vector2(real_t(entry.ring.x), real_t(entry.ring.y));
		valid[level] = entry.valid ? 1.f : 0.f;
		BakeRect rects[MAX_OUTSTANDING_RECTS];
		const int count = get_outstanding_rects(level, rects, MAX_OUTSTANDING_RECTS);
		outstanding_counts[level] = count;
		for (int index = 0; index < count; index++) {
			outstanding[level * MAX_OUTSTANDING_RECTS + index] = Vector4(real_t(rects[index].x0),
					real_t(rects[index].y0), real_t(rects[index].x1), real_t(rects[index].y1));
		}
	}
	arm["implementation"] = String(TerrainClipmap::implementation_name(TerrainClipmap::Implementation::LOD));
	arm["configured"] = true;
	arm["texture"] = _texture.get_rid();
	arm["size"] = _config.size;
	arm["levels"] = levels;
	arm["base_world"] = _config.base_world;
	arm["channels"] = _config.channels;
	arm["centers"] = centers;
	arm["rings"] = rings;
	arm["valid"] = valid;
	arm["outstanding"] = outstanding;
	arm["outstanding_counts"] = outstanding_counts;
	if (_config.baked_channels >= 3) {
		arm["baked_albedo"] = get_baked_texture_rid(0);
		arm["baked_normal"] = get_baked_texture_rid(1);
		arm["baked_params"] = get_baked_texture_rid(2);
	}
	return arm;
}

Dictionary Terrain3DClipmap::get_address_arm() const {
	Dictionary arm;
	if (!is_configured()) {
		return arm;
	}
	const int levels = get_level_count();
	PackedVector2Array centers;
	PackedVector2Array rings;
	PackedFloat32Array valid;
	centers.resize(MAX_LEVELS);
	rings.resize(MAX_LEVELS);
	valid.resize(MAX_LEVELS);
	for (int level = 0; level < levels; level++) {
		const Level &entry = _levels[size_t(level)];
		centers[level] = entry.center;
		rings[level] = Vector2(real_t(entry.ring.x), real_t(entry.ring.y));
		valid[level] = entry.valid ? 1.f : 0.f;
	}
	arm["centers"] = centers;
	arm["rings"] = rings;
	arm["valid"] = valid;
	return arm;
}

void Terrain3DClipmap::get_address_uniforms(PackedVector4Array &r_addresses,
		PackedVector4Array &r_outstanding, PackedInt32Array &r_outstanding_counts) const {
	const int levels = get_level_count();
	r_addresses.resize(MAX_LEVELS);
	for (int level = 0; level < MAX_LEVELS; level++) {
		const Level *entry = level < levels ? &_levels[size_t(level)] : nullptr;
		const Vector2 center = entry != nullptr ? entry->center : Vector2();
		const Vector2 ring = entry != nullptr ? Vector2(real_t(entry->ring.x), real_t(entry->ring.y)) : Vector2();
		const bool valid = entry != nullptr && entry->valid;
		r_addresses.set(level, Vector4(center.x, center.y, ring.x, ring.y + (valid ? 0.5f : 0.f)));
	}
	get_outstanding_uniforms(r_outstanding, r_outstanding_counts);
}

void Terrain3DClipmap::get_outstanding_uniforms(PackedVector4Array &r_outstanding,
		PackedInt32Array &r_outstanding_counts) const {
	const int levels = get_level_count();
	r_outstanding.resize(MAX_LEVELS * MAX_OUTSTANDING_RECTS);
	r_outstanding_counts.resize(MAX_LEVELS);
	for (int level = 0; level < MAX_LEVELS; level++) {
		const Level *entry = level < levels ? &_levels[size_t(level)] : nullptr;
		BakeRect rects[MAX_OUTSTANDING_RECTS];
		const int count = entry != nullptr ? get_outstanding_rects(level, rects, MAX_OUTSTANDING_RECTS) : 0;
		r_outstanding_counts.set(level, count);
		for (int index = 0; index < MAX_OUTSTANDING_RECTS; index++) {
			const int at = level * MAX_OUTSTANDING_RECTS + index;
			if (index < count) {
				r_outstanding.set(at, Vector4(real_t(rects[index].x0), real_t(rects[index].y0),
						real_t(rects[index].x1), real_t(rects[index].y1)));
			} else {
				r_outstanding.set(at, Vector4());
			}
		}
	}
}
