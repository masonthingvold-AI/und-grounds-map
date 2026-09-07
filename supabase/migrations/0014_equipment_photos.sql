-- 0014 Equipment as a first-class list: photos of machines and people, admin editing from the app, current holder on every asset.
-- Mason, Sep 7, 2026: equipment is a side-menu list with a picture and information per machine and the picture of the person it is assigned to.

-- ---------- media bucket (machine photos, people photos). Readable by anyone signed in, written through functions. ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', false, 8388608, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do nothing;

alter table public.assets add column photo_path text, add column photo_updated_at timestamptz, add column notes text;
alter table public.profiles add column avatar_path text, add column avatar_updated_at timestamptz;

-- registered upload targets, same pattern as evidence: register first, then storage.upload to the returned path
create table public.media_uploads (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('asset_photo','avatar')),
  target_id text not null,                 -- asset id, or profile uuid as text
  path text not null unique,
  uploaded_by uuid not null references public.profiles(id),
  registered_at timestamptz not null default now(),
  applied_at timestamptz
);
alter table public.media_uploads enable row level security;
create policy media_uploads_read on public.media_uploads for select to authenticated using (uploaded_by = auth.uid() or public.is_admin());

create policy media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and exists (select 1 from public.media_uploads m where m.path = name and m.uploaded_by = auth.uid()));
create policy media_read on storage.objects for select to authenticated using (bucket_id = 'media');
-- no update or delete from the app; a new photo is a new path and the old one stays

-- who may set a photo: admins for any asset; anyone for their own avatar; admins for anyone's avatar
create or replace function public.media_upload_path(kind text, target_id text, content_type text default 'image/jpeg')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r text; ext text; p text;
begin
  r := public.auth_role();
  if kind = 'asset_photo' then
    if r <> 'admin' then perform public.grnd_error(403, 'Only admins change equipment photos'); end if;
    if not exists (select 1 from public.assets where id = target_id) then perform public.grnd_error(404, 'Asset not found'); end if;
  elsif kind = 'avatar' then
    if not (target_id = auth.uid()::text or r = 'admin') then perform public.grnd_error(403, 'You may only change your own photo'); end if;
  else perform public.grnd_error(422, 'kind must be asset_photo or avatar', '{"fields":["kind"]}'); end if;
  ext := case content_type when 'image/png' then 'png' when 'image/webp' then 'webp' when 'image/heic' then 'heic' else 'jpg' end;
  p := format('%s/%s/%s.%s', kind, target_id, gen_random_uuid(), ext);
  insert into public.media_uploads(kind, target_id, path, uploaded_by) values (kind, target_id, p, auth.uid());
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('bucket', 'media', 'path', p, 'upload', 'direct'));
end $$;

