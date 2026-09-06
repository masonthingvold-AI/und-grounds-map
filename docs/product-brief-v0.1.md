# UND Grounds Workflow

Product brief v0.1 | September 6, 2026 | Draft for Mason and Claude

## Purpose

Give every employee a clear, achievable next assignment when they arrive, with the location, equipment, qualifications, and completion expectations in one place. Supervisors and full-time employees should be able to delegate outcomes, manage coverage, and respond to new work without repeatedly returning to the shop or explaining every step.

This captures Mason's proposed direction, not features already implemented or approved UND operating policy. Mason proposed the map; the head of facilities expressed a desire for a new map; Mason's prior work influenced it. The previous entirely external-origin description was incorrect. Final A/C classification awaits the actual idea-log framework; this document does not modify that log.

## Existing project and implementation boundary

Current repository: `/Users/masonthingvold/Claude/Projects/UND Landscaping/und-grounds-map/`. Read its AGENTS.md before changes. The current app is a single-file Leaflet map with per-device work storage and export/import. Shared authentication, synchronized assignments, and notifications require a shared service and enforced access rules; changing the visible role in a local page would not provide those capabilities.

Keep the current map usable under its single-file/no-framework rule. Plan the shared service as a separate, explicit extension. This brief is saved outside the repository while Claude is working there. No app code, geography, accounts, or operating permissions have been changed.

The handoff reports all 11 mowing polygons as placeholders, with equipment at the shop placeholder point. Actual geometry, route instructions, asset positions, and equipment availability must be verified before operational use. Preserve stable feature IDs and tracing flags. Existing acreage remains the record value under repository rules.

## People and access

Reporting hierarchy, app permissions, employment tier, and equipment qualifications are separate fields. Temp 2 is above Temp 1, but neither tier automatically qualifies someone for a Toolcat or any other equipment.

| Person or role | Proposed view | Proposed authority |
|---|---|---|
| Leadership above Chad | Campus workload, coverage, progress, blockers, and resource needs | Read-only oversight by default; exact scope to confirm |
| Chad | All crews, assignments, zones, equipment, and availability | Assign and reassign across crews |
| Bobby | Supervisor workspace | Supervisor scope and relationship to Chad to confirm |
| Mason | Management workspace as requested | Include in the proposed management group; operational scope to confirm |
| Full-time employee / crew lead | Other full-timers' work, own crew, own equipment and assignments | Delegate to their own people; cross-crew moves go to a supervisor |
| Temp 2 | Own assignments, relevant zone information, equipment instructions, qualifications | Update own work; higher tier does not imply delegation authority |
| Temp 1 | Same simple personal daily view | Update own work within approved capabilities |

Use a tree view to show who reports to whom and current assignments. Allow an effective-dated temporary crew placement for coverage. Keep qualification records editable only by a designated verifier. Actual accounts and verifier roles remain to be configured.

Leadership oversight should explain delays through blockers, priority changes, staffing, and equipment availability. Avoid using elapsed time alone as an employee performance score.

## Daily experience and user stories

- As a temporary employee, I open My Day and see where to go, what result is needed, which equipment is assigned, relevant hazards, and whom to contact so I can begin without repeated instructions.
- As a crew lead, I see my team's availability and qualifications so I can assign work to someone who can perform it.
- As Chad or another authorized supervisor, I enter a work-order description and location, select eligible people and equipment, and send the assignment so I can delegate the result.
- As a full-time employee, I photograph a fallen branch and place it on the map so the responsible zone team can respond.
- As a supervisor, I reassign unfinished work when someone leaves or is absent so nothing silently falls out of the plan.
- As a qualified replacement operator, I open the assigned machine's snow route and instructions so I can cover an absence.

Worker home screen: My next task, remaining tasks, assigned equipment, map, and a prominent Need help / blocked action. Suggested task states: assigned, accepted, in progress, blocked, ready for review, completed, canceled. A worker can finish a shift without falsely marking unfinished work complete.

Supervisor home screen: incoming work, crew tree, available qualified people, assigned equipment, and blocked/unassigned work. Assignment form asks for outcome, location, priority, timing, required qualifications, equipment, and completion evidence. Detailed steps are available where useful, particularly for unfamiliar routes.

## P0: First shared operational release

| Requirement | Acceptance criteria |
|---|---|
| Shared accounts and scoped permissions | A lead can assign only within their crew, including through direct service requests. A temp cannot open another person's private record. Chad can view all crews. |
| Employee capabilities | Record qualification, equipment class/attachment scope, verifier, verification date, expiration when applicable, and restrictions. Missing, expired, or suspended approval prevents an assignment requiring it. Skills and preferences never substitute for certification. |
| Availability | Show on shift, available, assigned, blocked, off shift, and expected shift end. Assigned staff can still be candidates for a supervisor-approved move, with displaced work shown. |
| Work orders and tasks | A work order can contain multiple tasks and locations. Every active task has an accountable owner or appears explicitly in the unassigned queue. Show outcome, priority, location, and equipment. |
| Equipment assignments | Track individual units, required qualifications, attachments, operational status, and booking interval. Conflicting bookings and out-of-service units are flagged before dispatch. |
| Map and zones | Connect work to stable zone IDs and a point, line, or area. Work spanning multiple zones remains one work order with separate task/location records. Unverified geography is visibly labeled. |
| Reporting an issue | A lead or supervisor can attach a photo, description, and confirmed location. Route it to the responsible zone team; absent or ambiguous ownership sends it to supervisor triage. Urgent hazards are visible before routine work. |
| Assignment notification | The assignee receives an in-app notification, can acknowledge it, and sees later changes. The dispatcher can distinguish sent from acknowledged. Retry does not create duplicate assignments. |
| Completion and blockers | Workers record results, notes/photos when required, and reasons for blocked work. Unfinished work remains visible at shift end. |
| Reassignment | One action opens eligible replacements and displaced tasks. Confirming transfers remaining work, notes, equipment needs, and ownership together; old and new assignees are notified. Completed history remains attributed correctly. |
| Connection and edit conflicts | Show when data is stale or an update is unsent. Concurrent assignment changes produce a conflict message rather than silently overwriting an owner. |

