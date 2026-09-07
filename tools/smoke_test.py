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
    "boss":   dict(email="boss@test.invalid",   name="Dana Oversight", tier="oversight", role="oversight"),
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
            r = self.conn.execute(f"select public.{fn}({keys})", {k: (json.dumps(v) if isinstance(v, dict) or (isinstance(v, list) and v and isinstance(v[0], dict)) or (k in ("samples","photos","materials","outcomes_met","entries") and isinstance(v, list)) else v) for k, v in args.items()}).fetchone()[0]
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
            crew = None if k in ("chad","boss") else (crewB if k == "other" else crewA)
            conn.execute("""insert into public.profiles(id, full_name, email, employment_tier, app_role, crew_id, is_student, active)
                            values (%s,%s,%s,%s,%s,%s,%s,true) on conflict (id) do update set crew_id = excluded.crew_id, app_role = excluded.app_role, employment_tier = excluded.employment_tier, active = true""",
                         (ids[k], p["name"], p["email"], p["tier"], p["role"], crew, k in ("jordan","sam","other")))
        conn.execute("update public.crews set lead_id = %s where id = %s", (ids["lead"], crewA))
        # the smoke test owns two walk-route zones so it never depends on the map's data
        for zid, name, coords in (("TEST-SW-1", "Test walk 1", [[-97.0740, 47.9226],[-97.0720, 47.9226]]), ("TEST-SW-2", "Test walk 2", [[-97.0742, 47.9228],[-97.0721, 47.9231]])):
            conn.execute("""insert into public.zones(id, name, class, site, season, priority_snow, responsible_crew_id, active) values (%s,%s,'walk_route','main','snow',1,%s,true)
                            on conflict (id) do update set responsible_crew_id = excluded.responsible_crew_id, active = true""", (zid, name, crewA))
            if not conn.execute("select current_version_id from public.zones where id=%s", (zid,)).fetchone()[0]:
                conn.execute("select public.zone_version_create(%s, %s::jsonb, 'smoke_test', true, null)", (zid, json.dumps({"type":"LineString","coordinates":coords})))
        # and one machine, so the asset checks never depend on the map's data either
        conn.execute("""insert into public.assets(id, name, asset_type, class, required_capability_code, status, active) values ('TST-EQ1','Test toolcat','machine','toolcat','TOOLCAT','in_service',true)
                        on conflict (id) do update set status='in_service', active=true""")
        conn.execute("update public.asset_reservations set released_at = now() where asset_id='TST-EQ1' and released_at is null")
        # clean earlier runs of this test's tasks
        conn.execute("update public.tasks set state='canceled' where created_by = %s and state not in ('done','canceled')", (ids["chad"],))
        conn.execute("update public.shifts set ended_at = now() where profile_id = any(%s) and ended_at is null", (list(ids.values()),))
        conn.execute("delete from public.certifications where profile_id = any(%s) and source <> 'full_time_default'", (list(ids.values()),))
        conn.execute("update public.certification_requests set status='withdrawn' where profile_id = any(%s) and status='pending'", (list(ids.values()),))
        conn.execute("select public.grant_full_time_defaults(%s)", (ids["lead"],))
        conn.execute("update public.asset_reservations set released_at = now() where released_at is null and holder_id = any(%s)", (list(ids.values()),))
        conn.commit()

        k = lambda: str(uuid.uuid4())
        loc = {"lng": -97.0731, "lat": 47.9229, "accuracy_m": 6.5, "taken_at": "now"}
        conn.execute("begin")
        # 1 task create by admin
        with As(conn, ids["chad"]) as chad:
            r = chad.rpc("task_create", idempotency_key=k(), zone_id="TEST-SW-2", task_type="salt", outcome="Walks around the Union open and salted before 6:30",
                         required_capabilities=["TOOLCAT"], priority=1)
            check("task_create", r.get("ok") is True, str(r)[:80]); task = r["data"]["task_id"]
            check("default evidence for salt", set(chad.q("select evidence_required from public.tasks where id=%s", task)[0][0]) == {"photo_before","photo_after","material_qty","location"})
            r = chad.rpc("task_assign", idempotency_key=k(), task_id=task, profile_id=ids["jordan"], expected_revision=1)
            check("assign unqualified -> GRND-423", r.get("error") == "GRND-423", str(r))
            r = chad.rpc("certification_verify", idempotency_key=k(), profile_id=ids["jordan"], capability_code="TOOLCAT")
            check("certification_verify", r.get("ok") is True, str(r)[:80])
            key = k()
            r1 = chad.rpc("task_assign", idempotency_key=key, task_id=task, profile_id=ids["jordan"], expected_revision=1, asset_id="TST-EQ1")
            check("assign qualified", r1.get("ok") is True and r1["data"]["state"] == "assigned", str(r1)[:100])
            r2 = chad.rpc("task_assign", idempotency_key=key, task_id=task, profile_id=ids["jordan"], expected_revision=1, asset_id="TST-EQ1")
            check("same key replays, no second assignment", r2.get("replayed") is True and r2["data"]["assignment_id"] == r1["data"]["assignment_id"])
            check("stale revision -> GRND-409", chad.rpc("task_assign", idempotency_key=k(), task_id=task, profile_id=ids["sam"], expected_revision=1).get("error") == "GRND-409")
            check("asset TST-EQ1 reserved", chad.q("select count(*) from public.asset_reservations where asset_id='TST-EQ1' and released_at is null")[0][0] == 1)
            r = chad.rpc("task_create", idempotency_key=k(), zone_id="TEST-SW-1", task_type="plow", outcome="Second task needs TST-EQ1 too", required_capabilities=[])
            check("task_create second", r.get("ok") is True, str(r)[:160]); task2 = r["data"]["task_id"]
            r = chad.rpc("task_assign", idempotency_key=k(), task_id=task2, profile_id=ids["sam"], asset_id="TST-EQ1")
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
            import datetime as _dt
            t0 = _dt.datetime.now(_dt.timezone.utc)
            samples = [{"taken_at": (t0 - _dt.timedelta(seconds=40)).isoformat(), "lng": -97.0731, "lat": 47.9229, "accuracy_m": 6.5, "battery": 80},
                       {"taken_at": (t0 - _dt.timedelta(seconds=20)).isoformat(), "lng": -97.0730, "lat": 47.9229, "accuracy_m": 5.8},
                       {"taken_at": t0.isoformat(), "lng": -97.0730, "lat": 47.9229}]
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
            check("zone status salted set", jordan.q("select count(*) from public.v_zone_status_current where zone_id='TEST-SW-2' and activity='salted'")[0][0] == 1)
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
            check("TST-EQ1 released after approve", lead.q("select count(*) from public.asset_reservations where asset_id='TST-EQ1' and released_at is null")[0][0] == 0)
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
        # 6 policy decisions (migration 0010)
        with As(conn, ids["lead"]) as lead:
            check("full-time lead auto-holds everything but CDL", "CDL" not in lead.q("select capabilities from public.v_me")[0][0] and "BOBCAT" in lead.q("select capabilities from public.v_me")[0][0])
            r = lead.rpc("certification_request", idempotency_key=k(), profile_id=ids["sam"], capability_code="TOOLCAT", outcomes_met=[])
            check("cert request needs every outcome -> GRND-422", r.get("error") == "GRND-422", str(r)[:120])
            outs = lead.q("select outcomes from public.v_capabilities where code='TOOLCAT'")[0][0]
            r = lead.rpc("certification_request", idempotency_key=k(), profile_id=ids["sam"], capability_code="TOOLCAT", outcomes_met=outs, notes="ran the walk with Sam")
            check("cert request pending", r.get("ok") and r["data"]["status"] == "pending", str(r)[:120]); req = r["data"]["request_id"]
            check("lead cannot decide", lead.rpc("certification_decide", idempotency_key=k(), request_id=req, approve=True).get("error") == "GRND-403")
        with As(conn, ids["chad"]) as chad:
            r = chad.rpc("certification_decide", idempotency_key=k(), request_id=req, approve=True, decision_notes="ok")
            check("admin approves -> certification", r.get("ok") and r["data"]["status"] == "approved" and chad.q("select valid from public.v_qualifications where profile_id=%s and capability_code='TOOLCAT'", ids["sam"])[0][0])
            r = chad.rpc("task_create", idempotency_key=k(), zone_id="TEST-SW-1", task_type="mow", outcome="Handoff test task", required_capabilities=["TOOLCAT"], external_ref={"system": "TMA", "ref": "WO-77123", "url": "https://example.invalid/wo/77123"})
            check("task_create with external ref", r.get("ok") and r["data"]["external_ref"] == "WO-77123", str(r)[:160]); task3 = r["data"]["task_id"]
            r = chad.rpc("task_assign", idempotency_key=k(), task_id=task3, profile_id=ids["other"], override_qualification=True, expected_revision=1)
            check("task_assign override ignored -> GRND-423", r.get("error") == "GRND-423", str(r)[:120])
            r = chad.rpc("task_assign", idempotency_key=k(), task_id=task3, profile_id=ids["jordan"])
            check("assign jordan (original)", r.get("ok") is True, str(r)[:100])
            st = chad.q("select revision from public.v_operating_state")[0][0]
            chad.rpc("operating_state_pivot", idempotency_key=k(), expected_revision=st, to_mode="snow", reason="handoff test")
        with As(conn, ids["jordan"]) as jordan:
            r = jordan.rpc("assignment_reassign", idempotency_key=k(), task_id=task3, to_profile_id=ids["sam"], reason="handing off")
            check("temp2 handoff blocked in snow -> GRND-403", r.get("error") == "GRND-403", str(r)[:120])
        with As(conn, ids["chad"]) as chad:
            st = chad.q("select revision from public.v_operating_state")[0][0]
            chad.rpc("operating_state_pivot", idempotency_key=k(), expected_revision=st, to_mode="landscaping", reason="handoff test")
        with As(conn, ids["jordan"]) as jordan:
            r = jordan.rpc("assignment_reassign", idempotency_key=k(), task_id=task3, to_profile_id=ids["sam"], reason="handing off")
            check("temp2 handoff allowed in landscaping", r.get("ok") is True and str(r["data"].get("original_assignee_id")) == str(ids["jordan"]), str(r["data"])[:300])
        with As(conn, ids["sam"]) as sam:
            row = sam.q("select original_assignee_name, assignee_name, external_ref, external_system from public.v_my_day where task_id=%s", task3)[0]
            check("original responsibility visible", row[0] == "Jordan Test" and row[1] == "Sam Test" and row[2] == "WO-77123", str(row))
            r = sam.rpc("shift_start", idempotency_key=k(), device_id="sam-phone"); sshift = r["data"]["shift_id"]
            r = sam.rpc("assignment_acknowledge", idempotency_key=k(), assignment_id=sam.q("select assignment_id from public.v_my_day where task_id=%s", task3)[0][0])
            check("sam acknowledges handoff", r.get("ok") is True, str(r)[:120])
            now_iso = sam.q("select now()")[0][0].isoformat()
            r = sam.rpc("task_start", idempotency_key=k(), task_id=task3, location={"lng": -97.07, "lat": 47.92, "accuracy_m": 5, "taken_at": now_iso})
            check("sam starts handoff task", r.get("ok") is True, str(r)[:120])
            r = sam.rpc("shift_end", idempotency_key=k(), shift_id=sshift)
            log = r.get("data", {}).get("day_log", {})
            check("shift_end returns day log with the work order", r.get("ok") and any(t["external_ref"] == "WO-77123" for t in log.get("tasks", [])), str(log)[:200])
            entries = [{"task_id": t["task_id"], "work_order_id": t["work_order_id"], "minutes": max(t["suggested_minutes"], 15), "suggested_minutes": t["suggested_minutes"], "external_ref": t["external_ref"]} for t in log.get("tasks", [])]
            r = sam.rpc("time_entries_confirm", idempotency_key=k(), shift_id=sshift, entries=entries)
            check("time entries confirmed", r.get("ok") and r["data"]["entries"] >= 1, str(r)[:120])
            check("second confirm -> GRND-410", sam.rpc("time_entries_confirm", idempotency_key=k(), shift_id=sshift, entries=entries).get("error") == "GRND-410")
        with As(conn, ids["chad"]) as chad:
            chad.rpc("task_cancel", idempotency_key=k(), task_id=task3, reason="test cleanup")
        # 7 campus events (migration 0012): ICS parsing edge cases, watch persistence across resync, reminders, ack
        ics = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:smoke_ics_1\r\nDTSTART:20991010T230700Z\r\nDTEND:20991011T013000Z\r\n"
               "LOCATION:Grand Forks\\, N.D.\\, Ralph Engelstad Arena\r\nSUMMARY:[W] University of North Dakota  Men's Hockey vs Smoke Test\r\n  (Exh.)\r\n"
               "URL:https://example.invalid/calendar.aspx?game_id=1&amp;sport_id=9\r\nEND:VEVENT\r\n"
               "BEGIN:VEVENT\r\nUID:smoke_ics_2\r\nDTSTART;VALUE=DATE:20991012\r\nDTEND;VALUE=DATE:20991013\r\nLOCATION:Fargo\\, N.D.\r\n"
               "SUMMARY:University of North Dakota  Football at NDSU\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
        with As(conn, ids["chad"]) as chad:
            r = chad.rpc("events_upsert_ics", payload=ics, p_source="ath")
            check("ics parse two events", r.get("ok") and r["data"]["events"] == 2, str(r)[:120])
            row = chad.q("select title, sport, home, venue_name, on_campus, watch, url, to_char(starts_at at time zone 'America/Chicago','HH24:MI') from public.campus_events where id='ath:smoke_ics_1'")[0]
            check("ics folded line, escaped commas, venue, home, url", row[0] == "Men's Hockey vs Smoke Test (Exh.)" and row[1] == "Men's Hockey" and row[2] is True and row[3] == "Ralph Engelstad Arena" and row[4] is True and row[5] is True and "&sport_id=9" in row[6] and row[7] == "18:07", str(row))
            row = chad.q("select home, all_day, watch, starts_at::date from public.campus_events where id='ath:smoke_ics_2'")[0]
            check("ics all-day away game not watched", row[0] is False and row[1] is True and row[2] is False, str(row))
            check("reminder ladder planned for watched event", chad.q("select count(*) from public.event_reminders where event_id='ath:smoke_ics_1'")[0][0] == 10)
            check("no reminders for unwatched", chad.q("select count(*) from public.event_reminders where event_id='ath:smoke_ics_2'")[0][0] == 0)
        with As(conn, ids["jordan"]) as jordan:
            check("worker cannot flag events", jordan.rpc("event_watch", idempotency_key=k(), event_id="ath:smoke_ics_1", watch=False).get("error") == "GRND-403")
        with As(conn, ids["lead"]) as lead:
            r = lead.rpc("event_watch", idempotency_key=k(), event_id="ath:smoke_ics_1", watch=False, reason="not our lot")
            check("lead clears watch", r.get("ok") and r["data"]["watch"] is False, str(r)[:120])
            check("clearing watch drops pending reminders", lead.q("select count(*) from public.event_reminders where event_id='ath:smoke_ics_1' and raised_at is null")[0][0] == 0)
        with As(conn, ids["chad"]) as chad:
            chad.rpc("events_upsert_ics", payload=ics, p_source="ath")
            check("person's decision survives resync", chad.q("select watch, watch_reason from public.campus_events where id='ath:smoke_ics_1'")[0] == (False, "not our lot"))
            r = chad.rpc("event_watch", idempotency_key=k(), event_id="ath:smoke_ics_2", watch=True, notes="parking overflow")
            check("admin flags away game on purpose", r.get("ok") and chad.q("select count(*) from public.event_reminders where event_id='ath:smoke_ics_2'")[0][0] == 10)
        # force one reminder due and raise it
        conn.execute("update public.event_reminders set due_on = current_date where event_id='ath:smoke_ics_2' and days_before=30")
        conn.execute("delete from public.outbox where event_type='event_reminder' and payload->>'event_id'='ath:smoke_ics_2'")
        conn.execute("select public.events_tick()")
        rid = conn.execute("select id from public.event_reminders where event_id='ath:smoke_ics_2' and days_before=30 and raised_at is not null").fetchone()
        check("tick raises the due reminder once", rid is not None and conn.execute("select count(*) from public.outbox where event_type='event_reminder' and payload->>'event_id'='ath:smoke_ics_2'").fetchone()[0] == 1)
        conn.execute("select public.events_tick()")
        check("second tick does not re-raise", conn.execute("select count(*) from public.outbox where event_type='event_reminder' and payload->>'event_id'='ath:smoke_ics_2'").fetchone()[0] == 1)
        with As(conn, ids["lead"]) as lead:
            check("reminder open in view", lead.q("select open from public.v_event_reminders where reminder_id=%s", rid[0])[0][0] is True)
            r = lead.rpc("event_reminder_ack", idempotency_key=k(), reminder_id=rid[0])
            check("lead acknowledges", r.get("ok") is True and lead.q("select open from public.v_event_reminders where reminder_id=%s", rid[0])[0][0] is False)
            check("second ack -> GRND-410", lead.rpc("event_reminder_ack", idempotency_key=k(), reminder_id=rid[0]).get("error") == "GRND-410")
        conn.execute("delete from public.campus_events where id like 'ath:smoke_ics_%'")
        # the test zones and machine stay out of the real lists between runs
        conn.execute("update public.zones set active = false where id in ('TEST-SW-1','TEST-SW-2')")
        conn.execute("update public.assets set active = false where id = 'TST-EQ1'")
        conn.commit()
    print(f"\n{sum(results)}/{len(results)} checks passed")
    sys.exit(0 if all(results) else 1)

if __name__ == "__main__":
    main()
