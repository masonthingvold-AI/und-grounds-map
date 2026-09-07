-- 0010 Mason's policy decisions of September 7, 2026 (see docs/api-contract.md v1.2 and docs/api-contract-changes.md)
-- 1. Certifications are an approval process with training outcomes; full-time employees get everything except CDL automatically; no admin override.
-- 2. Temp 2 may hand a task to a Temp 1 only in landscaping mode; every task records who was originally responsible.
-- 3. Oversight sees everything and may create, assign, reassign, and release work.
-- 4. Work orders can point at a ticket in another system.
-- 5. Ending a shift returns a day log; the worker confirms it into a time entry.

-- ---------- 1. capabilities with outcomes, requests, approvals, full-time defaults ----------
alter table public.capabilities
  add column outcomes jsonb not null default '[]'::jsonb,           -- ["Pre-start walkaround", "Attach and detach a bucket", ...]
  add column auto_for_full_time boolean not null default true;
update public.capabilities set auto_for_full_time = false where code = 'CDL';
update public.capabilities set outcomes = to_jsonb(array['Pre-start inspection and fluids', 'Safe start, stop, and parking', 'Operates on slopes and near people', 'Attachment change', 'Reports damage the same day']) where category = 'equipment' and outcomes = '[]'::jsonb;
update public.capabilities set outcomes = to_jsonb(array['PPE and guards', 'Safe handling and storage', 'Reports damage the same day']) where category = 'tool' and outcomes = '[]'::jsonb;
update public.capabilities set outcomes = to_jsonb(array['Current license or card on file']) where category = 'license' and outcomes = '[]'::jsonb;

create table public.certification_requests (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id),
  capability_id uuid not null references public.capabilities(id),
  requested_by uuid not null references public.profiles(id),
  outcomes_met jsonb not null default '[]'::jsonb,                 -- the outcomes the requester attests to
  notes text,
  status text not null default 'pending' check (status in ('pending','approved','denied','withdrawn')),
  decided_by uuid references public.profiles(id),
  decided_at timestamptz,
  decision_notes text,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
create index certification_requests_pending_idx on public.certification_requests(status, created_at) where status = 'pending';
alter table public.certification_requests enable row level security;
create policy cert_requests_read on public.certification_requests for select to authenticated using (profile_id = auth.uid() or public.can_see_profile(profile_id) or public.auth_role() in ('admin','oversight'));

alter table public.certifications add column request_id uuid references public.certification_requests(id);
alter table public.certifications add column source text not null default 'verified' check (source in ('verified','approved_request','full_time_default'));

