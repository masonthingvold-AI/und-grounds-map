# Backlog (decisions and asks from Mason, not yet built)

Kept in date order. When something ships, move it to the contract change log and delete it here.

## 2026-09-07 Beds, pots, courts, and quick check-offs

- Map every flower bed and every flower pot as its own feature (bed = polygon, pot = point). Volleyball courts as polygons.
- Per feature, a maintenance log with dated activities. Beds and pots: planted (with what), mulched, weeded, deadheaded, watered. Volleyball courts: tilled. This applies to flower beds, pots, and volleyball courts only, not to mowing areas or walks. Each entry records the employee, the time, and whether the phone was in that bed when it was logged (server-side assessment, same as tasks).
- Check-off has to be near zero effort: open the app near a bed, the bed is already selected from GPS, one tap on "Weeded" and it is logged. No photo required by default; photo optional. A supervisor can require a photo per activity type later.
- No "days since" coloring (Mason, Sep 7). Each bed and court shows a plain dated time stamp per activity (last mulched Sep 3 2:10 pm by Sam, last weeded ..., last tilled ...). Logging the activity again replaces the stamp automatically; the history stays in the log underneath.
- Data model sketch: `zones` gains classes `bed`, `pot`, `court`; `zone_activity` table (zone_id, activity, at, by, assessment, note, photo optional, plant list jsonb); view `v_zone_care_current` (last date per activity per zone); function `zone_activity_log(idempotency_key, zone_id, activity, note?, photo?)` allowed for any signed-in worker on shift, no task required.
- Flower crew works from this, not from tasks (Mason, earlier): bed designs with plant lists live here so they can tell weeds from plantings.

## 2026-09-07 Map look

- The 2025 mowing map PDF is the look Mason wants, not the required source. Add a clean plan-style basemap (light gray streets and building footprints, our colored zones on top) as a third basemap next to Satellite and Street.
