CREATE TABLE "user_settings" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"income_override" numeric(18, 2),
	"birth_year" integer,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "vehicles" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"account_id" uuid NOT NULL,
	"vin" text NOT NULL,
	"year" integer NOT NULL,
	"make" text NOT NULL,
	"model" text NOT NULL,
	"trim" text,
	"miles" integer NOT NULL,
	"valuation_source" text DEFAULT 'estimate' NOT NULL,
	"valued_at" timestamp with time zone DEFAULT now() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "user_settings" ADD CONSTRAINT "user_settings_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "vehicles" ADD CONSTRAINT "vehicles_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "vehicles" ADD CONSTRAINT "vehicles_account_id_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "vehicles_user_idx" ON "vehicles" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "vehicles_account_idx" ON "vehicles" USING btree ("account_id");--> statement-breakpoint
CREATE UNIQUE INDEX "budgets_user_category_idx" ON "budgets" USING btree ("user_id","category_id");