// Bounded FIFO for physical virtual-texture page arrivals.
//
// There is one node per physical slot.  Re-queuing a slot removes its previous
// node before appending it, so the queue cannot retain a consumed prefix or an
// obsolete record for a slot that has been reused.  The queue is intentionally
// header-only: it is a small state holder used by the fade pass and has no
// dependency on Terrain3D or on the renderer.

#ifndef TERRAIN_VT_ARRIVAL_QUEUE_H
#define TERRAIN_VT_ARRIVAL_QUEUE_H

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace TerrainVT {

class PageArrivalQueue {
	std::vector<int> _next;
	std::vector<int> _previous;
	std::vector<uint8_t> _queued;
	int _head = -1;
	int _tail = -1;
	std::size_t _size = 0;

	bool is_valid_slot(int p_slot) const {
		return p_slot >= 0 && std::size_t(p_slot) < _queued.size();
	}

	void append_unlinked(int p_slot) {
		_next[std::size_t(p_slot)] = -1;
		_previous[std::size_t(p_slot)] = _tail;
		if (_tail >= 0) {
			_next[std::size_t(_tail)] = p_slot;
		} else {
			_head = p_slot;
		}
		_tail = p_slot;
		_queued[std::size_t(p_slot)] = 1;
		++_size;
	}

public:
	PageArrivalQueue() = default;

	explicit PageArrivalQueue(std::size_t p_slot_count) {
		reset(p_slot_count);
	}

	std::size_t size() const { return _size; }

	std::size_t capacity() const { return _queued.size(); }

	bool empty() const { return _size == 0; }

	bool contains(int p_slot) const {
		return is_valid_slot(p_slot) && _queued[std::size_t(p_slot)] != 0;
	}

	void clear() {
		std::fill(_next.begin(), _next.end(), -1);
		std::fill(_previous.begin(), _previous.end(), -1);
		std::fill(_queued.begin(), _queued.end(), uint8_t(0));
		_head = -1;
		_tail = -1;
		_size = 0;
	}

	void reset(std::size_t p_slot_count = 0) {
		_next.assign(p_slot_count, -1);
		_previous.assign(p_slot_count, -1);
		_queued.assign(p_slot_count, uint8_t(0));
		_head = -1;
		_tail = -1;
		_size = 0;
	}

	// Growing does not move live nodes. Shrinking is a pool-lifecycle operation,
	// so it rebuilds the short live order once and drops slots outside the new
	// physical pool. Neither operation is used in the per-tick release loop.
	void resize(std::size_t p_slot_count) {
		if (p_slot_count == capacity()) {
			return;
		}
		if (p_slot_count > capacity()) {
			_next.resize(p_slot_count, -1);
			_previous.resize(p_slot_count, -1);
			_queued.resize(p_slot_count, uint8_t(0));
			return;
		}

		std::vector<int> retained;
		retained.reserve(_size);
		for (int slot = _head; slot >= 0; slot = _next[std::size_t(slot)]) {
			if (std::size_t(slot) < p_slot_count) {
				retained.push_back(slot);
			}
		}
		reset(p_slot_count);
		for (int slot : retained) {
			append_unlinked(slot);
		}
	}

	// Removes a live node in O(1). A removed node is fully unlinked, which is
	// what makes slot reuse safe without a separate generation number.
	bool remove(int p_slot) {
		if (!contains(p_slot)) {
			return false;
		}
		const std::size_t index = std::size_t(p_slot);
		const int previous = _previous[index];
		const int next = _next[index];
		if (previous >= 0) {
			_next[std::size_t(previous)] = next;
		} else {
			_head = next;
		}
		if (next >= 0) {
			_previous[std::size_t(next)] = previous;
		} else {
			_tail = previous;
		}
		_previous[index] = -1;
		_next[index] = -1;
		_queued[index] = 0;
		--_size;
		return true;
	}

	// A slot has at most one live entry. Re-enqueueing it therefore means that
	// its current arrival belongs at the tail of the FIFO.
	bool enqueue(int p_slot) {
		if (!is_valid_slot(p_slot)) {
			return false;
		}
		remove(p_slot);
		append_unlinked(p_slot);
		return true;
	}

	bool pop(int &r_slot) {
		if (_head < 0) {
			return false;
		}
		r_slot = _head;
		remove(r_slot);
		return true;
	}
};

} // namespace TerrainVT

#endif // TERRAIN_VT_ARRIVAL_QUEUE_H
