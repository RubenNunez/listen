// Draws the Listen orb with WebGL2, fed the way the app feeds its Metal shader
// (ios/Listen/Views/Theme.swift): the same spring for the pull, the same colour fade,
// the same canvas reaching 0.75 of the orb's size beyond its place.
// The router has no microphone: morph 0, no wave, and `gather` 1 keeps it in one
// winged sphere.
"use strict";

window.Orb = (function () {
  const state = {
    active: 0,          // shown colour, 0 grey to 1 coloured
    on: false,          // whether the router is ready
    changed: performance.now() - 10000,
    level: 0,           // a little life while a session answers
    levelTarget: 0,
    wakeAt: null,       // when the wake (rings and sparks) last started
    lean: { x: 0, y: 0 },
    velocity: { x: 0, y: 0 },
    target: { x: 0, y: 0 },
  };
  const dark = window.matchMedia("(prefers-color-scheme: dark)");
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

  function fallback(place) {
    place.classList.add("orb-fallback");
  }

  async function start(place) {
    const canvas = place.querySelector("canvas");
    const gl = canvas.getContext("webgl2", { premultipliedAlpha: true, alpha: true, antialias: false });
    if (!gl) return fallback(place);
    let source;
    try {
      source = await (await fetch("orb.frag")).text();
    } catch (e) {
      return fallback(place);
    }
    const vertex = `#version 300 es
      in vec2 corner;
      void main() { gl_Position = vec4(corner, 0.0, 1.0); }`;
    function compile(type, text) {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, text);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        console.error("orb shader:", gl.getShaderInfoLog(shader));
        return null;
      }
      return shader;
    }
    const vs = compile(gl.VERTEX_SHADER, vertex);
    const fs = compile(gl.FRAGMENT_SHADER, source);
    if (!vs || !fs) return fallback(place);
    const program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      console.error("orb program:", gl.getProgramInfoLog(program));
      return fallback(place);
    }
    gl.useProgram(program);
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const corner = gl.getAttribLocation(program, "corner");
    gl.enableVertexAttribArray(corner);
    gl.vertexAttribPointer(corner, 2, gl.FLOAT, false, 0, 0);
    const u = {};
    for (const name of ["u_size", "u_time", "u_morph", "u_level", "u_speakers", "u_active", "u_dark",
                        "u_lean", "u_gather", "u_since", "u_bleed", "u_waveCount"]) {
      u[name] = gl.getUniformLocation(program, name);
    }
    gl.uniform1f(u.u_morph, 0);
    gl.uniform1f(u.u_speakers, 1);
    gl.uniform1f(u.u_gather, 1);
    gl.uniform1i(u.u_waveCount, 0);

    // How far and which way the pointer pulls the body, from -1 to 1 on each axis (Theme.swift, pull).
    // As in the app, only a pointer over the orb's own view pulls, measured against that view's
    // size: near the body a little, at the view's edge fully. Elsewhere in the window it rests.
    window.addEventListener("pointermove", (event) => {
      const box = canvas.getBoundingClientRect();
      const half = Math.max(Math.min(box.width, box.height) / 2, 1);
      const x = (event.clientX - (box.left + box.width / 2)) / half;
      const y = (event.clientY - (box.top + box.height / 2)) / half;
      const length = Math.hypot(x, y);
      state.target = length > 1 ? { x: 0, y: 0 } : { x, y };
    });
    document.addEventListener("pointerleave", () => { state.target = { x: 0, y: 0 }; });

    const began = performance.now();
    let last = began;
    let clock = 0;
    function frame(now) {
      const elapsed = Math.min((now - last) / 1000, 1 / 30);
      last = now;
      clock += elapsed * (reduced.matches ? 0.2 : 1);

      // The body has mass: it follows the pull on a spring (Theme.swift, OrbBody).
      const stiffness = 42.0, damping = 5.5;
      state.velocity.x += (stiffness * (state.target.x - state.lean.x) - damping * state.velocity.x) * elapsed;
      state.velocity.y += (stiffness * (state.target.y - state.lean.y) - damping * state.velocity.y) * elapsed;
      state.lean.x += state.velocity.x * elapsed;
      state.lean.y += state.velocity.y * elapsed;
      state.level += (state.levelTarget - state.level) * (1 - Math.exp(-elapsed * 3));

      // Colour flows in over most of a second and drains a little faster.
      const sinceChange = (now - state.changed) / 1000;
      state.active = state.on ? Math.min(1, sinceChange / 0.8) : Math.max(0, 1 - sinceChange / 0.5);
      const since = state.on && state.wakeAt !== null && !reduced.matches ? (now - state.wakeAt) / 1000 : 99;

      const ratio = window.devicePixelRatio || 1;
      const box = canvas.getBoundingClientRect();
      const width = Math.round(box.width * ratio), height = Math.round(box.height * ratio);
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
      }
      gl.viewport(0, 0, width, height);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      // The canvas is the place plus 0.75 of the place on every side: place = size / 2.5.
      const placeSize = Math.min(width, height) / 2.5;
      gl.uniform2f(u.u_size, width, height);
      gl.uniform1f(u.u_time, clock % 3600);
      gl.uniform1f(u.u_level, state.level);
      gl.uniform1f(u.u_active, state.active);
      gl.uniform1f(u.u_dark, dark.matches ? 1 : 0);
      gl.uniform2f(u.u_lean, state.lean.x, state.lean.y);
      gl.uniform1f(u.u_since, since);
      gl.uniform1f(u.u_bleed, 0.75 * placeSize);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  return {
    start,
    /** The router's state: ready colours it, answering stirs it. */
    set({ ready, answering }) {
      if (ready !== state.on) {
        state.on = ready;
        state.changed = performance.now();
        if (ready) state.wakeAt = performance.now();
      }
      state.levelTarget = answering ? 0.12 : 0;
    },
    /** Rings and sparks, as when the app's microphone comes on. */
    wake() {
      state.wakeAt = performance.now();
    },
  };
})();
