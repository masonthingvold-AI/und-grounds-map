-- 0005 Shifts and location samples. docs/api-contract.md sections 4 and 5. ADR decisions 4, 7, 14.

create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  start_point geometry(Point, 4326),
  end_point geometry(Point, 4326),
  device_id text,
  ended_by uuid references public.profiles(id),
  note text,
  last_sample_at timestamptz,
  last_point geometry(Point, 4326),
  last_accuracy_m numeric,
  last_zone_id text references public.zones(id),
  last_zone_version_id uuid references public.zone_versions(id),
  last_result text,
  sample_count int not null default 0,
  created_at timestamptz not null default now(),
  -- one open shift per person (ADR decision 14)
  exclude using gist (profile_id with =, tstzrange(started_at, coalesce(ended_at, 'infinity'::timestamptz)) with &&)
);
create index shifts_profile_open_idx on public.shifts(profile_id) where ended_at is null;

-- raw samples, append only. Not partitioned in the pilot (ADR decision 14). Retention: records decision (ADR 9).
create table public.location_samples (
  id bigint generated always as identity primary key,
  shift_id uuid not null references public.shifts(id),
  profile_id uuid not null references public.profiles(id),
  taken_at timestamptz not null,
  received_at timestamptz not null default now(),
  geom geometry(Point, 4326) not null,
  accuracy_m numeric not null,
  speed_mps numeric, heading numeric, battery smallint, source text,
  zone_id text, zone_version_id uuid, result text, distance_m numeric
);
create index location_samples_shift_idx on public.location_samples(shift_id, taken_at);
create index location_samples_profile_idx on public.location_samples(profile_id, taken_at desc);
create trigger location_samples_immutable before update or delete on public.location_samples for each row execute function public.forbid_change();

create or replace function public.mk_point(loc jsonb) returns geometry
language sql immutable as $$
  select case when loc is null or loc->>'lng' is null or loc->>'lat' is null then null
         else st_setsrid(st_makepoint((loc->>'lng')::float8, (loc->>'lat')::float8), 4326) end
$$;

-- ---------- shift_start ----------
create or replace function public.shift_start(idempotency_key uuid, device_id text default null, location jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; open_ record; s record;
begin
  prior := public.idem_check(idempotency_key, 'shift_start'); if prior is not null then return prior; end if;
  perform public.auth_role();
  select * into open_ from public.shifts where profile_id = auth.uid() and ended_at is null;
  if open_.id is not null then
    perform public.grnd_error(410, 'You already have an open shift', jsonb_build_object('shift_id', open_.id, 'started_at', open_.started_at));
  end if;
  insert into public.shifts(profile_id, device_id, start_point) values (auth.uid(), device_id, public.mk_point(location)) returning * into s;
  return public.idem_store(idempotency_key, 'shift_start',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('shift_id', s.id, 'started_at', s.started_at), 'replayed', false));
end $$;

-- ---------- shift_end ----------
create or replace function public.shift_end(idempotency_key uuid, shift_id uuid, location jsonb default null, note text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; s record; open_tasks uuid[];
begin
  prior := public.idem_check(idempotency_key, 'shift_end'); if prior is not null then return prior; end if;
  perform public.auth_role();
  select * into s from public.shifts where id = shift_id;
  if s is null then perform public.grnd_error(404, 'Shift not found'); end if;
  if s.profile_id <> auth.uid() then perform public.grnd_error(403, 'Not your shift'); end if;
  if s.ended_at is not null then perform public.grnd_error(410, 'Shift already ended', jsonb_build_object('ended_at', s.ended_at)); end if;
  update public.shifts set ended_at = now(), end_point = public.mk_point(location), note = shift_end.note, ended_by = auth.uid()
   where id = shift_id returning * into s;
  open_tasks := public.open_task_ids_for(auth.uid());
  return public.idem_store(idempotency_key, 'shift_end',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('shift_id', s.id, 'started_at', s.started_at, 'ended_at', s.ended_at,
      'duration_minutes', round(extract(epoch from (s.ended_at - s.started_at)) / 60), 'open_task_ids', to_jsonb(open_tasks)), 'replayed', false));
end $$;

-- placeholder, replaced in 0006 once tasks exist
create or replace function public.open_task_ids_for(p uuid) returns uuid[] language sql stable as $$ select '{}'::uuid[] $$;

