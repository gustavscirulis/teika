/**
 * The particle cloud from the app, ported to WebGL2.
 *
 * `teika/Particles.metal` is reproduced line for line below; the per-particle
 * simulation that lives on the CPU in `VoiceOrbView.Coordinator.draw` is moved
 * into the vertex shader here, because uploading 3000 positions per frame from
 * JavaScript is the one thing that would make this stutter on a phone. The maths
 * is unchanged — the same seeded particles, the same drift, swirl, twinkle,
 * breath and edge fade, the same additive blend and the same two-pass draw with
 * the glow quad underneath.
 */
import { QUIET_ORB, WEB_ORB, blendOrb, type OrbConfig } from './orbConfig';

const PARTICLE_COUNT = 3000;
const FADE_BAND = 250;
/** `Coordinator.presenceTau`. */
const PRESENCE_TAU = 0.6;

/** `SplitMix64`, so the cloud is seeded identically to the app's. */
class SplitMix64 {
  private state: bigint;
  private static readonly MASK = (1n << 64n) - 1n;

  constructor(seed: bigint) {
    this.state = seed & SplitMix64.MASK;
  }

  private next(): bigint {
    this.state = (this.state + 0x9e3779b97f4a7c15n) & SplitMix64.MASK;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & SplitMix64.MASK;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & SplitMix64.MASK;
    return (z ^ (z >> 31n)) & SplitMix64.MASK;
  }

  float01(): number {
    return Number(this.next() >> 40n) / (1 << 24);
  }

  range(a: number, b: number): number {
    return a + (b - a) * this.float01();
  }
}

const PARTICLE_VERTEX = `#version 300 es
precision highp float;

// Static per-particle seeds, packed four floats to an attribute.
layout(location = 0) in vec4 aAngleRadiusBigSize;   // homeAngle, radiusRand, bigPick, sizeRand
layout(location = 1) in vec4 aBrightDrift;          // brightPick, brightRand, driftSpeedX, driftSpeedY
layout(location = 2) in vec4 aPhaseAmp;             // driftPhaseX, driftPhaseY, driftAmpX, driftAmpY
layout(location = 3) in vec4 aAngTwinkleIndex;      // angSpeed, twinklePhase, twinkleSpeed, index

uniform float uClk;          // motionClock, advanced by dt * (1 + level * voiceSpeed)
uniform float uTime;         // wall clock, drives twinkle
uniform float uLevel;
uniform float uAspect;
uniform vec4  uCloud;        // coreTightness, cloudScale, sizeScale, bigFraction
uniform vec4  uMotion;       // driftAmount, driftSpeed, swirlSpeed, twinkleAmount
uniform vec4  uVoice;        // breathGain, brightnessGain, idleBrightness, sizeExpand
uniform float uActiveCount;

out float vBrightness;

float mixf(float a, float b, float t) { return a + (b - a) * t; }

void main() {
  float homeAngle  = aAngleRadiusBigSize.x;
  float radiusRand = aAngleRadiusBigSize.y;
  float bigPick    = aAngleRadiusBigSize.z;
  float sizeRand   = aAngleRadiusBigSize.w;
  float brightPick = aBrightDrift.x;
  float brightRand = aBrightDrift.y;
  float index      = aAngTwinkleIndex.w;

  float r01     = pow(radiusRand, uCloud.x);
  float anchorR = r01 * uCloud.y;
  float ang     = homeAngle + uClk * aAngTwinkleIndex.x * uMotion.z;

  float ax = cos(ang) * anchorR;
  float ay = sin(ang) * anchorR;
  float dx = sin(uClk * aBrightDrift.z * uMotion.y + aPhaseAmp.x) * aPhaseAmp.z * uMotion.x;
  float dy = cos(uClk * aBrightDrift.w * uMotion.y + aPhaseAmp.y) * aPhaseAmp.w * uMotion.x;

  float breath = uLevel * uVoice.x * r01;
  vec2 pos = vec2(ax + dx + cos(ang) * breath, ay + dy + sin(ang) * breath);

  // particle_vertex: keep the cloud circular whichever way the viewport runs.
  if (uAspect < 1.0) {
    pos.y *= uAspect;
  } else {
    pos.x /= max(uAspect, 0.0001);
  }

  bool  big      = bigPick < uCloud.w;
  float baseSize = (big ? mixf(16.0, 30.0, sizeRand) : mixf(3.0, 9.0, sizeRand)) * uCloud.z;

  float baseBright;
  if (big) {
    baseBright = mixf(0.10, 0.22, brightRand);
  } else if (brightPick < 0.08) {
    baseBright = mixf(0.8, 1.0, brightRand);
  } else {
    baseBright = mixf(0.30, 0.75, brightRand);
  }

  float twinkle = (1.0 - uMotion.w)
    + uMotion.w * (0.5 + 0.5 * sin(uTime * aAngTwinkleIndex.z + aAngTwinkleIndex.y));
  float edgeFade = clamp((uActiveCount - index) / ${FADE_BAND}.0, 0.0, 1.0);

  vBrightness = min(baseBright * twinkle * uVoice.z + uLevel * uVoice.y, 1.8) * edgeFade;

  gl_Position = vec4(pos, 0.0, 1.0);
  gl_PointSize = clamp(baseSize * (1.0 + uLevel * uVoice.w), 1.0, 64.0);
}`;

