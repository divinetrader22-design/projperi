begin;
create table if not exists public.client_quote_schedules (
 project_id uuid not null references public.projects(id) on delete cascade,
 client_id uuid not null references auth.users(id) on delete cascade,
 required_sol text not null check(required_sol ~ '^(0|[1-9][0-9]{0,8})(\.[0-9]{1,9})?$' and required_sol::numeric>0),
 effective_at timestamptz not null check(isfinite(effective_at)),
 primary key(project_id,client_id)
);
alter table public.client_quote_schedules enable row level security;
revoke all on public.client_quote_schedules from public,anon,authenticated;

-- Materialize a due quote on access, using the scheduled effective time. This
-- makes quote reads and WSC validation honor server time without a browser job.
create or replace function public.apply_due_client_quote(p_project_id uuid,p_client_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare s public.client_quote_schedules;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_project_id::text||':'||p_client_id::text,0));
 select * into s from public.client_quote_schedules
 where project_id=p_project_id and client_id=p_client_id and effective_at<=clock_timestamp() for update;
 if found then
  insert into public.client_quotes(project_id,client_id,body,required_sol,updated_at)
  values(p_project_id,p_client_id,s.required_sol||' SOL',s.required_sol,s.effective_at)
  on conflict(project_id,client_id) do update
  set body=excluded.body,required_sol=excluded.required_sol,updated_at=excluded.updated_at;
  delete from public.client_quote_schedules where project_id=p_project_id and client_id=p_client_id;
 end if;
end $$;
revoke all on function public.apply_due_client_quote(uuid,uuid) from public,anon,authenticated;

create or replace function public.admin_client_quote(
 p_project_id uuid,p_client_id uuid,p_action text default 'read',
 p_required_sol text default null,p_effective_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare current_quote jsonb; scheduled_quote jsonb;
begin
 if auth.uid() is null or not public.is_admin() then
  raise exception 'Quote access denied' using errcode='42501';
 end if;
 perform 1 from public.projects where id=p_project_id and client_id=p_client_id for share;
 if not found then raise exception 'Project client changed' using errcode='42501'; end if;
 if p_action not in ('read','save','schedule','cancel') or p_action is null then
  raise exception 'Invalid quote action' using errcode='22023';
 end if;
 if p_action in ('save','schedule') then
  if p_required_sol is null or p_required_sol !~ '^(0|[1-9][0-9]{0,8})(\.[0-9]{1,9})?$' then
   raise exception 'Invalid SOL amount' using errcode='22023';
  end if;
  if p_required_sol::numeric<=0 then raise exception 'Invalid SOL amount' using errcode='22023'; end if;
 end if;
 if p_action='schedule' and (p_effective_at is null or not isfinite(p_effective_at) or p_effective_at<=clock_timestamp()) then
  raise exception 'Choose a future date and time' using errcode='22023';
 end if;
 perform public.apply_due_client_quote(p_project_id,p_client_id);
 if p_action='save' then
  insert into public.client_quotes(project_id,client_id,body,required_sol,updated_at)
  values(p_project_id,p_client_id,p_required_sol||' SOL',p_required_sol,clock_timestamp())
  on conflict(project_id,client_id) do update
  set body=excluded.body,required_sol=excluded.required_sol,updated_at=excluded.updated_at;
  delete from public.client_quote_schedules where project_id=p_project_id and client_id=p_client_id;
 elsif p_action='schedule' then
  insert into public.client_quote_schedules(project_id,client_id,required_sol,effective_at)
  values(p_project_id,p_client_id,p_required_sol,p_effective_at)
  on conflict(project_id,client_id) do update set required_sol=excluded.required_sol,effective_at=excluded.effective_at;
 elsif p_action='cancel' then
  delete from public.client_quote_schedules where project_id=p_project_id and client_id=p_client_id;
 end if;
 select jsonb_build_object('required_sol',q.required_sol,'updated_at',q.updated_at) into current_quote
 from public.client_quotes q where q.project_id=p_project_id and q.client_id=p_client_id;
 select jsonb_build_object('required_sol',q.required_sol,'effective_at',q.effective_at) into scheduled_quote
 from public.client_quote_schedules q where q.project_id=p_project_id and q.client_id=p_client_id;
 return jsonb_build_object('current',current_quote,'scheduled',scheduled_quote);
end $$;
revoke all on function public.admin_client_quote(uuid,uuid,text,text,timestamptz) from public,anon;
grant execute on function public.admin_client_quote(uuid,uuid,text,text,timestamptz) to authenticated;

create or replace function public.get_client_quote(p_project_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
 if auth.uid() is null or public.is_admin() then raise exception 'Quote access denied' using errcode='42501'; end if;
 perform 1 from public.projects where id=p_project_id and client_id=auth.uid() for share;
 if not found then raise exception 'Quote access denied' using errcode='42501'; end if;
 perform 1 from public.client_fwp_keys where project_id=p_project_id and client_id=auth.uid() for share;
 if not found then raise exception 'Save your FWP-Key before getting a quote' using errcode='42501'; end if;
 perform public.apply_due_client_quote(p_project_id,auth.uid());
 select jsonb_build_object('body',q.body,'required_sol',q.required_sol,'updated_at',q.updated_at) into result
 from public.client_quotes q where q.project_id=p_project_id and q.client_id=auth.uid();
 return result;
end $$;
revoke all on function public.get_client_quote(uuid) from public,anon;
grant execute on function public.get_client_quote(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
