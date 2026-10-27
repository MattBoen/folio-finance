import { createMiddleware } from "hono/factory";
import { verifyAccessToken } from "../services/jwt.js";

export interface AuthContext {
  userId: string;
  plan: string;
}

declare module "hono" {
  interface ContextVariableMap {
    auth: AuthContext;
  }
}

export const requireAuth = createMiddleware(async (c, next) => {
  const header = c.req.header("Authorization");
  if (!header?.startsWith("Bearer ")) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  const token = header.slice(7);
  try {
    const payload = await verifyAccessToken(token);
    c.set("auth", { userId: payload.sub!, plan: payload.plan });
    await next();
  } catch {
    return c.json({ error: "Unauthorized" }, 401);
  }
});
