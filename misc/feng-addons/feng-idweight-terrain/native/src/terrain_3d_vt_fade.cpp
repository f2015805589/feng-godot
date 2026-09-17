// Page-arrival fade: the ramp the shader blends an arriving page with, and the flag that decides
// when one has arrived.
//
// It is its own file because it is the one part of the VT tick that runs on *every* tick whether or
// not a demand pass had anything to do, and because it is what makes a page arrival a ramp instead
// of a step - which is exactly what a fast turn makes visible, since the view then refines in the
// rectangular grid its pages are. Everything it needs is a per-slot flag, set where content is
// removed or queued (terrain_3d_surface_vt.cpp), and the producer's readiness for the slots that
// flag names, which it reads once for the whole waiting set.
//
// The flag has exactly two writers, and they are the only two places a slot's content can change:
// `_invalidate_vt_slot()` and `_queue_vt_material_page()`, both in terrain_3d_surface_vt.cpp. Every
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
		_vt.vt_slot_pending.resize(needed, 0);
		_vt.vt_slot_fade_ticks.resize(needed, 0);
	}
	_vt.vt_slot_pending[slot] = 1;
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
	if (_vt.vt_page_fade_frames <= 0 || !_vt.surface_vt || !_vt.vt_shared_ready) { return; }
	const int slots = MAX(1, _vt.surface_vt->get_page_count());
	if (_vt.vt_page_fade_texture.is_null() || int(_vt.vt_slot_fade_ticks.size()) != slots) {
		// Keep the ramps that are already running: a slot keeps its index when the pool's page
		// count changes, so the counters are still that slot's, and reinitializing them would end
		// a ramp in flight - an arrival that has already begun to blend would finish as a step.
		// The texture is seeded from the counters rather than from settled for the same reason.
		_vt.vt_slot_fade_ticks.resize(size_t(slots), 0);
		_vt.vt_slot_pending.resize(size_t(slots), 0);
		PackedByteArray settled;
		settled.resize(slots);
		uint8_t *output = settled.ptrw();
		const int frames = MAX(1, _vt.vt_page_fade_frames);
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
	// Which waiting slots have content now, in one read of the producer's array: the waiting set
	// is a handful of slots even on a moving view, so this is one lock rather than one per slot.
	_vt.vt_page_fade_waiting.clear();
	for (int slot = 0; slot < slots; ++slot) {
		if (_vt.vt_slot_pending[size_t(slot)] != 0) { _vt.vt_page_fade_waiting.push_back(slot); }
	}
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
			const size_t slot = size_t(_vt.vt_page_fade_waiting[i]);
			_vt.vt_slot_pending[slot] = 0;
			_vt.vt_slot_fade_ticks[slot] = uint8_t(MIN(255, _vt.vt_page_fade_frames));
			_vt.vt_page_fade_starts++;
		}
	}
	// A fade steps down once per tick, so a run of ticks with nothing arriving is a loop over
	// the active slots and no upload.
	bool any_active = false;
	_vt.vt_page_fade_ticks_max = 0;
	for (int slot = 0; slot < slots; ++slot) {
		if (_vt.vt_slot_pending[size_t(slot)] != 0) { ++_vt.vt_page_fade_pending; }
		uint8_t &ticks = _vt.vt_slot_fade_ticks[size_t(slot)];
		if (ticks == 0) { continue; }
		_vt.vt_page_fade_ticks_max = MAX(_vt.vt_page_fade_ticks_max, int(ticks));
		--ticks;
		any_active = true;
	}
	if (!any_active) { return; }
	PackedByteArray bytes;
	bytes.resize(slots);
	uint8_t *output = bytes.ptrw();
	const int frames = MAX(1, _vt.vt_page_fade_frames);
	for (int slot = 0; slot < slots; ++slot) {
		const int ticks = _vt.vt_slot_fade_ticks[size_t(slot)];
		output[slot] = ticks <= 0 ? 255 : uint8_t(255 - (ticks * 255) / frames);
	}
	_vt.vt_page_fade_image->set_data(slots, 1, false, Image::FORMAT_R8, bytes);
	_vt.vt_page_fade_texture->update(_vt.vt_page_fade_image);
	_vt.vt_page_fade_active = slots;
}

void Terrain3D::set_vt_page_fade_frames(int p_frames) {
	p_frames = CLAMP(p_frames, 0, 60);
	if (_vt.vt_page_fade_frames == p_frames) { return; }
	_vt.vt_page_fade_frames = p_frames;
	// A disabled fade is the shader's own early out, and the settled texture already reads as
	// "no fade", so switching it off needs no texture work.
	if (p_frames == 0) { _vt.vt_slot_fade_ticks.clear(); _vt.vt_slot_pending.clear(); }
	if (_material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
}