-- lead or admin ends someone else's shift (phone died)
create or replace function public.shift_end_for(idempotency_key uuid, profile_id uuid, note text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; s record;
begin
  prior := public.idem_check(idempotency_key, 'shift_end_for'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','lead') or not public.can_see_profile(profile_id) then perform public.grnd_error(403, 'You may not end that shift'); end if;
  update public.shifts set ended_at = now(), ended_by = auth.uid(), note = shift_end_for.note
   where shifts.profile_id = shift_end_for.profile_id and ended_at is null returning * into s;
  if s is null then perform public.grnd_error(410, 'No open shift for that person'); end if;
  return public.idem_store(idempotency_key, 'shift_end_for',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('shift_id', s.id, 'ended_at', s.ended_at), 'replayed', false));
end $$;

-- ---------- location_upload ----------
create or replace function public.location_upload(idempotency_key uuid, shift_id uuid, samples jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; s record; smp jsonb; accepted int := 0; rejected jsonb := '[]'::jsonb; i int := 0;
        pt geometry; acc numeric; ta timestamptz; nz record; asmt jsonb; last_ta timestamptz; last_asmt jsonb;
begin
  prior := public.idem_check(idempotency_key, 'location_upload'); if prior is not null then return prior; end if;
  perform public.auth_role();
  select * into s from public.shifts where id = shift_id and profile_id = auth.uid();
  if s is null or s.ended_at is not null then perform public.grnd_error(425, 'No open shift'); end if;
  if samples is null or jsonb_typeof(samples) <> 'array' then perform public.grnd_error(422, 'samples must be an array', '{"fields":["samples"]}'); end if;
  if jsonb_array_length(samples) > 200 then perform public.grnd_error(422, 'max 200 samples per call', '{"fields":["samples"]}'); end if;
  for smp in select * from jsonb_array_elements(samples) loop
    pt := public.mk_point(smp); acc := (smp->>'accuracy_m')::numeric; ta := (smp->>'taken_at')::timestamptz;
    if pt is null or acc is null or ta is null or ta > now() + interval '2 minutes' then
      rejected := rejected || jsonb_build_object('index', i, 'reason', 'missing lng/lat/accuracy_m/taken_at or future timestamp');
    else
      select * into nz from public.nearest_zone_version(pt);
      asmt := public.assess_location(pt, acc, ta, nz.zone_version_id);
      insert into public.location_samples(shift_id, profile_id, taken_at, geom, accuracy_m, speed_mps, heading, battery, source, zone_id, zone_version_id, result, distance_m)
      values (shift_id, auth.uid(), ta, pt, acc, (smp->>'speed_mps')::numeric, (smp->>'heading')::numeric, (smp->>'battery')::smallint, smp->>'source',
              nz.zone_id, nz.zone_version_id, asmt->>'result', (asmt->>'distance_m')::numeric);
      accepted := accepted + 1;
      if last_ta is null or ta > last_ta then
        last_ta := ta; last_asmt := asmt || jsonb_build_object('zone_id', nz.zone_id, 'zone_version_id', nz.zone_version_id);
        update public.shifts set last_sample_at = ta, last_point = pt, last_accuracy_m = acc, last_zone_id = nz.zone_id,
               last_zone_version_id = nz.zone_version_id, last_result = asmt->>'result', sample_count = shifts.sample_count + 1 where id = shift_id;
      end if;
    end if;
    i := i + 1;
  end loop;
  return public.idem_store(idempotency_key, 'location_upload',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('accepted', accepted, 'rejected', jsonb_array_length(rejected),
      'rejected_detail', rejected, 'last_taken_at', last_ta, 'assessment', last_asmt), 'replayed', false));
end $$;

-- ---------- RLS, views, grants ----------
alter table public.shifts enable row level security;
alter table public.location_samples enable row level security;
create policy shifts_read on public.shifts for select to authenticated using (public.can_see_profile(profile_id));
create policy samples_read on public.location_samples for select to authenticated using (public.can_see_profile(profile_id));

create view public.v_my_shift with (security_invoker = true) as
select s.id as shift_id, s.started_at, s.last_sample_at as last_location_at,
       (s.last_sample_at is null or s.last_sample_at < now() - interval '5 minutes') as location_stale,
       s.sample_count as samples_today, s.last_zone_id, s.last_result, s.device_id
from public.shifts s where s.profile_id = auth.uid() and s.ended_at is null;

grant select on public.shifts, public.location_samples, public.v_my_shift to authenticated;
grant execute on function public.mk_point(jsonb), public.shift_start(uuid, text, jsonb), public.shift_end(uuid, uuid, jsonb, text),
  public.shift_end_for(uuid, uuid, text), public.location_upload(uuid, uuid, jsonb), public.open_task_ids_for(uuid) to authenticated;
