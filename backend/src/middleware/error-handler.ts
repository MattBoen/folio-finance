import type { Context } from "hono";

type PlaidErrorBody = {
  error_type?: string;
  error_code?: string;
  error_message?: string;
  display_message?: string | null;
};

function plaidBody(err: unknown): PlaidErrorBody | null {
  const data = (err as { response?: { data?: PlaidErrorBody } })?.response?.data;
  return data && typeof data === "object" && "error_code" in data ? data : null;
}

export function errorHandler(err: Error, c: Context) {
  const plaid = plaidBody(err);
  if (plaid) {
    console.error("[plaid-error]", plaid.error_type, plaid.error_code, plaid.error_message);
    const keysProblem =
      !process.env.PLAID_CLIENT_ID ||
      !process.env.PLAID_SECRET ||
      plaid.error_code === "INVALID_API_KEYS" ||
      plaid.error_code === "INVALID_CLIENT_ID";
    const message = keysProblem
      ? "Bank connections aren't set up on the server yet: the Plaid keys are missing or don't match PLAID_ENV."
      : plaid.display_message || `Plaid says: ${plaid.error_message ?? plaid.error_code}`;
    return c.json({ error: message, code: plaid.error_code }, 502);
  }
  console.error("[error]", err.message);
  return c.json({ error: "Internal server error" }, 500);
}
