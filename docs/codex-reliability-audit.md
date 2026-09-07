# Operations reliability audit

September 7, 2026. Result: improved pilot, not production-ready.

## Fixed

- Database permission/constraint codes no longer become retryable simply because their numeric value exceeds 500. Only HTTP 500 through 599, network failures, and GRND-500 retry.
- An action currently being transmitted cannot be canceled locally. Cancellation failure is displayed in Saved actions.
- Task start disables actions while GPS is pending. Shift start/end has a concurrent-click guard. Certification decisions disable both approve and deny until the response.
- Reload preserves the selected screen instead of resetting to My Day.
- Buffered location samples flush against their original shift and remain buffered if saving fails.

## Checks completed

28 automated tests pass, including new regressions for error classification, in-flight cancellation and shift buffering. Every operations module passes syntax checks. Seven tests cover the older mock model and are not live-backend evidence.

All six provisioned test accounts authenticated and returned the expected role and crew through the real adapter. Mobile browser walkthrough checked lead and admin navigation, My Day, map, zone status, assets, local message drafts, people, qualifications, planning, Settings, theme switching, reload, and sign-out. Admin calendar sync health returned successful source updates. No console warnings or errors were returned in the captured lead walkthrough.

## Gaps and limits

- Service records, Evidence, Keep-outs, and Mode are placeholder screens. Their menu entries load but do not implement the promised workflows.
- Messages are drafts only. Personal schedule and Face ID are not connected.
- Photo submission/finalization remains blocked by the client-hash contract conflict documented in api-contract-changes.md.
- Live operational mutations were not tested. Automatic approval review previously rejected persistent synthetic records; bounded test approval remains pending. Local tests cannot certify real dispatch/shift/certification writes.
- Fully offline reopening, interrupted evidence uploads, physical-device GPS, desktop responsive layouts and simultaneous multi-tab operation still need dedicated end-to-end testing. This audit does not certify those behaviors.
- Background location is not available in this foreground web pilot.

The next release gate is resolving these gaps and running approved live workflows on test accounts, followed by real-phone field testing. No zero-defect or production-readiness claim is made.
