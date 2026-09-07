-- 0006 Work orders, tasks, assignments, outbox, dispatch. docs/api-contract.md section 6 and views in section 3.

create sequence public.work_order_seq;

create table public.work_orders (
  id uuid primary key default gen_random_uuid(),
  number text not null unique default ('WO-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.work_order_seq')::text, 4, '0')),
  season text not null default 'either' check (season in ('landscaping','snow','either')),
  title text not null,
  description text,
  source text,                                  -- email, phone, walk-in, weather, inspection, app
  requested_by text,
  priority smallint not null default 2 check (priority between 1 and 3),
  status text not null default 'open' check (status in ('open','in_progress','blocked','done','canceled')),
  created_by uuid references public.profiles(id),
  event_id uuid,                                -- fk to weather_events added in 0008
  due_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger work_orders_touch before update on public.work_orders for each row execute function public.touch_updated_at();

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  revision int not null default 1,
  work_order_id uuid not null references public.work_orders(id),
  zone_id text not null references public.zones(id),
  zone_version_id uuid not null references public.zone_versions(id),
  point geometry(Point, 4326),
  task_type text not null,                      -- mow, trim, bed_check, tree_inspect, plow, shovel, salt, sand, brine, haul, inspect, project, other
  outcome text not null,
  description text,
  required_capabilities text[] not null default '{}',
  required_asset_class text,
  priority smallint not null default 2 check (priority between 1 and 3),
  state text not null default 'unassigned' check (state in ('unassigned','assigned','accepted','in_progress','blocked','review','done','canceled')),
  state_before_block text,
  blocked_reason text,
  crew_id uuid references public.crews(id),
  assignee_id uuid references public.profiles(id),
  current_assignment_id uuid,
  scheduled_start timestamptz, scheduled_end timestamptz,
  started_at timestamptz, finalized_at timestamptz, approved_at timestamptz,
  evidence_required text[] not null default '{}',
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index tasks_assignee_idx on public.tasks(assignee_id) where state not in ('done','canceled');
create index tasks_state_idx on public.tasks(state);
create index tasks_crew_idx on public.tasks(crew_id);
create trigger tasks_touch before update on public.tasks for each row execute function public.touch_updated_at();

create table public.assignments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id),
  profile_id uuid not null references public.profiles(id),
  asset_id text references public.assets(id),
  attachment_id text references public.assets(id),
  assigned_by uuid not null references public.profiles(id),
  assigned_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  released_at timestamptz,
  release_reason text,
  reassigned_from uuid references public.assignments(id),
  qualification_override boolean not null default false,
  note text
);
create index assignments_task_idx on public.assignments(task_id);
create index assignments_profile_open_idx on public.assignments(profile_id) where released_at is null;
alter table public.tasks add constraint tasks_current_assignment_fk foreign key (current_assignment_id) references public.assignments(id);
alter table public.asset_reservations add constraint reservations_task_fk foreign key (task_id) references public.tasks(id);
alter table public.asset_reservations add constraint reservations_assignment_fk foreign key (assignment_id) references public.assignments(id);

-- outbox: every notification comes from a committed change (section 10). 0009 wires it to Realtime.
create table public.outbox (
  id bigint generated always as identity primary key,
  topic text not null,                          -- person:<uuid>, crew:<uuid>, all
  event_type text not null,
  payload jsonb not null,
  created_at timestamptz not null default now(),
  delivered_at timestamptz
);

create or replace function public.notify(topic text, event_type text, payload jsonb) returns void
language sql security definer set search_path = public, extensions as $$
  insert into public.outbox(topic, event_type, payload) values (topic, event_type, payload || jsonb_build_object('type', event_type, 'at', now()))
$$;

-- ---------- helpers ----------
create or replace function public.default_evidence(task_type text) returns text[] language sql immutable as $$
  select case
    when task_type in ('plow','shovel','salt','sand','brine') then array['photo_before','photo_after','material_qty','location']
    when task_type in ('mow','trim') then array['photo_after','location']
    when task_type in ('inspect','bed_check','tree_inspect') then array['photo_after','location']
    else array['location'] end
$$;

-- who may see a task: admin/oversight all; lead: crew tasks; worker: own
create or replace function public.can_see_task(t public.tasks) returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
declare r text;
begin
  select app_role into r from public.profiles where id = auth.uid() and active;
  if r in ('admin','oversight') then return true; end if;
  if t.assignee_id = auth.uid() or t.created_by = auth.uid() then return true; end if;
  if r = 'lead' then
    return t.crew_id = any(public.my_crew_ids())
        or exists (select 1 from public.zones z where z.id = t.zone_id and z.responsible_crew_id = any(public.my_crew_ids()))
        or (t.assignee_id is not null and public.can_see_profile(t.assignee_id));
  end if;
  return false;
