/**
 * The one variable the whole page shares: what the orb is doing right now.
 *
 * In the app this comes from `AudioLevelMeter` and the transcriber's state. Here
 * scroll position plays that part, so the page reads as one continuous dictation
 * rather than a stack of sections. Kept as a plain mutable singleton because the
 * render loop reads it sixty times a second and React state would be the wrong
 * instrument for that.
 */
export type Stage = {
  /** 0 = silence, ~1 = speaking loudly. */
  level: number;
  /** 0 = `OrbConfig.quiet`, 1 = fully materialised. */
  presence: number;
  /** Whether the voice glow is lit. */
  active: boolean;
  /** How much the cloud recedes behind foreground text, as the app does at 0.6. */
  dim: number;
};

const stage: Stage = { level: 0, presence: 1, active: false, dim: 0 };

export function readStage(): Stage {
  return stage;
}

export function writeStage(next: Partial<Stage>): void {
  Object.assign(stage, next);
}

/**
 * A stand-in for a speech envelope: three detuned sines plus a slow gate, which
 * gives the uneven bursts of a real sentence rather than a hum. Deterministic, so
 * it never fights the smoothing in the render loop.
 */
export function speechEnvelope(t: number): number {
  const gate = 0.5 + 0.5 * Math.sin(t * 1.7);
  const burst =
    0.55 +
    0.28 * Math.sin(t * 7.3) +
    0.17 * Math.sin(t * 11.9 + 1.3) +
    0.1 * Math.sin(t * 19.1 + 2.7);
  return Math.max(0, Math.min(1.1, burst * (0.45 + 0.55 * gate)));
}
