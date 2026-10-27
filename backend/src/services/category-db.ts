import { ilike } from "drizzle-orm";
import { db } from "../db/client.js";
import { categories } from "../db/schema.js";

export async function findOrCreateCategory(name: string): Promise<string> {
  const [existing] = await db
    .select({ id: categories.id })
    .from(categories)
    .where(ilike(categories.name, name))
    .limit(1);
  if (existing) return existing.id;
  const [created] = await db.insert(categories).values({ name, isSystem: true }).returning({ id: categories.id });
  return created.id;
}
