@tool
extends Node
## One shared submission budget, including editor previews. Scene-tree work stays on the main thread.
static var _instance: WeakRef
var _sessions: Array[WeakRef] = []
var _cursor := 0
var _retired: Array[Dictionary] = []


static func register(session: RefCounted) -> void:
	var manager: Node = _instance.get_ref() if _instance != null else null
	if manager == null:
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null: return
		manager = load("res://addons/feng-ntc/runtime.gd").new()
		manager.name = "FengNTCStreaming"
		manager.process_mode = Node.PROCESS_MODE_ALWAYS
		_instance = weakref(manager)
		tree.root.add_child.call_deferred(manager)
	manager._sessions.append(weakref(session))


func _process(_delta: float) -> void:
	for i in range(_retired.size()-1,-1,-1):
		if Engine.get_process_frames() >= int(_retired[i].frame):
			var item := _retired[i]
			_free_allocation(item.decoder,item.pages)
			_retired.remove_at(i)
	# A page cap bounds work, not milliseconds: timing depends on the target GPU.
	var count := _sessions.size()
	for ignored in range(count):
		if _sessions.is_empty(): break
		_cursor %= _sessions.size()
		var session: RefCounted = _sessions[_cursor].get_ref()
		if session == null:
			_sessions.remove_at(_cursor)
			continue
		if session.ready and not session.virtual:
			_sessions.remove_at(_cursor)
			continue
		_cursor += 1
		if session.tick(): break


func _exit_tree() -> void:
	for entry in _sessions:
		var session: RefCounted = entry.get_ref()
		if session != null: session.close()
	_sessions.clear()
	for item: Dictionary in _retired: _free_allocation(item.decoder,item.pages)
	_retired.clear()
	_instance = null

static func retire(decoder: RefCounted, pages: RID) -> void:
	var manager: Node = _instance.get_ref() if _instance != null else null
	if manager == null or not manager.is_inside_tree():
		_free_allocation(decoder,pages)
	else:
		manager._retired.append({"decoder":decoder,"pages":pages,"frame":Engine.get_process_frames()+2})

static func _free_allocation(decoder: RefCounted,pages: RID) -> void:
	RenderingServer.call_on_render_thread(func():
		if pages.is_valid(): RenderingServer.get_rendering_device().free_rid(pages)
		decoder.dispose())
