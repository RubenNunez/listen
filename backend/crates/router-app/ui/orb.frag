#version 300 es
// The Listen orb, carried over line by line from the app's Metal shader
// ios/Listen/Views/FluidOrb.metal (function names and numbers kept, so a change there
// can be carried over here). Differences, all mechanical:
//  - Metal's `position` (top-left origin) is rebuilt from gl_FragCoord.
//  - `active` and `flat` are reserved words in GLSL ES and are called `active_` and `flatDir`;
//    the local `main` (the main vein) is called `mainVein`.
//  - pow(v, 2.0) on values that can be negative is written v * v (GLSL leaves pow of a negative undefined).
//  - The result is premultiplied, as the app's colorEffect returns it.
//  - The router always draws morph 0 (no microphone). Changes to the Metal shader that show
//    only on the way from calm to speech need not be carried over.
// One fluid body made of a few blobs and a swarm of particles.
// Quiet: the blobs drift apart into several small ones and flow back into one,
// and the particles circle them or sink into them.
// Sound: every particle draws itself out into a stroke; with speech (morph 1)
// the strokes ride the captured signal, whose shape is in `wave`.
// When all of it has flowed into one sphere, wings unfold behind it.
// Everything is one scalar field with a soft threshold, so parts merge and
// separate like liquid and no change is a cut.
precision highp float;
precision highp int;

uniform vec2 u_size;
uniform float u_time;
uniform float u_morph;
uniform float u_level;
uniform float u_speakers;
uniform float u_active;
uniform float u_dark;
uniform vec2 u_lean;
uniform float u_gather;
uniform float u_since;
uniform float u_bleed;
uniform float u_wave[64];
uniform int u_waveCount;

out vec4 fragColor;

// Catmull-Rom through the points: the line and its slope are both continuous,
// so it reads as one smooth curve rather than joined segments.
float sampleWave(int count, float x) {
    float position = clamp(x, 0.0, 1.0) * float(count - 1);
    int index = min(int(floor(position)), count - 2);
    float t = position - float(index);
    float p0 = u_wave[max(index - 1, 0)];
    float p1 = u_wave[index];
    float p2 = u_wave[index + 1];
    float p3 = u_wave[min(index + 2, count - 1)];
    return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
                  + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t);
}

// Smooth value noise, for motion that never repeats in an obvious loop.
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

vec2 drift(float seed, float time) {
    return vec2(noise(vec2(seed, time)), noise(vec2(seed + 17.3, time * 0.93))) * 2.0 - 1.0;
}

// Where the winged body is at a moment: it hovers, wanders in loops and now and
// then darts a little way, like something that flies because it wants to.
vec2 flightPath(float time) {
    vec2 loops = vec2(0.048 * sin(time * 0.55) + 0.018 * sin(time * 1.9 + 0.7),
                      0.036 * sin(time * 1.10 + 1.0) + 0.016 * sin(time * 2.7));
    return loops + 0.030 * drift(63.0, time * 0.45);
}

// Cells like those of a dragonfly's wing: returns how close the point is to a
// cell's border (x, 0 on the border) and a number that differs from cell to cell (y).
vec2 cells(vec2 p) {
    vec2 base = floor(p);
    vec2 f = fract(p);
    float first = 8.0;
    float second = 8.0;
    float id = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 cell = vec2(float(x), float(y));
            vec2 seed = base + cell;
            vec2 point = cell + vec2(hash(seed), hash(seed + 31.7)) * 0.8 + 0.1 - f;
            float d = dot(point, point);
            if (d < first) { second = first; first = d; id = hash(seed + 7.3); }
            else if (d < second) { second = d; }
        }
    }
    return vec2(sqrt(second) - sqrt(first), id);
}

// What one wing contributes at a point.
struct WingSample {
    float cover;  // how much of the wing lies over the point
    float shine;  // light caught by the membrane where it turns towards the viewer
    float hue;    // where on the wing's sheen the point lies
    float halo;   // soft light just outside the wing's edge
};

