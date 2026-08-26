# Design

<!-- impeccable:design-schema 1 -->

Recorded from the built site in `site/`, not from intention. The iOS app in
`teika/` is the origin of this system; where the two disagree, the app wins.

## Visual world

Teika's world, inherited rather than invented: a near-black field with one white
particle cloud in it, and monochrome text set directly on that field. There is no
second surface — no cards, no panels, no tinted sections, and no colour at all.
Depth comes from the cloud's own luminance and from glass, never from elevation
on a box.

The page is four movements: the offer, the moment it is for, the model, the
close. Two viewports, one
heading level below the `h1`, two text sizes. The only colour anywhere is the lit
red record circle in the hero. Everything that could be removed without losing
meaning has been.

## Color

| Token | Value | Role |
|---|---|---|
| `--bg` | `#0a0a0d` | The ground. Matches the app's Metal clear colour `(0.04, 0.04, 0.05)`. |
| `--fg` | `#f2f2f4` | Headings, emphasis, primary text. |
| `--muted` | `#8e8e96` | Body copy, captions, metadata. 5.99:1 on `--bg`. |
| `--rule` | `#232329` | Hairline separators. The only border colour. |
| `--glass` | `rgba(255,255,255,0.055)` | Capsule fill. |
| `--glass-rim` | `rgba(255,255,255,0.14)` | Capsule and circle rim. |
| `--glass-rim-strong` | `rgba(255,255,255,0.28)` | Rim on hover. |
| `--record-red` | `#e5484d` | The hero record circle. The only colour on the site. |

Strategy is Restrained by conviction, not by default: the visitor came to judge a
claim about accuracy and privacy, and a saturated palette would be arguing in a
register the product does not use.

## Type

System stack, deliberately — on the audience's own devices it resolves to SF Pro,
the app's face:

```
-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI Variable Text',
'Segoe UI', system-ui, Roboto, 'Helvetica Neue', Helvetica, Arial, sans-serif
```

- Two text sizes below the headings and nothing else: `.lede`
  `clamp(1.0625rem, 2.1vw, 1.25rem)` and `.caption` 0.9375rem, both `--muted`.
- Body 17px/1.65, dropping to 16px below 34rem.
- `h1` `clamp(2.4rem, 7.2vw, 4.25rem)`, `h2` `clamp(1.85rem, 4.6vw, 2.9rem)`,
  both 600 weight, `-0.028em`, `line-height` 1.08–1.12, `text-wrap: balance`.
- Measure capped at `--measure: 34rem`; the shell is 46rem.
- Tracking floor is `-0.028em`.

## Space and rhythm

`--section-gap: clamp(5.5rem, 13vh, 8.5rem)` between movements, `--gutter:
clamp(1.25rem, 5vw, 2.5rem)` inside them. The close carries
`min-height: calc(100svh - var(--footer-h))` and `padding-top: calc(2rem +
var(--header-h))` against a plain `2rem` bottom, so it and the footer fill the
viewport together and the content lands on the optical centre of what is
actually visible.

That centring took three attempts, and the lesson is that *the band is not the
viewport*. A stray `padding-top` override left the content high; removing it
centred the content on the viewport-minus-footer, which still read high by
exactly 31px — half the fixed header, which covers the top 63px at every scroll
position. The header's height now pads the top, shifting the content down by
half of it onto the true centre between the header's underside and the footer's
top edge. Verified at 0px off across five viewports.

`--footer-h` must never exceed the real footer height: under-estimating only
makes the close taller than needed, while over-estimating lets the previous
section back on screen. The footer measures 170px, wrapping to 207px below
355px wide. More space above a heading than below
it, everywhere: `h2` carries 1.5rem below it and a full section gap above.

## Components

Three exist. Two are the app's:

- **Capsule** (`.capsule`) — the app's `downloadButton`. Glass fill, 1px rim,
  `backdrop-filter: blur(20px) saturate(140%)`, fully round. Hover lifts the fill
  and rim. The lift and press are Framer Motion, not CSS: `whileHover` raises it
  1px at 1.01 and `whileTap` puts it 1px down at 0.99, both on one stiff, well
  damped spring (460/30/0.6), so a press interrupts the lift mid-flight instead
  of queueing behind it. Colour and shadow stay in CSS, where they cost nothing,
  and `useReducedMotion` drops the transform entirely. Transform must not also be
  set in CSS — Framer writes it inline and the two fight. The only button style
  on the site.
- **Record circle** (`.rec-circle`) — `clamp(52px, 6.2vw, 76px)` of
  `--record-red` above the `h1`, at the size it has in the product: the app's
  `Color.red.opacity(0.85)` inside a red-tinted rim. Its halo has no offset
  because it is not a shadow — the circle is a light source.

- **Steps** (`.steps`) — hairline rows, a bold promise over a muted mechanism,
  so the list scans on the bold alone.

Elevation is declared once: a rim, or a shadow, never both. There are no shadows,
no cards, and no third component — if something needed a container, it was cut
instead.

## Motion

One authored moment, not scattered effects. Everything eases on
`--ease: cubic-bezier(0.2, 0.9, 0.25, 1)` or `--ease-soft` for the cloud's
opacity.

The page's motion **is** the product's motion. `lib/stage.ts` holds `level` and
`presence` — the same two variables the app drives from `AudioLevelMeter` and the
transcriber's state — and `StageDriver` maps scroll position onto them, smoothed
in the render loop with the app's own attack (0.1 s), decay (0.47 s) and
`presenceTau` (0.6 s).

