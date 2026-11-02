import type { Metadata } from 'next';
import releases from '@/lib/releases.json';

export const metadata: Metadata = {
  title: 'Updates',
  description: 'The latest improvements to Teika.',
};

export default function Updates() {
  return (
    <main id="main" className="prose">
      <div className="shell">
        <h1>Updates</h1>
        <p className="lede">Small improvements for thoughts worth keeping.</p>

        {releases.pending.length > 0 && (
          <section aria-labelledby="in-development">
            <h2 id="in-development">In development</h2>
            <ul>
              {releases.pending.map((change) => <li key={change}>{change}</li>)}
            </ul>
          </section>
        )}

        {releases.releases.map((release) => (
          <section key={release.version} aria-labelledby={`version-${release.version}`}>
            <h2 id={`version-${release.version}`}>Teika {release.version}</h2>
            <p className="updated">
              <time dateTime={release.date}>{release.date}</time>
            </p>
            <ul>
              {release.notes.map((note) => <li key={note}>{note}</li>)}
            </ul>
          </section>
        ))}
      </div>
    </main>
  );
}
