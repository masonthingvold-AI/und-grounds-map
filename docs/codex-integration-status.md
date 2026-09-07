# Operations integration status

Date: September 7, 2026
Branch: codex/worker-dispatch-preview
Contract: v1.4, with main merged through 1534ac1.

## Implemented

The operations entry point uses Supabase Auth and the real read/RPC adapter. The shared UND shell shows the signed-in profile and role-specific navigation. Connected screens include My Day and task details, shifts and day-log confirmation, the owner-scoped offline queue, dispatch and people, certification requests and qualifications, planning and reminders, admin sync health, zone status, and assets.

Foreground GPS samples are buffered and uploaded during an enabled active shift. Queue retries preserve idempotency keys, chain task revisions, stop conflicting dependent actions, and isolate each account. Shift end flushes buffered samples; confirmation queued offline retains the day log.

Zone status uses assigned task zones and their saved geometry. The map respects the removal of placeholder boundaries: it asks for the campus boundary instead of inventing one. Messages remain local drafts.

## Verification completed

- 24 local tests passed covering shell roles, queue retries and conflicts, account isolation, zone filtering, boundary handling, and legacy prototype behavior. Legacy prototype tests do not verify the backend.
- All six provisioned accounts signed in and returned their own v_me profiles through the real adapter.
- Read-only checks covered Jordan task detail, lead and oversight dispatch data and candidates, lead/admin qualifications, planning events and reminders, and admin sync health.
- Browser checks covered Jordan login/My Day/task detail and lead planning/certifications, including the required TOOLCAT outcomes.

## Unfinished or blocked

- Live mutation tests have not run. Automatic approval review rejected creating persistent test records. A bounded test-run approval request is pending with Mason. Do not report dispatch, shift, certification, or Watch mutations as verified live.
- Photo upload and proof finalization are disabled. Mason says never send a hash; the current contract requires sha256. Original photos can be retained in local drafts. The proposed server-side digest contract is in api-contract-changes.md.
- Personal schedules, delivered messages, and Face ID require contracts not yet published. The UI must not imply those services work.
- Reopening the app fully offline still requires verification; cached reads work within an authenticated session.
- Background GPS is a separate native-device gate. This pilot tracks only while the page is visible.

No direct table writes, client geofence decisions, or client hash submissions were added.