end $$;

-- may the caller assign work to this person
create or replace function public.can_direct(target uuid) returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
declare r text;
begin
  select app_role into r from public.profiles where id = auth.uid() and active;
  if r = 'admin' then return true; end if;
  if r = 'lead' then return public.can_see_profile(target); end if;
  return false;
end $$;

create or replace function public.check_revision(t public.tasks, expected int) returns void language plpgsql as $$
begin
  if expected is not null and expected <> t.revision then
    perform public.grnd_error(409, 'Task changed since you loaded it', jsonb_build_object('task_id', t.id, 'revision', t.revision, 'expected_revision', expected, 'state', t.state));
  end if;
end $$;

create or replace function public.load_task(tid uuid) returns public.tasks language plpgsql security definer set search_path = public, extensions as $$
declare t public.tasks;
begin
  select * into t from public.tasks where id = tid for update;
  if t is null then perform public.grnd_error(404, 'Task not found', jsonb_build_object('task_id', tid)); end if;
  return t;
end $$;

create or replace function public.open_task_ids_for(p uuid) returns uuid[] language sql stable security definer set search_path = public, extensions as $$
  select coalesce(array_agg(id), '{}') from public.tasks where assignee_id = p and state in ('assigned','accepted','in_progress','blocked')
$$;

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
  insert into public.asset_reservations(asset_id, holder_id, task_id, assignment_id, during) values (p_asset, p_holder, p_task.id, p_assignment, w);
end $$;

create or replace function public.release_assets(p_task uuid, p_assignment uuid) returns void
language sql security definer set search_path = public, extensions as $$
  update public.asset_reservations set released_at = now() where task_id = p_task and (p_assignment is null or assignment_id = p_assignment) and released_at is null
$$;

