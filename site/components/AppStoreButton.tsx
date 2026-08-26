'use client';

import { motion, useReducedMotion } from 'framer-motion';
import { APP_STORE_URL } from '@/lib/site';

/**
 * The app's own `downloadButton`, rebuilt for the web: a glass capsule with a
 * rim, no fill colour, and a highlight that lifts on hover. Nothing here is a
 * generic button component — the app has exactly one control style and this is it.
 *
 * The lift and the press are Framer Motion rather than CSS transitions, so the
 * press interrupts the lift mid-flight instead of queueing behind it, and both
 * settle on a spring rather than a fixed duration. Colour and shadow stay in CSS,
 * where they cost nothing.
 */
export default function AppStoreButton() {
  const reduced = useReducedMotion();

  return (
    <motion.a
      className="capsule"
      href={APP_STORE_URL}
      whileHover={reduced ? undefined : { y: -1, scale: 1.01 }}
      whileTap={reduced ? undefined : { y: 1, scale: 0.99 }}
      // Deliberately small: 1px and 1% is enough to register as a lift without
      // the button appearing to jump at the cursor. Stiff and well damped so it
      // arrives quickly and does not wobble.
      transition={{ type: 'spring', stiffness: 460, damping: 30, mass: 0.6 }}
    >
      <svg viewBox="0 0 16 20" aria-hidden="true" focusable="false">
        <path
          fill="currentColor"
          d="M13.24 10.63c-.02-2.2 1.8-3.26 1.88-3.31-1.02-1.5-2.61-1.7-3.18-1.72-1.35-.14-2.64.8-3.33.8-.69 0-1.75-.78-2.87-.76-1.48.02-2.84.86-3.6 2.18-1.53 2.66-.39 6.6 1.1 8.76.73 1.06 1.6 2.25 2.74 2.2 1.1-.04 1.52-.71 2.85-.71 1.33 0 1.7.71 2.87.69 1.19-.02 1.94-1.08 2.66-2.14.84-1.23 1.19-2.42 1.2-2.48-.03-.01-2.3-.88-2.32-3.5zM11.06 3.9c.6-.74 1.01-1.75.9-2.77-.87.04-1.93.58-2.56 1.3-.56.65-1.05 1.68-.92 2.67.97.08 1.96-.5 2.58-1.2z"
        />
      </svg>
      <span>Download on the App Store</span>
    </motion.a>
  );
}
