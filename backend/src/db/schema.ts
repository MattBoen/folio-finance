import {
  pgTable,
  uuid,
  text,
  timestamp,
  numeric,
  boolean,
  integer,
  date,
  jsonb,
  index,
  uniqueIndex,
  primaryKey,
} from "drizzle-orm/pg-core";
import { relations } from "drizzle-orm";

// ─── Users ───────────────────────────────────────────────────────────────────

export const users = pgTable(
  "users",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    email: text("email").unique(),
    appleSub: text("apple_sub").unique(),
    passwordHash: text("password_hash"),
    plan: text("plan", { enum: ["free", "pro"] }).notNull().default("free"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
    deletedAt: timestamp("deleted_at", { withTimezone: true }),
  },
  (t) => [index("users_email_idx").on(t.email)]
);

export const refreshTokens = pgTable(
  "refresh_tokens",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    tokenHash: text("token_hash").notNull().unique(),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    revokedAt: timestamp("revoked_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index("refresh_tokens_user_idx").on(t.userId)]
);

// ─── Plaid ────────────────────────────────────────────────────────────────────

export const plaidItems = pgTable(
  "plaid_items",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    accessTokenEnc: text("access_token_enc").notNull(),
    accessTokenIv: text("access_token_iv").notNull(),
    itemId: text("item_id").notNull().unique(),
    institutionId: text("institution_id"),
    institutionName: text("institution_name"),
    status: text("status", { enum: ["active", "login_required", "error"] }).notNull().default("active"),
    transactionCursor: text("transaction_cursor"),
    // Set once the full history has been re-read to pick up purchase locations.
    placesBackfilled: boolean("places_backfilled").notNull().default(false),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index("plaid_items_user_idx").on(t.userId)]
);

// ─── Accounts ────────────────────────────────────────────────────────────────

export const accounts = pgTable(
  "accounts",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    plaidItemId: uuid("plaid_item_id").references(() => plaidItems.id, { onDelete: "cascade" }),
    plaidAccountId: text("plaid_account_id").unique(),
    name: text("name").notNull(),
    officialName: text("official_name"),
    type: text("type").notNull(),       // depository, credit, loan, investment
    subtype: text("subtype"),
    balanceCurrent: numeric("balance_current", { precision: 18, scale: 2 }),
    balanceAvailable: numeric("balance_available", { precision: 18, scale: 2 }),
    balanceLimit: numeric("balance_limit", { precision: 18, scale: 2 }),
    currency: text("currency").notNull().default("USD"),
    mask: text("mask"),
    isHidden: boolean("is_hidden").notNull().default(false),
    lastSyncedAt: timestamp("last_synced_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
    deletedAt: timestamp("deleted_at", { withTimezone: true }),
  },
  (t) => [index("accounts_user_idx").on(t.userId)]
);

// ─── Categories ───────────────────────────────────────────────────────────────

