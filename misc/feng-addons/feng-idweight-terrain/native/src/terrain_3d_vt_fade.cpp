// Page-arrival fade: the ramp the shader blends an arriving page with, and the flag that decides
// when one has arrived.
//
// It is its own file because it is the one part of the VT tick that runs on *every* tick whether or
// not a demand pass had anything to do, and because it is what makes a page arrival a ramp instead
// of a step - which is exactly what a fast turn makes visible, since the view then refines in the
// rectangular grid its pages are. Pages that finish together start their ramps together:
// staggering already-ready pages adds latency and exposes a moving page grid. Everything it
// needs is a per-slot flag, set where
// content is removed or queued (terrain_3d_vt_service.cpp), and the producer's readiness for the
// slots that flag names, which it reads once for the whole waiting set.
//
// The flag has exactly two writers, and they are the only two places a slot's content can change:
// `_invalidate_vt_slot()` and `_queue_vt_material_page()`, both in terrain_3d_vt_service.cpp. Every
// production path in the addon - near field, far field, diagnostic and bake - funnels through one of
// them, so an arrival that did not fade is either a slot that changed content outside those two or
// a ramp the shader did not read, and there is no third possibility to look for.
//
// The far field's demand pass, its root pyramid plan and its visible walk stay in
// terrain_3d_surface_views_far_walk.cpp, and the shared "is this page actually there" helper is
// page plumbing in terrain_3d_vt_service_pages.cpp; the tick that calls this pass is in terrain_3d.cpp.
#include "terrain_3d.h"
#include "terrain_3d_material.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_virtual_texture.h"
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>

// A slot whose content is missing, dropped, or still being produced. Whatever it holds next is
// an arrival, and that is the only thing the fade needs to know about it: `_update_vt_page_fade()`
// reads the flag against the producer's readiness and starts the ramp there.
//
// It is set where content is removed or queued - the invalidation a produced page begins with,
// and every queue call - rather than by each demand pass's readiness check. A demand pass is not
// a place an arrival can be trusted to: the near field stops classifying once its view is settled,
// so the last page of a burst - the one a turning view shows changing under the cursor - arrived
// with no pass left to notice it.
void Terrain3D::_vt_mark_page_waiting(int p_slot) {
	if (_vt.vt_page_fade_frames <= 0 || p_slot < 0) { return; }
	const size_t slot = size_t(p_slot);
	// Growing a slot is the struct's own operation, so every per-slot vector grows together: they
	// are one fact, and a slot index past one of them is past all of them. This can run before the
	// fade's texture is first published; the fade update then sizes the vectors to the pool's page
	// count and keeps what is recorded here.
	_vt.fade.ensure_slot(p_slot);
	// A slot may be invalidated again while an older arrival is still in the FIFO. Remove that
	// older record before marking the new content as waiting; one physical slot has one current
	// arrival, so no generation number or stale queue scan is needed.
	_vt.fade.queue.remove(p_slot);
	_vt.fade.arrival[slot] = PageArrival::WAITING;
	_vt.fade.ticks[slot] = uint8_t(MIN(255, MAX(1, _vt.vt_page_fade_frames)));
	_vt.fade.just_started[slot] = 0;
	_vt.fade.dirty = true;
}

