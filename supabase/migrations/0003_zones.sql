-- 0003 Zones (identity), zone versions (immutable geometry), keep-outs, location assessment
-- ADR decisions 5 and 7. Zone ids match data/*.geojson ids (MOW-03, SW-2, LOT-REA, BND-01, AST-01).

create table public.zones (
  id text primary key,
  name text not null,
  class text not null check (class in ('mowing_area','walk_route','lot','road','tier_zone','campus','crew_area','keep_out','sprayed','bed','point','other')),
  site text not null default 'main' check (site in ('main','greek','memorial','airport','offsite')),
  ownership text not null default 'UND' check (ownership in ('UND','future','not UND')),
  season text not null default 'either' check (season in ('landscaping','snow','either')),
  priority_landscaping smallint check (priority_landscaping between 1 and 3),
  priority_snow smallint check (priority_snow between 1 and 4),
  responsible_crew_id uuid references public.crews(id),
  owner text,                                   -- Facilities, Housing, Parking, REA, EERC, Athletics, Wellness
  acres_of_record numeric,                      -- from the UND mowing map, the number of record (AGENTS.md rule 4)
  attrs jsonb not null default '{}'::jsonb,      -- every other GeoJSON property, verbatim
  current_version_id uuid,                      -- fk added below
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger zones_touch before update on public.zones for each row execute function public.touch_updated_at();

create table public.zone_versions (
  id uuid primary key default gen_random_uuid(),
  zone_id text not null references public.zones(id),
  version int not null,
  geom geometry(Geometry, 4326) not null,
  geog geography generated always as (geom::geography) stored,
  needs_tracing boolean not null default true,
  source text not null,                         -- geojson:data/mowing_areas.geojson@<commit>, map_edit, city_parcels, ecopia
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  note text,
  unique (zone_id, version)
);
create index zone_versions_geom_gix on public.zone_versions using gist (geom);
create index zone_versions_geog_gix on public.zone_versions using gist (geog);
alter table public.zones add constraint zones_current_version_fk foreign key (current_version_id) references public.zone_versions(id);

-- zone_versions are immutable: no update, no delete, for anyone but the postgres owner
create or replace function public.forbid_change() returns trigger language plpgsql as $$
begin raise exception 'GRND-410: % rows are immutable', tg_table_name; end $$;
create trigger zone_versions_immutable before update or delete on public.zone_versions for each row execute function public.forbid_change();

-- create a new version and make it current. Service role or admin only (map edits come through tools/seed_supabase.py for now).
create or replace function public.zone_version_create(
  p_zone_id text, p_geom jsonb, p_source text, p_needs_tracing boolean default true, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v int; vid uuid; g geometry;
begin
  if auth.uid() is not null and not public.is_admin() then perform public.grnd_error(403, 'Only admins create zone versions'); end if;
  g := st_setsrid(st_geomfromgeojson(p_geom::text), 4326);
  if not st_isvalid(g) then g := st_makevalid(g); end if;
  select coalesce(max(version), 0) + 1 into v from public.zone_versions where zone_id = p_zone_id;
  insert into public.zone_versions(zone_id, version, geom, needs_tracing, source, created_by, note)
  values (p_zone_id, v, g, p_needs_tracing, p_source, auth.uid(), p_note) returning id into vid;
  update public.zones set current_version_id = vid where id = p_zone_id;
  return vid;
end $$;

-- ---------- keep-outs (sprayed areas, hazards, closures), self expiring ----------
create table public.keepouts (
  id uuid primary key default gen_random_uuid(),
  zone_id text references public.zones(id),
  geom geometry(Polygon, 4326),
  kind text not null check (kind in ('sprayed','hazard','closed')),
  reason text not null,
  product text,
  opened_by uuid not null references public.profiles(id),
  starts_at timestamptz not null default now(),
  reentry_at timestamptz,                       -- null means until closed
  closed_by uuid references public.profiles(id),
  closed_at timestamptz,
  photo_path text,
  notes text,
  created_at timestamptz not null default now()
);
create index keepouts_zone_idx on public.keepouts(zone_id) where closed_at is null;
create index keepouts_geom_gix on public.keepouts using gist (geom);

create or replace function public.keepout_active_for_zone(z text) returns text
language sql stable security definer set search_path = public as $$
  select kind || ': ' || reason from public.keepouts
  where zone_id = z and closed_at is null and starts_at <= now() and (reentry_at is null or reentry_at > now())
  order by starts_at desc limit 1
$$;

create or replace function public.keepout_open(
  idempotency_key uuid, kind text, reason text, zone_id text default null, geom jsonb default null,
  product text default null, reentry_at timestamptz default null, photo_path text default null, notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; r text; kid uuid; g geometry;
begin
  prior := public.idem_check(idempotency_key, 'keepout_open'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','lead') then perform public.grnd_error(403, 'Only admins and leads open keep-outs'); end if;
  if zone_id is null and geom is null then perform public.grnd_error(422, 'zone_id or geom is required', '{"fields":["zone_id","geom"]}'); end if;
  if geom is not null then g := st_setsrid(st_geomfromgeojson(geom::text), 4326); end if;
  insert into public.keepouts(zone_id, geom, kind, reason, product, opened_by, reentry_at, photo_path, notes)
  values (zone_id, g, kind, reason, product, auth.uid(), reentry_at, photo_path, notes) returning id into kid;
  return public.idem_store(idempotency_key, 'keepout_open',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('keepout_id', kid, 'zone_id', zone_id, 'kind', kind), 'replayed', false));
end $$;

create or replace function public.keepout_close(idempotency_key uuid, keepout_id uuid, note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; r text; n int;
begin
  prior := public.idem_check(idempotency_key, 'keepout_close'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','lead') then perform public.grnd_error(403, 'Only admins and leads close keep-outs'); end if;
  update public.keepouts set closed_by = auth.uid(), closed_at = now(), notes = coalesce(notes || E'\n', '') || coalesce(note, '')
   where id = keepout_id and closed_at is null;
  get diagnostics n = row_count;
  if n = 0 then perform public.grnd_error(410, 'Keep-out not found or already closed'); end if;
  return public.idem_store(idempotency_key, 'keepout_close',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('keepout_id', keepout_id, 'closed', true), 'replayed', false));
end $$;

-- ---------- location assessment (ADR decision 7) ----------
-- Result: inside, boundary, ambiguous, outside, unavailable. Computed from distance in meters, reported accuracy, sample age, zone class.
-- No fixed buffer. Wide accuracy on a narrow feature is ambiguous, never inside.
create or replace function public.assess_location(
  p_point geometry, p_accuracy_m numeric, p_taken_at timestamptz, p_zone_version_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare zv record; d numeric; acc numeric; age_s numeric; res text; zclass text; halfwidth numeric;
begin
  if p_point is null or p_zone_version_id is null then
    return jsonb_build_object('result', 'unavailable', 'distance_m', null, 'accuracy_m', p_accuracy_m, 'zone_class', null);
  end if;
  select zv0.*, z.class into zv from public.zone_versions zv0 join public.zones z on z.id = zv0.zone_id where zv0.id = p_zone_version_id;
  if zv is null then return jsonb_build_object('result', 'unavailable', 'distance_m', null, 'accuracy_m', p_accuracy_m, 'zone_class', null); end if;
  zclass := zv.class;
  acc := coalesce(p_accuracy_m, 9999);
  age_s := coalesce(extract(epoch from (now() - p_taken_at)), 0);
  d := st_distance(zv.geog, p_point::geography);            -- 0 when inside a polygon
  -- Lines (walk routes, roads) have no interior: treat the feature as a strip
  halfwidth := case zclass when 'walk_route' then 3 when 'road' then 8 else 0 end;
  if acc > 60 or age_s > 300 then res := 'unavailable';
  elsif d <= halfwidth and acc <= greatest(halfwidth, 5) + 10 then res := 'inside';
  elsif d <= halfwidth + acc then res := case when acc <= 25 then 'boundary' else 'ambiguous' end;
  elsif d <= halfwidth + acc * 2 then res := 'ambiguous';
  else res := 'outside'; end if;
  return jsonb_build_object('result', res, 'distance_m', round(d::numeric, 1), 'accuracy_m', p_accuracy_m, 'zone_class', zclass, 'age_s', round(age_s));
end $$;

-- which current zone version (polygon classes) contains or is nearest this point, within 30 m
create or replace function public.nearest_zone_version(p_point geometry, p_classes text[] default null)
returns table (zone_id text, zone_version_id uuid, distance_m numeric)
language sql stable security definer set search_path = public as $$
  select z.id, zv.id, round(st_distance(zv.geog, p_point::geography)::numeric, 1)
  from public.zones z join public.zone_versions zv on zv.id = z.current_version_id
  where z.active and z.class <> 'campus' and (p_classes is null or z.class = any(p_classes))
    and st_dwithin(zv.geog, p_point::geography, 30)
  order by st_distance(zv.geog, p_point::geography) asc, z.class = 'walk_route' desc
  limit 1
$$;

-- ---------- RLS and grants ----------
alter table public.zones enable row level security;
alter table public.zone_versions enable row level security;
alter table public.keepouts enable row level security;
create policy zones_read on public.zones for select to authenticated using (true);
create policy zone_versions_read on public.zone_versions for select to authenticated using (true);
create policy keepouts_read on public.keepouts for select to authenticated using (true);

create view public.v_zones with (security_invoker = true) as
select z.id, z.name, z.class, z.site, z.ownership, z.season, z.priority_landscaping, z.priority_snow, z.responsible_crew_id, z.owner,
       z.acres_of_record, z.attrs, z.current_version_id, zv.version, zv.needs_tracing, zv.source,
       st_asgeojson(zv.geom)::jsonb as geom, st_asgeojson(st_centroid(zv.geom))::jsonb as center,
       round((st_area(zv.geog) / 4046.8564224)::numeric, 2) as acres_drawn,
       public.keepout_active_for_zone(z.id) as keepout_reason
from public.zones z left join public.zone_versions zv on zv.id = z.current_version_id
where z.active;

create view public.v_keepouts with (security_invoker = true) as
select k.id, k.zone_id, z.name as zone_name, st_asgeojson(k.geom)::jsonb as geom, k.kind, k.reason, k.product,
       o.full_name as opened_by_name, k.starts_at, k.reentry_at, k.closed_at, c.full_name as closed_by_name, k.photo_path, k.notes,
       (k.closed_at is null and k.starts_at <= now() and (k.reentry_at is null or k.reentry_at > now())) as active
from public.keepouts k left join public.zones z on z.id = k.zone_id
left join public.profiles o on o.id = k.opened_by left join public.profiles c on c.id = k.closed_by;

grant select on public.zones, public.zone_versions, public.keepouts, public.v_zones, public.v_keepouts to authenticated;
grant execute on function public.zone_version_create(text, jsonb, text, boolean, text), public.keepout_active_for_zone(text),
  public.keepout_open(uuid, text, text, text, jsonb, text, timestamptz, text, text), public.keepout_close(uuid, uuid, text),
  public.assess_location(geometry, numeric, timestamptz, uuid), public.nearest_zone_version(geometry, text[]) to authenticated;
