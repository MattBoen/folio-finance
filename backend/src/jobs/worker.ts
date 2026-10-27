import PgBoss from "pg-boss";
import { syncItem } from "../services/plaid-sync.js";
import { setBoss } from "../routes/plaid.js";

const boss = new PgBoss(process.env.DATABASE_URL!);

boss.on("error", (err) => console.error("[pg-boss]", err));

await boss.start();
console.log("[worker] pg-boss started");

setBoss(boss);

await boss.work<{ itemId: string; userId: string }>("plaid-sync", async (jobs) => {
  for (const job of jobs) {
    const { itemId, userId } = job.data;
    console.log("[worker] plaid-sync start", itemId);
    try {
      await syncItem(itemId, userId);
      console.log("[worker] plaid-sync done", itemId);
    } catch (err) {
      console.error("[worker] plaid-sync error", itemId, err);
      throw err; // pg-boss will retry
    }
  }
});

await boss.work<{ userId: string }>("snapshot", async (jobs) => {
  for (const job of jobs) {
    console.log("[worker] snapshot stub, userId:", job.data?.userId);
  }
});

process.on("SIGTERM", async () => {
  await boss.stop();
  process.exit(0);
});
