import { db, pool } from "./client.js";
import { categories } from "./schema.js";

const SYSTEM_CATEGORIES = [
  { name: "Food & Drink", children: ["Restaurants", "Coffee", "Groceries", "Alcohol"] },
  { name: "Shopping", children: ["Clothing", "Electronics", "Home", "Amazon"] },
  { name: "Transportation", children: ["Gas", "Parking", "Rideshare", "Public Transit"] },
  { name: "Bills & Utilities", children: ["Electric", "Internet", "Phone", "Rent", "Insurance"] },
  { name: "Entertainment", children: ["Movies", "Music", "Games", "Sports"] },
  { name: "Health & Fitness", children: ["Doctor", "Pharmacy", "Gym"] },
  { name: "Travel", children: ["Flights", "Hotels", "Car Rental"] },
  { name: "Personal Care", children: ["Haircut", "Spa"] },
  { name: "Education", children: ["Tuition", "Books"] },
  { name: "Income", children: ["Paycheck", "Transfer"] },
  { name: "Transfers", children: [] },
  { name: "Other", children: [] },
];

async function main() {
  for (const parent of SYSTEM_CATEGORIES) {
    const [row] = await db
      .insert(categories)
      .values({ name: parent.name, isSystem: true })
      .onConflictDoNothing()
      .returning();

    if (row && parent.children.length > 0) {
      await db
        .insert(categories)
        .values(parent.children.map((name) => ({ name, parentId: row.id, isSystem: true })))
        .onConflictDoNothing();
    }
  }
  await pool.end();
}

main().catch(console.error);
