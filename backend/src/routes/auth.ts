import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import bcrypt from "bcryptjs";

// bcrypt cost 10 is the standard minimum; 12 takes seconds on Render's small free CPU. Raise it when the server is upgraded.
const BCRYPT_COST = Number(process.env.BCRYPT_COST ?? 10);
import { eq, and, gt, isNull, lt, or } from "drizzle-orm";
import { db } from "../db/client.js";
import { users, refreshTokens } from "../db/schema.js";
import {
  signAccessToken,
  generateRefreshToken,
  hashRefreshToken,
} from "../services/jwt.js";
import { verifyAppleIdentityToken } from "../services/apple-auth.js";
import { getEntitlements } from "../services/entitlements.js";
import { requireAuth } from "../middleware/auth.js";
import { rateLimit } from "../middleware/rate-limit.js";

const auth = new Hono();

const emailField = z.string().trim().toLowerCase().email();

const registerSchema = z.object({
  email: emailField,
  password: z.string().min(8).max(128),
});

const loginSchema = z.object({
  email: emailField,
  password: z.string(),
});

const appleSchema = z.object({
  identityToken: z.string(),
  fullName: z.string().optional(),
});

const refreshSchema = z.object({
  refresh_token: z.string(),
});

/** A refresh token just swapped for a new one still works this long, so two screens refreshing together,
 *  or a reply lost on a weak signal, doesn't sign the user out. */
const ROTATION_GRACE_MS = 30_000;

/** Retention: expired or revoked sessions are deleted whenever a user signs in or refreshes. */
async function purgeDeadSessions(userId: string) {
  const graceStart = new Date(Date.now() - ROTATION_GRACE_MS);
  await db
    .delete(refreshTokens)
    .where(and(eq(refreshTokens.userId, userId), or(lt(refreshTokens.expiresAt, new Date()), lt(refreshTokens.revokedAt, graceStart))));
}

async function issueTokenPair(userId: string, plan: string) {
  await purgeDeadSessions(userId);
  const accessToken = await signAccessToken(userId, plan);
  const { raw, hash, expiresAt } = generateRefreshToken();
  await db.insert(refreshTokens).values({ userId, tokenHash: hash, expiresAt });
  return { accessToken, refreshToken: raw };
}

// POST /auth/check: lets the app offer one "Continue" button that signs in or creates an account
auth.post(
  "/check",
  rateLimit({ max: 20, windowMs: 60_000 }),
  zValidator("json", z.object({ email: emailField })),
  async (c) => {
    const { email } = c.req.valid("json");
    const [existing] = await db
      .select({ id: users.id })
      .from(users)
      .where(and(eq(users.email, email), isNull(users.deletedAt)));
    return c.json({ exists: Boolean(existing) });
  }
);

// POST /auth/register
auth.post(
  "/register",
  rateLimit({ max: 10, windowMs: 60_000 }),
  zValidator("json", registerSchema),
  async (c) => {
    const { email, password } = c.req.valid("json");

    const [existing] = await db
      .select({ id: users.id })
      .from(users)
      .where(and(eq(users.email, email), isNull(users.deletedAt)));

    if (existing) return c.json({ error: "Email already registered" }, 409);

    const passwordHash = await bcrypt.hash(password, BCRYPT_COST);
    let user: { id: string; plan: string };
    try {
      [user] = await db
        .insert(users)
        .values({ email, passwordHash })
        .returning({ id: users.id, plan: users.plan });
    } catch (err) {
      // Two sign-ups racing on the same email: the unique index decides the winner.
      if ((err as { code?: string }).code === "23505") return c.json({ error: "Email already registered" }, 409);
      throw err;
    }

    const tokens = await issueTokenPair(user.id, user.plan);
    return c.json(tokens, 201);
  }
);