-- a lead (own crew) or the person themselves asks; every outcome must be attested
create or replace function public.certification_request(idempotency_key uuid, profile_id uuid, capability_code text, outcomes_met jsonb default '[]'::jsonb, notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; r text; cap record; rid uuid; missing jsonb;
begin
  prior := public.idem_check(idempotency_key, 'certification_request'); if prior is not null then return prior; end if;
  r := public.auth_role();
  select * into cap from public.capabilities where code = capability_code and active;
  if cap.id is null then perform public.grnd_error(404, 'Unknown capability ' || capability_code); end if;
  if not (profile_id = auth.uid() or r in ('admin','oversight') or (r = 'lead' and public.can_see_profile(profile_id))) then
    perform public.grnd_error(403, 'You may not request that certification'); end if;
  if exists (select 1 from public.certification_requests q where q.profile_id = certification_request.profile_id and q.capability_id = cap.id and q.status = 'pending') then
    perform public.grnd_error(410, 'A request is already pending for ' || capability_code); end if;
  select coalesce(jsonb_agg(o), '[]'::jsonb) into missing from jsonb_array_elements(cap.outcomes) o where not (coalesce(outcomes_met, '[]'::jsonb) ? (o #>> '{}'));
  if jsonb_array_length(missing) > 0 then
    perform public.grnd_error(422, 'Every training outcome must be met before requesting', jsonb_build_object('fields', array['outcomes_met'], 'missing', missing)); end if;
  insert into public.certification_requests(profile_id, capability_id, requested_by, outcomes_met, notes)
  values (profile_id, cap.id, auth.uid(), coalesce(outcomes_met, '[]'::jsonb), notes) returning id into rid;
  perform public.notify('all', 'certification_requested', jsonb_build_object('request_id', rid, 'profile_id', profile_id, 'capability_code', capability_code, 'message', 'Certification request: ' || capability_code));
  return public.idem_store(idempotency_key, 'certification_request',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('request_id', rid, 'status', 'pending', 'capability_code', capability_code), 'replayed', false));
end $$;

-- admin decides; approval creates or refreshes the certification
create or replace function public.certification_decide(idempotency_key uuid, request_id uuid, approve boolean, decision_notes text default null, expires_at timestamptz default null, restrictions text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; q record; cert_id uuid; code text;
begin
  prior := public.idem_check(idempotency_key, 'certification_decide'); if prior is not null then return prior; end if;
  if not public.is_admin() then perform public.grnd_error(403, 'Only admins approve certifications'); end if;
  select * into q from public.certification_requests where id = request_id for update;
  if q.id is null then perform public.grnd_error(404, 'Request not found'); end if;
  if q.status <> 'pending' then perform public.grnd_error(410, 'Request already ' || q.status); end if;
  update public.certification_requests set status = case when approve then 'approved' else 'denied' end, decided_by = auth.uid(), decided_at = now(),
         decision_notes = certification_decide.decision_notes, expires_at = certification_decide.expires_at where id = request_id;
  select c.code into code from public.capabilities c where c.id = q.capability_id;
  if approve then
    insert into public.certifications(profile_id, capability_id, verified_by, verified_at, expires_at, suspended, restrictions, notes, request_id, source)
    values (q.profile_id, q.capability_id, auth.uid(), now(), expires_at, false, restrictions, decision_notes, request_id, 'approved_request')
    on conflict on constraint certifications_profile_id_capability_id_key do update
      set verified_by = excluded.verified_by, verified_at = now(), expires_at = excluded.expires_at, suspended = false, restrictions = excluded.restrictions,
          notes = excluded.notes, request_id = excluded.request_id, source = 'approved_request'
    returning id into cert_id;
  end if;
  perform public.notify('person:' || q.profile_id::text, case when approve then 'certification_approved' else 'certification_denied' end,
    jsonb_build_object('request_id', request_id, 'capability_code', code, 'message', code || case when approve then ' approved' else ' denied' end || coalesce(': ' || decision_notes, '')));
  return public.idem_store(idempotency_key, 'certification_decide',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('request_id', request_id, 'status', case when approve then 'approved' else 'denied' end, 'certification_id', cert_id, 'capability_code', code), 'replayed', false));
end $$;

-- full-time employees hold every auto capability from the day their profile exists (everything except CDL)
create or replace function public.grant_full_time_defaults(p uuid) returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into public.certifications(profile_id, capability_id, verified_by, verified_at, source, notes)
  select p, c.id, null, now(), 'full_time_default', 'Full-time default'
  from public.capabilities c where c.active and c.auto_for_full_time
  on conflict on constraint certifications_profile_id_capability_id_key do nothing;
  get diagnostics n = row_count; return n;
end $$;
create or replace function public.profiles_full_time_defaults() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.employment_tier = 'full_time' and (tg_op = 'INSERT' or old.employment_tier is distinct from 'full_time') then perform public.grant_full_time_defaults(new.id); end if;
  return new;
end $$;
create trigger profiles_full_time_defaults after insert or update of employment_tier on public.profiles for each row execute function public.profiles_full_time_defaults();
select public.grant_full_time_defaults(id) from public.profiles where employment_tier = 'full_time';

create view public.v_certification_requests with (security_invoker = true) as
select q.id as request_id, q.profile_id, p.full_name, c.code as capability_code, c.name as capability_name, c.outcomes as outcomes_required, q.outcomes_met,
       rb.full_name as requested_by_name, q.notes, q.status, db.full_name as decided_by_name, q.decided_at, q.decision_notes, q.expires_at, q.created_at
from public.certification_requests q join public.profiles p on p.id = q.profile_id join public.capabilities c on c.id = q.capability_id
left join public.profiles rb on rb.id = q.requested_by left join public.profiles db on db.id = q.decided_by;

create or replace view public.v_capabilities with (security_invoker = true) as
select id, code, name, category, granted_by_tier, required_for_asset_classes, active, outcomes, auto_for_full_time from public.capabilities;

grant select on public.certification_requests, public.v_certification_requests to authenticated;
grant execute on function public.certification_request(uuid, uuid, text, jsonb, text), public.certification_decide(uuid, uuid, boolean, text, timestamptz, text) to authenticated;
revoke execute on function public.grant_full_time_defaults(uuid) from anon, authenticated;

-- ---------- 3. oversight may direct work ----------
create or replace function public.can_direct(target uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare r text;
begin
  select app_role into r from public.profiles where id = auth.uid() and active;
  if r in ('admin','oversight') then return true; end if;
  if r = 'lead' then return public.can_see_profile(target); end if;
  return false;
end $$;

-- ---------- 2 and 4. original responsibility, handoff rules, external work order refs ----------
alter table public.tasks add column original_assignee_id uuid references public.profiles(id);
update public.tasks t set original_assignee_id = (select a.profile_id from public.assignments a where a.task_id = t.id order by a.assigned_at limit 1) where original_assignee_id is null;
alter table public.work_orders add column external_system text, add column external_ref text, add column external_url text;
create index work_orders_external_idx on public.work_orders(external_system, external_ref);

create or replace function public.work_order_link_external(idempotency_key uuid, work_order_id uuid, external_system text, external_ref text, external_url text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; r text; n int;
begin
  prior := public.idem_check(idempotency_key, 'work_order_link_external'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','oversight','lead') then perform public.grnd_error(403, 'Only leads and admins link work orders'); end if;
  if external_ref is null or length(trim(external_ref)) = 0 then perform public.grnd_error(422, 'external_ref is required', '{"fields":["external_ref"]}'); end if;
  update public.work_orders set external_system = work_order_link_external.external_system, external_ref = work_order_link_external.external_ref, external_url = work_order_link_external.external_url
   where id = work_order_id; get diagnostics n = row_count;
  if n = 0 then perform public.grnd_error(404, 'Work order not found'); end if;
  return public.idem_store(idempotency_key, 'work_order_link_external',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('work_order_id', work_order_id, 'external_system', external_system, 'external_ref', external_ref), 'replayed', false));
end $$;

-- task_create: oversight allowed; optional external work order reference
drop function public.task_create(uuid, text, text, text, uuid, uuid, text, smallint, text[], text, timestamptz, timestamptz, text[], jsonb);
create or replace function public.task_create(
  idempotency_key uuid, zone_id text, task_type text, outcome text,
  work_order_id uuid default null, zone_version_id uuid default null, description text default null, priority smallint default 2,
  required_capabilities text[] default null, required_asset_class text default null,
  scheduled_start timestamptz default null, scheduled_end timestamptz default null,
  evidence_required text[] default null, point jsonb default null, external_ref jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; r text; z record; zv uuid; wo record; t public.tasks; ko text; my_crew uuid;
begin
  prior := public.idem_check(idempotency_key, 'task_create'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','oversight','lead') then perform public.grnd_error(403, 'Only admins, oversight, and leads create tasks'); end if;
  if outcome is null or length(trim(outcome)) < 3 then perform public.grnd_error(422, 'outcome is required', '{"fields":["outcome"]}'); end if;
  select * into z from public.zones where id = zone_id and active;
  if z.id is null then perform public.grnd_error(404, 'Zone not found', jsonb_build_object('zone_id', zone_id)); end if;
  if r = 'lead' and z.responsible_crew_id is not null and not (z.responsible_crew_id = any(public.my_crew_ids())) then
    perform public.grnd_error(403, 'That zone belongs to another crew'); end if;
  zv := coalesce(task_create.zone_version_id, z.current_version_id);
  if zv is null then perform public.grnd_error(422, 'Zone has no geometry version yet', jsonb_build_object('zone_id', zone_id)); end if;
  ko := public.keepout_active_for_zone(zone_id);
  if ko is not null and task_type not in ('inspect','project','other') then
    perform public.grnd_error(426, 'Keep-out active on ' || zone_id || ' (' || ko || ')', jsonb_build_object('zone_id', zone_id, 'keepout', ko)); end if;
  if work_order_id is null then
    insert into public.work_orders(season, title, description, source, priority, created_by, external_system, external_ref, external_url)
    values (z.season, left(outcome, 120), description, 'app', priority, auth.uid(), external_ref->>'system', external_ref->>'ref', external_ref->>'url') returning * into wo;
  else
    select * into wo from public.work_orders where id = work_order_id;
    if wo.id is null then perform public.grnd_error(404, 'Work order not found'); end if;
    if external_ref is not null then
      update public.work_orders set external_system = coalesce(external_ref->>'system', external_system), external_ref = coalesce(external_ref->>'ref', wo.external_ref), external_url = coalesce(external_ref->>'url', external_url) where id = wo.id returning * into wo;
    end if;
  end if;
  select crew_id into my_crew from public.profiles where id = auth.uid();
  insert into public.tasks(work_order_id, zone_id, zone_version_id, point, task_type, outcome, description, required_capabilities,
                           required_asset_class, priority, scheduled_start, scheduled_end, evidence_required, created_by, crew_id)
  values (wo.id, zone_id, zv, public.mk_point(point), task_type, outcome, description, coalesce(required_capabilities, '{}'),
          required_asset_class, priority, scheduled_start, scheduled_end, coalesce(evidence_required, public.default_evidence(task_type)), auth.uid(),
          coalesce(z.responsible_crew_id, my_crew))
  returning * into t;
  perform public.notify('crew:' || coalesce(t.crew_id::text, 'none'), 'task_created', jsonb_build_object('task_id', t.id, 'zone_id', zone_id, 'revision', t.revision));
  return public.idem_store(idempotency_key, 'task_create', public.task_result(t, jsonb_build_object('work_order_number', wo.number, 'work_order_id', wo.id, 'external_ref', wo.external_ref)));
end $$;

-- task_assign: no override; original assignee recorded
create or replace function public.task_assign(
  idempotency_key uuid, task_id uuid, profile_id uuid, expected_revision int default null,
  asset_id text default null, attachment_id text default null, note text default null, override_qualification boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; r text; t public.tasks; target record; missing text[]; a public.assignments; assigner text;
begin
  prior := public.idem_check(idempotency_key, 'task_assign'); if prior is not null then return prior; end if;
  r := public.auth_role();
  t := public.load_task(task_id);
  perform public.check_revision(t, expected_revision);
  if t.state not in ('unassigned') then perform public.grnd_error(410, 'Task is ' || t.state || ', use reassign', jsonb_build_object('state', t.state)); end if;
  if not public.can_direct(profile_id) then perform public.grnd_error(403, 'You may not assign work to that person'); end if;
  select * into target from public.profiles where id = profile_id and active;
  if target.id is null then perform public.grnd_error(404, 'Person not found'); end if;
  missing := public.missing_capabilities(profile_id, t.required_capabilities);
  if array_length(missing, 1) > 0 then
    perform public.grnd_error(423, target.full_name || ' is not certified for ' || array_to_string(missing, ', ') || '. Request the certification first.',
      jsonb_build_object('missing', to_jsonb(missing), 'profile_id', profile_id, 'task_id', task_id)); end if;
  insert into public.assignments(task_id, profile_id, asset_id, attachment_id, assigned_by, note)
  values (task_id, profile_id, asset_id, attachment_id, auth.uid(), note) returning * into a;
  perform public.reserve_asset(asset_id, profile_id, t, a.id);
  perform public.reserve_asset(attachment_id, profile_id, t, a.id);
  update public.tasks set state = 'assigned', assignee_id = profile_id, current_assignment_id = a.id, revision = revision + 1,
         crew_id = coalesce(target.crew_id, crew_id), original_assignee_id = coalesce(original_assignee_id, profile_id)
   where id = task_id returning * into t;
  update public.work_orders set status = 'in_progress' where id = t.work_order_id and status = 'open';
  select full_name into assigner from public.profiles where id = auth.uid();
  perform public.notify('person:' || profile_id::text, 'assigned', jsonb_build_object('task_id', t.id, 'assignment_id', a.id, 'from_name', assigner, 'message', t.zone_id || ': ' || t.outcome, 'revision', t.revision));
  return public.idem_store(idempotency_key, 'task_assign', public.task_result(t, jsonb_build_object('assignment_id', a.id, 'notified', true)));
end $$;

-- assignment_reassign: no override; Temp 2 to Temp 1 only in landscaping mode; original responsibility kept
create or replace function public.assignment_reassign(
  idempotency_key uuid, task_id uuid, to_profile_id uuid, expected_revision int default null, reason text default null,
  keep_asset boolean default true, asset_id text default null, attachment_id text default null, override_qualification boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; r text; t public.tasks; old_a public.assignments; new_a public.assignments; target record; missing text[];
        me record; prev_name text; use_asset text; use_att text; mode_ text;
begin
  prior := public.idem_check(idempotency_key, 'assignment_reassign'); if prior is not null then return prior; end if;
  r := public.auth_role();
  t := public.load_task(task_id);
  perform public.check_revision(t, expected_revision);
  if t.state not in ('assigned','accepted','in_progress') then perform public.grnd_error(410, 'Task is ' || t.state, jsonb_build_object('state', t.state)); end if;
  select * into old_a from public.assignments where id = t.current_assignment_id for update;
  select * into target from public.profiles where id = to_profile_id and active;
  if target.id is null then perform public.grnd_error(404, 'Person not found'); end if;
  select * into me from public.profiles where id = auth.uid();
  select mode into mode_ from public.operating_state;
  if public.can_direct(to_profile_id) then null;
  elsif r = 'worker' and me.employment_tier = 'temp2' and old_a.profile_id = auth.uid() and target.employment_tier = 'temp1' and target.crew_id = me.crew_id then
    if mode_ <> 'landscaping' then perform public.grnd_error(403, 'Temp 2 handoffs are only allowed in landscaping season; ask your lead'); end if;
  else perform public.grnd_error(403, 'You may not reassign to that person'); end if;
  missing := public.missing_capabilities(to_profile_id, t.required_capabilities);
  if array_length(missing, 1) > 0 then
    perform public.grnd_error(423, target.full_name || ' is not certified for ' || array_to_string(missing, ', ') || '. Request the certification first.',
      jsonb_build_object('missing', to_jsonb(missing), 'profile_id', to_profile_id, 'task_id', task_id)); end if;
  update public.assignments set released_at = now(), release_reason = coalesce(reason, 'reassigned') where id = old_a.id returning * into old_a;
  perform public.release_assets(task_id, old_a.id);
  use_asset := coalesce(asset_id, case when keep_asset then old_a.asset_id end);
  use_att := coalesce(attachment_id, case when keep_asset then old_a.attachment_id end);
  insert into public.assignments(task_id, profile_id, asset_id, attachment_id, assigned_by, reassigned_from, note)
  values (task_id, to_profile_id, use_asset, use_att, auth.uid(), old_a.id, reason) returning * into new_a;
  perform public.reserve_asset(use_asset, to_profile_id, t, new_a.id);
  perform public.reserve_asset(use_att, to_profile_id, t, new_a.id);
  update public.tasks set state = 'assigned', assignee_id = to_profile_id, current_assignment_id = new_a.id, revision = revision + 1,
         crew_id = coalesce(target.crew_id, crew_id), started_at = null, original_assignee_id = coalesce(original_assignee_id, old_a.profile_id)
   where id = task_id returning * into t;
  select full_name into prev_name from public.profiles where id = old_a.profile_id;
  perform public.notify('person:' || old_a.profile_id::text, 'reassigned_away', jsonb_build_object('task_id', t.id, 'assignment_id', old_a.id, 'from_name', me.full_name,
    'message', t.zone_id || ' reassigned to ' || target.full_name || coalesce(' (' || reason || ')', ''), 'revision', t.revision));
  perform public.notify('person:' || to_profile_id::text, 'reassigned_to_you', jsonb_build_object('task_id', t.id, 'assignment_id', new_a.id, 'from_name', me.full_name,
    'message', t.zone_id || ': ' || t.outcome || coalesce(' (' || reason || ')', ''), 'revision', t.revision));
  return public.idem_store(idempotency_key, 'assignment_reassign', public.task_result(t,
    jsonb_build_object('assignment_id', new_a.id, 'released_assignment_id', old_a.id, 'previous_assignee_name', prev_name, 'original_assignee_id', t.original_assignee_id)));
end $$;

-- names of people on a task are visible to anyone who can see the task, even if they cannot see the profile row
create or replace function public.profile_name(p uuid) returns text language sql stable security definer set search_path = public as $$
  select full_name from public.profiles where id = p
$$;
grant execute on function public.profile_name(uuid) to authenticated;

-- ---------- views: original assignee, handoff chain, external refs ----------
drop view public.v_dispatch_board; drop view public.v_my_day; drop view public.v_task_detail;
create view public.v_task_detail with (security_invoker = true) as
select t.id as task_id, t.revision as task_revision, a.id as assignment_id,
       t.task_type, t.outcome, t.description, t.priority, t.state, t.blocked_reason,
       t.zone_id, z.name as zone_name, t.zone_version_id, z.class as zone_class,
       st_asgeojson(zv.geom)::jsonb as zone_geom, st_asgeojson(st_centroid(zv.geom))::jsonb as zone_center, st_asgeojson(t.point)::jsonb as point,
       z.site, wo.season,
       t.scheduled_start, t.scheduled_end, t.started_at, t.finalized_at, t.approved_at,
       public.profile_name(a.assigned_by) as assigned_by_name, a.assigned_at, a.acknowledged_at,
       t.assignee_id, public.profile_name(t.assignee_id) as assignee_name,
       t.original_assignee_id, public.profile_name(t.original_assignee_id) as original_assignee_name,
       a.asset_id, ast.name as asset_name, a.attachment_id, att.name as attachment_name,
       t.required_capabilities,
       case when t.assignee_id is null then '{}'::text[] else public.missing_capabilities(t.assignee_id, t.required_capabilities) end as missing_capabilities,
       t.evidence_required,
       (public.keepout_active_for_zone(t.zone_id) is not null) as keepout_active, public.keepout_active_for_zone(t.zone_id) as keepout_reason,
       wo.number as work_order_number, wo.title as work_order_title, t.work_order_id, wo.external_system, wo.external_ref, wo.external_url,
       t.crew_id, public.profile_name(t.created_by) as created_by_name, t.created_at, t.updated_at,
       (select coalesce(jsonb_agg(jsonb_build_object('assignment_id', h.id, 'profile_id', h.profile_id, 'profile_name', public.profile_name(h.profile_id), 'assigned_by_name', public.profile_name(h.assigned_by), 'assigned_at', h.assigned_at,
               'acknowledged_at', h.acknowledged_at, 'released_at', h.released_at, 'release_reason', h.release_reason, 'reassigned_from', h.reassigned_from) order by h.assigned_at), '[]'::jsonb)
          from public.assignments h where h.task_id = t.id) as assignment_history,
       case t.state when 'in_progress' then 0 when 'accepted' then 10 when 'assigned' then 20 when 'blocked' then 30 when 'review' then 40 else 50 end * 10 + t.priority as sort_key
from public.tasks t
join public.work_orders wo on wo.id = t.work_order_id
join public.zones z on z.id = t.zone_id
join public.zone_versions zv on zv.id = t.zone_version_id
left join public.assignments a on a.id = t.current_assignment_id
left join public.assets ast on ast.id = a.asset_id
left join public.assets att on att.id = a.attachment_id;

create view public.v_my_day with (security_invoker = true) as
select * from public.v_task_detail
where assignee_id = auth.uid() and state in ('assigned','accepted','in_progress','blocked','review')
order by sort_key, scheduled_start nulls last;

create view public.v_dispatch_board with (security_invoker = true) as
select d.task_id, d.task_revision, d.work_order_number, d.work_order_title, d.external_system, d.external_ref, d.external_url, d.task_type, d.outcome, d.priority, d.state, d.season,
       d.zone_id, d.zone_name, d.zone_class, d.zone_center, d.site, d.scheduled_start, d.scheduled_end,
       (d.scheduled_end is not null and d.scheduled_end < now() and d.state not in ('review','done','canceled')) as overdue,
       d.assignee_id, d.assignee_name, d.original_assignee_id, d.original_assignee_name,
       exists (select 1 from public.shifts s where s.profile_id = d.assignee_id and s.ended_at is null) as assignee_on_shift,
       (d.acknowledged_at is not null) as acknowledged, d.assigned_at,
       d.asset_id, d.asset_name, d.required_capabilities,
       (select count(*) from public.profiles p join public.shifts s on s.profile_id = p.id and s.ended_at is null
         where p.active and p.app_role in ('worker','lead') and public.missing_capabilities(p.id, d.required_capabilities) = '{}'
           and not exists (select 1 from public.tasks x where x.assignee_id = p.id and x.state = 'in_progress'))::int as qualified_available_count,
       d.blocked_reason, d.keepout_active, d.crew_id, d.updated_at as last_activity_at, d.sort_key
from public.v_task_detail d
where d.state not in ('done','canceled');
grant select on public.v_task_detail, public.v_my_day, public.v_dispatch_board to authenticated;

-- ---------- 5. day log and confirmed time entries (ADR 12: confirmed, not inferred) ----------
create table public.time_entries (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id),
  shift_id uuid not null references public.shifts(id),
  work_order_id uuid references public.work_orders(id),
  task_id uuid references public.tasks(id),
  zone_id text references public.zones(id),
  external_ref text,
  minutes int not null check (minutes >= 0),
  suggested_minutes int,
  note text,
  confirmed_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index time_entries_profile_idx on public.time_entries(profile_id, confirmed_at desc);
alter table public.time_entries enable row level security;
create policy time_entries_read on public.time_entries for select to authenticated using (profile_id = auth.uid() or public.can_see_profile(profile_id));

-- what a person did during a shift: one line per task worked, plus minutes per zone from GPS
create or replace function public.day_log(shift_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s record; tasks_ jsonb; zones_ jsonb; total int;
begin
  perform public.auth_role();
  select * into s from public.shifts where id = shift_id;
  if s.id is null then perform public.grnd_error(404, 'Shift not found'); end if;
  if s.profile_id <> auth.uid() and not public.can_see_profile(s.profile_id) then perform public.grnd_error(403, 'Not your shift'); end if;
  select coalesce(jsonb_agg(row_to_json(x) order by x.started_at), '[]'::jsonb) into tasks_ from (
    select t.id as task_id, wo.id as work_order_id, wo.number as work_order_number, wo.title as work_order_title, wo.external_system, wo.external_ref, wo.external_url,
           t.zone_id, z.name as zone_name, t.task_type, t.state,
           greatest(t.started_at, s.started_at) as started_at, least(coalesce(t.finalized_at, s.ended_at, now()), coalesce(s.ended_at, now())) as ended_at,
           greatest(0, round(extract(epoch from (least(coalesce(t.finalized_at, s.ended_at, now()), coalesce(s.ended_at, now())) - greatest(t.started_at, s.started_at))) / 60))::int as suggested_minutes
    from public.tasks t join public.work_orders wo on wo.id = t.work_order_id join public.zones z on z.id = t.zone_id
    where t.started_at is not null and t.started_at <= coalesce(s.ended_at, now()) and coalesce(t.finalized_at, now()) >= s.started_at
      and exists (select 1 from public.assignments a where a.task_id = t.id and a.profile_id = s.profile_id)
  ) x;
  select coalesce(jsonb_agg(row_to_json(y) order by y.minutes desc), '[]'::jsonb) into zones_ from (
    select g.zone_id, z.name as zone_name, count(*)::int as samples, coalesce(round(sum(g.gap_s) / 60), 0)::int as minutes
    from (select l.zone_id, least(coalesce(extract(epoch from (l.taken_at - lag(l.taken_at) over (order by l.taken_at))), 0), 300) as gap_s
          from public.location_samples l where l.shift_id = day_log.shift_id) g
    left join public.zones z on z.id = g.zone_id
    where g.zone_id is not null group by g.zone_id, z.name
  ) y;
  total := round(extract(epoch from (coalesce(s.ended_at, now()) - s.started_at)) / 60);
  return jsonb_build_object('shift_id', s.id, 'started_at', s.started_at, 'ended_at', s.ended_at, 'shift_minutes', total, 'tasks', tasks_, 'zones', zones_,
    'confirmed', (select coalesce(jsonb_agg(jsonb_build_object('work_order_number', w.number, 'minutes', e.minutes)), '[]'::jsonb) from public.time_entries e left join public.work_orders w on w.id = e.work_order_id where e.shift_id = s.id));
end $$;

-- the worker confirms the log into time entries (edits allowed; suggested minutes kept for comparison)
create or replace function public.time_entries_confirm(idempotency_key uuid, shift_id uuid, entries jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; s record; e jsonb; n int := 0; total int := 0; wo uuid;
begin
  prior := public.idem_check(idempotency_key, 'time_entries_confirm'); if prior is not null then return prior; end if;
  perform public.auth_role();
  select * into s from public.shifts where id = shift_id;
  if s.id is null then perform public.grnd_error(404, 'Shift not found'); end if;
  if s.profile_id <> auth.uid() and not (public.auth_role() in ('admin','lead') and public.can_see_profile(s.profile_id)) then perform public.grnd_error(403, 'Not your shift'); end if;
  if entries is null or jsonb_typeof(entries) <> 'array' or jsonb_array_length(entries) = 0 then perform public.grnd_error(422, 'entries must be a non-empty array', '{"fields":["entries"]}'); end if;
  if exists (select 1 from public.time_entries where time_entries.shift_id = time_entries_confirm.shift_id) then perform public.grnd_error(410, 'Time already confirmed for this shift'); end if;
  for e in select * from jsonb_array_elements(entries) loop
    wo := (e->>'work_order_id')::uuid;
    if wo is null and (e->>'task_id') is not null then select work_order_id into wo from public.tasks where id = (e->>'task_id')::uuid; end if;
    insert into public.time_entries(profile_id, shift_id, work_order_id, task_id, zone_id, external_ref, minutes, suggested_minutes, note)
    values (s.profile_id, shift_id, wo, (e->>'task_id')::uuid, e->>'zone_id', e->>'external_ref', (e->>'minutes')::int, (e->>'suggested_minutes')::int, e->>'note');
    n := n + 1; total := total + (e->>'minutes')::int;
  end loop;
  return public.idem_store(idempotency_key, 'time_entries_confirm',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('shift_id', shift_id, 'entries', n, 'minutes', total), 'replayed', false));
end $$;

-- shift_end now returns the day log
create or replace function public.shift_end(idempotency_key uuid, shift_id uuid, location jsonb default null, note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prior jsonb; s record; open_tasks uuid[];
begin
  prior := public.idem_check(idempotency_key, 'shift_end'); if prior is not null then return prior; end if;
  perform public.auth_role();
  select * into s from public.shifts where id = shift_id;
  if s.id is null then perform public.grnd_error(404, 'Shift not found'); end if;
  if s.profile_id <> auth.uid() then perform public.grnd_error(403, 'Not your shift'); end if;
  if s.ended_at is not null then perform public.grnd_error(410, 'Shift already ended', jsonb_build_object('ended_at', s.ended_at)); end if;
  update public.shifts set ended_at = now(), end_point = public.mk_point(location), note = shift_end.note, ended_by = auth.uid()
   where id = shift_id returning * into s;
  open_tasks := public.open_task_ids_for(auth.uid());
  return public.idem_store(idempotency_key, 'shift_end',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('shift_id', s.id, 'started_at', s.started_at, 'ended_at', s.ended_at,
      'duration_minutes', round(extract(epoch from (s.ended_at - s.started_at)) / 60), 'open_task_ids', to_jsonb(open_tasks), 'day_log', public.day_log(s.id)), 'replayed', false));
end $$;

create view public.v_time_entries with (security_invoker = true) as
select e.id, e.profile_id, p.full_name, e.shift_id, e.work_order_id, w.number as work_order_number, w.external_system, w.external_ref, e.task_id, e.zone_id, e.minutes, e.suggested_minutes, e.note, e.confirmed_at
from public.time_entries e join public.profiles p on p.id = e.profile_id left join public.work_orders w on w.id = e.work_order_id;

grant select on public.time_entries, public.v_time_entries to authenticated;
grant execute on function public.day_log(uuid), public.time_entries_confirm(uuid, uuid, jsonb), public.work_order_link_external(uuid, uuid, text, text, text),
  public.task_create(uuid, text, text, text, uuid, uuid, text, smallint, text[], text, timestamptz, timestamptz, text[], jsonb, jsonb) to authenticated;
