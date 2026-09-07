-- 0008 Weather events, scoped zone status, operating state with revision. docs/api-contract.md sections 8 and 9. ADR decisions 6 and 10.

create table public.weather_events (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null default 'storm' check (kind in ('storm','ice','cleanup','other')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  opened_by uuid references public.profiles(id),
  notes text,
  created_at timestamptz not null default now()
);
create index weather_events_open_idx on public.weather_events(starts_at desc) where ends_at is null;
alter table public.work_orders add constraint work_orders_event_fk foreign key (event_id) references public.weather_events(id);
alter table public.service_records add constraint service_records_event_fk foreign key (event_id) references public.weather_events(id);

create or replace function public.active_event_id() returns uuid language sql stable security definer set search_path = public, extensions as $$
  select id from public.weather_events where ends_at is null order by starts_at desc limit 1
$$;

-- ---------- zone status: one row per fact (zone, event, activity, time) ----------
create table public.zone_status (
  id uuid primary key default gen_random_uuid(),
  zone_id text not null references public.zones(id),
  zone_version_id uuid references public.zone_versions(id),
  event_id uuid references public.weather_events(id),
  activity text not null check (activity in ('cleared','salted','sanded','brined','mowed','trimmed','inspected','blocked')),
  at timestamptz not null default now(),
  by_profile_id uuid not null references public.profiles(id),
  task_id uuid references public.tasks(id),
  service_record_id uuid references public.service_records(id),
  asset_id text references public.assets(id),
  location geometry(Point, 4326),
  note text,
  created_at timestamptz not null default now()
);
create index zone_status_zone_idx on public.zone_status(zone_id, at desc);
create index zone_status_event_idx on public.zone_status(event_id, at desc);
create trigger zone_status_immutable before update or delete on public.zone_status for each row execute function public.forbid_change();

create or replace function public.zone_status_set(
  idempotency_key uuid, zone_id text, activity text, zone_version_id uuid default null, event_id uuid default null,
  at timestamptz default null, location jsonb default null, task_id uuid default null, asset_id text default null, note text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; z record; sid uuid; me text; ev uuid;
begin
  prior := public.idem_check(idempotency_key, 'zone_status_set'); if prior is not null then return prior; end if;
  r := public.auth_role();
  select * into z from public.zones where id = zone_id and active;
  if z is null then perform public.grnd_error(404, 'Zone not found'); end if;
  if r = 'admin' then null;
  elsif r = 'lead' and (z.responsible_crew_id is null or z.responsible_crew_id = any(public.my_crew_ids())) then null;
  elsif r = 'worker' and task_id is not null and exists (select 1 from public.tasks t where t.id = task_id and t.assignee_id = auth.uid() and t.zone_id = zone_status_set.zone_id) then null;
  else perform public.grnd_error(403, 'You may not set status on ' || zone_id); end if;
  ev := coalesce(event_id, public.active_event_id());
  insert into public.zone_status(zone_id, zone_version_id, event_id, activity, at, by_profile_id, task_id, asset_id, location, note)
  values (zone_id, coalesce(zone_version_id, z.current_version_id), ev, activity, coalesce(at, now()), auth.uid(), task_id, asset_id, public.mk_point(location), note)
  returning id into sid;
  select full_name into me from public.profiles where id = auth.uid();
  perform public.notify('all', 'zone_status', jsonb_build_object('zone_id', zone_id, 'activity', activity, 'at', coalesce(at, now()), 'by_name', me));
  return public.idem_store(idempotency_key, 'zone_status_set',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('zone_status_id', sid, 'zone_id', zone_id, 'activity', activity, 'at', coalesce(at, now()), 'by_name', me, 'event_id', ev), 'replayed', false));
end $$;

-- called by service_finalize: a finalized action also sets the status
create or replace function public.zone_status_from_action(z text, zv uuid, action text, at timestamptz, task uuid, rec uuid, asset text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare act text;
begin
  act := case action when 'plowed' then 'cleared' when 'shoveled' then 'cleared' when 'salted' then 'salted' when 'sanded' then 'sanded'
                     when 'brined' then 'brined' when 'mowed' then 'mowed' when 'trimmed' then 'trimmed' when 'inspected' then 'inspected' end;
  if act is null then return; end if;
  insert into public.zone_status(zone_id, zone_version_id, event_id, activity, at, by_profile_id, task_id, service_record_id, asset_id)
  values (z, zv, public.active_event_id(), act, at, auth.uid(), task, rec, asset);
end $$;

create view public.v_zone_status_current with (security_invoker = true) as
select distinct on (s.zone_id, s.activity)
       s.zone_id, z.name as zone_name, z.class as zone_class, z.site, s.event_id, s.activity, s.at,
       s.by_profile_id, p.full_name as by_name, s.task_id, s.service_record_id, s.asset_id, s.note,
       (extract(epoch from (now() - s.at)) / 60)::int as minutes_ago,
       (s.event_id is not null and s.at < now() - interval '6 hours') as stale
from public.zone_status s join public.zones z on z.id = s.zone_id join public.profiles p on p.id = s.by_profile_id
where (s.event_id is not null and s.event_id = public.active_event_id()) or (s.event_id is null and s.at > now() - interval '24 hours')
order by s.zone_id, s.activity, s.at desc;

-- ---------- operating state (single row, revisioned) ----------
create table public.operating_state (
  id boolean primary key default true check (id),   -- exactly one row
  mode text not null check (mode in ('landscaping','snow')),
  revision int not null default 1,
  changed_at timestamptz not null default now(),
  changed_by uuid references public.profiles(id),
  reason text,
  active_event_id uuid references public.weather_events(id)
);
insert into public.operating_state(mode, reason) values ('landscaping', 'initial');

create table public.operating_state_acks (
  device_id text not null,
  profile_id uuid not null references public.profiles(id),
  revision int not null,
  acked_at timestamptz not null default now(),
  primary key (device_id, profile_id)
);

create or replace function public.operating_state_pivot(idempotency_key uuid, expected_revision int, to_mode text, reason text, event jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; st record; ev uuid; me text;
begin
  prior := public.idem_check(idempotency_key, 'operating_state_pivot'); if prior is not null then return prior; end if;
  if not public.is_admin() then perform public.grnd_error(403, 'Only admins pivot the operating state'); end if;
  if expected_revision is null then perform public.grnd_error(422, 'expected_revision is required', '{"fields":["expected_revision"]}'); end if;
  if to_mode not in ('landscaping','snow') then perform public.grnd_error(422, 'to_mode must be landscaping or snow', '{"fields":["to_mode"]}'); end if;
  select * into st from public.operating_state where id for update;
  if st.revision <> expected_revision then
    perform public.grnd_error(409, 'Operating state changed', jsonb_build_object('revision', st.revision, 'expected_revision', expected_revision, 'mode', st.mode)); end if;
  if to_mode = 'snow' then
    ev := public.active_event_id();
    if ev is null then
      insert into public.weather_events(name, starts_at, opened_by, notes)
      values (coalesce(event->>'name', 'Storm ' || to_char(now(), 'YYYY-MM-DD')), coalesce((event->>'starts_at')::timestamptz, now()), auth.uid(), reason) returning id into ev;
    end if;
  else
    update public.weather_events set ends_at = now() where ends_at is null;
    ev := null;
  end if;
  update public.operating_state set mode = to_mode, revision = revision + 1, changed_at = now(), changed_by = auth.uid(), reason = operating_state_pivot.reason, active_event_id = ev
   where id returning * into st;
  select full_name into me from public.profiles where id = auth.uid();
  perform public.notify('all', 'pivot', jsonb_build_object('mode', st.mode, 'revision', st.revision, 'from_name', me, 'message', 'Mode is now ' || st.mode || ': ' || reason, 'active_event_id', ev));
  return public.idem_store(idempotency_key, 'operating_state_pivot',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('mode', st.mode, 'revision', st.revision, 'active_event_id', ev), 'revision', st.revision, 'replayed', false));
end $$;

create or replace function public.operating_state_ack(revision int, device_id text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.auth_role();
  insert into public.operating_state_acks(device_id, profile_id, revision) values (device_id, auth.uid(), revision)
  on conflict (device_id, profile_id) do update set revision = excluded.revision, acked_at = now();
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('revision', revision));
end $$;

create view public.v_operating_state with (security_invoker = true) as
select s.mode, s.revision, s.changed_at, p.full_name as changed_by_name, s.reason, s.active_event_id, e.name as active_event_name,
       (select count(*) from public.tasks t join public.work_orders w on w.id = t.work_order_id
         where t.state not in ('done','canceled') and w.season not in (s.mode, 'either'))::int as carryover_task_count,
       (select count(*) from public.operating_state_acks a where a.revision = s.revision and a.acked_at > now() - interval '12 hours')::int as devices_on_revision
from public.operating_state s left join public.profiles p on p.id = s.changed_by left join public.weather_events e on e.id = s.active_event_id;

create view public.v_weather_events with (security_invoker = true) as
select e.id, e.name, e.kind, e.starts_at, e.ends_at, p.full_name as opened_by_name, e.notes, (e.ends_at is null) as active
from public.weather_events e left join public.profiles p on p.id = e.opened_by;

-- ---------- RLS, grants ----------
alter table public.weather_events enable row level security;
alter table public.zone_status enable row level security;
alter table public.operating_state enable row level security;
alter table public.operating_state_acks enable row level security;
create policy weather_events_read on public.weather_events for select to authenticated using (true);
create policy zone_status_read on public.zone_status for select to authenticated using (true);
create policy operating_state_read on public.operating_state for select to authenticated using (true);
create policy acks_read on public.operating_state_acks for select to authenticated using (public.auth_role() in ('admin','oversight','lead') or profile_id = auth.uid());

grant select on public.weather_events, public.zone_status, public.operating_state, public.operating_state_acks,
  public.v_zone_status_current, public.v_operating_state, public.v_weather_events to authenticated;
grant execute on function public.active_event_id(), public.zone_status_set(uuid, text, text, uuid, uuid, timestamptz, jsonb, uuid, text, text),
  public.operating_state_pivot(uuid, int, text, text, jsonb), public.operating_state_ack(int, text) to authenticated;
