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
