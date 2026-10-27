export type Plan = "free" | "pro";

export interface Entitlements {
  plan: Plan;
  maxAccounts: number;
  budgets: boolean;
  widgets: boolean;
  spending: boolean;
}

export function getEntitlements(plan: Plan): Entitlements {
  // Phase 1: everyone is free. Entitlement checks exist for Phase 2 flip.
  const base: Entitlements = {
    plan,
    maxAccounts: 10,
    budgets: true,
    widgets: true,
    spending: true,
  };
  return base;
}
