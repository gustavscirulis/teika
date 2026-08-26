'use client';

import { useEffect, useRef, useState } from 'react';
import { mountOrb } from '@/lib/orb';
import { readStage, speechEnvelope } from '@/lib/stage';

/**
 * The cloud, fixed behind the whole document. It is decorative — every claim on
 * the page is carried by text — so it is hidden from assistive technology and
 * degrades to a plain radial glow when WebGL2 is missing.
 */
export default function Orb() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
    const start = performance.now() / 1000;

    const handle = mountOrb(
      canvas,
      () => {
        const stage = readStage();
        const t = performance.now() / 1000 - start;
        return {
          // `level` is a target the loop smooths with the app's attack/decay, so
          // the envelope can be as jagged as speech actually is.
          level: stage.level > 0 ? stage.level * speechEnvelope(t) : 0,
          presence: stage.presence,
          active: stage.active,
        };
      },
      { staticFrame: reduced.matches },
    );

    if (!handle) {
      setFailed(true);
      return;
    }
    return () => handle.destroy();
  }, []);

  if (failed) return <div className="orb-fallback" aria-hidden="true" />;

  return <canvas ref={canvasRef} className="orb" aria-hidden="true" />;
}
