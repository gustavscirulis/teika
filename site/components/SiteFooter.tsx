import Link from 'next/link';
import { SOURCE_URL } from '@/lib/site';

export default function SiteFooter() {
  return (
    <footer className="site-footer">
      <div className="shell">
        <div className="site-footer-inner">
          <nav aria-label="Footer">
            <Link href="/support/">Support</Link>
            <Link href="/privacy/">Privacy</Link>
            <a href={SOURCE_URL} rel="noreferrer noopener" target="_blank">
              View source
            </a>
          </nav>
          <p>
            © 2026{' '}
            <a href="https://gustavscirulis.com" rel="noreferrer noopener" target="_blank">
              Gustavs Cirulis
            </a>
          </p>
        </div>
      </div>
    </footer>
  );
}
