import AppStoreButton from '@/components/AppStoreButton';
import StageDriver from '@/components/StageDriver';
import { MODEL, SOURCE_URL } from '@/lib/site';

/**
 * Each of these makes a real part of the capture path faster, and each is
 * verifiable in this app's own source:
 *  - no app-picking: ContentView is one screen with one control
 *  - no silence cutoff: SampleStore is an unbounded buffer, stopped only by the
 *    second tap. The only bound is a ~0.3 s *minimum*.
 *  - clipboard + library: `onTranscription` writes UIPasteboard and inserts a Note
 */
const STEPS = [
  {
    lead: 'Start from what is closest',
    body: 'Use the app, Apple Watch, a widget, Control Center, or Shortcuts. On iPhone, you can also say “Siri, start recording with Teika.”',
  },
  {
    lead: 'Talk until you are done',
    body: 'One tap starts a recording. It keeps listening until you tap stop, even when you pause to think.',
  },
  {
    lead: 'Paste it now, or find it later',
    body: 'Every transcription is copied to your clipboard and kept in a library on your phone.',
  },
];

export default function Home() {
  return (
    <main id="main">
      <StageDriver />

      <section className="movement hero" data-stage="hero">
        <div className="shell">
          {/* The app's recording state, lifted straight out of the product. */}
          <span className="rec-circle" aria-hidden="true" />
          {/* The break is placed by hand so the two halves of the thought stay
              whole. The space sits outside the tag, so collapsing the break on
              narrow viewports does not weld the halves together. */}
          <h1>
            Catch the thought{' '}
            <br />
            before it&rsquo;s gone.
          </h1>
          {/* Speech-to-text, not text-to-speech: this app turns talking into
              writing, and the reverse names a different product category. */}
          <p className="lede">
            Accurate, fast, and private speech-to-text notes for iPhone and Apple Watch.
          </p>
          <div className="cta">
            <AppStoreButton />
            <span className="price-label">
              Free and open source.{' '}
              <a href={SOURCE_URL} rel="noreferrer noopener" target="_blank">
                View source
              </a>
            </span>
          </div>
        </div>
      </section>

      <section className="movement" data-stage="steps">
        <div className="shell">
          <h2>For thoughts you have on the move</h2>
          <p className="lede">
            On the bike, in the car, halfway down the street. The moments you cannot type
            are the ones worth catching.
          </p>
          <ul className="steps">
            {STEPS.map((step) => (
              <li key={step.lead}>
                <strong>{step.lead}</strong>
                {step.body}
              </li>
            ))}
          </ul>
        </div>
      </section>

      <section className="movement" data-stage="model">
        <div className="shell">
          <h2>The good model, on your phone</h2>
          <p className="lede">
            Speech recognition this accurate normally runs on someone else&rsquo;s server.
            Teika runs{' '}
            <a href={MODEL.cardUrl} rel="noreferrer noopener" target="_blank">
              {MODEL.vendor}&rsquo;s Parakeet
            </a>{' '}
            on your iPhone — which is why it works in Airplane Mode, why nothing you say is
            uploaded, and why it costs nothing.
          </p>
          <p className="caption">
            After you approve it, the model downloads once — about 0.5 GB. After setup,
            transcription runs entirely offline.
          </p>
        </div>
      </section>

      <section className="movement close" data-stage="close">
        <div className="shell">
          <h2>Open it and talk.</h2>
          <div className="cta cta-stacked">
            <AppStoreButton />
            <span className="price-label">
              Free and open source.{' '}
              <a href={SOURCE_URL} rel="noreferrer noopener" target="_blank">
                View source
              </a>
            </span>
          </div>
        </div>
      </section>
    </main>
  );
}
