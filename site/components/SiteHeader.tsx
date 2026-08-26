'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';

/**
 * The app's navigation bar: a title, and nothing else. The hairline and backdrop
 * only appear once the page has moved, so the first viewport is the cloud and the
 * headline with no chrome drawn across it.
 */
export default function SiteHeader() {
  const [lifted, setLifted] = useState(false);

  useEffect(() => {
    const onScroll = () => setLifted(window.scrollY > 24);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

  return (
    <header className="site-header" data-lifted={lifted || undefined}>
      <div className="site-header-inner">
        <Link className="wordmark" href="/">
          Teika
        </Link>
      </div>
    </header>
  );
}
