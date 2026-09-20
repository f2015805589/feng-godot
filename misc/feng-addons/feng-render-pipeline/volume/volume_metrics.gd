@tool
extends RefCounted
## Main-thread CPU milliseconds per process frame. GPU work is not measured.
## Keep the preceding frame readable regardless of debugger polling order.

const PREFIX := "volume/"
const CHANNELS := ["runtime_cpu_ms", "editor_cpu_ms", "apply_cpu_ms", "total_cpu_ms"]
static var _users := 0
static var _frame := -1
static var _current := [0, 0, 0, 0]
static var _previous := [0, 0, 0, 0]

static func acquire() -> void:
	_users += 1
	if _users != 1:
		return
	_frame = -1
	_current = [0, 0, 0, 0]
	_previous = [0, 0, 0, 0]
	for index in CHANNELS.size():
		Performance.add_custom_monitor(PREFIX + CHANNELS[index], sample.bind(index))

static func release() -> void:
	_users = maxi(0, _users - 1)
	if _users == 0:
		for channel in CHANNELS:
			Performance.remove_custom_monitor(PREFIX + channel)

static func _advance() -> void:
	var frame := Engine.get_process_frames()
	if frame == _frame:
		return
	_previous = _current.duplicate() if frame == _frame + 1 else [0, 0, 0, 0]
	_current = [0, 0, 0, 0]
	_frame = frame

static func record(channel: int, elapsed_usec: int) -> void:
	if _users == 0:
		return
	_advance()
	_current[channel] += elapsed_usec
	_current[3] += elapsed_usec

static func sample(channel: int) -> float:
	_advance()
	return float(_previous[channel]) / 1000.0
