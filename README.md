# Badal Exchange

EVC Plus &harr; Wallet &harr; WinWin exchange system for the Somali market.

The **Customer Wallet** is the single source of balance. Every deposit and
withdrawal, on either rail, passes through it and creates an auditable
order + ledger entry. The backend is the only thing that can ever change a
wallet balance — the mobile apps only ever display what the backend
computed and confirmed.

## Structure

- `backend/` — Node.js + TypeScript + Express + PostgreSQL API. Source of
  truth for auth, the wallet ledger, orders, exchange rates/fees, SMS and
  WinWin/MobCash transaction matching, and payment-integration credentials.
  See `backend/README.md` (and inline comments in `src/db/migrations/001_init.sql`)
  for the schema and flows.
- `admin-dashboard/` — React/Vite web dashboard for admins & managers.
- `customer-app/` — Flutter app for customers (deposit/withdraw/orders/profile).
- `agent-app/` — Flutter app for authorized agents (SMS-based EVC Plus
  verification, WinWin/MobCash confirmation entry, withdrawal processing).
- `docs/` — architecture notes.

## Core flows

```
EVC Plus  --> Customer Wallet --> WinWin
WinWin    --> Customer Wallet --> EVC Plus
```

Deposits never credit the wallet on the customer's say-so. An authorized
agent (EVC Plus: reads the payment SMS on a registered device; WinWin:
observes the confirmed result in the real WinWin Manager app) submits the
verified transaction to the backend, which matches it against the pending
order (phone/WinWin ID + deposit code + amount, dedup'd by provider
transaction reference) before crediting the wallet.

Withdrawals reserve funds out of `available` into `pending` immediately
(so the same balance can never be double-spent), and only move to a
permanent deduction once an agent/admin confirms the payout actually went
out. A failed payout releases the reservation — the customer is never
charged for a withdrawal that didn't happen.

## MobCash / WinWin integration note

WinWin/MobCash has no published public API today — only a manager-role
login inside the WinWin app itself, used to manually top up a WebUser ID
(deposit) or pay out against a withdrawal code (withdrawal). Badal Exchange
does **not** automate or screen-scrape that login — this system stores the
manager account credentials encrypted at rest (Admin &rarr; Payment
Integrations) for record-keeping, wired through a pluggable adapter
interface, but production confirmation always goes through a human
operator keying the real result into the backend. If WinWin ever publishes
an official API, only the adapter implementation needs to change.
