-- 0007 Evidence: photos in Storage, service records, per-record hash chained evidence events.
-- docs/api-contract.md section 7. ADR decisions 8, 9, 15. Tamper evidence, not immutability.

-- ---------- storage bucket ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidence', 'evidence', false, 8388608, array['image/jpeg','image/png','image/heic'])
on conflict (id) do nothing;

-- ---------- evidence objects (one row per photo the client intends to upload) ----------
create table public.evidence_objects (
  id uuid primary key,                          -- client_photo_id, generated on the phone
  task_id uuid not null references public.tasks(id),
  kind text not null check (kind in ('before','after','issue','material','other')),
  path text not null unique,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  taken_at timestamptz not null,
  location geometry(Point, 4326),
  accuracy_m numeric,
  uploaded_by uuid not null references public.profiles(id),
  registered_at timestamptz not null default now(),
  server_received_at timestamptz,              -- set at finalize when the object is confirmed in storage
  size_bytes bigint,
  service_record_id uuid,                       -- fk added below
  superseded_by uuid references public.evidence_objects(id),
  legal_hold boolean not null default false,
  hash_verified_at timestamptz                  -- set by the verification Edge Function (planned)
);
create index evidence_objects_task_idx on public.evidence_objects(task_id);

-- ---------- service records: the liability record ----------
create table public.service_records (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null unique references public.tasks(id),
  zone_id text not null references public.zones(id),
  zone_version_id uuid not null references public.zone_versions(id),
  profile_id uuid not null references public.profiles(id),
  assignment_id uuid references public.assignments(id),
  asset_id text references public.assets(id),
  attachment_id text references public.assets(id),
  action text not null check (action in ('plowed','shoveled','salted','sanded','brined','mowed','trimmed','inspected','other')),
  started_at timestamptz not null,
  completed_at timestamptz not null,
  device_completed_at timestamptz not null,
  server_time timestamptz not null default now(),
  completion_point geometry(Point, 4326) not null,
  gps_accuracy_m numeric not null,
  assessment jsonb not null,                    -- from assess_location, computed here, never supplied
  materials jsonb not null default '[]'::jsonb,
  conditions jsonb not null default '{}'::jsonb,
  weather_snapshot jsonb,                       -- filled by the weather Edge Function later
  notes text,
  event_id uuid,                                -- fk to weather_events in 0008
  legal_hold boolean not null default false,
  created_at timestamptz not null default now()
);
create index service_records_zone_idx on public.service_records(zone_id, completed_at desc);
create index service_records_profile_idx on public.service_records(profile_id, completed_at desc);
create trigger service_records_immutable before update or delete on public.service_records for each row execute function public.forbid_change();
alter table public.evidence_objects add constraint evidence_objects_record_fk foreign key (service_record_id) references public.service_records(id);
alter table public.material_transactions add constraint material_tx_record_fk foreign key (service_record_id) references public.service_records(id);

-- ---------- evidence events: append only, per record sequence and hash chain ----------
create table public.evidence_events (
  id uuid primary key default gen_random_uuid(),
  record_id uuid not null references public.service_records(id),
  seq int not null,
  kind text not null,                           -- record_created, photo, approval, correction, note
  actor uuid references public.profiles(id),
  at timestamptz not null default now(),
  payload jsonb not null,
  prev_hash text not null,
  hash text not null,
  unique (record_id, seq)
);
create trigger evidence_events_immutable before update or delete on public.evidence_events for each row execute function public.forbid_change();

-- canonical serialization: jsonb text form is deterministic for equal jsonb values
create or replace function public.evidence_append(p_record uuid, p_kind text, p_payload jsonb) returns record
language plpgsql security definer set search_path = public as $$
declare last_ record; s int; prev text; h text; ev record; canon text;
begin
  select seq, hash into last_ from public.evidence_events where record_id = p_record order by seq desc limit 1 for update;
  s := coalesce(last_.seq, 0) + 1;
  prev := coalesce(last_.hash, repeat('0', 64));
  canon := jsonb_build_object('record_id', p_record, 'seq', s, 'kind', p_kind, 'actor', auth.uid(), 'payload', p_payload)::text;
  h := encode(extensions.digest(prev || '|' || canon, 'sha256'), 'hex');
  insert into public.evidence_events(record_id, seq, kind, actor, payload, prev_hash, hash)
  values (p_record, s, p_kind, auth.uid(), p_payload, prev, h) returning seq, hash into ev;
  return ev;
