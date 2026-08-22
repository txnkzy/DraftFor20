"use client";

import type { ButtonHTMLAttributes } from "react";

type Variant = "primary" | "ghost" | "calm" | "danger" | "quiet";
type Size = "sm" | "md" | "lg";

const SIZES: Record<Size, string> = {
  sm: "h-9 px-3 text-[0.6875rem]",
  md: "h-11 px-4 text-[0.8125rem]",
  lg: "h-14 px-5 text-[0.9375rem]",
};

export function Button({
  variant = "ghost",
  size = "md",
  className = "",
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; size?: Size }) {
  return <button className={`btn btn-${variant} ${SIZES[size]} ${className}`} {...rest} />;
}
