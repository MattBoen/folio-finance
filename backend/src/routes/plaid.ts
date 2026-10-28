import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { eq, and, isNull, notInArray, lt, count } from "drizzle-orm";
import { createHash } from "node:crypto";
import { decodeProtectedHeader, importJWK, jwtVerify } from "jose";
import { db } from "../db/client.js";
import { plaidItems, accounts } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";
import { plaid } from "../services/plaid-client.js";
import { encryptToken, decryptToken } from "../services/encryption.js";
import { syncItem, takeNetWorthSnapshot } from "../services/plaid-sync.js";
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
/** Where Plaid should send "new transactions" notices. Render sets RENDER_EXTERNAL_URL automatically. */
export function webhookUrl(): string | undefined {
  if (process.env.PLAID_WEBHOOK_URL) return process.env.PLAID_WEBHOOK_URL;
  const base = process.env.RENDER_EXTERNAL_URL;
  return base ? `${base.replace(/\/$/, "")}/plaid/webhook` : undefined;
}

router.post("/link/token", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  const body = (await c.req.json().catch(() => ({}))) as { item_id?: unknown };
  const webhook = webhookUrl();
  const common = {
    user: { client_user_id: userId },
    client_name: "Folio",
    country_codes: [CountryCode.Us],
    language: "en",
    ...(webhook ? { webhook } : {}),
    ...(process.env.PLAID_REDIRECT_URI ? { redirect_uri: process.env.PLAID_REDIRECT_URI } : {}),
  };

  // Update mode: the bank needs the user to sign in again. No products, just the item's access token.
  if (typeof body.item_id === "string") {
    const [item] = await db
      .select()
      .from(plaidItems)
      .where(and(eq(plaidItems.id, body.item_id), eq(plaidItems.userId, userId)));
    if (!item) return c.json({ error: "Not found" }, 404);
    const { data } = await plaid.linkTokenCreate({
      ...common,
      access_token: decryptToken(item.accessTokenEnc, item.accessTokenIv),
    });
    return c.json({ link_token: data.link_token, expiration: data.expiration });
  }

  const request = { ...common, products: [Products.Transactions] };
  try {
    // Best-effort extras: institutions that lack them still appear in Link.
    const { data } = await plaid.linkTokenCreate({
      ...request,
      optional_products: [Products.Investments, Products.Liabilities],
    });
    return c.json({ link_token: data.link_token, expiration: data.expiration });
  } catch (err) {
    // Plaid rejects the whole request when an optional product isn't enabled on the account.
    // Fall back to transactions only so banks can still be linked.
    const body = (err as {
      response?: { data?: { error_code?: string; error_message?: string; display_message?: string | null } };
    })?.response?.data;
    const text = `${body?.error_message ?? ""} ${body?.display_message ?? ""}`;
    const productNotEnabled =
      body?.error_code === "INVALID_PRODUCT" || /not enabled for|not authorized to access/i.test(text);
    if (!productNotEnabled) throw err;
    console.warn("[plaid] optional products not enabled, linking with transactions only:", body?.error_code, text.trim());
    const { data } = await plaid.linkTokenCreate(request);
    return c.json({ link_token: data.link_token, expiration: data.expiration });
  }
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
      // Plaid account ids the user chose to add. Anything else on the item is kept but hidden.
      account_ids: z.array(z.string()).optional(),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const { public_token, institution_id, institution_name, account_ids } = c.req.valid("json");

    const { data: exchanged } = await plaid.itemPublicTokenExchange({
      public_token,
    });

    // Linking the same bank twice would double-count every balance (and cost a second connection).
    if (institution_id) {
      const [existing] = await db
        .select({ id: plaidItems.id, name: plaidItems.institutionName })
        .from(plaidItems)
        .where(and(eq(plaidItems.userId, userId), eq(plaidItems.institutionId, institution_id)));
      if (existing) {
        await plaid.itemRemove({ access_token: exchanged.access_token }).catch(() => undefined);
        return c.json(
          {
            error: `${existing.name ?? institution_name ?? "That bank"} is already connected. To change which accounts Folio sees, disconnect it in Money > Accounts and connect it again.`,
            code: "DUPLICATE_ITEM",
          },
          409
        );
      }
    }

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

    // Import accounts + transactions now so they exist when the app reloads.
    // (The API runs without a job worker, so don't rely on the queue.)
    let synced = true;
    try {
      await syncItem(item.id, userId);
    } catch (err) {
      synced = false;
      console.error("[plaid] initial sync failed", err);
      if (boss) await boss.send("plaid-sync", { itemId: item.id, userId });
    }

    if (account_ids && account_ids.length > 0) {
      await db
        .update(accounts)
        .set({ isHidden: true, updatedAt: new Date() })
        .where(and(eq(accounts.plaidItemId, item.id), notInArray(accounts.plaidAccountId, account_ids)));
    }

    // Tell the app exactly what was imported so it can show the user.
    const imported = await db
      .select({
        id: accounts.id,
        name: accounts.name,
        type: accounts.type,
        subtype: accounts.subtype,
        mask: accounts.mask,
        balanceCurrent: accounts.balanceCurrent,
      })
      .from(accounts)
      .where(and(eq(accounts.plaidItemId, item.id), isNull(accounts.deletedAt), eq(accounts.isHidden, false)));

    return c.json({
      id: item.id,
      institution_name: item.institutionName,
      status: item.status,
      created_at: item.createdAt,
      synced,
      accounts: imported,
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
      lastSyncedAt: plaidItems.updatedAt,
      accountCount: count(accounts.id),
    })
    .from(plaidItems)
    .leftJoin(accounts, and(eq(accounts.plaidItemId, plaidItems.id), isNull(accounts.deletedAt)))
    .where(eq(plaidItems.userId, userId))
    .groupBy(plaidItems.id);

  return c.json({ items });
});