// One wing in three dimensions, drawn flat. It is hinged at its root and swings
// towards and away from the viewer by `swing` radians; `flex` lets the tip lag
// behind the root, as a thin membrane does. Swinging shortens the wing on screen,
// brings its far half nearer (so it grows a little) and changes what light it
// catches. `p` is measured from the root, `dir` points along the wing, `up` is 1
// when a negative offset across the wing is its leading edge.
WingSample wingAt(vec2 p, vec2 dir, float up, float len, float lead, float trail, float bend,
                  float swing, float flex, float px, float time, float seed) {
    WingSample w;
    w.cover = 0.0; w.shine = 0.0; w.hue = 0.0; w.halo = 0.0;
    float along = dot(p, dir);
    if (along <= 0.0) { return w; }
    float first = clamp(along / (len * max(cos(swing), 0.25)), 0.0, 1.0);
    float here = swing + flex * first * first;
    float shorten = max(cos(0.5 * (swing + here)), 0.22);
    float u = along / (len * shorten);
    if (u >= 1.0) { return w; }
    float depth = u * sin(here);
    float across = (up * dot(p, vec2(-dir.y, dir.x)) - bend * len * shorten * u * u) / (1.0 + 0.30 * depth);
    // The leading edge is nearly straight and strong, the trailing edge full and soft.
    // Both run out into a rounded tip, like a petal.
    float front = lead * len * pow(u, 0.50) * pow(1.0 - u, 0.50);
    float back = trail * len * pow(u, 0.75) * pow(1.0 - u, 0.60);
    float inside = across < 0.0 ? front + across : back - across;
    if (inside <= -0.04) { return w; }
    w.halo = exp(min(inside, 0.0) / 0.012) * (1.0 - 0.6 * u) * step(inside, 0.0);
    float mask = smoothstep(-px, px, inside);
    if (mask <= 0.0) { return w; }
    float span = across < 0.0 ? front : back;
    float s = across / max(span, 0.0005);

    // Membrane: sheer, denser at the root and where it is seen nearly edge-on.
    float membrane = mix(0.34, 0.10, smoothstep(0.0, 0.9, u)) * mix(1.0, 1.8, 1.0 - shorten);
    // Rim: a fine line all round, heavier along the leading edge.
    float rim = smoothstep(0.0045 + 3.0 * px, 0.0, inside) * (across < 0.0 ? 0.80 : 0.42) * (1.0 - 0.35 * u);
    // The main vein runs just behind the leading edge and thins out towards the tip.
    float mainVein = smoothstep(0.0030 * (1.0 - u) + px, 0.0, abs(s + 0.70) * front) * step(across, 0.0);
    // The membrane is made of cells, long near the root and small towards the edge;
    // their borders are the fine veins, and each cell holds the light a little differently.
    vec2 cell = cells(vec2(u * 6.5 + seed, s * 2.4 * (0.7 + 0.6 * u)));
    float veins = smoothstep(0.085, 0.015, cell.x) * smoothstep(0.03, 0.14, u);
    // Light slides across the membrane as the wing turns.
    float sheen = (here - 0.30 + 0.5 * s * 0.2) / 0.22;
    w.shine = exp(-(sheen * sheen)) * (0.55 + 0.45 * noise(vec2(u * 9.0 + seed, s * 4.0)));
    w.hue = 0.7 * u + 0.2 * s + 0.5 * here + 0.45 * cell.y + seed * 0.13 + time * 0.03;
    float fine = smoothstep(0.012, 0.005, px);  // 0 when a pixel is too coarse for veins
    w.cover = mask * clamp(membrane * (0.85 + 0.35 * cell.y * fine) + rim + fine * (0.55 * mainVein + 0.30 * veins) + 0.20 * w.shine, 0.0, 1.0);
    return w;
}

// How the orb looks on a light background, as `dayLook` in FluidOrb.metal.
// 1: it glows white inside a cool bloom. 2: white over a soft neutral shadow.
// 3: a pearl, white with a graphite rim and no halo. 0: the earlier look, graphite to black.
// The dark appearance is the same for all. The canvas is not an sRGB layer, so the Metal
// shader's `forSRGBLayer` has no counterpart here.
const int dayLook = 1;

