# Teika site

Marketing page, Support page and Privacy Policy for Teika. Next.js App Router,
statically exported, no server.

From the repo root, `run.sh` drives this as well as the app:

```bash
./run.sh site            # dev server with hot reload, opens a browser
./run.sh site build      # static export into site/out
./run.sh site preview    # export, then serve it exactly as it will ship
```

`preview` is the one that matters before a deploy — it serves the real static
output rather than the dev server, so trailing slashes, `_next/` paths and the
Open Graph image are all exercised the way GitHub Pages will exercise them.

Or directly, from this directory:

```bash
npm install
npm run dev      # http://localhost:3000
npm run build    # static site in out/
npm run lint     # tsc --noEmit
```

## Production URL

The canonical production domain is `https://teika.app`; `app/layout.tsx`, the
in-app Support and Privacy links, and the App Store submission metadata use it.

Nothing else on the site is a placeholder. Every number, capability and absence
is checked against the app source or the model card — see `../PRODUCT.md`,
"Evidence on Hand", for what may and may not be claimed here.

## Deploying

Vercel can serve the static export using `vercel.json`. The public repository
can also publish `out/` directly with GitHub Pages.

For a **project page** at `https://<user>.github.io/teika/`, the site has to
know it is served from a subdirectory:

```bash
NEXT_PUBLIC_BASE_PATH=/teika npm run build
```

For a **user page** or a **custom domain**, build without that variable.

Either way, publish `out/` and add a `.nojekyll` file at its root, or GitHub will
refuse to serve the `_next` directory:

```bash
touch out/.nojekyll
```

The two URLs App Store Connect requires then exist:

- Privacy Policy URL → `…/privacy/`
- Support URL → `…/support/`

Both are static HTML with no JavaScript requirement for their content.

## How it is put together

The page is one dictation, scrolled — the app's own state machine as the spine.
`components/StageDriver.tsx` maps scroll position onto the two variables the app
drives from audio and model loading, and `components/Orb.tsx` renders them.

- `lib/orb.ts` — the particle cloud from `teika/Particles.metal`, ported to
  WebGL2. Same 3000 particles, same SplitMix64 seed, same drift, swirl, twinkle,
  breath, edge fade, additive blend and glow pass. The per-particle simulation
  moved from the CPU into the vertex shader, because uploading 3000 positions a
  frame from JavaScript is what would make it stutter on a phone.
- `lib/orbConfig.ts` — a transcription of `teika/OrbConfig.swift`. The shipped iOS
  values are the source of truth; nothing is retuned for the web.
- `components/Reveal.tsx` — the per-word blur-in from `teika/StreamingText.swift`,
  same 4px blur, same 20 ms stagger, same 0.3 s cap.
- `app/globals.css` — tokens carried over from `docs/privacy.html` unchanged.

Graceful degradation is real, not nominal: no WebGL2 gets a single soft radial
in `.orb-fallback`, `prefers-reduced-motion` gets one composed static frame and
fully visible text, and every page renders its content without JavaScript.
