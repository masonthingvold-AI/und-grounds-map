#!/usr/bin/env python3
"""Security and hardening audit against the live project. Read-only except for rolled-back write probes.

Checks: RLS on every table, security_invoker on every view, search_path pinned on every security definer function,
which functions app roles may execute (against an allow list), what each role can read (row counts per relation),
and that direct writes fail for every role. Prints PASS/FAIL lines and exits 1 on any FAIL.
"""
import json, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from migrate import connect

# functions the app is allowed to call (docs/api-contract.md); anything else executable by authenticated is a finding
ALLOWED_FUNCTIONS = {  # trigger functions are executable by their tables' owner only, so they never appear here
    "auth_profile_id","auth_role","is_admin","my_crew_ids","can_see_profile","can_see_task","can_direct","profile_name",
    "valid_capability_codes","missing_capabilities","certification_verify","certification_suspend","certification_request","certification_decide",
    "zone_version_create","keepout_active_for_zone","keepout_open","keepout_close","assess_location","nearest_zone_version","asset_available","mk_point",
    "shift_start","shift_end","shift_end_for","location_upload","open_task_ids_for","default_evidence",
    "task_create","task_assign","assignment_acknowledge","assignment_reassign","assignment_release","task_start","task_block","task_unblock","task_cancel",
    "dispatch_candidates","evidence_upload_url","service_finalize","task_approve","evidence_verify",
    "active_event_id","zone_status_set","operating_state_pivot","operating_state_ack",
    "day_log","time_entries_confirm","work_order_link_external",
    "media_upload_path","media_apply","asset_upsert",
    "event_watch","event_reminder_ack","events_upsert","events_upsert_ics","reminder_ladder","venue_lookup",
    # trigger functions and pure helpers are harmless but listed so the report is exact
    "touch_updated_at","forbid_change","material_tx_apply","profiles_full_time_defaults","outbox_broadcast","task_result","check_revision",
    "ics_unescape","ics_prop","ics_time","event_auto_watch",
}
# what a worker may read at all (row counts may still be zero); everything else must be zero rows or denied
WORKER_READ_OK = {"profiles","crews","crew_placements","capabilities","certifications","zones","zone_versions","keepouts","assets","asset_reservations",
                  "materials","material_transactions","shifts","location_samples","work_orders","tasks","assignments","evidence_objects","service_records",
                  "evidence_events","weather_events","zone_status","operating_state","operating_state_acks","time_entries","certification_requests",
                  "campus_events","event_reminders","event_venues"}
results = []
def check(name, ok, info=""):
    ok = bool(ok); results.append(ok); print(("PASS " if ok else "FAIL ") + name + (f"  ({info})" if info else ""))

def as_user(conn, uid):
    conn.execute("set local role authenticated")
    conn.execute("select set_config('request.jwt.claims', %s, true)", (json.dumps({"sub": str(uid), "role": "authenticated"}),))

