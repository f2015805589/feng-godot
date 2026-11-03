shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES.
// SPDX-License-Identifier: LicenseRef-NvidiaProprietary
// GenericInt8 inference mathematics adapted from RTXNTC-Library 35ec0395.
// See ../LICENSES/NVIDIA-LICENSE.txt and NVIDIA-ThirdPartyLicenses.txt.
// This path keeps NTC weights/latents resident. It never expands a full RGBA mip chain.
uniform sampler2D ntc_tensor : filter_nearest, repeat_disable;
uniform ivec4 ntc_tensor_mask = ivec4(0);
uniform bool ntc_tensor_wide = false;
uniform sampler2DArray ntc_latents : filter_nearest, repeat_enable;
uniform ivec4 ntc_bases = ivec4(0);
uniform ivec3 ntc_maps = ivec3(0,-1,-1);
uniform vec2 ntc_size = vec2(1.0);
uniform int ntc_mips = 1;
uniform int ntc_layers = 1;
uniform int ntc_outputs = 16;
uniform int ntc_from_space = 0;
uniform bool ntc_ready = false;
uniform vec4 albedo : source_color = vec4(1.0);
uniform float roughness : hint_range(0,1) = 1.0;
uniform float metallic : hint_range(0,1) = 0.0;
uniform float specular : hint_range(0,1) = 0.5;
uniform float normal_scale : hint_range(-16,16) = 1.0;
uniform bool ao_enabled = false;
uniform float ao_light_affect : hint_range(0,1) = 0.0;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform bool trilinear = true;
uniform bool exact_texels = false;

