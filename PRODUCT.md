# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

_(The Teika app itself is `ios`. This record covers the marketing/support website in `site/`; the iOS app's own design truth lives in `teika/`.)_

## Stack

Next.js (App Router), specified by the user. Static export target so the whole site
can be hosted without a server, including on GitHub Pages. The App Store submission
needs publicly reachable Support and Privacy URLs.

## Users

Someone with a thought they will lose in a minute and no hands to type it —
on a bike, in a car, halfway down the street. They have already tried dictating
into the built-in keyboard and given up on it: it misheard them, or it quit the
moment they paused to think, or the friction of first choosing *which app to
take the note in* meant the thought was gone before the note existed.

Teika was built by its author for exactly this, out on a bike. That is the
audience: not people shopping for a transcription tool, but people who keep
losing thoughts and have not connected that to an app they could install.

Secondary and non-negotiable: an App Store reviewer following the Support and
Privacy URLs.

## Product Purpose

Catch a thought before it is gone. Open the app, press record, talk for as long
as you need, press again: the text appears, lands on the clipboard, and stays in
a library. Success is that the thought survives the walk from head to clipboard
without the user having to choose an app, race a timeout, or wonder where the
audio went.

## Positioning

**The competitor is iOS's built-in dictation**, not other note apps. Three
specific failures of it are the whole reason Teika exists:

1. **It makes you pick an app first.** The thought has to survive choosing a
   destination. Teika is one screen with one control — open it, press record.
2. **It quits when you pause.** iOS dictation ends the session after roughly
   30 seconds of *silence*, not of speech, so thinking mid-sentence kills it.
   Teika's buffer is unbounded and stops only on the second tap.
3. **It mishears.** Teika runs a named, published recogniser instead.

The payoff after the recording is the other half: the transcript is on the
clipboard *and* in a library, so it can be pasted straight into whatever app it
was headed for, or left to be found later.

Underneath all three is one architectural fact — **the model runs on the
device**. That is why it works in Airplane Mode, why nothing is uploaded, and
why it costs nothing to run.

**How the competitor may be discussed.** The workflow failures above are the
reader's own experience and are fair to describe. The accuracy comparison is
not: Apple publishes no word error rate for its recogniser, so no honest
head-to-head exists. The site therefore never names Apple as a benchmark
opponent and never shows a Teika-versus-Apple figure.

## Operating Context

In motion, one-handed, often offline: a bike, a car, a train, a plane, a
basement, a country where roaming costs money. The output is destined for
another app — Notes, Slack, a mail draft — which is why the clipboard copy is
automatic rather than a button. First run costs a consented 0.5 GB download over
Wi-Fi; that cost is a real objection the site must handle rather than hide, and
it is stated on the landing page rather than left to Support.

## Capabilities and Constraints

Confirmed, from the code:

- One control: a circle to start and stop. Recording state is a red glass circle.
- Transcription runs on the iPhone. iPhone audio is held in memory and
  discarded; a stopped iPhone recording waits there if its cached model is still
  loading. Watch audio stays in a persistent device-local outbox until transfer
  succeeds, then stays on the iPhone until processing finishes. Recordings are
  never uploaded.
- Every completed transcription is copied to the system clipboard automatically
  and confirmed with a "Copied to clipboard" pill for 1.5 s.
- Notes are saved locally via SwiftData, searchable across their full text, listed,
  reopenable, re-copyable, and deletable.
- A paired Apple Watch app records on the wrist and sends clips to the iPhone for
  transcription and storage. After setup has completed once, it can record while
  the iPhone is unreachable and queue multiple clips for later delivery.
- A **Start Recording** widget is available on the iPhone Home Screen and Lock
  Screen, plus a Control Center control. The same action is available through
  Shortcuts and Siri; each opens Teika and starts a fresh recording.
- The model auto-detects language (`language: nil`) across 25 European
  languages — real, but untested by the developer, so the site states it only as
  the model's documented capability, not as a tested Teika feature.
- Recordings under ~0.3 s are discarded by design.
- Model download is consent-gated: ~0.5 GB, from Hugging Face, Inc. The prompt
  identifies the host and its standard connection metadata before networking.
- Forced dark mode (`preferredColorScheme(.dark)`); there is no light variant.
- Free and open source. No account, no IAP, no subscription, no ads, no in-app
  analytics, no tracking, no IDFA. The App Privacy label conservatively discloses
  the model host's coarse location, product interaction, and diagnostic connection
  data.
- iOS 26.5 deployment target; iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`),
  with a paired Apple Watch app.
- Motion permission is used only to tilt the decorative particle orb.

Undecided / not to be invented: pricing beyond "free", user counts, reviews,
ratings, press, testimonials, a Mac version, launch date.

## Committed Copy

The landing page's current wording, so future edits change it deliberately:

- **h1** — "Catch the thought before it's gone." (the why)
- **Lede** — "Accurate, fast, and private speech-to-text notes for iPhone and
  Apple Watch."
  Speech-to-text, never text-to-speech: the reverse names a different product.
- **Section 2** — "For thoughts you have on the move", with the three workflow
  answers: start from the nearest surface · talk until you are done · paste it
  now, or find it later.
- **Section 3** — "The good model, on your phone", framed as cause, not spec:
  running on the device is *why* it works offline, uploads nothing and is free.
  Closes with the one-time 0.5 GB download.
- **Close** — "Open it and talk."
- **Install signal** — "Free and open source." The words "open source" link to
  the source.

## Brand Commitments

- Name: **Teika**. App Store name: "Teika: Voice to Text Notes".
- The app's visual world is binding and the site inherits it: near-black ground
  (`#0a0a0d`; the app clears to `rgb(0.04, 0.04, 0.05)`), monochrome white, a
  single glowing white particle cloud, system SF stack, tight negative tracking
  on display type, glass capsule controls, per-word blur-in reveal of
  transcribed text (opacity 0→1, blur 4→0, ~20 ms stagger, whole reveal capped
  at 0.3 s).
- Existing web tokens, already shipped in `docs/privacy.html`:
  `--bg #0a0a0d`, `--fg #f2f2f4`, `--muted #8e8e96`, `--rule #232329`.
- Voice: plain and factual. Flat declaratives, no marketing register, no
  exclamation. The App Store copy is the reference register: "Tap the circle,
  speak, tap again."
- Copyright: 2026 Gustavs Cirulis. Contact: gustavs.cirulis@gmail.com.
- Source: https://github.com/gustavscirulis/teika. GPLv3 or later with the
  repository's Apple App Store additional permission.

## Evidence on Hand

**Verified in this repo's own source** — the strongest evidence available,
because a reader can check it:

- No recording length cap. `SampleStore` is an unbounded `[Float]` buffer and
  `stopAndTranscribe` is the only thing that ends a session, so pausing never
  stops it. The single bound is a ~0.3 s *minimum* (`minimumRequiredSamples`).
- One screen, one control (`ContentView`).
- Clipboard write plus a saved `Note` on every completed transcription.
- One kind of app network activity: the consent-gated model download. It may use
  several HTTPS requests and redirects to retrieve the model files.

**Citable, from the published record** (model card and the Open ASR Leaderboard
paper, arXiv:2510.06961 Table 3, checked August 2026):

- NVIDIA Parakeet TDT 0.6B v3, 600M parameters, 25 European languages.
- Open ASR Leaderboard English track, measured on one A100 at batch 64 —
  Parakeet **6.32%** WER at **3,333×** real time; Canary Qwen 2.5B 5.63% /
  418×; Canary 1B v2 7.15% / 749×; Whisper Large v3 7.44% / 146×. Parakeet is
  therefore more accurate *and* ~23× faster than Whisper Large v3, and less
  accurate than Canary Qwen. The model card's own English average is 6.34%;
  never mix the two sources inside one comparison.
- Automatic punctuation and capitalisation.

**Citable with care — a leaderboard figure is not a product claim.** RTFx is
measured on a data-centre GPU. Quoting "3,333× real time" or "an hour of audio
in a second" beside an iPhone reads as a promise the phone will not keep, and
the landing page no longer does it. No on-device timing has been measured; until
one exists, the site makes no speed claim in seconds.

**Deliberately absent — must never be fabricated:**

- Any Apple-vs-Teika word error rate. Apple publishes no WER for its
  recogniser, and no public head-to-head exists. Teika competes with it on
  *workflow* — no app to pick, no silence cutoff, clipboard and library — all of
  which are checkable from this repo's source.
- A specific figure for iOS dictation's silence timeout. The ~30 s figure is
  widely reported by users but is not in Apple's documentation, so the site
  states Teika's behaviour positively ("pausing never ends the recording")
  rather than asserting a number about someone else's product.
- User counts, ratings, reviews, testimonials, press quotes, awards.
- A licence claim beyond the attribution in `teika/LICENSES.txt`. The NVIDIA
  model and FluidInference Core ML conversion declare CC-BY-4.0; legal review is
  needed before making broader licensing claims about the model on the site.

**Assets:** the app icon at `teika/AppIcon.icon/Assets/icon_512x512@2x.png` —
the source for the site's favicon, apple-touch icon and Open Graph image;
privacy text at `PRIVACY.md` and `docs/privacy.html`. No product screenshots
exist yet, so the site carries no imagery of the app itself.

## Product Principles

1. **Show the mechanism, don't adjectivise it.** The app is one circle and a
   reveal. The site should let a visitor watch that happen, not read that it is
   "seamless".
2. **Every claim must be checkable by the reader.** "Turn on Airplane Mode" is
   the model for all proof here: an instruction the user can run themselves
   beats a number they must trust.
3. **Name the cost honestly.** The 0.5 GB download is stated, not buried. The
   privacy policy's tone — "that is the whole policy" — is the register.
4. **Silence is the brand.** Black space, one light source, few words. Anything
   that could be removed without loss of meaning is removed.
5. **Never claim what the code cannot do.** No sync, no assistant, no commands,
   no tested multilingual promise.

## Accessibility & Inclusion

The app ships real accessibility labels, hints and values on every control, and
the site must match that standard: full keyboard operability, visible focus on
the near-black ground, WCAG AA contrast for all body text (the app's `--muted`
`#8e8e96` on `#0a0a0d` passes at body size), honest `prefers-reduced-motion`
handling for the particle field and the text reveal, and no information carried
by the animation alone.
