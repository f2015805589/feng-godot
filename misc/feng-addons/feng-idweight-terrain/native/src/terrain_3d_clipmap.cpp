// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The clipmap delivery's implementation. Read terrain_3d_clipmap.h first: it states the ring's
// invariant and why the stored content never moves, the production budget, what the upload
// accounting is for, and why the channel a level carries lives behind `Terrain3DClipmapSource`
// rather than in this file.

#include "terrain_3d_clipmap.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

#include "logger.h"

// The smallest and largest ring the settings can ask for. A level below 8 texels an axis stops
// being a clipmap (there is no strip left to update); above 4096 the array is larger than any
// budget the addon can produce under.
static constexpr int CLIPMAP_MIN_SIZE = 8;
static constexpr int CLIPMAP_MAX_SIZE = 4096;
static constexpr int CLIPMAP_MAX_CHANNELS = 4;

// One value per texel per layer, so the layer's format is the value's format. A format with more
// components is a different publish, not a different ring.
static int _clipmap_bytes_per_texel(const Image::Format p_format) {
	return p_format == Image::FORMAT_RF ? 4 : 1;
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
	config.levels = CLAMP(config.levels, 1, Terrain3DClipmap::MAX_LEVELS);
	config.base_world = MAX(real_t(0.001), config.base_world);
	config.channels = CLAMP(config.channels, 1, CLIPMAP_MAX_CHANNELS);
	if (config.format != Image::FORMAT_RF && config.format != Image::FORMAT_R8) {
		LOG(ERROR, "Clipmap format ", int(config.format), " has no publish path; using RF");
		config.format = Image::FORMAT_RF;
	}
	if (!_levels.empty() && config.size == _config.size && config.levels == int(_levels.size()) &&
			config.channels == _config.channels && config.format == _config.format &&
			Math::is_equal_approx(config.base_world, _config.base_world)) {
		return;
	}	LOG(INFO, "Configuring clipmap (", get_source_name(), "): ", config.size, " texels, ", config.levels,
			" levels, ", config.channels, " channels, base ", config.base_world, " m");
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
	}
	_row_values.assign(size_t(config.size), 0.f);
	// Content cannot survive a different shape, and neither can the texture the last shape was
	// published into: the layer size and the layer count both changed.
	_jobs.clear();
	_texture.clear();
	_layer_image.unref();
	_has_focus = false;
	_last_focus = Vector2();
	_state_stamp++;
}

void Terrain3DClipmap::clear() {
	_levels.clear();
	_jobs.clear();
	_row_values.clear();
	_texture.clear();
	_layer_image.unref();
	_config.size = 0;
	_config.levels = 0;
	_has_focus = false;
	_last_focus = Vector2();
	_state_stamp++;
}

