shader_type canvas_item;
// Ground states drawn as one connected surface per kind (water, oil, swamp, ice), worked out per
// art pixel so neighbouring cells of the same kind merge into one puddle. The edge wobbles but
// always stays inside the cells that hold the state: nothing spills into a neighbouring cell.

uniform sampler2D state : filter_nearest;   // one texel per cell, r = kind code / 255
uniform vec2 grid = vec2(15.0, 9.0);
uniform float t = 0.0;                      // seconds (slowed down while paused)
uniform float fade = 1.0;

float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vn(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	float a = h21(i), b = h21(i + vec2(1.0, 0.0)), c = h21(i + vec2(0.0, 1.0)), d = h21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float kind_at(vec2 cell) {
	if (cell.x < 0.0 || cell.y < 0.0 || cell.x >= grid.x || cell.y >= grid.y) return 0.0;
	return floor(texture(state, (cell + 0.5) / grid).r * 255.0 + 0.5);
}

void fragment() {
	vec2 p = floor(UV * grid * 16.0);           // art pixel
	vec2 cell = floor(p / 16.0);
	vec2 l = p - cell * 16.0 + 0.5;              // 0.5 .. 15.5 inside the cell
	float k = kind_at(cell);
	if (k < 0.5) { COLOR = vec4(0.0); }
	else {
		// distance to the nearest cell edge whose neighbour is a different kind
		float d = 99.0;
		if (kind_at(cell + vec2(-1, 0)) != k) d = min(d, l.x);
		if (kind_at(cell + vec2(1, 0)) != k) d = min(d, 16.0 - l.x);
		if (kind_at(cell + vec2(0, -1)) != k) d = min(d, l.y);
		if (kind_at(cell + vec2(0, 1)) != k) d = min(d, 16.0 - l.y);
		if (kind_at(cell + vec2(-1, -1)) != k) d = min(d, length(l));
		if (kind_at(cell + vec2(1, -1)) != k) d = min(d, length(l - vec2(16.0, 0.0)));
		if (kind_at(cell + vec2(-1, 1)) != k) d = min(d, length(l - vec2(0.0, 16.0)));
		if (kind_at(cell + vec2(1, 1)) != k) d = min(d, length(l - vec2(16.0, 16.0)));
		float e = 1.5 + 3.0 * vn(p / 6.0 + k * 7.0);
		vec4 col = vec4(0.0);
		if (d <= e) {
			// damp ring just outside the surface
			col = (d > e - 1.6) ? vec4(0.0, 0.0, 0.02, 0.28) : vec4(0.0);
		} else {
			float depth = min(1.0, (d - e) / 5.0);
			float ph = 6.2831 * fract(t / 4.0);
			float r1 = vn(vec2(p.x / 7.0 + 1.5 * cos(ph), p.y / 4.0 + 1.5 * sin(ph)) + k * 3.0);
			float r2 = vn(vec2(p.x / 5.0 - 1.2 * sin(ph), p.y / 3.0 + 1.2 * cos(ph)) + k * 5.0);
			float v = (r1 + r2) * 0.5;
			float g = h21(p + k);
			vec3 c;
			float a = 0.86;
			if (k < 1.5) {          // water
				c = depth < 0.35 ? vec3(0.26, 0.50, 0.69) : (depth < 0.75 ? vec3(0.20, 0.42, 0.63) : vec3(0.16, 0.37, 0.58));
				if (v > 0.50 && v < 0.54) c += vec3(0.09, 0.12, 0.12);
				if (g < 0.025 && sin(ph * 2.0 + g * 400.0) > 0.92) c = vec3(0.84, 0.94, 1.0);
			} else if (k < 2.5) {   // oil: dark, with a slow rainbow sheen
				c = mix(vec3(0.10, 0.08, 0.06), vec3(0.05, 0.04, 0.04), depth);
				if (v > 0.47 && v < 0.53) {
					float hue = fract(v * 3.0 + t * 0.05);
					c += 0.22 * vec3(0.5 + 0.5 * cos(6.2831 * (hue + vec3(0.0, 0.33, 0.67))));
				}
				a = 0.9;
			} else if (k < 3.5) {   // swamp: murky green, a bubble now and then
				c = mix(vec3(0.24, 0.30, 0.13), vec3(0.15, 0.20, 0.09), depth);
				if (v > 0.52 && v < 0.56) c += vec3(0.06, 0.07, 0.02);
				float bub = fract(g * 13.0 + t * 0.3);
				if (g < 0.02 && bub > 0.85) c = vec3(0.52, 0.62, 0.30);
				a = 0.9;
			} else {                // ice: pale, cracked, glinting
				c = mix(vec3(0.70, 0.86, 0.94), vec3(0.56, 0.76, 0.88), depth);
				float cr = abs(vn(p / 4.0 + 11.0) - 0.5);
				if (cr < 0.035) c = vec3(0.92, 0.98, 1.0);
				if (g < 0.02 && sin(t * 1.5 + g * 300.0) > 0.95) c = vec3(1.0);
				a = 0.82;
			}
			if (d - e < 1.0) c = min(vec3(1.0), c + vec3(0.17, 0.19, 0.19));
			col = vec4(c, a);
		}
		COLOR = vec4(col.rgb, col.a * fade);
	}
}
