begin;
create table if not exists public.client_fwp_keys (
 project_id uuid not null references public.projects(id) on delete cascade,
 client_id uuid not null references auth.users(id) on delete cascade,
 key_value text not null check(char_length(key_value) between 1 and 96 and char_length(btrim(key_value)) > 0),
 updated_at timestamptz not null default now(),
 primary key(project_id,client_id)
);
alter table public.client_fwp_keys enable row level security;
revoke all on public.client_fwp_keys from public,anon,authenticated;
grant select,insert,update on public.client_fwp_keys to authenticated;
drop policy if exists "Clients manage only their own FWP key" on public.client_fwp_keys;
create policy "Clients manage only their own FWP key" on public.client_fwp_keys
 for all to authenticated
 using (not public.is_admin() and client_id=auth.uid() and exists(
  select 1 from public.projects p where p.id=client_fwp_keys.project_id and p.client_id=auth.uid()
 ))
 with check (not public.is_admin() and client_id=auth.uid() and exists(
  select 1 from public.projects p where p.id=client_fwp_keys.project_id and p.client_id=auth.uid()
 ));
-- Admins receive only a boolean. This table is deliberately excluded from Realtime.
create or replace function public.get_fwp_key_status(p_project_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or not coalesce(public.is_admin(),false) then
  raise exception 'Only admins may check client key status' using errcode='42501';
 end if;
 return exists(select 1 from public.client_fwp_keys k join public.projects p on p.id=k.project_id
  where p.id=p_project_id and p.client_id=k.client_id);
end $$;
revoke all on function public.get_fwp_key_status(uuid) from public,anon;
grant execute on function public.get_fwp_key_status(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