// ── Sync everything for this user (app open / pull to refresh) ──────────────
const SYNC_EVERY_MS = 10 * 60_000;

router.post("/sync", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  const force = c.req.query("force") === "1";
  const stale = await db
    .select({ id: plaidItems.id })
    .from(plaidItems)
    .where(
      and(
        eq(plaidItems.userId, userId),
        eq(plaidItems.status, "active"),
        ...(force ? [] : [lt(plaidItems.updatedAt, new Date(Date.now() - SYNC_EVERY_MS))])
      )
    );

  let synced = 0;
  let needsAttention = 0;
  for (const item of stale) {
    try {
      await syncItem(item.id, userId);
      synced++;
    } catch (err) {
      const code = (err as { response?: { data?: { error_code?: string } } })?.response?.data?.error_code;
      console.error("[plaid sync]", code ?? (err as Error).message);
      if (code === "ITEM_LOGIN_REQUIRED" || code === "PENDING_EXPIRATION") {
        needsAttention++;
        await db.update(plaidItems).set({ status: "login_required", updatedAt: new Date() }).where(eq(plaidItems.id, item.id));
      }
    }
  }
  return c.json({ synced, needsAttention });
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
    await takeNetWorthSnapshot(userId);
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

      if (item) {
        if (boss) {
          await boss.send("plaid-sync", { itemId: item.id, userId: item.userId });
        } else {
          // No worker on this deployment: sync in the background, reply to Plaid right away.
          syncItem(item.id, item.userId).catch((err) => console.error("[plaid webhook] sync failed", err));
        }
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

  // Run inline for immediate feedback; for scale, enqueue instead.
  // Also called after the user signs in again (update mode), so mark the item healthy first.
  await db.update(plaidItems).set({ status: "active" }).where(eq(plaidItems.id, itemId));
  await syncItem(itemId, userId);
  return c.json({ ok: true });
});

export { router as plaid };