// POST /auth/login
auth.post(
  "/login",
  rateLimit({ max: 10, windowMs: 60_000 }),
  zValidator("json", loginSchema),
  async (c) => {
    const { email, password } = c.req.valid("json");

    const [user] = await db
      .select()
      .from(users)
      .where(and(eq(users.email, email), isNull(users.deletedAt)));

    if (!user || !user.passwordHash) {
      return c.json({ error: "Invalid credentials" }, 401);
    }

    const valid = await bcrypt.compare(password, user.passwordHash);
    if (!valid) return c.json({ error: "Invalid credentials" }, 401);

    // Older accounts were hashed at a heavier setting that is very slow on the small free server: move them to the lighter one.
    if (bcrypt.getRounds(user.passwordHash) > BCRYPT_COST) {
      await db.update(users).set({ passwordHash: await bcrypt.hash(password, BCRYPT_COST) }).where(eq(users.id, user.id));
    }

    const tokens = await issueTokenPair(user.id, user.plan);
    return c.json(tokens);
  }
);

// POST /auth/apple
auth.post(
  "/apple",
  rateLimit({ max: 10, windowMs: 60_000 }),
  zValidator("json", appleSchema),
  async (c) => {
    const { identityToken, fullName } = c.req.valid("json");

    let claims;
    try {
      claims = await verifyAppleIdentityToken(identityToken);
    } catch {
      return c.json({ error: "Invalid Apple identity token" }, 401);
    }

    let [user] = await db
      .select()
      .from(users)
      .where(and(eq(users.appleSub, claims.sub), isNull(users.deletedAt)));

    if (!user) {
      [user] = await db
        .insert(users)
        .values({ appleSub: claims.sub, email: claims.email })
        .returning();
    }

    const tokens = await issueTokenPair(user.id, user.plan);
    return c.json(tokens);
  }
);

// POST /auth/refresh
auth.post(
  "/refresh",
  rateLimit({ max: 30, windowMs: 60_000 }),
  zValidator("json", refreshSchema),
  async (c) => {
    const { refresh_token: raw } = c.req.valid("json");
    const hash = hashRefreshToken(raw);

    const [token] = await db
      .select()
      .from(refreshTokens)
      .where(and(eq(refreshTokens.tokenHash, hash), gt(refreshTokens.expiresAt, new Date())));

    if (!token) return c.json({ error: "Invalid or expired refresh token" }, 401);

    if (token.revokedAt) {
      // Only a token swapped moments ago by a refresh counts. Signing out revokes every session,
      // so then no live session remains and this is still refused.
      const recent = Date.now() - token.revokedAt.getTime() < ROTATION_GRACE_MS;
      const [live] = await db
        .select({ id: refreshTokens.id })
        .from(refreshTokens)
        .where(and(eq(refreshTokens.userId, token.userId), isNull(refreshTokens.revokedAt), gt(refreshTokens.expiresAt, new Date())))
        .limit(1);
      if (!recent || !live) return c.json({ error: "Invalid or expired refresh token" }, 401);
    } else {
      // Rotate: revoke old, issue new pair
      await db
        .update(refreshTokens)
        .set({ revokedAt: new Date() })
        .where(eq(refreshTokens.id, token.id));
    }

    const [user] = await db
      .select({ id: users.id, plan: users.plan })
      .from(users)
      .where(eq(users.id, token.userId));

    if (!user) return c.json({ error: "User not found" }, 401);

    const tokens = await issueTokenPair(user.id, user.plan);
    return c.json(tokens);
  }
);

// DELETE /auth/session (logout)
auth.delete("/session", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  // Revoke all refresh tokens for this user (logout all devices)
  await db
    .update(refreshTokens)
    .set({ revokedAt: new Date() })
    .where(and(eq(refreshTokens.userId, userId), isNull(refreshTokens.revokedAt)));

  return c.body(null, 204);
});

// GET /auth/export (data export)
auth.get("/export", requireAuth, async (c) => {
  const { userId } = c.get("auth");

  const [userData] = await db
    .select({ id: users.id, email: users.email, plan: users.plan, createdAt: users.createdAt })
    .from(users)
    .where(eq(users.id, userId));

  return c.json({
    exportedAt: new Date().toISOString(),
    user: userData,
    message: "Full transaction/account export will be implemented in milestone (g).",
  });
});

// GET /auth/me — entitlements
auth.get("/me", requireAuth, async (c) => {
  const { userId, plan } = c.get("auth");
  const entitlements = getEntitlements(plan as "free" | "pro");
  return c.json({ userId, entitlements });
});

export { auth };
