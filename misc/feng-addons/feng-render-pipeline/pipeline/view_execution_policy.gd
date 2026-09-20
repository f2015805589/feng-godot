@tool
extends RefCounted
## Decides whether one authored pass can share its execution resource between views.
##
## This policy is deliberately independent of Renderer storage and schedule loops.
## Renderer supplies the stock native-script map because it owns that addon manifest;
## the map is only read here and is not copied or mutated.

const BuiltinPass = preload("../passes/builtin_pass.gd")
const NativePass = preload("../passes/native/native_pass.gd")
const ShaderPass = preload("../passes/shader_pass.gd")

## Stock shader resources and the exact stock native entries are safe to share.
## Unknown subclasses are isolated unless their top-level entry explicitly opts in
## through FengPass.can_share_view_execution(). For a BuiltinPass, an opt-in on its
## implementation is never consulted: a top-level custom BuiltinPass must opt in and
## thereby take responsibility for the complete carried implementation/overlay graph.
static func is_view_shareable(
		entry: FengPass,
		stock_native_pass_scripts: Dictionary,
		stock_passes_dir: String
) -> bool:
	if entry == null:
		return false
	if entry.get_script() == ShaderPass:
		return true
	if entry is BuiltinPass:
		if entry.get_script() == BuiltinPass:
			return _is_stock_builtin(entry as FengBuiltinPass, stock_native_pass_scripts, stock_passes_dir)
		# A custom BuiltinPass is allowed to opt in only at the entry level. This keeps
		# an implementation's opt-in from silently sharing a mutable overlay graph.
		return entry.can_share_view_execution()
	return entry.can_share_view_execution()

static func _is_stock_builtin(
		entry: FengBuiltinPass,
		stock_native_pass_scripts: Dictionary,
		stock_passes_dir: String
) -> bool:
	var implementation = entry.implementation
	if implementation == null:
		return false
	if not implementation is NativePass:
		return false
	if implementation.overlay != null:
		return false
	var script_path: String = stock_native_pass_scripts.get(entry.native_id, "")
	if script_path == "":
		return false
	var implementation_script: Script = implementation.get_script()
	return implementation_script != null and implementation_script.resource_path == stock_passes_dir + script_path
