// Page-arrival fade: the ramp the shader blends an arriving page with, and the flag that decides
// when one has arrived.
//
// It is its own file because it is the one part of the VT tick that runs on *every* tick whether or
// not a demand pass had anything to do, and because it is what makes a page arrival a ramp instead
// of a step - which is exactly what a fast turn makes visible, since the view then refines in the
// rectangular grid its pages are. A burst of arrivals is *held* and released a few ramps per tick
// for the same reason one arrival is ramped: a whole block sharpening on one tick reads as a
// flicker however smooth each page's own ramp is. Everything it needs is a per-slot flag, set where
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

namespace {
// Ramps that may start on one tick when there is nothing to spread out: an isolated arrival, or a
// backlog no larger than this. It is a floor rather than the whole rate because a page that landed
// alone must not wait for company - and it is more than one because a pair landing together is the
// smallest thing a wash is worth spreading.
constexpr int FADE_STARTS_FLOOR = 2;
} // namespace

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
	}
	_vt.vt_slot_pending[slot] = PageArrival::WAITING;
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
	if (_vt.vt_page_fade_texture.is_null() || int(_vt.vt_slot_fade_ticks.size()) != slots) {
		// Keep the ramps that are already running: a slot keeps its index when the pool's page
		// count changes, so the counters are still that slot's, and reinitializing them would end
		// a ramp in flight - an arrival that has already begun to blend would finish as a step.
		// The texture is seeded from the counters rather than from settled for the same reason.
		_vt.vt_slot_fade_ticks.resize(size_t(slots), 0);
		_vt.vt_slot_pending.resize(size_t(slots), PageArrival::SETTLED);
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
			// The content landed, so the slot is armed at zero - what the shader reads meanwhile
			// is the level this page replaces - and it joins the order below rather than starting
			// its ramp here. That is what lets a burst be spread over the ticks that follow.
			const size_t slot = size_t(_vt.vt_page_fade_waiting[i]);
			_vt.vt_slot_pending[slot] = PageArrival::ARMED;
			_vt.vt_slot_fade_ticks[slot] = uint8_t(MIN(255, frames));
			_vt.vt_page_fade_queue.push_back(int(slot));
			landed = true;
			++armed;
		}
	}
	// Release a few armed slots per tick, oldest first. This is the whole of the anti-flicker
	// measure: a burst that lands together would otherwise start every ramp on the same tick, and
	// the block would sharpen as one step - which is what a view that is turning shows, because a
	// turn is what makes a burst. At least two ramps start per tick, and a backlog larger than the
	// ramp's own length is spread over it, so a burst sharpens in about the time one ramp takes.
	// An armed slot is not blurry and not late: it is showing the level its page is replacing, at
	// the weight that level would have had on its own.
	held += armed;
	_vt.vt_page_fade_held = held;
	const int per_tick = MAX(FADE_STARTS_FLOOR, (held + frames - 1) / frames);
	int released = 0;
	while (released < per_tick && _vt.vt_page_fade_queue_at < _vt.vt_page_fade_queue.size()) {
		const int slot = _vt.vt_page_fade_queue[_vt.vt_page_fade_queue_at++];
		// A stale entry is dropped rather than trusted: a slot re-armed since it was queued, or
		// one the pool no longer has, is not the arrival this entry describes.
		if (slot < 0 || slot >= slots || _vt.vt_slot_pending[size_t(slot)] != PageArrival::ARMED) { continue; }
		_vt.vt_slot_pending[size_t(slot)] = PageArrival::SETTLED;
		++_vt.vt_page_fade_starts;
		++released;
	}
	if (released > _vt.vt_page_fade_starts_peak) { _vt.vt_page_fade_starts_peak = released; }
	if (_vt.vt_page_fade_queue_at >= _vt.vt_page_fade_queue.size()) {
		_vt.vt_page_fade_queue.clear();
		_vt.vt_page_fade_queue_at = 0;
	}
	// A fade steps down once per tick, so a run of ticks with nothing arriving is a loop over
	// the active slots and no upload. An armed slot is skipped: its countdown has not started, and
	// the level it shows is what its own arrival is being blended against.
	bool any_active = false;
	int ramping = 0;
	_vt.vt_page_fade_ticks_max = 0;
	for (int slot = 0; slot < slots; ++slot) {
		if (_vt.vt_slot_pending[size_t(slot)] == PageArrival::WAITING) { ++_vt.vt_page_fade_pending; }
		if (_vt.vt_slot_pending[size_t(slot)] == PageArrival::ARMED) { continue; }
		uint8_t &ticks = _vt.vt_slot_fade_ticks[size_t(slot)];
		if (ticks == 0) { continue; }
		_vt.vt_page_fade_ticks_max = MAX(_vt.vt_page_fade_ticks_max, int(ticks));
		--ticks;
		++ramping;
		any_active = true;
	}
	// A tick that armed a slot has a byte to publish even when no ramp is running: an armed slot
	// reads zero until its ramp starts, and that zero is what holds its replacement's level there.
	if (!any_active && !landed && released == 0) { return; }
	PackedByteArray bytes;
	bytes.resize(slots);
	uint8_t *output = bytes.ptrw();
	for (int slot = 0; slot < slots; ++slot) {
		const int ticks = _vt.vt_slot_fade_ticks[size_t(slot)];
		output[slot] = ticks <= 0 ? 255 : uint8_t(255 - (ticks * 255) / frames);
	}
	_vt.vt_page_fade_image->set_data(slots, 1, false, Image::FORMAT_R8, bytes);
	_vt.vt_page_fade_texture->update(_vt.vt_page_fade_image);
	// The ramps actually running, not the slots the texture was published for: a tick that only
	// armed an arrival publishes a byte without a ramp behind it, and a count that included those
	// would read as a view that is fading when it is only holding.
	_vt.vt_page_fade_active = ramping;
}

void Terrain3D::set_vt_page_fade_frames(int p_frames) {
	p_frames = CLAMP(p_frames, 0, 60);
	if (_vt.vt_page_fade_frames == p_frames) { return; }
	_vt.vt_page_fade_frames = p_frames;
	// A disabled fade is the shader's own early out, and the settled texture already reads as
	// "no fade", so switching it off needs no texture work.
	if (p_frames == 0) {
		// Nothing is fading and nothing is owed once the feature is off, so the armed slots and the
		// order they were waiting in go with the counters.
		_vt.vt_slot_fade_ticks.clear();
		_vt.vt_slot_pending.clear();
		_vt.vt_page_fade_queue.clear();
		_vt.vt_page_fade_queue_at = 0;
	}
	if (_material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
}
