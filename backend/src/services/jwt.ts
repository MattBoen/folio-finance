import { SignJWT, jwtVerify, type JWTPayload } from "jose";
import { createHash, randomBytes } from "crypto";

const ACCESS_SECRET = new TextEncoder().encode(process.env.JWT_ACCESS_SECRET!);
const REFRESH_SECRET = new TextEncoder().encode(process.env.JWT_REFRESH_SECRET!);

const ACCESS_TTL = "15m";
const REFRESH_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

export interface AccessPayload extends JWTPayload {
  sub: string;  // userId
  plan: string;
}

export async function signAccessToken(userId: string, plan: string): Promise<string> {
  return new SignJWT({ plan })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(ACCESS_TTL)
    .sign(ACCESS_SECRET);
}

export async function verifyAccessToken(token: string): Promise<AccessPayload> {
  const { payload } = await jwtVerify(token, ACCESS_SECRET);
  return payload as AccessPayload;
}

export function generateRefreshToken(): { raw: string; hash: string; expiresAt: Date } {
  const raw = randomBytes(40).toString("hex");
  const hash = createHash("sha256").update(raw).digest("hex");
  const expiresAt = new Date(Date.now() + REFRESH_TTL_MS);
  return { raw, hash, expiresAt };
}

export function hashRefreshToken(raw: string): string {
  return createHash("sha256").update(raw).digest("hex");
}
