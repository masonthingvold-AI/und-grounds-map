-- 0002 Capabilities (the master list Chad and Bobby own) and certifications (a person holding one)
-- docs/api-contract.md section 3.4

create table public.capabilities (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                 -- TOOLCAT, MOWER_4100, BOBCAT, PLOW_TRUCK, CHAINSAW, AERIAL_LIFT, PESTICIDE, CDL, SALT_SPREADER, SMALL_TOOLS
  name text not null,
  category text not null check (category in ('equipment','tool','license','safety','other')),
  granted_by_tier text not null default 'admin' check (granted_by_tier in ('admin','full_time')),
  required_for_asset_classes text[] not null default '{}',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger capabilities_touch before update on public.capabilities for each row execute function public.touch_updated_at();

create table public.certifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id),
  capability_id uuid not null references public.capabilities(id),
  verified_by uuid references public.profiles(id),
  verified_at timestamptz not null default now(),
  expires_at timestamptz,
  suspended boolean not null default false,
  restrictions text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_id, capability_id)
);
create trigger certifications_touch before update on public.certifications for each row execute function public.touch_updated_at();

-- valid capability codes for a person, as of now
create or replace function public.valid_capability_codes(p uuid) returns text[]
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(array_agg(c.code order by c.code), '{}')
  from public.certifications ce join public.capabilities c on c.id = ce.capability_id
  where ce.profile_id = p and not ce.suspended and c.active
    and (ce.expires_at is null or ce.expires_at > now())
$$;

-- which of the required codes does this person lack
create or replace function public.missing_capabilities(p uuid, required text[]) returns text[]
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(array_agg(r order by r), '{}')
  from unnest(coalesce(required, '{}')) r
  where not (r = any(public.valid_capability_codes(p)))
$$;

-- ---------- certification_verify (admin any; lead only full_time-tier capabilities, own crew) ----------
create or replace function public.certification_verify(
  idempotency_key uuid, profile_id uuid, capability_code text,
  expires_at timestamptz default null, restrictions text default null, notes text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; cap record; cert_id uuid;
begin
  prior := public.idem_check(idempotency_key, 'certification_verify'); if prior is not null then return prior; end if;
  r := public.auth_role();
  select * into cap from public.capabilities where code = capability_code and active;
  if cap is null then perform public.grnd_error(404, 'Unknown capability ' || capability_code); end if;
  if r = 'admin' then null;
  elsif r = 'lead' and cap.granted_by_tier = 'full_time' and public.can_see_profile(profile_id) then null;
  else perform public.grnd_error(403, 'You may not verify ' || capability_code); end if;
  insert into public.certifications(profile_id, capability_id, verified_by, verified_at, expires_at, suspended, restrictions, notes)
  values (profile_id, cap.id, auth.uid(), now(), expires_at, false, restrictions, notes)
  on conflict on constraint certifications_profile_id_capability_id_key do update
    set verified_by = excluded.verified_by, verified_at = now(), expires_at = excluded.expires_at,
        suspended = false, restrictions = excluded.restrictions, notes = excluded.notes
  returning id into cert_id;
  return public.idem_store(idempotency_key, 'certification_verify',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('certification_id', cert_id, 'profile_id', profile_id, 'capability_code', capability_code), 'replayed', false));
end $$;

