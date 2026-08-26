'use client';

import { useEffect } from 'react';
import { writeStage, type Stage } from '@/lib/stage';

type Keyframe = Omit<Stage, 'active'> & { active: boolean };

/**
 * Scroll is the audio here. The cloud is alive in the first viewport — expanded,
 * lit, breathing on the app's own voice envelope — and settles as the page is
 * read, so the energy is spent where there is nothing to read and withdrawn
 * where there is.
 */
const KEYFRAMES: Record<string, { from: Keyframe; to: Keyframe }> = {
  hero: {
    from: { level: 0.85, presence: 1, dim: 0, active: true },
    to: { level: 0.4, presence: 1, dim: 0.12, active: true },
  },
  steps: {
    from: { level: 0.12, presence: 1, dim: 0.3, active: false },
    to: { level: 0, presence: 1, dim: 0.4, active: false },
  },
  model: {
    from: { level: 0, presence: 1, dim: 0.4, active: false },
    to: { level: 0, presence: 1, dim: 0.34, active: false },
  },
  close: {
    from: { level: 0, presence: 1, dim: 0.24, active: false },
    to: { level: 0, presence: 1, dim: 0.12, active: false },
  },
};

const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

export default function StageDriver() {
  useEffect(() => {
    let sections: { key: string; top: number; height: number }[] = [];
    let frame = 0;

    function measure() {
      sections = Array.from(document.querySelectorAll<HTMLElement>('[data-stage]'))
        .map((el) => ({
          key: el.dataset.stage!,
          top: el.offsetTop,
          height: el.offsetHeight || 1,
        }))
        .filter((s) => KEYFRAMES[s.key]);
      apply();
    }

    function apply() {
      if (!sections.length) return;
      // Read the stage at the point the eye actually sits, a little above centre.
      const probe = window.scrollY + window.innerHeight * 0.45;

      let current = sections[0];
      for (const section of sections) {
        if (probe >= section.top) current = section;
      }
      const progress = Math.min(1, Math.max(0, (probe - current.top) / current.height));
      const { from, to } = KEYFRAMES[current.key];

      writeStage({
        level: lerp(from.level, to.level, progress),
        presence: lerp(from.presence, to.presence, progress),
        dim: lerp(from.dim, to.dim, progress),
        active: progress < 0.5 ? from.active : to.active,
      });

      document.documentElement.style.setProperty(
        '--orb-dim',
        lerp(from.dim, to.dim, progress).toFixed(3),
      );
    }

    function onScroll() {
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        apply();
      });
    }

    measure();
    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', measure, { passive: true });
    // Late font or image layout shifts would otherwise leave the offsets stale.
    const settle = window.setTimeout(measure, 500);

    return () => {
      window.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', measure);
      window.clearTimeout(settle);
      cancelAnimationFrame(frame);
    };
  }, []);

  return null;
}
