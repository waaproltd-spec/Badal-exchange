# BADAL AI Developer Bot: owner guide

A Telegram bot that does real engineering work for BADAL EXCHANGE: you write a request in Somali or English, it plans it,
a coding agent writes it on a branch, tests run, and you get a **pull request** with the result. It never merges or deploys
by itself.

## How it works

```
Telegram  ->  dev-bot (Edge Function)  ->  Claude (plans, asks the one missing question, rates the risk)
                    |                              
                    +-> GitHub Actions "Developer Bot agent" (dev-agent.yml): Claude Code works on branch devbot/<n>-..., 
                    |   runs analyze/tests, a guard checks the change, opens a PR, starts the CI tests
                    +-> report (HMAC-signed) -> dev-bot -> Telegram (progress, PR, test result)
                    +-> Postgres: tasks, task log, project memory, audit log, one-time approvals
                    +-> health monitor, GitHub test results, deployment (with backup) -> /health /tests /deploy
```

## What it can and can not do

| It does | It never does |
| --- | --- |
| Reads the code, writes and edits code, adds tests, runs `flutter analyze/test` | Merge, or push to your production branch |
| Creates a branch, commits, pushes, opens a PR, starts the CI tests | Deploy by itself |
| Reports progress, test results, the PR link, in Somali or English | Touch production data, balances, secrets, tokens or workflow files |
| Remembers architecture, decisions, bugs, features, deployments | Delete data, or run anything without a task you sent |
| Prepares a deployment: tests green, backup + restore test, then asks you | Deploy on a red test, or an older/newer commit than the one checked |

**Approval is required (one-time button, owner only)** for: a task that touches money, the database, security or a release
(it starts only after you press "Yes"), and every production deployment (two approvals: before the backup, after it).

## Access

Only Telegram accounts that are **linked to a platform manager** (an administrator, or an agent with the `manage_settings`
responsibility; link it in Agent App > Account > Telegram Bot with `/link CODE` in any cashier bot) **and** listed by the owner can
use it. The first manager who sends `/start` (while there is no owner) becomes the **owner**. The owner adds people with
`/authorize TELEGRAM_ID` (the person must be a platform manager with Telegram linked) and removes them with `/revoke TELEGRAM_ID`. Everyone else gets a refusal, and the attempt is audited.

## Commands

`/start` `/help` `/status` `/projects` `/tasks` `/task N` (details) `/task <request>` (start a task without the AI planner)
`/cancel N` `/health` `/logs` `/tests` `/deploy` `/memory [word]` `/authorize ID` `/revoke ID`, and ordinary messages.

## One-time setup (the owner)

1. **Create the bot** in @BotFather; keep the token.
2. **Supabase > Edge Functions > Secrets**:
   `DEVBOT_TELEGRAM_TOKEN` (the bot token), `DEVBOT_WEBHOOK_SECRET` (a long random string), `DEVBOT_REPORT_SECRET` (another long random
   string), `ANTHROPIC_API_KEY` (already there for the support bot), `DEVBOT_GITHUB_TOKEN` (below), and the settings
   `DEVBOT_REPO` (`owner/repo`), `DEVBOT_BASE_BRANCH` (the branch production is deployed from, where PRs go), optionally `DEVBOT_DEPLOY_REF`.
3. **`DEVBOT_GITHUB_TOKEN`**: a *fine-grained personal access token* for this one repository with only: Actions **read and write**,
   Contents **read**, Pull requests **read**, Metadata **read**. It can start workflows and read results; it cannot push or merge.
4. **GitHub > Settings > Secrets and variables > Actions**: `ANTHROPIC_API_KEY`, `DEVBOT_REPORT_URL`
   (`https://<project>.supabase.co/functions/v1/dev-bot/report`), `DEVBOT_REPORT_SECRET` (the same value as in Supabase),
   plus the existing `SUPABASE_DATABASE_URL` and `BACKUP_PASSPHRASE` (for the backup before a deployment).
5. **GitHub > Settings > Actions > General**: allow "GitHub Actions to create and approve pull requests".
6. Deploy (the "Deploy to Supabase" workflow publishes the `dev-bot` function), then register the webhook once:
   `POST https://<project>.supabase.co/functions/v1/dev-bot/setup?key=<DEVBOT_WEBHOOK_SECRET>`.
7. Open the bot in Telegram and send `/start`.

## Safety model (why it is safe to give it a repository)

* The coding agent runs in GitHub Actions **without the GitHub token or any production secret**; it can read and edit files, run
  analyze/tests, and nothing else (no network, no push, no `gh`).
* After it finishes, a **guard** removes workflow/secret files, rejects a change that contains a secret-looking value or is too large
  (120 files / 10,000 lines), marks the PR **high risk** when it touches migrations, Edge Functions, wallets, payments or auth, and only
  then pushes the branch and opens the PR. The full CI runs on the PR.
* One task runs at a time (the rest wait); 10 new tasks per 24 hours; a task with no news for 90 minutes is stopped.
* Every important action is in `public.dev_audit` (who, what, when, allowed or refused); approvals are single-use, 15 minutes, owner only.
* A deployment needs green Backend and Customer tests for the exact commit, a verified backup (or the owner's explicit
  "deploy without backup"), and the owner's second approval; a branch that moved after the check is not deployed.
* Rollback: `git revert` + deploy again, previous APK/AAB (see `docs/DISASTER_RECOVERY.md`).

## Limits, honestly

* The agent is as good as its request and tests: it opens a PR for **you to review**; it does not replace review.
* It can not run the Supabase backend tests locally (they need a database stack); those run in CI on the PR, and the bot tells you the result.
* Production runs on Supabase (managed): there is no PM2/Caddy/Linux server of ours to manage. `/health` reports the platform
  monitor (database, cron, Sahal, bots, money invariants); CPU/RAM/disk belong to Supabase.
* Large, multi-day projects are done as stages: ask for a stage, review the PR, ask for the next; the project memory carries the context.
