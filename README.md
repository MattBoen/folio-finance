# FinanceClient

Client-facing personal finance app — iPhone + backend API.

## Structure

```
backend/   Node 20 + TypeScript + Hono + Drizzle + PostgreSQL
ios/       SwiftUI iOS 17+ (Xcode project, added in milestone c)
```

## Backend: local setup

### Prerequisites
- Node 20+
- PostgreSQL 15+ running locally

### First run

```bash
cd backend
cp .env.example .env
# Fill in DATABASE_URL and generate secrets (see .env.example comments)
npm install
npm run db:migrate
npm run db:seed       # optional: seeds system categories
npm run dev
```

### Run tests

```bash
# Requires a real Postgres DB (uses DATABASE_URL from .env)
npm test
```

### Generate a migration after schema changes

```bash
npm run db:generate
npm run db:migrate
```

## Deploy (Render)

1. Push this repo to GitHub.
2. In Render dashboard → "New → Blueprint" → point at this repo.
3. Render reads `render.yaml` and provisions the web service, worker, and Postgres.
4. Set the `sync: false` env vars (PLAID_CLIENT_ID, PLAID_SECRET, APPLE_BUNDLE_ID, ALLOWED_ORIGINS) in the Render dashboard.

## Milestones

- [x] (a) Backend + auth + multi-tenant tests
- [ ] (b) Plaid link + sync
- [ ] (c) iOS app shell + Overview + Accounts
- [ ] (d) Transactions + Spending
- [ ] (e) Budget
- [ ] (f) Widgets
- [ ] (g) Hardening + TestFlight