vec4 fluidOrbField() {
    vec2 size = u_size;
    float time = u_time;
    float morph = u_morph;
    float level = u_level;
    float speakers = u_speakers;
    float active_ = u_active;
    float dark = u_dark;
    vec2 lean = u_lean;
    float gather = u_gather;
    float since = u_since;
    float bleed = u_bleed;
    int waveCount = u_waveCount;
    vec2 position = vec2(gl_FragCoord.x, size.y - gl_FragCoord.y);

    // The canvas is larger than the orb's place in the layout by `bleed` on every side, so
    // wings, dust and sparks can leave that place without being cut off. All measures
    // refer to the place itself.
    vec2 place = size - 2.0 * bleed;
    float scale = min(place.x, place.y);
    vec2 uv = (position - 0.5 * size) / scale;
    // Waking up. `since` counts the seconds from the moment the microphone was switched
    // on: the body swells and springs back, rings of light run outwards and sparks fly.
    float wake = clamp(since, 0.0, 10.0);
    // It swells over the first few frames: starting at its full swell would be a jump in size.
    float pop = (0.42 * exp(-wake * 4.2) * sin(wake * 13.0 + 0.6) + 0.30 * exp(-wake * 9.0)) * smoothstep(0.0, 0.10, wake);
    vec2 plain = uv;
    uv /= 1.0 + pop;
    // The surface itself is never quite still: a slow warp of the space it lives in.
    float calm = 1.0 - morph;
    uv += calm * 0.018 * drift(3.0 + uv.y * 2.4, time * 0.35 + uv.x * 2.0);

    // The loudest point sets the scale, so a quiet voice still draws a clear line
    // while silence stays nearly flat.
    float peak = 0.0;
    for (int i = 0; i < waveCount; i++) { peak = max(peak, abs(u_wave[i])); }
    float gain = 0.12 / max(peak, 0.10);
    float stretch = scale / place.x;

    // A slow breath, now and then a shiver, and a tide of its own: at high tide
    // everything flows into one body, at low tide it lies apart as several small
    // ones. Sound in the room pushes it apart as well.
    float breath = 0.5 + 0.5 * sin(time * 0.9 + 0.6 * sin(time * 0.37));
    float shiver = smoothstep(0.82 - 0.3 * level, 1.0, noise(vec2(time * 0.22, 9.1)));
    // `gather` holds the tide high: everything stays in one sphere.
    float tide = max(smoothstep(0.32, 0.68, noise(vec2(time * 0.10, 5.5))), gather);
    float apart = clamp(1.0 - tide + 0.6 * level, 0.0, 1.2);
    float pull = length(lean);

    // With everything in one sphere and the room quiet, wings unfold behind it. They
    // beat about once a second, down faster than up, never twice quite the same, and
    // the body rises and sinks a little with every stroke. Drawn small, the wings keep their
    // shape and rim and lose only the fine veins, which would turn to noise.
    float winged = smoothstep(0.80, 0.40, apart) * calm;
    float beat = time * 6.3 + 1.4 * noise(vec2(time * 0.21, 2.2));
    float reach = 0.42 + 0.26 * noise(vec2(time * 0.33, 7.7));
    // Winged, the figure is drawn a touch smaller; its wings may reach beyond the orb's place.
    uv *= 1.0 + 0.05 * winged;
    vec2 still = uv;  // the view itself, before the body flies off in it
    // It turns towards where it is flying, and looks about on its own: `turn` is how far
    // it has turned away from the viewer, to the left or the right.
    float heading = (flightPath(time + 0.06).x - flightPath(time - 0.06).x) / 0.12;
    float turn = clamp(heading * 7.0, -1.0, 1.0) * 0.75 + 0.45 * sin(time * 0.27 + 0.8 * sin(time * 0.11));
    uv -= winged * flightPath(time);
    uv.y += winged * 0.011 * sin(beat + 1.2);

    float spread = 1.0 - 0.75 * morph;
    float spheres = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        // Each blob wanders on its own noise path instead of a fixed orbit.
        vec2 wander = drift(fi * 5.7, time * (0.14 + 0.03 * fi)) * (0.17 + 0.08 * level);
        vec2 orbit = vec2(sin(time * (0.31 + 0.07 * fi) + fi * 1.7),
                          cos(time * (0.27 + 0.05 * fi) + fi * 2.3)) * 0.04;
        float follow = 0.35 + 0.25 * fi;  // inner blobs lag, outer ones swing far
        vec2 centre = (wander + orbit) * spread * (0.22 + 1.15 * apart) * (0.85 + 0.25 * breath)
                    + lean * 0.20 * follow * calm
                    + shiver * (0.012 + 0.03 * level) * drift(fi * 2.1, time * 6.0);
        float radius = ((0.100 - 0.014 * fi) + 0.012 * sin(time * 0.7 + fi * 1.9)
                     + 0.010 * breath + 0.03 * level) * (1.0 - 0.08 * winged);  // a little smaller between its wings
        vec2 d = uv - centre;
        // Moving makes it stretch along the pull, like something soft being dragged.
        if (pull > 0.001) {
            vec2 along = lean / pull;
            d -= along * dot(d, along) * min(0.35, pull * 0.5) * calm;
        }
        d.y *= 1.0 + 2.5 * morph;  // the blobs flatten as the signal takes over
        spheres += (radius * radius) / (dot(d, d) + 0.0008);
    }

    // The swarm. Each particle has a place around the body and a place on the
    // signal, and is somewhere between the two.
    float particles = 0.0;
    for (int j = 0; j < 18; j++) {
        float fj = float(j);
        float h1 = hash(vec2(fj, 1.7));
        float h2 = hash(vec2(fj, 4.1));
        float h3 = hash(vec2(fj, 8.9));
        // Quiet: it circles the body, further out at low tide, inside it at high tide.
        float angle = 6.2832 * h1 + time * (0.20 + 0.45 * h2) * (h3 > 0.5 ? 1.0 : -1.0)
                    + 2.0 * noise(vec2(fj * 2.3, time * 0.30));
        float reach = (0.09 + 0.27 * noise(vec2(fj * 4.9 + 2.0, time * (0.12 + 0.10 * h2))))
                    * (0.12 + apart) + 0.08 * level * h3;
        vec2 around = vec2(cos(angle), sin(angle));
        vec2 home = around * reach + lean * 0.30 * (0.4 + h1) * calm
                  + shiver * 0.02 * drift(fj * 3.3, time * 5.0);
        // Speech: it travels along the signal, a little above or below it.
        float a = (fract(h1 + time * (0.03 + 0.06 * h2)) - 0.5) * 0.74;
        float edge = smoothstep(0.36, 0.20, abs(a));
        float value = 0.0;
        float slope = 0.0;
        if (waveCount > 1) {
            value = sampleWave(waveCount, a + 0.5) * gain;
            slope = (sampleWave(waveCount, a + 0.504) - sampleWave(waveCount, a + 0.496))
                  * gain / 0.008 * stretch;
        }
        vec2 onSignal = vec2(a / stretch, value * edge + (h3 - 0.5) * 0.10 * (0.25 + level));
        vec2 centre = mix(home, onSignal, morph);
        // Sound draws it out into a stroke: along its path when quiet, along
        // the signal when someone speaks.
        float stroke = max(morph, smoothstep(0.04, 0.40, level * (0.6 + 0.9 * h2)));
        vec2 axis = mix(vec2(-around.y, around.x), normalize(vec2(1.0, clamp(slope * edge, -1.2, 1.2))), morph);
        axis = normalize(axis + vec2(0.0001, 0.0));
        vec2 d = uv - centre;
        float lengthwise = dot(d, axis) / (1.0 + 2.6 * stroke * (0.5 + h3));
        float sideways = dot(d, vec2(-axis.y, axis.x)) * (1.0 + 1.5 * stroke);
        float radius = (0.022 + 0.022 * h2) * mix(1.0, edge, morph);
        particles += (radius * radius) / (lengthwise * lengthwise + sideways * sideways + 0.0002);
    }

    // Wings: four of them behind the body, the lower pair first so the upper pair lies over it.
    vec3 wingColour = vec3(0.0);
    float wingAlpha = 0.0;
    if (winged > 0.001) {
        float px = 1.2 / scale;
        // The wings grow from the back: turned to one side, their roots show on the other.
        vec2 root = lean * 0.10 * calm + 0.010 * drift(41.0, time * 0.25) - vec2(0.030 * sin(turn), 0.0);
        float unfold = 0.30 + 0.70 * winged;
        vec3 base = mix(vec3(0.20, 0.23, 0.31), vec3(0.86, 0.90, 1.0), dark);
        if (dayLook == 1 && dark < 0.5) { base = vec3(0.27, 0.36, 0.66); }  // wings of the same cool light
        for (int w = 0; w < 4; w++) {
            bool upper = w >= 2;
            float side = (w % 2 == 0) ? 1.0 : -1.0;
            // The lower pair follows the upper one a moment later; left and right differ by a breath.
            float lag = (upper ? 0.0 : 0.75) + (side > 0.0 ? 0.0 : 0.06);
            float swing = (upper ? 0.30 : 0.22) + (upper ? 1.0 : 0.8) * reach * sin(beat - lag - 0.35 * sin(beat - lag));
            float flex = -0.55 * reach * cos(beat - lag);
            // Screen y points down: a negative y lifts the wing. It also sweeps a little in its own plane.
            float angle = upper ? (0.62 + 0.10 * sin(beat - lag)) : (-0.46 - 0.07 * sin(beat - lag));
            // In space each wing points outwards, upwards and a little backwards. Turning the
            // body swings both pairs to one side: the near wing lengthens, the far one shortens
            // and slips behind the body.
            vec2 flatDir = vec2(side * cos(angle) * cos(turn) - 0.62 * sin(turn), -sin(angle));
            float seen = length(flatDir);
            vec2 dir = flatDir / max(seen, 0.001);
            float facing = flatDir.x * side > 0.0 ? 1.0 : -1.0;  // a wing swung across the body shows its other face
            WingSample one = wingAt(uv - root, dir, side * facing, (upper ? 0.50 : 0.34) * unfold * clamp(seen, 0.35, 1.15),
                                    upper ? 0.36 : 0.44, upper ? 0.62 : 0.74, (upper ? -0.14 : 0.18),
                                    swing, flex, px, time, float(w) * 3.7);
            // A faint play of colour, as on a soap film: never more than a tint.
            vec3 film = 0.5 + 0.5 * cos(6.2832 * (one.hue + vec3(0.0, 0.33, 0.67)));
            vec3 colour = base + (film - 0.5) * mix(0.06, 0.12, dark) + (dark > 0.5 ? 0.16 : -0.10) * one.shine;
            float a = one.cover * winged + one.halo * winged * mix(0.05, 0.12, dark);
            wingColour = wingColour * (1.0 - a) + colour * a;
            wingAlpha = wingAlpha * (1.0 - a) + a;
        }
    }

    // An aura: light that spills from the body over the roots of the wings.
    if (winged > 0.001) {
        vec2 d = uv - lean * 0.10 * calm;
        vec3 light = mix(vec3(0.60, 0.72, 0.98), vec3(0.80, 0.90, 1.0), dark);
        float a = (0.42 * exp(-dot(d, d) / 0.020) + 0.12 * exp(-dot(d, d) / 0.050)) * winged * (0.85 + 0.15 * sin(beat));
        wingColour = wingColour * (1.0 - a) + light * a;
        wingAlpha = wingAlpha * (1.0 - a) + a;
    }

    // The wake itself: two rings and a burst of sparks, gone after a second and a half.
    if (wake < 1.6) {
        vec3 spark = mix(vec3(0.10, 0.14, 0.34), vec3(0.95, 0.97, 1.0), dark);
        if (dayLook == 1 && dark < 0.5) { spark = vec3(0.28, 0.40, 0.90); }
        float far = length(plain);
        for (int r = 0; r < 2; r++) {
            float t = clamp((wake - 0.14 * float(r)) / (1.0 + 0.2 * float(r)), 0.0, 1.0);
            float eased = 1.0 - pow(1.0 - t, 3.0);
            float radius = 0.07 + 0.50 * eased;
            float thick = 0.010 * (1.0 - t) + 0.0025;
            float off = (far - radius) / thick;
            float ring = exp(-(off * off)) * (1.0 - t) * (1.0 - t) * step(0.001, t);
            float a = clamp(ring * (r == 0 ? 0.85 : 0.5), 0.0, 1.0);
            wingColour = wingColour * (1.0 - a) + spark * a;
            wingAlpha = wingAlpha * (1.0 - a) + a;
        }
        float t = clamp(wake / 1.3, 0.0, 1.0);
        float eased = 1.0 - pow(1.0 - t, 2.6);
        for (int k = 0; k < 22; k++) {
            float fk = float(k);
            float h1 = hash(vec2(fk, 12.3));
            float h2 = hash(vec2(fk, 45.6));
            float angle = 6.2832 * (fk + h1) / 22.0;
            // Each spark flies out on a slightly bent path and falls a little at the end.
            vec2 at = vec2(cos(angle + 0.5 * eased * (h2 - 0.5)), sin(angle + 0.5 * eased * (h2 - 0.5)))
                    * (0.06 + (0.22 + 0.26 * h2) * eased) + vec2(0.0, 0.05 * t * t);
            vec2 d = plain - at;
            float size = (0.007 + 0.008 * h1) * (1.0 - 0.7 * t);
            float glow = exp(-dot(d, d) / (size * size));
            float rays = exp(-abs(d.x) * abs(d.y) / (size * size * 0.10)) * exp(-length(d) / (size * 5.0));
            float a = clamp(1.4 * glow + rays, 0.0, 1.0) * (1.0 - t) * smoothstep(0.0, 0.05, t);
            wingColour = wingColour * (1.0 - a) + spark * a;
            wingAlpha = wingAlpha * (1.0 - a) + a;
        }
    }

    // Dust. The flying body sheds motes of light where it has just been; each one
    // sinks, drifts sideways, twinkles and is gone after a few seconds.
    if (winged > 0.001) {
        vec3 mote = mix(vec3(0.16, 0.24, 0.55), vec3(0.92, 0.95, 1.0), dark);
        float life = 3.2;
        for (int m = 0; m < 26; m++) {
            float fm = float(m);
            float turn = time / life + fm / 26.0;
            float age = fract(turn);
            float born = (floor(turn) - fm / 26.0) * life;
            float h1 = hash(vec2(fm, floor(turn) + 3.1));
            float h2 = hash(vec2(fm + 9.0, floor(turn) + 5.7));
            vec2 at = flightPath(born) * winged
                    + vec2((h1 - 0.5) * 0.62, -0.10 + 0.30 * h2) * sqrt(age)  // leaves the body quickly, some of it upwards
                    + vec2(0.02 * sin(age * 7.0 + h1 * 6.0), 0.20 * age * age);  // sways and sinks
            vec2 d = still - at;
            float r = (0.0110 + 0.0130 * h2) * (1.0 - 0.5 * age);
            float glow = exp(-dot(d, d) / (r * r));
            // A glint: four fine rays that come and go.
            float twinkle = 0.5 + 0.5 * sin(time * (5.0 + 6.0 * h1) + fm);
            float rays = exp(-abs(d.x) * abs(d.y) / (r * r * 0.10)) * exp(-length(d) / (r * 4.5)) * twinkle;
            float a = clamp(1.5 * glow + rays, 0.0, 1.0) * (1.0 - age) * smoothstep(0.0, 0.06, age) * winged;
            wingColour = wingColour * (1.0 - a) + mote * a;
            wingAlpha = wingAlpha * (1.0 - a) + a;
        }
    }

    int count = int(clamp(speakers, 1.0, 4.0));
    // Along the line the view's full width is used, whatever its shape.
    float across = (position.x - 0.5 * size.x) / place.x;
    // The line keeps to the middle of the view: a signal, not a banner.
    float sides = smoothstep(0.36, 0.14, abs(across));
    float waves = 0.0;
    for (int k = 0; k < count; k++) {
        float fk = float(k);
        float offset = (fk - (float(count) - 1.0) * 0.5) * 0.16;
        // One microphone gives one signal: the first line is the real sound,
        // further lines stay flat until speakers can be told apart.
        float value = 0.0;
        float slope = 0.0;
        if (k == 0 && waveCount > 1) {
            float x = across + 0.5;
            value = sampleWave(waveCount, x) * gain;
            slope = (sampleWave(waveCount, x + 0.004) - sampleWave(waveCount, x - 0.004)) * gain / 0.008 * stretch;
        }
        // Dividing by the slope's length keeps the stroke equally thick on steep parts.
        float distance = (uv.y - (offset + value * sides)) / sqrt(1.0 + slope * slope * sides * sides);
        // A fine line; it gains only a little weight with loudness.
        float width = (k == 0 ? 0.0030 : 0.0024) + 0.0012 * level;
        waves += sides * exp(-(distance * distance) / (2.0 * width * width)) * (k == 0 ? 3.4 : 1.6);
    }

    float field = mix(spheres, waves, morph) + particles;
    float alpha = smoothstep(0.55, 2.0, field);
    float core = smoothstep(1.6, 4.0, field);

    // Ink: silver to white on black, graphite to black on white.
    vec3 onDark = mix(vec3(0.56, 0.61, 0.71), vec3(1.0), core);
    vec3 onLight = mix(vec3(0.45, 0.49, 0.58), vec3(0.05, 0.05, 0.07), core);
    vec3 tone = mix(onLight, onDark, dark);
    // A soft highlight that slides the other way when the body is pulled.
    vec2 light = vec2(-0.06, -0.07) - lean * 0.10;
    float glint = exp(-dot(uv - light, uv - light) / 0.012) * core * calm;
    tone += (dark > 0.5 ? 0.10 : -0.10) * glint;
    vec3 resting = mix(vec3(0.70), vec3(0.45), dark);
    tone = mix(resting, tone, active_);
    if (dayLook != 0 && dark < 0.5) {
        // White on white: the body is told from the page by a tinted rim and by the bloom
        // it lies in, not by being dark. Drawn out into the signal it turns to ink,
        // because a fine white line would be lost.
        vec3 rim = dayLook == 1 ? vec3(0.42, 0.55, 1.0) : (dayLook == 2 ? vec3(0.62, 0.65, 0.72) : vec3(0.38, 0.42, 0.54));
        vec3 halo = dayLook == 1 ? vec3(0.40, 0.54, 1.0) : vec3(0.44, 0.47, 0.56);
        float strength = dayLook == 1 ? 0.42 : (dayLook == 2 ? 0.22 : 0.0);
        float inked = smoothstep(0.42, 0.76, morph);
        // By way of a deep blue: straight from white to ink would pass through a muddy grey.
        vec3 heart = mix(mix(vec3(1.0), vec3(0.24, 0.32, 0.70), min(1.0, 2.0 * inked)), vec3(0.08, 0.10, 0.24), max(0.0, 2.0 * inked - 1.0));
        float lit = dayLook == 3 ? smoothstep(0.8, 3.2, field) : smoothstep(0.7, 1.7, field);
        vec3 day = mix(rim, heart, lit);
        // The side away from the light is a shade cooler, so the white body has volume.
        day = mix(day, rim, 0.05 * (1.0 - exp(-dot(uv - light, uv - light) / 0.012)) * core * (1.0 - inked));
        tone = mix(resting, day, active_);
        float bloom = strength * pow(smoothstep(0.16, 1.3, field), 1.3) * (1.0 - 0.5 * inked) * active_;
        wingColour = wingColour * (1.0 - bloom) + halo * bloom;
        wingAlpha = wingAlpha * (1.0 - bloom) + bloom;
    }
    // Off, it is grey but as solid as ever.
    // The wings lie behind the body. Everything light around it (wings, aura, dust, the
    // wake) runs out in a circle well inside the canvas, so its square border never shows.
    float canvas = 0.5 + bleed / scale;  // how far the canvas goes, in the orb's own measure
    float room = smoothstep(canvas - 0.02, canvas - 0.30, length(plain));
    wingColour *= room;
    wingAlpha *= room;
    float behind = 1.0 - alpha;
    vec3 wingTone = mix(resting * wingAlpha, wingColour, active_) * behind;
    wingAlpha *= behind;
    return vec4(tone * alpha + wingTone, alpha + wingAlpha);
}

void main() {
    fragColor = fluidOrbField();
}
