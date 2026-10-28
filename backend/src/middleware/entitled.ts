import { createMiddleware } from "hono/factory";
import { isEntitled } from "../services/billing.js";

/** Blocks the costly features (bank linking, Ask) for people without a subscription, once billing is switched on. */
export const requireEntitled = createMiddleware(async (c, next) => {
  const { userId } = c.get("auth");
  if (!(await isEntitled(userId))) return c.json({ error: "Start your Folio subscription to use this.", code: "subscription_required" }, 402);
  await next();
});
