#[compute]
#version 450
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D source_image;
layout(rgba16f,set=0,binding=1) uniform writeonly image2D destination_image;
layout(push_constant,std430) uniform Params { vec4 unused; } params;
void main() {
	ivec2 pixel=ivec2(gl_GlobalInvocationID.xy);
	if(any(greaterThanEqual(pixel,imageSize(destination_image))))return;
	imageStore(destination_image,pixel,texelFetch(source_image,pixel,0));
}