// Publishes the per-slot arrival fade the shader blends with. The texture is one byte per
// physical slot, indexed by the slot the indirection lookup already decoded, so the fade costs
// the shader one extra fetch and no address arithmetic. A settled slot reads 255 (fade 1, the
// page itself), which is what the whole texture holds when nothing is arriving - so a settled
// view uploads nothing at all.
//
// This pass also decides what an arrival is: a slot that was waiting for content and has content
// now. It owns that judgement because it runs on every tick, while the passes that produce pages
// do not, so a page arriving after the view settled publishes its ramp here or not at all.
void Terrain3D::_update_vt_page_fade() {
	_vt.fade.active = 0;
	_vt.fade.pending = 0;
	_vt.fade.held = 0;
	if (_vt.vt_page_fade_frames <= 0 || !_vt.vt_shared_ready) { return; }
	// The fade is per *physical slot* of the shared pool, so the view it asks is whichever one
	// exists: requiring the near view made a far-only configuration publish no ramps at all, which
	// is a page arriving as a step - the defect this pass exists to remove - on the tier that has
	// the coarser pages and therefore the more visible steps.
	const Terrain3DVirtualTexture *fade_view = _vt.surface_vt ? _vt.surface_vt : _vt.surface_svt;
	if (fade_view == nullptr) { return; }
	const int slots = MAX(1, fade_view->get_page_count());
	const int frames = MAX(1, _vt.vt_page_fade_frames);
	if (_vt.fade.queue.capacity() != size_t(slots)) {
		_vt.fade.queue.resize(size_t(slots));
	}
	if (_vt.fade.texture.is_null() || int(_vt.fade.slot_count()) != slots) {
		// Keep the ramps that are already running: a slot keeps its index when the pool's page
		// count changes, so the counters are still that slot's, and reinitializing them would end
		// a ramp in flight - an arrival that has already begun to blend would finish as a step.
		// The texture is seeded from the counters rather than from settled for the same reason.
		_vt.fade.resize_slots(size_t(slots));
		PackedByteArray settled;
		settled.resize(slots);
		uint8_t *output = settled.ptrw();
		for (int slot = 0; slot < slots; ++slot) {
			const int ticks = int(_vt.fade.ticks[size_t(slot)]);
			output[slot] = ticks <= 0 ? 255 : uint8_t(255 - (ticks * 255) / frames);
		}
		Ref<Image> image = Image::create_from_data(slots, 1, false, Image::FORMAT_R8, settled);
		if (image.is_null()) { return; }
		_vt.fade.image = image;
		_vt.fade.texture = ImageTexture::create_from_image(image);
		// The material has to be told about a texture it has not been bound to before.
		if (_material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
		if (_vt.fade.texture.is_null()) { return; }
	}
	// Which slots are waiting for content now, and how many are already armed: one read of the
	// producer's array. The waiting set is a handful of slots even on a moving view, so this is one
	// lock rather than one per slot.
	_vt.fade.waiting.clear();
	int held = 0;
	for (int slot = 0; slot < slots; ++slot) {
		const PageArrival state = _vt.fade.arrival[size_t(slot)];
		if (state == PageArrival::WAITING) {
			_vt.fade.waiting.push_back(slot);
		} else if (state == PageArrival::ARMED) {
			++held;
		}
	}
	bool landed = false;
	int armed = 0;
	if (!_vt.fade.waiting.empty()) {
		const Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
		if (producer) {
			producer->query_page_readiness(_vt.fade.waiting, _vt.fade.ready);
		} else {
			_vt.fade.ready.assign(_vt.fade.waiting.size(), 1);
		}
		for (size_t i = 0; i < _vt.fade.waiting.size(); ++i) {
			const bool ready = i < _vt.fade.ready.size() && _vt.fade.ready[i] != 0;
			if (!ready) { continue; }
			// Arm at zero, then publish every completed page in this batch together.
			// The first displayed sample remains its parent; only the ramp changes it.
			const size_t slot = size_t(_vt.fade.waiting[i]);
			_vt.fade.arrival[slot] = PageArrival::ARMED;
			_vt.fade.ticks[slot] = uint8_t(MIN(255, frames));
			_vt.fade.queue.enqueue(int(slot));
			landed = true;
			++armed;
		}
	}
	// Production already has a bounded per-tick budget. Do not impose a second
	// throughput limit on content that is ready: that keeps nearby detail blurry
	// and starts neighbouring pages on visibly different clocks.
	held += armed;
	int released = 0;
	int slot = -1;
	while (_vt.fade.queue.pop(slot)) {
		// The slot is normally still armed. Keep the state check as a cheap defensive guard for a
		// service reset that raced a queued result; the queue itself has no stale historical entries.
		if (slot < 0 || slot >= slots || _vt.fade.arrival[size_t(slot)] != PageArrival::ARMED) { continue; }
		_vt.fade.arrival[size_t(slot)] = PageArrival::SETTLED;
		_vt.fade.just_started[size_t(slot)] = 1;
		++_vt.fade.starts;
		++released;
	}
	_vt.fade.held = MAX(0, held - released);
	if (released > _vt.fade.starts_peak) { _vt.fade.starts_peak = released; }
	// A fade steps down once per tick, so a run of ticks with nothing arriving is a loop over
	// the active slots and no upload. An armed slot is skipped: its countdown has not started, and
	// the level it shows is what its own arrival is being blended against.
	bool any_active = false;
	int ramping = 0;
	_vt.fade.ticks_max = 0;
	for (int slot = 0; slot < slots; ++slot) {
		const size_t index = size_t(slot);
		if (_vt.fade.arrival[index] == PageArrival::WAITING) {
			++_vt.fade.pending;
			// Waiting content must keep the replacement-level byte at zero. It is not a ramp and
			// must not count down while the producer is still working.
			continue;
		}
		if (_vt.fade.arrival[index] == PageArrival::ARMED) { continue; }
		uint8_t &ticks = _vt.fade.ticks[index];
		if (ticks == 0) { continue; }
		_vt.fade.ticks_max = MAX(_vt.fade.ticks_max, int(ticks));
		if (_vt.fade.just_started[index] != 0) {
			// The release tick publishes the first zero-weight frame. Countdown starts on the
			// following tick, so the first visible step is never 1/frames.
			_vt.fade.just_started[index] = 0;
			continue;
		}
		--ticks;
		++ramping;
		any_active = true;
	}
	// A tick that armed a slot has a byte to publish even when no ramp is running: an armed slot
	// reads zero until its ramp starts, and that zero is what holds its replacement's level there.
	if (!any_active && !landed && released == 0 && !_vt.fade.dirty) { return; }
	PackedByteArray bytes;
	bytes.resize(slots);
	uint8_t *output = bytes.ptrw();
	for (int slot = 0; slot < slots; ++slot) {
		const int ticks = _vt.fade.ticks[size_t(slot)];
		output[slot] = ticks <= 0 ? 255 : uint8_t(255 - (ticks * 255) / frames);
	}
	_vt.fade.image->set_data(slots, 1, false, Image::FORMAT_R8, bytes);
	_vt.fade.texture->update(_vt.fade.image);
	_vt.fade.dirty = false;
	// The ramps actually running, not the slots the texture was published for: a tick that only
	// armed an arrival publishes a byte without a ramp behind it, and a count that included those
	// would read as a view that is fading when it is only holding.
	_vt.fade.active = ramping;
}

// A page pool rebuild invalidates every physical slot index, so the fade drops the state built
// from it. The counters that say where the ramps are stay cumulative; the struct's own note says
// which ones and why.
void Terrain3D::_reset_vt_page_fade() {
	_vt.fade.reset_for_pool();
}

void Terrain3D::set_vt_page_fade_frames(int p_frames) {
	p_frames = CLAMP(p_frames, 0, 60);
	if (_vt.vt_page_fade_frames == p_frames) { return; }
	const int old_frames = _vt.vt_page_fade_frames;
	_vt.vt_page_fade_frames = p_frames;
	if (old_frames > 0 && p_frames > 0) {
		// Preserve the current normalized blend when the ramp length changes. Waiting and armed
		// slots have not started their ramp, so they are simply prepared at the new length. This
		// keeps the setter from publishing an out-of-range byte or wrapping uint8_t when a live
		// ramp is shortened.
		const size_t count = _vt.fade.slot_count();
		bool changed = false;
		for (size_t slot = 0; slot < count; ++slot) {
			if (_vt.fade.arrival[slot] == PageArrival::WAITING ||
					_vt.fade.arrival[slot] == PageArrival::ARMED) {
				_vt.fade.ticks[slot] = uint8_t(p_frames);
				changed = true;
				continue;
			}
			const int old_ticks = MIN(old_frames, int(_vt.fade.ticks[slot]));
			if (old_ticks <= 0) { continue; }
			_vt.fade.ticks[slot] = uint8_t(
					MIN(p_frames, (old_ticks * p_frames + old_frames - 1) / old_frames));
			changed = true;
		}
		if (changed) { _vt.fade.dirty = true; }
	}
	// A disabled fade is the shader's own early out, and the settled texture already reads as
	// "no fade", so switching it off needs no texture work.
	if (p_frames == 0) {
		// Nothing is fading and nothing is owed once the feature is off, so the armed slots and the
		// order they were waiting in go with the counters.
		_reset_vt_page_fade();
	}
	if (_material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
}

// The fade's half of `get_vt_settings()`, in the order a reader asks about it: the requested ramp
// length, the ramps the last tick advanced, the arrivals still waiting for content, the ones armed
// and waiting their turn, the ramps started, the most one tick has started - which is what says
// whether a burst is being spread or is still arriving as one step - and the longest ramp still
// running. It is written here rather than in the report file because every key below reads this
// file's own state.
void Terrain3D::_report_vt_fade(Dictionary &r_result) const {
	Dictionary &result = r_result;
	result["vt_page_fade_frames"] = _vt.vt_page_fade_frames;
	result["vt_page_fade_active_slots"] = _vt.fade.active;
	result["vt_page_fade_pending_slots"] = _vt.fade.pending;
	result["vt_page_fade_held_slots"] = _vt.fade.held;
	result["vt_page_fade_starts"] = int64_t(_vt.fade.starts);
	result["vt_page_fade_starts_peak"] = _vt.fade.starts_peak;
	result["vt_page_fade_ticks_max"] = _vt.fade.ticks_max;
	// The FIFO has one node per physical slot. Its live length describes the armed arrivals, while
	// capacity proves that historical arrivals do not leave a consumed prefix behind.
	result["vt_page_fade_queue_size"] = int64_t(_vt.fade.queue.size());
	result["vt_page_fade_queue_capacity"] = int64_t(_vt.fade.queue.capacity());
}
