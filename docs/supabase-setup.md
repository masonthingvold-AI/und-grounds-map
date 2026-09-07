# Supabase setup and day to day commands

Project: `und-grounds` in the "UND Grounds" organization on supabase.com (Mason's account). Region and plan: free tier, prototype only (ADR planning assumptions).

## Secrets

`.env` in the repo root, never committed (`.gitignore` covers it). Copy `.env.example` and fill in:

```
SUPABASE_URL=https://<ref>.supabase.co
SUPABASE_PROJECT_REF=<ref>
SUPABASE_ANON_KEY=...          public, ships in the app
SUPABASE_SERVICE_ROLE_KEY=...  secret, bypasses RLS, server side only
SUPABASE_DB_PASSWORD='...'     secret, quote it if it has & or %
```

The anon key is safe to give to Codex for the client build. The other two stay on Mason's Mac. Rotate both from the dashboard (Project Settings, API and Database) before the pilot goes live with real employees.

## Commands (run from the repo root on the Mac; needs `python3 -m pip install "psycopg[binary]"`)

```
python3 tools/migrate.py --status      what is applied, what is pending, whether an applied file changed
python3 tools/migrate.py               apply pending migrations, each in its own transaction
python3 tools/migrate.py --sql "..."   run one statement (debug)
python3 tools/seed_supabase.py         load data/*.geojson into zones, zone_versions, assets (idempotent; new version only when geometry changed)
python3 tools/seed_supabase.py --check report without writing
python3 tools/smoke_test.py            vertical slice as synthetic users, 52 checks, safe to re-run
GROUNDS_ALLOW_RESET=yes python3 tools/migrate.py --reset   drop everything and start over (prototype only; also empties the evidence bucket)
```

Migrations are numbered `supabase/migrations/NNNN_name.sql`. Once a migration is on `main` and applied, do not edit it; add a new one. Until the pilot, the reset command is the way to change earlier files.

## Project settings that matter

- Data API: on. Automatically expose new tables: off (every grant is explicit in the migrations). Automatic RLS on new tables: on.
- Auth: email and password for the pilot. No self sign-up: admins create users, then a `profiles` row (see `tools/smoke_test.py` for the pattern). UND SSO is a production gate (ADR 17).
- Storage: bucket `evidence`, private, 8 MB limit, JPEG/PNG/HEIC. App roles can insert at registered paths and read what RLS lets them see; nothing can update or delete from the app.
- Realtime: private broadcast topics `all`, `person:<uuid>`, `crew:<uuid>`; `postgres_changes` on `tasks`, `assignments`, `operating_state`, `zone_status`.

## Synthetic people

`chad@test.invalid` (admin), `lead@test.invalid` (lead of Snow walks A), `jordan@test.invalid` (Temp 2), `sam@test.invalid` (Temp 1), `other@test.invalid` (Temp 1, Snow walks B). Created by the smoke test with random passwords. Not real employees. Delete from Authentication, Users whenever.

## What is not built yet

Push notifications, the weather Edge Function, the evidence export Edge Function (`verification_url` is a relative path until then), the nightly signed anchor digest (ADR 8), background photo hash verification, asset checkout and maintenance log, route guidance. All listed as planned in `docs/api-contract.md` section 0.
