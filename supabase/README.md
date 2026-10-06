# BAARI backend on Supabase

Supabase is the backend for both apps. The Customer App and the Agent App
talk to the Supabase project (`onbezsojnpsrtuxzwsjr`, eu-west-1) directly:

| Need | Supabase piece |
| --- | --- |
| Data | Postgres, schema in `migrations/` (same tables as the old Node backend) |
| Login, sessions | Supabase Auth (email+password; the apps derive the email from the phone number) |
| Business logic | Postgres functions called with `supabase.rpc(...)`: one per old REST endpoint |
| Authorization | Checks inside every function, plus row level security on every table |
| Live updates | Supabase Realtime on orders, wallets, confirmations, notifications, app content |
| CashdeskBot API | Edge Function `functions/cashdeskbot` (holds the CashdeskBot secrets) |
| MobCash portal automation | `backend/src/worker.ts` (optional; see below) |

The old server (203.161.38.33) and its local database are no longer used.
The Node backend (`backend/`) is kept unchanged as a fallback until the
Supabase setup has run in production for a while; it works against the same
schema.

## What was migrated (audit)

Every REST endpoint the apps used has a Supabase function returning the same
JSON, so the apps' screens and models did not change.

| Old REST endpoint | Supabase |
| --- | --- |
| `POST /auth/customer/register` | `register_customer` (also creates the wallet) |
| `POST /auth/{customer,agent}/login`, `/auth/refresh`, `/auth/logout` | Supabase Auth, then `session_profile` (role check + login audit) |
| `GET /meta/payment-methods` | `payment_method_catalog` (callable before login) |
| `GET /customer/wallet`, `/orders`, `/orders/:id` | `customer_wallet`, `customer_orders`, `customer_order` |
| `POST /customer/quotes` | `customer_quote` |
| `POST /customer/deposits/:method`, `/withdrawals/:method` | `customer_create_deposit`, `customer_create_withdrawal` |
| `GET /customer/payment-methods`, `/home-ads`, `/notifications`, `/contacts` | `customer_payment_methods`, `customer_home_ads`, `customer_notifications`, `customer_contacts` |
| `POST /agent/devices/register`, `GET /agent/profile` | `agent_register_device`, `agent_profile` |
| `GET /agent/deposits/pending`, `/withdrawals/pending`, `/orders/completed`, `/orders/failed` | `agent_pending_deposits`, `agent_pending_withdrawals`, `agent_completed_orders`, `agent_failed_orders` |
| `POST /agent/sms-transactions`, `/mobile-money-transactions` | `agent_submit_sms_transaction`, `agent_submit_mobile_money_transaction` |
| `POST /agent/platform-transactions`, `/winwin-transactions` | `agent_submit_platform_transaction` |
| `POST /agent/withdrawals/:id/{start,complete,fail}` | `agent_withdrawal_start`, `agent_withdrawal_complete`, `agent_withdrawal_fail` |
| `GET /agent/dashboard`, `/customers`, `/customers/:id`, `/customers/:id/ledger` | `agent_dashboard`, `agent_customers`, `agent_customer`, `agent_customer_ledger` |
| `GET /agent/reports`, `/history`, `/account` | `agent_reports`, `agent_history`, `agent_account` |
| `POST /agent/account/password` | `change_password` (signs out the user's other sessions) |
| `/agent/manage/payment-methods`, `home-ads`, `deposit-numbers`, `notifications`, `contacts` | `manage_*` |
| `/admin/exchange-rates`, `/fees`, `/withdrawal-limits` | `admin_exchange_rates`, `admin_set_exchange_rate`, `admin_fees`, `admin_set_fee`, `admin_withdrawal_limits`, `admin_set_withdrawal_limits` |
| `/admin/agents...` | `admin_agents`, `admin_create_agent`, `admin_set_agent_status`, `admin_set_agent_responsibilities`, `admin_agent_devices`, `admin_agent_transactions` |
| `/admin/dashboard/summary`, `/customers`, `/wallets`, `/orders`, `/transactions`, `/audit-logs`, `/reports/daily` | `admin_dashboard_summary`, `admin_customers`, `admin_customer`, `admin_wallets`, `admin_wallet_ledger`, `admin_orders`, `admin_order`, `admin_transactions`, `admin_audit_logs`, `admin_reports_daily` |
| `POST /admin/winwin-transactions` | `admin_submit_platform_transaction` |
| `/admin/payment-integrations...` | `admin_payment_integrations`, `admin_payment_integration`, `admin_set_integration_credentials`, `admin_set_integration_status`, `admin_test_integration_connection`, `admin_set_integration_automation`, `admin_reset_circuit_breaker`, `admin_automation_runs`, `admin_automation_run_screenshot` |
| `POST /admin/payment-integrations/mobcash_winwin/login-check` | Needs a headless browser, so only the MobCash worker can do it. `admin_mobcash_login_check` says so. |
| `/admin/cashdeskbot/*` | Edge Function `cashdeskbot` (same routes and bodies) |

### Business rules kept

- **Money:** amounts are kept in cents and computed only in the database.
  Each order snapshots the rate and fee in force when it was created.
- **Deposits:** a deposit is pending until verified. A mobile-money deposit
  is matched on sender phone + amount (from an SMS, or entered by an agent).
  A betting-platform deposit is matched on account ID + amount, plus the
  deposit code when one is given. Each provider reference credits a wallet
  only once.
- **Withdrawals:** funds are reserved when the request is made. The
  withdrawal then either completes (debit) or fails (release). An identical
  request while one is in flight is refused.
- **Ledger and locking:** every balance change writes a ledger entry
  (credit, debit, reserve, release). The wallet row is locked during each
  change, so concurrent requests can't double-spend.
- **Idempotency:** money-moving calls take an idempotency key. A retried
  call returns the first result instead of running again. This is also the
  money rate limit: 20 calls per minute per user.
- **Audit:** every state change and management action is written to
  `audit_logs`.
- **Payment methods:** ON/OFF switch per method; a switched-off method
  refuses new orders.
- **Permissions:** `manage_settings` is checked on every call. Agents can't
  lock themselves out by removing it or by disabling their own account.
- **Disabled accounts:** they are banned in Supabase Auth and signed out
  everywhere.
- **Integration credentials:** stored in Supabase Vault (encrypted). The
  password is never returned.

### Accounts and passwords

Accounts stay in `public.users` and are mirrored into `auth.users` with the
same id and the same bcrypt hash (trigger `users_sync_auth`), so **existing
users keep their passwords**: nothing to reset. Login uses a synthetic email,
`<phone digits>@phone.baari.invalid`, which the apps compute from the phone
number. No email is ever sent to it.

On a brand-new database the migrations create the same demo logins the old
seed did. All three use password `ChangeMe123!`:

| Role | Phone | Notes |
| --- | --- | --- |
| Admin | 252610000001 | |
| Agent | 252610000002 | Has `manage_settings` |
| Customer | 252610000003 | |

Change these passwords before going live (Account → Change Password).

## Deploying

1. **Database and functions.** Two ways:
   - Run the *Deploy to Supabase* GitHub Action (needs the
     `SUPABASE_DATABASE_URL` secret, and `SUPABASE_ACCESS_TOKEN` for the
     Edge Function).
   - Or let the Supabase GitHub integration apply `supabase/migrations`
     when this branch is merged to `main`.

   Both record applied migrations in the same place, so running both is
   safe. The migrations also apply cleanly to a database that already has
   the Node backend's tables and data, keeping that data.
2. **Apps.** Add the project's publishable (anon) key as the repository
   secret or variable `SUPABASE_ANON_KEY`. It is under Supabase dashboard →
   Project Settings → API Keys. Then run *Build Customer & Agent APKs*.
3. **Recommended Auth settings** (Supabase dashboard → Authentication):
   turn off *Allow new users to sign up*. Customers register through
   `register_customer`, which also creates their wallet; direct sign-ups
   would only create orphan logins that every function refuses anyway.
4. **CashdeskBot** (if used): set its secrets with
   `supabase secrets set CASHDESKBOT_LOGIN=... CASHDESKBOT_CASHIERPASS=... CASHDESKBOT_HASH=... CASHDESKBOT_CASHDESKID=...`.
5. **MobCash automation** (optional, off by default). Automatic WinWin
   processing drives the MobCash web portal with a headless browser, which
   can't run inside Supabase. Without it, WinWin works exactly as before:
   agents confirm top-ups and payouts by hand. To automate it, run the
   worker on any machine with Node 20+ and Chromium:

   ```bash
   cd backend && npm ci && npm run build
   DATABASE_URL='<session pooler URL>' npm run worker
   ```

   It processes new WinWin withdrawals as they arrive and polls deposits
   every minute. It does nothing until a manager switches MobCash to
   automatic in the Agent App.

Moving data from the old server's database is not needed for the app to
work. If it is ever wanted, `pg_dump --data-only` it into Supabase. The
`users_sync_auth` trigger gives every imported account its Supabase login
with its existing password.

## Testing

```bash
supabase start                 # local stack (Docker)
supabase db reset              # all migrations on a fresh database
cd supabase/tests && npm install && npm test

# the apps' real API classes against the same stack
cd customer-app && SUPABASE_E2E_URL=http://127.0.0.1:54321 SUPABASE_E2E_ANON_KEY=<publishable key> flutter test
cd agent-app    && SUPABASE_E2E_URL=http://127.0.0.1:54321 SUPABASE_E2E_ANON_KEY=<publishable key> flutter test
```

The backend tests cover:

- registration and login, including a legacy bcrypt user;
- role separation;
- quote math;
- deposits by SMS, by hand and on betting platforms;
- withdrawals: reserve, complete and fail/release;
- idempotency and duplicate guards;
- row level security: each role sees only its own rows and can't write;
- the agent console;
- all management actions;
- agent disable and ban;
- password change;
- Vault credentials;
- Realtime isolation between customers.

The *Supabase tests* workflow runs all of this on every pull request.
