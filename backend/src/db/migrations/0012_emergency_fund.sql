ALTER TABLE "user_settings" ADD COLUMN "emergency_included" jsonb;--> statement-breakpoint
ALTER TABLE "user_settings" ADD COLUMN "emergency_basis" text;--> statement-breakpoint
ALTER TABLE "user_settings" ADD COLUMN "emergency_picks" jsonb;