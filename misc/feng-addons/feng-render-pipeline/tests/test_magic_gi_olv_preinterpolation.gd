extends SceneTree
## Production layout 7/8 OLV: choose a categorical domain, then hardware-filter
## its independent SH2 volume. No model or authored scene is needed here.
const LIB := "res://addons/feng-render-pipeline/library/magic-gi/"
const R := 4
const LODS := 2
const SIDE := 8
const Y00 := 0.2820947918
var rd: RenderingDevice
var shader := RID()
var pipeline := RID()
var linear := RID()
var nearest := RID()
var output := RID()
var dummy := RID()
var set0 := RID()
var owned: Array[RID] = []
var checks := 0
var failures := 0
func _initialize() -> void: call_deferred("_run")
func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
func _run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		_check(false,"RenderingDevice required")
		_finish()
		return
	var source := RDShaderSource.new()
	var tensor := FileAccess.get_file_as_string(LIB+"magic_gi_sh4_tensor.glslinc")
	var sampling := FileAccess.get_file_as_string(LIB+"magic_gi_dynamic_volume_sample.glslinc").replace('#include "magic_gi_sh4_tensor.glslinc"','')
	source.source_compute = """#version 450
#define MAGIC_GI_PREINTERPOLATED_ONLY
#define MAGIC_GI_OLV_GATE
#define FRP_MAGIC_GI_DYNAMIC_VOLUME_LINEAR_SAMPLER linear_sampler
#define FRP_MAGIC_GI_OLV_LABEL_SAMPLER nearest_sampler
layout(local_size_x=1) in;
layout(set=0,binding=0) uniform sampler linear_sampler;
layout(set=0,binding=1) uniform sampler nearest_sampler;
layout(set=0,binding=2,std430) buffer Result { vec4 values[2]; } result;
layout(push_constant,std430) uniform Query { vec4 world; } query;
#define FRP_MAGIC_GI_OLV_VISIBLE_RAY(world, view) (query.world.w > 0.5 ? vec3(0.3,1.6,3.0) - (world) : vec3(0.0))
"""+tensor+sampling+"""
void main() {
    if (abs(query.world.w) > 0.5) {
        result.values[0] = vec4(float(frp_magic_gi_olv_receiver_domain(query.world.xyz,vec3(0,-1,0),0)),float(frp_magic_gi_olv_label_fetch(ivec3(1,0,1),0,4,frp_magic_gi_dynamic_volume_dimensions_version(0))),0,0);
        result.values[1] = vec4(0,0,0,1);
        return;
    }
    vec3 incident; float coverage;
    bool hit = frp_magic_gi_dynamic_volume_sample(query.world.xyz,vec3(0,1,0),vec3(0,1,0),0,incident,coverage);
    vec3 ambient = vec3(3.0);
    frp_magic_gi_dynamic_volume_apply(query.world.xyz,vec3(0,1,0),vec3(0,1,0),vec3(1.0),1.0,1.0,0,ambient,vec3(2.0));
    result.values[0] = vec4(incident,coverage);
    result.values[1] = vec4(ambient,hit ? 1.0 : 0.0);
}
"""
	var spirv := rd.shader_compile_spirv_from_source(source)
	_check(spirv.compile_error_compute.is_empty(),"production OLV sampler compiles: "+spirv.compile_error_compute)
	if not spirv.compile_error_compute.is_empty():
		_finish()
		return
	shader = _own(rd.shader_create_from_spirv(spirv))
	pipeline = _own(rd.compute_pipeline_create(shader))
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear = _own(rd.sampler_create(state))
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest = _own(rd.sampler_create(state))
	output = _own(rd.storage_buffer_create(32))
	dummy = _own(rd.storage_buffer_create(16))
	set0 = _own(rd.uniform_set_create([_u(RenderingDevice.UNIFORM_TYPE_SAMPLER,0,linear),_u(RenderingDevice.UNIFORM_TYPE_SAMPLER,1,nearest),_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,2,output)],shader,0))
	for layout in [7,8]:
		for point: Vector3 in [Vector3(0.25,0.7,0.7),Vector3(1.25,0.7,0.7),Vector3(2.25,0.7,0.7),Vector3(3,0.7,0.7),Vector3(0.25,0.7,6)]:
			var domain := 2 if point.x < 1.5 else 1
			var scalar: float = 0.2+point.x*0.02+point.y*0.01 if domain==2 else 1000.0+point.x*10.0
			var expected: Vector3 = Vector3(1,0.5,0.25)*scalar*Y00
			var result := _sample(layout,point,"full")
			_check(result.hit,"layout %d valid domain sample at %s" % [layout,point])
			_check(result.incident.distance_to(expected)<0.0002*maxf(1.0,expected.length()),"partition radiance never blends the foreign domain")
			_check(result.ambient.distance_to(Vector3.ONE+expected)<0.0002*maxf(1.0,expected.length()),"a supported sample fully replaces native sky")
		var before := _sample(layout,Vector3(0.9999,0.7,0.7),"full")
		var after := _sample(layout,Vector3(1.0001,0.7,0.7),"full")
		_check(before.incident.distance_to(after.incident)<0.00001,"same-domain interpolation stays continuous across a cell boundary")
		var coarse := _sample(layout,Vector3(1.25,0.7,0.7),"fine_hole")
		_check(coarse.hit and coarse.incident.distance_to(Vector3(1,0.5,0.25)*(0.2+1.25*0.02+0.7*0.01)*Y00)<0.0001,"a missing fine response falls back to the same partition")
		var sparse := _sample(layout,Vector3(0.25,0.25,0.25),"sparse")
		_check(sparse.hit and sparse.coverage<0.5,"partial valid support is normalized instead of becoming a black block")
		_check(sparse.incident.distance_to(Vector3(1,0.5,0.25)*0.2*Y00)<0.0001,"sparse support is normalized exactly once")
		for kind in ["no_labels","no_support","nan"]:
			var miss := _sample(layout,Vector3(0.25,0.7,0.7),kind)
			_check(not miss.hit and miss.incident.is_finite(),"unavailable/corrupt data never shades a foreign partition: "+kind)
		var outside := _sample(layout,Vector3(20,0.7,0.7),"full")
		_check(not outside.hit and outside.ambient.distance_to(Vector3.ONE*3)<0.0001,"receivers outside the owner retain ambient")
		var contact_control := _sample(layout,Vector3(0.3,0.02,0.3),"contact_control")
		var contact := _sample(layout,Vector3(0.3,0.02,0.3),"contact")
		var contact_empty := _sample(layout,Vector3(0.3,0.02,0.3),"contact_empty")
		_check(contact_control.incident.x==1.0,"control reproduces coarse outdoor selection underneath a floor")
		_check(contact.incident.y==1.0,"the relocated outdoor source retains its lighting partition")
		_check(contact.incident.x==2.0,"visible fine free-space support wins before a coarse under-floor label")
		_check(contact_empty.incident.x==1.0,"the visible-ray fallback never invents a missing fine label")
	_finish()
