import type { Metadata, Viewport } from "next";
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
