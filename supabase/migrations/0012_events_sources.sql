-- 0012 Campus events, rebuilt for two sources: calendar.und.edu (Localist JSON) and fightinghawks.com (Sidearm iCal).
-- Replaces the 0011 tables (prototype data only). Adds venue lookup, ICS parsing, sync health alerts.

drop view if exists public.v_event_reminders; drop view if exists public.v_campus_events;
drop table if exists public.event_reminders; drop table if exists public.campus_events; drop table if exists public.event_sync_log;
select cron.unschedule(jobname) from cron.job where jobname like 'und-events-%';

-- ---------- venues: name patterns to campus points (athletics gives names only) ----------
create table public.event_venues (
  id serial primary key,
  pattern text not null,                          -- case-insensitive regex on the venue name
  name text not null,
  location geometry(Point, 4326),
  on_campus boolean not null default true,
  note text
);
insert into public.event_venues(pattern, name, location, on_campus, note) values
 ('ralph engelstad', 'Ralph Engelstad Arena', st_setsrid(st_makepoint(-97.0848, 47.9214), 4326), true, 'hockey; REA lots and walks'),
 ('betty engelstad', 'Betty Engelstad Sioux Center', st_setsrid(st_makepoint(-97.0856, 47.9222), 4326), true, 'volleyball, basketball'),
 ('bronson field', 'Bronson Field', st_setsrid(st_makepoint(-97.0870, 47.9245), 4326), true, 'soccer'),
 ('albrecht field', 'Albrecht Field', st_setsrid(st_makepoint(-97.0830, 47.9240), 4326), true, 'softball'),
 ('kraft field', 'Kraft Field', st_setsrid(st_makepoint(-97.0830, 47.9235), 4326), true, 'baseball'),
 ('hyslop', 'Hyslop Sports Center', st_setsrid(st_makepoint(-97.0832, 47.9208), 4326), true, 'track, tennis'),
 ('memorial union', 'Memorial Union', st_setsrid(st_makepoint(-97.0693, 47.9216), 4326), true, null),
 ('chester fritz auditorium|chester fritz performing', 'Chester Fritz Auditorium', st_setsrid(st_makepoint(-97.0821, 47.9192), 4326), true, 'shows; lots and walks'),
 ('gorecki', 'Gorecki Alumni Center', st_setsrid(st_makepoint(-97.0722, 47.9171), 4326), true, null),
 ('twamley quad|the quad', 'Twamley Quad', st_setsrid(st_makepoint(-97.0741, 47.9228), 4326), true, 'outdoor'),
 ('wellness center', 'Wellness Center', st_setsrid(st_makepoint(-97.0640, 47.9212), 4326), true, null),
 ('alerus', 'Alerus Center', st_setsrid(st_makepoint(-97.0842, 47.9143), 4326), false, 'football; city venue, not UND grounds');
alter table public.event_venues enable row level security;
create policy event_venues_read on public.event_venues for select to authenticated using (true);

create or replace function public.venue_lookup(p_venue text) returns public.event_venues
language sql stable as $$
  select v from public.event_venues v where p_venue ~* v.pattern order by v.id limit 1
$$;

-- ---------- events ----------
create table public.campus_events (
  id text primary key,                              -- 'und:<localist id>' or 'ath:<sidearm uid>'
  source text not null check (source in ('und','ath')),
  external_id text not null,
  title text not null,
  url text,
  description text,
  sport text,                                       -- athletics only
  home boolean,                                     -- athletics only
  venue_name text,
  address text,
  location geometry(Point, 4326),
  on_campus boolean,
  zone_id text references public.zones(id),
  starts_at timestamptz not null,
  ends_at timestamptz,
  all_day boolean not null default false,
  first_date date, last_date date,
  audience text[] not null default '{}',
  topics text[] not null default '{}',
  raw jsonb not null default '{}'::jsonb,
  watch boolean not null default false,
  watch_reason text,
  watch_set_by uuid references public.profiles(id),
  notes text,
  work_order_id uuid references public.work_orders(id),
  first_seen_at timestamptz not null default now(),
  last_synced_at timestamptz not null default now(),
  active boolean not null default true,
  unique (source, external_id)
);
create index campus_events_start_idx on public.campus_events(starts_at) where active;
create index campus_events_watch_idx on public.campus_events(starts_at) where active and watch;
alter table public.campus_events enable row level security;
create policy campus_events_read on public.campus_events for select to authenticated using (true);

