// SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES.
// SPDX-License-Identifier: LicenseRef-NvidiaProprietary
// GenericInt8 math from RTXNTC-Library 35ec0395; see ../LICENSES.
// This is evaluated-VT sampling, with signed world normals and linear HDR channels.
uniform sampler2D _ntc_tensor : filter_nearest, repeat_disable;
uniform sampler2D _ntc_latents : filter_nearest, repeat_disable;
uniform sampler2D _ntc_pages : filter_nearest, repeat_disable;
uniform bool _ntc_ready = false;
uniform sampler2DArray _ntc_cache_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2DArray _ntc_cache_normal : filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2DArray _ntc_cache_params : filter_linear_mipmap_anisotropic, repeat_disable;
uniform int _ntc_cache_normal_encoding = 0;
uniform bool _ntc_cache_params_encoded = false;

vec4 ntc_fetch(int index) { return texelFetch(_ntc_tensor, ivec2(index%64,index/64),0); }
uvec4 ntc_words(int index, int packet, uvec4 mask, bool wide) {
    if (!wide) { return floatBitsToUint(ntc_fetch(packet+index))^mask; }
    uvec4 a=uvec4(ntc_fetch(packet+index*2));
    uvec4 b=uvec4(ntc_fetch(packet+index*2+1));
    return uvec4(a.x|(a.y<<16u),a.z|(a.w<<16u),b.x|(b.y<<16u),b.z|(b.w<<16u));
}
uint ntc_pack8(ivec4 v) { return (uint(v.x)&255u)|((uint(v.y)&255u)<<8u)|((uint(v.z)&255u)<<16u)|(uint(v.w)<<24u); }
ivec4 ntc_dot4(uint value, uvec4 weights) {
    ivec4 v=ivec4(int(value<<24u)>>24,int(value<<16u)>>24,int(value<<8u)>>24,int(value)>>24);
    return v.x*(ivec4(weights<<24u)>>24)+v.y*(ivec4(weights<<16u)>>24)
        +v.z*(ivec4(weights<<8u)>>24)+v.w*(ivec4(weights)>>24);
}
vec4 ntc_latent(ivec2 xy, ivec3 grid) {
    xy=clamp(xy,ivec2(0),grid.yz-1);
    int at=grid.x+xy.y*grid.y+xy.x;
    uvec2 bytes=uvec2(round(texelFetch(_ntc_latents,ivec2(at%4096,at/4096),0).ra*255.0));
    uint bits=bytes.x|(bytes.y<<8u);
    return vec4(uvec4(bits&15u,(bits>>4u)&15u,(bits>>8u)&15u,(bits>>12u)&15u))/15.0;
}
vec4 ntc_feature(vec2 uv, ivec3 grid) {
    vec2 p=uv*vec2(grid.yz)-0.5; ivec2 xy=ivec2(floor(p)); vec2 f=fract(p);
    return mix(mix(ntc_latent(xy,grid),ntc_latent(xy+ivec2(1,0),grid),f.x),
               mix(ntc_latent(xy+ivec2(0,1),grid),ntc_latent(xy+ivec2(1),grid),f.x),f.y);
}
void ntc_layer(int base,int rows,int outputs,bool first,bool last,int layers,int packet,uvec4 mask,bool wide,
        uint values[16], out uint result[16]) {
    for(int col=0;col<outputs;col+=4) {
        int block=base+(col/4)*(rows+2);
        ivec4 sum=ivec4(ntc_words(block+rows,packet,mask,wide));
        vec4 scale=uintBitsToFloat(ntc_words(block+rows+1,packet,mask,wide));
        for(int row=0;row<rows;row++) {
            int source=first?(row<layers*2?(row/layers)*4+row%layers:8+row-layers*2):row;
            sum+=ntc_dot4(values[source],ntc_words(block+row,packet,mask,wide));
        }
        vec4 x=vec4(sum)*scale;
        if(last) {
            result[col]=floatBitsToUint(x.x); result[col+1]=floatBitsToUint(x.y);
            result[col+2]=floatBitsToUint(x.z); result[col+3]=floatBitsToUint(x.w);
        } else {
            x=min(x,vec4(3.0))*clamp(x*0.333333+0.5,vec4(0.0),vec4(1.0));
            result[col/4]=ntc_pack8(ivec4(roundEven(x*80.0)-113.0));
        }
    }
}
bool surface_neural_source_fallback() { return true; }
bool surface_neural_material_slot(int slot,vec2 offset,int page_size,int border,vec2 dx,vec2 dy,out material mat,out vec3 normal) {
    if(!_ntc_ready || slot<0 || slot>=textureSize(_ntc_pages,0).x*textureSize(_ntc_pages,0).y) { return false; }
    vec4 entry=texelFetch(_ntc_pages,ivec2(slot%64,slot/64),0);
    if(entry.z<0.5) { return false; }
    if(entry.w>0.5) {
        vec3 at=vec3((offset*float(page_size)+float(border))/float(page_size+border*2),entry.w-1.0);
        vec4 a=textureGrad(_ntc_cache_albedo,at,dx,dy);
        vec4 n=textureGrad(_ntc_cache_normal,at,dx,dy);
        vec4 p=textureGrad(_ntc_cache_params,at,dx,dy);
        if(p.a<(_ntc_cache_params_encoded?0.49:0.99)) { return false; }
        if(_ntc_cache_normal_encoding!=0) {
            vec2 oct=(_ntc_cache_normal_encoding==2?n.ag:n.rg)*2.0-1.0;
            vec3 v=vec3(oct.x,1.0-abs(oct.x)-abs(oct.y),oct.y);
            float fold=clamp(-v.y,0.0,1.0);
            v.x+=v.x>=0.0?-fold:fold; v.z+=v.z>=0.0?-fold:fold;
            n.xyz=normalize(v);
        }
        if(_ntc_cache_params_encoded) { p.r*=2.0; n.a=clamp(p.a*2.0-1.0,0.0,1.0); }
        normal=n.xyz;
        mat=material(a,n,p.r,p.g,p.b,1.0);
        return true;
    }
    int model=int(entry.z)-1;
    vec4 meta=ntc_fetch(model*12);
    ivec4 bases=ivec4(ntc_fetch(model*12+1));
    uvec4 mask=uvec4(ntc_fetch(model*12+2));
    vec4 settings=ntc_fetch(model*12+3);
    int layers=int(meta.w), packet=int(meta.z); bool wide=settings.x>0.5;
    vec2 pixel=entry.xy+offset*float(page_size)+float(border)-0.5;
    vec2 uv=(pixel+0.5)/meta.xy;
    uint values[16]; uint h0[16]; uint h1[16]; uint h2[16]; uint output_values[16];
    for(int i=0;i<16;i++) { values[i]=0u; output_values[i]=0u; }
    for(int level=0;level<2;level++) {
        for(int layer=0;layer<4;layer++) {
            if(layer<layers) {
                ivec3 grid=ivec3(ntc_fetch(model*12+4+level*4+layer).xyz);
                values[level*4+layer]=ntc_pack8(ivec4(floor(ntc_feature(uv,grid)*255.0-128.0)));
            }
        }
    }
    vec2 pos=pixel*settings.z;
    for(int wave=0;wave<3;wave++) {
        vec4 v=fract(vec4(pos,pos+0.25))*2.0-1.0;
        values[8+wave]=ntc_pack8(ivec4(v*127.5)); pos*=2.0;
    }
    int lod=int(settings.y*127.5); values[11]=ntc_pack8(ivec4(lod,lod,0,0));
    ntc_layer(bases.x,layers*2+4,64,true,false,layers,packet,mask,wide,values,h0);
    ntc_layer(bases.y,16,48,false,false,layers,packet,mask,wide,h0,h1);
    ntc_layer(bases.z,12,32,false,false,layers,packet,mask,wide,h1,h2);
    ntc_layer(bases.w,8,12,false,true,layers,packet,mask,wide,h2,output_values);
    vec4 a=vec4(uintBitsToFloat(output_values[0]),uintBitsToFloat(output_values[1]),uintBitsToFloat(output_values[2]),uintBitsToFloat(output_values[3]));
    vec4 n=vec4(uintBitsToFloat(output_values[4]),uintBitsToFloat(output_values[5]),uintBitsToFloat(output_values[6]),uintBitsToFloat(output_values[7]));
    vec4 p=vec4(uintBitsToFloat(output_values[8]),uintBitsToFloat(output_values[9]),uintBitsToFloat(output_values[10]),uintBitsToFloat(output_values[11]));
    if(p.a<0.5) { return false; }
    normal=normalize(n.xyz+vec3(0.0,1e-12,0.0)); n.xyz=normal; n.a=clamp(n.a,0.0,1.0);
    mat=material(a,n,p.x,p.y,p.z,1.0);
    return true;
}
