shader_type canvas_item;
render_mode unshaded;

uniform mat4 world_to_clip;
uniform vec2 viewport_size;
varying flat float selected;
varying flat float visible_point;

void vertex() {
	vec4 clip = world_to_clip * vec4(INSTANCE_CUSTOM.xyz, 1.0);
	selected = INSTANCE_CUSTOM.w;
	visible_point = float(clip.w > 0.0 && abs(clip.z) <= clip.w);
	vec2 screen = (clip.xy / max(clip.w, 0.00001) * vec2(0.5, -0.5) + 0.5) * viewport_size;
	VERTEX = screen + VERTEX * mix(4.0, 8.0, selected);
}

void fragment() {
	if (visible_point < 0.5) { discard; }
	float radius = length(UV * 2.0 - 1.0);
	float aa = max(fwidth(radius), 0.01);
	float disc = 1.0 - smoothstep(mix(1.0, 0.5, selected) - aa, mix(1.0, 0.5, selected), radius);
	float ring = selected * smoothstep(0.68, 0.68 + aa, radius) * (1.0 - smoothstep(1.0 - aa, 1.0, radius));
	COLOR.rgb = mix(COLOR.rgb, vec3(1.0), step(0.5, selected) * step(0.6, radius));
	COLOR.a *= max(disc, ring);
}
