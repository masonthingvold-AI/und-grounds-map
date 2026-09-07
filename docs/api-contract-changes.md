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
