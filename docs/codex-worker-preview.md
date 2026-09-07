# Worker and dispatch preview

Local synthetic preview built against API contract v1.0, September 6, 2026. Source paths: operations/ and tests/operations.test.mjs. No edits to the map shell or database. Open operations/index.html through a localhost HTTP server or approved HTTPS host.

Implemented for review: worker My Day, shift start/end, foreground device position indicator, acknowledgment, task start/block, original photo drafts in IndexedDB, quantity/notes, local completion review, supervisor assignment and reassignment candidate checks, simulated seasonal pivot with carryover, persistent action queue and attention states. Persona selector and offline checkbox are demonstration controls, never authentication.

The mock adapter is operations/model.mjs. It models a subset of contract commands with revisions and idempotent results; it is not security enforcement. The preview sends no requests to Supabase and never claims a valid geofence assessment. Device location is not uploaded as telemetry; action context may be saved locally when explicitly starting/finalizing a task. Use synthetic data and test photos only.

Not yet implemented: actual login, Supabase adapter, upload intents/token flow, secure native storage, background tracking, service worker shell cache, live realtime/push, location batching, authenticated evidence export, new-task creation, equipment picker, or backend-backed authorization. No claim of full operational MVP completion. Offline simulation demonstrates durable command retry while the page remains available; loading the app itself while disconnected is a later step.

Queue conflicts stay visible and retain evidence. The demo allows one outstanding command per task, avoiding inventing dependency revision semantics absent from the contract. User switching is only a demo persona change; it does not discard drafts. The supervisor JSON export is marked preview-only and is not a forensic report. Originals are retained pending clarification of the contract's derivative upload rule.

Run validation: node --test tests/operations.test.mjs. Browser smoke test should cover acknowledgment, reload persistence, offline action replay, blocked candidate, and supervisor pivot. Field GPS, locked screen, and actual backend gates remain untested.

Next: Claude resolves the proposed contract entries, implements endpoints, and provides a synthetic test environment. Codex connects the adapter and expands integration tests without modifying the schema. The original map remains at ../index.html.

Verified in browser: offline acknowledgment adds a saved action; reconnect processes it exactly once and displays accepted; supervisor candidate picker disables Sam for missing TOOLCAT. Seven model tests pass. Live backend, photo upload, and field GPS remain unverified.
