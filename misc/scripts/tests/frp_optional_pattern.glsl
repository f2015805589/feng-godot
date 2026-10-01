#[compute]
#version 450
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;
layout(rgba16f,set=0,binding=0) uniform image2D color_image;
layout(push_constant,std430) uniform Params {vec4 unused;} params;
void main() {
 ivec2 p=ivec2(gl_GlobalInvocationID.xy);
 if(any(greaterThanEqual(p,imageSize(color_image))))return;
 vec3 c=vec3(0.125+0.75*float((p.x/7+p.y/5)%2),0.125+0.5*float((p.x/11)%2),0.125+0.5*float((p.y/13)%2));
 imageStore(color_image,p,vec4(c,1.0));
}
