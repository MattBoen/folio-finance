import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import bcrypt from "bcryptjs";
import { eq, and, gt, isNull } from "drizzle-orm";
import { db } from "../db/client.js";
import { users, refreshTokens, auditLog } from "../db/schema.js";
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

async function issueTokenPair(userId: string, plan: string) {
  const accessToken = await signAccessToken(userId, plan);
  const { raw, hash, expiresAt } = generateRefreshToken();
  await db.insert(refreshTokens).values({ userId, tokenHash: hash, expiresAt });
  return { accessToken, refreshToken: raw };
}

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

    const passwordHash = await bcrypt.hash(password, 12);
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
      .where(
        and(
          eq(refreshTokens.tokenHash, hash),
          isNull(refreshTokens.revokedAt),
          gt(refreshTokens.expiresAt, new Date())
        )
      );

    if (!token) return c.json({ error: "Invalid or expired refresh token" }, 401);

    // Rotate: revoke old, issue new pair
    await db
      .update(refreshTokens)
      .set({ revokedAt: new Date() })
      .where(eq(refreshTokens.id, token.id));

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

// DELETE /auth/account (GDPR account deletion)
auth.delete("/account", requireAuth, async (c) => {
  const { userId } = c.get("auth");

  await db
    .update(users)
    .set({ deletedAt: new Date() })
    .where(eq(users.id, userId));

  await db
    .update(refreshTokens)
    .set({ revokedAt: new Date() })
    .where(eq(refreshTokens.userId, userId));

  await db.insert(auditLog).values({
    userId,
    action: "account_deleted",
    resourceType: "user",
    resourceId: userId,
  });

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