vec4 tensor_fetch(int index) { return texelFetch(ntc_tensor,ivec2(index%64,index/64),0); }
uvec4 tensor(int index) {
    if(!ntc_tensor_wide) return floatBitsToUint(tensor_fetch(index))^uvec4(ntc_tensor_mask);
    int p=index*2;
    uvec4 a=uvec4(tensor_fetch(p));
    p++;
    uvec4 b=uvec4(tensor_fetch(p));
    return uvec4(a.x|(a.y<<16u),a.z|(a.w<<16u),b.x|(b.y<<16u),b.z|(b.w<<16u));
}
uint pack8(ivec4 v) { return (uint(v.x)&255u)|((uint(v.y)&255u)<<8u)|((uint(v.z)&255u)<<16u)|(uint(v.w)<<24u); }
ivec4 dot4_outputs(uint value,uvec4 weights) {
    // Decode an activation only once for all four output neurons. Vector lanes
    // are output neurons, so the four signed byte planes share one extraction.
    ivec4 v=ivec4(int(value<<24u)>>24,int(value<<16u)>>24,int(value<<8u)>>24,int(value)>>24);
    return v.x*(ivec4(weights<<24u)>>24)+v.y*(ivec4(weights<<16u)>>24)
          +v.z*(ivec4(weights<<8u)>>24)+v.w*(ivec4(weights)>>24);
}
vec4 latent_texel(ivec2 xy,int mip,int layer) {
    ivec2 size=textureSize(ntc_latents,mip).xy;
    xy=(xy+size*2)%size;
    // RG8 is exposed by Godot as luminance-alpha; R and A contain the two bytes.
    uvec2 bytes=uvec2(round(texelFetch(ntc_latents,ivec3(xy,layer),mip).ra*255.0));
    uint bits=bytes.x|(bytes.y<<8u);
    return vec4(uvec4(bits&15u,(bits>>4u)&15u,(bits>>8u)&15u,(bits>>12u)&15u))/15.0;
}
vec4 sample_latent(vec2 uv,int mip,int layer) {
    vec2 pos=uv*vec2(textureSize(ntc_latents,mip).xy)-0.5;
    ivec2 xy=ivec2(floor(pos)); vec2 f=fract(pos);
    return mix(mix(latent_texel(xy,mip,layer),latent_texel(xy+ivec2(1,0),mip,layer),f.x),
               mix(latent_texel(xy+ivec2(0,1),mip,layer),latent_texel(xy+ivec2(1),mip,layer),f.x),f.y);
}
void neural_layer(int base,int inputs,int outputs,bool first,bool last,uint values[16],out uint result[16]) {
    int rows=first ? ntc_layers*2+4 : inputs/4;
    for(int col=0;col<outputs;col+=4) {
        int block=base+(col/4)*(rows+2);
        ivec4 sum=ivec4(tensor(block+rows));
        vec4 scale=uintBitsToFloat(tensor(block+rows+1));
        for(int row=0;row<rows;row++) {
            uvec4 weights=tensor(block+row);
            int source=first ? (row<ntc_layers*2 ? (row/ntc_layers)*4+row%ntc_layers : 8+row-ntc_layers*2) : row;
            uint value=values[source];
            sum+=dot4_outputs(value,weights);
        }
        vec4 x=vec4(sum)*scale;
        if(last) {
            result[col]=floatBitsToUint(x.x); result[col+1]=floatBitsToUint(x.y);
            result[col+2]=floatBitsToUint(x.z); result[col+3]=floatBitsToUint(x.w);
        } else {
            x=min(x,vec4(3.0))*clamp(x*0.333333+0.5,vec4(0.0),vec4(1.0));
            result[col/4]=pack8(ivec4(roundEven(x*80.0)-113.0));
        }
    }
}
void neural_sample(vec2 uv,int mip,out float result[16]) {
    vec2 size=max(floor(ntc_size/exp2(float(mip))),vec2(1.0));
    vec2 pixel=fract(uv)*size-0.5;
    if(exact_texels) pixel=floor(fract(uv)*size);
    vec2 sample_uv=(pixel+0.5)/size;
    uvec4 constants=tensor(mip);
    int neural=int(constants.x);
    uint values[16]; uint h0[16]; uint h1[16]; uint h2[16]; uint output_values[16];
    for(int i=0;i<16;i++) values[i]=0u;
    for(int level=0;level<2;level++) {
        for(int layer=0;layer<4;layer++) {
            if(layer<ntc_layers) values[level*4+layer]=pack8(ivec4(floor(sample_latent(sample_uv,neural+level,layer)*255.0-128.0)));
        }
    }
    vec2 pos=pixel*uintBitsToFloat(constants.z);
    for(int wave=0;wave<3;wave++) {
        vec4 v=fract(vec4(pos,pos+0.25))*2.0-1.0;
        values[8+wave]=pack8(ivec4(v*127.5)); pos*=2.0;
    }
    int lod=int(uintBitsToFloat(constants.y)*127.5);
    values[11]=pack8(ivec4(lod,lod,0,0));
    for(int i=0;i<16;i++) output_values[i]=0u;
    neural_layer(ntc_bases.x,48,64,true,false,values,h0);
    neural_layer(ntc_bases.y,64,48,false,false,h0,h1);
    neural_layer(ntc_bases.z,48,32,false,false,h1,h2);
    neural_layer(ntc_bases.w,32,ntc_outputs,false,true,h2,output_values);
    for(int channel=0;channel<16;channel++) {
        float value=uintBitsToFloat(output_values[channel]);
        uint space=(uint(ntc_from_space)>>uint(channel*2))&3u;
        if(space==1u) value=value<=0.04045?value/12.92:pow((value+0.055)/1.055,2.4);
        if(space==2u) { float a=abs(value); value=sign(value)*(a<0.5?4.0*a*a:exp((a-0.55991073)/0.17883277)+0.28466892); }
        result[channel]=clamp(value,0.0,1.0);
    }
}
void fragment() {
    vec2 uv=UV*uv_scale+uv_offset;
    vec3 base=vec3(1.0),norm=vec3(0.5,0.5,1.0),orm=vec3(1.0);
    if(ntc_ready) {
        vec2 dx=dFdx(uv)*ntc_size,dy=dFdy(uv)*ntc_size;
        float lod=clamp(0.5*log2(max(max(dot(dx,dx),dot(dy,dy)),1.0)),0.0,float(ntc_mips-1));
        int mip=int(floor(lod));
        float values[16]; neural_sample(uv,mip,values);
        if(trilinear && fract(lod)>0.001 && mip<ntc_mips-1) {
            float second[16]; neural_sample(uv,mip+1,second);
            for(int channel=0;channel<16;channel++) values[channel]=mix(values[channel],second[channel],fract(lod));
        }
        base=vec3(values[ntc_maps.x],values[ntc_maps.x+1],values[ntc_maps.x+2]);
        int normal_channel=max(ntc_maps.y,0),orm_channel=max(ntc_maps.z,0);
        if(ntc_maps.y>=0) norm=vec3(values[normal_channel],values[normal_channel+1],values[normal_channel+2]);
        if(ntc_maps.z>=0) orm=vec3(values[orm_channel],values[orm_channel+1],values[orm_channel+2]);
    }
    ALBEDO=base*albedo.rgb; ROUGHNESS=orm.g*roughness; METALLIC=orm.b*metallic; SPECULAR=specular;
    AO=ao_enabled?orm.r:1.0; AO_LIGHT_AFFECT=ao_light_affect;
    if(ntc_maps.y>=0) { NORMAL_MAP=norm; NORMAL_MAP_DEPTH=normal_scale; }
}
