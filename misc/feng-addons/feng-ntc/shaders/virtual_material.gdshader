shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform sampler2D ntc_albedo : source_color, filter_linear, repeat_disable;
uniform sampler2D ntc_normal : filter_linear, repeat_disable;
uniform sampler2D ntc_orm : filter_linear, repeat_disable;
uniform sampler2D ntc_pages : filter_nearest, repeat_disable;
uniform vec2 ntc_size = vec2(1.0);
uniform int ntc_mips = 1;
uniform bool ntc_ready = false;
uniform bool ntc_has_normal = false;
uniform bool ntc_has_orm = false;
uniform vec4 albedo : source_color = vec4(1.0);
uniform float roughness : hint_range(0,1) = 1.0;
uniform float metallic : hint_range(0,1) = 0.0;
uniform float specular : hint_range(0,1) = 0.5;
uniform float normal_scale : hint_range(-16,16) = 1.0;
uniform float ao_light_affect : hint_range(0,1) = 0.0;
uniform bool ao_enabled = false;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
// Page IDs are point-sampled. Filter only decoded color, with a two-texel gutter.
vec4 page_uv(vec2 uv, int desired) {
    int base_y=max(int(ntc_size.y)/64,1);
    int tail_y=int(log2(float(base_y)));
    int row=2*(base_y-max(base_y>>desired,1))+max(0,desired-tail_y);
    vec2 wanted_size=max(floor(ntc_size/exp2(float(desired))),vec2(1.0));
    ivec2 page=ivec2(floor(fract(uv)*wanted_size/64.0));
    vec4 entry=texelFetch(ntc_pages,ivec2(page.x,row+page.y),0);
    // CPU page residency already resolved the ancestor and its affine UV transform.
    return vec4(fract(uv)*entry.zw+entry.xy,entry.zw);
}
void fragment() {
    vec2 uv = UV*uv_scale+uv_offset;
    vec4 base = vec4(1.0);
    vec3 norm = vec3(0.5,0.5,1.0);
    vec3 orm = vec3(1.0);
    if (ntc_ready) {
        vec2 dx=dFdx(uv)*ntc_size, dy=dFdy(uv)*ntc_size;
        float lod=clamp(0.5*log2(max(max(dot(dx,dx),dot(dy,dy)),1.0)),0.0,float(ntc_mips-1));
        vec4 a=page_uv(uv,int(floor(lod)));
        base=textureLod(ntc_albedo,a.xy,0.0);
        if (ntc_has_normal) norm=textureLod(ntc_normal,a.xy,0.0).rgb;
        if (ntc_has_orm) orm=textureLod(ntc_orm,a.xy,0.0).rgb;
        float blend=fract(lod);
        // Magnification / an exact mip needs one sample, not two duplicate lookups.
        if (blend>0.001) {
            vec4 b=page_uv(uv,min(int(floor(lod))+1,ntc_mips-1));
            if (a.z!=b.z || a.w!=b.w) {
                base=mix(base,textureLod(ntc_albedo,b.xy,0.0),blend);
                if (ntc_has_normal) norm=mix(norm,textureLod(ntc_normal,b.xy,0.0).rgb,blend);
                if (ntc_has_orm) orm=mix(orm,textureLod(ntc_orm,b.xy,0.0).rgb,blend);
            }
        }
    }
    ALBEDO = base.rgb*albedo.rgb;
    ROUGHNESS = orm.g*roughness;
    METALLIC = orm.b*metallic;
    SPECULAR = specular;
    AO = ao_enabled ? orm.r : 1.0;
    AO_LIGHT_AFFECT = ao_light_affect;
    if (ntc_has_normal) { NORMAL_MAP = norm; NORMAL_MAP_DEPTH=normal_scale; }
}
