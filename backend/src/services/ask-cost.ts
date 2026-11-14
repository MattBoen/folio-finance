// Pure money rules for Ask Folio (no database), so the engine and tests can use them directly.
export const DEFAULT_MODEL = "claude-haiku-5-5";
const INPUT_PER_M = 0.1; // dollars per million input tokens (Haiku 5.5)
const OUTPUT_PER_M = 0.5; // dollars per million output tokens

export const QUESTION_LIMIT_USD = 0.1;

export interface Usage { input_tokens?: number; output_tokens?: number; cache_read_input_tokens?: number; cache_creation_input_tokens?: number }

/** Dollars for one response. Cached tokens are billed at full price here so the limit trips early. */
export function costOf(u: Usage | undefined | null): number {
  if (!u) return 0;
  const input = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + 1.25 * (u.cache_creation_input_tokens ?? 0);
  return (input * INPUT_PER_M + (u.output_tokens ?? 0) * OUTPUT_PER_M) / 1_000_000;
}

/** Only Haiku can ever be used. A bad ASK_MODEL value falls back to the default instead of picking Opus or Sonnet. */
export function askModel(env: string | undefined = process.env.ASK_MODEL): string {
  return env && /haiku/i.test(env) ? env : DEFAULT_MODEL;
}

const num = (v: string | undefined, fallback: number) => {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
};
/** Dollars one user can spend per month. */
export const userMonthlyLimit = () => num(process.env.ASK_USER_MONTHLY_LIMIT, 0.5);
/** Dollars the whole app can spend per month (the kill switch). 0 turns Ask off for everyone. */
export const globalMonthlyLimit = () => num(process.env.ASK_GLOBAL_MONTHLY_LIMIT, 10);

