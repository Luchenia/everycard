shader_type canvas_item;
// Held time softly drains colour (a light black-and-white) from the whole world: floor, units and effects.
// Warnings, paths, hp bars and numbers are drawn above this, so they keep their colour and stand out. The drain spreads out
// from the hero as a ring when time stops.
uniform sampler2D screen : hint_screen_texture, filter_nearest;
uniform float amount = 0.0;
uniform vec2 center = vec2(0.5);
uniform float aspect = 1.4;
uniform float wave = 9.0;   // seconds since time stopped

void fragment() {
	vec3 c = texture(screen, SCREEN_UV).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	vec3 grey = vec3(l);
	vec2 d = (UV - center) * vec2(aspect, 1.0);
	float r = length(d);
	float reach = clamp(wave / 0.55, 0.0, 1.0);
	reach = 1.0 - pow(1.0 - reach, 3.0);
	float m = amount * smoothstep(reach * 1.8, reach * 1.8 - 0.45, r);
	// a slight darkening toward the room's edges
	float edge = smoothstep(0.55, 1.05, r);
	// a light black-and-white: most of the colour goes, a little stays, barely any darkening
	vec3 o = mix(c, grey, m * 0.85);
	o *= 1.0 - m * (0.04 + edge * 0.12);
	COLOR = vec4(o, 1.0);
}
