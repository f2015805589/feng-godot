@tool
class_name FengNTCStreamer
extends Node3D
## Optional conservative mesh visibility requester. This is not GPU pixel-feedback VT.
## Attach below a MeshInstance3D, or assign target_mesh. For terrain use request_uv_rect directly.
@export var target_mesh: MeshInstance3D
@export var uv_bounds := Rect2(0,0,1,1)
@export_range(0.05,2.0,0.05) var update_interval := 0.15
var _elapsed := 0.0

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < update_interval: return
	_elapsed = 0.0
	var mesh := target_mesh if is_instance_valid(target_mesh) else get_parent() as MeshInstance3D
	if mesh == null or mesh.mesh == null or not mesh.is_visible_in_tree(): return
	var camera := get_viewport().get_camera_3d()
	if Engine.is_editor_hint():
		var editor: Object = Engine.get_singleton("EditorInterface")
		if editor != null: camera = editor.get_editor_viewport_3d(0).get_camera_3d()
	if camera == null: return
	var bounds: AABB = mesh.global_transform * mesh.get_aabb()
	var center := bounds.get_center()
	var radius := bounds.size.length()*0.5
	for plane: Plane in camera.get_frustum():
		if plane.distance_to(center) > radius: return
	var distance := maxf(0.01,camera.global_position.distance_to(center)-radius)
	var viewport_height := float(camera.get_viewport().get_visible_rect().size.y)
	var diameter := radius*viewport_height/(distance*tan(deg_to_rad(camera.fov)*0.5))
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL: diameter=2.0*radius*viewport_height/maxf(camera.size,0.01)
	for i in range(mesh.mesh.get_surface_count()):
		var material := mesh.get_active_material(i)
		if material == null or not material.has_method("request_uv_rect") or material.texture_set == null: continue
		var size := float(material.texture_set.package.get("width",1))
		var mip := maxi(0,int(floor(log(maxf(1.0,size/maxf(diameter,1.0)))/log(2.0))))
		material.request_uv_rect(uv_bounds,mip)
