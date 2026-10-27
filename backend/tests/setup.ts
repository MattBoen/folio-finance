import { pool } from "../src/db/client.js";

beforeAll(async () => {
  // Verify DB is reachable
  await pool.query("SELECT 1");
});

afterAll(async () => {
  await pool.end();
});