func _sample(layout: int, world: Vector3, kind: String) -> Dictionary:
	var response := _response(kind)
	var labels := _labels(kind)
	var params := PackedFloat32Array()
	for lod in 4:
		if kind.begins_with("contact"):
			params.append_array(PackedFloat32Array([0,-0.06 if lod==0 else -0.31,0,0.25*float(1<<lod)]))
		else:
			params.append_array(PackedFloat32Array([0,0,0,float(1<<lod)]))
	var bytes := params.to_byte_array()
	bytes.append_array(PackedInt32Array([R,R,R*LODS,layout]).to_byte_array())
	bytes.append_array(PackedFloat32Array([1.0]).to_byte_array())
	bytes.append_array(PackedInt32Array([4,LODS,R]).to_byte_array())
	var parameters := _own(rd.uniform_buffer_create(96,bytes))
	var owner := _own(rd.uniform_buffer_create(96,PackedFloat32Array([1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1,20,20,20,1,1,1,1,0]).to_byte_array()))
	var encoding := 2 if kind.begins_with("contact") and kind!="contact_control" else 1
	var metadata := _own(rd.uniform_buffer_create(32,PackedInt32Array([R,R,R*LODS,layout,encoding,1,SIDE*LODS,SIDE]).to_byte_array()))
	var set1 := _own(rd.uniform_set_create([_u(RenderingDevice.UNIFORM_TYPE_TEXTURE,69,response),_u(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,76,parameters),_u(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,77,owner),_u(RenderingDevice.UNIFORM_TYPE_TEXTURE,87,response),_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,88,dummy),_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,89,dummy),_u(RenderingDevice.UNIFORM_TYPE_TEXTURE,90,labels),_u(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,91,metadata)],shader,1))
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,pipeline)
	rd.compute_list_bind_uniform_set(list,set0,0)
	rd.compute_list_bind_uniform_set(list,set1,1)
	var query_mode := -1.0 if kind=="contact_control" else 1.0 if kind.begins_with("contact") else 0.0
	var push := PackedFloat32Array([world.x,world.y,world.z,query_mode]).to_byte_array()
	rd.compute_list_set_push_constant(list,push,push.size())
	rd.compute_list_dispatch(list,1,1,1)
	rd.compute_list_end()
	rd.submit(); rd.sync()
	var data := rd.buffer_get_data(output).to_float32_array()
	return {"incident":Vector3(data[0],data[1],data[2]),"coverage":data[3],"ambient":Vector3(data[4],data[5],data[6]),"hit":data[7]>0.5}
