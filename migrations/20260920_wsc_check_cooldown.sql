begin;
create table if not exists public.wsc_check_limits (
 project_id uuid not null references public.projects(id) on delete cascade,
 client_id uuid not null references auth.users(id) on delete cascade,
 next_check_at timestamptz not null,
 primary key(project_id,client_id)
);
alter table public.wsc_check_limits enable row level security;
revoke all on public.wsc_check_limits from public, anon, authenticated;

-- Atomic reservation prevents simultaneous requests or refreshes bypassing the limit.
create or replace function public.claim_wsc_check(p_project_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare deadline timestamptz;
begin
 if auth.uid() is null or public.is_admin() or not exists (
  select 1 from public.projects p where p.id=p_project_id and p.client_id=auth.uid()
 ) or not exists (
  select 1 from public.client_fwp_keys k where k.project_id=p_project_id and k.client_id=auth.uid()
 ) or not exists (
  select 1 from public.client_quotes q where q.project_id=p_project_id and q.client_id=auth.uid() and q.required_sol is not null
 ) then
  raise exception 'Validation access denied' using errcode='42501';
 end if;
 insert into public.wsc_check_limits(project_id,client_id,next_check_at)
 values(p_project_id,auth.uid(),clock_timestamp()+interval '60 seconds')
 on conflict(project_id,client_id) do update set next_check_at=excluded.next_check_at
 where wsc_check_limits.next_check_at<=clock_timestamp()
 returning next_check_at into deadline;
 if found then
  return jsonb_build_object('allowed',true,'retry_after',60);
 end if;
 select next_check_at into deadline from public.wsc_check_limits
 where project_id=p_project_id and client_id=auth.uid();
 return jsonb_build_object('allowed',false,'retry_after',greatest(1,ceil(extract(epoch from deadline-clock_timestamp()))::int));
end $$;
revoke all on function public.claim_wsc_check(uuid) from public, anon;
grant execute on function public.claim_wsc_check(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
