/**
 * Static export, so the marketing, Support and Privacy pages can be hosted
 * without a server. The App Store submission needs the latter two to remain
 * publicly reachable.
 *
 * For a project page (…github.io/teika) set NEXT_PUBLIC_BASE_PATH=/teika
 * at build time. For a user page or a custom domain, leave it unset.
 */
const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? '';

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'export',
  basePath: basePath || undefined,
  // GitHub Pages serves /about as /about/index.html, so emit directories.
  trailingSlash: true,
  images: { unoptimized: true },
};

export default nextConfig;
