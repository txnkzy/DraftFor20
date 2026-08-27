import { notFound } from "next/navigation";
import DevCardsClient from "./DevCardsClient";

/**
 * A server component purely so the guard can return a REAL 404.
 *
 * The first attempt called notFound() inside the client component, which
 * blanked the page but still answered 200 — a client component runs after the
 * response status is already sent. The check has to happen on the server.
 */
export default function DevCardsPage() {
  if (process.env.NODE_ENV === "production") notFound();
  return <DevCardsClient />;
}