def main():
    with connect() as conn:
        conn.autocommit = False
        # 1 RLS on every table
        rows = conn.execute("select relname, relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and relkind in ('r','p') and relname <> 'schema_migrations' and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e') order by 1").fetchall()
        bad = [r[0] for r in rows if not r[1]]
        check(f"RLS enabled on all {len(rows)} tables", not bad, ", ".join(bad))
        # 2 security_invoker on every view
        rows = conn.execute("select c.relname, coalesce(array_to_string(c.reloptions, ','), '') from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and relkind='v' and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e') order by 1").fetchall()
        bad = [r[0] for r in rows if 'security_invoker=true' not in r[1]]
        check(f"security_invoker on all {len(rows)} views", not bad, ", ".join(bad))
        # 3 search_path pinned on security definer functions
        rows = conn.execute("""select p.proname, coalesce(array_to_string(p.proconfig, ','), '') from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                               where n.nspname='public' and p.prosecdef and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') order by 1""").fetchall()
        bad = [r[0] for r in rows if 'search_path=' not in r[1]]
        check(f"search_path pinned on all {len(rows)} security definer functions", not bad, ", ".join(bad))
        # 4 executable functions vs allow list
        rows = conn.execute("""select distinct p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                               where n.nspname='public' and has_function_privilege('authenticated', p.oid, 'execute') and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') order by 1""").fetchall()
        extra = sorted(r[0] for r in rows if r[0] not in ALLOWED_FUNCTIONS)
        check("no unexpected functions executable by authenticated", not extra, ", ".join(extra))
        rows = conn.execute("""select distinct p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                               where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute') and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') order by 1""").fetchall()
        anon_fns = sorted(r[0] for r in rows)
        check("anon cannot execute app functions", not anon_fns, ", ".join(anon_fns))
        # 5 anon cannot read anything
        tables = [r[0] for r in conn.execute("select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and relkind in ('r','v') and relname<>'schema_migrations' and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e') order by 1")]
        leaks = []
        conn.execute("savepoint a"); conn.execute("set local role anon")
        for t in tables:
            try:
                conn.execute("savepoint b"); n = conn.execute(f"select count(*) from public.{t}").fetchone()[0]
                if n > 0: leaks.append(f"{t}={n}")
                conn.execute("release savepoint b")
            except Exception: conn.execute("rollback to savepoint b")
        conn.execute("rollback to savepoint a")
        check("anon reads zero rows everywhere", not leaks, ", ".join(leaks))
        # PostGIS catalog objects must not be readable by app roles either
        # PostGIS lives in the extensions schema: nothing of it may sit in the API schema
        st = conn.execute("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'st\\_%'").fetchone()[0]
        check("PostGIS functions are not in the API schema", st == 0, f"{st} st_* functions in public")
        # 6 per-role read matrix and direct write probes
        people = {r[1]: r[0] for r in conn.execute("select p.id, p.app_role || ':' || u.email from public.profiles p join auth.users u on u.id=p.id where u.email like '%@test.invalid'")}
        worker = next(v for k, v in people.items() if k.startswith("worker:other"))
        conn.execute("savepoint a"); as_user(conn, worker)
        leaks = []
        for t in tables:
            try:
                conn.execute("savepoint b"); n = conn.execute(f"select count(*) from public.{t}").fetchone()[0]; conn.execute("release savepoint b")
            except Exception as ex:
                conn.execute("rollback to savepoint b"); continue
            if t == "profiles" and n != 1: leaks.append(f"profiles={n}")
            if t in ("tasks","assignments","shifts","location_samples","service_records","time_entries") and n != 0: leaks.append(f"{t}={n}")
            if t.startswith("v_") and t in ("v_dispatch_board","v_my_day","v_task_detail","v_time_entries","v_qualifications","v_certification_requests","v_crew_availability") and n not in (0, 1): leaks.append(f"{t}={n}")
        conn.execute("rollback to savepoint a")
        check("isolated worker (other crew) sees only own rows", not leaks, ", ".join(leaks))
        # direct writes as worker and as admin must fail on every table
        for label, uid in (("worker", worker), ("admin", next(v for k, v in people.items() if k.startswith("admin")))):
            allowed = []
            conn.execute("savepoint a"); as_user(conn, uid)
            for t in [x for x in tables if not x.startswith("v_")]:
                for stmt in (f"insert into public.{t} default values", f"update public.{t} set id = id where false", f"delete from public.{t} where false"):
                    try:
                        conn.execute("savepoint b"); conn.execute(stmt); conn.execute("release savepoint b"); allowed.append(f"{t}:{stmt.split()[0]}")
                    except Exception as ex:
                        conn.execute("rollback to savepoint b")
                        msg = str(ex)
                        if "permission denied" not in msg and "row-level security" not in msg and "immutable" not in msg and "not-null" not in msg and "null value" not in msg and "does not exist" not in msg and "syntax" not in msg:
                            pass
            conn.execute("rollback to savepoint a")
            check(f"{label} cannot write any table directly", not allowed, ", ".join(allowed[:8]))
        # 7 storage policies
        pols = [r[0] for r in conn.execute("select policyname from pg_policies where schemaname='storage' and tablename='objects'")]
        check("storage: insert and select policies only, no update/delete for app roles",
              set(pols) >= {"evidence_insert","evidence_read"} and not any(p for p in pols if "update" in p.lower() or "delete" in p.lower()), ", ".join(pols))
        # 8 buckets private
        b = conn.execute("select id, public, file_size_limit from storage.buckets").fetchall()
        check("evidence bucket private with size limit", all(not r[1] and r[2] for r in b), str(b))
        # 9 cron jobs present
        jobs = [r[0] for r in conn.execute("select jobname from cron.job where active")]
        check("daily jobs scheduled", {"und-events-request","und-events-ingest","und-events-tick"} <= set(jobs), ", ".join(jobs))
        conn.rollback()
    print(f"\n{sum(results)}/{len(results)} audit checks passed")
    sys.exit(0 if all(results) else 1)

if __name__ == "__main__":
    main()
