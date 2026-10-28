import { describe, it, expect, vi, beforeEach } from "vitest";
import bcrypt from "bcryptjs";
import { Hono } from "hono";

const state = { passwordHash: null as string | null, found: true };
const hardDeleteUser = vi.fn(async () => {});
const removePlaidItems = vi.fn(async () => ({ removed: 0, failed: 0 }));

vi.mock("../src/db/client.js", () => ({
  db: {
    select: () => ({
      from: () => ({
        where: async () => (state.found ? [{ id: "u1", passwordHash: state.passwordHash }] : []),
      }),
    }),
  },
}));
vi.mock("../src/middleware/auth.js", () => ({
  requireAuth: async (c: any, next: any) => { c.set("auth", { userId: "u1", plan: "free" }); await next(); },
}));
vi.mock("../src/services/account-deletion.js", () => ({ hardDeleteUser, removePlaidItems }));

const { accountRouter } = await import("../src/routes/account.js");
const app = new Hono().route("/account", accountRouter);
const del = (body?: unknown) =>
  app.request("/account", { method: "DELETE", headers: { "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });

describe("DELETE /account", () => {
  beforeEach(async () => {
    hardDeleteUser.mockClear(); removePlaidItems.mockClear();
    state.found = true;
    state.passwordHash = await bcrypt.hash("correct-horse-1", 4);
  });

  it("requires the password for password accounts", async () => {
    const res = await del({});
    expect(res.status).toBe(400);
    expect(hardDeleteUser).not.toHaveBeenCalled();
  });

  it("rejects a wrong password and deletes nothing", async () => {
    const res = await del({ password: "nope-nope-1" });
    expect(res.status).toBe(401);
    expect((await res.json()).error).toBe("That password doesn't match.");
    expect(removePlaidItems).not.toHaveBeenCalled();
    expect(hardDeleteUser).not.toHaveBeenCalled();
  });

  it("removes Plaid items first, then deletes the user, on the right password", async () => {
    const res = await del({ password: "correct-horse-1" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    expect(removePlaidItems).toHaveBeenCalledWith("u1");
    expect(hardDeleteUser).toHaveBeenCalledWith("u1");
    expect(removePlaidItems.mock.invocationCallOrder[0]).toBeLessThan(hardDeleteUser.mock.invocationCallOrder[0]);
  });

  it("lets Apple-only accounts (no password hash) delete without a password", async () => {
    state.passwordHash = null;
    const res = await del();
    expect(res.status).toBe(200);
    expect(hardDeleteUser).toHaveBeenCalledWith("u1");
  });

  it("returns 404 if the user no longer exists", async () => {
    state.found = false;
    expect((await del({ password: "x" })).status).toBe(404);
  });
});