end $$;

-- recompute the chain for one record; returns ok plus the first bad seq if any
create or replace function public.evidence_verify(p_record uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e record; prev text := repeat('0', 64); canon text; h text; n int := 0;
begin
  perform public.auth_role();
  for e in select * from public.evidence_events where record_id = p_record order by seq loop
    n := n + 1;
    if e.seq <> n or e.prev_hash <> prev then return jsonb_build_object('ok', false, 'bad_seq', e.seq, 'why', 'sequence or prev_hash mismatch'); end if;
    canon := jsonb_build_object('record_id', e.record_id, 'seq', e.seq, 'kind', e.kind, 'actor', e.actor, 'payload', e.payload)::text;
    h := encode(extensions.digest(prev || '|' || canon, 'sha256'), 'hex');
    if h <> e.hash then return jsonb_build_object('ok', false, 'bad_seq', e.seq, 'why', 'hash mismatch'); end if;
    prev := e.hash;
  end loop;
  return jsonb_build_object('ok', true, 'events', n, 'head', prev);
end $$;

-- ---------- evidence_upload_url ----------
-- Registers the intended object and returns its path. The client then uploads with
-- supabase.storage.from('evidence').upload(path, blob, { contentType: 'image/jpeg', upsert: false }).
-- The storage policy below only allows an insert at a path this function registered for this user.
create or replace function public.evidence_upload_url(task_id uuid, kind text, client_photo_id uuid, sha256 text, taken_at timestamptz, location jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.tasks; r text; p text; existing record;
begin
  r := public.auth_role();
  select * into t from public.tasks where id = task_id;
  if t is null then perform public.grnd_error(404, 'Task not found'); end if;
  if not (t.assignee_id = auth.uid() or r = 'admin' or (r = 'lead' and public.can_see_task(t))) then perform public.grnd_error(403, 'Not your task'); end if;
  if t.state in ('done','canceled') then perform public.grnd_error(410, 'Task is ' || t.state); end if;
  if sha256 !~ '^[0-9a-f]{64}$' then perform public.grnd_error(422, 'sha256 must be 64 hex characters', '{"fields":["sha256"]}'); end if;
  select * into existing from public.evidence_objects where id = client_photo_id;
  if existing.id is not null then
    if existing.uploaded_by <> auth.uid() or existing.task_id <> task_id then perform public.grnd_error(422, 'client_photo_id already used elsewhere', '{"fields":["client_photo_id"]}'); end if;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('path', existing.path, 'signed_url', null, 'upload', 'direct', 'bucket', 'evidence'), 'replayed', true);
  end if;
  p := format('evidence/%s/%s/%s/%s-%s.jpg', to_char(taken_at at time zone 'UTC', 'YYYY'), to_char(taken_at at time zone 'UTC', 'MM'), task_id, kind, client_photo_id);
  insert into public.evidence_objects(id, task_id, kind, path, sha256, taken_at, location, accuracy_m, uploaded_by)
  values (client_photo_id, task_id, kind, p, sha256, taken_at, public.mk_point(location), (location->>'accuracy_m')::numeric, auth.uid());
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('path', p, 'signed_url', null, 'upload', 'direct', 'bucket', 'evidence'), 'replayed', false);
end $$;

