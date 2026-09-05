import type { Metadata, Viewport } from "next";
import { SITE_URL } from "@/lib/site";
import { Bricolage_Grotesque, Instrument_Sans } from "next/font/google";
import "./globals.css";

const bricolage = Bricolage_Grotesque({
  subsets: ["latin"],
  variable: "--font-bricolage",
  display: "swap",
});
const instrument = Instrument_Sans({
  subsets: ["latin"],
  variable: "--font-instrument",
  display: "swap",
});

export const metadata: Metadata = {
  // metadataBase turns every relative `alternates.canonical` in the app into
  // an absolute URL. Without it only the one page that hardcoded SITE_URL
  // emitted a canonical at all, so the apex, the www copy and the Vercel
  // deployment host each looked like a separate site with the same content.
  metadataBase: new URL(SITE_URL),
  alternates: { canonical: "/" },
  title: "DraftFor20 — the $20 auction draft",
  description:
    "Two players, one bankroll. The deck deals a name, you fight over what it is worth, and the board settles the argument.",
  applicationName: "DraftFor20",
};

export const viewport: Viewport = {
  themeColor: "#14161C",
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${bricolage.variable} ${instrument.variable}`}>
      <body>
        <div id="app-root">{children}</div>
      </body>
    </html>
  );
}
