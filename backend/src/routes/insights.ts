import { Hono } from "hono";
import { requireAuth } from "../middleware/auth.js";
import { computeInsightsForUser } from "../services/insight-data.js";

const router = new Hono();

router.get("/", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  return c.json(await computeInsightsForUser(userId));
});

export { router as insightsRouter };
