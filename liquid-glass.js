/*!
 * MesonX Liquid Glass Engine v1.0.0
 * Pure WebGL (WebGL1 / GLSL ES 1.00) - zero dependencies, no CDN required.
 *
 * A hyper-realistic liquid-glass panel that physically refracts a colourful
 * background image beneath it:
 *   1. Specular highlights that follow the pointer (mouse / touch, with inertia)
 *   2. Chromatic aberration (per-channel UV splitting) at the curved glass rim
 *   3. An organic fluid ripple (4-octave animated normals) - gel-like surface
 *
 * Usage:
 *   <script src="liquid-glass.js"></script>
 *   <script>
 *     MesonLiquidGlass.init(document.getElementById('glass'), {
 *       rect:      [0, 0, 1, 1],     // panel rect in UV space
 *       radiusPx:  24,               // corner radius in CSS px (or fn)
 *       solidBg:   false,            // false = transparent outside panel,
 *                                    // true  = draw opaque background outside
 *       texture:   null              // optional <img> / <canvas>; built-in
 *                                    // colourful scene is used when omitted
 *     });
 *   </script>
 */
(function (global) {
  'use strict';

  if (!global || !global.document) return;

  var VERT_SRC = [
    'attribute vec2 aPos;',
    'varying vec2 vUv;',
    'void main(void){',
    '  vUv = aPos * 0.5 + 0.5;',
    '  gl_Position = vec4(aPos, 0.0, 1.0);',
    '}'
  ].join('\n');

  var FRAG_SRC = [
    'precision highp float;',
    'varying vec2 vUv;',
    'uniform vec2  uRes;',
    'uniform float uTime;',
    'uniform vec2  uMouse;',
    'uniform sampler2D uTex;',
    'uniform vec4  uRect;',
    'uniform float uRadius;',
    'uniform float uMode;',
    '',
    'float sdRoundRect(vec2 p, vec2 b, float r){',
    '  vec2 q = abs(p) - b + r;',
    '  return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;',
    '}',
    '',
    '/* ---- organic gel ripple: stacked travelling sine waves ---- */',
    'vec2 ripple(vec2 p){',
    '  float t = uTime;',
    '  vec2 n = vec2(0.0);',
    '  n += 0.60 * vec2(sin(p.x * 9.0  + t * 1.30 + sin(p.y * 5.0  + t * 0.70)),',
    '                   cos(p.y * 8.0  - t * 1.10));',
    '  n += 0.32 * vec2(sin(p.x * 17.0 - t * 2.20 + sin(p.y * 12.0 + t * 1.10)),',
    '                   cos(p.y * 14.0 + t * 1.80 + sin(p.x * 10.0 - t * 0.90)));',
    '  n += 0.14 * vec2(sin(p.x * 33.0 + t * 3.60), cos(p.y * 29.0 - t * 3.10));',
    '  n += 0.07 * vec2(sin(p.x * 61.0 - t * 5.20), cos(p.y * 53.0 + t * 4.70));',
    '  return n;',
    '}',
    '',
    'vec3 bgCol(vec2 uv){',
    '  return texture2D(uTex, clamp(uv, vec2(0.0), vec2(1.0))).rgb;',
    '}',
    '',
    'void main(void){',
    '  vec2  uv     = vUv;',
    '  float aspect = uRes.x / max(uRes.y, 1.0);',
    '',
    '  /* ---- glass geometry (aspect-corrected space, 1 unit = 1px of height) ---- */',
    '  vec2 halfC = ((uRect.xy + uRect.zw) * 0.5 - 0.5) * vec2(aspect, 1.0);',
    '  vec2 halfB = vec2((uRect.z - uRect.x) * 0.5 * aspect, (uRect.w - uRect.y) * 0.5);',
    '  vec2 p     = (uv - 0.5) * vec2(aspect, 1.0) - halfC;',
    '  float rad  = min(uRadius * aspect, 0.50 * min(halfB.x, halfB.y));',
    '  float d    = sdRoundRect(p, halfB, rad);',
    '  float px   = 2.0 / uRes.y;',
    '  float mask = 1.0 - smoothstep(-px * 0.6, px * 1.4, d);',
    '  float inner = max(-d, 0.0);',
    '  float rim   = exp(-inner * 12.0);',
    '',
    '  if (mask < 0.004){',
    '    gl_FragColor = vec4(bgCol(uv), max(mask, uMode));',
    '    return;',
    '  }',
    '',
    '  /* ---- refraction: convex lens zoom + gel ripple + rim bend ---- */',
    '  vec2 n   = ripple(uv * 3.2);',
    '  vec2 cuv = uv - 0.5;',
    '  float zoom = 1.0 - 0.14 * (1.0 - rim);',
    '  vec2 refrUv = 0.5 + cuv * zoom',
    '            + n  * (0.012 + 0.030 * rim)',
    '            + cuv * 0.018 * rim;',
    '',
    '  /* ---- chromatic aberration at the curved rim (RGB split) ---- */',
    '  float rm = pow(rim, 1.5);',
    '  vec2 ca = (n * 0.050 + cuv * 0.030) * rm;',
    '  vec3 col;',
    '  col.r = bgCol(refrUv + ca * 1.35).r;',
    '  col.g = bgCol(refrUv        ).g;',
    '  col.b = bgCol(refrUv - ca * 1.35).b;',
    '',
    '  /* ---- specular highlights: pointer-following + orbital key light ---- */',
    '  vec2 mp  = (uv - uMouse) * vec2(aspect, 1.0);',
    '  vec2 lr  = (uv - (0.5 + 0.36 * vec2(cos(uTime * 0.42), sin(uTime * 0.31)))) * vec2(aspect, 1.0);',
    '  float sp1 = exp(-dot(mp, mp) * 150.0);',
    '  float sp2 = exp(-dot(lr, lr) * 100.0);',
    '  float spec = sp1 * 0.95 + sp2 * 0.30;',
    '  col += vec3(1.00, 0.98, 0.94) * spec * (0.72 + 0.28 * sin(uTime * 1.9));',
    '',
    '  /* ---- sweeping sheen + fresnel rim light ---- */',
    '  float sheen = pow(0.5 + 0.5 * sin((uv.y - uv.x) * 3.0 + uTime * 0.8), 24.0) * 0.10;',
    '  col += vec3(1.0, 1.0, 0.98) * sheen;',
    '  vec3 frn = mix(vec3(1.00), vec3(0.60, 0.85, 1.00), rim);',
    '  col += frn * pow(rim, 1.5) * 0.40;',
    '',
    '  /* ---- glass tint, transmission, inner haze, edge thickness ---- */',
    '  col = col * 0.90 + vec3(0.05, 0.07, 0.10) * 0.35;',
    '  float cen = smoothstep(1.40, 0.00, length(p / halfB));',
    '  col = mix(col, col * 0.90 + vec3(0.06, 0.08, 0.11), cen * 0.26);',
    '  col *= 1.0 - 0.32 * rim * rim;',
    '',
    '  vec3 outCol = mix(bgCol(uv), col, mask);',
    '  gl_FragColor = vec4(outCol, max(mask, uMode));',
    '}'
].join('\n');
function compileShader(gl, type, src) {
    var sh = gl.createShader(type);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      var err = gl.getShaderInfoLog(sh) || 'unknown shader error';
      gl.deleteShader(sh);
      throw new Error('LiquidGlass shader: ' + err);
    }
    return sh;
  }

  function buildProgram(gl) {
    var vs = compileShader(gl, gl.VERTEX_SHADER, VERT_SRC);
    var fs = compileShader(gl, gl.FRAGMENT_SHADER, FRAG_SRC);
    var pr = gl.createProgram();
    gl.attachShader(pr, vs);
    gl.attachShader(pr, fs);
    gl.linkProgram(pr);
    if (!gl.getProgramParameter(pr, gl.LINK_STATUS)) {
      throw new Error('LiquidGlass link: ' + gl.getProgramInfoLog(pr));
    }
    gl.useProgram(pr);
    return pr;
  }

  /* The colourful "background image beneath" the glass — built procedurally so
     the demo works fully offline. Swap in any <img>/<canvas> via opts.texture. */
  function colourfulTexture(gl) {
    var c = document.createElement('canvas');
    c.width = 512; c.height = 512;
    var g = c.getContext('2d');

    var lg = g.createLinearGradient(0, 0, 512, 512);
    lg.addColorStop(0, '#0a0e24');
    lg.addColorStop(0.55, '#0f1736');
    lg.addColorStop(1, '#070a18');
    g.fillStyle = lg;
    g.fillRect(0, 0, 512, 512);

    var blobs = [
      ['rgba(255,47,180,0.85)', 118, 152, 150],
      ['rgba(0,198,255,0.80)',  400, 168, 165],
      ['rgba(123,47,255,0.85)', 268, 428, 185],
      ['rgba(34,211,167,0.75)',  88, 396, 118],
      ['rgba(255,181,47,0.78)', 428, 402, 108],
      ['rgba(91,124,255,0.80)', 330, 258, 132],
      ['rgba(255,90,120,0.70)', 210,  92,  96]
    ];
    var i, b;
    for (i = 0; i < blobs.length; i++) {
      b = blobs[i];
      var rg = g.createRadialGradient(b[1], b[2], 4, b[1], b[2], b[3]);
      rg.addColorStop(0, b[0]);
      rg.addColorStop(1, 'rgba(0,0,0,0)');
      g.fillStyle = rg;
      g.beginPath();
      g.arc(b[1], b[2], b[3], 0, 6.2832);
      g.fill();
    }

    g.globalAlpha = 0.10;
    g.strokeStyle = '#ffffff';
    g.lineWidth = 60;
    for (var s = 0; s < 3; s++) {
      var ang = -Math.PI / 4 + s * 0.18;
      var cc = Math.cos(ang), ss = Math.sin(ang);
      g.beginPath();
      g.moveTo(256 - cc * 420, 256 - ss * 420);
      g.lineTo(256 + cc * 420, 256 + ss * 420);
      g.stroke();
    }
    g.globalAlpha = 1;

    var tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, c);
    return tex;
  }

  function loadExternalTexture(gl, source) {
    var tex = gl.createTexture();
    var upload = function (img) {
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
    };
    if (source.complete || source.naturalWidth) upload(source);
    else source.addEventListener('load', function () { upload(source); });
    return tex;
  }
