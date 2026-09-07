-- 0001 People, crews, helpers, idempotency log
-- See docs/api-contract.md sections 1 and 2, docs/adr-001-architecture.md decisions 2 and 14.

create extension if not exists postgis;
create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- ---------- error helper ----------
-- Every function raises through this so the client always sees GRND-<code>: <text> with JSON details.
create or replace function public.grnd_error(code int, msg text, detail jsonb default '{}'::jsonb)
returns void language plpgsql as $$
begin
  raise exception using errcode = 'P0001',
    message = 'GRND-' || code::text || ': ' || msg,
    detail = detail::text;
end $$;

-- ---------- updated_at ----------
create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ---------- crews and profiles ----------
create table public.crews (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  crew_type text not null check (crew_type in ('zone','mow','flower','snow_lots','snow_walks','tree','irrigation','shop')),
  lead_id uuid,                              -- fk added after profiles exists
  home_zone_ids text[] not null default '{}',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  phone text,
  email text,
  employment_tier text not null check (employment_tier in ('oversight','admin','full_time','temp2','temp1')),
  app_role text not null check (app_role in ('oversight','admin','lead','worker')),
  reports_to uuid references public.profiles(id),
  crew_id uuid references public.crews(id),
  is_student boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.crews add constraint crews_lead_fk foreign key (lead_id) references public.profiles(id);
create index profiles_crew_idx on public.profiles(crew_id);
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
create trigger crews_touch before update on public.crews for each row execute function public.touch_updated_at();

-- temporary coverage of another crew, effective dated
create table public.crew_placements (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id),
  crew_id uuid not null references public.crews(id),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  placed_by uuid references public.profiles(id),
  reason text,
  created_at timestamptz not null default now()
);
create index crew_placements_profile_idx on public.crew_placements(profile_id, starts_at);

-- ---------- caller helpers ----------
create or replace function public.auth_profile_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.profiles where id = auth.uid() and active
$$;

create or replace function public.auth_role() returns text
language plpgsql stable security definer set search_path = public as $$
declare r text;
begin
  select app_role into r from public.profiles where id = auth.uid() and active;
  if r is null then perform public.grnd_error(401, 'Not signed in or profile inactive'); end if;
  return r;
end $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select app_role in ('admin') from public.profiles where id = auth.uid() and active), false)
$$;

-- crews the caller belongs to right now (home crew plus active placements)
create or replace function public.my_crew_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct c), '{}')
  from (
    select crew_id c from public.profiles where id = auth.uid() and crew_id is not null
    union
    select crew_id from public.crew_placements
     where profile_id = auth.uid() and starts_at <= now() and (ends_at is null or ends_at > now())
  ) s
$$;

-- can the caller see or direct this person? admin and oversight: anyone. lead: own crew. worker: self.
create or replace function public.can_see_profile(target uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare r text;
begin
  if target = auth.uid() then return true; end if;
  select app_role into r from public.profiles where id = auth.uid() and active;
  if r in ('admin','oversight') then return true; end if;
  if r = 'lead' then
    return exists (
      select 1 from public.profiles p where p.id = target and p.crew_id = any(public.my_crew_ids())
    ) or exists (
      select 1 from public.crew_placements cp where cp.profile_id = target
        and cp.crew_id = any(public.my_crew_ids()) and cp.starts_at <= now() and (cp.ends_at is null or cp.ends_at > now())
    );
  end if;
  return false;
end $$;

-- ---------- idempotency ----------
create table public.command_log (
  idempotency_key uuid primary key,
  fn text not null,
  caller uuid not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
create index command_log_created_idx on public.command_log(created_at);

-- Returns the stored result if this key was already used by the same caller and function, else null.
create or replace function public.idem_check(key uuid, fn_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare row_ record;
begin
  if key is null then perform public.grnd_error(422, 'idempotency_key is required', '{"fields":["idempotency_key"]}'); end if;
  select * into row_ from public.command_log where idempotency_key = key;
  if not found then return null; end if;
  if row_.fn <> fn_name or row_.caller <> auth.uid() then
    perform public.grnd_error(422, 'idempotency_key was used for a different command', jsonb_build_object('fields', array['idempotency_key']));
  end if;
  return row_.result || jsonb_build_object('replayed', true);
end $$;

create or replace function public.idem_store(key uuid, fn_name text, result jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  insert into public.command_log(idempotency_key, fn, caller, result) values (key, fn_name, auth.uid(), result);
  return result;
end $$;

-- ---------- RLS ----------
alter table public.profiles enable row level security;
alter table public.crews enable row level security;
alter table public.crew_placements enable row level security;
alter table public.command_log enable row level security;

create policy profiles_read on public.profiles for select to authenticated using (public.can_see_profile(id));
create policy crews_read on public.crews for select to authenticated using (true);
create policy placements_read on public.crew_placements for select to authenticated using (public.can_see_profile(profile_id));
-- no insert/update/delete policies: writes go through functions (admin tooling uses service role for now)

-- ---------- views ----------
create view public.v_me with (security_invoker = true) as
select p.id, p.full_name, p.phone, p.email, p.employment_tier, p.app_role, p.crew_id, c.name as crew_name,
       p.reports_to, p.is_student, p.active,
       '{}'::text[] as capabilities   -- replaced in 0002
from public.profiles p left join public.crews c on c.id = p.crew_id
where p.id = auth.uid();

-- ---------- grants ----------
revoke all on all tables in schema public from anon, authenticated;
grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.crews, public.crew_placements, public.v_me to authenticated;
grant execute on function public.auth_profile_id(), public.auth_role(), public.is_admin(), public.my_crew_ids(), public.can_see_profile(uuid) to authenticated;
revoke execute on function public.idem_check(uuid, text), public.idem_store(uuid, text, jsonb), public.grnd_error(int, text, jsonb) from anon, authenticated;
