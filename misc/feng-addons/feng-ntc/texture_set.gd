@tool
class_name FengNTCTextureSet
extends Resource
## Portable model/latent buffers. The SDK is only used to import old .ntc payloads in the editor.
const Session = preload("gpu_session.gd")
const Decoder = preload("gpu_decoder.gd")
const SampleSession = preload("sample_session.gd")
@export_storage var package: Dictionary = {}
# Read compatibility for existing assets; newly created resources store only package.
@export_storage var payload: PackedByteArray
var last_error := ""
var _session: RefCounted
var _sample_session: RefCounted

func fingerprint() -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(payload if package.is_empty() else var_to_bytes(package))
	return hash.finish().hex_encode()

func ensure_portable() -> bool:
	if not package.is_empty():
		last_error = Decoder.validate(package)
		return last_error.is_empty()
	if payload.is_empty(): last_error = "NTC 数据为空。"; return false
	if not ClassDB.class_exists(&"FengNTCCodec"):
		last_error = "旧版 NTC 数据尚未转换。请在制作端重新导入或保存材质；运行时资源应包含 portable package。"
		return false
	# Metadata extraction is CPU-only, does not initialize CUDA or decode pixels.
	var codec: Object = ClassDB.instantiate(&"FengNTCCodec")
	var result: Dictionary = codec.prepare_portable(payload)
	if not result.get("ok",false): last_error = result.get("error","NTC metadata error"); return false
	package = result.package
	payload = PackedByteArray()
	last_error = Decoder.validate(package)
	return last_error.is_empty()

func get_session() -> RefCounted:
	if not ensure_portable(): return null
	if _session == null:
		_session = Session.new()
		_session.start(package)
	return _session

func prepare_async() -> Dictionary:
	# Explicitly retain the resource while external callers await its load.
	var owner: Resource = self
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: last_error = "NTC requires SceneTree"; return {}
	var session := get_session()
	if session == null: return {}
	while not session.ready and session.last_error.is_empty(): await tree.process_frame
	owner.last_error = session.last_error
	return session.textures if owner.last_error.is_empty() else {}

func create_virtual_session(axis := 8) -> RefCounted:
	if not ensure_portable(): return null
	var session := Session.new()
	session.start(package,true,axis)
	return session

func get_sample_session() -> RefCounted:
	if not ensure_portable(): return null
	if _sample_session==null:
		_sample_session=SampleSession.new()
		_sample_session.start(package)
	return _sample_session

func get_runtime_stats() -> Dictionary:
	return _session.stats.duplicate() if _session != null else {}
