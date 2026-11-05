# Disaster recovery and rollback

## Copies of the data

1. **Supabase's own backups** (Dashboard > Database > Backups; point-in-time recovery if the plan has it). First
   choice for any restore. Confirm in the dashboard which of the two the plan includes and how many days.
2. **Our independent nightly dump** (`.github/workflows/backup.yml`): `public` and `private` schemas,
   encrypted with the repository secret `BACKUP_PASSPHRASE`, kept 90 days as a workflow artifact. Every night
   the dump is restored into a scratch database and the row counts are compared with the source **before** it is
   kept: a backup that does not restore fails the job the same day. Keep `BACKUP_PASSPHRASE` in the owner's
   password manager as well: without it the dumps cannot be opened.

Not in the dump: Supabase Auth users (re-created by Supabase restore or by "forgot password"), the Vault secrets
and the Edge Function secrets (Supabase dashboard; keep a copy of the values in the password manager).

## Restoring from our dump

1. Actions > "Database backup and restore test" > the run you want > download `db-backup-<run>`.
2. `gpg --decrypt backup.dump.gpg > backup.dump` (asks for `BACKUP_PASSPHRASE`).
3. Restore into a **new** Supabase project or a scratch Postgres first and check it:
   `pg_restore -d "<new database url>" --no-owner --no-privileges --clean --if-exists backup.dump`
   then run the `diagnose` sections 10 and 30 against it (everything must be 0).
4. Only after it is checked, point the apps and functions at the restored project or copy the needed tables.
   Never restore over the live database without a second dump of it first.

## Rolling back a bad release

* **Edge Functions and the apps:** `git revert <commit>` on the branch, push, run "Deploy Supabase" (mode
  `deploy`) again. The apps: install the previous build from its GitHub release (`apk-build-<run>`); a Play Store
  release is replaced by uploading the previous version with a higher version code.
* **Database migrations are forward-only.** A migration that is wrong is fixed by a new migration (never by
  editing an applied one). Every migration in this repository is idempotent (`IF NOT EXISTS`,
  `CREATE OR REPLACE`) and changes no balance. Financial rows are never deleted to fix a technical problem.
* **Gate:** nothing is deployed until Backend tests and Customer App tests are green (the Agent App has two
  known failing end-to-end tests, `payments_e2e_test.dart`, accepted as a baseline).

## Disaster checklist

1. Is it the platform (Supabase status page) or us? `diagnose` mode and the System Health screen say.
2. Stop money first: if balances look wrong, keep orders pending, do not "fix" balances by hand.
3. Restore from Supabase backup; if that is not possible, from the nightly dump (above).
4. Re-register the Telegram webhooks (the health monitor does this by itself every 5 minutes) and check
   `diagnose` sections 5, 9 and 10 before telling customers it is back.
