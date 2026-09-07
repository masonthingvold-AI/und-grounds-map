-- 0011 UND events calendar: pull calendar.und.edu (Localist) daily, let leads flag events the crew must plan for,
-- and raise reminders a month out and then more often until the day after. Mason, Sep 7, 2026.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create table public.campus_events (
  id bigint primary key,                             -- Localist event id
  title text not null,
  url text,
  description text,
  venue_name text,
  address text,
  location geometry(Point, 4326),
  zone_id text references public.zones(id),          -- nearest current zone within 150 m, if any
  starts_at timestamptz not null,
  ends_at timestamptz,
  all_day boolean not null default false,
  first_date date, last_date date,
  audience text[] not null default '{}',
  topics text[] not null default '{}',
  experience text,
  raw jsonb not null default '{}'::jsonb,
  watch boolean not null default false,              -- grounds needs to plan for this one
  watch_reason text,
  watch_set_by uuid references public.profiles(id),
  notes text,
  work_order_id uuid references public.work_orders(id),
  first_seen_at timestamptz not null default now(),
  last_synced_at timestamptz not null default now(),
  active boolean not null default true
);
create index campus_events_start_idx on public.campus_events(starts_at) where active;
create index campus_events_watch_idx on public.campus_events(starts_at) where active and watch;
alter table public.campus_events enable row level security;
create policy campus_events_read on public.campus_events for select to authenticated using (true);

