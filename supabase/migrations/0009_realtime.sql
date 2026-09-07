-- 0009 Realtime: outbox rows become private broadcasts; row changes on four tables are published. docs/api-contract.md section 10.

-- outbox -> broadcast. Runs after commit of the row that wrote the outbox entry (same transaction), so a message always matches a committed change.
create or replace function public.outbox_broadcast() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform realtime.send(new.payload || jsonb_build_object('outbox_id', new.id), new.event_type, new.topic, true);
  update public.outbox set delivered_at = now() where id = new.id;
  return new;
end $$;
create trigger outbox_broadcast after insert on public.outbox for each row execute function public.outbox_broadcast();

-- who may receive on which private topic
create policy realtime_receive on realtime.messages for select to authenticated
using (
  realtime.messages.extension = 'broadcast' and (
    realtime.topic() = 'all'
    or realtime.topic() = 'person:' || auth.uid()::text
    or (realtime.topic() like 'crew:%' and substr(realtime.topic(), 6)::uuid = any(public.my_crew_ids()))
    or (realtime.topic() like 'crew:%' and public.auth_role() in ('admin','oversight'))
  )
);
-- clients never broadcast themselves; no insert policy on realtime.messages for app roles.

-- postgres_changes on the four tables the contract names (RLS filters rows per subscriber)
alter publication supabase_realtime add table public.tasks, public.assignments, public.operating_state, public.zone_status;
alter table public.tasks replica identity full;
alter table public.assignments replica identity full;
alter table public.zone_status replica identity full;

-- outbox is internal; readable by admins for debugging only
create policy outbox_read on public.outbox for select to authenticated using (public.is_admin());
grant select on public.outbox to authenticated;
