# Benta Business Control

A mobile-first Vue 3 PWA for multi-shop food businesses. It covers branch checkout, sales history, recipe-based inventory, production batches, cash shifts, expenses, owner approvals, reports, and encrypted offline sales.

## Run locally

```bash
npm install
cp .env.example .env
npm run dev
```

Add the Supabase project URL and **publishable/anon** key to `.env`. Never put a service-role key in this application.

The Supabase schema and RPCs live in `supabase/migrations`. Deploy those migrations and the seed before signing in.

## Features

- Email/password sign-in with super admin, owner, and branch staff access.
- Branch-aware cashier with required flavor choices, discounts, cash tendering, and exact change.
- Server-authoritative pricing, stock deduction, idempotent checkout, and payment records.
- Encrypted offline checkout queue using a device PIN, AES-GCM, and PBKDF2.
- Registered branch devices, remote wipe requests, and automatic sync on reconnect.
- Sales history, order detail, owner review of offline conflicts, voids, and refunds.
- Ingredient balances, restocking, production batches, waste, and finished-goods stock.
- Cash shifts, cash movements, expenses, corrections, and audit trail.
- Dashboard and profit reports for branch, shop, or group scope.
- Admin controls for shops, branches, team access, menu, recipes, payments, settings, and devices.
- Installable PWA with an offline app shell; Supabase API responses are never cached.

## Security and data rules

- Money is represented as integer centavos in the client.
- The browser UI is not trusted for financial logic; Supabase RPCs re-read prices, stock, costs, and permissions.
- Offline sales are encrypted at rest and require a registered device. The PIN never leaves the browser.
- A queued sale is keyed by request id, so retries are idempotent.
- Configuration changes require a current revision so stale offline orders go to owner review instead of posting silently.

## Commands

```bash
npm run dev
npm run build
npm run typecheck
npm test
npm run test:watch
```

## Deploy to Netlify

1. Push this folder to a Git repository, then create a Netlify site from that repository.
2. Netlify reads [netlify.toml](./netlify.toml): build command `npm run build`, publish directory `dist`, Node 22.
3. In **Site configuration → Environment variables**, add:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_PUBLISHABLE_KEY`
4. In Supabase **Authentication → URL Configuration**, add the Netlify production and deploy-preview URLs.
5. Deploy. The PWA service worker precaches the app shell, uses an SPA navigation fallback, and avoids caching API responses.

Local `.env` values are ignored by Git. Set the same variables in Netlify.
