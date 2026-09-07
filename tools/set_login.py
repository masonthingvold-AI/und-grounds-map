#!/usr/bin/env python3
"""Create or update a person's app login and profile. Runs on the Mac (reads .env, uses the service role key locally).

  python3 tools/set_login.py mason.thingvold@und.edu "Mason Thingvold" admin
  python3 tools/set_login.py chad@und.edu "Chad Lastname" admin
  python3 tools/set_login.py someone@und.edu "First Last" worker temp1 "Snow walks A"

Roles: oversight, admin, lead, worker. Tiers (for lead and worker): full_time, temp2, temp1. Crew name is optional.
The password is typed at the prompt, never on the command line, never written anywhere.
"""
import sys, json, subprocess, getpass, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from migrate import env, connect

def api(E, method, path, body=None):
    cmd = ["curl", "-s", "-X", method, f"{E['SUPABASE_URL']}/auth/v1{path}", "-H", f"apikey: {E['SUPABASE_SERVICE_ROLE_KEY']}",
           "-H", f"Authorization: Bearer {E['SUPABASE_SERVICE_ROLE_KEY']}", "-H", "Content-Type: application/json"]
    if body is not None: cmd += ["-d", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    return json.loads(out or "{}")

def main():
    if len(sys.argv) < 4:
        print(__doc__); sys.exit(1)
    email, full_name, role = sys.argv[1].strip().lower(), sys.argv[2], sys.argv[3]
    tier = sys.argv[4] if len(sys.argv) > 4 else {"oversight": "oversight", "admin": "admin", "lead": "full_time", "worker": "temp1"}[role]
    crew = sys.argv[5] if len(sys.argv) > 5 else None
    pw = getpass.getpass(f"Password for {email} (12+ characters): ")
    if len(pw) < 12 or pw != getpass.getpass("Type it again: "):
        print("Passwords did not match or were too short. Nothing changed."); sys.exit(1)
    E = env()
    with connect() as conn:
        row = conn.execute("select id from auth.users where email = %s", (email,)).fetchone()
        if row:
            uid = row[0]; r = api(E, "PUT", f"/admin/users/{uid}", {"password": pw, "email_confirm": True})
        else:
            r = api(E, "POST", "/admin/users", {"email": email, "password": pw, "email_confirm": True, "user_metadata": {"full_name": full_name}})
            uid = r.get("id")
        if not uid:
            print("Auth API error:", r); sys.exit(1)
        crew_id = None
        if crew:
            c = conn.execute("select id from public.crews where name = %s", (crew,)).fetchone()
            if not c: print(f"No crew named {crew}. Existing:", [x[0] for x in conn.execute("select name from public.crews")]); sys.exit(1)
            crew_id = c[0]
        conn.execute("""insert into public.profiles(id, full_name, email, employment_tier, app_role, crew_id, is_student, active)
                        values (%s, %s, %s, %s, %s, %s, %s, true)
                        on conflict (id) do update set full_name = excluded.full_name, email = excluded.email, employment_tier = excluded.employment_tier,
                          app_role = excluded.app_role, crew_id = coalesce(excluded.crew_id, profiles.crew_id), active = true""",
                     (uid, full_name, email, tier, role, crew_id, tier in ("temp1", "temp2")))
        conn.commit()
    # prove the login works through the public API, the same way the app does
    r = subprocess.run(["curl", "-s", "-X", "POST", f"{E['SUPABASE_URL']}/auth/v1/token?grant_type=password", "-H", f"apikey: {E['SUPABASE_ANON_KEY']}",
                        "-H", "Content-Type: application/json", "-d", json.dumps({"email": email, "password": pw})], capture_output=True, text=True)
    print("login check:", "PASS" if "access_token" in r.stdout else "FAIL " + r.stdout[:200])
    print(f"{email} is {role} ({tier}){' on ' + crew if crew else ''}.")

if __name__ == "__main__":
    main()
