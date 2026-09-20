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
// The far field's demand pass, its root pyramid plan and the shared "is this page actually there"
// helper stay in terrain_3d_vt_demand.cpp; the tick that calls this pass is in terrain_3d.cpp.
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
	// The two per-slot vectors are the same length by construction, so a slot beyond them is
	// added to both. This can run before the fade's texture is first published, and the fade
	// update then resizes them to the pool's page count and keeps what is already recorded.
	if (slot >= _vt.vt_slot_pending.size()) {
		// Never a shrink: a resize to the slot below the length the fade pass published would
		// drop the counters of every slot above it, and with them the ramps that are running -
		// a page arriving mid-blend would finish as a step. The fade pass resizes both to the
		// pool's page count on its next run and keeps what is recorded here.
		const size_t needed = MAX(slot + 1, _vt.vt_slot_pending.size());
		_vt.vt_slot_pending.resize(needed, PageArrival::SETTLED);
		_vt.vt_slot_fade_ticks.resize(needed, 0);
		_vt.vt_slot_fade_just_started.resize(needed, 0);
	}
	if (slot >= _vt.vt_slot_fade_just_started.size()) {
		_vt.vt_slot_fade_just_started.resize(slot + 1, 0);
	}
	// A slot may be invalidated again while an older arrival is still in the FIFO. Remove that
	// older record before marking the new content as waiting; one physical slot has one current
	// arrival, so no generation number or stale queue scan is needed.
	_vt.vt_page_fade_queue.remove(p_slot);
	_vt.vt_slot_pending[slot] = PageArrival::WAITING;
	_vt.vt_slot_fade_ticks[slot] = uint8_t(MIN(255, MAX(1, _vt.vt_page_fade_frames)));
	_vt.vt_slot_fade_just_started[slot] = 0;
	_vt.vt_page_fade_dirty = true;
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
	_vt.vt_page_fade_active = 0;
	_vt.vt_page_fade_pending = 0;
	_vt.vt_page_fade_held = 0;
	if (_vt.vt_page_fade_frames <= 0 || !_vt.surface_vt || !_vt.vt_shared_ready) { return; }
	const int slots = MAX(1, _vt.surface_vt->get_page_count());
	const int frames = MAX(1, _vt.vt_page_fade_frames);
	if (_vt.vt_page_fade_queue.capacity() != size_t(slots)) {
		_vt.vt_page_fade_queue.resize(size_t(slots));
	}
	if (_vt.vt_page_fade_texture.is_null() || int(_vt.vt_slot_fade_ticks.size()) != slots) {
		// Keep the ramps that are already running: a slot keeps its index when the pool's page
		// count changes, so the counters are still that slot's, and reinitializing them would end
		// a ramp in flight - an arrival that has already begun to blend would finish as a step.
		// The texture is seeded from the counters rather than from settled for the same reason.
		_vt.vt_slot_fade_ticks.resize(size_t(slots), 0);
		_vt.vt_slot_pending.resize(size_t(slots), PageArrival::SETTLED);
		_vt.vt_slot_fade_just_started.resize(size_t(slots), 0);
		PackedByteArray settled;
		settled.resize(slots);
		uint8_t *output = settled.ptrw();
		for (int slot = 0; slot < slots; ++slot) {
			const int ticks = int(_vt.vt_slot_fade_ticks[size_t(slot)]);
			output[slot] = ticks <= 0 ? 255 : uint8_t(255 - (ticks * 255) / frames);
		}
		Ref<Image> image = Image::create_from_data(slots, 1, false, Image::FORMAT_R8, settled);
		if (image.is_null()) { return; }
		_vt.vt_page_fade_image = image;
		_vt.vt_page_fade_texture = ImageTexture::create_from_image(image);
		// The material has to be told about a texture it has not been bound to before.
		if (_material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
		if (_vt.vt_page_fade_texture.is_null()) { return; }
	}
	if (int(_vt.vt_slot_fade_just_started.size()) != slots) {
		_vt.vt_slot_fade_just_started.resize(size_t(slots), 0);
	}
	// Which slots are waiting for content now, and how many are already armed: one read of the
	// producer's array. The waiting set is a handful of slots even on a moving view, so this is one
	// lock rather than one per slot.
	_vt.vt_page_fade_waiting.clear();
	int held = 0;
	for (int slot = 0; slot < slots; ++slot) {
		const PageArrival state = _vt.vt_slot_pending[size_t(slot)];
		if (state == PageArrival::WAITING) {
			_vt.vt_page_fade_waiting.push_back(slot);
		} else if (state == PageArrival::ARMED) {
			++held;
		}
	}
	bool landed = false;
	int armed = 0;
	if (!_vt.vt_page_fade_waiting.empty()) {
		const Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
		if (producer) {
			producer->query_page_readiness(_vt.vt_page_fade_waiting, _vt.vt_page_fade_ready);
		} else {
			_vt.vt_page_fade_ready.assign(_vt.vt_page_fade_waiting.size(), 1);
		}
		for (size_t i = 0; i < _vt.vt_page_fade_waiting.size(); ++i) {
			const bool ready = i < _vt.vt_page_fade_ready.size() && _vt.vt_page_fade_ready[i] != 0;
			if (!ready) { continue; }
			// Arm at zero, then publish every completed page in this batch together.
			// The first displayed sample remains its parent; only the ramp changes it.
			const size_t slot = size_t(_vt.vt_page_fade_waiting[i]);
			_vt.vt_slot_pending[slot] = PageArrival::ARMED;
			_vt.vt_slot_fade_ticks[slot] = uint8_t(MIN(255, frames));
			_vt.vt_page_fade_queue.enqueue(int(slot));
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
	while (_vt.vt_page_fade_queue.pop(slot)) {
		// The slot is normally still armed. Keep the state check as a cheap defensive guard for a
		// service reset that raced a queued result; the queue itself has no stale historical entries.
		if (slot < 0 || slot >= slots || _vt.vt_slot_pending[size_t(slot)] != PageArrival::ARMED) { continue; }
		_vt.vt_slot_pending[size_t(slot)] = PageArrival::SETTLED;
		_vt.vt_slot_fade_just_started[size_t(slot)] = 1;
		++_vt.vt_page_fade_starts;
		++released;
	}
	_vt.vt_page_fade_held = MAX(0, held - released);
	if (released > _vt.vt_page_fade_starts_peak) { _vt.vt_page_fade_starts_peak = released; }
	// A fade steps down once per tick, so a run of ticks with nothing arriving is a loop over
	// the active slots and no upload. An armed slot is skipped: its countdown has not started, and
	// the level it shows is what its own arrival is being blended against.
	bool any_active = false;
	int ramping = 0;
	_vt.vt_page_fade_ticks_max = 0;
	for (int slot = 0; slot < slots; ++slot) {
		const size_t index = size_t(slot);
		if (_vt.vt_slot_pending[index] == PageArrival::WAITING) {
			++_vt.vt_page_fade_pending;
			// Waiting content must keep the replacement-level byte at zero. It is not a ramp and
			// must not count down while the producer is still working.
			continue;
		}
		if (_vt.vt_slot_pending[index] == PageArrival::ARMED) { continue; }
		uint8_t &ticks = _vt.vt_slot_fade_ticks[index];
		if (ticks == 0) { continue; }
		_vt.vt_page_fade_ticks_max = MAX(_vt.vt_page_fade_ticks_max, int(ticks));
		if (_vt.vt_slot_fade_just_started[index] != 0) {
			// The release tick publishes the first zero-weight frame. Countdown starts on the
			// following tick, so the first visible step is never 1/frames.
			_vt.vt_slot_fade_just_started[index] = 0;
			continue;
		}
		--ticks;
		++ramping;
		any_active = true;
	}
	// A tick that armed a slot has a byte to publish even when no ramp is running: an armed slot
	// reads zero until its ramp starts, and that zero is what holds its replacement's level there.
	if (!any_active && !landed && released == 0 && !_vt.vt_page_fade_dirty) { return; }
	PackedByteArray bytes;
	bytes.resize(slots);
	uint8_t *output = bytes.ptrw();
	for (int slot = 0; slot < slots; ++slot) {
		const int ticks = _vt.vt_slot_fade_ticks[size_t(slot)];
		output[slot] = ticks <= 0 ? 255 : uint8_t(255 - (ticks * 255) / frames);
	}
	_vt.vt_page_fade_image->set_data(slots, 1, false, Image::FORMAT_R8, bytes);
	_vt.vt_page_fade_texture->update(_vt.vt_page_fade_image);
	_vt.vt_page_fade_dirty = false;
	// The ramps actually running, not the slots the texture was published for: a tick that only
	// armed an arrival publishes a byte without a ramp behind it, and a count that included those
	// would read as a view that is fading when it is only holding.
	_vt.vt_page_fade_active = ramping;
}

// A page pool rebuild invalidates every physical slot index. Drop the fade texture and all
// per-slot arrival state with it, so a slot number reused by the new pool cannot inherit an old
// arrival or an armed FIFO node. Cumulative start diagnostics intentionally remain cumulative;
// the live counters describe the new pool from this point onward.
void Terrain3D::_reset_vt_page_fade() {
	_vt.vt_slot_fade_ticks.clear();
	_vt.vt_slot_pending.clear();
	_vt.vt_slot_fade_just_started.clear();
	_vt.vt_page_fade_queue.reset();
	_vt.vt_page_fade_waiting.clear();
	_vt.vt_page_fade_ready.clear();
	_vt.vt_page_fade_image.unref();
	_vt.vt_page_fade_texture.unref();
	_vt.vt_page_fade_dirty = false;
	_vt.vt_page_fade_active = 0;
	_vt.vt_page_fade_pending = 0;
	_vt.vt_page_fade_held = 0;
	_vt.vt_page_fade_ticks_max = 0;
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
		const size_t count = MIN(_vt.vt_slot_fade_ticks.size(), _vt.vt_slot_pending.size());
		bool changed = false;
		for (size_t slot = 0; slot < count; ++slot) {
			if (_vt.vt_slot_pending[slot] == PageArrival::WAITING ||
					_vt.vt_slot_pending[slot] == PageArrival::ARMED) {
				_vt.vt_slot_fade_ticks[slot] = uint8_t(p_frames);
				changed = true;
				continue;
			}
			const int old_ticks = MIN(old_frames, int(_vt.vt_slot_fade_ticks[slot]));
			if (old_ticks <= 0) { continue; }
			_vt.vt_slot_fade_ticks[slot] = uint8_t(
					MIN(p_frames, (old_ticks * p_frames + old_frames - 1) / old_frames));
			changed = true;
		}
		if (changed) { _vt.vt_page_fade_dirty = true; }
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
