#[compute]
#version 450
#define NTC_LATENT_LAYERS 4
#define NTC_OUTPUT_CHANNELS 16
// This software contains source code provided by NVIDIA Corporation.
// GenericInt8 inference adapted from RTXNTC-Library 35ec0395 (Inference.hlsli).
// SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES.
// SPDX-License-Identifier: LicenseRef-NvidiaProprietary
// See ../LICENSES/NVIDIA-LICENSE.txt. Uses portable 32-bit arithmetic, no CUDA,
// vendor extension, 16-bit storage, bindless array or cooperative matrix.
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(set=0,binding=0,std430) readonly buffer Constants { uint c[]; };
layout(set=0,binding=1,std430) readonly buffer Weights { uint w[]; };
layout(set=0,binding=2,std430) readonly buffer Latents { uint l[]; };
layout(set=0,binding=3,std430) readonly buffer Layout { ivec4 grid[]; };
layout(set=0,binding=4,rgba8) uniform writeonly image2D albedo_out;
layout(set=0,binding=5,rgba8) uniform writeonly image2D normal_out;
layout(set=0,binding=6,rgba8) uniform writeonly image2D orm_out;
layout(push_constant,std430) uniform Push {
    ivec4 src; // source x, y, dispatch width, height (may include a tile gutter)
    ivec4 dst; // output x, y, source mip, latent layers
    ivec4 maps; // first albedo channel, normal (-1 if absent), ORM, unused
    uvec4 spaces; // 2 bits/channel target color spaces, unused
} p;
shared uint matrix[1024];
shared int biases[64];
shared float scales[64];

