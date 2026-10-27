import { createMiddleware } from "hono/factory";

// Simple in-process token bucket. Replace with Redis in production for multi-instance.
const buckets = new Map<string, { tokens: number; lastRefill: number }>();

export function rateLimit(options: { max: number; windowMs: number }) {
  return createMiddleware(async (c, next) => {
    const ip = c.req.header("x-forwarded-for") ?? c.req.header("cf-connecting-ip") ?? "unknown";
    const key = `${c.req.path}:${ip}`;
    const now = Date.now();
    let bucket = buckets.get(key);

    if (!bucket || now - bucket.lastRefill > options.windowMs) {
      bucket = { tokens: options.max, lastRefill: now };
    }

    if (bucket.tokens <= 0) {
      return c.json({ error: "Too many requests" }, 429);
    }

    bucket.tokens--;
    buckets.set(key, bucket);
    await next();
  });
}