create or replace function public.certification_suspend(idempotency_key uuid, profile_id uuid, capability_code text, reason text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare prior jsonb; r text; cap record; n int;
begin
  prior := public.idem_check(idempotency_key, 'certification_suspend'); if prior is not null then return prior; end if;
  r := public.auth_role();
  select * into cap from public.capabilities where code = capability_code;
  if cap is null then perform public.grnd_error(404, 'Unknown capability ' || capability_code); end if;
  if not (r = 'admin' or (r = 'lead' and cap.granted_by_tier = 'full_time' and public.can_see_profile(profile_id))) then
    perform public.grnd_error(403, 'You may not suspend ' || capability_code); end if;
  update public.certifications set suspended = true, notes = coalesce(notes || E'\n', '') || 'Suspended: ' || coalesce(reason, '')
   where certifications.profile_id = certification_suspend.profile_id and capability_id = cap.id;
  get diagnostics n = row_count;
  if n = 0 then perform public.grnd_error(404, 'No certification to suspend'); end if;
  return public.idem_store(idempotency_key, 'certification_suspend',
    jsonb_build_object('ok', true, 'data', jsonb_build_object('profile_id', profile_id, 'capability_code', capability_code, 'suspended', true), 'replayed', false));
end $$;

-- ---------- RLS ----------
alter table public.capabilities enable row level security;
alter table public.certifications enable row level security;
create policy capabilities_read on public.capabilities for select to authenticated using (true);
create policy certifications_read on public.certifications for select to authenticated using (public.can_see_profile(profile_id));

-- ---------- views ----------
create view public.v_capabilities with (security_invoker = true) as
select id, code, name, category, granted_by_tier, required_for_asset_classes, active from public.capabilities;

create view public.v_qualifications with (security_invoker = true) as
select ce.profile_id, p.full_name, c.id as capability_id, c.code as capability_code, c.name as capability_name, c.category,
       vb.full_name as verified_by_name, ce.verified_at, ce.expires_at, ce.suspended, ce.restrictions,
       (not ce.suspended and c.active and (ce.expires_at is null or ce.expires_at > now())) as valid
from public.certifications ce
join public.profiles p on p.id = ce.profile_id
join public.capabilities c on c.id = ce.capability_id
left join public.profiles vb on vb.id = ce.verified_by;

create or replace view public.v_me with (security_invoker = true) as
select p.id, p.full_name, p.phone, p.email, p.employment_tier, p.app_role, p.crew_id, c.name as crew_name,
       p.reports_to, p.is_student, p.active,
       public.valid_capability_codes(p.id) as capabilities
from public.profiles p left join public.crews c on c.id = p.crew_id
where p.id = auth.uid();

-- ---------- grants ----------
grant select on public.capabilities, public.certifications, public.v_capabilities, public.v_qualifications to authenticated;
grant execute on function public.valid_capability_codes(uuid), public.missing_capabilities(uuid, text[]),
  public.certification_verify(uuid, uuid, text, timestamptz, text, text), public.certification_suspend(uuid, uuid, text, text) to authenticated;

-- ---------- seed the master list (Chad and Bobby edit this; codes are stable) ----------
insert into public.capabilities (code, name, category, granted_by_tier, required_for_asset_classes) values
 ('SMALL_TOOLS',   'Small tools (trimmers, blowers, hand tools)', 'tool', 'full_time', '{trimmer,blower,hand_tool}'),
 ('MOWER_ZTR',     'Zero turn mower',                    'equipment', 'full_time', '{mower_ztr}'),
 ('MOWER_WIDE',    'Wide area mower (4100 class)',       'equipment', 'admin',     '{mower_wide}'),
 ('TOOLCAT',       'Bobcat Toolcat',                     'equipment', 'full_time', '{toolcat}'),
 ('BOBCAT',        'Skid steer / compact loader',        'equipment', 'admin',     '{skid_steer,loader}'),
 ('TRACTOR',       'Tractor with attachments',           'equipment', 'admin',     '{tractor}'),
 ('PLOW_TRUCK',    'Plow truck',                         'equipment', 'admin',     '{plow_truck}'),
 ('SALT_SPREADER', 'Salt and sand spreader',             'equipment', 'full_time', '{spreader}'),
 ('UTV',           'Utility vehicle (Gator class)',      'equipment', 'full_time', '{utv}'),
 ('CHAINSAW',      'Chainsaw',                           'tool',      'admin',     '{chainsaw}'),
 ('AERIAL_LIFT',   'Aerial lift',                        'equipment', 'admin',     '{aerial_lift}'),
 ('PESTICIDE',     'ND pesticide applicator license',    'license',   'admin',     '{sprayer}'),
 ('CDL',           'Commercial driver license',          'license',   'admin',     '{cdl_truck}'),
 ('IRRIGATION',    'Irrigation system work',             'safety',    'admin',     '{}');
