import { permanentRedirect } from "next/navigation";

/**
 * The vote used to live at /judge/<code>. Links get screenshotted, pinned in
 * chats and printed on stream overlays, so the old one keeps working forever
 * rather than turning into a 404 somebody discovers mid-broadcast.
 */
export default async function JudgeRedirect({
  params,
}: {
  params: Promise<{ code: string }>;
}) {
  const { code } = await params;
  permanentRedirect(`/vote/${code}`);
}
