begin;
-- Quotes are scoped to the current client, so project reassignment cannot leak them.
create table if not exists public.client_quotes (
 project_id uuid not null references public.projects(id) on delete cascade,
 client_id uuid not null references auth.users(id) on delete cascade,
 body text not null check (char_length(btrim(body)) between 1 and 4000),
 updated_at timestamptz not null default now(),
 primary key (project_id, client_id)
);
alter table public.client_quotes enable row level security;
revoke all on public.client_quotes from public, anon, authenticated;
grant select, insert, update on public.client_quotes to authenticated;
drop policy if exists "Admins manage current client quotes" on public.client_quotes;
create policy "Admins manage current client quotes" on public.client_quotes
 for all to authenticated
 using (public.is_admin() and exists (
  select 1 from public.projects p where p.id = client_quotes.project_id and p.client_id = client_quotes.client_id
 ))
 with check (public.is_admin() and exists (
  select 1 from public.projects p where p.id = client_quotes.project_id and p.client_id = client_quotes.client_id
 ));

-- Clients cannot bypass the saved-key prerequisite with a direct table query.
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
 select jsonb_build_object('body', q.body, 'updated_at', q.updated_at) into result
 from public.client_quotes q where q.project_id = p_project_id and q.client_id = auth.uid();
 return result;
end $$;
revoke all on function public.get_client_quote(uuid) from public, anon;
grant execute on function public.get_client_quote(uuid) to authenticated;
notify pgrst, 'reload schema';
commit;
