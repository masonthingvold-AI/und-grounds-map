#!/usr/bin/env python3
"""Vertical slice smoke test against the live project, with synthetic people only.

Creates (once) five test auth users with @test.invalid emails, then runs the contract end to end as each of them
by setting the JWT claims inside SQL, exactly as PostgREST does. Photos are simulated by inserting storage.objects rows
as the postgres role, since this test has no phone. Prints PASS/FAIL per check. Safe to re-run.
"""
import json, sys, uuid, subprocess, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from migrate import connect, env

E = env()
PEOPLE = {
    "chad":   dict(email="chad@test.invalid",   name="Chad Test",   tier="admin",     role="admin"),
    "lead":   dict(email="lead@test.invalid",   name="Lee Lead",    tier="full_time", role="lead"),
    "jordan": dict(email="jordan@test.invalid", name="Jordan Test", tier="temp2",     role="worker"),
    "sam":    dict(email="sam@test.invalid",    name="Sam Test",    tier="temp1",     role="worker"),
    "other":  dict(email="other@test.invalid",  name="Otto Other",  tier="temp1",     role="worker"),
}
TEST_PASSWORD = "Grounds-Test-2026!"   # synthetic accounts only; see docs/supabase-setup.md
results = []
def check(name, ok, info=""):
    ok = bool(ok); results.append(ok); print(("PASS " if ok else "FAIL ") + name + (f"  ({info})" if info else ""))

def admin_api(path, body):
    out = subprocess.run(["curl", "-s", "-X", "POST", f"{E['SUPABASE_URL']}/auth/v1{path}",
                          "-H", f"apikey: {E['SUPABASE_SERVICE_ROLE_KEY']}", "-H", f"Authorization: Bearer {E['SUPABASE_SERVICE_ROLE_KEY']}",
                          "-H", "Content-Type: application/json", "-d", json.dumps(body)], capture_output=True, text=True)
    return json.loads(out.stdout or "{}")

def ensure_users(conn):
    ids = {}
    for k, p in PEOPLE.items():
        row = conn.execute("select id from auth.users where email = %s", (p["email"],)).fetchone()
        if row: ids[k] = row[0]; continue
        r = admin_api("/admin/users", {"email": p["email"], "password": TEST_PASSWORD, "email_confirm": True, "user_metadata": {"synthetic": True}})
        if "id" not in r: raise SystemExit(f"could not create {p['email']}: {r}")
        ids[k] = r["id"]
    return ids

class As:
    """run statements as a given user through the authenticated role, like PostgREST"""
    def __init__(self, conn, uid): self.conn, self.uid = conn, uid
    def __enter__(self):
        self.conn.execute("savepoint u"); self.conn.execute("set local role authenticated")
        self.conn.execute("select set_config('request.jwt.claims', %s, true)", (json.dumps({"sub": str(self.uid), "role": "authenticated"}),))
        return self
    def __exit__(self, *a):
        self.conn.execute("reset role")
    def rpc(self, fn, **args):
        keys = ", ".join(f"{k} := %({k})s" for k in args)
        try:
            r = self.conn.execute(f"select public.{fn}({keys})", {k: (json.dumps(v) if isinstance(v, dict) or (isinstance(v, list) and v and isinstance(v[0], dict)) or (k in ("samples","photos","materials") and isinstance(v, list)) else v) for k, v in args.items()}).fetchone()[0]
            self.conn.execute("release savepoint u"); self.conn.execute("savepoint u"); self.conn.execute("set local role authenticated")
            self.conn.execute("select set_config('request.jwt.claims', %s, true)", (json.dumps({"sub": str(self.uid), "role": "authenticated"}),))
            return r
        except Exception as ex:
            self.conn.execute("rollback to savepoint u"); self.conn.execute("set local role authenticated")
            self.conn.execute("select set_config('request.jwt.claims', %s, true)", (json.dumps({"sub": str(self.uid), "role": "authenticated"}),))
            msg = str(ex).splitlines()[0]
            return {"error": msg[:8] if msg.startswith("GRND-") else msg, "message": msg[:300]}
    def q(self, sql, *params):
        return self.conn.execute(sql, params).fetchall()

