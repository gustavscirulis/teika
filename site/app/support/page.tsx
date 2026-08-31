import type { Metadata } from 'next';
import { CONTACT_EMAIL, MODEL, SOURCE_URL } from '@/lib/site';

export const metadata: Metadata = {
  title: 'Support',
  description:
    'Use Teika on iPhone and Apple Watch, and start recordings from widgets, Control Center, or Shortcuts.',
};

/**
 * Every answer here describes behaviour that is actually in the code — including
 * the three things that look like faults and are not.
 */
export default function Support() {
  return (
    <main id="main" className="prose">
      <div className="shell">
        <h1>Support</h1>
        <p className="updated">Teika · Voice to Text Notes</p>

        <h2>How do I use it?</h2>
        <p>
          Tap the large circle near the bottom of the screen, speak, then tap it again.
          Take as long as you like — pausing to think will not end the recording. The text
          appears on screen, is copied to your clipboard, and is saved as a note.
        </p>

        <h2>Where is the record button?</h2>
        <p>
          Look for the circle near the bottom of the screen. It turns red while recording.
        </p>

        <h2>Why does the first screen only offer a download?</h2>
        <p>
          That is intended. Teika does not ship with its speech model, and it does not
          fetch anything until you say so. Tap <strong>Set Up Transcription</strong>,
          review the 0.5 GB download and privacy details, then choose{' '}
          <strong>Download 0.5 GB</strong>. Choosing <strong>Not Now</strong> does not
          start the download. Use Wi-Fi and let the ring around the button finish. It can
          take several minutes depending on your connection.
        </p>
        <p>After that, transcription works without an Internet connection.</p>

        <h2>How do I start a recording outside the app?</h2>
        <p>
          Once the speech model is ready, add Teika&rsquo;s <strong>Start Recording</strong>{' '}
          widget to your Home Screen or Lock Screen. You can also add its{' '}
          <strong>Start Recording</strong> control to Control Center, run{' '}
          <strong>Start Recording with Teika</strong> from Shortcuts or Spotlight, or say
          &ldquo;Siri, start recording with Teika.&rdquo; Touch and hold Teika&rsquo;s app icon
          and choose <strong>New Recording</strong> for the same action. Each opens Teika
          and starts a new recording.
        </p>

        <h2>How do I use Teika on Apple Watch?</h2>
        <p>
          On your paired Apple Watch, tap the circle, speak, then tap it again. Teika sends
          the recording to your iPhone, where it is transcribed and saved as a note. If
          the phone is available, the watch says <strong>Sent to iPhone</strong>. Otherwise
          it says <strong>Queued for iPhone</strong> and sends it when the connection
          returns.
        </p>
        <p>
          You must complete transcription setup on the iPhone once before the watch can
          record. After that, the phone does not need to be nearby: the watch keeps each
          recording until transfer succeeds, and the phone keeps received audio until its
          speech model is ready to process it. If your watch says{' '}
          <strong>Finish setup on your iPhone</strong>, open Teika on your phone and
          complete the model download.
        </p>

        <h2>Where are my saved notes?</h2>
        <p>
          The list icon is always in the top-right corner. Tap it to open your library;
          before your first recording, it shows an empty state. Saved notes are grouped by
          date and searchable by their full text. Tap a row to copy it again, or swipe left
          for Open and Delete.
        </p>

        <h2>I tapped the circle and nothing happened</h2>
        <p>
          Very short recordings are discarded on purpose — a stray tap is not speech. Tap
          once, speak a full sentence, then tap again.
        </p>

        <h2>I declined the microphone permission</h2>
        <p>
          Teika will show a notice with a link straight to its Settings page. Turn on
          Microphone there and return to the app.
        </p>

        <h2>The download failed</h2>
        <p>
          Every error state in the app is recoverable — you will get a message and a{' '}
          <strong>Try Again</strong> button. If you already completed setup, Teika can
          record while the cached model prepares. When preparation fails after you stop,
          the recording stays in memory while the app remains open; choose{' '}
          <strong>Try Again</strong> to process it or <strong>Discard Recording</strong> to
          remove it. If the first download keeps failing, check that you are not on a
          captive Wi-Fi network that needs a browser sign-in, and that you have about a
          gigabyte free.
        </p>

        <h2>Which languages does it recognise?</h2>
        <p>
          The model is documented as supporting {MODEL.languages} European languages and
          detects the language automatically — there is no setting to change. Teika&rsquo;s
          own testing has been in English, so treat the rest as the model&rsquo;s
          capability rather than a tested promise.
        </p>

        <h2>What does it cost?</h2>
        <p>
          Nothing. Teika is free and open source, with no in-app purchases, subscription,
          ads or analytics. You can{' '}
          <a href={SOURCE_URL} rel="noreferrer noopener" target="_blank">
            view the source on GitHub
          </a>
          .
        </p>

        <h2>How do I delete everything?</h2>
        <p>
          Swipe a note in the list to delete it individually. Deleting the app removes
          every note and the downloaded model from that device. If device backups are
          enabled, an existing iCloud or computer backup may still contain notes until you
          remove or replace that backup through Apple&rsquo;s backup settings. Teika has no
          server copy.
        </p>

        <h2>What model does it run?</h2>
        <p>
          <a href={MODEL.cardUrl} rel="noreferrer noopener" target="_blank">
            {MODEL.vendor} {MODEL.name}
          </a>
          , as a Core ML build (<code>{MODEL.build}</code>). It runs entirely on your
          device.
        </p>

        <h2>Does Teika send my recordings to an AI service?</h2>
        <p>
          No. Recordings, transcripts, and notes stay on your devices. Hugging Face hosts
          the model files used during the setup download, but it does not receive your
          recordings or perform the transcription. See the{' '}
          <a href="/privacy/">privacy policy</a> for the connection information involved
          in that download.
        </p>

        <h2>Still stuck?</h2>
        <p>
          <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> — tell me your device and
          iOS version and what you were doing.
        </p>
      </div>
    </main>
  );
}
