import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { eq, and } from "drizzle-orm";
import { createHash } from "node:crypto";
import { decodeProtectedHeader, importJWK, jwtVerify } from "jose";
import { db } from "../db/client.js";
import { plaidItems } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";
import { plaid } from "../services/plaid-client.js";
import { encryptToken } from "../services/encryption.js";
import { syncItem } from "../services/plaid-sync.js";
import { Products, CountryCode } from "plaid";
import PgBoss from "pg-boss";

// ── Webhook signature verification ────────────────────────────────────────────
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const keyCache = new Map<string, any>();

async function verifyPlaidWebhook(rawBody: string, token: string): Promise<boolean> {
  try {
    const header = decodeProtectedHeader(token);
    const kid = header.kid as string;
    if (!kid) return false;

    if (!keyCache.has(kid)) {
      const { data } = await plaid.webhookVerificationKeyGet({ key_id: kid });
      keyCache.set(kid, data.key);
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const publicKey = await importJWK(keyCache.get(kid) as any);
    const { payload } = await jwtVerify(token, publicKey, { algorithms: ["ES256"] });

    // Verify the SHA-256 of the raw body matches the claim
    const bodyHash = createHash("sha256").update(rawBody).digest("hex");
    if ((payload as any).request_body_sha256 !== bodyHash) return false;

    // Reject tokens older than 5 minutes
    const iat = payload.iat ?? 0;
    if (Math.floor(Date.now() / 1000) - iat > 300) return false;

    return true;
  } catch {
    return false;
  }
}

// Boss is injected so tests can pass a stub; production passes a live instance.
let boss: PgBoss | null = null;
export function setBoss(b: PgBoss) { boss = b; }

const router = new Hono();

// ── Create link token ────────────────────────────────────────────────────────
router.post("/link/token", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  const { data } = await plaid.linkTokenCreate({
    user: { client_user_id: userId },
    client_name: "Folio Finance",
    products: [Products.Transactions],
    additional_consented_products: [Products.Liabilities],
    country_codes: [CountryCode.Us],
    language: "en",
    webhook: process.env.PLAID_WEBHOOK_URL,
  });
  return c.json({ link_token: data.link_token, expiration: data.expiration });
});

// ── Exchange public token ─────────────────────────────────────────────────────
router.post(
  "/exchange",
  requireAuth,
  zValidator(
    "json",
    z.object({
      public_token: z.string(),
      institution_id: z.string().optional(),
      institution_name: z.string().optional(),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const { public_token, institution_id, institution_name } = c.req.valid("json");

    const { data: exchanged } = await plaid.itemPublicTokenExchange({
      public_token,
    });

    const { enc, iv } = encryptToken(exchanged.access_token);

    const [item] = await db
      .insert(plaidItems)
      .values({
        userId,
        accessTokenEnc: enc,
        accessTokenIv: iv,
        itemId: exchanged.item_id,
        institutionId: institution_id ?? null,
        institutionName: institution_name ?? null,
        status: "active",
      })
      .returning();

    // Enqueue initial sync
    if (boss) {
      await boss.send("plaid-sync", { itemId: item.id, userId });
    }

    return c.json({
      id: item.id,
      institution_name: item.institutionName,
      status: item.status,
      created_at: item.createdAt,
    });
  }
);

// ── List items ───────────────────────────────────────────────────────────────
router.get("/items", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  const items = await db
    .select({
      id: plaidItems.id,
      institutionName: plaidItems.institutionName,
      status: plaidItems.status,
      createdAt: plaidItems.createdAt,
    })
    .from(plaidItems)
    .where(eq(plaidItems.userId, userId));

  return c.json({ items });
});

// ── Remove item ──────────────────────────────────────────────────────────────
router.delete(
  "/items/:id",
  requireAuth,
  async (c) => {
    const { userId } = c.get("auth");
    const itemId = c.req.param("id");

    const [item] = await db
      .select()
      .from(plaidItems)
      .where(and(eq(plaidItems.id, itemId), eq(plaidItems.userId, userId)));

    if (!item) return c.json({ error: "Not found" }, 404);

    try {
      const accessToken = (await import("../services/encryption.js")).decryptToken(
        item.accessTokenEnc,
        item.accessTokenIv
      );
      await plaid.itemRemove({ access_token: accessToken });
    } catch {
      // Continue with local deletion even if Plaid call fails
    }

    await db.delete(plaidItems).where(eq(plaidItems.id, itemId));
    return c.json({ ok: true });
  }
);

// ── Webhook ───────────────────────────────────────────────────────────────────
router.post("/webhook", async (c) => {
  const rawBody = await c.req.text();
  const signatureToken = c.req.header("Plaid-Verification");

  if (!signatureToken) {
    return c.json({ error: "Missing Plaid-Verification header" }, 400);
  }

  const valid = await verifyPlaidWebhook(rawBody, signatureToken);
  if (!valid) {
    console.warn("[plaid webhook] invalid signature — rejected");
    return c.json({ error: "Invalid webhook signature" }, 401);
  }

  const body = JSON.parse(rawBody);
  const { webhook_type, webhook_code, item_id } = body;

  if (webhook_type === "TRANSACTIONS") {
    if (
      webhook_code === "SYNC_UPDATES_AVAILABLE" ||
      webhook_code === "DEFAULT_UPDATE"
    ) {
      const [item] = await db
        .select({ id: plaidItems.id, userId: plaidItems.userId })
        .from(plaidItems)
        .where(eq(plaidItems.itemId, item_id));

      if (item && boss) {
        await boss.send("plaid-sync", { itemId: item.id, userId: item.userId });
      }
    }
  }

  if (webhook_type === "ITEM" && webhook_code === "ERROR") {
    await db
      .update(plaidItems)
      .set({ status: "login_required", updatedAt: new Date() })
      .where(eq(plaidItems.itemId, item_id));
  }

  return c.json({ ok: true });
});

// ── Manual refresh ───────────────────────────────────────────────────────────
router.post("/items/:id/refresh", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  const itemId = c.req.param("id");

  const [item] = await db
    .select({ id: plaidItems.id })
    .from(plaidItems)
    .where(and(eq(plaidItems.id, itemId), eq(plaidItems.userId, userId)));

  if (!item) return c.json({ error: "Not found" }, 404);

  // Run inline for immediate feedback; for scale, enqueue instead
  await syncItem(itemId, userId);
  return c.json({ ok: true });
});

export { router as plaid };
