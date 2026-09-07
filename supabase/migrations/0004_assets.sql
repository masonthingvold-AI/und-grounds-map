-- 0004 Assets (machines, attachments, vehicles, tools), reservations, materials
-- Asset ids match data/assets.geojson (EQ-01..). ADR decision 14: exclusion constraint on reservations.

create table public.assets (
  id text primary key,                          -- EQ-14, ATT-03; printed on the barcode label
  name text not null,
  asset_type text not null check (asset_type in ('machine','attachment','vehicle','tool','facility','fixed')),
  class text not null,                          -- mower_ztr, mower_wide, toolcat, skid_steer, loader, tractor, utv, plow_truck, spreader, pusher_box, broom, blower, bucket, trimmer, hand_tool, sprayer, aerial_lift, chainsaw, storage, hydrant, salt_box, other
  make text, model text, year int, serial text,
  required_capability_code text references public.capabilities(code),
  compatible_with text[] not null default '{}', -- for attachments: asset ids or classes they fit
  status text not null default 'in_service' check (status in ('in_service','down','needs_repair','retired','unknown')),
  home_zone_id text references public.zones(id),
  location geometry(Point, 4326),
  hour_meter numeric,
  barcode text unique,
  howto_md text,
  attrs jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger assets_touch before update on public.assets for each row execute function public.touch_updated_at();

-- one asset, one holder, for a time window. Exclusion constraint prevents overlapping reservations.
create table public.asset_reservations (
  id uuid primary key default gen_random_uuid(),
  asset_id text not null references public.assets(id),
  holder_id uuid not null references public.profiles(id),
  task_id uuid,                                 -- fk added in 0006
  assignment_id uuid,
  during tstzrange not null,
  released_at timestamptz,
  created_at timestamptz not null default now(),
  exclude using gist (asset_id with =, during with &&) where (released_at is null)
);
create index asset_reservations_asset_idx on public.asset_reservations(asset_id) where released_at is null;

create or replace function public.asset_available(p_asset text, p_window tstzrange, p_required_class text default null)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare a record; conflict_ record;
begin
  select * into a from public.assets where id = p_asset and active;
  if a is null then return jsonb_build_object('ok', false, 'why', 'not_found'); end if;
  if a.status <> 'in_service' then return jsonb_build_object('ok', false, 'why', a.status); end if;
  if p_required_class is not null and a.class <> p_required_class then return jsonb_build_object('ok', false, 'why', 'wrong_class', 'class', a.class); end if;
  select r.*, p.full_name into conflict_ from public.asset_reservations r join public.profiles p on p.id = r.holder_id
   where r.asset_id = p_asset and r.released_at is null and r.during && p_window limit 1;
  if conflict_.id is not null then return jsonb_build_object('ok', false, 'why', 'reserved', 'holder', conflict_.full_name, 'task_id', conflict_.task_id); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- materials (minimal: enough for service_finalize to record what was used) ----------
create table public.materials (
  code text primary key,                        -- bulk_salt, sand, brine, fertilizer, mulch, seed
  name text not null,
  unit text not null,                           -- lb, gal, bag, yd3
  on_hand numeric not null default 0,
  reorder_at numeric not null default 0,
  storage_zone_id text references public.zones(id),
  active boolean not null default true,
  updated_at timestamptz not null default now()
);
create table public.material_transactions (
  id uuid primary key default gen_random_uuid(),
  material_code text not null references public.materials(code),
  qty numeric not null,                         -- negative for use
  unit text not null,
  kind text not null check (kind in ('receive','use','adjust','waste')),
  by_profile uuid references public.profiles(id),
  at timestamptz not null default now(),
  service_record_id uuid,                       -- fk added in 0007
  zone_id text references public.zones(id),
  note text
);
create index material_tx_material_idx on public.material_transactions(material_code, at);
create trigger material_tx_immutable before update or delete on public.material_transactions for each row execute function public.forbid_change();

create or replace function public.material_tx_apply() returns trigger language plpgsql as $$
begin
  update public.materials set on_hand = on_hand + new.qty, updated_at = now() where code = new.material_code;
  return new;
end $$;
create trigger material_tx_apply after insert on public.material_transactions for each row execute function public.material_tx_apply();

insert into public.materials(code, name, unit) values
 ('bulk_salt', 'Bulk salt', 'lb'), ('sand', 'Sand', 'lb'), ('brine', 'Liquid brine', 'gal'),
 ('bagged_icemelt', 'Bagged ice melt', 'bag'), ('fertilizer', 'Fertilizer', 'lb'), ('mulch', 'Mulch', 'yd3'), ('seed', 'Grass seed', 'lb');

-- ---------- RLS, views, grants ----------
alter table public.assets enable row level security;
alter table public.asset_reservations enable row level security;
alter table public.materials enable row level security;
alter table public.material_transactions enable row level security;
create policy assets_read on public.assets for select to authenticated using (true);
create policy reservations_read on public.asset_reservations for select to authenticated using (true);
create policy materials_read on public.materials for select to authenticated using (true);
create policy material_tx_read on public.material_transactions for select to authenticated using (public.auth_role() in ('admin','lead','oversight') or by_profile = auth.uid());

create view public.v_assets with (security_invoker = true) as
select a.id, a.name, a.asset_type, a.class, a.make, a.model, a.year, a.required_capability_code, a.compatible_with, a.status,
       a.home_zone_id, st_asgeojson(a.location)::jsonb as location, a.hour_meter, a.barcode, a.howto_md, a.attrs,
       r.holder_id as reserved_by, p.full_name as reserved_by_name, r.task_id as reserved_for_task, r.during as reserved_window
from public.assets a
left join lateral (select * from public.asset_reservations r where r.asset_id = a.id and r.released_at is null and r.during @> now() limit 1) r on true
left join public.profiles p on p.id = r.holder_id
where a.active;

grant select on public.assets, public.asset_reservations, public.materials, public.material_transactions, public.v_assets to authenticated;
grant execute on function public.asset_available(text, tstzrange, text) to authenticated;