func _response(kind: String) -> RID:
	var values := PackedFloat32Array()
	values.resize(R*2*R*R*LODS*4*4)
	for field in 4:
		for lod in LODS:
			for z in R:
				for y in R:
					for x in R*2:
						var indoor := x>=R
						var step := float(1<<lod)
						var scalar: float = 0.2+float(x%R)*step*0.02+float(y)*step*0.01 if indoor else 1000.0+float(x)*step*10.0
						var valid := kind!="no_support" and not(kind=="fine_hole" and lod==0)
						if kind=="sparse": valid=lod==0 and x%R==0 and y==0 and z==0
						var index := (((field*R*LODS+lod*R+z)*R+y)*(R*2)+x)*4
						if valid and field==0:
							values[index]=NAN if kind=="nan" and indoor else scalar
							values[index+1]=scalar*0.5;values[index+2]=scalar*0.25
						if valid and field==3: values[index+3]=1.0
	return _texture(R*2,R,R*LODS*4,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,values.to_byte_array())
func _labels(kind: String) -> RID:
	var labels := PackedByteArray()
	labels.resize(SIDE*SIDE*SIDE*LODS)
	for lod in LODS:
		for z in SIDE:
			for y in SIDE:
				for x in SIDE:
					var label := 0 if kind=="no_labels" else (2 if (x-2)*(1<<lod)<1.5 else 1)
					if kind.begins_with("contact"):
						var source_label := 1 if lod>0 or y<=2 else 2
						var receiver_label := 1 if lod>0 else 2 if y==3 and kind!="contact_empty" else 0
						label=source_label if kind=="contact_control" else source_label | (receiver_label<<2)
					labels[((lod*SIDE+z)*SIDE+y)*SIDE+x] = label
	return _texture(SIDE,SIDE,SIDE*LODS,RenderingDevice.DATA_FORMAT_R8_UNORM,labels)
func _texture(w: int,h: int,d: int,fmt: int,data: PackedByteArray) -> RID:
	var f := RDTextureFormat.new()
	f.texture_type=RenderingDevice.TEXTURE_TYPE_3D;f.format=fmt;f.width=w;f.height=h;f.depth=d
	f.usage_bits=RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return _own(rd.texture_create(f,RDTextureView.new(),[data]))
func _u(type: int,binding: int,rid: RID) -> RDUniform:
	var u := RDUniform.new();u.uniform_type=type;u.binding=binding;u.add_id(rid);return u
func _own(rid: RID) -> RID:
	owned.append(rid);return rid
func _finish() -> void:
	print("OLV_PREINTERPOLATION_RESULT checks=",checks," failures=",failures)
	if rd!=null:
		owned.reverse()
		for rid in owned:
			if rid.is_valid(): rd.free_rid(rid)
		rd.free()
	quit(1 if failures else 0)
