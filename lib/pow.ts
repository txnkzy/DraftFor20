/**
 * A tiny proof of work in front of room creation.
 *
 * The browser finds a nonce whose SHA-256 starts with N zero bits; the server
 * checks it in one hash. Costs a human about 100ms and costs a scripted room
 * flood the same 100ms per room, which is the point. No third party, no
 * tracking pixel, no puzzle for the user to look at.
 *
 * The challenge is the current minute, so nothing has to be stored between
 * the challenge and the answer.
 */
export const POW_BITS = 16;

export function powChallenges(now = Date.now()): string[] {
  const minute = Math.floor(now / 60_000);
  // accept the current and previous minute so a slow device is not punished
  return [`df20:${minute}`, `df20:${minute - 1}`];
}

async function sha256(input: string): Promise<Uint8Array> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return new Uint8Array(digest);
}

function leadingZeroBits(bytes: Uint8Array): number {
  let bits = 0;
  for (const b of bytes) {
    if (b === 0) {
      bits += 8;
      continue;
    }
    bits += Math.clz32(b) - 24;
    break;
  }
  return bits;
}

/** Browser side. Returns the nonce that solves the current challenge. */
export async function solvePow(bits = POW_BITS): Promise<{ challenge: string; nonce: number }> {
  const challenge = powChallenges()[0];
  for (let nonce = 0; nonce < 20_000_000; nonce++) {
    if (leadingZeroBits(await sha256(`${challenge}:${nonce}`)) >= bits) {
      return { challenge, nonce };
    }
  }
  throw new Error("proof of work failed");
}

/** Server side. One hash. */
export async function verifyPow(
  challenge: string,
  nonce: number,
  bits = POW_BITS,
): Promise<boolean> {
  if (!powChallenges().includes(challenge)) return false;
  if (!Number.isInteger(nonce) || nonce < 0) return false;
  return leadingZeroBits(await sha256(`${challenge}:${nonce}`)) >= bits;
}
