import type { Metadata, Viewport } from 'next';
import { Analytics } from '@vercel/analytics/next';
import './globals.css';
import DirectionContract from '@/components/DirectionContract';
import Orb from '@/components/Orb';
import SiteHeader from '@/components/SiteHeader';
import SiteFooter from '@/components/SiteFooter';

export const metadata: Metadata = {
  metadataBase: new URL('https://teika.app'),
  title: {
    default: 'Teika — Speech to text notes',
    template: '%s — Teika',
  },
  description:
    'Free and open-source speech-to-text notes for iPhone and Apple Watch. Private, on-device transcription that works offline after setup.',
  applicationName: 'Teika',
  openGraph: {
    type: 'website',
    siteName: 'Teika',
    title: 'Teika — Speech to text notes',
    description:
      'Free and open-source speech-to-text notes for iPhone and Apple Watch. Private, on-device transcription that works offline after setup.',
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Teika — Speech to text notes',
    description:
      'Free and open-source speech-to-text notes for iPhone and Apple Watch, with private on-device transcription.',
  },
};

export const viewport: Viewport = {
  themeColor: '#0a0a0d',
  colorScheme: 'dark',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <DirectionContract />
        <a className="skip-link" href="#main">
          Skip to content
        </a>
        <Orb />
        <SiteHeader />
        {children}
        <SiteFooter />
        <Analytics />
      </body>
    </html>
  );
}
