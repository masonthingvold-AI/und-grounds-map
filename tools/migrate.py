#!/usr/bin/env python3
"""Apply supabase/migrations/*.sql to the project in .env, in order, once each.

Usage:
  python3 tools/migrate.py            apply pending migrations
  python3 tools/migrate.py --status   show applied and pending
  python3 tools/migrate.py --sql "select 1"   run one statement (debug)

Reads SUPABASE_PROJECT_REF and SUPABASE_DB_PASSWORD from .env (never committed).
Each file runs inside one transaction; a failure rolls that file back and stops.
"""
import os, sys, glob, hashlib, urllib.parse, pathlib
import psycopg

ROOT = pathlib.Path(__file__).resolve().parent.parent
MIG = ROOT / "supabase" / "migrations"

def env():
    out = {}
    for line in (ROOT / ".env").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip("'").strip('"')
    return out

def connect():
    e = env()
    ref, pw = e["SUPABASE_PROJECT_REF"], urllib.parse.quote(e["SUPABASE_DB_PASSWORD"])
    conn = psycopg.connect(f"postgresql://postgres:{pw}@db.{ref}.supabase.co:5432/postgres?sslmode=require", autocommit=False)
    conn.execute("set search_path = public, extensions"); conn.commit()   # PostGIS lives in extensions; migrations and tools resolve geometry through this path
    return conn

def ensure_table(conn):
    conn.execute("""create table if not exists public.schema_migrations (
        name text primary key, sha256 text not null, applied_at timestamptz not null default now())""")
    conn.execute("revoke all on public.schema_migrations from anon, authenticated")
    conn.commit()

def applied(conn):
    return {r[0]: r[1] for r in conn.execute("select name, sha256 from public.schema_migrations order by name")}

def main():
    args = sys.argv[1:]
    with connect() as conn:
        ensure_table(conn)
        if args[:1] == ["--reset"]:
            if os.environ.get("GROUNDS_ALLOW_RESET") != "yes":
                print("refusing: set GROUNDS_ALLOW_RESET=yes (drops every table, prototype only)"); return
            conn.autocommit = True
            for stmt in ["drop policy if exists evidence_insert on storage.objects", "drop policy if exists evidence_read on storage.objects",
                         "drop policy if exists realtime_receive on realtime.messages",
                         "drop schema public cascade", "create schema public",
                         "grant usage on schema public to postgres, anon, authenticated, service_role", "grant all on schema public to postgres, service_role",
                         "comment on schema public is 'standard public schema'"]:
                conn.execute(stmt)
            # storage rows can only go through the Storage API
            import subprocess
            e = env()
            for m, path in (("POST", "/storage/v1/bucket/evidence/empty"), ("DELETE", "/storage/v1/bucket/evidence")):
                subprocess.run(["curl", "-s", "-o", "/dev/null", "-X", m, e["SUPABASE_URL"] + path,
                                "-H", "apikey: " + e["SUPABASE_SERVICE_ROLE_KEY"], "-H", "Authorization: Bearer " + e["SUPABASE_SERVICE_ROLE_KEY"]])
            print("reset done"); return
        if args[:1] == ["--sql"]:
            conn.autocommit = True
            cur = conn.execute(args[1])
            try:
                for row in cur.fetchall(): print(row)
            except psycopg.ProgrammingError: print("ok")
            return
        done = applied(conn)
        files = sorted(glob.glob(str(MIG / "*.sql")))
        pending = []
        for f in files:
            name = os.path.basename(f)
            sha = hashlib.sha256(open(f, "rb").read()).hexdigest()
            if name in done:
                flag = "" if done[name] == sha else "  (CHANGED since applied!)"
                print(f"applied  {name}{flag}")
            else:
                pending.append((name, f, sha))
                print(f"pending  {name}")
        if args[:1] == ["--status"] or not pending:
            return
        for name, f, sha in pending:
            sql = open(f).read()
            try:
                conn.execute(sql)
                conn.execute("insert into public.schema_migrations(name, sha256) values (%s, %s)", (name, sha))
                conn.commit()
                print(f"ok       {name}")
            except Exception as ex:
                conn.rollback()
                print(f"FAILED   {name}\n{ex}")
                sys.exit(1)

if __name__ == "__main__":
    main()