-- ---------- service_finalize ----------
create or replace function public.service_finalize(
  idempotency_key uuid, task_id uuid, action text, started_at timestamptz, completed_at timestamptz, location jsonb, photos jsonb,
  expected_revision int default null, materials jsonb default '[]'::jsonb, asset_id text default null, attachment_id text default null,
  conditions jsonb default '{}'::jsonb, notes text default null, supersedes_photo_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; t public.tasks; s record; a public.assignments; pt geometry; acc numeric; asmt jsonb; rec public.service_records;
        ph jsonb; eo record; so record; missing text[] := '{}'; kinds text[] := '{}'; m jsonb; ev record; last_ev record; rid uuid;
begin
  prior := public.idem_check(idempotency_key, 'service_finalize'); if prior is not null then return prior; end if;
  perform public.auth_role();
  t := public.load_task(task_id);
  perform public.check_revision(t, expected_revision);
  if t.assignee_id <> auth.uid() then perform public.grnd_error(403, 'Not your task'); end if;
  if t.state <> 'in_progress' then perform public.grnd_error(410, 'Task is ' || t.state || ', start it first', jsonb_build_object('state', t.state)); end if;
  select * into s from public.shifts where profile_id = auth.uid() and ended_at is null;
  if s is null then perform public.grnd_error(425, 'No open shift'); end if;
  if completed_at is null or started_at is null or completed_at < started_at then missing := array_append(missing, 'completed_at'); end if;
  pt := public.mk_point(location); acc := (location->>'accuracy_m')::numeric;
  if pt is null or acc is null then missing := array_append(missing, 'location'); end if;
  -- photos: each must be registered by this user for this task and present in storage
  if photos is null or jsonb_typeof(photos) <> 'array' then photos := '[]'::jsonb; end if;
  for ph in select * from jsonb_array_elements(photos) loop
    select * into eo from public.evidence_objects where id = (ph->>'client_photo_id')::uuid;
    if eo is null or eo.task_id <> task_id or eo.uploaded_by <> auth.uid() then missing := array_append(missing, ('photos.' || coalesce(ph->>'client_photo_id', '?'))); continue; end if;
    if eo.sha256 <> lower(coalesce(ph->>'sha256', '')) then missing := array_append(missing, ('photos.' || eo.id::text || '.sha256')); continue; end if;
    select * into so from storage.objects where bucket_id = 'evidence' and name = eo.path;
    if so is null then missing := array_append(missing, ('photos.' || eo.id::text || '.not_uploaded')); continue; end if;
    kinds := kinds || eo.kind;
  end loop;
  if 'photo_before' = any(t.evidence_required) and not ('before' = any(kinds)) then missing := array_append(missing, 'photos.before'); end if;
  if 'photo_after' = any(t.evidence_required) and not ('after' = any(kinds)) then missing := array_append(missing, 'photos.after'); end if;
  if 'material_qty' = any(t.evidence_required) and (materials is null or jsonb_array_length(materials) = 0) then missing := array_append(missing, 'materials'); end if;
  for m in select * from jsonb_array_elements(coalesce(materials, '[]'::jsonb)) loop
    if not exists (select 1 from public.materials where code = m->>'material_code' and active) or (m->>'qty') is null then missing := array_append(missing, ('materials.' || coalesce(m->>'material_code', '?'))); end if;
  end loop;
  if array_length(missing, 1) > 0 then
    perform public.grnd_error(422, 'Missing or invalid: ' || array_to_string(missing, ', '), jsonb_build_object('fields', to_jsonb(missing)));
  end if;
  asmt := public.assess_location(pt, acc, coalesce((location->>'taken_at')::timestamptz, completed_at), t.zone_version_id);
  select * into a from public.assignments where id = t.current_assignment_id;
  insert into public.service_records(task_id, zone_id, zone_version_id, profile_id, assignment_id, asset_id, attachment_id, action,
    started_at, completed_at, device_completed_at, completion_point, gps_accuracy_m, assessment, materials, conditions, notes)
  values (task_id, t.zone_id, t.zone_version_id, auth.uid(), a.id, coalesce(asset_id, a.asset_id), coalesce(attachment_id, a.attachment_id), action,
    started_at, now(), completed_at, pt, acc, asmt, coalesce(materials, '[]'::jsonb), coalesce(conditions, '{}'::jsonb), notes)
  returning * into rec;
  rid := rec.id;
  -- chain: record first, then each photo, then supersessions
  ev := public.evidence_append(rid, 'record_created', jsonb_build_object('task_id', task_id, 'zone_id', t.zone_id, 'zone_version_id', t.zone_version_id,
          'action', action, 'started_at', started_at, 'completed_at', completed_at, 'device_completed_at', completed_at, 'server_time', rec.server_time,
          'point', st_asgeojson(pt)::jsonb, 'accuracy_m', acc, 'assessment', asmt, 'materials', coalesce(materials, '[]'::jsonb),
          'conditions', coalesce(conditions, '{}'::jsonb), 'asset_id', rec.asset_id, 'attachment_id', rec.attachment_id, 'notes', notes));
  for ph in select * from jsonb_array_elements(photos) loop
    select * into eo from public.evidence_objects where id = (ph->>'client_photo_id')::uuid;
    select * into so from storage.objects where bucket_id = 'evidence' and name = eo.path;
    update public.evidence_objects set service_record_id = rid, server_received_at = so.created_at, size_bytes = (so.metadata->>'size')::bigint where id = eo.id;
    ev := public.evidence_append(rid, 'photo', jsonb_build_object('client_photo_id', eo.id, 'kind', eo.kind, 'path', eo.path, 'sha256', eo.sha256,
            'taken_at', eo.taken_at, 'location', st_asgeojson(eo.location)::jsonb, 'storage_created_at', so.created_at, 'size', so.metadata->>'size'));
  end loop;
  if supersedes_photo_ids is not null then
    update public.evidence_objects e2 set superseded_by = (photos->0->>'client_photo_id')::uuid where e2.id = any(supersedes_photo_ids) and e2.task_id = service_finalize.task_id and e2.superseded_by is null;
    ev := public.evidence_append(rid, 'correction', jsonb_build_object('superseded', to_jsonb(supersedes_photo_ids)));
  end if;
  for m in select * from jsonb_array_elements(coalesce(materials, '[]'::jsonb)) loop
    insert into public.material_transactions(material_code, qty, unit, kind, by_profile, service_record_id, zone_id, note)
    values (m->>'material_code', -abs((m->>'qty')::numeric), coalesce(m->>'unit', (select unit from public.materials where code = m->>'material_code')), 'use', auth.uid(), rid, t.zone_id, 'service ' || rid::text);
  end loop;
  update public.tasks set state = 'review', finalized_at = now(), revision = revision + 1 where id = task_id returning * into t;
  perform public.zone_status_from_action(t.zone_id, t.zone_version_id, action, completed_at, task_id, rid, rec.asset_id);
  perform public.notify('crew:' || coalesce(t.crew_id::text, 'none'), 'review_requested', jsonb_build_object('task_id', t.id, 'record_id', rid, 'revision', t.revision, 'message', t.zone_id || ' ' || action || ', ready for review'));
  select seq, hash into last_ev from public.evidence_events where record_id = rid order by seq desc limit 1;
  return public.idem_store(idempotency_key, 'service_finalize', public.task_result(t, jsonb_build_object('service_record_id', rid, 'assessment', asmt,
    'evidence_event_seq', last_ev.seq, 'row_hash', last_ev.hash, 'verification_url', '/functions/v1/evidence-export?record=' || rid::text)));
end $$;

-- placeholder until 0008 defines zone status
create or replace function public.zone_status_from_action(z text, zv uuid, action text, at timestamptz, task uuid, rec uuid, asset text) returns void language sql as $$ select null $$;

-- ---------- task_approve ----------
create or replace function public.task_approve(idempotency_key uuid, task_id uuid, expected_revision int default null, note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; r text; t public.tasks; rec record; ev record;
begin
  prior := public.idem_check(idempotency_key, 'task_approve'); if prior is not null then return prior; end if;
  r := public.auth_role();
  t := public.load_task(task_id);
  perform public.check_revision(t, expected_revision);
  if not (r = 'admin' or (r = 'lead' and public.can_see_task(t))) then perform public.grnd_error(403, 'Only admins and leads approve'); end if;
  if t.state <> 'review' then perform public.grnd_error(410, 'Task is ' || t.state, jsonb_build_object('state', t.state)); end if;
  select * into rec from public.service_records where service_records.task_id = task_approve.task_id;
  ev := public.evidence_append(rec.id, 'approval', jsonb_build_object('note', note));
  perform public.release_assets(task_id, null);
  update public.tasks set state = 'done', approved_at = now(), revision = revision + 1 where id = task_id returning * into t;
  update public.work_orders set status = 'done' where id = t.work_order_id and not exists (select 1 from public.tasks x where x.work_order_id = t.work_order_id and x.state not in ('done','canceled'));
  if t.assignee_id is not null then
    perform public.notify('person:' || t.assignee_id::text, 'approved', jsonb_build_object('task_id', t.id, 'revision', t.revision, 'message', t.zone_id || ' approved'));
  end if;
  return public.idem_store(idempotency_key, 'task_approve', public.task_result(t, jsonb_build_object('service_record_id', rec.id)));
end $$;

-- ---------- storage policies ----------
create policy evidence_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'evidence' and exists (select 1 from public.evidence_objects e where e.path = name and e.uploaded_by = auth.uid()));
create policy evidence_read on storage.objects for select to authenticated
  using (bucket_id = 'evidence' and exists (select 1 from public.evidence_objects e join public.tasks t on t.id = e.task_id where e.path = name and public.can_see_task(t)));
-- no update or delete policy for app roles: objects cannot be replaced or removed from the app (tamper evidence, not a retention lock: ADR 8)

-- ---------- RLS, views, grants ----------
alter table public.evidence_objects enable row level security;
alter table public.service_records enable row level security;
alter table public.evidence_events enable row level security;
create policy evidence_objects_read on public.evidence_objects for select to authenticated using (exists (select 1 from public.tasks t where t.id = task_id and public.can_see_task(t)));
create policy service_records_read on public.service_records for select to authenticated using (exists (select 1 from public.tasks t where t.id = task_id and public.can_see_task(t)));
create policy evidence_events_read on public.evidence_events for select to authenticated using (exists (select 1 from public.service_records r join public.tasks t on t.id = r.task_id where r.id = record_id and public.can_see_task(t)));

create view public.v_service_records with (security_invoker = true) as
select r.id as service_record_id, r.task_id, r.zone_id, z.name as zone_name, r.zone_version_id, r.profile_id, p.full_name as profile_name,
       r.asset_id, r.attachment_id, r.action, r.started_at, r.completed_at, r.device_completed_at, r.server_time,
       st_asgeojson(r.completion_point)::jsonb as completion_point, r.gps_accuracy_m, r.assessment, r.materials, r.conditions, r.weather_snapshot, r.notes, r.legal_hold,
       (select coalesce(jsonb_agg(jsonb_build_object('evidence_id', e.id, 'kind', e.kind, 'path', e.path, 'sha256', e.sha256, 'taken_at', e.taken_at,
          'location', st_asgeojson(e.location)::jsonb, 'superseded_by', e.superseded_by, 'size_bytes', e.size_bytes) order by e.taken_at), '[]'::jsonb)
          from public.evidence_objects e where e.service_record_id = r.id) as evidence,
       (select max(seq) from public.evidence_events ev where ev.record_id = r.id) as event_count,
       (select hash from public.evidence_events ev where ev.record_id = r.id order by seq desc limit 1) as head_hash
from public.service_records r join public.zones z on z.id = r.zone_id join public.profiles p on p.id = r.profile_id;

grant select on public.evidence_objects, public.service_records, public.evidence_events, public.v_service_records to authenticated;
grant execute on function public.evidence_upload_url(uuid, text, uuid, text, timestamptz, jsonb),
  public.service_finalize(uuid, uuid, text, timestamptz, timestamptz, jsonb, jsonb, int, jsonb, text, text, jsonb, text, uuid[]),
  public.task_approve(uuid, uuid, int, text), public.evidence_verify(uuid) to authenticated;
revoke execute on function public.evidence_append(uuid, text, jsonb), public.zone_status_from_action(text, uuid, text, timestamptz, uuid, uuid, text) from anon, authenticated;
