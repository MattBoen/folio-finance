import { Hono } from "hono";
import { z } from "zod";
import bcrypt from "bcryptjs";
import { eq } from "drizzle-orm";
import { db } from "../db/client.js";
import { users } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";
import { rateLimit } from "../middleware/rate-limit.js";
import { hardDeleteUser, removePlaidItems } from "../services/account-deletion.js";

const accountRouter = new Hono();

const bodySchema = z.object({ password: z.string().max(128).optional() });

// DELETE /account: permanent deletion of the signed-in user and all of their data.
accountRouter.delete("/", requireAuth, rateLimit({ max: 5, windowMs: 60_000 }), async (c) => {
  const { userId } = c.get("auth");
  const parsed = bodySchema.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: "Invalid request" }, 400);

  const [user] = await db.select({ id: users.id, passwordHash: users.passwordHash }).from(users).where(eq(users.id, userId));
  if (!user) return c.json({ error: "Not found" }, 404);

  if (user.passwordHash) {
    const { password } = parsed.data;
    if (!password) return c.json({ error: "Enter your password to delete your account." }, 400);
    if (!(await bcrypt.compare(password, user.passwordHash))) {
      return c.json({ error: "That password doesn't match." }, 401);
    }
  }

  await removePlaidItems(userId);
  await hardDeleteUser(userId);
  return c.json({ ok: true });
});

export { accountRouter };