const PARTICLE_FRAGMENT = `#version 300 es
precision highp float;

in float vBrightness;
uniform vec3 uColor;
uniform float uFalloff;
out vec4 fragColor;

void main() {
  vec2 uv = gl_PointCoord * 2.0 - 1.0;
  float r2 = dot(uv, uv);
  if (r2 > 1.0) discard;
  float a = exp(-r2 * uFalloff) * vBrightness;
  fragColor = vec4(uColor * a, a);
}`;

const GLOW_VERTEX = `#version 300 es
precision highp float;

uniform float uAspect;
out vec2 vDesign;

void main() {
  // Same gl_VertexID trick as glow_vertex: a triangle strip covering clip space.
  vec2 ndc = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1)) * 2.0 - 1.0;
  float aspect = max(uAspect, 0.0001);
  vDesign = aspect < 1.0 ? vec2(ndc.x, ndc.y / aspect) : vec2(ndc.x * aspect, ndc.y);
  gl_Position = vec4(ndc, 0.0, 1.0);
}`;

const GLOW_FRAGMENT = `#version 300 es
precision highp float;

in vec2 vDesign;
uniform vec4 uParams;   // intensity, radius, falloff, haloMix
uniform vec4 uParams2;  // centreX, centreY, aspect, ditherScale
uniform vec3 uColor;
out vec4 fragColor;

// glow_dither — a cheap hash, so the wide gradient does not band on an 8-bit target.
float glowDither(vec2 p) {
  uvec2 q = uvec2(p);
  uint h = (q.x * 73856093u) ^ (q.y * 19349663u);
  h ^= h >> 13; h *= 0x5BD1E995u; h ^= h >> 15;
  return float(h & 0xFFFFu) / 65535.0 - 0.5;
}

void main() {
  float radius = max(uParams.y, 0.001);
  vec2 d = vDesign - uParams2.xy;
  float rn2 = dot(d, d) / (radius * radius);
  float core = exp(-rn2 * uParams.z);
  float halo = exp(-rn2 * uParams.z * 0.16);
  float a = uParams.x * mix(core, halo, uParams.w);
  a = max(a + glowDither(gl_FragCoord.xy) * uParams2.w, 0.0);
  fragColor = vec4(uColor * a, a);
}`;

function compile(gl: WebGL2RenderingContext, type: number, source: string) {
  const shader = gl.createShader(type)!;
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const log = gl.getShaderInfoLog(shader);
    gl.deleteShader(shader);
    throw new Error(`orb shader: ${log}`);
  }
  return shader;
}

function link(gl: WebGL2RenderingContext, vs: string, fs: string) {
  const program = gl.createProgram()!;
  gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, vs));
  gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(`orb program: ${gl.getProgramInfoLog(program)}`);
  }
  return program;
}

export type OrbDriver = {
  /** 0 = silent, ~1 = speaking. Smoothed with the app's attack/decay. */
  level: number;
  /** 0 = `OrbConfig.quiet`, 1 = the shipped config. */
  presence: number;
  /** Drives the glow's fade in and out, exactly as `isActive` does in the app. */
  active: boolean;
};

export type OrbHandle = { destroy(): void };

/**
 * Mounts the cloud on `canvas` and drives it from whatever `read()` returns each
 * frame. Returns null when WebGL2 is unavailable, so the caller can leave its
 * static fallback in place.
 */
