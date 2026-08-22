"use client";

import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * Host branding uploads, in one place.
 *
 * Used by the host settings page and by the export card customiser, because
 * they are the same upload with the same rules and two copies of them would
 * eventually disagree.
 *
 * SVG is deliberately absent from the allow list: it can carry script and
 * this file gets rendered into an image other people share. The checks here
 * are for a fast, clear message — the bucket's own file_size_limit and
 * allowed_mime_types are the ones that actually hold.
 */
export const LOGO_MAX_BYTES = 512 * 1024;
export const LOGO_TYPES = ["image/png", "image/jpeg", "image/webp"];

export function logoProblem(file: File): string | null {
  if (!LOGO_TYPES.includes(file.type)) return "Logos have to be PNG, JPEG or WebP.";
  if (file.size > LOGO_MAX_BYTES) {
    return `That file is ${Math.round(file.size / 1024)}KB. The cap is 512KB.`;
  }
  return null;
}

export async function uploadBrandLogo(
  sb: SupabaseClient,
  userId: string,
  file: File,
): Promise<{ url?: string; error?: string }> {
  const problem = logoProblem(file);
  if (problem) return { error: problem };

  const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
  // the storage policy only lets a host write inside a folder named after
  // their own uid, so the path is not decoration
  const path = `${userId}/logo-${Date.now()}.${ext}`;
  const { error } = await sb.storage
    .from("brand")
    .upload(path, file, { contentType: file.type, upsert: true });
  if (error) return { error: error.message };

  const { data } = sb.storage.from("brand").getPublicUrl(path);
  return { url: data.publicUrl };
}
