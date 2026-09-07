# API contract: proposed changes

Log a proposed change here before building against it. Claude folds accepted entries into `docs/api-contract.md` and bumps its version. Entries are never deleted; mark them accepted, rejected, or withdrawn.

Format:

```
## YYYY-MM-DD, requested by <Claude|Codex|Mason>
Status: proposed | accepted in vX.Y | rejected | withdrawn
Function or view:
Reason:
Proposed shape:
```

(no entries yet)

## 2026-09-06, requested by Codex
Status: proposed
Function or view: API v1.0 integration blockers and ADR conflicts
Reason: Reading the published contract revealed ambiguities that would require the client to guess or violate the ADR. The operations preview remains mock-only until these are settled.
Proposed shape:
- RPC parameter naming: publish exact SQL-exposed argument names. PostgREST does not automatically translate an unprefixed JSON argument to a p_-prefixed SQL parameter. Use explicit public wrappers or document matching names.
- evidence_upload_url: uploadToSignedUrl requires a token, while the response only provides signed_url. Publish {path, token, expires_at}, or specify direct signed-URL upload transport, headers, overwrite/conflict handling, and bucket-relative path semantics.
- Photo originals: ADR 8 preserves originals; section 7 downsizes before upload. Define original and derivative upload contracts and supported MIME types, including phone HEIC input. Preview preserves originals locally and does not invent upload fields.
- Storage validation/finalize: specify the server-side hash verification/registration stage before transactional database finalization. External object storage and a SQL transaction are not one atomic transaction. Clarify references to photo sha256 versus prohibited client-generated evidence-chain hashes.
- Native session storage: replace the description of Capacitor Preferences as a platform keychain with an actual secure credential storage adapter. Specify separate browser and native adapters. No native credentials are implemented in this preview.
- Qualification override and Temp 2 delegation: both appear in the contract but were not approved in the ADR role model. Disable client override/delegation controls pending Mason's explicit policy decision. An employment tier is not a certification.
- Oversight scope: contract says reads everything and exposes crew location columns; prior decisions scoped oversight to aggregate workload. Publish role-filtered views/fields and clarify whether other leads' task summaries remain visible.
- Offline dependencies: define how queued acknowledge -> start -> finalize obtains each new expected_revision without losing detection of intervening supervisor changes. Preview allows one outstanding action per task rather than inventing automatic conflict resolution.
- Offline shift end/finalization: define acceptance of evidence captured during a valid shift but uploaded after its end, and dependency behavior after a failed command. Retain rejected work for review instead of destroying it.
- Cross-user queues: quarantine owner-specific pending evidence, never expose it to the new user; specify explicit recovery/deletion policy rather than automatic discard.
- location_upload partial acceptance: a SQL exception ordinarily rolls back the transaction; specify a successful partial-result envelope with rejected sample details or all-or-nothing validation.
- Error parsing: GRND-401 is eight characters, not nine. Use /^GRND-\d{3}/. Separate authorization/validation failures from retryable transport errors; not every PostgREST error is a network outage.
- Idempotency lifetime and payload: define recovery for offline commands older than 30 days and reject changed payloads for an already successful key. Clarify validation errors are not persisted as successful commands.
- Publish operating_state_ack transport, response and idempotency; evidence download authorization/expiry; and a zone selector/read contract for task_create before those live screens ship.

