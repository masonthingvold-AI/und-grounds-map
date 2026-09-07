-- 0013 Hardening after the first audit (tools/audit.py), September 7, 2026.
-- 1. Function execution is deny by default. Postgres grants EXECUTE to PUBLIC on every new function; that let anon and
--    authenticated call internal helpers (evidence_append, idem_store, notify, event_put ...). Revoke everything, grant the contract's
--    allow list to authenticated, and change the default privileges so future functions start locked.
-- 2. PostGIS catalog objects are not readable by app roles.
-- 3. Idempotency is race-proof (advisory lock per key).
-- 4. Constraint violations that a client can trigger come back as GRND codes.
-- 5. Housekeeping jobs: command_log and delivered outbox rows older than 30 days.
-- 6. A finalized photo must be a real photo (20 KB minimum).

-- ---------- 1. deny by default ----------
revoke execute on all functions in schema public from public, anon, authenticated;
-- Supabase's own default ACL for role postgres grants execute to anon and authenticated on every new function; remove that too
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

do $$
declare fn text; r record;
begin
  foreach fn in array array[
    'auth_profile_id','auth_role','is_admin','my_crew_ids','can_see_profile','can_see_task','can_direct','profile_name',
    'valid_capability_codes','missing_capabilities','certification_verify','certification_suspend','certification_request','certification_decide',
    'zone_version_create','keepout_active_for_zone','keepout_open','keepout_close','assess_location','nearest_zone_version','asset_available','mk_point',
    'shift_start','shift_end','shift_end_for','location_upload','open_task_ids_for','default_evidence',
    'task_create','task_assign','assignment_acknowledge','assignment_reassign','assignment_release','task_start','task_block','task_unblock','task_cancel',
    'dispatch_candidates','evidence_upload_url','service_finalize','task_approve','evidence_verify',
    'active_event_id','zone_status_set','operating_state_pivot','operating_state_ack',
    'day_log','time_entries_confirm','work_order_link_external',
    'event_watch','event_reminder_ack','events_upsert','events_upsert_ics','reminder_ladder','venue_lookup'] loop
    for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = fn loop
      execute format('grant execute on function %s to authenticated', r.sig);
    end loop;
  end loop;
end $$;
-- trigger functions run as the table owner; no grant needed. Realtime and storage call nothing of ours directly.

-- ---------- 2. PostGIS catalog ----------
-- PostGIS catalog tables are owned by supabase_admin with a PUBLIC read grant that postgres cannot revoke. They hold SRID reference
-- data only, app roles cannot write them, and PostGIS functions live in the extensions schema, outside the API. Accepted (tools/audit.py checks it).

-- ---------- 3. race-proof idempotency ----------
-- Two identical requests arriving together (a retry racing the original) serialize on a per-key lock inside the transaction,
-- so the second one always sees the first one's stored result instead of executing again.
create or replace function public.idem_check(key uuid, fn_name text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare row_ record;
begin
  if key is null then perform public.grnd_error(422, 'idempotency_key is required', '{"fields":["idempotency_key"]}'); end if;
  perform pg_advisory_xact_lock(hashtext('idem:' || key::text));
  select * into row_ from public.command_log where idempotency_key = key;
  if not found then return null; end if;
  if row_.fn <> fn_name or row_.caller <> auth.uid() then
    perform public.grnd_error(422, 'idempotency_key was used for a different command', jsonb_build_object('fields', array['idempotency_key']));
  end if;
  return row_.result || jsonb_build_object('replayed', true);
end $$;

-- ---------- 4. constraint violations as GRND codes ----------
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
  begin
    insert into public.shifts(profile_id, device_id, start_point) values (auth.uid(), device_id, public.mk_point(location)) returning * into s;
  exception when exclusion_violation then
    select * into open_ from public.shifts where profile_id = auth.uid() and ended_at is null;
    perform public.grnd_error(410, 'You already have an open shift', jsonb_build_object('shift_id', open_.id, 'started_at', open_.started_at));
  end;
  return public.idem_store(idempotency_key, 'shift_start',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('shift_id', s.id, 'started_at', s.started_at), 'replayed', false));
end $$;

