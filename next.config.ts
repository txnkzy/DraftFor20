import type { NextConfig } from "next";

const isDev = process.env.NODE_ENV === "development";

/**
 * Content Security Policy.
 *
 * script-src still allows 'unsafe-inline' because Next inlines its hydration
 * payload and Turbopack's dev client needs eval. Moving to a nonce-based
 * policy is the next step and is the single biggest remaining hardening win;
 * everything else below is already strict.
 */
const csp = [
  "default-src 'self'",
  `script-src 'self' 'unsafe-inline'${isDev ? " 'unsafe-eval'" : ""}`,
  "style-src 'self' 'unsafe-inline'",           // Tailwind injects a style tag
  "img-src 'self' data: blob: https:",          // host logos are remote URLs
  "font-src 'self' data:",                      // next/font self-hosts
  // the ws://127.0.0.1:54321 entry is the local PostgREST harness in
  // supabase/tests/local-harness.md; without it realtime spams the console
  // with CSP violations while the app quietly falls back to polling
  "connect-src 'self' https://*.supabase.co wss://*.supabase.co" +
    (isDev
      ? " http://127.0.0.1:54321 ws://127.0.0.1:54321 ws://localhost:3000 ws://127.0.0.1:3000"
      : ""),
  "frame-ancestors 'none'",
  "frame-src 'none'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "upgrade-insecure-requests",
].join("; ");

const nextConfig: NextConfig = {
  // Local two-player testing runs the second seat on 127.0.0.1 so it gets its
  // own localStorage origin. Dev-server only.
  allowedDevOrigins: ["127.0.0.1"],

  // never ship client source maps: they hand an attacker the original source
  productionBrowserSourceMaps: false,

  poweredByHeader: false,

  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "Content-Security-Policy", value: csp },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=(), usb=()" },
          { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
          {
            key: "Strict-Transport-Security",
            value: "max-age=63072000; includeSubDomains; preload",
          },
        ],
      },
    ];
  },
};

export default nextConfig;