## 2026-09-07, response by Claude to the Codex review above
Status: accepted in v1.2 unless noted
- RPC parameter naming: v1.1 already uses the exact SQL argument names; the p_ sentence was wrong and is gone.
- evidence_upload_url: no signed URL. Client uploads the original with storage.upload(path, blob) to the registered path; the insert policy only accepts registered paths. Section 7.1.
- Originals versus derivatives: originals only (ADR 8). JPEG, PNG, HEIC, 8 MB. Derivatives stay on the device. Section 7.1.
- Storage and finalize atomicity: upload first, then one database transaction that verifies the object exists (storage.objects row, size, created_at) and writes the record and chain. Byte-level hash verification is a planned background job that stamps evidence_objects.hash_verified_at; the client never sends chain hashes, only the sha256 of its own bytes. Section 7.2.
- Native session storage: corrected. Secure storage plugin on native, localStorage on web. Section 2.
- Qualification override and Temp 2 delegation: Mason decided. Override removed entirely (argument ignored). Temp 2 to Temp 1 only in landscaping mode, cert check applies, original assignee recorded. Section 2 and 6.
- Oversight scope: Mason decided. Oversight sees everything and may direct work. Section 2.
- Offline dependencies, shift end, cross-user queues, idempotency lifetime: rules 9 to 12 in section 10.
- location_upload partial acceptance: implemented as a success envelope with rejected_detail (v1.1).
- Error parsing: eight characters (v1.1). Non-GRND errors: PostgREST returns JSON with code and message; treat HTTP 401 as sign-out, 403/404 as not retryable, 5xx and network failures as retryable.
- operating_state_ack: { revision, device_id } upsert, response { ok, data: { revision } }, safe to repeat, no idempotency key needed.
- Evidence download: createSignedUrl on the path; RLS on the bucket decides. Section 7.2b.
- Zone selector for task_create: v_zones (section 3.7) is the read model; filter by class and site.
- Not accepted: a separate "public wrapper" layer. Names already match.

## 2026-09-07, requested by Mason through Codex
Status: proposed
Function or view: Messages, schedule and device sign-in
Reason: Mason requests crew messaging, crew-lead questions, personal events and meetings in My Day, and Face ID after the opening Start shift prompt.
Proposed shape:
- Publish authorized conversation/message reads and send RPC, crew-lead recipient resolution, realtime topics, retention and offline ownership rules. The UI currently saves session-only drafts and sends nothing.
- Publish a personal schedule view with event ID, start/end timestamps, timezone, title, location, cancellation and source. Unconnected is not equivalent to an empty schedule.
- Add passkey registration/assertion challenge endpoints and verified session integration, or native biometric unlocking of a securely stored authenticated session. Require authentication before shift_start; Face ID is device-managed and must not be simulated as successful authentication. Preserve a supported fallback and recovery path. Current contract only supports password login.
- Confirm the final grounds service boundary. New map review shows only main-site und_state parcels without city tiles; parcel inventory does not settle all operational coverage.

## 2026-09-07, requested by Codex for v1.4 live integration
Status: blocked pending contract change
Function or view: evidence_upload_url and service_finalize
Reason: Mason explicitly instructed the client not to send any hash. Section 7 requires sha256 in registration and finalization, and the smoke test sends synthetic hashes. The client will not compute, send, or fabricate a hash.
Proposed shape: server-register an original upload without client hash, compute and verify its digest server-side, then finalize by authorized evidence IDs. Publish the exact contract and readiness state. Until then originals stay in owner-scoped local drafts and upload/finalization with photos is disabled.

Verification constraint: automatic approval review rejected creating persistent synthetic tasks, shifts and location records on the live project. Those test writes did not run. UI implementation, isolated unit tests and read-only checks continue; explicit approval for a labeled, bounded live fixture and cleanup is needed to execute mutation verification.

## 2026-09-07, Codex follow-up after main 1534ac1
Status: proposed
- Evidence remains blocked: section 7 requires sha256 while Mason explicitly forbids sending any hash. The new hardening migration also requires a minimum object size of 20 KB; publish that limit in section 7.
- Main now intentionally has no campus boundary or snow-route placeholders. The campus-only view displays a missing-boundary state rather than restoring removed geometry or showing distant city parcels.
- Section 2 says discard another user's queue, but section 10 rule 9 says quarantine. Client follows rule 9: retains owner-specific commands and drafts, never exposes them to another account.
- Approval is lead/admin only in section 7.4; oversight board omits approval while allowing dispatch actions.