create table public.event_reminders (
  id uuid primary key default gen_random_uuid(),
  event_id text not null references public.campus_events(id) on delete cascade,
  days_before int not null,
  due_on date not null,
  raised_at timestamptz,
  acknowledged_by uuid references public.profiles(id),
  acknowledged_at timestamptz,
  unique (event_id, days_before)
);
create index event_reminders_due_idx on public.event_reminders(due_on) where raised_at is null;
alter table public.event_reminders enable row level security;
create policy event_reminders_read on public.event_reminders for select to authenticated using (true);

create table public.event_sync_log (
  id bigint generated always as identity primary key,
  source text not null,
  page int,
  requested_at timestamptz not null default now(),
  request_id bigint,
  ingested_at timestamptz,
  events int,
  error text
);
alter table public.event_sync_log enable row level security;
create policy event_sync_log_read on public.event_sync_log for select to authenticated using (public.auth_role() in ('admin','oversight'));

-- ---------- rules ----------
create or replace function public.reminder_ladder() returns int[] language sql immutable as $$ select array[30, 21, 14, 7, 5, 3, 2, 1, 0, -1] $$;

-- what makes an event a planning item by default; a person's decision always wins over this
create or replace function public.event_auto_watch(source text, title text, topics text[], audience text[], venue text, home boolean, on_campus boolean) returns text
language sql immutable as $$
  select case
    when source = 'ath' then case
      when not coalesce(home, false) then null
      when coalesce(on_campus, false) then 'home game on campus'
      when venue ~* 'alerus' then 'home football at the Alerus (city venue)'
      else null end
    when title ~* '(donut|pizza|blood drive|luncheon|banquet|webinar|zoom|virtual|deadline|last day|refund|application)' then null
    when title ~* '(commencement|graduation|homecoming (parade|tailgate|game|fest|week)|move[- ]?in|move[- ]?out|potato bowl|tailgat|parade|festival|\\b5k\\b|\\b10k\\b|fun run|family weekend|welcome weekend|new student orientation|frost fest|wacipi|pow ?wow|open house|preview day|state of the university|memorial day|veterans day|big event|spring fling|springfest|ice ?breaker)' then 'title keyword'
    when venue ~* '(quad|green|lawn|field|stadium|arena|outdoor|plaza|coulee|greenway|parking)' then 'outdoor or stadium venue'
    when venue ~* '(alerus|ralph engelstad|betty engelstad|hyslop|memorial stadium|chester fritz auditorium|performing arts)' and 'General Public' = any(audience) then 'large public venue, parking and walks'
    else null end
$$;

create or replace function public.event_reminders_plan(p_event text) returns void
language plpgsql security definer set search_path = public as $$
declare ev record; d int;
begin
  select * into ev from public.campus_events where id = p_event;
  if ev.id is null then return; end if;
  if not ev.watch or not ev.active then delete from public.event_reminders where event_id = p_event and raised_at is null; return; end if;
  foreach d in array public.reminder_ladder() loop
    insert into public.event_reminders(event_id, days_before, due_on) values (p_event, d, (ev.starts_at at time zone 'America/Chicago')::date - d)
    on conflict (event_id, days_before) do update set due_on = excluded.due_on where event_reminders.raised_at is null;
  end loop;
  delete from public.event_reminders where event_id = p_event and raised_at is null and due_on < current_date - 1;
end $$;

