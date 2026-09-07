# Campus and daily dashboard update

Merged main b170efb before reading contract v1.2. All six provisioned accounts successfully authenticated and read v_me on September 7, 2026. Roles, crews, and capability lists matched Mason's handoff. Sessions were ended after the checks; no operations RPCs or smoke-test reset were run.

UI changes: Messages and Ask my crew lead under Connect; Assets visible in Work; campus-only parcel view without city tiles, excluding parcels outside the existing campus search extent; selected-zone map, remaining assignments and suggested crew-lead questions; My Day forecast and schedule panel; opening shift prompt followed by explicitly labeled planned Face ID confirmation and a test-shift option. Original index.html was updated only by merging Claude's main, not edited by Codex.

Remaining integration: preview still uses synthetic assignments and simulated shift commands. Messaging only saves drafts for the current browser session. Schedule has an unconnected state. Face ID requires passkey/backend authentication support or native secure-session integration; it is not implemented. Forecast uses the public National Weather Service API for fixed campus coordinates, with an unavailable state. Campus parcel outlines and operational zones need final human review; no tracing flags or source geometry were changed.

Validation: 14 Node checks; browser review of opening prompt, weather dashboard, campus rendering and selected-zone task filtering. Fixed missing NWS update timestamp fallback and remote parcels during review.