A proposed first pilot: one verified zone, one crew lead, a small temp crew, and a verified equipment subset. Measure the complete assign-to-complete workflow before expanding across campus.

## P1: Coverage, time, and smarter dispatch

- Filter replacement candidates by current qualification, shift overlap, availability, equipment access, and relevant skills. Explain why each person is eligible and what work would need coverage.
- Add a redistribution preview for all unfinished tasks of an absent employee. Tasks without an eligible replacement remain in an explicit exception queue.
- Start with transparent assignment rules. Later use prior task experience and stated strengths to improve suggestions, with a supervisor choosing the reassignment. Do not let learned preferences grant qualifications or silently reshuffle crews.
- Add push notifications after delivery behavior is tested on the crew's devices. Keep the in-app queue as the record of assignment.
- Add start, pause, resume, and finish time entries linked to task, work order, and zone. Separate travel, active work, breaks, and blocked time; support corrections without erasing history.
- Add optional on-duty location sharing and zone-entry suggestions. Display location timestamp and accuracy. Zone presence alone does not establish work performed; workers confirm the task and time. Define who can view location and how long it is retained before rollout.
- Report work-order labor time and zone totals without double-counting one person's overlapping entries. Distinguish person-hours from elapsed project time.
- Consider email/work-order intake after identifying the existing system. Manual entry is sufficient for the pilot; an email does not automatically dispatch work.

## P2: Campus knowledge and snow operations

### Campus knowledge layers

Sprinkler heads, water mains, shutoff valves, holes, recurring hazards, access restrictions, and maintenance notes. Each record needs location confidence, source, last verification date, responsible department, and relevant instructions. Temporary hazards have open/resolved states. Display approved infrastructure records to appropriate roles; unknown locations remain unknown.

### Snow coverage and route guidance

Build verified routes with ordered segments, start point, direction, equipment/attachment compatibility, clearing instructions, priority, hazards, and completion state. A qualified replacement can open the machine's route and resume remaining segments. Downloadable instructions should remain usable during poor connectivity. Turn guidance depends on a verified traversable network; a drawn line alone is insufficient.

Carry forward the repository's snow priorities: T1 open 6:30 a.m.; T2 open 7:30 a.m.; T3 noon next day; T4 by request. Confirm the underlying standard before implementing operational deadlines.

### Department collaboration

Explore UAS mapping and civil engineering collaboration for imagery, surface conditions, and mapped assets. Treat these as potential partners, not commitments. A drone image does not establish the location of buried water mains or valves; use verified department records and field confirmation for those layers.

### Separate future idea

Adapt the assignment, qualification, equipment, and crew hierarchy model for construction project managers and subcontractors. Preserve this as a later product idea; do not expand the UND pilot to serve that market yet. Its formal idea-log classification remains pending.

## Core records and relationships

Employee -> reporting lead, crew, employment tier, app permissions, qualifications, skills, availability.

Qualification -> employee, capability/equipment scope, verifier, validity, restrictions.

Zone -> geometry, responsible crew, hazards, assets, work orders.

Equipment -> unit ID, class, attachments, required qualifications, availability, assignments.

Work order -> requested outcome, source/reference, priority, locations, tasks.

Task -> work order, zone/location, requirements, assignees, accountable owner, equipment, state, completion record.

Assignment -> employee/task/equipment links, scheduled interval, acknowledgment, reassignment history.

Time entry -> employee, task/work order, zone, start/end, activity type, correction history.

Location observation -> employee or equipment, timestamp, coordinates, accuracy; separate from confirmed work/time.

Hazard/asset -> mapped feature, source, confidence, owner, verification, status.

## Proposed pilot measures

These are draft targets, not measured results or agreed commitments. Establish a one-week baseline and review after four pilot weeks.

- 90% of pilot arrivals can identify their next task within two minutes.
- 100% of assignments requiring equipment approval pass a current qualification check.
- Zero silent double-bookings or lost ownership during reassignment in pilot verification.
- Reduce repeated requests for next-task instructions by 30% from baseline, using a simple crew tally.
- Reduce supervisor-reported daily coordination time by 20% from baseline; separately track why tasks are delayed.

## Decisions and dependencies

Before live shared use, Mason and supervisors confirm the actual reporting tree, Bobby's scope, Mason's operational permissions, who verifies certifications, Temp 1/2 distinctions, and cross-crew coverage authority. Product/technical owner confirms the shared service, identity setup, device access, and synchronization approach. No hosting or vendor choice is assumed here.

Before the pilot, the crew verifies pilot zone geometry, equipment records, qualification requirements, and completion expectations. Identify how incoming work orders are referenced. Before location/time rollout, operations confirms tracking visibility, on-duty boundaries, retention, and correction workflow. Before snow guidance, Grounds verifies traversable segments, machine compatibility, and designated ADA routes.

No deadline was supplied. Sequence: confirm records and permissions; pilot shared dispatch; add coverage and time; validate snow guidance; expand campus knowledge and department collaboration.

Carry forward existing data questions: all 11 real mowing polygons; sidewalk widths; lot area and accessible stalls; designated ADA routes; snow storage corners; Bobcat attachments/pusher boxes; crew shifts per route; and unidentified red symbols on the prior snow map.