export const categories = pgTable("categories", {
  id: uuid("id").primaryKey().defaultRandom(),
  name: text("name").notNull(),
  parentId: uuid("parent_id"),
  isSystem: boolean("is_system").notNull().default(true),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

// ─── Transactions ─────────────────────────────────────────────────────────────

export const transactions = pgTable(
  "transactions",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    accountId: uuid("account_id").notNull().references(() => accounts.id, { onDelete: "cascade" }),
    plaidTransactionId: text("plaid_transaction_id").unique(),
    plaidPendingTransactionId: text("plaid_pending_transaction_id"),
    amount: numeric("amount", { precision: 18, scale: 2 }).notNull(),
    date: date("date").notNull(),
    name: text("name").notNull(),
    merchantName: text("merchant_name"),
    categoryId: uuid("category_id").references(() => categories.id),
    userCategoryId: uuid("user_category_id").references(() => categories.id),
    userName: text("user_name"),
    note: text("note"),
    isPending: boolean("is_pending").notNull().default(false),
    isExcluded: boolean("is_excluded").notNull().default(false),
    lat: numeric("lat", { precision: 10, scale: 7 }),
    lon: numeric("lon", { precision: 10, scale: 7 }),
    // Street address the bank reported for the purchase, when it did: "123 Main St, Minot, ND 58701".
    place: text("place"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
    deletedAt: timestamp("deleted_at", { withTimezone: true }),
  },
  (t) => [
    index("transactions_user_idx").on(t.userId),
    index("transactions_account_idx").on(t.accountId),
    index("transactions_date_idx").on(t.date),
  ]
);

// ─── Budgets ──────────────────────────────────────────────────────────────────

export const budgets = pgTable(
  "budgets",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    categoryId: uuid("category_id").references(() => categories.id),
    monthlyAmount: numeric("monthly_amount", { precision: 18, scale: 2 }).notNull(),
    isActive: boolean("is_active").notNull().default(true),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index("budgets_user_idx").on(t.userId),
    uniqueIndex("budgets_user_category_idx").on(t.userId, t.categoryId),
  ]
);

// ─── User settings (income override, profile) ─────────────────────────────────

export const userSettings = pgTable("user_settings", {
  userId: uuid("user_id").primaryKey().references(() => users.id, { onDelete: "cascade" }),
  incomeOverride: numeric("income_override", { precision: 18, scale: 2 }),
  birthYear: integer("birth_year"),
  askEnabled: boolean("ask_enabled").notNull().default(false),
  askConsentedAt: timestamp("ask_consented_at", { withTimezone: true }),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

// ─── Ask Folio (assistant): per-day usage counts and pending changes, never message text ───

export const askUsage = pgTable(
  "ask_usage",
  {
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    day: date("day").notNull(),
    count: integer("count").notNull().default(0),
  },
  (t) => [primaryKey({ columns: [t.userId, t.day] })]
);

export const askProposals = pgTable(
  "ask_proposals",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    payload: jsonb("payload").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    appliedAt: timestamp("applied_at", { withTimezone: true }),
    dismissedAt: timestamp("dismissed_at", { withTimezone: true }),
  },
  (t) => [index("ask_proposals_user_idx").on(t.userId)]
);

// ─── Vehicles (manual asset with VIN + mileage) ───────────────────────────────

export const vehicles = pgTable(
  "vehicles",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    accountId: uuid("account_id").notNull().references(() => accounts.id, { onDelete: "cascade" }),
    vin: text("vin").notNull(),
    year: integer("year").notNull(),
    make: text("make").notNull(),
    model: text("model").notNull(),
    trim: text("trim"),
    miles: integer("miles").notNull(),
    // Miles driven per year, so the value can keep up with the odometer between updates.
    annualMiles: integer("annual_miles"),
    valuationSource: text("valuation_source").notNull().default("estimate"),
    valuedAt: timestamp("valued_at", { withTimezone: true }).notNull().defaultNow(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index("vehicles_user_idx").on(t.userId),
    uniqueIndex("vehicles_account_idx").on(t.accountId),
  ]
);

// ─── Net-worth snapshots ──────────────────────────────────────────────────────

export const netWorthSnapshots = pgTable(
  "net_worth_snapshots",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    date: date("date").notNull(),
    totalAssets: numeric("total_assets", { precision: 18, scale: 2 }).notNull(),
    totalLiabilities: numeric("total_liabilities", { precision: 18, scale: 2 }).notNull(),
    netWorth: numeric("net_worth", { precision: 18, scale: 2 }).notNull(),
    // Investment-account total on that day; null for snapshots taken before this was tracked.
    invested: numeric("invested", { precision: 18, scale: 2 }),
    // True for days rebuilt from transaction history rather than recorded on the day.
    estimated: boolean("estimated").notNull().default(false),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index("snapshots_user_idx").on(t.userId),
    uniqueIndex("snapshots_user_date_idx").on(t.userId, t.date),
  ]
);

// ─── Device push tokens (skeleton) ───────────────────────────────────────────

export const devicePushTokens = pgTable(
  "device_push_tokens",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    token: text("token").notNull(),
    platform: text("platform", { enum: ["apns"] }).notNull().default("apns"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index("push_tokens_user_idx").on(t.userId),
    uniqueIndex("push_tokens_token_idx").on(t.token),
  ]
);

// ─── Audit log ────────────────────────────────────────────────────────────────

export const auditLog = pgTable(
  "audit_log",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").references(() => users.id, { onDelete: "set null" }),
    action: text("action").notNull(),
    resourceType: text("resource_type"),
    resourceId: text("resource_id"),
    metadata: jsonb("metadata"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index("audit_log_user_idx").on(t.userId)]
);

// ─── Relations ────────────────────────────────────────────────────────────────

export const usersRelations = relations(users, ({ many }) => ({
  refreshTokens: many(refreshTokens),
  plaidItems: many(plaidItems),
  accounts: many(accounts),
  transactions: many(transactions),
  budgets: many(budgets),
  netWorthSnapshots: many(netWorthSnapshots),
  devicePushTokens: many(devicePushTokens),
}));

export const plaidItemsRelations = relations(plaidItems, ({ one, many }) => ({
  user: one(users, { fields: [plaidItems.userId], references: [users.id] }),
  accounts: many(accounts),
}));

export const accountsRelations = relations(accounts, ({ one, many }) => ({
  user: one(users, { fields: [accounts.userId], references: [users.id] }),
  plaidItem: one(plaidItems, { fields: [accounts.plaidItemId], references: [plaidItems.id] }),
  transactions: many(transactions),
}));

export const transactionsRelations = relations(transactions, ({ one }) => ({
  user: one(users, { fields: [transactions.userId], references: [users.id] }),
  account: one(accounts, { fields: [transactions.accountId], references: [accounts.id] }),
  category: one(categories, { fields: [transactions.categoryId], references: [categories.id] }),
  userCategory: one(categories, { fields: [transactions.userCategoryId], references: [categories.id] }),
}));


// ─── Subscriptions (Stripe) ──────────────────────────────────────────────────

export const subscriptions = pgTable(
  "subscriptions",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
    stripeCustomerId: text("stripe_customer_id").notNull(),
    stripeSubscriptionId: text("stripe_subscription_id"),
    // Stripe's own status: trialing, active, past_due, canceled, unpaid, incomplete, ...
    status: text("status").notNull().default("incomplete"),
    interval: text("interval"),
    currentPeriodEnd: timestamp("current_period_end", { withTimezone: true }),
    trialEnd: timestamp("trial_end", { withTimezone: true }),
    cancelAtPeriodEnd: boolean("cancel_at_period_end").notNull().default(false),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex("subscriptions_user_idx").on(t.userId), uniqueIndex("subscriptions_customer_idx").on(t.stripeCustomerId)]
);

// ─── Historical security prices (cache for rebuilding investment history) ─────

export const securityPrices = pgTable(
  "security_prices",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    ticker: text("ticker").notNull(),
    date: date("date").notNull(),
    close: numeric("close", { precision: 18, scale: 6 }).notNull(),
  },
  (t) => [uniqueIndex("security_prices_ticker_date_idx").on(t.ticker, t.date)]
);

export const priceFetches = pgTable("price_fetches", {
  ticker: text("ticker").primaryKey(),
  ok: boolean("ok").notNull(),
  // earliest day the last fetch asked for
  fromDate: date("from_date").notNull(),
  fetchedAt: timestamp("fetched_at", { withTimezone: true }).notNull().defaultNow(),
});
