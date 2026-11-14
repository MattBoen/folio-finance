// Forgot-password codes. A code is a 6-digit number computed from the account's email, its current password hash and a
// 15-minute window, signed with a server secret. Nothing is stored: changing the password changes the hash, which kills
// every code that was sent before, so each code works once. A code is accepted for its own window and the one after
// (15 to 30 minutes).
import { createHmac, timingSafeEqual } from "node:crypto";

export const WINDOW_MS = 15 * 60_000;
const SECRET = () => `${process.env.JWT_REFRESH_SECRET ?? "dev-only"}:password-reset`;

export function resetCode(email: string, passwordHash: string, windowIndex: number): string {
  const mac = createHmac("sha256", SECRET()).update(`${email}|${passwordHash}|${windowIndex}`).digest();
  const n = mac.readUInt32BE(0) % 1_000_000;
  return String(n).padStart(6, "0");
}

export function currentCode(email: string, passwordHash: string, now = Date.now()): string {
  return resetCode(email, passwordHash, Math.floor(now / WINDOW_MS));
}

export function verifyResetCode(email: string, passwordHash: string, code: string, now = Date.now()): boolean {
  if (!/^\d{6}$/.test(code)) return false;
  const w = Math.floor(now / WINDOW_MS);
  const given = Buffer.from(code);
  return [w, w - 1].some((i) => {
    const want = Buffer.from(resetCode(email, passwordHash, i));
    return want.length === given.length && timingSafeEqual(want, given);
  });
}

/**
 * Stops anyone guessing the 1,000,000 possible codes: at most `max` tries per email per `windowMs`, and at most
 * `maxSends` emails per address per hour so the form can't be used to spam someone's inbox. Kept in memory, like the
 * other rate limits (it resets when the server restarts, which only makes it more forgiving, not less safe, because
 * the codes themselves expire).
 */
export class AttemptLimiter {
  private hits = new Map<string, number[]>();
  constructor(private max: number, private windowMs: number) {}
  /** Records a try and says whether it is allowed. */
  take(key: string, now = Date.now()): boolean {
    const recent = (this.hits.get(key) ?? []).filter((t) => now - t < this.windowMs);
    if (recent.length >= this.max) { this.hits.set(key, recent); return false; }
    recent.push(now);
    this.hits.set(key, recent);
    return true;
  }
  clear(key: string) { this.hits.delete(key); }
}

/** Sends the code by email through Resend. Returns false (and logs) when email isn't set up, so the app never breaks. */
export async function sendResetEmail(to: string, code: string): Promise<boolean> {
  const key = process.env.RESEND_API_KEY, from = process.env.MAIL_FROM;
  if (!key || !from) {
    console.warn("Password reset requested but RESEND_API_KEY / MAIL_FROM are not set, so no email was sent.");
    return false;
  }
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from,
        to,
        subject: `Your Folio code is ${code}`,
        text:
          `Your Folio password reset code is ${code}.\n\n` +
          `It works for 15 minutes. If you didn't ask to reset your password, ignore this email: nothing has changed and your account is safe.\n\n` +
          `Folio will never ask you for this code by phone, text or email.`,
      }),
    });
    if (!res.ok) console.error("Reset email failed:", res.status);
    return res.ok;
  } catch (err) {
    console.error("Reset email error:", (err as Error).message);
    return false;
  }
}
