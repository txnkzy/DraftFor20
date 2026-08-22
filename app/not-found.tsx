import type { Metadata } from "next";
import Link from "next/link";
import { Footer, Header } from "@/components/site/Chrome";

export const metadata: Metadata = {
  title: "Page not found — DraftFor20",
  description: "That page doesn't exist. Start a room or join one with a code.",
};

export default function NotFound() {
  return (
    <>
      <Header thin />
      <main className="mx-auto flex w-full max-w-md flex-col items-start px-4 py-20">
        <p className="type-num text-[3.5rem] leading-none text-coral">404</p>
        <h1 className="type-display mt-3 text-[1.75rem]">Nothing on the block here</h1>
        <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
          That page doesn&apos;t exist. If you were headed for a draft, room links look like{" "}
          <code className="type-num text-ink">/room/ABC123</code> and the code is six characters.
        </p>
        <div className="mt-7 flex flex-wrap gap-2">
          <Link href="/new" className="btn btn-primary h-12 px-5 text-[0.875rem]">
            Start a room
          </Link>
          <Link href="/join" className="btn btn-ghost h-12 px-5 text-[0.875rem]">
            Join with a code
          </Link>
        </div>
      </main>
      <Footer />
    </>
  );
}
