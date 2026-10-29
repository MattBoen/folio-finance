CREATE TABLE "price_fetches" (
	"ticker" text PRIMARY KEY NOT NULL,
	"ok" boolean NOT NULL,
	"from_date" date NOT NULL,
	"fetched_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "security_prices" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"ticker" text NOT NULL,
	"date" date NOT NULL,
	"close" numeric(18, 6) NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "security_prices_ticker_date_idx" ON "security_prices" USING btree ("ticker","date");