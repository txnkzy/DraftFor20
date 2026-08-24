"use client";

import { useEffect, useState } from "react";
import { cardDataUri } from "@/lib/images/card";

/**
 * The picture on the card being auctioned.
 *
 * There is no "no image" state. A category with no pictures, a source that
 * went missing, a hotlink that 404s months later — all three land on the same
 * generated card, drawn from the item name. That is what lets the board treat
 * an image as always present instead of laying out twice.
 *
 * `object-contain` rather than cover: a club crest and a film poster have
 * nothing in common as shapes, and cropping either to fill a box is how a
 * crest loses its top half.
 */
export function CardImage({
  name,
  url,
  className = "",
  height = 96,
}: {
  name: string;
  url: string | null;
  className?: string;
  height?: number;
}) {
  const generated = cardDataUri(name);
  const [broken, setBroken] = useState(false);

  // a new card must retry its own URL rather than inherit the previous
  // card's failure
  useEffect(() => setBroken(false), [url, name]);

  const src = !url || broken ? generated : url;

  return (
    <div
      className={`flex shrink-0 items-center justify-center overflow-hidden ${className}`}
      style={{
        height,
        borderRadius: "var(--radius-card, 10px)",
        background: "var(--color-surface)",
      }}
    >
      <img
        key={src}
        src={src}
        alt=""
        aria-hidden="true"
        onError={() => setBroken(true)}
        style={{ height: "100%", width: "auto", maxWidth: "100%", objectFit: "contain" }}
      />
    </div>
  );
}