uint pack8(ivec4 v) { return (uint(v.x)&255u)|((uint(v.y)&255u)<<8)|((uint(v.z)&255u)<<16)|(uint(v.w)<<24); }
ivec4 dot4_outputs(uint value,uvec4 weights) {
    int v=int(value); ivec4 w=ivec4(weights);
    return bitfieldExtract(v,0,8)*bitfieldExtract(w,0,8)
         + bitfieldExtract(v,8,8)*bitfieldExtract(w,8,8)
         + bitfieldExtract(v,16,8)*bitfieldExtract(w,16,8)
         + bitfieldExtract(v,24,8)*bitfieldExtract(w,24,8);
}
int source_row(int row,int layer) {
    if(layer!=0) return row;
    return row<NTC_LATENT_LAYERS*2 ? (row/NTC_LATENT_LAYERS)*4+row%NTC_LATENT_LAYERS : 8+row-NTC_LATENT_LAYERS*2;
}
vec4 texel(ivec4 g, ivec4 window, ivec2 xy) {
    // A compact, wrapped feature window can replace the full latent grid for VT pages.
    // GLSL '%' with a negative operand is undefined. Feature grids need not be powers of two.
    xy=(xy-window.xy+g.yz*2)%g.yz;
    int address=g.x+xy.y*g.w+xy.x*2;
    uint bits=l[address>>2] >> uint((address&2)*8);
    return vec4(bits&15u,(bits>>4)&15u,(bits>>8)&15u,(bits>>12)&15u)/15.0;
}
vec4 sample_grid(vec2 uv, int mip, int layer) {
    int index=(mip*p.dst.w+layer)*2;
    ivec4 g=grid[index], window=grid[index+1];
    vec2 pos=uv*vec2(g.yz)-0.5;
    ivec2 xy=ivec2(floor(pos)); vec2 f=fract(pos);
    return mix(mix(texel(g,window,xy),texel(g,window,xy+ivec2(1,0)),f.x),
               mix(texel(g,window,xy+ivec2(0,1)),texel(g,window,xy+ivec2(1)),f.x),f.y);
}
void layer(int index, int input_count, int output_count, in uint input_values[16], out uint output_values[16]) {
    barrier();
    int tid=int(gl_LocalInvocationIndex);
    int rows=index==0 ? NTC_LATENT_LAYERS*2+4 : input_count/4;
    for(int i=tid;i<rows*output_count;i+=64) {
        int col=i/rows, row=i%rows;
        matrix[i]=w[(int(c[64+index])>>2)+col*(input_count/4)+source_row(row,index)];
    }
    if(tid<output_count) {
        biases[tid]=int(w[(int(c[68+index])>>2)+tid]);
        scales[tid]=uintBitsToFloat(w[(int(c[72+index])>>2)+tid]);
    }
    barrier();
    for(int col=0;col<output_count;col+=4) {
        ivec4 sum=ivec4(biases[col],biases[col+1],biases[col+2],biases[col+3]);
        for(int r=0;r<rows;++r) {
            uint v=input_values[source_row(r,index)];
            sum+=dot4_outputs(v,uvec4(matrix[(col+0)*rows+r],matrix[(col+1)*rows+r],
                                     matrix[(col+2)*rows+r],matrix[(col+3)*rows+r]));
        }
        vec4 result=vec4(sum)*vec4(scales[col],scales[col+1],scales[col+2],scales[col+3]);
        if(index==3) for(int j=0;j<4;++j) output_values[col+j]=floatBitsToUint(result[j]);
        else {
            result=min(result,vec4(3.0))*clamp(result*0.333333+0.5,0.0,1.0);
            output_values[col/4]=pack8(ivec4(roundEven(result*80.0)-113.0));
        }
    }
}
float linearize(float value, uint space) {
    if(space==1u) return value<=0.04045?value/12.92:pow((value+0.055)/1.055,2.4);
    if(space==2u) { float a=abs(value); return sign(value)*(a<0.5?4.0*a*a:exp((a-0.55991073)/0.17883277)+0.28466892); }
    return value;
}
vec4 output_map(uint values[16], int first, int count) {
    vec4 result=vec4(0,0,0,1);
    for(int i=0;i<count;++i) {
        int channel=first+i;
        float value=uintBitsToFloat(values[channel]);
        uint from=(c[81]>>uint(channel*2))&3u;
        uint to=(p.spaces.x>>uint(channel*2))&3u;
        if(from!=to) {
            value=linearize(value,from);
            if(to==1u) value=value<=0.0031308?value*12.92:1.055*pow(max(value,0.0),1.0/2.4)-0.055;
        }
        result[i]=roundEven(clamp(value,0.0,1.0)*255.0)/255.0;
    }
    return result;
}
void main() {
    ivec2 local=ivec2(gl_GlobalInvocationID.xy);
    int mip=p.dst.z;
    ivec2 size=max(ivec2(c[76],c[77])>>mip,ivec2(1));
    // Repeat is applied at the virtual image boundary, never at an atlas page boundary.
    ivec2 pixel=(p.src.xy+local)&(size-1); // Validated power-of-two material dimensions.
    vec2 uv=(vec2(pixel)+0.5)/vec2(size);
    int neural=int(c[mip*4]);
    uint input_values[16]; uint h0[16]; uint h1[16]; uint h2[16]; uint output_values[16];
    for(int i=0;i<16;++i) input_values[i]=0u;
    for(int level=0;level<2;++level) for(int j=0;j<4;++j) {
        if(j<NTC_LATENT_LAYERS) input_values[level*4+j]=pack8(ivec4(floor(sample_grid(uv,neural+level,j)*255.0-128.0)));
    }
    vec2 pos=vec2(pixel)*uintBitsToFloat(c[mip*4+2]);
    for(int wave=0;wave<3;++wave) {
        vec4 v=fract(vec4(pos,pos+0.25))*2.0-1.0;
        input_values[8+wave]=pack8(ivec4(v*127.5)); pos*=2.0;
    }
    int lod=int(uintBitsToFloat(c[mip*4+1])*127.5);
    input_values[11]=pack8(ivec4(lod,lod,0,0));
    layer(0,48,64,input_values,h0); layer(1,64,48,h0,h1);
    layer(2,48,32,h1,h2); layer(3,32,NTC_OUTPUT_CHANNELS,h2,output_values);
    // All invocations must reach the shared-weight barriers above.
    if(any(greaterThanEqual(local,p.src.zw))) return;
    ivec2 destination=p.dst.xy+local;
    imageStore(albedo_out,destination,output_map(output_values,p.maps.x,4));
    if(p.maps.y>=0) imageStore(normal_out,destination,output_map(output_values,p.maps.y,3));
    if(p.maps.z>=0) imageStore(orm_out,destination,output_map(output_values,p.maps.z,3));
}