-- after the upload: point the asset or profile at the new photo (verifies the object exists)
create or replace function public.media_apply(idempotency_key uuid, path text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; m record;
begin
  prior := public.idem_check(idempotency_key, 'media_apply'); if prior is not null then return prior; end if;
  perform public.auth_role();
  select * into m from public.media_uploads where media_uploads.path = media_apply.path and uploaded_by = auth.uid();
  if m.id is null then perform public.grnd_error(404, 'Upload not registered by you'); end if;
  if not exists (select 1 from storage.objects where bucket_id = 'media' and name = path) then perform public.grnd_error(422, 'File not uploaded yet', '{"fields":["path"]}'); end if;
  if m.kind = 'asset_photo' then update public.assets set photo_path = path, photo_updated_at = now() where id = m.target_id;
  else update public.profiles set avatar_path = path, avatar_updated_at = now() where id = m.target_id::uuid; end if;
  update public.media_uploads set applied_at = now() where id = m.id;
  return public.idem_store(idempotency_key, 'media_apply', jsonb_build_object('ok', true, 'data', jsonb_build_object('kind', m.kind, 'target_id', m.target_id, 'path', path), 'replayed', false));
end $$;

-- ---------- equipment editing from the app (admin), no service role needed ----------
create or replace function public.asset_upsert(
  idempotency_key uuid, id text, name text, asset_type text, class text,
  make text default null, model text default null, year int default null, serial text default null,
  required_capability_code text default null, compatible_with text[] default null, status text default null,
  home_zone_id text default null, location jsonb default null, hour_meter numeric default null, barcode text default null,
  howto_md text default null, notes text default null, attrs jsonb default null, active boolean default true)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; a public.assets;
begin
  prior := public.idem_check(idempotency_key, 'asset_upsert'); if prior is not null then return prior; end if;
  if not public.is_admin() then perform public.grnd_error(403, 'Only admins edit equipment'); end if;
  if id is null or id !~ '^[A-Z]{2,4}-[0-9A-Za-z]{1,8}$' then perform public.grnd_error(422, 'id must look like EQ-07 or ATT-03', '{"fields":["id"]}'); end if;
  if required_capability_code is not null and not exists (select 1 from public.capabilities where code = required_capability_code) then
    perform public.grnd_error(404, 'Unknown capability ' || required_capability_code); end if;
  insert into public.assets(id, name, asset_type, class, make, model, year, serial, required_capability_code, compatible_with, status, home_zone_id, location, hour_meter, barcode, howto_md, notes, attrs, active)
  values (id, name, asset_type, class, make, model, year, serial, required_capability_code, coalesce(compatible_with, '{}'), coalesce(status, 'in_service'), home_zone_id,
          public.mk_point(location), hour_meter, coalesce(barcode, id), howto_md, notes, coalesce(attrs, '{}'::jsonb), coalesce(active, true))
  on conflict (id) do update set name = excluded.name, asset_type = excluded.asset_type, class = excluded.class, make = excluded.make, model = excluded.model, year = excluded.year,
    serial = excluded.serial, required_capability_code = excluded.required_capability_code, compatible_with = excluded.compatible_with, status = coalesce(asset_upsert.status, assets.status),
    home_zone_id = excluded.home_zone_id, location = coalesce(excluded.location, assets.location), hour_meter = coalesce(excluded.hour_meter, assets.hour_meter),
    barcode = coalesce(asset_upsert.barcode, assets.barcode), howto_md = coalesce(excluded.howto_md, assets.howto_md), notes = coalesce(excluded.notes, assets.notes),
    attrs = coalesce(asset_upsert.attrs, assets.attrs), active = coalesce(asset_upsert.active, assets.active)
  returning * into a;
  return public.idem_store(idempotency_key, 'asset_upsert', jsonb_build_object('ok', true, 'data', jsonb_build_object('id', a.id, 'name', a.name, 'status', a.status), 'replayed', false));
end $$;

-- ---------- the equipment list: machine, photo, who holds it right now and their photo ----------
drop view public.v_assets;
create view public.v_assets with (security_invoker = true) as
select a.id, a.name, a.asset_type, a.class, a.make, a.model, a.year, a.serial, a.required_capability_code, a.compatible_with, a.status,
       a.home_zone_id, z.name as home_zone_name, st_asgeojson(a.location)::jsonb as location, a.hour_meter, a.barcode, a.howto_md, a.notes, a.attrs,
       a.photo_path, a.photo_updated_at,
       r.holder_id, public.profile_name(r.holder_id) as holder_name, hp.avatar_path as holder_avatar_path,
       r.task_id as holder_task_id, t.zone_id as holder_zone_id, t.state as holder_task_state, r.during as reserved_window,
       (select count(*) from public.asset_reservations x where x.asset_id = a.id and x.released_at is null and x.during @> now()) > 0 as in_use,
       a.active
from public.assets a
left join public.zones z on z.id = a.home_zone_id
left join lateral (select * from public.asset_reservations r where r.asset_id = a.id and r.released_at is null and r.during @> now() order by r.created_at desc limit 1) r on true
left join public.profiles hp on hp.id = r.holder_id
left join public.tasks t on t.id = r.task_id
where a.active;

create or replace view public.v_me with (security_invoker = true) as
select p.id, p.full_name, p.phone, p.email, p.employment_tier, p.app_role, p.crew_id, c.name as crew_name,
       p.reports_to, p.is_student, p.active, public.valid_capability_codes(p.id) as capabilities, p.avatar_path
from public.profiles p left join public.crews c on c.id = p.crew_id where p.id = auth.uid();

drop view public.v_crew_availability;
create view public.v_crew_availability with (security_invoker = true) as
select p.id as profile_id, p.full_name, p.app_role, p.employment_tier, p.crew_id, c.name as crew_name, p.avatar_path,
       (select max(cp.ends_at) from public.crew_placements cp where cp.profile_id = p.id and cp.starts_at <= now() and (cp.ends_at is null or cp.ends_at > now())) as placement_until,
       (s.id is not null) as on_shift, s.started_at as shift_started_at,
       s.last_sample_at as last_location_at, st_asgeojson(s.last_point)::jsonb as last_location,
       (s.id is not null and (s.last_sample_at is null or s.last_sample_at < now() - interval '5 minutes')) as location_stale,
       s.last_zone_id as current_zone_id, z.name as current_zone_name, s.last_result as current_zone_result,
       (select count(*) from public.tasks x where x.assignee_id = p.id and x.state in ('assigned','accepted','in_progress','blocked'))::int as open_task_count,
       ip.id as in_progress_task_id, ipz.name as in_progress_zone_name,
       public.valid_capability_codes(p.id) as capabilities,
       null::numeric as hours_today, null::numeric as hours_week,
       case when not p.active then 'unavailable' when s.id is null then 'off_shift' when ip.id is not null then 'busy' else 'free' end as availability,
       (select coalesce(jsonb_agg(jsonb_build_object('asset_id', r.asset_id, 'name', a.name, 'photo_path', a.photo_path)), '[]'::jsonb)
          from public.asset_reservations r join public.assets a on a.id = r.asset_id where r.holder_id = p.id and r.released_at is null and r.during @> now()) as holding
from public.profiles p
left join public.crews c on c.id = p.crew_id
left join public.shifts s on s.profile_id = p.id and s.ended_at is null
left join public.zones z on z.id = s.last_zone_id
left join lateral (select x.id, x.zone_id from public.tasks x where x.assignee_id = p.id and x.state = 'in_progress' limit 1) ip on true
left join public.zones ipz on ipz.id = ip.zone_id
where p.active and p.app_role in ('admin','lead','worker');

grant select on public.media_uploads, public.v_assets, public.v_me, public.v_crew_availability to authenticated;
grant execute on function public.media_upload_path(text, text, text), public.media_apply(uuid, text),
  public.asset_upsert(uuid, text, text, text, text, text, text, int, text, text, text[], text, text, jsonb, numeric, text, text, text, jsonb, boolean) to authenticated;

-- the default-privilege revoke in 0013 does not reach functions created by the migration runner's role, so say it here too
revoke execute on function public.media_upload_path(text, text, text), public.media_apply(uuid, text),
  public.asset_upsert(uuid, text, text, text, text, text, text, int, text, text, text[], text, text, jsonb, numeric, text, text, text, jsonb, boolean) from public, anon;
