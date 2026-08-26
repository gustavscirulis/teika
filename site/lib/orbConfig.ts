/**
 * A direct transcription of `teika/OrbConfig.swift`. The shipped iOS defaults are
 * the source of truth; nothing here is retuned for the web, so the cloud on this
 * page is the same cloud that is in the app.
 */
export type OrbConfig = {
  density: number;
  coreTightness: number;
  cloudScale: number;
  sizeScale: number;
  bigFraction: number;
  falloff: number;
  idleBrightness: number;

  driftAmount: number;
  driftSpeed: number;
  swirlSpeed: number;
  twinkleAmount: number;

  levelGain: number;
  voiceDensity: number;
  voiceSpeed: number;
  breathGain: number;
  brightnessGain: number;
  sizeExpand: number;
  attack: number;
  decay: number;

  glowQuietIntensity: number;
  glowLoudIntensity: number;
  glowQuietRadius: number;
  glowLoudRadius: number;
  glowCurve: number;
  glowFalloff: number;
  glowHaloMix: number;
  glowFade: number;
};

export const DEFAULT_ORB: OrbConfig = {
  density: 0.7,
  coreTightness: 2.6,
  cloudScale: 1.5,
  sizeScale: 0.6,
  bigFraction: 0.2,
  falloff: 2.0,
  idleBrightness: 1.1,

  driftAmount: 4.15,
  driftSpeed: 0.25,
  swirlSpeed: 0.6,
  twinkleAmount: 0.35,

  levelGain: 1.05,
  voiceDensity: 0.5,
  voiceSpeed: 2.45,
  breathGain: 0.64,
  brightnessGain: 0.2,
  sizeExpand: 0.5,
  attack: 0.1,
  decay: 0.47,

  glowQuietIntensity: 0.08,
  glowLoudIntensity: 0.36,
  glowQuietRadius: 0.5,
  glowLoudRadius: 1.35,
  glowCurve: 0.7,
  glowFalloff: 2.5,
  glowHaloMix: 0.45,
  glowFade: 0.45,
};

/**
 * The web's own attenuation. On a phone the cloud *is* the screen and can carry
 * full brightness; behind a page of text it becomes a starfield competing with
 * the words. Same simulation, turned down: dimmer, sparser, less twinkle. These
 * are the only three numbers on this site that deliberately differ from the app.
 */
export const WEB_ORB: OrbConfig = {
  ...DEFAULT_ORB,
  idleBrightness: 0.62,
  density: 0.62,
  twinkleAmount: 0.2,
};

/** `OrbConfig.quiet` — the orb before the speech model exists. */
export const QUIET_ORB: OrbConfig = {
  ...DEFAULT_ORB,
  density: 0.3,
  coreTightness: 2.5,
  idleBrightness: 0.6,
};

/** `OrbConfig.blend` — linear interpolation across every numeric field. */
export function blendOrb(a: OrbConfig, b: OrbConfig, t: number): OrbConfig {
  const out = { ...b } as Record<string, number>;
  const from = a as unknown as Record<string, number>;
  const to = b as unknown as Record<string, number>;
  for (const key of Object.keys(to)) {
    out[key] = from[key] + (to[key] - from[key]) * t;
  }
  return out as unknown as OrbConfig;
}
