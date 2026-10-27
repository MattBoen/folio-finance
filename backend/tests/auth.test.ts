import { describe, it, expect, beforeEach } from "vitest";
import { testClient } from "hono/testing";
import { app } from "../src/index.js";
import { db, pool } from "../src/db/client.js";
import { users, refreshTokens } from "../src/db/schema.js";
import { eq } from "drizzle-orm";

const client = testClient(app);

async function cleanup(email: string) {
  const [u] = await db.select().from(users).where(eq(users.email, email));
  if (u) {
    await db.delete(refreshTokens).where(eq(refreshTokens.userId, u.id));
    await db.delete(users).where(eq(users.id, u.id));
  }
}

describe("Auth: register + login", () => {
  const email = `test-${Date.now()}@example.com`;
  const password = "S3cure!Pass";

  beforeEach(() => cleanup(email));

  it("registers a new user and returns token pair", async () => {
    const res = await client.auth.register.$post({ json: { email, password } });
    expect(res.status).toBe(201);
    const body = await res.json() as any;
    expect(body.accessToken).toBeTruthy();
    expect(body.refreshToken).toBeTruthy();
  });

  it("rejects duplicate email", async () => {
    await client.auth.register.$post({ json: { email, password } });
    const res = await client.auth.register.$post({ json: { email, password } });
    expect(res.status).toBe(409);
  });

  it("logs in with correct credentials", async () => {
    await client.auth.register.$post({ json: { email, password } });
    const res = await client.auth.login.$post({ json: { email, password } });
    expect(res.status).toBe(200);
    const body = await res.json() as any;
    expect(body.accessToken).toBeTruthy();
  });

  it("rejects wrong password", async () => {
    await client.auth.register.$post({ json: { email, password } });
    const res = await client.auth.login.$post({ json: { email, password: "wrong" } });
    expect(res.status).toBe(401);
  });
});

describe("Auth: refresh token rotation", () => {
  const email = `refresh-${Date.now()}@example.com`;
  const password = "S3cure!Pass";

  beforeEach(() => cleanup(email));

  it("issues new tokens on refresh and invalidates old refresh token", async () => {
    const reg = await client.auth.register.$post({ json: { email, password } });
    const { refreshToken: rt1 } = await reg.json() as any;

    const res1 = await client.auth.refresh.$post({ json: { refresh_token: rt1 } });
    expect(res1.status).toBe(200);
    const { accessToken: at2, refreshToken: rt2 } = await res1.json() as any;
    expect(rt2).not.toBe(rt1);

    // Old token is now invalid
    const res2 = await client.auth.refresh.$post({ json: { refresh_token: rt1 } });
    expect(res2.status).toBe(401);
  });
});

describe("Auth: protected route", () => {
  const email = `prot-${Date.now()}@example.com`;
  const password = "S3cure!Pass";

  beforeEach(() => cleanup(email));

  it("returns 401 without token", async () => {
    const res = await client.auth.me.$get();
    expect(res.status).toBe(401);
  });

  it("returns entitlements with valid token", async () => {
    const reg = await client.auth.register.$post({ json: { email, password } });
    const { accessToken } = await reg.json() as any;

    const res = await client.auth.me.$get({}, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    expect(res.status).toBe(200);
    const body = await res.json() as any;
    expect(body.entitlements.plan).toBe("free");
  });
});