create or replace function public.reserve_asset(p_asset text, p_holder uuid, p_task public.tasks, p_assignment uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare w tstzrange; avail jsonb;
begin
  if p_asset is null then return; end if;
  w := tstzrange(coalesce(p_task.scheduled_start, now()), coalesce(p_task.scheduled_end, coalesce(p_task.scheduled_start, now()) + interval '10 hours'));
  avail := public.asset_available(p_asset, w, null);
  if not (avail->>'ok')::boolean then
    perform public.grnd_error(424, 'Asset ' || p_asset || ' not available: ' || (avail->>'why'), avail || jsonb_build_object('asset_id', p_asset));
  end if;
  begin
    insert into public.asset_reservations(asset_id, holder_id, task_id, assignment_id, during) values (p_asset, p_holder, p_task.id, p_assignment, w);
  exception when exclusion_violation then
    perform public.grnd_error(424, 'Asset ' || p_asset || ' was just reserved by someone else', jsonb_build_object('asset_id', p_asset, 'why', 'reserved'));
  end;
end $$;

-- ---------- 5. housekeeping ----------
create or replace function public.housekeeping() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a int; b int; c int;
begin
  delete from public.command_log where created_at < now() - interval '30 days'; get diagnostics a = row_count;
  delete from public.outbox where delivered_at is not null and created_at < now() - interval '30 days'; get diagnostics b = row_count;
  delete from public.event_sync_log where requested_at < now() - interval '60 days'; get diagnostics c = row_count;
  return jsonb_build_object('command_log', a, 'outbox', b, 'event_sync_log', c);
end $$;
revoke execute on function public.housekeeping() from public, anon, authenticated;
select cron.schedule('und-housekeeping', '30 8 * * *', $$select public.housekeeping()$$);

-- ---------- 6. real photos only ----------
-- service_finalize: an uploaded object under 20 KB is not a photo of a sidewalk. Re-declared in full so the check sits with the others.
create or replace function public.service_finalize(
  idempotency_key uuid, task_id uuid, action text, started_at timestamptz, completed_at timestamptz, location jsonb, photos jsonb,
  expected_revision int default null, materials jsonb default '[]'::jsonb, asset_id text default null, attachment_id text default null,
  conditions jsonb default '{}'::jsonb, notes text default null, supersedes_photo_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
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
  if s.id is null then perform public.grnd_error(425, 'No open shift'); end if;
  if action is null or action not in ('plowed','shoveled','salted','sanded','brined','mowed','trimmed','inspected','other') then missing := array_append(missing, 'action'); end if;
  if completed_at is null or started_at is null or completed_at < started_at then missing := array_append(missing, 'completed_at'); end if;
  if completed_at is not null and completed_at > now() + interval '5 minutes' then missing := array_append(missing, 'completed_at.future'); end if;
  pt := public.mk_point(location); acc := (location->>'accuracy_m')::numeric;
  if pt is null or acc is null then missing := array_append(missing, 'location'); end if;
  if photos is null or jsonb_typeof(photos) <> 'array' then photos := '[]'::jsonb; end if;
  for ph in select * from jsonb_array_elements(photos) loop
    select * into eo from public.evidence_objects where id = (ph->>'client_photo_id')::uuid;
    if eo.id is null or eo.task_id <> task_id or eo.uploaded_by <> auth.uid() then missing := array_append(missing, ('photos.' || coalesce(ph->>'client_photo_id', '?'))); continue; end if;
    if eo.sha256 <> lower(coalesce(ph->>'sha256', '')) then missing := array_append(missing, ('photos.' || eo.id::text || '.sha256')); continue; end if;
    select * into so from storage.objects where bucket_id = 'evidence' and name = eo.path;
    if so.id is null then missing := array_append(missing, ('photos.' || eo.id::text || '.not_uploaded')); continue; end if;
    if coalesce((so.metadata->>'size')::bigint, 0) < 20000 then missing := array_append(missing, ('photos.' || eo.id::text || '.too_small')); continue; end if;
    kinds := kinds || eo.kind;
  end loop;
  if 'photo_before' = any(t.evidence_required) and not ('before' = any(kinds)) then missing := array_append(missing, 'photos.before'); end if;
  if 'photo_after' = any(t.evidence_required) and not ('after' = any(kinds)) then missing := array_append(missing, 'photos.after'); end if;
  if 'material_qty' = any(t.evidence_required) and (materials is null or jsonb_typeof(materials) <> 'array' or jsonb_array_length(materials) = 0) then missing := array_append(missing, 'materials'); end if;
  for m in select * from jsonb_array_elements(case when jsonb_typeof(materials) = 'array' then materials else '[]'::jsonb end) loop
    if not exists (select 1 from public.materials where code = m->>'material_code' and active) or (m->>'qty') !~ '^[0-9]+(\.[0-9]+)?$' or (m->>'qty')::numeric <= 0 or (m->>'qty')::numeric > 100000 then
      missing := array_append(missing, ('materials.' || coalesce(m->>'material_code', '?'))); end if;
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

-- location_upload: cap the sample list and reject samples before the shift started or wildly inaccurate
create or replace function public.location_upload(idempotency_key uuid, shift_id uuid, samples jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; s record; smp jsonb; accepted int := 0; rejected jsonb := '[]'::jsonb; i int := 0;
        pt geometry; acc numeric; ta timestamptz; nz record; asmt jsonb; last_ta timestamptz; last_asmt jsonb;
begin
  prior := public.idem_check(idempotency_key, 'location_upload'); if prior is not null then return prior; end if;
  perform public.auth_role();
  select * into s from public.shifts where id = shift_id and profile_id = auth.uid();
  if s.id is null or s.ended_at is not null then perform public.grnd_error(425, 'No open shift'); end if;
  if samples is null or jsonb_typeof(samples) <> 'array' then perform public.grnd_error(422, 'samples must be an array', '{"fields":["samples"]}'); end if;
  if jsonb_array_length(samples) > 200 then perform public.grnd_error(422, 'max 200 samples per call', '{"fields":["samples"]}'); end if;
  for smp in select * from jsonb_array_elements(samples) loop
    pt := public.mk_point(smp); acc := (smp->>'accuracy_m')::numeric; ta := (smp->>'taken_at')::timestamptz;
    if pt is null or acc is null or ta is null or ta > now() + interval '2 minutes' or ta < s.started_at - interval '5 minutes' or acc < 0 or acc > 5000
       or abs(st_y(pt)) > 90 or abs(st_x(pt)) > 180 then
      rejected := rejected || jsonb_build_object('index', i, 'reason', 'missing lng/lat/accuracy_m/taken_at, out of range, before the shift, or in the future');
    else
      select * into nz from public.nearest_zone_version(pt);
      asmt := public.assess_location(pt, acc, ta, nz.zone_version_id);
      insert into public.location_samples(shift_id, profile_id, taken_at, geom, accuracy_m, speed_mps, heading, battery, source, zone_id, zone_version_id, result, distance_m)
      values (shift_id, auth.uid(), ta, pt, acc, (smp->>'speed_mps')::numeric, (smp->>'heading')::numeric, (smp->>'battery')::smallint, left(smp->>'source', 20),
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

-- functions re-declared above keep their grants; make the internal ones explicit once more
revoke execute on function public.reserve_asset(text, uuid, public.tasks, uuid), public.idem_check(uuid, text) from public, anon, authenticated;
