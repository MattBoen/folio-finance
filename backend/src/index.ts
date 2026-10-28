import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { secureHeaders } from "hono/secure-headers";
import { logger } from "hono/logger";
import { auth } from "./routes/auth.js";
import { plaid } from "./routes/plaid.js";
import { accountsRouter } from "./routes/accounts.js";
import { transactionsRouter } from "./routes/transactions.js";
import { insightsRouter } from "./routes/insights.js";
import { budgetsRouter } from "./routes/budgets.js";
import { settingsRouter } from "./routes/settings.js";
import { vehiclesRouter } from "./routes/vehicles.js";
import { accountRouter } from "./routes/account.js";
import { legal } from "./routes/legal.js";
import { askRouter } from "./routes/ask.js";
import { billingRouter } from "./routes/billing.js";
import { errorHandler } from "./middleware/error-handler.js";

const app = new Hono();

app.use("*", secureHeaders());
app.use("*", cors({ origin: process.env.ALLOWED_ORIGINS?.split(",") ?? [] }));
app.use("*", logger());

app.get("/health", (c) => c.json({ ok: true, ts: new Date().toISOString() }));

app.route("/auth", auth);
app.route("/plaid", plaid);
app.route("/accounts", accountsRouter);
app.route("/transactions", transactionsRouter);
app.route("/insights", insightsRouter);
app.route("/budgets", budgetsRouter);
app.route("/settings", settingsRouter);
app.route("/vehicles", vehiclesRouter);
app.route("/account", accountRouter);
app.route("/ask", askRouter);
app.route("/billing", billingRouter);
app.route("/", legal);

app.onError(errorHandler);

// Only bind to a port when run directly, not when imported by tests
if (process.env.NODE_ENV !== "test") {
  const PORT = Number(process.env.PORT ?? 4000); // 3000 belongs to the personal Financial Picture app on this Mac
  serve({ fetch: app.fetch, port: PORT }, () => {
    console.log(`Server running on port ${PORT}`);
  });
}

export { app };