export function mountOrb(
  canvas: HTMLCanvasElement,
  read: () => OrbDriver,
  options: { staticFrame?: boolean } = {},
): OrbHandle | null {
  const gl = canvas.getContext('webgl2', {
    alpha: false,
    antialias: false,
    depth: false,
    stencil: false,
    powerPreference: 'low-power',
  });
  if (!gl) return null;

  let particleProgram: WebGLProgram;
  let glowProgram: WebGLProgram;
  try {
    particleProgram = link(gl, PARTICLE_VERTEX, PARTICLE_FRAGMENT);
    glowProgram = link(gl, GLOW_VERTEX, GLOW_FRAGMENT);
  } catch {
    return null;
  }

  // seedParticles(), with the app's seed so the layout matches.
  const rng = new SplitMix64(0xcafebabedeadbeefn);
  const seeds = new Float32Array(PARTICLE_COUNT * 16);
  for (let i = 0; i < PARTICLE_COUNT; i++) {
    const o = i * 16;
    seeds[o + 0] = rng.range(0, 2 * Math.PI); // homeAngle
    seeds[o + 1] = rng.float01(); // radiusRand
    seeds[o + 2] = rng.float01(); // bigPick
    seeds[o + 3] = rng.float01(); // sizeRand
    seeds[o + 4] = rng.float01(); // brightPick
    seeds[o + 5] = rng.float01(); // brightRand
    seeds[o + 6] = rng.range(0.08, 0.7); // driftSpeedX
    seeds[o + 7] = rng.range(0.08, 0.7); // driftSpeedY
    seeds[o + 8] = rng.range(0, 2 * Math.PI); // driftPhaseX
    seeds[o + 9] = rng.range(0, 2 * Math.PI); // driftPhaseY
    seeds[o + 10] = rng.range(0.05, 0.16); // driftAmpX
    seeds[o + 11] = rng.range(0.05, 0.16); // driftAmpY
    seeds[o + 12] = rng.range(-0.28, 0.28); // angSpeed
    seeds[o + 13] = rng.range(0, 2 * Math.PI); // twinklePhase
    seeds[o + 14] = rng.range(0.3, 1.2); // twinkleSpeed
    seeds[o + 15] = i; // index, for the edge fade
  }

  const vao = gl.createVertexArray()!;
  gl.bindVertexArray(vao);
  const buffer = gl.createBuffer()!;
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, seeds, gl.STATIC_DRAW);
  const stride = 16 * 4;
  for (let slot = 0; slot < 4; slot++) {
    gl.enableVertexAttribArray(slot);
    gl.vertexAttribPointer(slot, 4, gl.FLOAT, false, stride, slot * 4 * 4);
  }
  gl.bindVertexArray(null);

  const glowVao = gl.createVertexArray()!;

  const pu = {
    clk: gl.getUniformLocation(particleProgram, 'uClk'),
    time: gl.getUniformLocation(particleProgram, 'uTime'),
    level: gl.getUniformLocation(particleProgram, 'uLevel'),
    aspect: gl.getUniformLocation(particleProgram, 'uAspect'),
    cloud: gl.getUniformLocation(particleProgram, 'uCloud'),
    motion: gl.getUniformLocation(particleProgram, 'uMotion'),
    voice: gl.getUniformLocation(particleProgram, 'uVoice'),
    activeCount: gl.getUniformLocation(particleProgram, 'uActiveCount'),
    color: gl.getUniformLocation(particleProgram, 'uColor'),
    falloff: gl.getUniformLocation(particleProgram, 'uFalloff'),
  };
  const gu = {
    aspect: gl.getUniformLocation(glowProgram, 'uAspect'),
    params: gl.getUniformLocation(glowProgram, 'uParams'),
    params2: gl.getUniformLocation(glowProgram, 'uParams2'),
    color: gl.getUniformLocation(glowProgram, 'uColor'),
  };

  gl.disable(gl.DEPTH_TEST);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE); // additive, as in the Metal pipeline descriptor
  gl.clearColor(0.04, 0.04, 0.05, 1);

  let width = 0;
  let height = 0;
  function resize() {
    // Cap the device pixel ratio: 3000 additive point sprites at DPR 3 is a lot
    // of overdraw for a background, and the cloud is soft enough not to show it.
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
    const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
    if (w === width && h === height) return;
    width = w;
    height = h;
    canvas.width = w;
    canvas.height = h;
    gl!.viewport(0, 0, w, h);
  }

  let smoothedLevel = 0;
  let smoothedPresence: number | null = null;
  let glowPresence = 0;
  let motionClock = 0;
  const start = performance.now() / 1000;
  let last = start;
  let raf = 0;
  let running = true;

  function frame(nowMs: number) {
    if (!running) return;
    const gl2 = gl!;
    resize();

    const now = nowMs / 1000;
    const dt = Math.min(now - last, 1 / 30);
    last = now;
    const t = now - start;

    const driver = read();

    const presence =
      smoothedPresence === null
        ? driver.presence
        : smoothedPresence +
          (driver.presence - smoothedPresence) * (1 - Math.exp(-dt / PRESENCE_TAU));
    smoothedPresence = presence;
    const cfg: OrbConfig = blendOrb(QUIET_ORB, WEB_ORB, presence);

    const rawTarget = Math.min(driver.level * cfg.levelGain, 1.5);
    const tau = rawTarget > smoothedLevel ? cfg.attack : cfg.decay;
    smoothedLevel += (rawTarget - smoothedLevel) * (1 - Math.exp(-dt / Math.max(tau, 0.001)));
    const level = smoothedLevel;

    const glowTarget = driver.active ? 1 : 0;
    glowPresence += (glowTarget - glowPresence) * (1 - Math.exp(-dt / Math.max(cfg.glowFade, 0.001)));
    if (glowTarget === 0 && glowPresence < 0.002) glowPresence = 0;

    motionClock += dt * (1 + level * cfg.voiceSpeed);

    const aspect = height > 0 ? width / height : 1;
    const activeCount = Math.min(1, cfg.density + level * cfg.voiceDensity) * PARTICLE_COUNT;
    const drawCount = Math.max(1, Math.min(PARTICLE_COUNT, Math.ceil(activeCount + FADE_BAND)));

    gl2.clear(gl2.COLOR_BUFFER_BIT);

    const glowT = Math.pow(Math.min(Math.max(level, 0), 1), cfg.glowCurve);
    const glowIntensity =
      (cfg.glowQuietIntensity + (cfg.glowLoudIntensity - cfg.glowQuietIntensity) * glowT) *
      glowPresence;
    if (glowIntensity > 0.001) {
      gl2.useProgram(glowProgram);
      gl2.bindVertexArray(glowVao);
      gl2.uniform1f(gu.aspect, aspect);
      gl2.uniform4f(
        gu.params,
        glowIntensity,
        cfg.glowQuietRadius + (cfg.glowLoudRadius - cfg.glowQuietRadius) * glowT,
        cfg.glowFalloff,
        cfg.glowHaloMix,
      );
      gl2.uniform4f(gu.params2, 0, 0, aspect, 1 / 255);
      gl2.uniform3f(gu.color, 1, 1, 1);
      gl2.drawArrays(gl2.TRIANGLE_STRIP, 0, 4);
      gl2.bindVertexArray(null);
    }

    gl2.useProgram(particleProgram);
    gl2.bindVertexArray(vao);
    gl2.uniform1f(pu.clk, motionClock);
    gl2.uniform1f(pu.time, t);
    gl2.uniform1f(pu.level, level);
    gl2.uniform1f(pu.aspect, aspect);
    gl2.uniform4f(pu.cloud, cfg.coreTightness, cfg.cloudScale, cfg.sizeScale, cfg.bigFraction);
    gl2.uniform4f(pu.motion, cfg.driftAmount, cfg.driftSpeed, cfg.swirlSpeed, cfg.twinkleAmount);
    gl2.uniform4f(pu.voice, cfg.breathGain, cfg.brightnessGain, cfg.idleBrightness, cfg.sizeExpand);
    gl2.uniform1f(pu.activeCount, activeCount);
    gl2.uniform3f(pu.color, 1, 1, 1);
    gl2.uniform1f(pu.falloff, cfg.falloff);
    gl2.drawArrays(gl2.POINTS, 0, drawCount);
    gl2.bindVertexArray(null);

    // Reduced motion gets one composed frame: the cloud is present, it just
    // does not move. Re-rendering only on resize keeps that true.
    if (!options.staticFrame) raf = requestAnimationFrame(frame);
  }

  function onResize() {
    if (options.staticFrame) {
      resize();
      frame(performance.now());
    }
  }

  // Submitting GPU work for an off-screen canvas is pure battery burn, the same
  // reasoning as `OrbMTKView.updateActivity`.
  function onVisibility() {
    if (options.staticFrame) return;
    if (document.hidden) {
      running = false;
      cancelAnimationFrame(raf);
    } else if (!running) {
      running = true;
      last = performance.now() / 1000;
      raf = requestAnimationFrame(frame);
    }
  }

  window.addEventListener('resize', onResize, { passive: true });
  document.addEventListener('visibilitychange', onVisibility);
  raf = requestAnimationFrame(frame);

  return {
    destroy() {
      running = false;
      cancelAnimationFrame(raf);
      window.removeEventListener('resize', onResize);
      document.removeEventListener('visibilitychange', onVisibility);
      gl.deleteBuffer(buffer);
      gl.deleteVertexArray(vao);
      gl.deleteVertexArray(glowVao);
      gl.deleteProgram(particleProgram);
      gl.deleteProgram(glowProgram);
    },
  };
}