create or replace function public.task_result(t public.tasks, extra jsonb default '{}'::jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object('ok', true, 'data', jsonb_build_object('task_id', t.id, 'revision', t.revision, 'state', t.state) || extra, 'revision', t.revision, 'replayed', false)
$$;

-- ---------- task_create ----------
create or replace function public.task_create(
  idempotency_key uuid, zone_id text, task_type text, outcome text,
  work_order_id uuid default null, zone_version_id uuid default null, description text default null, priority smallint default 2,
  required_capabilities text[] default null, required_asset_class text default null,
  scheduled_start timestamptz default null, scheduled_end timestamptz default null,
  evidence_required text[] default null, point jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; z record; zv uuid; wo record; t public.tasks; ko text; my_crew uuid;
begin
  prior := public.idem_check(idempotency_key, 'task_create'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','lead') then perform public.grnd_error(403, 'Only admins and leads create tasks'); end if;
  if outcome is null or length(trim(outcome)) < 3 then perform public.grnd_error(422, 'outcome is required', '{"fields":["outcome"]}'); end if;
  select * into z from public.zones where id = zone_id and active;
  if z is null then perform public.grnd_error(404, 'Zone not found', jsonb_build_object('zone_id', zone_id)); end if;
  if r = 'lead' and z.responsible_crew_id is not null and not (z.responsible_crew_id = any(public.my_crew_ids())) then
    perform public.grnd_error(403, 'That zone belongs to another crew'); end if;
  zv := coalesce(task_create.zone_version_id, z.current_version_id);
  if zv is null then perform public.grnd_error(422, 'Zone has no geometry version yet', jsonb_build_object('zone_id', zone_id)); end if;
  ko := public.keepout_active_for_zone(zone_id);
  if ko is not null and task_type not in ('inspect','project','other') then
    perform public.grnd_error(426, 'Keep-out active on ' || zone_id || ' (' || ko || ')', jsonb_build_object('zone_id', zone_id, 'keepout', ko)); end if;
  if work_order_id is null then
    insert into public.work_orders(season, title, description, source, priority, created_by)
    values (z.season, left(outcome, 120), description, 'app', priority, auth.uid()) returning * into wo;
  else
    select * into wo from public.work_orders where id = work_order_id;
    if wo is null then perform public.grnd_error(404, 'Work order not found'); end if;
  end if;
  select crew_id into my_crew from public.profiles where id = auth.uid();
  insert into public.tasks(work_order_id, zone_id, zone_version_id, point, task_type, outcome, description, required_capabilities,
                           required_asset_class, priority, scheduled_start, scheduled_end, evidence_required, created_by, crew_id)
  values (wo.id, zone_id, zv, public.mk_point(point), task_type, outcome, description, coalesce(required_capabilities, '{}'),
          required_asset_class, priority, scheduled_start, scheduled_end, coalesce(evidence_required, public.default_evidence(task_type)), auth.uid(),
          coalesce(z.responsible_crew_id, my_crew))
  returning * into t;
  perform public.notify('crew:' || coalesce(t.crew_id::text, 'none'), 'task_created', jsonb_build_object('task_id', t.id, 'zone_id', zone_id, 'revision', t.revision));
  return public.idem_store(idempotency_key, 'task_create', public.task_result(t, jsonb_build_object('work_order_number', wo.number, 'work_order_id', wo.id)));
end $$;

-- ---------- task_assign ----------
create or replace function public.task_assign(
  idempotency_key uuid, task_id uuid, profile_id uuid, expected_revision int default null,
  asset_id text default null, attachment_id text default null, note text default null, override_qualification boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; t public.tasks; target record; missing text[]; a public.assignments; assigner text;
begin
  prior := public.idem_check(idempotency_key, 'task_assign'); if prior is not null then return prior; end if;
  r := public.auth_role();
  t := public.load_task(task_id);
  perform public.check_revision(t, expected_revision);
  if t.state not in ('unassigned') then perform public.grnd_error(410, 'Task is ' || t.state || ', use reassign', jsonb_build_object('state', t.state)); end if;
  if not public.can_direct(profile_id) then perform public.grnd_error(403, 'You may not assign work to that person'); end if;
  select * into target from public.profiles where id = profile_id and active;
  if target is null then perform public.grnd_error(404, 'Person not found'); end if;
  missing := public.missing_capabilities(profile_id, t.required_capabilities);
  if array_length(missing, 1) > 0 then
    if override_qualification and r = 'admin' then null;
    else perform public.grnd_error(423, target.full_name || ' is not certified for ' || array_to_string(missing, ', '),
           jsonb_build_object('missing', to_jsonb(missing), 'profile_id', profile_id, 'task_id', task_id)); end if;
  end if;
  insert into public.assignments(task_id, profile_id, asset_id, attachment_id, assigned_by, note, qualification_override)
  values (task_id, profile_id, asset_id, attachment_id, auth.uid(), note, override_qualification and array_length(missing, 1) > 0) returning * into a;
  perform public.reserve_asset(asset_id, profile_id, t, a.id);
  perform public.reserve_asset(attachment_id, profile_id, t, a.id);
  update public.tasks set state = 'assigned', assignee_id = profile_id, current_assignment_id = a.id, revision = revision + 1,
         crew_id = coalesce(target.crew_id, crew_id)
   where id = task_id returning * into t;
  update public.work_orders set status = 'in_progress' where id = t.work_order_id and status = 'open';
  select full_name into assigner from public.profiles where id = auth.uid();
  perform public.notify('person:' || profile_id::text, 'assigned', jsonb_build_object('task_id', t.id, 'assignment_id', a.id, 'from_name', assigner,
    'message', t.zone_id || ': ' || t.outcome, 'revision', t.revision));
  return public.idem_store(idempotency_key, 'task_assign', public.task_result(t, jsonb_build_object('assignment_id', a.id, 'notified', true)));
end $$;

-- ---------- assignment_acknowledge ----------
create or replace function public.assignment_acknowledge(idempotency_key uuid, assignment_id uuid, expected_revision int default null, location jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; a public.assignments; t public.tasks;
begin
  prior := public.idem_check(idempotency_key, 'assignment_acknowledge'); if prior is not null then return prior; end if;
  perform public.auth_role();
  select * into a from public.assignments where id = assignment_id for update;
  if a is null then perform public.grnd_error(404, 'Assignment not found'); end if;
  if a.profile_id <> auth.uid() then perform public.grnd_error(403, 'Not your assignment'); end if;
  if a.released_at is not null then perform public.grnd_error(410, 'Assignment was released'); end if;
  if a.acknowledged_at is not null then perform public.grnd_error(410, 'Already acknowledged', jsonb_build_object('acknowledged_at', a.acknowledged_at)); end if;
  t := public.load_task(a.task_id);
  perform public.check_revision(t, expected_revision);
  if t.state <> 'assigned' then perform public.grnd_error(410, 'Task is ' || t.state, jsonb_build_object('state', t.state)); end if;
  update public.assignments set acknowledged_at = now() where id = assignment_id returning * into a;
  update public.tasks set state = 'accepted', revision = revision + 1 where id = t.id returning * into t;
  perform public.notify('crew:' || coalesce(t.crew_id::text, 'none'), 'acknowledged', jsonb_build_object('task_id', t.id, 'assignment_id', a.id, 'revision', t.revision));
  return public.idem_store(idempotency_key, 'assignment_acknowledge', public.task_result(t, jsonb_build_object('assignment_id', a.id, 'acknowledged_at', a.acknowledged_at)));
end $$;

-- ---------- assignment_reassign (one click) ----------
create or replace function public.assignment_reassign(
  idempotency_key uuid, task_id uuid, to_profile_id uuid, expected_revision int default null, reason text default null,
  keep_asset boolean default true, asset_id text default null, attachment_id text default null, override_qualification boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; t public.tasks; old_a public.assignments; new_a public.assignments; target record; missing text[];
        me record; prev_name text; assigner text; use_asset text; use_att text;
begin
  prior := public.idem_check(idempotency_key, 'assignment_reassign'); if prior is not null then return prior; end if;
  r := public.auth_role();
  t := public.load_task(task_id);
  perform public.check_revision(t, expected_revision);
  if t.state not in ('assigned','accepted','in_progress') then perform public.grnd_error(410, 'Task is ' || t.state, jsonb_build_object('state', t.state)); end if;
  select * into old_a from public.assignments where id = t.current_assignment_id for update;
  select * into target from public.profiles where id = to_profile_id and active;
  if target is null then perform public.grnd_error(404, 'Person not found'); end if;
  select * into me from public.profiles where id = auth.uid();
  -- permission: admin anyone; lead own crew; Temp 2 assignee may hand to a Temp 1 in the same crew
  if public.can_direct(to_profile_id) then null;
  elsif r = 'worker' and me.employment_tier = 'temp2' and old_a.profile_id = auth.uid() and target.employment_tier = 'temp1' and target.crew_id = me.crew_id then null;
  else perform public.grnd_error(403, 'You may not reassign to that person'); end if;
  missing := public.missing_capabilities(to_profile_id, t.required_capabilities);
  if array_length(missing, 1) > 0 and not (override_qualification and r = 'admin') then
    perform public.grnd_error(423, target.full_name || ' is not certified for ' || array_to_string(missing, ', '),
      jsonb_build_object('missing', to_jsonb(missing), 'profile_id', to_profile_id, 'task_id', task_id)); end if;
  update public.assignments set released_at = now(), release_reason = coalesce(reason, 'reassigned') where id = old_a.id returning * into old_a;
  perform public.release_assets(task_id, old_a.id);
  use_asset := coalesce(asset_id, case when keep_asset then old_a.asset_id end);
  use_att := coalesce(attachment_id, case when keep_asset then old_a.attachment_id end);
  insert into public.assignments(task_id, profile_id, asset_id, attachment_id, assigned_by, reassigned_from, note, qualification_override)
  values (task_id, to_profile_id, use_asset, use_att, auth.uid(), old_a.id, reason, override_qualification and array_length(missing, 1) > 0) returning * into new_a;
  perform public.reserve_asset(use_asset, to_profile_id, t, new_a.id);
  perform public.reserve_asset(use_att, to_profile_id, t, new_a.id);
  update public.tasks set state = 'assigned', assignee_id = to_profile_id, current_assignment_id = new_a.id, revision = revision + 1,
         crew_id = coalesce(target.crew_id, crew_id), started_at = null
   where id = task_id returning * into t;
  select full_name into prev_name from public.profiles where id = old_a.profile_id;
  assigner := me.full_name;
  perform public.notify('person:' || old_a.profile_id::text, 'reassigned_away', jsonb_build_object('task_id', t.id, 'assignment_id', old_a.id, 'from_name', assigner,
    'message', t.zone_id || ' reassigned to ' || target.full_name || coalesce(' (' || reason || ')', ''), 'revision', t.revision));
  perform public.notify('person:' || to_profile_id::text, 'reassigned_to_you', jsonb_build_object('task_id', t.id, 'assignment_id', new_a.id, 'from_name', assigner,
    'message', t.zone_id || ': ' || t.outcome || coalesce(' (' || reason || ')', ''), 'revision', t.revision));
  return public.idem_store(idempotency_key, 'assignment_reassign', public.task_result(t,
    jsonb_build_object('assignment_id', new_a.id, 'released_assignment_id', old_a.id, 'previous_assignee_name', prev_name)));
end $$;

-- ---------- assignment_release ----------
create or replace function public.assignment_release(idempotency_key uuid, assignment_id uuid, reason text, expected_revision int default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; a public.assignments; t public.tasks; me text;
begin
  prior := public.idem_check(idempotency_key, 'assignment_release'); if prior is not null then return prior; end if;
  perform public.auth_role();
  select * into a from public.assignments where id = assignment_id for update;
  if a is null then perform public.grnd_error(404, 'Assignment not found'); end if;
  if a.released_at is not null then perform public.grnd_error(410, 'Already released'); end if;
  if not public.can_direct(a.profile_id) then perform public.grnd_error(403, 'You may not release that assignment'); end if;
  t := public.load_task(a.task_id);
  perform public.check_revision(t, expected_revision);
  if t.state not in ('assigned','accepted','blocked') then perform public.grnd_error(410, 'Task is ' || t.state || '; reassign instead', jsonb_build_object('state', t.state)); end if;
  update public.assignments set released_at = now(), release_reason = reason where id = assignment_id;
  perform public.release_assets(t.id, assignment_id);
  update public.tasks set state = 'unassigned', assignee_id = null, current_assignment_id = null, revision = revision + 1, state_before_block = null, blocked_reason = null
   where id = t.id returning * into t;
  select full_name into me from public.profiles where id = auth.uid();
  perform public.notify('person:' || a.profile_id::text, 'released', jsonb_build_object('task_id', t.id, 'assignment_id', a.id, 'from_name', me, 'message', t.zone_id || ': ' || reason, 'revision', t.revision));
  return public.idem_store(idempotency_key, 'assignment_release', public.task_result(t));
end $$;

-- ---------- task_start ----------
create or replace function public.task_start(idempotency_key uuid, task_id uuid, location jsonb, expected_revision int default null, asset_id text default null, attachment_id text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; t public.tasks; s record; pt geometry; asmt jsonb; ko text;
begin
  prior := public.idem_check(idempotency_key, 'task_start'); if prior is not null then return prior; end if;
  perform public.auth_role();
  t := public.load_task(task_id);
  perform public.check_revision(t, expected_revision);
  if t.assignee_id <> auth.uid() then perform public.grnd_error(403, 'Not your task'); end if;
  if t.state <> 'accepted' then perform public.grnd_error(410, 'Task is ' || t.state || ', acknowledge it first', jsonb_build_object('state', t.state)); end if;
  select * into s from public.shifts where profile_id = auth.uid() and ended_at is null;
  if s is null then perform public.grnd_error(425, 'Start your shift first'); end if;
  ko := public.keepout_active_for_zone(t.zone_id);
  if ko is not null then perform public.grnd_error(426, 'Keep-out active on ' || t.zone_id || ' (' || ko || ')', jsonb_build_object('keepout', ko)); end if;
  pt := public.mk_point(location);
  if pt is null or (location->>'accuracy_m') is null then perform public.grnd_error(422, 'location with accuracy_m is required', '{"fields":["location"]}'); end if;
  asmt := public.assess_location(pt, (location->>'accuracy_m')::numeric, coalesce((location->>'taken_at')::timestamptz, now()), t.zone_version_id);
  if asset_id is not null or attachment_id is not null then
    update public.assignments a2 set asset_id = coalesce(task_start.asset_id, a2.asset_id), attachment_id = coalesce(task_start.attachment_id, a2.attachment_id) where a2.id = t.current_assignment_id;
  end if;
  update public.tasks set state = 'in_progress', started_at = now(), revision = revision + 1 where id = t.id returning * into t;
  perform public.notify('crew:' || coalesce(t.crew_id::text, 'none'), 'task_started', jsonb_build_object('task_id', t.id, 'revision', t.revision, 'assessment', asmt->>'result'));
  return public.idem_store(idempotency_key, 'task_start', public.task_result(t, jsonb_build_object('started_at', t.started_at, 'assessment', asmt)));
end $$;

-- ---------- task_block / unblock / cancel ----------
create or replace function public.task_block(idempotency_key uuid, task_id uuid, reason text, expected_revision int default null, photo_path text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; t public.tasks; me text;
begin
  prior := public.idem_check(idempotency_key, 'task_block'); if prior is not null then return prior; end if;
  r := public.auth_role();
  t := public.load_task(task_id);
  perform public.check_revision(t, expected_revision);
  if not (t.assignee_id = auth.uid() or r = 'admin' or (r = 'lead' and public.can_see_task(t))) then perform public.grnd_error(403, 'You may not block that task'); end if;
  if t.state in ('blocked','done','canceled') then perform public.grnd_error(410, 'Task is ' || t.state, jsonb_build_object('state', t.state)); end if;
  if reason is null or length(trim(reason)) < 2 then perform public.grnd_error(422, 'reason is required', '{"fields":["reason"]}'); end if;
  update public.tasks set state_before_block = state, state = 'blocked', blocked_reason = reason || coalesce(' [photo ' || photo_path || ']', ''), revision = revision + 1
   where id = t.id returning * into t;
  select full_name into me from public.profiles where id = auth.uid();
  perform public.notify('crew:' || coalesce(t.crew_id::text, 'none'), 'task_blocked', jsonb_build_object('task_id', t.id, 'from_name', me, 'message', t.zone_id || ' blocked: ' || reason, 'revision', t.revision));
  return public.idem_store(idempotency_key, 'task_block', public.task_result(t));
end $$;

create or replace function public.task_unblock(idempotency_key uuid, task_id uuid, expected_revision int default null, note text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; t public.tasks;
begin
  prior := public.idem_check(idempotency_key, 'task_unblock'); if prior is not null then return prior; end if;
  r := public.auth_role();
  if r not in ('admin','lead') then perform public.grnd_error(403, 'Only admins and leads unblock'); end if;
  t := public.load_task(task_id);
  perform public.check_revision(t, expected_revision);
  if t.state <> 'blocked' then perform public.grnd_error(410, 'Task is not blocked'); end if;
  update public.tasks set state = coalesce(state_before_block, case when assignee_id is null then 'unassigned' else 'assigned' end),
         state_before_block = null, blocked_reason = null, revision = revision + 1 where id = t.id returning * into t;
  if t.assignee_id is not null then
    perform public.notify('person:' || t.assignee_id::text, 'task_unblocked', jsonb_build_object('task_id', t.id, 'message', coalesce(note, t.zone_id || ' unblocked'), 'revision', t.revision));
  end if;
  return public.idem_store(idempotency_key, 'task_unblock', public.task_result(t));
end $$;

create or replace function public.task_cancel(idempotency_key uuid, task_id uuid, reason text, expected_revision int default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; t public.tasks;
begin
  prior := public.idem_check(idempotency_key, 'task_cancel'); if prior is not null then return prior; end if;
  r := public.auth_role();
  t := public.load_task(task_id);
  perform public.check_revision(t, expected_revision);
  if not (r = 'admin' or (r = 'lead' and public.can_see_task(t))) then perform public.grnd_error(403, 'You may not cancel that task'); end if;
  if t.state in ('done','canceled') then perform public.grnd_error(410, 'Task is ' || t.state); end if;
  update public.assignments a2 set released_at = now(), release_reason = 'canceled: ' || reason where a2.task_id = t.id and a2.released_at is null;
  perform public.release_assets(t.id, null);
  update public.tasks set state = 'canceled', blocked_reason = reason, revision = revision + 1 where id = t.id returning * into t;
  if t.assignee_id is not null then
    perform public.notify('person:' || t.assignee_id::text, 'canceled', jsonb_build_object('task_id', t.id, 'message', t.zone_id || ' canceled: ' || reason, 'revision', t.revision));
  end if;
  return public.idem_store(idempotency_key, 'task_cancel', public.task_result(t));
end $$;

-- ---------- dispatch_candidates ----------
create or replace function public.dispatch_candidates(task_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare t public.tasks; center geography; out_ jsonb;
begin
  perform public.auth_role();
  select * into t from public.tasks where id = task_id;
  if t is null or not public.can_see_task(t) then perform public.grnd_error(404, 'Task not found'); end if;
  select st_centroid(geom)::geography into center from public.zone_versions where id = t.zone_version_id;
  select coalesce(jsonb_agg(row_to_json(c) order by (c.availability = 'free' and c.missing_capabilities = '{}') desc, c.distance_m nulls last, c.full_name), '[]'::jsonb)
  into out_
  from (
    select p.id as profile_id, p.full_name, cr.name as crew_name,
           (s.id is not null) as on_shift,
           case when not p.active then 'unavailable' when s.id is null then 'off_shift'
                when exists (select 1 from public.tasks x where x.assignee_id = p.id and x.state = 'in_progress') then 'busy' else 'free' end as availability,
           case when s.last_point is not null and center is not null then round(st_distance(s.last_point::geography, center)::numeric) end as distance_m,
           public.missing_capabilities(p.id, t.required_capabilities) as missing_capabilities,
           (select jsonb_build_object('task_id', x.id, 'zone_id', x.zone_id) from public.tasks x where x.assignee_id = p.id and x.state = 'in_progress' limit 1) as current_task
    from public.profiles p
    left join public.crews cr on cr.id = p.crew_id
    left join public.shifts s on s.profile_id = p.id and s.ended_at is null
    where p.active and p.app_role in ('lead','worker','admin') and public.can_direct(p.id) and p.id <> coalesce(t.assignee_id, '00000000-0000-0000-0000-000000000000'::uuid)
  ) c;
  return jsonb_build_object('ok', true, 'data', out_);
end $$;

-- ---------- RLS ----------
alter table public.work_orders enable row level security;
alter table public.tasks enable row level security;
alter table public.assignments enable row level security;
alter table public.outbox enable row level security;
create policy work_orders_read on public.work_orders for select to authenticated using (public.auth_role() in ('admin','oversight','lead') or created_by = auth.uid()
  or exists (select 1 from public.tasks t where t.work_order_id = work_orders.id and public.can_see_task(t)));
create policy tasks_read on public.tasks for select to authenticated using (public.can_see_task(tasks));
create policy assignments_read on public.assignments for select to authenticated using (profile_id = auth.uid() or public.can_see_profile(profile_id)
  or exists (select 1 from public.tasks t where t.id = assignments.task_id and public.can_see_task(t)));

-- ---------- views ----------
create view public.v_task_detail with (security_invoker = true) as
select t.id as task_id, t.revision as task_revision, a.id as assignment_id,
       t.task_type, t.outcome, t.description, t.priority, t.state, t.blocked_reason,
       t.zone_id, z.name as zone_name, t.zone_version_id, z.class as zone_class,
       st_asgeojson(zv.geom)::jsonb as zone_geom, st_asgeojson(st_centroid(zv.geom))::jsonb as zone_center, st_asgeojson(t.point)::jsonb as point,
       z.site, wo.season,
       t.scheduled_start, t.scheduled_end, t.started_at, t.finalized_at, t.approved_at,
       ab.full_name as assigned_by_name, a.assigned_at, a.acknowledged_at,
       t.assignee_id, asg.full_name as assignee_name,
       a.asset_id, ast.name as asset_name, a.attachment_id, att.name as attachment_name,
       t.required_capabilities,
       case when t.assignee_id is null then '{}'::text[] else public.missing_capabilities(t.assignee_id, t.required_capabilities) end as missing_capabilities,
       t.evidence_required,
       (public.keepout_active_for_zone(t.zone_id) is not null) as keepout_active, public.keepout_active_for_zone(t.zone_id) as keepout_reason,
       wo.number as work_order_number, wo.title as work_order_title, t.work_order_id,
       t.crew_id, cb.full_name as created_by_name, t.created_at, t.updated_at,
       (select coalesce(jsonb_agg(jsonb_build_object('assignment_id', h.id, 'profile_id', h.profile_id, 'profile_name', hp.full_name, 'assigned_at', h.assigned_at,
               'acknowledged_at', h.acknowledged_at, 'released_at', h.released_at, 'release_reason', h.release_reason) order by h.assigned_at), '[]'::jsonb)
          from public.assignments h join public.profiles hp on hp.id = h.profile_id where h.task_id = t.id) as assignment_history,
       case t.state when 'in_progress' then 0 when 'accepted' then 10 when 'assigned' then 20 when 'blocked' then 30 when 'review' then 40 else 50 end * 10 + t.priority as sort_key
from public.tasks t
join public.work_orders wo on wo.id = t.work_order_id
join public.zones z on z.id = t.zone_id
join public.zone_versions zv on zv.id = t.zone_version_id
left join public.assignments a on a.id = t.current_assignment_id
left join public.profiles ab on ab.id = a.assigned_by
left join public.profiles asg on asg.id = t.assignee_id
left join public.profiles cb on cb.id = t.created_by
left join public.assets ast on ast.id = a.asset_id
left join public.assets att on att.id = a.attachment_id;

create view public.v_my_day with (security_invoker = true) as
select * from public.v_task_detail
where assignee_id = auth.uid() and state in ('assigned','accepted','in_progress','blocked','review')
order by sort_key, scheduled_start nulls last;

create view public.v_dispatch_board with (security_invoker = true) as
select d.task_id, d.task_revision, d.work_order_number, d.work_order_title, d.task_type, d.outcome, d.priority, d.state, d.season,
       d.zone_id, d.zone_name, d.zone_class, d.zone_center, d.site, d.scheduled_start, d.scheduled_end,
       (d.scheduled_end is not null and d.scheduled_end < now() and d.state not in ('review','done','canceled')) as overdue,
       d.assignee_id, d.assignee_name,
       exists (select 1 from public.shifts s where s.profile_id = d.assignee_id and s.ended_at is null) as assignee_on_shift,
       (d.acknowledged_at is not null) as acknowledged, d.assigned_at,
       d.asset_id, d.asset_name, d.required_capabilities,
       (select count(*) from public.profiles p join public.shifts s on s.profile_id = p.id and s.ended_at is null
         where p.active and p.app_role in ('worker','lead') and public.missing_capabilities(p.id, d.required_capabilities) = '{}'
           and not exists (select 1 from public.tasks x where x.assignee_id = p.id and x.state = 'in_progress'))::int as qualified_available_count,
       d.blocked_reason, d.keepout_active, d.crew_id, d.updated_at as last_activity_at, d.sort_key
from public.v_task_detail d
where d.state not in ('done','canceled');

create view public.v_crew_availability with (security_invoker = true) as
select p.id as profile_id, p.full_name, p.app_role, p.employment_tier, p.crew_id, c.name as crew_name,
       (select max(cp.ends_at) from public.crew_placements cp where cp.profile_id = p.id and cp.starts_at <= now() and (cp.ends_at is null or cp.ends_at > now())) as placement_until,
       (s.id is not null) as on_shift, s.started_at as shift_started_at,
       s.last_sample_at as last_location_at, st_asgeojson(s.last_point)::jsonb as last_location,
       (s.id is not null and (s.last_sample_at is null or s.last_sample_at < now() - interval '5 minutes')) as location_stale,
       s.last_zone_id as current_zone_id, z.name as current_zone_name, s.last_result as current_zone_result,
       (select count(*) from public.tasks x where x.assignee_id = p.id and x.state in ('assigned','accepted','in_progress','blocked'))::int as open_task_count,
       ip.id as in_progress_task_id, ipz.name as in_progress_zone_name,
       public.valid_capability_codes(p.id) as capabilities,
       null::numeric as hours_today, null::numeric as hours_week,
       case when not p.active then 'unavailable' when s.id is null then 'off_shift' when ip.id is not null then 'busy' else 'free' end as availability
from public.profiles p
left join public.crews c on c.id = p.crew_id
left join public.shifts s on s.profile_id = p.id and s.ended_at is null
left join public.zones z on z.id = s.last_zone_id
left join lateral (select x.id, x.zone_id from public.tasks x where x.assignee_id = p.id and x.state = 'in_progress' limit 1) ip on true
left join public.zones ipz on ipz.id = ip.zone_id
where p.active and p.app_role in ('admin','lead','worker');

-- ---------- grants ----------
grant select on public.work_orders, public.tasks, public.assignments, public.v_task_detail, public.v_my_day, public.v_dispatch_board, public.v_crew_availability to authenticated;
grant execute on function
  public.task_create(uuid, text, text, text, uuid, uuid, text, smallint, text[], text, timestamptz, timestamptz, text[], jsonb),
  public.task_assign(uuid, uuid, uuid, int, text, text, text, boolean),
  public.assignment_acknowledge(uuid, uuid, int, jsonb),
  public.assignment_reassign(uuid, uuid, uuid, int, text, boolean, text, text, boolean),
  public.assignment_release(uuid, uuid, text, int),
  public.task_start(uuid, uuid, jsonb, int, text, text),
  public.task_block(uuid, uuid, text, int, text), public.task_unblock(uuid, uuid, int, text), public.task_cancel(uuid, uuid, text, int),
  public.dispatch_candidates(uuid), public.can_see_task(public.tasks), public.can_direct(uuid), public.default_evidence(text)
  to authenticated;
revoke execute on function public.notify(text, text, jsonb), public.load_task(uuid), public.reserve_asset(text, uuid, public.tasks, uuid), public.release_assets(uuid, uuid) from anon, authenticated;
