@tool
class_name FengMagicGIPass
extends FengShaderPass
## Applies a FMagicGIVolume's baked probe field as diffuse GI.
##
## The volume's SH table arrives as a one-row RGBA32F atlas, 7 texels per probe,
## plus a small uniform block carrying the camera's inverse view-projection and
## the volume's world->probe-grid transform. Both are created and filled on the
## render thread by this pass from the snapshot FMagicGIRuntime publishes, so the
## bake path never has to touch the renderer.
##
## The pass is a plain FengShaderPass in every other way: the .tres declares the
## color/depth/normal/albedo inputs, and the compute shader adds
## albedo * irradiance onto the resolved color.

const RUNTIME_SCRIPT := "res://addons/feng-magic-gi/feng_magic_gi_runtime.gd"
const SH_TEXELS_PER_PROBE := 7
const UBO_FLOATS := 40  # inv_view_proj, world_to_grid, grid(dims,count), control

static var _runtime_script = null
static var _runtime_looked_up := false

var _scene_data = null
var _sh_texture := RID()
var _sh_version := -1
var _ubo := RID()
var _frame_strength := 1.0

func _frp_execute(ctx: FRPPassContext) -> void:
	var data := ctx.get_render_data()
	_scene_data = data.get_render_scene_data() if data != null else null
	super._frp_execute(ctx)
	_scene_data = null

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	var snapshot := _read_snapshot()
	if snapshot.is_empty():
		return
	var data = snapshot.get("data")
	if data == null or not data.is_valid():
		return
	if not _ensure_resources(rd, data, int(snapshot.get("version", 0))):
		return
	_frame_strength = float(snapshot.get("strength", 1.0))
	if not _fill_ubo(rd, data, view):
		return
	super._render(buffers, view, rd)

## The latest published bake, or {} when feng-magic-gi is not installed or no
## baked volume is enabled. Loaded by path (cached after the first hit) so this
## addon parses and runs without feng-magic-gi installed.
func _read_snapshot() -> Dictionary:
	if not _runtime_looked_up:
		_runtime_looked_up = true
		if ResourceLoader.exists(RUNTIME_SCRIPT):
			_runtime_script = load(RUNTIME_SCRIPT)
	if _runtime_script == null:
		return {}
	return _runtime_script.bake_snapshot

func _ensure_resources(rd: RenderingDevice, data, version: int) -> bool:
	if not _ubo.is_valid():
		_ubo = rd.uniform_buffer_create(UBO_FLOATS * 4)
		if not _ubo.is_valid():
			_report("Could not create the GI parameter buffer.")
			return false
	if _sh_version != version:
		var image: Image = data.make_atlas_image()
		if image == null:
			return false
		if _sh_texture.is_valid():
			rd.free_rid(_sh_texture)
			_sh_texture = RID()
		var format := RDTextureFormat.new()
		format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		format.width = image.get_width()
		format.height = 1
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		var view := RDTextureView.new()
		_sh_texture = rd.texture_create(format, view, [image.get_data()])
		if not _sh_texture.is_valid():
			_report("Could not upload the SH atlas texture.")
			return false
		_sh_version = version
	return true

func _fill_ubo(rd: RenderingDevice, data, view: int) -> bool:
	if _scene_data == null:
		return false
	var inv_vp: Projection = _scene_data.get_view_projection(view).inverse()
	var floats := PackedFloat32Array()
	floats.resize(UBO_FLOATS)
	for i in 4:
		var c: Vector4 = inv_vp[i]
		floats[i * 4] = c.x; floats[i * 4 + 1] = c.y
		floats[i * 4 + 2] = c.z; floats[i * 4 + 3] = c.w
	var w2g: Transform3D = data.world_to_grid
	for i in 3:
		floats[16 + i * 4] = w2g.basis[i].x
		floats[16 + i * 4 + 1] = w2g.basis[i].y
		floats[16 + i * 4 + 2] = w2g.basis[i].z
		floats[16 + i * 4 + 3] = 0.0
	floats[28] = w2g.origin.x; floats[29] = w2g.origin.y; floats[30] = w2g.origin.z
	floats[31] = 1.0
	var dims: Vector3i = data.grid_dims
	floats[32] = dims.x; floats[33] = dims.y; floats[34] = dims.z
	floats[35] = data.probe_count()
	floats[36] = _frame_strength
	floats[37] = 0.0; floats[38] = 0.0; floats[39] = 0.0
	rd.buffer_update(_ubo, 0, floats.size() * 4, floats.to_byte_array())
	return true

func _collect_bindings(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> Dictionary:
	var binding_data := super._collect_bindings(buffers, view, rd)
	if _binding_error:
		return binding_data
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	if _ensure_sampler(rd):
		var atlas := RDUniform.new()
		atlas.binding = 4
		atlas.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		atlas.add_id(_sampler)
		atlas.add_id(_sh_texture)
		uniforms.append(atlas)
		binding_data["textures"].append(_sh_texture)
	var params := RDUniform.new()
	params.binding = 5
	params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params.add_id(_ubo)
	uniforms.append(params)
	return binding_data

func _cleanup(rd: RenderingDevice) -> void:
	if rd != null:
		if _sh_texture.is_valid():
			rd.free_rid(_sh_texture)
			_sh_texture = RID()
		if _ubo.is_valid():
			rd.free_rid(_ubo)
			_ubo = RID()
	_sh_version = -1
	super._cleanup(rd)
