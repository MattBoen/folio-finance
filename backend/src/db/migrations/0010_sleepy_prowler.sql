CREATE TABLE "merchant_places" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"key" text NOT NULL,
	"address" text,
	"city" text,
	"region" text,
	"postal" text,
	"confidence" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "plaid_items" ADD COLUMN "details_backfilled" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "transactions" ADD COLUMN "city" text;--> statement-breakpoint
ALTER TABLE "transactions" ADD COLUMN "region" text;--> statement-breakpoint
ALTER TABLE "transactions" ADD COLUMN "payment_channel" text;--> statement-breakpoint
ALTER TABLE "transactions" ADD COLUMN "store_number" text;--> statement-breakpoint
ALTER TABLE "transactions" ADD COLUMN "original_description" text;--> statement-breakpoint
ALTER TABLE "merchant_places" ADD CONSTRAINT "merchant_places_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "merchant_places_user_key_idx" ON "merchant_places" USING btree ("user_id","key");--> statement-breakpoint
-- A town alone was stored as the place before; it put pins in the middle of town. Keep street addresses only.
UPDATE "transactions" SET "place" = NULL WHERE "place" IS NOT NULL AND "place" !~ '^\s*\d';