-- one row in, upsert, plan reminders, announce new watched events
create or replace function public.event_put(
  p_source text, p_external_id text, p_title text, p_url text, p_description text, p_sport text, p_home boolean,
  p_venue text, p_address text, p_location geometry, p_starts timestamptz, p_ends timestamptz, p_all_day boolean,
  p_first date, p_last date, p_audience text[], p_topics text[], p_raw jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v public.event_venues; loc geometry; oncamp boolean; nz_zone text; auto text; id_ text; is_new boolean; watched boolean;
begin
  id_ := p_source || ':' || p_external_id;
  v := public.venue_lookup(coalesce(p_venue, ''));
  loc := coalesce(p_location, v.location);
  oncamp := case when v.id is not null then v.on_campus when loc is not null then exists (select 1 from public.zones z join public.zone_versions zv on zv.id = z.current_version_id where z.class = 'campus' and st_intersects(zv.geom, loc)) else null end;
  -- nearest operational zone within 150 m (events sit at building doors, not on the walk itself)
  nz_zone := null;
  if loc is not null then
    select z.id into nz_zone from public.zones z join public.zone_versions zv on zv.id = z.current_version_id
     where z.active and z.class not in ('campus','other') and st_dwithin(zv.geog, loc::geography, 150)
     order by st_distance(zv.geog, loc::geography) limit 1;
  end if;
  auto := public.event_auto_watch(p_source, p_title, coalesce(p_topics, '{}'), coalesce(p_audience, '{}'), coalesce(p_venue, ''), p_home, oncamp);
  is_new := not exists (select 1 from public.campus_events where id = id_);
  insert into public.campus_events(id, source, external_id, title, url, description, sport, home, venue_name, address, location, on_campus, zone_id, starts_at, ends_at, all_day,
                                   first_date, last_date, audience, topics, raw, watch, watch_reason, last_synced_at)
  values (id_, p_source, p_external_id, p_title, p_url, p_description, p_sport, p_home, coalesce(v.name, p_venue), p_address, loc, oncamp, nz_zone, p_starts, p_ends, coalesce(p_all_day, false),
          p_first, p_last, coalesce(p_audience, '{}'), coalesce(p_topics, '{}'), coalesce(p_raw, '{}'::jsonb), auto is not null, auto, now())
  on conflict (id) do update set title = excluded.title, url = excluded.url, description = excluded.description, sport = excluded.sport, home = excluded.home,
    venue_name = excluded.venue_name, address = excluded.address, location = excluded.location, on_campus = excluded.on_campus, zone_id = coalesce(excluded.zone_id, campus_events.zone_id),
    starts_at = excluded.starts_at, ends_at = excluded.ends_at, all_day = excluded.all_day, first_date = excluded.first_date, last_date = excluded.last_date,
    audience = excluded.audience, topics = excluded.topics, raw = excluded.raw, last_synced_at = now(), active = true,
    watch = case when campus_events.watch_set_by is not null then campus_events.watch else excluded.watch end,
    watch_reason = case when campus_events.watch_set_by is not null then campus_events.watch_reason else excluded.watch_reason end;
  select watch into watched from public.campus_events where id = id_;
  perform public.event_reminders_plan(id_);
  if is_new and watched then
    perform public.notify('all', 'event_watch', jsonb_build_object('event_id', id_, 'message', 'New event to plan for: ' || p_title || ' on ' || to_char(p_starts at time zone 'America/Chicago', 'Mon DD')));
  end if;
  return id_;
end $$;

-- Localist JSON page
create or replace function public.events_upsert(payload jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e jsonb; ev jsonb; inst jsonb; n int := 0; pt geometry; sa timestamptz; ea timestamptz;
begin
  if auth.uid() is not null and not public.is_admin() then perform public.grnd_error(403, 'Only admins load events'); end if;
  for e in select * from jsonb_array_elements(coalesce(payload->'events', '[]'::jsonb)) loop
    ev := e->'event'; inst := coalesce(ev->'event_instances'->0->'event_instance', '{}'::jsonb);
    sa := (inst->>'start')::timestamptz; ea := (inst->>'end')::timestamptz;
    if sa is null or ev->>'id' is null then continue; end if;
    pt := case when ev->'geo'->>'latitude' ~ '^-?[0-9.]+$' and ev->'geo'->>'longitude' ~ '^-?[0-9.]+$' then st_setsrid(st_makepoint((ev->'geo'->>'longitude')::float8, (ev->'geo'->>'latitude')::float8), 4326) end;
    perform public.event_put('und', ev->>'id', ev->>'title', ev->>'localist_url', left(regexp_replace(coalesce(ev->>'description_text', ''), '\s+', ' ', 'g'), 2000), null, null,
      ev->>'location_name', ev->>'address', pt, sa, ea, coalesce((inst->>'all_day')::boolean, false), (ev->>'first_date')::date, (ev->>'last_date')::date,
      coalesce((select array_agg(t->>'name') from jsonb_array_elements(coalesce(ev->'filters'->'event_target_audience', '[]'::jsonb)) t), '{}'),
      coalesce((select array_agg(t->>'name') from jsonb_array_elements(coalesce(ev->'filters'->'event_topic', '[]'::jsonb)) t), '{}'), ev);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('events', n));
end $$;

-- iCal text (Sidearm). Handles folded lines, escaped commas, Z and floating times, VALUE=DATE all-day events.
create or replace function public.ics_unescape(t text) returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t, ''), '\,', ','), '\;', ';'), '\n', ' '), '\\', '\')
$$;
create or replace function public.ics_prop(block text, key text) returns text language sql immutable as $$
  select (regexp_match(block, '(?m)^' || key || '(?:;[^:\n]*)?:(.*)$'))[1]