-- reminder ladder in days before the start (negative = after)
create table public.event_reminders (
  id uuid primary key default gen_random_uuid(),
  event_id bigint not null references public.campus_events(id) on delete cascade,
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

create or replace function public.reminder_ladder() returns int[] language sql immutable as $$ select array[30, 21, 14, 7, 5, 3, 2, 1, 0, -1] $$;

-- what makes an event a planning item by default; leads and admins can flip watch either way and their choice sticks
create or replace function public.event_auto_watch(title text, topics text[], audience text[], venue text) returns text
language sql immutable as $$
  select case
    when title ~* '(donut|pizza|blood drive|luncheon|banquet|webinar|zoom|virtual|deadline|last day|refund|application)' then null
    when title ~* '(commencement|graduation|homecoming (parade|tailgate|game|fest|week)|move[- ]?in|move[- ]?out|potato bowl|tailgat|parade|festival|\b5k\b|\b10k\b|fun run|family weekend|welcome weekend|new student orientation|frost fest|wacipi|pow ?wow|open house|preview day|state of the university|memorial day|veterans day|big event|spring fling|springfest|ice ?breaker)' then 'title keyword'
    when venue ~* '(quad|green|lawn|field|stadium|arena|outdoor|plaza|coulee|greenway|english coulee|parking)' then 'outdoor or stadium venue'
    when venue ~* '(alerus|ralph engelstad|betty engelstad|hyslop|memorial stadium|chester fritz auditorium|performing arts)' and 'General Public' = any(audience) then 'large public venue, parking and walks'
    when 'Athletics' = any(topics) and venue ~* '(bronson|engelstad|hyslop|alerus|memorial stadium|und |campus|field)' then 'home athletics'
    else null end
$$;

-- upsert a page of Localist events (service role from the sync job, or an admin pasting JSON)
create or replace function public.events_upsert(payload jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare e jsonb; ev jsonb; inst jsonb; n int := 0; pt geometry; nz_zone text; auto text; is_new boolean; watched boolean; sa timestamptz; ea timestamptz;
begin
  if auth.uid() is not null and not public.is_admin() then perform public.grnd_error(403, 'Only admins load events'); end if;
  for e in select * from jsonb_array_elements(coalesce(payload->'events', '[]'::jsonb)) loop
    ev := e->'event';
    inst := coalesce(ev->'event_instances'->0->'event_instance', '{}'::jsonb);
    sa := (inst->>'start')::timestamptz; ea := (inst->>'end')::timestamptz;
    if sa is null then continue; end if;
    pt := case when ev->'geo'->>'latitude' is not null then st_setsrid(st_makepoint((ev->'geo'->>'longitude')::float8, (ev->'geo'->>'latitude')::float8), 4326) end;
    nz_zone := null; if pt is not null then select zone_id into nz_zone from public.nearest_zone_version(pt); end if;
    auto := public.event_auto_watch(ev->>'title',
              coalesce((select array_agg(t->>'name') from jsonb_array_elements(coalesce(ev->'filters'->'event_topic', '[]'::jsonb)) t), '{}'),
              coalesce((select array_agg(t->>'name') from jsonb_array_elements(coalesce(ev->'filters'->'event_target_audience', '[]'::jsonb)) t), '{}'),
              ev->>'location_name');
    is_new := not exists (select 1 from public.campus_events where id = (ev->>'id')::bigint);
    insert into public.campus_events(id, title, url, description, venue_name, address, location, zone_id, starts_at, ends_at, all_day, first_date, last_date, audience, topics, experience, raw, watch, watch_reason, last_synced_at)
    values ((ev->>'id')::bigint, ev->>'title', ev->>'localist_url', left(regexp_replace(coalesce(ev->>'description_text', ''), '\s+', ' ', 'g'), 2000), ev->>'location_name', ev->>'address', pt, nz_zone,
            sa, ea, coalesce((inst->>'all_day')::boolean, false), (ev->>'first_date')::date, (ev->>'last_date')::date,
            coalesce((select array_agg(t->>'name') from jsonb_array_elements(coalesce(ev->'filters'->'event_target_audience', '[]'::jsonb)) t), '{}'),
            coalesce((select array_agg(t->>'name') from jsonb_array_elements(coalesce(ev->'filters'->'event_topic', '[]'::jsonb)) t), '{}'),
            ev->>'experience', ev, auto is not null, auto, now())
    on conflict (id) do update set title = excluded.title, url = excluded.url, description = excluded.description, venue_name = excluded.venue_name, address = excluded.address,
      location = excluded.location, zone_id = coalesce(excluded.zone_id, campus_events.zone_id), starts_at = excluded.starts_at, ends_at = excluded.ends_at, all_day = excluded.all_day,
      first_date = excluded.first_date, last_date = excluded.last_date, audience = excluded.audience, topics = excluded.topics, experience = excluded.experience, raw = excluded.raw,
      last_synced_at = now(), active = true,
      -- a person's watch decision wins over the keyword rule; the rule only fills in when nobody has decided
      watch = case when campus_events.watch_set_by is not null then campus_events.watch else excluded.watch end,
      watch_reason = case when campus_events.watch_set_by is not null then campus_events.watch_reason else excluded.watch_reason end;
    select watch into watched from public.campus_events where id = (ev->>'id')::bigint;
    perform public.event_reminders_plan((ev->>'id')::bigint);
    if is_new and watched then
      perform public.notify('all', 'event_watch', jsonb_build_object('event_id', (ev->>'id')::bigint, 'message', 'New campus event to plan for: ' || (ev->>'title') || ' on ' || to_char(sa at time zone 'America/Chicago', 'Mon DD')));
    end if;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('events', n));
end $$;

-- (re)build the reminder ladder for one event; reminders exist only while the event is watched
create or replace function public.event_reminders_plan(p_event bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare ev record; d int;
begin
  select * into ev from public.campus_events where id = p_event;
  if ev.id is null then return; end if;
  if not ev.watch or not ev.active then
    delete from public.event_reminders where event_id = p_event and raised_at is null; return;
  end if;
  foreach d in array public.reminder_ladder() loop
    insert into public.event_reminders(event_id, days_before, due_on)
    values (p_event, d, (ev.starts_at at time zone 'America/Chicago')::date - d)
    on conflict (event_id, days_before) do update set due_on = excluded.due_on where event_reminders.raised_at is null;
  end loop;
  delete from public.event_reminders where event_id = p_event and raised_at is null and due_on < current_date - 1;
end $$;

-- a lead or admin decides an event needs planning (or not) and can attach notes and a work order
create or replace function public.event_watch(idempotency_key uuid, event_id bigint, watch boolean, reason text default null, notes text default null, work_order_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; ev record;
begin
  prior := public.idem_check(idempotency_key, 'event_watch'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','oversight','lead') then perform public.grnd_error(403, 'Only leads and admins flag events'); end if;
  update public.campus_events set watch = event_watch.watch, watch_reason = coalesce(reason, case when event_watch.watch then 'flagged by ' || public.profile_name(auth.uid()) else null end),
         watch_set_by = auth.uid(), notes = coalesce(event_watch.notes, notes), work_order_id = coalesce(event_watch.work_order_id, work_order_id)
   where id = event_id returning * into ev;
  if ev.id is null then perform public.grnd_error(404, 'Event not found'); end if;
  perform public.event_reminders_plan(event_id);
  return public.idem_store(idempotency_key, 'event_watch', jsonb_build_object('ok', true, 'data', jsonb_build_object('event_id', event_id, 'watch', ev.watch, 'title', ev.title), 'replayed', false));
end $$;

create or replace function public.event_reminder_ack(idempotency_key uuid, reminder_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text;
begin
  prior := public.idem_check(idempotency_key, 'event_reminder_ack'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','oversight','lead') then perform public.grnd_error(403, 'Only leads and admins acknowledge reminders'); end if;
  update public.event_reminders set acknowledged_by = auth.uid(), acknowledged_at = now() where id = reminder_id and acknowledged_at is null;
  return public.idem_store(idempotency_key, 'event_reminder_ack', jsonb_build_object('ok', true, 'data', jsonb_build_object('reminder_id', reminder_id), 'replayed', false));
end $$;

-- daily: raise every reminder that is due, as a broadcast on 'all' (push later reuses the same event type)
create or replace function public.events_tick() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare rem record; n int := 0; label text;
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
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('raised', n));
end $$;

-- ---------- sync from calendar.und.edu with pg_net (async): request pages, then ingest what came back ----------
create table public.event_sync_log (
  id bigint generated always as identity primary key,
  requested_at timestamptz not null default now(),
  request_id bigint,
  page int,
  ingested_at timestamptz,
  events int,
  error text
);
alter table public.event_sync_log enable row level security;
create policy event_sync_log_read on public.event_sync_log for select to authenticated using (public.is_admin());

create or replace function public.events_sync_request(p_days int default 120, p_pages int default 8) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare i int; rid bigint;
begin
  for i in 1..p_pages loop
    rid := net.http_get(url := format('https://calendar.und.edu/api/2/events?days=%s&pp=100&page=%s', p_days, i), timeout_milliseconds := 20000);
    insert into public.event_sync_log(request_id, page) values (rid, i);
  end loop;
  return p_pages;
end $$;

create or replace function public.events_sync_ingest() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare l record; resp record; body jsonb; res jsonb; total int := 0; pages int := 0;
begin
  for l in select * from public.event_sync_log where ingested_at is null and requested_at > now() - interval '1 day' order by id loop
    select * into resp from net._http_response where id = l.request_id;
    if resp.id is null then continue; end if;
    if resp.status_code <> 200 or resp.content is null then
      update public.event_sync_log set ingested_at = now(), error = 'HTTP ' || coalesce(resp.status_code::text, 'none') || ' ' || coalesce(resp.error_msg, '') where id = l.id; continue;
    end if;
    begin
      body := resp.content::jsonb;
      res := public.events_upsert(body);
      update public.event_sync_log set ingested_at = now(), events = (res->'data'->>'events')::int where id = l.id;
      total := total + (res->'data'->>'events')::int; pages := pages + 1;
    exception when others then
      update public.event_sync_log set ingested_at = now(), error = left(sqlerrm, 500) where id = l.id;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('pages', pages, 'events', total));
end $$;

-- 6:00 and 6:10 Central (11:00 and 11:10 UTC during daylight time) fetch and ingest; 6:20 raise reminders
select cron.schedule('und-events-request', '0 11 * * *', $$select public.events_sync_request()$$);
select cron.schedule('und-events-ingest',  '10 11 * * *', $$select public.events_sync_ingest()$$);
select cron.schedule('und-events-tick',    '20 11 * * *', $$select public.events_tick()$$);

-- ---------- views ----------
create view public.v_campus_events with (security_invoker = true) as
select e.id as event_id, e.title, e.url, e.description, e.venue_name, e.address, st_asgeojson(e.location)::jsonb as location, e.zone_id, z.name as zone_name,
       e.starts_at, e.ends_at, e.all_day, e.first_date, e.last_date, e.audience, e.topics, e.experience,
       e.watch, e.watch_reason, public.profile_name(e.watch_set_by) as watch_set_by_name, e.notes, e.work_order_id, w.number as work_order_number,
       ((e.starts_at at time zone 'America/Chicago')::date - current_date) as days_until,
       (select min(r.due_on) from public.event_reminders r where r.event_id = e.id and r.raised_at is null) as next_reminder_on,
       e.last_synced_at
from public.campus_events e left join public.zones z on z.id = e.zone_id left join public.work_orders w on w.id = e.work_order_id
where e.active;

create view public.v_event_reminders with (security_invoker = true) as
select r.id as reminder_id, r.event_id, e.title, e.venue_name, e.zone_id, e.starts_at, r.days_before, r.due_on, r.raised_at,
       r.acknowledged_at, public.profile_name(r.acknowledged_by) as acknowledged_by_name,
       (r.raised_at is not null and r.acknowledged_at is null) as open
from public.event_reminders r join public.campus_events e on e.id = r.event_id
where e.active and e.watch;

grant select on public.campus_events, public.event_reminders, public.event_sync_log, public.v_campus_events, public.v_event_reminders to authenticated;
grant execute on function public.event_watch(uuid, bigint, boolean, text, text, uuid), public.event_reminder_ack(uuid, uuid), public.events_upsert(jsonb), public.reminder_ladder() to authenticated;
revoke execute on function public.events_tick(), public.events_sync_request(int, int), public.events_sync_ingest(), public.event_reminders_plan(bigint) from anon, authenticated;