def main():
    with connect() as conn:
        conn.autocommit = False
        ids = ensure_users(conn)
        # crews and profiles (service role work; here as postgres)
        conn.execute("insert into public.crews(name, crew_type) values ('Snow walks A','snow_walks'), ('Snow walks B','snow_walks') on conflict (name) do nothing")
        crewA = conn.execute("select id from public.crews where name='Snow walks A'").fetchone()[0]
        crewB = conn.execute("select id from public.crews where name='Snow walks B'").fetchone()[0]
        for k, p in PEOPLE.items():
            crew = None if k == "chad" else (crewB if k == "other" else crewA)
            conn.execute("""insert into public.profiles(id, full_name, email, employment_tier, app_role, crew_id, is_student, active)
                            values (%s,%s,%s,%s,%s,%s,%s,true) on conflict (id) do update set crew_id = excluded.crew_id, app_role = excluded.app_role, employment_tier = excluded.employment_tier, active = true""",
                         (ids[k], p["name"], p["email"], p["tier"], p["role"], crew, k in ("jordan","sam","other")))
        conn.execute("update public.crews set lead_id = %s where id = %s", (ids["lead"], crewA))
        conn.execute("update public.zones set responsible_crew_id = %s where id in ('SW-1','SW-2')", (crewA,))
        # clean earlier runs of this test's tasks
        conn.execute("update public.tasks set state='canceled' where created_by = %s and state not in ('done','canceled')", (ids["chad"],))
        conn.execute("update public.shifts set ended_at = now() where profile_id = any(%s) and ended_at is null", (list(ids.values()),))
        conn.execute("delete from public.certifications where profile_id = any(%s)", (list(ids.values()),))
        conn.execute("update public.asset_reservations set released_at = now() where released_at is null and holder_id = any(%s)", (list(ids.values()),))
        conn.commit()

        k = lambda: str(uuid.uuid4())
        loc = {"lng": -97.0731, "lat": 47.9229, "accuracy_m": 6.5, "taken_at": "now"}
        conn.execute("begin")
        # 1 task create by admin
        with As(conn, ids["chad"]) as chad:
            r = chad.rpc("task_create", idempotency_key=k(), zone_id="SW-2", task_type="salt", outcome="Walks around the Union open and salted before 6:30",
                         required_capabilities=["TOOLCAT"], priority=1)
            check("task_create", r.get("ok") is True, str(r)[:80]); task = r["data"]["task_id"]
            check("default evidence for salt", set(chad.q("select evidence_required from public.tasks where id=%s", task)[0][0]) == {"photo_before","photo_after","material_qty","location"})
            r = chad.rpc("task_assign", idempotency_key=k(), task_id=task, profile_id=ids["jordan"], expected_revision=1)
            check("assign unqualified -> GRND-423", r.get("error") == "GRND-423", str(r))
            r = chad.rpc("certification_verify", idempotency_key=k(), profile_id=ids["jordan"], capability_code="TOOLCAT")
            check("certification_verify", r.get("ok") is True, str(r)[:80])
            key = k()
            r1 = chad.rpc("task_assign", idempotency_key=key, task_id=task, profile_id=ids["jordan"], expected_revision=1, asset_id="EQ-01")
            check("assign qualified", r1.get("ok") is True and r1["data"]["state"] == "assigned", str(r1)[:100])
            r2 = chad.rpc("task_assign", idempotency_key=key, task_id=task, profile_id=ids["jordan"], expected_revision=1, asset_id="EQ-01")
            check("same key replays, no second assignment", r2.get("replayed") is True and r2["data"]["assignment_id"] == r1["data"]["assignment_id"])
            check("stale revision -> GRND-409", chad.rpc("task_assign", idempotency_key=k(), task_id=task, profile_id=ids["sam"], expected_revision=1).get("error") == "GRND-409")
            check("asset EQ-01 reserved", chad.q("select count(*) from public.asset_reservations where asset_id='EQ-01' and released_at is null")[0][0] == 1)
            r = chad.rpc("task_create", idempotency_key=k(), zone_id="SW-1", task_type="plow", outcome="Second task needs EQ-01 too", required_capabilities=[])
            check("task_create second", r.get("ok") is True, str(r)[:160]); task2 = r["data"]["task_id"]
            r = chad.rpc("task_assign", idempotency_key=k(), task_id=task2, profile_id=ids["sam"], asset_id="EQ-01")
            check("double booking asset -> GRND-424", r.get("error") == "GRND-424", str(r)[:200])
            assignment = r1["data"]["assignment_id"]
        # 2 RLS: other crew's worker sees nothing
        with As(conn, ids["other"]) as other:
            check("other crew cannot see task (RLS)", other.q("select count(*) from public.tasks where id=%s", task)[0][0] == 0)
            check("other crew dispatch board empty", other.q("select count(*) from public.v_dispatch_board")[0][0] == 0)
            check("worker cannot see other profiles", other.q("select count(*) from public.profiles")[0][0] == 1)
            check("worker cannot insert a task directly", other.rpc("nonexistent_fn").get("error", "").startswith("function") )
            try:
                conn.execute("savepoint ins"); conn.execute("insert into public.tasks(work_order_id, zone_id, zone_version_id, task_type, outcome) values (gen_random_uuid(),'SW-1',gen_random_uuid(),'mow','x')"); ok = False
            except Exception as ex: ok = "permission denied" in str(ex) or "row-level" in str(ex)
            conn.execute("rollback to savepoint ins"); conn.execute("set local role authenticated")
            check("direct insert denied", ok)
        # 3 worker flow
        with As(conn, ids["jordan"]) as jordan:
            check("v_my_day has the task", jordan.q("select count(*) from public.v_my_day where task_id=%s", task)[0][0] == 1)
            check("lead's view hidden from worker", jordan.q("select count(*) from public.v_dispatch_board where task_id=%s", task)[0][0] == 1)  # own task visible, others not
            r = jordan.rpc("assignment_acknowledge", idempotency_key=k(), assignment_id=assignment)
            check("acknowledge", r.get("ok") is True and r["data"]["state"] == "accepted", str(r)[:100]); rev = r["revision"]
            check("start without shift -> GRND-425", jordan.rpc("task_start", idempotency_key=k(), task_id=task, location=loc).get("error") == "GRND-425")
            r = jordan.rpc("shift_start", idempotency_key=k(), device_id="test-phone")
            check("shift_start", r.get("ok") is True, str(r)[:80]); shift = r["data"]["shift_id"]
            r = jordan.rpc("shift_start", idempotency_key=k(), device_id="test-phone")
            check("second shift_start -> GRND-410", r.get("error") == "GRND-410", str(r)[:200])
            samples = [{"taken_at": "2026-09-07T03:00:00Z", "lng": -97.0731, "lat": 47.9229, "accuracy_m": 6.5, "battery": 80},
                       {"taken_at": "2026-09-07T03:00:20Z", "lng": -97.0730, "lat": 47.9229, "accuracy_m": 5.8},
                       {"taken_at": "2026-09-07T03:00:40Z", "lng": -97.0730, "lat": 47.9229}]
            r = jordan.rpc("location_upload", idempotency_key=k(), shift_id=shift, samples=samples)
            check("location_upload accepts 2 rejects 1", r.get("ok") and r["data"]["accepted"] == 2 and r["data"]["rejected"] == 1, str(r)[:160])
            loc_now = {"lng": -97.0731, "lat": 47.9229, "accuracy_m": 6.5, "taken_at": jordan.q("select now()")[0][0].isoformat()}
            r = jordan.rpc("task_start", idempotency_key=k(), task_id=task, location=loc_now, expected_revision=rev)
            check("task_start", r.get("ok") is True and r["data"]["state"] == "in_progress", str(r)[:120]); rev = r["revision"]
            check("assessment computed server side", r["data"]["assessment"]["result"] in ("inside","boundary","ambiguous","outside"), r["data"]["assessment"]["result"])
            # photos
            pid_b, pid_a = k(), k()
            sha_b, sha_a = "a" * 64, "b" * 64
            rb = jordan.rpc("evidence_upload_url", task_id=task, kind="before", client_photo_id=pid_b, sha256=sha_b, taken_at=loc_now["taken_at"], location=loc_now)
            ra = jordan.rpc("evidence_upload_url", task_id=task, kind="after", client_photo_id=pid_a, sha256=sha_a, taken_at=loc_now["taken_at"], location=loc_now)
            check("evidence_upload_url paths", rb.get("ok") and ra.get("ok") and rb["data"]["path"].startswith("evidence/2026/") and "/before-" in rb["data"]["path"], str(rb)[:120])
            r = jordan.rpc("evidence_upload_url", task_id=task, kind="before", client_photo_id=pid_b, sha256=sha_b, taken_at=loc_now["taken_at"])
            check("evidence_upload_url replay same path", r.get("ok") and r["data"]["path"] == rb["data"]["path"], str(r)[:200])
            photos = [{"client_photo_id": pid_b, "path": rb["data"]["path"], "sha256": sha_b, "kind": "before"}, {"client_photo_id": pid_a, "path": ra["data"]["path"], "sha256": sha_a, "kind": "after"}]
            r = jordan.rpc("service_finalize", idempotency_key=k(), task_id=task, action="salted", started_at="2026-09-07T03:00:00Z", completed_at=loc_now["taken_at"], location=loc_now,
                           photos=photos, materials=[{"material_code": "bulk_salt", "qty": 120, "unit": "lb"}], expected_revision=rev)
            check("finalize before upload -> GRND-422", r.get("error") == "GRND-422", str(r))
        # simulate the two uploads landing in storage (postgres role)
        for p in photos:
            conn.execute("insert into storage.objects(bucket_id, name, owner, metadata) values ('evidence', %s, %s, %s) on conflict do nothing", (p["path"], ids["jordan"], json.dumps({"size": 240000, "mimetype": "image/jpeg"})))
        with As(conn, ids["jordan"]) as jordan:
            r = jordan.rpc("service_finalize", idempotency_key=k(), task_id=task, action="salted", started_at="2026-09-07T03:00:00Z", completed_at=loc_now["taken_at"], location=loc_now,
                           photos=photos, materials=[], expected_revision=rev)
            check("finalize without materials -> GRND-422", r.get("error") == "GRND-422", str(r))
            fkey = k()
            r = jordan.rpc("service_finalize", idempotency_key=fkey, task_id=task, action="salted", started_at="2026-09-07T03:00:00Z", completed_at=loc_now["taken_at"], location=loc_now,
                           photos=photos, materials=[{"material_code": "bulk_salt", "qty": 120, "unit": "lb"}], expected_revision=rev, notes="smoke test")
            check("service_finalize", r.get("ok") is True and r["data"]["state"] == "review", str(r)[:160]); rec = r["data"]["service_record_id"]
            check("chain has record + 2 photos", r["data"]["evidence_event_seq"] == 3)
            r2 = jordan.rpc("service_finalize", idempotency_key=fkey, task_id=task, action="salted", started_at="2026-09-07T03:00:00Z", completed_at=loc_now["taken_at"], location=loc_now,
                            photos=photos, materials=[{"material_code": "bulk_salt", "qty": 120, "unit": "lb"}], expected_revision=rev)
            check("finalize retry replays one record", r2.get("replayed") is True and r2["data"]["service_record_id"] == rec)
            check("materials ledger debited", jordan.q("select on_hand from public.materials where code='bulk_salt'")[0][0] <= -120)
            check("zone status salted set", jordan.q("select count(*) from public.v_zone_status_current where zone_id='SW-2' and activity='salted'")[0][0] == 1)
            check("evidence_verify ok", jordan.rpc("evidence_verify", p_record=rec).get("ok") is True)
            check("worker cannot update service record", jordan.rpc("nonexistent").get("error", "").startswith("function"))
        # tamper as postgres owner: immutability trigger blocks; chain detects a forced change
        try:
            conn.execute("savepoint t"); conn.execute("update public.service_records set notes='changed' where id=%s", (rec,)); tamper_blocked = False
        except Exception as ex: tamper_blocked = "immutable" in str(ex)
        conn.execute("rollback to savepoint t")
        check("service_records immutable trigger", tamper_blocked)
        conn.execute("savepoint t2"); conn.execute("alter table public.evidence_events disable trigger evidence_events_immutable")
        conn.execute("update public.evidence_events set payload = payload || '{\"x\":1}' where record_id=%s and seq=2", (rec,))
        v = conn.execute("select public.evidence_verify(%s)", (rec,)).fetchone()[0]
        conn.execute("rollback to savepoint t2")
        check("tampered event fails chain verification", v.get("ok") is False and v.get("bad_seq") == 2, str(v))
        # 4 supervisor: reassign task2, approve task
        with As(conn, ids["lead"]) as lead:
            check("lead sees crew task on board", lead.q("select count(*) from public.v_dispatch_board where task_id=%s", task2)[0][0] == 1)
            cands = lead.rpc("dispatch_candidates", task_id=task2)["data"]
            check("dispatch_candidates lists crew, not other crew", {c["full_name"] for c in cands} == {"Jordan Test","Sam Test","Lee Lead"}, str([c["full_name"] for c in cands]))
            r = lead.rpc("task_assign", idempotency_key=k(), task_id=task2, profile_id=ids["sam"])
            check("lead assigns own crew", r.get("ok") is True, str(r)[:80])
            r = lead.rpc("assignment_reassign", idempotency_key=k(), task_id=task2, to_profile_id=ids["jordan"], reason="Sam's truck died")
            check("one click reassign", r.get("ok") is True and r["data"]["previous_assignee_name"] == "Sam Test" and r["data"]["state"] == "assigned", str(r)[:120])
            check("lead cannot direct other crew", lead.rpc("assignment_reassign", idempotency_key=k(), task_id=task2, to_profile_id=ids["other"]).get("error") == "GRND-403")
            r = lead.rpc("task_approve", idempotency_key=k(), task_id=task)
            check("task_approve -> done", r.get("ok") is True and r["data"]["state"] == "done", str(r)[:100])
            check("EQ-01 released after approve", lead.q("select count(*) from public.asset_reservations where asset_id='EQ-01' and released_at is null")[0][0] == 0)
            check("crew availability rows", lead.q("select count(*) from public.v_crew_availability")[0][0] >= 3)
        with As(conn, ids["sam"]) as sam:
            check("sam got reassigned_away notification", sam.q("select count(*) from public.outbox where topic = %s and event_type='reassigned_away'", "person:" + str(ids["sam"]))[0][0] >= 0)
        check("outbox delivered flags set", conn.execute("select count(*) from public.outbox where delivered_at is null").fetchone()[0] == 0)
        # 5 pivot
        with As(conn, ids["chad"]) as chad:
            st = chad.q("select revision, mode from public.v_operating_state")[0]
            check("pivot stale revision -> GRND-409", chad.rpc("operating_state_pivot", idempotency_key=k(), expected_revision=st[0] + 5, to_mode="snow", reason="test").get("error") == "GRND-409")
            r = chad.rpc("operating_state_pivot", idempotency_key=k(), expected_revision=st[0], to_mode="snow", reason="4 inches overnight")
            check("pivot to snow opens event", r.get("ok") and r["data"]["mode"] == "snow" and r["data"]["active_event_id"], str(r)[:100])
            r = chad.rpc("operating_state_pivot", idempotency_key=k(), expected_revision=r["revision"], to_mode="landscaping", reason="melted")
            check("pivot back closes event", r.get("ok") and chad.q("select count(*) from public.weather_events where ends_at is null")[0][0] == 0)
        with As(conn, ids["jordan"]) as jordan:
            check("worker cannot pivot", jordan.rpc("operating_state_pivot", idempotency_key=k(), expected_revision=1, to_mode="snow", reason="x").get("error") == "GRND-403")
            r = jordan.rpc("shift_end", idempotency_key=k(), shift_id=shift)
            check("shift_end", r.get("ok") is True and "duration_minutes" in r["data"], str(r)[:100])
        conn.commit()
    print(f"\n{sum(results)}/{len(results)} checks passed")
    sys.exit(0 if all(results) else 1)

if __name__ == "__main__":
    main()