The shape of that curve is the whole design: **the cloud is alive in the first
viewport and settles as the page is read.** The hero block is centred on the
viewport itself, so the cloud is at its brightest exactly where the eye lands. Expanded, lit and breathing on the
voice envelope at the top; withdrawn to a quiet field by the model section. The
energy is spent where there is nothing to read and withdrawn where there is.

## The cloud's web attenuation

`WEB_ORB` in `lib/orbConfig.ts` holds the only three numbers on this site that
deliberately differ from the shipped app: `idleBrightness` 1.1 → 0.62, `density`
0.7 → 0.62, `twinkleAmount` 0.35 → 0.2. On a phone the cloud *is* the screen and
can carry full brightness; behind a page of text the same values read as a
starfield competing with the words. Same simulation, turned down — then handed
back its energy in the hero through `level`, which is a different lever entirely.

Turned down is not turned off: at `idleBrightness` 0.42 the cloud lost its shape
and became formless dust, which is worse than too bright. It has to still read as
one soft mass.

## Legibility over the cloud

The one rule with no counterpart in the app, and the one that took the most
tuning. Body copy sits on a live particle field, so each text column carries its
own well of ground: a wide radial on `.shell::before`, bled 24vw past the column
so the gradient's tail finishes inside its own box rather than clipping into a
visible seam. The hero uses a softer one — the cloud is the argument there.

That ground is deliberately light, which leaves small text able to land on a
single bright particle. Measured against the raw canvas, the worst case was
**1.13:1**. The fix is not more ground — that buries the cloud — but type that
carries its own: a real shadow with an offset and a blur, invisible against the
black and just enough to hold an edge against a particle. It applies to every
heading, lede, caption and step row on the page, not only the hero, because the
cloud now stays bright the whole way down (`--orb-dim` peaks at 0.4, not 0.55).

Sections that carry text also raise `--orb-dim`, which is the same move the app
makes when it drops the cloud to 0.6 behind a transcript.

## Icons

All derived from the app's own icon at
`teika/AppIcon.icon/Assets/icon_512x512@2x.png`. Its content occupies only 70% of
the source frame — measured, not guessed — so the favicon is an 880px centred
crop that brings the disc and its particle spray to 82% of frame, which is what
makes it read at 16px. `app/favicon.ico` carries 16/32/48, and its embedded PNGs
must be RGBA: Next's ICO decoder rejects RGB outright and fails the build.
`apple-icon.png` stays uncropped, because a home-screen icon should match the app.

## Browser surfaces

Themed from the palette rather than left to the browser: `::selection`,
`:focus-visible` (2px `--fg`, 3px offset), the scrollbar in both
`scrollbar-color` and `::-webkit-scrollbar` form, link underline colour and
`text-underline-offset`, and tabular numerals on the footer's year.

## Accessibility

- Skip link, first in tab order, revealed on focus.
- The canvas is `aria-hidden` and purely decorative; every claim is in text.
- `prefers-reduced-motion` gives the cloud one composed static frame and makes the
  reveal render fully visible with no transition — verified, not assumed.
- No WebGL2 falls back to `.orb-fallback`, a single soft radial.
- One `h1` per page, no unlabelled images, all content renders without JS.

## Refusals

Recorded so a later pass does not reintroduce them: no cards as page structure,
no eyebrow labels above headings, no section numbers, no gradient text, no
hero-metric stat row, no icon-plus-heading-plus-text grid, no device mockups
(the app is already edge-to-edge black — a bezel would put chrome between the
reader and the product), and no invented Apple-versus-Teika benchmark.

**No number that describes the model instead of the product.** Leaderboard
figures are measured on server GPUs; quoting them as though they describe an
iPhone is the quiet dishonesty this page kept walking into.

And the one this page learned the hard way: **no section that exists because the
scroll felt short.** The first build had seven movements — a notes list, a
clipboard confirmation, a measurement table, four paragraphs on benchmarks. All
of it was true and none of it was needed. The pitch is one sentence long, and the
page should not be much longer than it needs to carry that sentence, show it
working, and name the model.

Two later cuts worth keeping cut: the transcribing-sentence demo (a nice port of
`StreamingText.swift`, but a demo the page did not need), and any framing of the
model as a comparison against Apple's — Apple publishes no figure, so there is
nothing to compare against.

Comparison against *published* models is a different thing and belongs on the
page. Two attempts failed before this one, and both failed the same way — the
reader could not tell what was being measured:

1. Three bars of LibriSpeech scores. Jargon dataset names, and the bars grew
   as the result got **worse**. A caption had to explain its own axis, which is
   the tell that the visual had failed.
2. A hundred dots with six dimmed. Honest and legible, but it showed one model
   against nothing, so it answered "how good?" with no scale to judge it by.

A third attempt built a proper ranked table — named competitors, both metrics in
column headers, benchmark and hardware in the caption. It was accurate and it
still failed, for a reason none of the three shared: **every figure in it
described a model on a data-centre GPU, not this app on a phone.** The most
memorable number on the page was 3,333× real time, measured on an A100, which a
handset will not do. Caveated in the caption, and still read as a promise.

The section that replaced it makes the technical fact *cause* something the
reader wants: the model runs on the phone, which is why the app works in
Airplane Mode, uploads nothing, and costs nothing. The only benchmark left is
one sentence — it beats Whisper Large v3 on the Open ASR Leaderboard — carrying
a link for anyone who wants to check. Proof belongs on the page; a leaderboard
does not.

The header carries the wordmark alone. Support and Privacy live in the footer,
where a visitor looks for them, rather than competing with the one action the
page is asking for.