int Terrain3DClipmap::get_level_valid_count() const {
	int valid = 0;
	for (const Level &level : _levels) {
		if (level.valid) {
			valid++;
		}
	}
	return valid;
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

Vector2 Terrain3DClipmap::world_of_logical(const int p_level, const Vector2i &p_logical) const {
	const Level &entry = _levels[size_t(p_level)];
	const real_t half = entry.world_size * 0.5f;
	return Vector2(entry.center.x - half + (real_t(p_logical.x) + 0.5f) * entry.texel_world,
			entry.center.y - half + (real_t(p_logical.y) + 0.5f) * entry.texel_world);
}

real_t Terrain3DClipmap::sample(const Vector2 &p_world, const int p_channel) const {
	if (_levels.empty()) {
		return NAN;
	}
	const int level_index = level_for_world(p_world);
	const Level &entry = _levels[size_t(level_index)];
	// The inverse of `world_of_logical()`: the texel whose centre the point is nearest, i.e. the one
	// `floor(local / texel)` names. Going through the *logical* index is what undoes the ring; the
	// physical index alone names a different world position after every wrap.
	const Vector2 half(entry.world_size * 0.5f, entry.world_size * 0.5f);
	const Vector2 local = p_world - entry.center + half;
	const Vector2i logical(CLAMP(int(Math::floor(local.x / entry.texel_world)), 0, _config.size - 1),
			CLAMP(int(Math::floor(local.y / entry.texel_world)), 0, _config.size - 1));
	const Vector2i physical = physical_of_logical(level_index, logical);
	return entry.texels[(size_t(physical.y) * size_t(_config.size) + size_t(physical.x)) * size_t(_config.channels) +
			size_t(CLAMP(p_channel, 0, _config.channels - 1))];
}

int Terrain3DClipmap::_wrap(const int p_value) const {
	const int reduced = p_value % _config.size;
	return reduced < 0 ? reduced + _config.size : reduced;
}

Vector2i Terrain3DClipmap::physical_of_logical(const int p_level, const Vector2i &p_logical) const {
	const Vector2i ring = _levels[size_t(p_level)].ring;
	return Vector2i(_wrap(p_logical.x + ring.x), _wrap(p_logical.y + ring.y));
}

Vector2i Terrain3DClipmap::logical_of_physical(const int p_level, const Vector2i &p_physical) const {
	const Vector2i ring = _levels[size_t(p_level)].ring;
	return Vector2i(_wrap(p_physical.x - ring.x), _wrap(p_physical.y - ring.y));
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
	_update_calls++;
	if (!is_configured() || _source == nullptr) {
		return 0;
	}
	// Jobs already queued describe the mapping the levels were advanced to. Re-deriving them from
	// the focus now would discard a partially produced level and produce a rect the ring no longer
	// matches, so the queue is only rebuilt once it is empty.
	if (_jobs.empty()) {
		_rebuild_jobs(p_focus);
	}
	if (_jobs.empty()) {
		_idle_updates++;
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
			_publish_level(level);
			// A level that just became current is a level a reader may now serve, which is addressing
			// state like any other.
			_state_stamp++;
		}
	}
	_jobs = std::move(remaining);
	_last_focus = p_focus;
	return produced;
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
	// The world position of the centre of logical texel (0, 0), which is the inverse of
	// `world_of_logical()` and of `sample()`: all three agree on where a logical texel is.
	const real_t half = entry.world_size * 0.5f;
	const real_t centre_of_first = 0.5f * entry.texel_world;
	row.origin = Vector2(entry.center.x - half + centre_of_first, entry.center.y - half + centre_of_first);
	_source->fill_row(row, _row_values.data());
	// The source never sees a physical index: the ring is undone here, per value, so a wrap cannot
	// reach the producer.
	for (int x = p_x0; x < p_x1; x++) {
		const Vector2i physical = physical_of_logical(p_job.level, Vector2i(x, p_y));
		entry.texels[(size_t(physical.y) * size_t(_config.size) + size_t(physical.x)) * size_t(_config.channels) +
				size_t(p_channel)] = _row_values[size_t(x)];
	}
}

void Terrain3DClipmap::_ensure_texture() {
	const int bytes_per_texel = _clipmap_bytes_per_texel(_config.format);
	const int64_t texels = int64_t(_config.size) * int64_t(_config.size);
	if (_layer_image.is_null() || _layer_image->get_width() != _config.size || _layer_image->get_format() != _config.format) {
		PackedByteArray blank;
		blank.resize(texels * bytes_per_texel);
		_layer_image = Image::create_from_data(_config.size, _config.size, false, _config.format, blank);
	}
	_texture.ensure_layers(_layer_image, int(_levels.size()) * _config.channels);
}

void Terrain3DClipmap::_publish_level(const int p_level) {
	_ensure_texture();
	if (!_texture.get_rid().is_valid()) {
		return;
	}
	const Level &entry = _levels[size_t(p_level)];
	const int64_t texels = int64_t(_config.size) * int64_t(_config.size);
	const int bytes_per_texel = _clipmap_bytes_per_texel(_config.format);
	PackedByteArray bytes;
	bytes.resize(texels * bytes_per_texel);
	uint8_t *dst = bytes.ptrw();
	for (int channel = 0; channel < _config.channels; channel++) {
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
		_texture.update(image, p_level * _config.channels + channel);
		_upload_bytes += uint64_t(texels * bytes_per_texel);
	}
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
		reports.push_back(report);
	}
	return reports;
}

Array Terrain3DClipmap::get_layout_reports() const {
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
		// What is left of this level's jobs, in world space, because that is what a debug view draws
		// and because a queued rect is the one thing a settled report cannot show. A rect the budget
		// cut short is up to *two* rects - the rest of the row it stopped inside, then the rows below
		// it - since a partial row with the rows under it is not a rectangle. `cursor_channel` above
		// zero means the row itself is unfinished, so it is pending from its own start.
		Array rects;
		int pending = 0;
		for (const Job &job : _jobs) {
			if (job.level != level) {
				continue;
			}
			pending++;
			const int open_x0 = job.cursor_channel == 0 ? job.cursor_x : job.x0;
			if (open_x0 == job.x0) {
				rects.push_back(_clipmap_logical_rect_world(entry, job.x0, job.cursor_y, job.x1, job.y1));
				continue;
			}
			rects.push_back(_clipmap_logical_rect_world(entry, open_x0, job.cursor_y, job.x1, job.cursor_y + 1));
			if (job.cursor_y + 1 < job.y1) {
				rects.push_back(_clipmap_logical_rect_world(entry, job.x0, job.cursor_y + 1, job.x1, job.y1));
			}
		}
		report["pending"] = pending;
		report["pending_rects"] = rects;
		reports.push_back(report);
	}
	return reports;
}
