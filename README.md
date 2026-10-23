# Benta Business Control

A mobile-first Vue 3 PWA foundation for multi-shop food businesses. It includes a responsive cashier flow seeded with the supplied chicken-wings prices and flavor rules.

## Run locally

```bash
npm install
cp .env.example .env
npm run dev
```

To connect Supabase, add the project URL and **publishable/anon** key to `.env`. Never put a service-role key in this application.

## Current foundation

- Responsive phone, tablet, and desktop cashier UI
- Chicken-wings menu with required flavor-count validation
- Cash/GCash checkout, tendered cash, and change calculation
- Local offline indicator and provisional pending-sync transaction state
- Installable PWA shell caching static files only
- Supabase client configuration and SQL migration folder

## Security and data rules

- Money is represented as integer centavos in the client.
- The browser UI is not trusted for financial logic; final validation, inventory, permissions, and idempotency belong in Supabase RPCs.
- Schema migrations must be deployed before enabling real transactions.

## Commands

```bash
npm run dev
npm run build
```

## Deploy to Netlify

1. Push this folder to a Git repository, then create a new Netlify site from that repository.
2. Netlify reads [netlify.toml](./netlify.toml) automatically: build command is `npm run build`, publish directory is `dist`, and Node 22 is selected.
3. In **Site configuration → Environment variables**, add:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_PUBLISHABLE_KEY`
4. In Supabase **Authentication → URL Configuration**, add the Netlify production URL and its deploy-preview URL pattern to the allowed redirect URLs before enabling email login or password recovery.
5. Deploy. The PWA service worker is configured to avoid caching API responses and is refreshed without long-term caching.

The values in local `.env` are ignored by Git. Set the same variables in Netlify; Vite embeds only variables prefixed with `VITE_` at build time.
