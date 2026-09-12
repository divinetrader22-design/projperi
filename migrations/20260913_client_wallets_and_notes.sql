-- Run once in the Supabase SQL Editor before deploying the wallet/notes UI.
-- Safe to re-run. The two tables are scoped to a project and protected by RLS.
create table if not exists public.client_wallets (
  project_id uuid primary key references public.projects(id) on delete cascade,
  network text not null check (network in ('BTC', 'ETH', 'SOL')),
  address text not null check (char_length(btrim(address)) between 1 and 255),
  updated_at timestamptz not null default now()
);

alter table public.client_wallets enable row level security;
revoke all on public.client_wallets from anon;
grant select, insert, update on public.client_wallets to authenticated;
drop policy if exists "Project participants view client wallets" on public.client_wallets;
drop policy if exists "Linked clients add their own wallet" on public.client_wallets;
drop policy if exists "Linked clients update their own wallet" on public.client_wallets;

create policy "Project participants view client wallets"
  on public.client_wallets for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1 from public.projects p
      where p.id = client_wallets.project_id and p.client_id = auth.uid()
    )
  );

create policy "Linked clients add their own wallet"
  on public.client_wallets for insert to authenticated
  with check (
    exists (
      select 1 from public.projects p
      where p.id = client_wallets.project_id and p.client_id = auth.uid()
    )
  );

create policy "Linked clients update their own wallet"
  on public.client_wallets for update to authenticated
  using (
    exists (
      select 1 from public.projects p
      where p.id = client_wallets.project_id and p.client_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.projects p
      where p.id = client_wallets.project_id and p.client_id = auth.uid()
    )
  );

create table if not exists public.client_notes (
  id bigint generated always as identity primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  body text not null check (char_length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists client_notes_project_created_idx
  on public.client_notes (project_id, created_at desc, id desc);

alter table public.client_notes enable row level security;
revoke all on public.client_notes from anon;
grant select, insert, update, delete on public.client_notes to authenticated;
drop policy if exists "Project participants view client notes" on public.client_notes;
drop policy if exists "Admins create client notes" on public.client_notes;
drop policy if exists "Admins edit client notes" on public.client_notes;
drop policy if exists "Admins delete client notes" on public.client_notes;

create policy "Project participants view client notes"
  on public.client_notes for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1 from public.projects p
      where p.id = client_notes.project_id and p.client_id = auth.uid()
    )
  );

create policy "Admins create client notes"
  on public.client_notes for insert to authenticated
  with check (public.is_admin());

create policy "Admins edit client notes"
  on public.client_notes for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create policy "Admins delete client notes"
  on public.client_notes for delete to authenticated
  using (public.is_admin());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'client_wallets'
  ) then
    alter publication supabase_realtime add table public.client_wallets;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'client_notes'
  ) then
    alter publication supabase_realtime add table public.client_notes;
  end if;
end $$;
