/**
 * The design contract this surface was built against, emitted as a real HTML
 * comment. A JSX comment is compiled away and never reaches the document, so it
 * could not be audited against the shipped page — which is the only thing that
 * makes writing it down worth anything.
 */
const CONTRACT = `
  TEIKA — SURFACE DIRECTION CONTRACT

  THESIS: Catching a thought you are about to lose. The page refuses the
  dark-SaaS arrangement of hero, feature cards and logo wall, and it refuses the
  spec-sheet arrangement it passed through on the way here — a page about the
  speech model is a page about the wrong thing.

  OWN-WORLD: The app's world, inherited rather than invented. #0a0a0d ground,
  one white particle cloud ported from teika/Particles.metal, monochrome text at
  --fg/--muted, hairline --rule separators, glass capsules, the system SF stack
  at -0.028em. The only colour anywhere is the lit red record circle.

  STORY: The visitor recognises the moment — a thought on the bike, in the car,
  halfway down the street — learns it takes two taps and no app-picking, that
  pausing never ends the recording, and that the text lands on the clipboard and
  stays in a library. The model appears only as the reason all of that can be
  accurate, offline and free.

  FIRST VIEWPORT: Full-bleed cloud at its most alive. Fixed hairline header,
  chrome-free until scroll. The record circle at product scale, then the
  headline, one line of category, the App Store capsule and its terms — the
  whole block centred on the viewport's own centre line.

  FORM: Four movements — hero, the moment it is for, the model, the close — with
  scroll position driving the cloud's level and presence exactly as audio and
  model loading drive them in the app. Candidate 5 of 7 on the resonance-ordered
  list. Seed key 7ad3f1c9, surface scope, persuade mode.

  FINISH: unreviewed and undocumented is unfinished; this build ends with the
  finish review, the verdict, and DESIGN.md
`;

export default function DirectionContract() {
  return <div hidden dangerouslySetInnerHTML={{ __html: `<!--${CONTRACT}-->` }} />;
}
