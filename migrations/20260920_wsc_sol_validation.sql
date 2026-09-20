begin;
-- Decimal text avoids losing lamport precision in JavaScript clients.
alter table public.client_quotes add column if not exists required_sol text;
alter table public.client_quotes drop constraint if exists client_quotes_required_sol_check;
alter table public.client_quotes add constraint client_quotes_required_sol_check
 check (required_sol is null or (
  required_sol ~ '^(0|[1-9][0-9]{0,8})(\.[0-9]{1,9})?$'
  and required_sol::numeric > 0
 ));

create or replace function public.get_client_quote(p_project_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
 if auth.uid() is null or public.is_admin() or not exists (
  select 1 from public.projects p where p.id = p_project_id and p.client_id = auth.uid()
 ) then
  raise exception 'Quote access denied' using errcode = '42501';
 end if;
 if not exists (select 1 from public.client_fwp_keys k
  where k.project_id = p_project_id and k.client_id = auth.uid()) then
  raise exception 'Save your FWP-Key before getting a quote' using errcode = '42501';
 end if;
 select jsonb_build_object('body', q.body, 'updated_at', q.updated_at,
  'required_sol', q.required_sol) into result
 from public.client_quotes q where q.project_id = p_project_id and q.client_id = auth.uid();
 return result;
end $$;
revoke all on function public.get_client_quote(uuid) from public, anon;
grant execute on function public.get_client_quote(uuid) to authenticated;
notify pgrst, 'reload schema';
commit;