function init(canvas, opts) {
    if (!canvas) return null;
    if (canvas.__mesonGlassReady) return canvas.__mesonGlassReady;
    opts = opts || {};

    var attribs = { alpha: true, antialias: true, premultipliedAlpha: false,
                    preserveDrawingBuffer: true, depth: false, stencil: false };
    var gl = canvas.getContext('webgl', attribs) ||
             canvas.getContext('experimental-webgl', attribs);
    if (!gl) {
      canvas.dataset.glass = 'unsupported';
      return null;
    }

    var pr = buildProgram(gl);
    var aPos = gl.getAttribLocation(pr, 'aPos');
    var u = {};
    ['uRes', 'uTime', 'uMouse', 'uTex', 'uRect', 'uRadius', 'uMode']
      .forEach(function (n) { u[n] = gl.getUniformLocation(pr, n); });

    var buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

    var tex = opts.texture ? loadExternalTexture(gl, opts.texture) : colourfulTexture(gl);

    var DPR = Math.min((global.devicePixelRatio || 1), 2);
    var mx = 0.5, my = 0.5, tmx = 0.5, tmy = 0.5;
    var t0 = (global.performance && performance.now) ? performance.now() : Date.now();
    var slow = !!(global.matchMedia && global.matchMedia('(prefers-reduced-motion: reduce)').matches);
    var running = true, rafId = 0;

    function resize() {
      var w = canvas.clientWidth || 1, h = canvas.clientHeight || 1;
      var nw = Math.max(1, Math.round(w * DPR));
      var nh = Math.max(1, Math.round(h * DPR));
      if (canvas.width !== nw) canvas.width = nw;
      if (canvas.height !== nh) canvas.height = nh;
      gl.viewport(0, 0, nw, nh);
    }
    resize();
    if (global.ResizeObserver) {
      try { new ResizeObserver(resize).observe(canvas); } catch (e) { /* noop */ }
    }

    function onPointer(e) {
      var br = canvas.getBoundingClientRect();
      if (!br.width || !br.height) return;
      tmx = Math.min(1, Math.max(0, (e.clientX - br.left) / br.width));
      tmy = Math.min(1, Math.max(0, (e.clientY - br.top) / br.height));
    }
    global.addEventListener('pointermove', onPointer, { passive: true });
    global.addEventListener('pointerdown', onPointer, { passive: true });
    global.addEventListener('touchmove', onPointer, { passive: true });

    var rect = opts.rect || [0, 0, 1, 1];
    var radiusPx = (typeof opts.radiusPx === 'function') ? opts.radiusPx
                  : function () { return opts.radiusPx || 24; };
    var mode = opts.solidBg ? 1 : 0;

    function frame() {
      if (!running) return;
      rafId = global.requestAnimationFrame(frame);
      var now = (global.performance && performance.now) ? performance.now() : Date.now();
      var t = ((now - t0) / 1000) * (slow ? 0.25 : 1);
      mx += (tmx - mx) * 0.055;
      my += (tmy - my) * 0.055;
      resize();
      gl.uniform2f(u.uRes, canvas.width, canvas.height);
      gl.uniform1f(u.uTime, t);
      gl.uniform2f(u.uMouse, mx, my);
      gl.uniform4f(u.uRect, rect[0], rect[1], rect[2], rect[3]);
      gl.uniform1f(u.uRadius, radiusPx() / (canvas.clientHeight || 1));
      gl.uniform1f(u.uMode, mode);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.uniform1i(u.uTex, 0);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    rafId = global.requestAnimationFrame(frame);

    canvas.dataset.glass = 'ok';

    var api = {
      canvas: canvas,
      gl: gl,
      stop: function () {
        running = false;
        global.cancelAnimationFrame(rafId);
        global.removeEventListener('pointermove', onPointer);
        global.removeEventListener('pointerdown', onPointer);
        global.removeEventListener('touchmove', onPointer);
      },
      setRect: function (r) { rect = r; },
      setMouse: function (m) { mx = tmx = m[0]; my = tmy = m[1]; }
    };
    canvas.__mesonGlassReady = api;
    return api;
  }

  global.MesonLiquidGlass = { init: init, version: '1.0.0' };
})(typeof window !== 'undefined' ? window : this);
