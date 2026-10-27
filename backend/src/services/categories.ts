// Folio's single, small category vocabulary. Raw names come from Plaid (via plaid-sync's friendly names),
// the seeded system categories, or whatever a user typed; everything is folded into these.
export const FOLIO_CATEGORIES = [
  "Groceries", "Dining", "Transport", "Shopping", "Bills & Utilities", "Home",
  "Entertainment", "Health", "Travel", "Subscriptions", "Income", "Transfer", "Other",
] as const;
export type FolioCategory = (typeof FOLIO_CATEGORIES)[number];

// Categories that are not spending (and not budgetable).
export const NON_SPENDING: ReadonlySet<string> = new Set(["Income", "Transfer"]);

const RULES: [RegExp, FolioCategory][] = [
  [/grocer|supermarket/, "Groceries"],
  [/dining|restaurant|coffee|cafe|fast food|food|drink|alcohol|bar\b/, "Dining"],
  [/transport|gas\b|fuel|parking|rideshare|transit|taxi|auto\b|car rental/, "Transport"],
  [/subscription|streaming|software|membership/, "Subscriptions"],
  [/bill|utilit|rent|phone|internet|insurance|electric|water|cable/, "Bills & Utilities"],
  [/home|improvement|furniture|hardware|garden/, "Home"],
  [/entertain|movie|music|game|sport|recreation/, "Entertainment"],
  [/health|medical|doctor|pharmac|fitness|gym|personal care|haircut|spa\b|dental/, "Health"],
  [/travel|flight|airline|hotel|lodging/, "Travel"],
  [/income|payroll|paycheck|salary|wage|deposit|dividend|interest earned/, "Income"],
  [/transfer|loan payment|credit card payment|payment|withdrawal/, "Transfer"],
  [/shop|merchandise|clothing|electronics|amazon|general/, "Shopping"],
];

function key(raw: string): string {
  return raw.toLowerCase().replace(/_/g, " ").trim();
}

export function normalizeCategory(raw: string | null | undefined): FolioCategory {
  if (!raw) return "Other";
  const exact = FOLIO_CATEGORIES.find((c) => c.toLowerCase() === key(raw));
  if (exact) return exact;
  const k = key(raw);
  for (const [re, cat] of RULES) if (re.test(k)) return cat;
  return "Other";
}

// Manual or synced rows can carry a card/loan payment that must not count as spending (the card's own
// purchases already do). Plaid usually marks these Transfer; this catches the rest by description.
const PAYMENT_RE = /\b(autopay|auto pay|payment thank you|online payment|credit card payment|card payment|payment to|epayment|ach pmt|pymt)\b/i;
export function isCardPayment(name: string): boolean {
  return PAYMENT_RE.test(name);
}
