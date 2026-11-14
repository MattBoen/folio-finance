CREATE TABLE "ask_spend" (
	"user_id" uuid NOT NULL,
	"month" text NOT NULL,
	"micro_usd" integer DEFAULT 0 NOT NULL,
	"questions" integer DEFAULT 0 NOT NULL,
	CONSTRAINT "ask_spend_user_id_month_pk" PRIMARY KEY("user_id","month")
);
--> statement-breakpoint
ALTER TABLE "ask_spend" ADD CONSTRAINT "ask_spend_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;