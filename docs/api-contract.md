# API contract v1.5: UND Grounds operations platform

Status: v1.0 published September 7, 2026; v1.1 the same day once migrations 0001 to 0009 were applied; v1.2 with migration 0010 (Mason's policy decisions and the answers to Codex's review in `docs/api-contract-changes.md`). Smoke test: 68 checks. Owner: Claude (database, functions, views). Consumer: Codex (worker app, dispatch screens).
Governs: everything the client is allowed to call. If a screen needs something not in this document, ask for it in `docs/api-contract-changes.md` rather than inventing a query.
Depends on: `docs/adr-001-architecture.md`. Where this document and the ADR disagree, the ADR wins and this document gets fixed.

Stability promise: once a function or view is marked **implemented**, its name, arguments, and return shape do not change. New optional arguments and new return fields may be added. Anything else is a new name (`task_assign_v2`) and a line in the change log at the bottom. Items marked **planned** may still change; build against them only where the status table says "safe to build".

## 0. Implementation status

Live on the Supabase project `und-grounds` (URL and anon key are in the Mac checkout's `.env`; ask Mason for the anon key, it is safe to ship in the app). Migrations are in `supabase/migrations/`, applied with `python3 tools/migrate.py`; zones and assets are loaded from the GeoJSON with `python3 tools/seed_supabase.py`; `python3 tools/smoke_test.py` runs the vertical slice end to end as synthetic users (52 checks). See `docs/supabase-setup.md`.

| Item | Status | Migration |
|---|---|---|
| Auth, `profiles`, `auth_role()`, permissions, `v_me` (section 2) | implemented | 0001 |
| `v_capabilities`, `v_qualifications`, `certification_verify`, `certification_suspend` (section 3.4) | implemented | 0002 |
| `v_zones`, `v_keepouts`, `keepout_open`, `keepout_close`, `assess_location` (sections 3, 5) | implemented | 0003 |
| `v_assets`, `asset_available`, materials ledger (section 6, 7) | implemented | 0004 |
| `shift_start`, `shift_end`, `shift_end_for`, `location_upload`, `v_my_shift` (sections 4, 5) | implemented | 0005 |
| `task_create`, `task_assign`, `assignment_acknowledge`, `assignment_reassign`, `assignment_release`, `task_start`, `task_block`, `task_unblock`, `task_cancel`, `dispatch_candidates`, `v_my_day`, `v_task_detail`, `v_dispatch_board`, `v_crew_availability` (sections 3, 6) | implemented | 0006 |
| `evidence_upload_url`, `service_finalize`, `task_approve`, `evidence_verify`, `v_service_records`, storage bucket `evidence` (section 7) | implemented | 0007 |
| `zone_status_set`, `v_zone_status_current`, `operating_state_pivot`, `operating_state_ack`, `v_operating_state`, `v_weather_events` (sections 8, 9) | implemented | 0008 |
| Realtime broadcasts from the outbox, `postgres_changes` on four tables (section 10) | implemented, not yet exercised from a real client | 0009 |
| Certification requests and approvals, full-time defaults, oversight may direct work, Temp 2 handoff rule, `original_assignee`, external work order refs, `day_log`, `time_entries_confirm` (sections 2, 3.8, 4, 6, 11) | implemented | 0010 |
| Campus events from calendar.und.edu and fightinghawks.com: `v_campus_events`, `v_event_reminders`, `v_event_sync_health`, `event_watch`, `event_reminder_ack`, daily sync, reminder ladder, sync alerts (section 12) | implemented | 0011, 0012 |
| Equipment list with photos and holder avatars: `asset_upsert`, `media_upload_path`, `media_apply`, `v_assets` photo and holder fields, `avatar_path` on `v_me` and `v_crew_availability`, storage bucket `media` (section 13) | implemented | 0014 |
| Push notifications, weather Edge Function, evidence export Edge Function, photo hash verification job | planned | |
| Asset checkout screens, maintenance log, barcode, route guidance | not in this version | |

Synthetic test people (`*@test.invalid`) exist in the project from the smoke test. They are not real employees and can be deleted any time.

## 1. Conventions

**Transport.** Supabase JS client (`@supabase/supabase-js` v2). Reads go through views with `supabase.from('v_name').select(...)`. Writes go through database functions with `supabase.rpc('fn_name', { ...args })`. Direct `insert`, `update`, or `delete` on any table from the client is denied by RLS and by grants; do not write one.

**Argument naming.** Function arguments are snake_case with no prefix in the RPC call (`supabase.rpc('task_assign', { task_id, profile_id, idempotency_key })`). The SQL parameters use the same names, so the RPC argument names in this document are exact (the two exceptions, `evidence_verify(p_record)` and internal helpers, are noted where they appear).

**Timestamps.** ISO 8601 with offset, always UTC on the wire (`2026-11-14T13:02:11Z`). The database stores `timestamptz`. The client displays in America/Chicago.

**IDs.** People, shifts, tasks, assignments, evidence: `uuid`. Zones, assets, routes: text IDs that match the GeoJSON (`MOW-03`, `LOT-REA`, `EQ-14`). Zone versions: `uuid`.

**Geometry.** Sent as `{ lng, lat }` numbers in WGS84. Returned as GeoJSON geometry objects. Never send `[lat, lng]`.

**Return shape.** Every function returns one `jsonb` object:

```json
{ "ok": true, "data": { ... }, "revision": 17, "replayed": false }
```

`revision` is present when the object the function touched carries one (tasks, operating state). `replayed: true` means the idempotency key had already been processed and this is the stored result of the first call, not a second execution.

**Errors.** Functions raise with `RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'GRND-<code>: <human text>', DETAIL = '<json>'`. The Supabase client surfaces this as `error.message` starting with `GRND-` and `error.details` as a JSON string. Parse the code from the first eight characters (`GRND-423`). Codes:

| Code | Meaning | Client should |
|---|---|---|
| `GRND-401` | not signed in, or profile inactive | send to login |
| `GRND-403` | signed in but role may not do this | show message, do not retry |
| `GRND-404` | referenced row does not exist | show message, refresh list |
| `GRND-409` | revision conflict (`expected_revision` is stale) | refetch, show what changed, let the user redo |
| `GRND-410` | object is in a state that does not allow this transition (task already done, shift already ended) | refresh, do not retry |
| `GRND-422` | validation failed (missing photo, quantity out of range, bad geometry) | show `details.fields`, fix, resubmit with the same idempotency key |
| `GRND-423` | person is not qualified, or certification suspended or expired | show which capability from `details.missing` |
| `GRND-424` | asset not available (reserved, down, or wrong class) | offer another asset |
| `GRND-425` | worker has no open shift | prompt shift start |
| `GRND-426` | keep-out or hazard blocks this zone right now | show the keep-out, block the action |
| `GRND-500` | unexpected database error | retry with backoff, then surface |

Anything without a `GRND-` prefix is a PostgREST or network error and follows the offline rules in section 10.

**Idempotency.** Every function that changes data takes `idempotency_key uuid`. The client generates it (UUID v4) when the user performs the action, stores it with the queued command, and reuses the same key on every retry of that command. The server stores `(key, function, caller, result)` in `command_log` for 30 days. A repeated key with the same function and caller returns the stored result with `replayed: true`. A repeated key with a different function or caller raises `GRND-422`.

**Expected revision.** Tasks and the operating state carry an integer `revision` that increments on every change. Functions that transition a task accept an optional `expected_revision`; if supplied and stale, they raise `GRND-409`. Supply it whenever the user is acting on something they looked at (accepting, reassigning, finalizing). Omit it for fire-and-forget commands such as location upload.

**Pagination.** Views accept PostgREST `range` and `order`. Default page 50. `v_my_day` is small enough to fetch whole.

## 2. Login, session, roles

**Auth.** Supabase Auth, email and password for the pilot. UND SSO is a production gate (ADR 17) and will replace the password flow without changing anything below; the client only ever holds the Supabase session.

**Session.** On the web the client keeps the Supabase session in localStorage. On native it uses a secure storage plugin (iOS Keychain, Android Keystore, for example `capacitor-secure-storage-plugin`); Capacitor Preferences is plain storage and is not acceptable for tokens. Two adapters, one interface. Refresh is automatic in the JS client. A `401` from any call means refresh failed; sign the user out and keep the offline queue intact so it replays after the next login by the same user. A queue from user A is discarded if user B logs in on the device.

**Profile.** Every auth user has exactly one `profiles` row, created by an admin (there is no self sign-up). On login the client reads `v_me`:

```sql
v_me: id, full_name, phone, employment_tier, app_role, crew_id, crew_name, reports_to, is_student, active,
      capabilities text[]   -- codes of currently valid certifications
```

**Roles.** `profiles.app_role` is one of:

| app_role | Who | employment_tier values |
|---|---|---|
| `oversight` | Chad's supervisor. Sees everything on the map and the board, and may create, assign, reassign, and release work (Mason, Sep 7) | `oversight` |
| `admin` | Chad, Bobby, Mason | `admin` |
| `lead` | full-time employees who run a crew | `full_time` |
| `worker` | Temp 2, Temp 1 | `temp2`, `temp1` |

`auth_role()` is a SQL helper the views and functions use; it returns the caller's `app_role` or raises `GRND-401`.

**Permissions matrix.** Functions enforce this server side; the client uses it only to hide buttons.

| Action | oversight | admin | lead | worker |
|---|---|---|---|---|
| read all tasks and people | yes | yes | own crew only | own tasks only |
| create task | yes | yes | yes, within own crew's zones | no |
| assign, reassign, release | anyone | anyone | own crew members only | Temp 2 may hand their own task to a Temp 1 on the same crew, only while the operating mode is `landscaping` (GRND-403 in `snow`); the certification check still applies |
| acknowledge assignment | no | self | self | self |
| start, block, finalize task | no | self | self | self |
| shift start and end, location upload | no | self | self | self |
| set zone status | no | yes | own crew's zones | on an assigned task only |
| request certification | yes | yes | own crew | self |
| approve or deny certification | no | yes | no | no |
| pivot operating state | no | yes | no | no |
| open, close keep-out | no | yes | yes | no |

"Own crew" means `profiles.crew_id` matches, or an active `crew_placements` row matches. Row Level Security applies the same matrix to the views, so a worker selecting from `v_dispatch_board` gets zero rows rather than an error.

## 3. Views

All views are read-only, RLS filtered, and safe to poll. Column types are Postgres types; `geometry` columns come back as GeoJSON.

### 3.1 `v_my_day` (worker home screen)

One row per active assignment for the caller, ordered by `sort_key`.

```
assignment_id uuid, task_id uuid, task_revision int,
task_type text, outcome text, priority smallint, state text,
zone_id text, zone_name text, zone_version_id uuid, zone_class text, zone_geom geometry, zone_center geometry,
site text, season text,
scheduled_start timestamptz, scheduled_end timestamptz,
assigned_by_name text, assigned_at timestamptz, acknowledged_at timestamptz,
asset_id text, asset_name text, attachment_id text, attachment_name text,
required_capabilities text[], missing_capabilities text[],     -- empty means qualified
evidence_required text[],                                       -- photo_before, photo_after, material_qty, location
keepout_active boolean, keepout_reason text,
work_order_number text, work_order_title text,
sort_key int                                                    -- in_progress first, then accepted, then assigned, then by priority and scheduled_start
```

Also included, as separate one-row lookups on the same screen: `v_me` (above), `v_operating_state` (section 9), and `v_my_shift`:

```
v_my_shift: shift_id uuid, started_at timestamptz, last_location_at timestamptz, location_stale boolean,  -- stale is true when last_location_at is older than 5 minutes while the shift is open
            samples_today int
```

### 3.2 `v_task_detail`

Everything `v_my_day` has plus: `description text`, `assignment_history jsonb` (array of `{assignment_id, profile_name, assigned_at, acknowledged_at, released_at, release_reason}`), `evidence jsonb` (array of `{evidence_id, kind, path, taken_at, assessment}`), `service_record jsonb` (null until finalized), `blocked_reason text`, `created_by_name text`, `created_at timestamptz`.

### 3.3 `v_crew_availability` (dispatch, reassignment picker)

One row per active person visible to the caller.

```
profile_id uuid, full_name text, app_role text, employment_tier text,
crew_id uuid, crew_name text, placement_until timestamptz,          -- non-null when covering another crew
on_shift boolean, shift_started_at timestamptz,
last_location_at timestamptz, last_location geometry, location_stale boolean,
current_zone_id text, current_zone_name text,                        -- from the latest server assessment, null if none
open_task_count int, in_progress_task_id uuid, in_progress_zone_name text,
capabilities text[],                                                 -- valid certification codes
hours_today numeric, hours_week numeric,                             -- from confirmed time entries only; null until time confirmation ships
availability text                                                    -- 'free', 'busy', 'off_shift', 'unavailable'
```

`availability` is computed: `off_shift` if no open shift; `busy` if an in-progress task; `free` otherwise; `unavailable` if `profiles.active = false` or a placement ended.

### 3.4 `v_qualifications`

One row per (person, capability) for people the caller may see.

```
profile_id uuid, full_name text, capability_id uuid, capability_code text, capability_name text, category text,
verified_by_name text, verified_at timestamptz, expires_at timestamptz, suspended boolean, restrictions text,
valid boolean   -- not suspended, not expired
```

`v_capabilities` lists the master list: `id, code, name, category, granted_by_tier, required_for_asset_classes text[]`.

### 3.5 `v_dispatch_board` (supervisor screen)

One row per task that is not `done` or `canceled`, for tasks the caller may see.

```
task_id uuid, task_revision int, work_order_number text, work_order_title text,
task_type text, outcome text, priority smallint, state text, season text,
zone_id text, zone_name text, zone_class text, zone_center geometry, site text,
scheduled_start timestamptz, scheduled_end timestamptz, overdue boolean,
assignee_id uuid, assignee_name text, assignee_on_shift boolean, acknowledged boolean,
asset_id text, asset_name text,
required_capabilities text[],
qualified_available_count int,     -- people who are free, on shift, and hold every required capability
blocked_reason text, keepout_active boolean,
last_activity_at timestamptz
```

Companion: `v_dispatch_candidates(task_id)` is a function, not a view, because it takes an argument:

```
supabase.rpc('dispatch_candidates', { task_id })
→ { ok: true, data: [{ profile_id, full_name, availability, distance_m, on_shift, missing_capabilities: [], current_task: null, crew_name }] }
```

The caller appears in the list when they may assign to themselves (a lead can take a task).

Ordered: qualified and free first, then by distance from the zone, then busy people. Never omits anyone the caller could assign; unqualified people appear with `missing_capabilities` filled so the supervisor sees why they are greyed out.

### 3.6 `v_zone_status_current`, `v_operating_state`

Sections 8 and 9.

### 3.7 Reference views

`v_zones` (every zone with its current geometry as GeoJSON, `acres_drawn`, `needs_tracing`, `keepout_reason`), `v_keepouts`, `v_assets` (with who holds a reservation right now), `v_service_records` (the record with its evidence list, `event_count`, `head_hash`), `v_weather_events`, `v_capabilities`. All read-only, RLS filtered.

### 3.8 Certifications (approval process, v1.2)

Every capability carries `outcomes` (a list of training outcomes, see `v_capabilities`). A person is certified only through an approved request or a full-time default. There is no override anywhere: `task_assign` and `assignment_reassign` raise `GRND-423` for a missing capability no matter who calls, and the `override_qualification` argument is accepted for compatibility and ignored.

```
certification_request: { idempotency_key, profile_id, capability_code, outcomes_met: text[] (every outcome in v_capabilities.outcomes), notes? }
                       → { request_id, status: 'pending', capability_code }
                       errors: GRND-422 with details.missing listing outcomes not attested; GRND-410 if a request is already pending; GRND-403
                       who: the person, their lead, admin, oversight
certification_decide:  { idempotency_key, request_id, approve: boolean, decision_notes?, expires_at?, restrictions? }
                       → { request_id, status: 'approved'|'denied', certification_id, capability_code }      admin only
certification_suspend: { idempotency_key, profile_id, capability_code, reason } → { suspended: true }      admin, or lead for full_time-tier capabilities on own crew
certification_verify:  kept for admins (direct grant with no request), same shape as v1.1
v_certification_requests: request_id, profile_id, full_name, capability_code, capability_name, outcomes_required, outcomes_met, requested_by_name, notes, status, decided_by_name, decided_at, decision_notes, expires_at, created_at
```

Full-time employees (`employment_tier = 'full_time'`) automatically hold every capability with `auto_for_full_time = true`, which is everything except `CDL`, from the moment their profile exists. Those rows have `source = 'full_time_default'`. Broadcasts: `certification_requested` on `all`, `certification_approved` and `certification_denied` on `person:<id>`.

## 4. Shifts

### `shift_start`

```
args: { idempotency_key uuid, device_id text, location?: { lng, lat, accuracy_m, taken_at } }
data: { shift_id uuid, started_at timestamptz }
errors: GRND-410 if the caller already has an open shift (error.details carries { shift_id, started_at }, so the client adopts it instead of failing)
```

A shift belongs to the caller. One open shift per person is an exclusion constraint. If the device finds an open shift on login (`v_my_shift`), it resumes it rather than starting a new one.

### `shift_end`

```
args: { idempotency_key uuid, shift_id uuid, location?: {...}, note?: text }
data: { shift_id, started_at, ended_at, duration_minutes numeric, open_task_ids uuid[], day_log: {...} }
errors: GRND-404, GRND-410 if already ended
```

`day_log` (v1.2) is the end-of-day screen: `{ shift_id, started_at, ended_at, shift_minutes, tasks: [{ task_id, work_order_id, work_order_number, work_order_title, external_system, external_ref, external_url, zone_id, zone_name, task_type, state, started_at, ended_at, suggested_minutes }], zones: [{ zone_id, zone_name, samples, minutes }], confirmed: [...] }`. `tasks` is every task the person started during the shift with its work order and external ticket; `zones` is minutes per zone from GPS samples (gaps over 5 minutes are not counted). The same object is available any time from `day_log({ shift_id })` for the worker, their lead, or an admin.

The worker confirms it (ADR decision 12, confirmed not inferred):

```
time_entries_confirm: { idempotency_key, shift_id, entries: [{ task_id?, work_order_id?, zone_id?, external_ref?, minutes int, suggested_minutes?, note? }] }
                      → { shift_id, entries int, minutes int }
                      errors: GRND-422 empty entries; GRND-410 already confirmed for this shift; GRND-403
v_time_entries: id, profile_id, full_name, shift_id, work_order_id, work_order_number, external_system, external_ref, task_id, zone_id, minutes, suggested_minutes, note, confirmed_at
```

The client shows the suggested minutes, lets the worker edit, and submits once. Edits after confirmation are a supervisor correction (planned).

Ending a shift does not release assignments; `open_task_ids` tells the client to warn. Leads and admins can end another person's shift with `shift_end_for` (same args plus `profile_id`), used when a phone dies.

## 5. Location upload

### `location_upload`

Batch. Called every 60 seconds while a shift is open and the app is in the foreground, or immediately before any command that needs a location (start task, finalize).

```
args: { idempotency_key uuid, shift_id uuid,
        samples: [{ taken_at timestamptz, lng, lat, accuracy_m numeric, speed_mps?: numeric, heading?: numeric, battery?: smallint, source?: 'gps'|'network'|'manual' }] }   -- max 200 per call
data: { accepted int, rejected int, rejected_detail: [{ index, reason }], last_taken_at timestamptz, assessment: { zone_id, zone_version_id, result, distance_m, accuracy_m, zone_class, age_s } | null }
errors: GRND-425 no open shift, GRND-422 if a sample lacks accuracy_m or has a future timestamp (rejected samples are listed in details.rejected, the rest are accepted)
```

The server never trusts the client to say where it is relative to a zone. `assessment.result` is one of `inside`, `boundary`, `ambiguous`, `outside`, `unavailable` per ADR decision 7, computed from the newest accepted sample. The client shows it as a hint, nothing more.

Sampling rule for phase 1: foreground only, 15 to 30 seconds while moving, 60 to 120 seconds when stationary, buffered locally and flushed in one call. Background tracking is gated (ADR decision 4) and adds nothing to this contract when it passes.

## 6. Tasks and assignments

Task states and who moves them:

```
unassigned → assigned        task_assign (lead/admin)
assigned   → accepted        assignment_acknowledge (assignee)
accepted   → in_progress     task_start (assignee)
in_progress → review         service_finalize (assignee)                 -- section 7
review     → done            task_approve (lead/admin)                   -- planned, same phase
any open   → blocked         task_block (assignee, lead, admin)
blocked    → previous state  task_unblock (lead, admin)
assigned/accepted/in_progress → assigned (new person)   assignment_reassign (lead/admin)
assigned/accepted → unassigned                          assignment_release (lead/admin)
any open   → canceled        task_cancel (admin, or lead within own crew)
```

Every transition bumps `task_revision`. Every transition writes an outbox event (section 10).

### `task_create`

```
args: { idempotency_key uuid, work_order_id?: uuid, zone_id text, zone_version_id?: uuid,   -- defaults to the current version
        task_type text, outcome text, description?: text, priority?: smallint (1 high, 2 normal, 3 low; default 2),
        required_capabilities?: text[] (codes), required_asset_class?: text,
        scheduled_start?: timestamptz, scheduled_end?: timestamptz,
        evidence_required?: text[] (default derived from task_type: snow actions require photo_before, photo_after, material_qty, location; mow requires photo_after, location),
        point?: { lng, lat },
        external_ref?: { system: text, ref: text, url?: text } }     -- the ticket in the other work order system (v1.2)
data: { task_id uuid, revision 1, state 'unassigned', work_order_number text, work_order_id uuid, external_ref text }
who: admin, oversight, lead (own crew's zones)
errors: GRND-403, GRND-404 zone, GRND-422, GRND-426 if the zone has an active keep-out and task_type is not an admin task
```

If `work_order_id` is omitted the function creates a work order titled from `outcome` so every task has a human number. `work_order_link_external({ idempotency_key, work_order_id, external_system, external_ref, external_url? })` attaches or changes the external ticket later (lead, admin, oversight). `v_task_detail`, `v_my_day`, and `v_dispatch_board` carry `external_system`, `external_ref`, `external_url`, and `original_assignee_id` / `original_assignee_name` (the first person assigned; never changes on reassign), and `assignment_history` entries carry `assigned_by_name` and `reassigned_from` so the full handoff chain is visible.

### `task_assign`

```
args: { idempotency_key uuid, task_id uuid, profile_id uuid, expected_revision?: int,
        asset_id?: text, attachment_id?: text, note?: text, override_qualification?: boolean }
data: { assignment_id uuid, task_id, revision, state 'assigned', notified: true }
errors: GRND-403, GRND-409, GRND-410 if the task is done or canceled,
        GRND-423 with details.missing = ['BOBCAT'] when the person lacks a required capability (admins may pass override_qualification: true, which records the override on the assignment; leads cannot),
        GRND-424 if the asset is reserved by another open assignment, down, or its class does not match required_asset_class
```

Assigning reserves the asset and attachment for the task's scheduled window (exclusion constraint on `asset_reservations`). The assignee's device gets a realtime event and a push notification (push is planned, realtime is phase 1).

### `assignment_acknowledge`

```
args: { idempotency_key uuid, assignment_id uuid, expected_revision?: int, location?: {...} }
data: { assignment_id, task_id, revision, state 'accepted', acknowledged_at }
errors: GRND-403 if not the assignee, GRND-410 if already acknowledged, released, or the task moved on
```

Acknowledging is the worker saying "I saw it". It is required before `task_start`. The dispatch board shows unacknowledged assignments older than 10 minutes with `acknowledged = false` so the supervisor can call.

### `assignment_reassign`

One click in the supervisor UI, one call here.

```
args: { idempotency_key uuid, task_id uuid, to_profile_id uuid, expected_revision?: int, reason?: text,
        keep_asset?: boolean (default true), asset_id?: text, attachment_id?: text, override_qualification?: boolean }
data: { assignment_id (new), released_assignment_id, task_id, revision, state 'assigned', previous_assignee_name text }
errors: as task_assign, plus GRND-410 if the task is not assigned, accepted, or in_progress
```

Releases the old assignment with `release_reason = reason`, creates the new one with `reassigned_from` pointing back, transfers the asset reservation when `keep_asset` is true, and moves the task back to `assigned` so the new person must acknowledge. Evidence already captured stays attached to the task, tagged with who captured it. Both devices get realtime events; the old assignee's screen shows "reassigned to <name> by <name>".

### `assignment_release`

```
args: { idempotency_key uuid, assignment_id uuid, expected_revision?: int, reason text }
data: { task_id, revision, state 'unassigned' }
```

### `task_start`

```
args: { idempotency_key uuid, task_id uuid, expected_revision?: int, location: {...}, asset_id?: text, attachment_id?: text }
data: { task_id, revision, state 'in_progress', started_at, assessment: { result, distance_m } }
errors: GRND-425 no open shift, GRND-410 not accepted, GRND-426 keep-out active, GRND-422 location missing
```

A location is required, but an `outside` assessment does not block starting. It is recorded and shown to the supervisor.

### `task_block`, `task_unblock`, `task_cancel`

```
task_block:   { idempotency_key, task_id, expected_revision?, reason text, photo_path?: text }  → { task_id, revision, state 'blocked' }
task_unblock: { idempotency_key, task_id, expected_revision?, note?: text }                     → { task_id, revision, state (restored) }
task_cancel:  { idempotency_key, task_id, expected_revision?, reason text }                     → { task_id, revision, state 'canceled' }
```

Blocking releases nothing; the assignment stays so the supervisor knows who hit the problem.

## 7. Evidence and service finalization

### 7.1 Photo upload flow

Photos never go through a database function. They go to Supabase Storage, and the record of them goes through `service_finalize`.

1. Client captures the photo and uploads the original bytes (ADR decision 8: originals are never replaced by derivatives). Accepted types: JPEG, PNG, HEIC; 8 MB limit per object. The client may make a smaller derivative for its own display but never uploads it in place of the original. It computes `sha256` of the original bytes and generates a `client_photo_id` (UUID v4).
2. Client calls `evidence_upload_url` (the name is kept from v1.0; it registers the object and returns its path, there is no signed URL):

```
args: { task_id uuid, kind 'before'|'after'|'issue'|'material'|'other', client_photo_id uuid, sha256 text, taken_at timestamptz, location?: {...} }
data: { path text, bucket 'evidence', upload 'direct', signed_url null }
errors: GRND-403 not the assignee or supervisor of that task, GRND-410 task not open, GRND-422 bad sha256 format or client_photo_id already used for another task
```

   `path` is deterministic: `evidence/{yyyy}/{mm}/{task_id}/{kind}-{client_photo_id}.jpg` (year and month from `taken_at`, UTC). Calling again with the same `client_photo_id` returns the same path with `replayed: true`, so retries are safe.
3. Client uploads the bytes with `supabase.storage.from('evidence').upload(path, blob, { contentType: 'image/jpeg', upsert: false })`. The bucket's insert policy only accepts a path this function registered for this user, so nothing else can be written there. On network failure, keep the blob on disk and retry the same path; a second upload of an existing path fails harmlessly and the client moves on to finalize.
4. The bucket denies update and delete to `authenticated`. A photo, once uploaded, cannot be replaced from the app. A wrong photo is superseded by uploading another and noting it in `service_finalize`; nothing is deleted.
5. The client keeps `{client_photo_id, path, sha256, kind, taken_at, location}` and passes that list to `service_finalize`.

Metadata the client must send with each photo: `taken_at` from the device clock at capture, and the freshest location sample at capture if one is under 30 seconds old. At finalize the server checks that each declared photo was registered by this user for this task, that the declared `sha256` matches the registered one, and that the object exists in the bucket; anything missing is `GRND-422` with `details.fields` such as `['photos.<id>.not_uploaded', 'photos.before']`. Comparing the stored bytes to the declared hash is a planned background job (`hash_verified_at`), not part of finalize.

### 7.2 `service_finalize`

The one call that creates the liability record. Everything else is preparation for it.

```
args: { idempotency_key uuid, task_id uuid, expected_revision?: int,
        action text,                               -- plowed, shoveled, salted, sanded, brined, mowed, trimmed, inspected, other
        started_at timestamptz, completed_at timestamptz,     -- device times
        location: { lng, lat, accuracy_m, taken_at },         -- at completion, required
        photos: [{ client_photo_id, path, sha256, kind, taken_at, location? }],
        materials?: [{ material_code text, qty numeric, unit text }],   -- 'bulk_salt', 'sand', 'brine' with lb, lb, gal
        asset_id?: text, attachment_id?: text,
        conditions?: { air_temp_f?, surface_temp_f?, precip?: text, snow_depth_in? },   -- what the worker observed; the server adds the weather snapshot separately
        notes?: text,
        supersedes_photo_ids?: uuid[] }            -- photos to mark as replaced, never deleted
data: { service_record_id uuid, task_id, revision, state 'review',
        assessment: { result, distance_m, accuracy_m, zone_class, age_s },
        evidence_event_seq int, row_hash text, verification_url text }     -- verification_url is a relative path until the export Edge Function ships
errors: GRND-425 no open shift, GRND-410 task not in_progress, GRND-403 not the assignee,
        GRND-422 with details.fields naming any missing requirement from the task's evidence_required
        (for example ['photos.before', 'materials'] ), a completed_at earlier than started_at, or a hash mismatch,
        GRND-409 revision conflict
```

What the server does in one transaction: verifies the caller, the shift, the task state, and each declared photo against Storage; computes the location assessment; inserts the `service_records` row; inserts one `evidence_events` row per photo and one for the record itself, each with its per-record sequence number and hash chained to the previous event for that record (ADR decision 8); appends a material transaction per line when materials ship; moves the task to `review`; writes the outbox event. The client never sends a hash, a sequence number, or an assessment.

`verification_url` is a link to the minimal evidence export for that one record (ADR decision 15), usable by a supervisor right away.

### 7.2b Reading evidence

A photo is read with `supabase.storage.from('evidence').createSignedUrl(path, 3600)` (or `download(path)`); the bucket's select policy allows it only for people who can see the task, so no extra authorization call is needed. Signed URLs expire; never store one.

### 7.3 `evidence_verify`

```
supabase.rpc('evidence_verify', { p_record: service_record_id }) → { ok: true, events: n, head: hash } or { ok: false, bad_seq, why }
```
Recomputes the chain for one record. Anyone who can see the record can call it.

### 7.4 `task_approve` (lead or admin)

```
args: { idempotency_key uuid, task_id uuid, expected_revision?: int, note?: text }
data: { task_id, revision, state 'done' }
```

Approval is a separate evidence event. It does not edit the service record.

## 8. Zone status (snow)

Scoped status, ADR decision 6. Cleared, salted, and sanded are separate facts.

### `zone_status_set`

```
args: { idempotency_key uuid, zone_id text, zone_version_id?: uuid, event_id?: uuid (defaults to the active storm event, or null in summer),
        activity 'cleared'|'salted'|'sanded'|'brined'|'mowed'|'inspected', at?: timestamptz (default now), location?: {...},
        task_id?: uuid, asset_id?: text, note?: text }
data: { zone_status_id uuid, zone_id, activity, at, by_name }
errors: GRND-403, GRND-404, GRND-422
```

Setting a status is not the same as finalizing a service record. Status is the fast "the crew says it is done" flag that the map shows; the service record is the evidence. Finalizing a service record with `action = 'salted'` also sets the status, so workers usually never call this directly; supervisors do when correcting or marking work done by another department.

### `v_zone_status_current`

One row per (zone, activity) for the active event, or the last 24 hours in summer.

```
zone_id text, zone_name text, zone_class text, site text, event_id uuid,
activity text, at timestamptz, by_profile_id uuid, by_name text, task_id uuid, service_record_id uuid,
minutes_ago int, stale boolean          -- stale after 6 hours during an active storm event
```

The map colors a zone from these rows (`cleared` and `salted` both present means fully serviced).

## 9. Operating state (summer, winter, pivot)

### `v_operating_state`

One row.

```
mode 'landscaping'|'snow', revision int, changed_at timestamptz, changed_by_name text, reason text,
active_event_id uuid, active_event_name text,     -- storm name when mode is snow
carryover_task_count int                           -- open tasks from the other mode still visible
```

### `operating_state_pivot` (admin)

```
args: { idempotency_key uuid, expected_revision int (required), to_mode 'landscaping'|'snow', reason text, event?: { name text, starts_at timestamptz } }
data: { revision (new), mode, active_event_id }
errors: GRND-403, GRND-409 if expected_revision is stale, GRND-422
```

Clients must acknowledge a new revision by calling `operating_state_ack({ revision, device_id })` after they have applied it; `v_operating_state.devices_on_revision` counts acknowledgments in the last 12 hours. Pivoting to `snow` opens a weather event if none is active (named from `event.name` or the date); pivoting to `landscaping` closes the active event. Active work is never hidden by a pivot (ADR decision 10).

## 10. Offline, retry, and realtime

### Command queue

The worker app keeps a durable FIFO queue of commands `{ id, fn, args (with idempotency_key), created_at, attempts, last_error }` on disk (Capacitor Preferences or SQLite, not memory). Rules:

1. Enqueue first, then attempt. The UI updates optimistically for acknowledge, start, block, and status; it shows "pending" for finalize until the server answers, because the assessment and the record ID only exist server side.
2. Replay strictly in order per task. A finalize for task X is never sent before the start for task X.
3. Retry on network errors and `GRND-500` with backoff 5s, 15s, 60s, then every 5 minutes, forever, until success or the user cancels the command.
4. Do not retry `GRND-403`, `GRND-404`, `GRND-410`, `GRND-423`, `GRND-424`, `GRND-426`. Surface them, remove the command, and refetch `v_my_day`.
5. On `GRND-409`, refetch the object, show the user the current state, and let them redo the action with a new idempotency key. Never auto-resolve a revision conflict on finalize.
6. On `GRND-422`, keep the command, show the fields, let the user fix them, and resubmit with the same idempotency key.
7. Photos upload independently of the queue; `service_finalize` waits in the queue until every photo it references has uploaded.
8. `location_upload` is its own queue with a cap: keep the newest 2,000 samples, drop older ones with a local note. It never blocks the command queue.
9. Identity: the queue is keyed to the user ID. When a different user signs in, the previous user's queue and drafts are kept on the device but quarantined: never shown to the new user, never sent under their session, replayed only when the original user signs in again. Deletion is explicit (that user, or a device reset), never automatic.
10. Dependencies: commands on the same task are a chain. Each successful command returns `revision`; the client stores it and uses it as `expected_revision` for the next queued command on that task. If a supervisor changed the task in between, the next command gets `GRND-409` and the chain stops for review; it is never auto-resolved. One outstanding command per task is acceptable and simpler.
11. Ordering per person: `shift_end` is queued after every task command captured during the shift, so an offline finalize replays before the shift closes. If a finalize is rejected, the evidence stays on the device in a "needs review" state and the worker or lead deals with it the next day; nothing is deleted.
12. Idempotency lifetime: keys are stored for 30 days. A queued command older than that is replayed with the same key; if the server no longer remembers it, it runs as new, which is correct for commands that were never received. Never change a queued command's payload after it is created; if the user edits, make a new command with a new key. Failed validation is not stored, so fixing a `GRND-422` and resubmitting with the same key runs the command.

### Realtime

Supabase Realtime on Postgres changes, filtered by RLS, plus a broadcast channel.

| Channel | Payload | Who subscribes |
|---|---|---|
| `postgres_changes` on `tasks` | full row on insert and update | dispatch board (all visible), worker (own tasks) |
| `postgres_changes` on `assignments` | full row | worker: filter `profile_id = me`; supervisor: crew |
| `postgres_changes` on `operating_state` | full row | everyone |
| `postgres_changes` on `zone_status` | full row | map, dispatch board |
| broadcast `crew:{crew_id}` | `{ type, task_id, assignment_id, from_name, message, revision, at }` | members of the crew |
| broadcast `person:{profile_id}` | same shape | that person only |

`type` values in phase 1: `assigned`, `reassigned_to_you`, `reassigned_away`, `released`, `task_blocked`, `review_requested`, `approved`, `pivot`, `keepout_opened`, `keepout_closed`. Every broadcast is generated from the `outbox` table by a trigger, never from the client, so a notification always corresponds to a committed change. The client treats a broadcast as a hint to refetch, not as the truth; the row from `postgres_changes` or the view is the truth.

Push notifications (APNs, FCM) are planned and will reuse the same `type` values.

## 11. Synthetic example records

All people, tasks, and events below are made up. Zone IDs match the current GeoJSON. Use these in mocks and tests.

```json
// v_me
{ "id": "0d2d3f2e-1111-4a5b-9c3e-000000000001", "full_name": "Jordan Test", "phone": "701-555-0101",
  "employment_tier": "temp2", "app_role": "worker", "crew_id": "5f6a0000-0000-4000-8000-000000000010",
  "crew_name": "Snow walks A", "reports_to": "0d2d3f2e-1111-4a5b-9c3e-000000000002", "is_student": true, "active": true,
  "capabilities": ["TOOLCAT", "SALT_SPREADER", "SMALL_TOOLS"] }

// v_operating_state
{ "mode": "snow", "revision": 17, "changed_at": "2026-11-14T11:30:00Z", "changed_by_name": "Chad Test",
  "reason": "4 inches overnight, T1 by 6:30", "active_event_id": "9a9a0000-0000-4000-8000-000000000031",
  "active_event_name": "Storm 2026-11-14", "carryover_task_count": 3 }

// v_my_day (one row)
{ "assignment_id": "7b7b0000-0000-4000-8000-000000000101", "task_id": "3c3c0000-0000-4000-8000-000000000201", "task_revision": 2,
  "task_type": "shovel", "outcome": "Walks around Memorial Union open and salted before 6:30", "priority": 1, "state": "assigned",
  "zone_id": "SW-2", "zone_name": "Walk route 2 (Union, Chester Fritz)", "zone_version_id": "aaaa0000-0000-4000-8000-000000000301",
  "zone_class": "walk_route", "zone_geom": { "type": "LineString", "coordinates": [[-97.0742, 47.9228], [-97.0721, 47.9231]] },
  "zone_center": { "type": "Point", "coordinates": [-97.0731, 47.9229] }, "site": "main", "season": "snow",
  "scheduled_start": "2026-11-14T10:30:00Z", "scheduled_end": "2026-11-14T12:30:00Z",
  "assigned_by_name": "Bobby Test", "assigned_at": "2026-11-14T10:02:11Z", "acknowledged_at": null,
  "asset_id": "EQ-07", "asset_name": "Toolcat 5600 #2", "attachment_id": "ATT-03", "attachment_name": "V-blade 60in",
  "required_capabilities": ["TOOLCAT"], "missing_capabilities": [],
  "evidence_required": ["photo_before", "photo_after", "material_qty", "location"],
  "keepout_active": false, "keepout_reason": null,
  "work_order_number": "WO-2026-0143", "work_order_title": "Storm 2026-11-14 T1 walks", "sort_key": 30 }

// rpc task_assign, request and response
{ "idempotency_key": "c1c1c1c1-0000-4000-8000-000000000001", "task_id": "3c3c0000-0000-4000-8000-000000000201",
  "profile_id": "0d2d3f2e-1111-4a5b-9c3e-000000000001", "expected_revision": 1, "asset_id": "EQ-07", "attachment_id": "ATT-03" }
{ "ok": true, "data": { "assignment_id": "7b7b0000-0000-4000-8000-000000000101", "task_id": "3c3c0000-0000-4000-8000-000000000201",
  "revision": 2, "state": "assigned", "notified": true }, "revision": 2, "replayed": false }

// rpc task_assign, qualification error (error.message and error.details as the client sees them)
"GRND-423: Jordan Test is not certified for BOBCAT"
"{\"missing\":[\"BOBCAT\"],\"profile_id\":\"0d2d3f2e-1111-4a5b-9c3e-000000000001\",\"task_id\":\"3c3c0000-0000-4000-8000-000000000201\"}"

// rpc location_upload
{ "idempotency_key": "d2d2d2d2-0000-4000-8000-000000000002", "shift_id": "8e8e0000-0000-4000-8000-000000000401",
  "samples": [ { "taken_at": "2026-11-14T11:05:00Z", "lng": -97.07312, "lat": 47.92291, "accuracy_m": 6.5, "speed_mps": 1.1, "battery": 81, "source": "gps" },
               { "taken_at": "2026-11-14T11:05:20Z", "lng": -97.07301, "lat": 47.92294, "accuracy_m": 5.8, "speed_mps": 1.3, "battery": 81, "source": "gps" } ] }
{ "ok": true, "data": { "accepted": 2, "rejected": 0, "last_taken_at": "2026-11-14T11:05:20Z",
  "assessment": { "zone_id": "SW-2", "zone_version_id": "aaaa0000-0000-4000-8000-000000000301", "result": "inside" } } }

// rpc evidence_upload_url
{ "task_id": "3c3c0000-0000-4000-8000-000000000201", "kind": "before", "client_photo_id": "e3e3e3e3-0000-4000-8000-000000000003",
  "sha256": "9f2c0e4d8b7a6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d", "taken_at": "2026-11-14T11:06:02Z",
  "location": { "lng": -97.07305, "lat": 47.92293, "accuracy_m": 7.2, "taken_at": "2026-11-14T11:06:00Z" } }
{ "ok": true, "data": { "path": "evidence/2026/11/3c3c0000-0000-4000-8000-000000000201/before-e3e3e3e3-0000-4000-8000-000000000003.jpg",
  "signed_url": "https://<project>.supabase.co/storage/v1/object/upload/sign/evidence/...", "expires_at": "2026-11-14T13:06:02Z" } }

// rpc service_finalize
{ "idempotency_key": "f4f4f4f4-0000-4000-8000-000000000004", "task_id": "3c3c0000-0000-4000-8000-000000000201", "expected_revision": 4,
  "action": "salted", "started_at": "2026-11-14T11:06:30Z", "completed_at": "2026-11-14T11:48:10Z",
  "location": { "lng": -97.07222, "lat": 47.92308, "accuracy_m": 8.9, "taken_at": "2026-11-14T11:48:05Z" },
  "photos": [ { "client_photo_id": "e3e3e3e3-0000-4000-8000-000000000003", "path": "evidence/2026/11/3c3c.../before-e3e3....jpg", "sha256": "9f2c...c1d", "kind": "before", "taken_at": "2026-11-14T11:06:02Z" },
              { "client_photo_id": "e5e5e5e5-0000-4000-8000-000000000005", "path": "evidence/2026/11/3c3c.../after-e5e5....jpg", "sha256": "1a2b...9e8f", "kind": "after", "taken_at": "2026-11-14T11:47:50Z" } ],
  "materials": [ { "material_code": "bulk_salt", "qty": 120, "unit": "lb" } ],
  "asset_id": "EQ-07", "attachment_id": "ATT-03",
  "conditions": { "air_temp_f": 18, "surface_temp_f": 22, "precip": "light snow", "snow_depth_in": 4 },
  "notes": "Ice under the drift by the Union loading dock, salted twice." }
{ "ok": true, "data": { "service_record_id": "1b1b0000-0000-4000-8000-000000000501", "task_id": "3c3c0000-0000-4000-8000-000000000201",
  "revision": 5, "state": "review",
  "assessment": { "result": "inside", "distance_m": 0, "accuracy_m": 8.9, "zone_class": "walk_route" },
  "evidence_event_seq": 3, "row_hash": "5d41402abc4b2a76b9719d911017c592d0e4f6a7b8c9d0e1f2a3b4c5d6e7f8a9",
  "verification_url": "https://<project>.supabase.co/functions/v1/evidence-export?record=1b1b0000-0000-4000-8000-000000000501" }, "revision": 5, "replayed": false }

// broadcast on person:{profile_id}
{ "type": "reassigned_away", "task_id": "3c3c0000-0000-4000-8000-000000000201", "assignment_id": "7b7b0000-0000-4000-8000-000000000101",
  "from_name": "Bobby Test", "message": "SW-2 reassigned to Sam Test (Toolcat 2 needed at Lot 43)", "revision": 6, "at": "2026-11-14T11:20:00Z" }

// v_crew_availability (one row)
{ "profile_id": "0d2d3f2e-1111-4a5b-9c3e-000000000003", "full_name": "Sam Test", "app_role": "worker", "employment_tier": "temp1",
  "crew_id": "5f6a0000-0000-4000-8000-000000000010", "crew_name": "Snow walks A", "placement_until": null,
  "on_shift": true, "shift_started_at": "2026-11-14T10:45:00Z", "last_location_at": "2026-11-14T11:19:30Z",
  "last_location": { "type": "Point", "coordinates": [-97.0768, 47.9214] }, "location_stale": false,
  "current_zone_id": "SW-4", "current_zone_name": "Walk route 4 (Wilkerson, Squires)",
  "open_task_count": 1, "in_progress_task_id": null, "in_progress_zone_name": null,
  "capabilities": ["SMALL_TOOLS", "SALT_SPREADER"], "hours_today": null, "hours_week": null, "availability": "free" }
```

## 12. Campus events and planning reminders (v1.4)

Two feeds, pulled every morning at 6:00 Central by pg_cron and pg_net, kept a year ahead: the UND events calendar (calendar.und.edu, Localist JSON, `source = 'und'`) and UND Athletics (fightinghawks.com iCal, `source = 'ath'`, every sport including hockey). Athletics rows carry `sport` and `home`; venues are matched to campus points through `event_venues` so home games at REA, the Betty, Bronson Field, Albrecht Field, and Hyslop land on the map, and `on_campus` says whether the venue is UND ground (the Alerus Center is not).

`watch` means grounds should plan for it. A rule sets it at import: every home game on campus, home football at the Alerus (flagged with that reason so it can be cleared), outdoor and stadium venues, large public venues, and titles such as commencement, homecoming parade, tailgate, move-in, open house. A lead, admin, or oversight can flip any event either way and their choice survives every later sync.

Watched events get reminders at 30, 21, 14, 7, 5, 3, 2, 1 days before, the day of, and the day after. Each is raised once as broadcast `event_reminder` on `all` with `{ reminder_id, event_id, days_before, message, starts_at, zone_id }` and stays open in `v_event_reminders` until acknowledged. If a feed has not synced successfully for two days, `event_sync_failed` is broadcast once a day and `v_event_sync_health` shows the last error.

```
v_campus_events:     event_id text ('und:<id>' or 'ath:<uid>'), source, title, url, description, sport, home, venue_name, address, location (GeoJSON point), on_campus,
                     zone_id, zone_name, starts_at, ends_at, all_day, first_date, last_date, audience text[], topics text[], watch, watch_reason, watch_set_by_name,
                     notes, work_order_id, work_order_number, days_until int, next_reminder_on date, last_synced_at     -- upcoming only
v_event_reminders:   reminder_id, event_id, source, title, venue_name, zone_id, starts_at, days_before, due_on, raised_at, acknowledged_at, acknowledged_by_name, open
v_event_sync_health: source, last_success, last_error_at, last_error, active_events
event_watch:         { idempotency_key, event_id text, watch boolean, reason?, notes?, work_order_id? } → { event_id, watch, title }     lead, admin, oversight
event_reminder_ack:  { idempotency_key, reminder_id } → { reminder_id }; GRND-410 if already acknowledged                        lead, admin, oversight
```

Suggested screens: Planning (watched events by date with `days_until`, notes, a Watch toggle on any event, a button that calls `task_create` for the prep work and passes the result back through `event_watch.work_order_id`), an Open reminders strip on the dispatch board (`v_event_reminders?open=eq.true`), and the sync health line under Admin.

## 13. Equipment list, machine photos, people photos (v1.5)

Equipment is a list, not map markers, until Mason places machines himself. `v_assets` is the whole list for any signed-in person; only admins add or edit. Every machine can carry one photo and every person one avatar, both in the private `media` bucket (8 MB, JPEG, PNG, WebP, HEIC). Paths are fixed by the server: `asset_photo/<ASSET-ID>/<uuid>.<ext>` and `avatar/<profile-id>/<uuid>.<ext>`; the old file stays in storage and `photo_path` simply moves to the new one. Read a file with `GET {url}/storage/v1/object/authenticated/media/<path>` and the user's bearer token; the response is the image bytes.

```
v_assets:            id, name, asset_type, class, make, model, year, serial, status, active, home_zone_id, location (GeoJSON point or null), hour_meter, barcode,
                     required_capability_code, compatible_with text[], howto_md, notes, attrs, photo_path, photo_updated_at,
                     holder_id, holder_name, holder_avatar_path, holder_task_id, holder_zone_id, in_use boolean, updated_at
                     -- holder_* are the open reservation from task_assign(asset_id); released by task_approve, assignment_release, task_cancel
v_me:                adds avatar_path
v_crew_availability: adds avatar_path and holding jsonb [{ asset_id, name, class, task_id }]
asset_upsert:        { idempotency_key, id text (^[A-Z]{2,4}-[0-9A-Za-z]{1,8}$, uppercase), name, asset_type, class, make?, model?, year?, serial?,
                       required_capability_code?, compatible_with?, status?, home_zone_id?, location? (GeoJSON point), hour_meter?, barcode?, howto_md?, notes?, attrs?, active? }
                     → { id, name, revision }     admin only; GRND-422 on a bad id or unknown type/status/capability
media_upload_path:   { kind: 'asset_photo'|'avatar', target_id text (asset id or profile id), content_type? }
                     → { bucket: 'media', path, upload: 'direct' }     asset_photo: admin; avatar: the person or admin
                     then POST {url}/storage/v1/object/media/<path> with the bearer token, Content-Type, x-upsert: false, body = the file
media_apply:         { idempotency_key, path } → { kind, target_id, path }     records the upload on the asset or profile; GRND-404 if the path was not registered by you, GRND-422 if the file is not in storage yet
```

Suggested screen: an Equipment entry in the left menu that lists `v_assets` ordered by class then name, each row with the photo, name and id, class, make, model, year, hours, a status pill (`in use` when `in_use`, otherwise `status`), and the holder's avatar and name with the zone they are in. Tapping a row opens the machine (how to run it, notes, serial, barcode). Admins get Add and Edit forms that call `asset_upsert` and the photo flow. A person's own avatar upload lives on the profile screen (`media_upload_path` with `kind: 'avatar'` and their own id).

## 14. What Codex can build now

Against this document and the examples: login and profile screen, My Day list and task detail, shift start and stop with the staleness indicator, the proof of service form (before photo, after photo, quantity, notes, submit with pending state), the offline queue with the retry rules above, the dispatch board, the crew availability list, the assign and one-click reassign flow with the candidate picker, the operating state banner, and the equipment list with photos (section 13). Use a local mock that returns the section 11 shapes and raises the section 1 errors.

Do not build: anything that writes a table directly, any client-side geofence decision, anything that stores a hash or sequence, asset checkout, materials inventory screens, weather, or route guidance.

## 15. Change log

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-09-07 | First publication. Nothing implemented yet; all items planned. |
| 1.5 | 2026-09-07 | Migration 0014: `media` bucket, machine photos and people avatars, `asset_upsert`, `media_upload_path`, `media_apply`, `v_assets` rebuilt with photo and holder fields. Section 13. Placeholder map assets removed; the equipment list is empty until Mason adds machines. |
| 1.4 | 2026-09-07 | Migration 0012: events rebuilt for two sources, athletics iCal (all sports, hockey included) with venue matching, sync health alerts, event ids are text. Smoke test 83 checks. |
| 1.3 | 2026-09-07 | Migration 0011: campus events from calendar.und.edu with watch flags, reminder ladder, daily sync. Section 12. |
| 1.2 | 2026-09-07 | Migration 0010. Certification approval flow with training outcomes, full-time defaults (all but CDL), no qualification override anywhere; Temp 2 to Temp 1 handoff only in landscaping mode; `original_assignee` and full handoff chain on every task; oversight may create, assign, reassign, release; external work order references on tasks and work orders; `day_log` in `shift_end`, `time_entries_confirm`, `v_time_entries`; originals uploaded not derivatives; evidence read rule; secure native storage wording; offline queue rules 9 to 12 answering Codex's review. |
| 1.1 | 2026-09-07 | Everything in sections 2 to 10 implemented in migrations 0001 to 0009 and smoke tested. Changes from 1.0: photos upload directly to the registered path (no signed URL); `dispatch_candidates` wraps its list in `{ ok, data }`; `location_upload` returns `rejected_detail`; `evidence_verify`, `certification_verify`, `certification_suspend`, `shift_end_for`, `operating_state_ack`, and the reference views in 3.7 added; `task_unblock`, `task_cancel`, `task_approve` implemented as specified. Realtime wiring is in place but has not been exercised from a real client yet. |

Proposed changes go in `docs/api-contract-changes.md` as a dated entry with the requesting assistant, the reason, and the proposed shape. Claude folds accepted changes into this document with a new version line above.