$$;
create or replace function public.ics_time(block text, key text) returns timestamptz language plpgsql immutable as $$
declare raw text; params text;
begin
  raw := public.ics_prop(block, key); if raw is null then return null; end if;
  params := (regexp_match(block, '(?m)^' || key || '(;[^:\n]*)?:'))[1];
  raw := trim(raw);
  if raw ~ '^\d{8}$' then return (to_date(raw, 'YYYYMMDD')::timestamp at time zone 'America/Chicago'); end if;   -- all-day
  if raw ~ 'Z$' then return to_timestamp(left(raw, 15), 'YYYYMMDD"T"HH24MISS') at time zone 'UTC'; end if;
  if params ~* 'TZID=' then return (to_timestamp(left(raw, 15), 'YYYYMMDD"T"HH24MISS')::timestamp at time zone (regexp_match(params, 'TZID=([^;:]+)'))[1]); end if;
  return to_timestamp(left(raw, 15), 'YYYYMMDD"T"HH24MISS')::timestamp at time zone 'America/Chicago';
end $$;

create or replace function public.events_upsert_ics(payload text, p_source text default 'ath') returns jsonb
language plpgsql security definer set search_path = public as $$
declare body text; blk text; n int := 0; uid text; summary text; loc text; url text; sport text; home boolean; sa timestamptz; ea timestamptz; allday boolean; venue text; title text;
begin
  if auth.uid() is not null and not public.is_admin() then perform public.grnd_error(403, 'Only admins load events'); end if;
  if payload is null or payload !~ 'BEGIN:VCALENDAR' then perform public.grnd_error(422, 'Not an iCalendar payload', '{"fields":["payload"]}'); end if;
  body := regexp_replace(replace(payload, E'\r', ''), E'\n[ \t]', '', 'g');       -- unfold continuation lines
  for blk in select m[1] from regexp_matches(body, 'BEGIN:VEVENT\n(.*?)\nEND:VEVENT', 'g') m loop
    uid := public.ics_prop(blk, 'UID'); if uid is null then continue; end if;
    summary := public.ics_unescape(public.ics_prop(blk, 'SUMMARY'));
    loc := public.ics_unescape(public.ics_prop(blk, 'LOCATION'));
    url := replace(coalesce(public.ics_prop(blk, 'URL'), ''), '&amp;', '&');
    sa := public.ics_time(blk, 'DTSTART'); ea := public.ics_time(blk, 'DTEND');
    if sa is null then continue; end if;
    allday := coalesce(public.ics_prop(blk, 'DTSTART'), '') ~ '^\d{8}$';
    -- "[W] University of North Dakota  Women's Soccer vs Regina (Exh.)" -> sport "Women's Soccer", title "Women's Soccer vs Regina (Exh.)"
    title := regexp_replace(summary, '^\[[A-Z]\]\s*', '');
    title := regexp_replace(title, '^University of North Dakota\s+', '');
    sport := (regexp_match(title, '^(.*?)\s+(vs|at)\s', 'i'))[1];
    home := loc ~* 'grand forks' and title !~* '\sat\s';
    venue := nullif(trim(regexp_replace(loc, '^Grand Forks,?\s*N\.?D\.?,?\s*', '', 'i')), '');
    perform public.event_put(p_source, uid, title, url, left(public.ics_unescape(public.ics_prop(blk, 'DESCRIPTION')), 2000), sport, home,
      coalesce(venue, loc), loc, null, sa, ea, allday, (sa at time zone 'America/Chicago')::date, (coalesce(ea, sa) at time zone 'America/Chicago')::date,
      '{}', array['Athletics'], jsonb_build_object('summary', summary, 'location', loc));
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('events', n));
end $$;

