# UND Grounds App, working spec v0.1

Date: September 6, 2026
Owner: Mason Thingvold
Status: draft for Chad and Bobby to react to

## The one sentence

A campus map app where anyone on the grounds crew can open their phone and know what to do today, and where Chad can take a work order, assign people and equipment to it, and let them run with it.

## Why

Right now the day gets run by full-timers walking back to the shop and telling people what to do. Temps and students wait. Chad carries everything in his head and in email. Nobody can see who is free, who is certified for what, or what got done where. The map we already built shows the ground. This adds the people, the equipment, and the work on top of it.

## Who uses it

The org is a tree, and what you can see and do depends on where you sit in it.

| Tier | Who | Sees | Can do |
|---|---|---|---|
| Oversight | Chad's boss, and that person's boss | Everything, read only. Summaries, not a live feed of individuals. | Nothing. Not a tool for catching people. |
| Admin | Chad, Bobby, Mason | Everyone, every task, every zone, all equipment | Create work orders, assign anyone, reassign, edit certs, edit zones and equipment |
| Full-time | Each full-time employee | Other full-timers, their own kit, their own people, their own zones | Assign tasks to their own people only, report issues, close tasks |
| Temp 2 | Senior temps | Their own tasks, their zone, the equipment they are certified on | Accept tasks, report issues, mark done, log time |
| Temp 1 | New temps and students | Same as Temp 2 with fewer certs | Same as Temp 2 |

Temp 2 is above Temp 1. The difference is certifications and trust, not a separate app.

## What every person carries

- Name, tier, who they report to, phone
- Certifications: each piece of equipment they are cleared to run (Toolcat yes or no, 4100 mower, Bobcat, Workman, blower, plow, etc.), plus non-equipment certs (chainsaw, aerial lift, pesticide, CDL if it matters)
- Home zones: the mowing areas or campus zones they normally cover
- Availability: on shift, off, on a task, done for the day
- Current assignments: tasks and equipment checked out to them

Certifications are the key to the whole thing. When Chad opens a work order and picks "needs a Toolcat," the app only shows him people who are certified and free.

## What every piece of equipment carries

- Unit, make, model, year, attachments
- Who is certified on it
- Where it lives, where it is now (from the last person who checked it out)
- Status: in service, down, needs repair
- Current assignment: which task and which person

## The daily loop

1. Chad gets a request (email, phone, walking by). He opens the app, taps New Work Order, types a plain description, taps the location on the map or picks a zone, adds a photo if there is one.
2. The app shows who is available and certified for what the job needs. He taps names and equipment. Done. He does not write out steps.
3. Those people get a notification. They open it and see the location, the description, the equipment, and who else is on it.
4. They go do it. GPS logs when they arrive in the zone and when they leave. They mark it done, add a note or a photo.
5. If someone leaves early or gets pulled, Chad or their full-timer taps Reassign and picks the next person. One click. The new person gets the same notification.
6. At the end of the day, the app has a record: what was done, by who, in which zone, how long it took, on which work order.

A temp opening the app in the morning sees: your tasks today, in order, on the map. If they have none, they see the standing work for their zone (mow, trim, blow, check) so they are never standing at the shop waiting.

## Issue reporting from anyone

Anyone in the app can take a picture, drop it on the map, and type a line. "Tree branch down here." The app routes it to the full-timer and temps for that zone and to Chad. Chad can turn it into a work order in one tap.

## GPS and time

Phase one: the app records when a person enters and leaves a zone while on shift, tied to whatever task they are on. That gives time per zone and time per work order without anyone filling in a timesheet.

Rule from the start: location is only recorded while on shift and only for work, nobody sees a live dot of an individual except the person themselves and their direct lead, and the oversight tier sees totals, not people. Put this in writing before the first temp downloads it, or it will get called tracking and die.

## Campus knowledge layer

Separate from tasks. A set of map layers with things you need to know and cannot see: sprinkler heads, irrigation zones and controllers, water mains, shutoff valves, known holes and washouts, buried lines, hydrants, salt boxes, snow storage corners. Anyone can look. Admins can add. This is the layer to build with other departments: UAS for a drone flyover of all of campus, civil engineering for the grading and drainage side. That partnership is its own project and can start once the base app is real.

## Snow

Snow routes stay a separate mode. Each machine route becomes a guided run: a Google Maps style step list on the phone, leg by leg, so anyone certified on that machine can jump in and run someone else's route. The route data already exists from the redesign (14 machine routes, tiers, timing). What is new is the guidance screen and the "I am taking over this machine" button that reassigns the route.

## Phases

**Phase 0 (done):** static map, mowing areas, snow routes, equipment, per-phone work tracking. Files in a repo.

**Phase 1, people and assignments (next):** user accounts and the tree, certifications, equipment register, work orders, assignment and reassignment, notifications, the daily task list. Photo issue reports. This is the part that changes how the shop runs.

**Phase 2, time and location:** zone entry and exit logging, time per zone and per work order, end of day summary for Chad.

**Phase 3, knowledge layer:** utilities and hazards layers, UAS and civil engineering partnership.

**Phase 4, snow guidance:** turn by turn route runs, machine takeover.

## How it gets built

Phase 0 is a single web page with no server, which is exactly why it cannot do accounts, notifications, or GPS logging. Phase 1 needs a backend. The plan that keeps it cheap and keeps both Claude and ChatGPT able to work on it:

- Keep the map and the GeoJSON as they are. They become one screen in the app.
- Add a hosted database with logins and push notifications (Supabase or Firebase, free tier is plenty for a crew this size).
- Ship it as a web app that installs to the phone home screen (a PWA). No App Store, no UND IT procurement to start. Works on iPhone and Android.
- Everything stays in the GitHub repo so either AI tool can read the whole thing and pick up where the other left off.

Cost to run: zero until it is proven. If Chad's boss wants it official later, that is the point to talk to UIT about hosting it on a UND domain and using UND logins.

## Decisions I need

1. Backend: Supabase or Firebase. Either works. Supabase is plain SQL and easier for both AIs to reason about.
2. First test group: Mason, Chad, Bobby, one full-timer, two or three temps. Enough to prove the loop, small enough to fix fast.
3. The location rule above. Chad signs off on it before anyone is asked to install the app.
4. Who owns the certification list. Chad or Bobby has to be the one who says a student can run a Toolcat.

## Saved for later

The same system is a project management app for a job site: subs instead of temps, trades instead of certs, work orders instead of RFIs. Different product, same bones.

---

## v0.2 additions (September 6, 2026, after the second pass with Mason)

### Decisions made

- Backend: Supabase.
- Test group: Mason, Chad, Bobby, one full-timer, two or three temps.
- Location rule: Mason will take it to Chad. Chad and Bobby own the master certification list. Full-timers get a second tier they can grant themselves: Toolcats, mowers, small misc tools.

### Crews that are not zone crews

Two crews work across zones instead of inside one: the mow crew and the flower crew. They need a crew view (what my crew is on today, in order, across campus) instead of a zone view. Same data, different screen.

The flower crew gets a bed layer: each bed drawn on the map with its planting plan (what is in it, where, photo of it at its best) so a new person can tell a planting from a weed. That layer is the one to link to the public UND map or app if UND ever wants a campus plants feature.

### Keep-out and hazards

- Sprayed areas: a full-timer or admin marks an area as sprayed with the product and the re-entry time. It shows red on everyone's map until the time passes, then clears itself. The crew phone warns if GPS puts them inside it.
- Hazards: anyone can drop a hazard (beehive, wasp nest, hole, washout, downed line) with a photo. Chad and Bobby get the notification with the when and where. It stays on the map until a certified person closes it. Certifications drive who gets offered the job, same as any task.

### Snow, the field side

- Every walk segment, lot, and road on the snow map has a live status: not started, in progress, cleared, salted, sanded (salted and sanded can both be true). The operator taps it from the machine or the status comes from GPS when a unit is assigned to that route.
- Attachment on the unit: when an operator takes a machine they pick the attachment (plow, pusher box, broom, blower, bucket). That gives who used what, and when something comes back broken, who had it last.
- Route guidance: each machine route is a step list on the phone so anyone certified can run someone else's route. Takeover button reassigns the route.

### Equipment log and barcodes

Every unit and attachment gets a label with a barcode or QR code. Scan it in the app and it opens that unit: who has it, current attachment, hours, last service, open issues, and the how-to page (start-up, quirks, tips, what breaks). Scanning also does check-out and check-in, so the log of who had what writes itself. Service and repairs get logged against the unit with a photo and a note. Chad gets a list of units due for service.

### MyUND app

My UND is UND's mobile app, run by UIT, built on Modo Labs (the "Modo Communicate" module is the messaging side). Modo apps can embed a hosted web page as a module. That means the snow status map (cleared, salted, sanded, by walk, lot, and road) can be shown inside My UND as a page we host, with no work by UIT beyond adding the module and approving the page. Ask: a "Campus snow status" module in My UND pointed at our status page. Talk to UIT once the status page exists and has run through one snow event.

### Ecopia AI, what it is and whether it helps

Ecopia sells map data extracted from imagery by AI: building footprints, land cover in 3D (grass, trees, pavement, sidewalks, parking, water) for 400 plus US cities, transportation features (sidewalks, crosswalks, curbs), and custom feature extraction from imagery you give them. Delivery is through their data portal and API and as Esri layers. There is no free tier or sample for a campus; it is a sales conversation and priced per area.

What it would give us: a ready-made polygon for every patch of grass, every sidewalk, every lot, every tree canopy on campus. That is exactly the tracing work the map needs and it is the part nobody has time for.

What to do with it: worth one email to their sales team asking for the 3D land cover and transportation layers for the UND campus extent (about 2 square miles) and whether they do academic pricing. If the number is reasonable, it replaces months of tracing. If not, the UAS drone flyover plus a free tool (segment the orthophoto ourselves) gets most of the way there, and the city's own GIS already gives us parcels, roads, and building outlines for free.

Do not buy anything before the app has run for a season. The tracing can be done by hand in the meantime and the acreage numbers of record already exist.

### Map scope, settled

The map shows only what UND owns plus about two blocks around it. The city's parcel records (City of Grand Forks open data, "Parcel Owner Info Active") are loaded as a layer: 59 parcels under UND, the State of ND for UND, the State Board of Higher Ed, the UND Alumni Association and Foundation, the UND Aerospace Foundation, the Bronson property, and the two Greek alumni corporations the city lists. Ralph Engelstad Arena did not match an owner name in the city records; the arena parcel is probably listed under the State or a different name and needs a look. Everything outside the hand-drawn campus boundary is dimmed. Mason draws the boundary and the zones on the iPad.