-- ---------- people ----------
create or replace function public.event_watch(idempotency_key uuid, event_id text, watch boolean, reason text default null, notes text default null, work_order_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; r text; ev record;
begin
  prior := public.idem_check(idempotency_key, 'event_watch'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','oversight','lead') then perform public.grnd_error(403, 'Only leads and admins flag events'); end if;
  update public.campus_events ce set watch = event_watch.watch, watch_reason = coalesce(reason, case when event_watch.watch then 'flagged by ' || public.profile_name(auth.uid()) else 'cleared by ' || public.profile_name(auth.uid()) end),
         watch_set_by = auth.uid(), notes = coalesce(event_watch.notes, ce.notes), work_order_id = coalesce(event_watch.work_order_id, ce.work_order_id)
   where ce.id = event_id returning ce.* into ev;
  if ev.id is null then perform public.grnd_error(404, 'Event not found'); end if;
  perform public.event_reminders_plan(event_id);
  return public.idem_store(idempotency_key, 'event_watch', jsonb_build_object('ok', true, 'data', jsonb_build_object('event_id', event_id, 'watch', ev.watch, 'title', ev.title), 'replayed', false));
end $$;

create or replace function public.event_reminder_ack(idempotency_key uuid, reminder_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; r text; n int;
begin
  prior := public.idem_check(idempotency_key, 'event_reminder_ack'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','oversight','lead') then perform public.grnd_error(403, 'Only leads and admins acknowledge reminders'); end if;
  update public.event_reminders set acknowledged_by = auth.uid(), acknowledged_at = now() where id = reminder_id and acknowledged_at is null;
  get diagnostics n = row_count;
  if n = 0 then perform public.grnd_error(410, 'Reminder not found or already acknowledged'); end if;
  return public.idem_store(idempotency_key, 'event_reminder_ack', jsonb_build_object('ok', true, 'data', jsonb_build_object('reminder_id', reminder_id), 'replayed', false));
end $$;

-- ---------- daily jobs ----------
create or replace function public.events_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare rem record; n int := 0; label text; stale record;
begin
  for rem in select r.*, e.title, e.starts_at, e.venue_name, e.zone_id from public.event_reminders r join public.campus_events e on e.id = r.event_id
             where r.raised_at is null and r.due_on <= current_date and e.watch and e.active order by r.due_on loop
    label := case when rem.days_before > 1 then rem.days_before || ' days out' when rem.days_before = 1 then 'tomorrow' when rem.days_before = 0 then 'today' else 'yesterday, follow up' end;
    perform public.notify('all', 'event_reminder', jsonb_build_object('reminder_id', rem.id, 'event_id', rem.event_id, 'days_before', rem.days_before,
      'message', rem.title || ' (' || label || ')' || coalesce(' at ' || rem.venue_name, ''), 'starts_at', rem.starts_at, 'zone_id', rem.zone_id));
    update public.event_reminders set raised_at = now() where id = rem.id;
    n := n + 1;
  end loop;
  update public.campus_events set active = false where active and coalesce(ends_at, starts_at) < now() - interval '2 days';
  -- sync health: a source with no successful ingest in 2 days gets one alert per day
  for stale in select s.source from (values ('und'), ('ath')) s(source)
               where not exists (select 1 from public.event_sync_log l where l.source = s.source and l.error is null and l.ingested_at > now() - interval '2 days')
                 and not exists (select 1 from public.outbox o where o.event_type = 'event_sync_failed' and o.payload->>'source' = s.source and o.created_at > now() - interval '1 day') loop
    perform public.notify('all', 'event_sync_failed', jsonb_build_object('source', stale.source, 'message', 'Event calendar sync (' || stale.source || ') has not succeeded in 2 days'));
  end loop;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('raised', n));
end $$;

create or replace function public.events_sync_request(p_days int default 365, p_pages int default 9) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare i int; rid bigint;
begin
  for i in 1..p_pages loop
    rid := net.http_get(url := format('https://calendar.und.edu/api/2/events?days=%s&pp=100&page=%s', p_days, i), timeout_milliseconds := 20000);
    insert into public.event_sync_log(source, request_id, page) values ('und', rid, i);
  end loop;
  -- no custom headers: fightinghawks.com answers 400 to pg_net requests that carry them
  rid := net.http_get(url := 'https://fightinghawks.com/calendar.ashx/calendar.ics', timeout_milliseconds := 20000);
  insert into public.event_sync_log(source, request_id, page) values ('ath', rid, 1);
  return p_pages + 1;
end $$;

create or replace function public.events_sync_ingest() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare l record; resp record; res jsonb; total int := 0; pages int := 0;
begin
  for l in select * from public.event_sync_log where ingested_at is null and requested_at > now() - interval '1 day' order by id loop
    select * into resp from net._http_response where id = l.request_id;
    if resp.id is null then
      if l.requested_at < now() - interval '30 minutes' then update public.event_sync_log set ingested_at = now(), error = 'no response from pg_net' where id = l.id; end if;
      continue;
    end if;
    if resp.status_code <> 200 or resp.content is null then
      update public.event_sync_log set ingested_at = now(), error = 'HTTP ' || coalesce(resp.status_code::text, 'none') || ' ' || coalesce(resp.error_msg, '') where id = l.id; continue;
    end if;
    begin
      res := case l.source when 'und' then public.events_upsert(resp.content::jsonb) else public.events_upsert_ics(resp.content, 'ath') end;
      update public.event_sync_log set ingested_at = now(), events = (res->'data'->>'events')::int where id = l.id;
      total := total + (res->'data'->>'events')::int; pages := pages + 1;
    exception when others then
      update public.event_sync_log set ingested_at = now(), error = left(sqlerrm, 500) where id = l.id;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('pages', pages, 'events', total));
end $$;

select cron.schedule('und-events-request', '0 11 * * *',  $$select public.events_sync_request()$$);
select cron.schedule('und-events-ingest',  '10 11 * * *', $$select public.events_sync_ingest()$$);
select cron.schedule('und-events-tick',    '20 11 * * *', $$select public.events_tick()$$);

-- ---------- views ----------
create view public.v_campus_events with (security_invoker = true) as
select e.id as event_id, e.source, e.title, e.url, e.description, e.sport, e.home, e.venue_name, e.address, st_asgeojson(e.location)::jsonb as location, e.on_campus, e.zone_id, z.name as zone_name,
       e.starts_at, e.ends_at, e.all_day, e.first_date, e.last_date, e.audience, e.topics,
       e.watch, e.watch_reason, public.profile_name(e.watch_set_by) as watch_set_by_name, e.notes, e.work_order_id, w.number as work_order_number,
       ((e.starts_at at time zone 'America/Chicago')::date - current_date) as days_until,
       (select min(r.due_on) from public.event_reminders r where r.event_id = e.id and r.raised_at is null) as next_reminder_on,
       e.last_synced_at
from public.campus_events e left join public.zones z on z.id = e.zone_id left join public.work_orders w on w.id = e.work_order_id
where e.active;

create view public.v_event_reminders with (security_invoker = true) as
select r.id as reminder_id, r.event_id, e.source, e.title, e.venue_name, e.zone_id, e.starts_at, r.days_before, r.due_on, r.raised_at,
       r.acknowledged_at, public.profile_name(r.acknowledged_by) as acknowledged_by_name,
       (r.raised_at is not null and r.acknowledged_at is null) as open
from public.event_reminders r join public.campus_events e on e.id = r.event_id
where e.active and e.watch;

create view public.v_event_sync_health with (security_invoker = true) as
select s.source, max(l.ingested_at) filter (where l.error is null) as last_success, max(l.ingested_at) filter (where l.error is not null) as last_error_at,
       (select error from public.event_sync_log x where x.source = s.source and x.error is not null order by id desc limit 1) as last_error,
       (select count(*) from public.campus_events e where e.source = s.source and e.active) as active_events
from (values ('und'), ('ath')) s(source) left join public.event_sync_log l on l.source = s.source group by s.source;

grant select on public.event_venues, public.campus_events, public.event_reminders, public.event_sync_log, public.v_campus_events, public.v_event_reminders, public.v_event_sync_health to authenticated;
grant execute on function public.event_watch(uuid, text, boolean, text, text, uuid), public.event_reminder_ack(uuid, uuid), public.events_upsert(jsonb), public.events_upsert_ics(text, text), public.reminder_ladder(), public.venue_lookup(text) to authenticated;
revoke execute on function public.events_tick(), public.events_sync_request(int, int), public.events_sync_ingest(), public.event_reminders_plan(text),
  public.event_put(text, text, text, text, text, text, boolean, text, text, geometry, timestamptz, timestamptz, boolean, date, date, text[], text[], jsonb) from anon, authenticated;
drop function if exists public.event_auto_watch(text, text[], text[], text);
