-- ============================================================
-- Provada database schema
-- Run this in Supabase Dashboard -> SQL Editor -> New query.
-- Safe to re-run any time (uses IF NOT EXISTS / DROP POLICY IF EXISTS).
--
-- ACCOUNTS ARE INVITE-ONLY. There is no public sign-up form.
-- To create a login for a client or admin:
--   1. Supabase Dashboard -> Authentication -> Users -> Add user
--      (set their email + a password, check "Auto Confirm User")
--   2. Every new user gets a profile row with role = 'client' by default.
--      To make someone an admin, run:
--        update public.profiles set role = 'admin' where id =
--          (select id from auth.users where email = 'admin@example.com');
--   3. To link a client account to the project so they (and only they,
--      besides admins) can see its progress/chat, run:
--        update public.projects set client_id =
--          (select id from auth.users where email = 'client@example.com')
--        where ref = 'PZ-0142';
--   4. For chat image uploads to work: Supabase Dashboard -> Storage ->
--      New bucket -> name it exactly "chat-attachments" -> keep it PRIVATE.
--      (This SQL script sets up the access policies for that bucket below.)
-- ============================================================

-- 1. Profiles (extends auth.users with a role)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'client' check (role in ('client', 'admin')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "Users can view their own profile" on public.profiles;
drop policy if exists "Users can view all profiles (needed for chat display)" on public.profiles;
drop policy if exists "Users can update their own profile" on public.profiles;

-- Only your own profile is readable — no browsing other accounts.
create policy "Users can view their own profile"
  on public.profiles for select
  using (auth.uid() = id);

create policy "Users can update their own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- Automatically create a profile row whenever a new user is added
-- (via Authentication -> Add user). Defaults to role = 'client'.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    coalesce(new.raw_user_meta_data->>'role', 'client')
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Lets a policy check "is the current user an admin" without recursively
-- re-triggering RLS on public.profiles (security definer bypasses RLS here).
create or replace function public.is_admin()
returns boolean
language sql
security definer set search_path = public
stable
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- 2. Projects (one row per client project shown on the dashboard)
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  ref text not null default 'PZ-0142',
  client_name text not null default 'Aurora Retail Co.',
  owner text not null default 'Pazovado Team',
  est_completion date,
  progress int not null default 0 check (progress between 0 and 100),
  status_label text not null default 'Initiated',
  client_id uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

alter table public.projects add column if not exists client_id uuid references auth.users(id);
alter table public.projects add column if not exists wallet_network text;
alter table public.projects add column if not exists wallet_coin text;
alter table public.projects add column if not exists wallet_address text;

alter table public.projects enable row level security;

drop policy if exists "Authenticated users can view projects" on public.projects;
drop policy if exists "Admins view all projects, clients view only their own" on public.projects;
drop policy if exists "Only admins can update projects" on public.projects;

-- Admins see every project; a client only sees the project they're linked to.
create policy "Admins view all projects, clients view only their own"
  on public.projects for select
  using (public.is_admin() or client_id = auth.uid());

create policy "Only admins can update projects"
  on public.projects for update
  using (public.is_admin());

-- Seed one demo project row (safe to run once; skip if you already have one)
insert into public.projects (ref, client_name, owner, est_completion, progress, status_label)
select 'PZ-0142', 'Aurora Retail Co.', 'Pazovado Team', '2026-09-05', 20, 'Reviewing'
where not exists (select 1 from public.projects);

-- 3. Event log (timeline entries shown in the dashboard's Event Log panel)
create table if not exists public.event_log (
  id bigint generated always as identity primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  message text not null,
  created_at timestamptz not null default now()
);

alter table public.event_log enable row level security;

drop policy if exists "Authenticated users can view event log" on public.event_log;
drop policy if exists "Only project participants can view event log" on public.event_log;
drop policy if exists "Only admins can insert event log entries" on public.event_log;
drop policy if exists "Only admins can delete event log entries" on public.event_log;

-- Only the admin team and the specific linked client can see a project's log.
create policy "Only project participants can view event log"
  on public.event_log for select
  using (
    public.is_admin()
    or exists (select 1 from public.projects p where p.id = event_log.project_id and p.client_id = auth.uid())
  );

create policy "Only admins can insert event log entries"
  on public.event_log for insert
  with check (public.is_admin());

create policy "Only admins can delete event log entries"
  on public.event_log for delete
  using (public.is_admin());

-- 4. Chat messages (live support chat between client and admin)
create table if not exists public.messages (
  id bigint generated always as identity primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  sender_role text not null check (sender_role in ('client', 'admin')),
  content text not null default '',
  attachment_path text,
  created_at timestamptz not null default now()
);

-- Migrate older installs: allow empty content (image-only messages) and add attachment_path.
alter table public.messages alter column content set default '';
alter table public.messages alter column content drop not null;
update public.messages set content = '' where content is null;
alter table public.messages alter column content set not null;
alter table public.messages add column if not exists attachment_path text;
alter table public.messages add column if not exists edited_at timestamptz;

alter table public.messages enable row level security;

drop policy if exists "Authenticated users can view messages" on public.messages;
drop policy if exists "Only project participants can view messages" on public.messages;
drop policy if exists "Authenticated users can send messages" on public.messages;
drop policy if exists "Only project participants can send messages" on public.messages;
drop policy if exists "Senders can edit their own messages" on public.messages;

-- A client only ever sees messages on their own project's thread; admins see all.
-- No client can ever read another client's conversation.
create policy "Only project participants can view messages"
  on public.messages for select
  using (
    public.is_admin()
    or exists (select 1 from public.projects p where p.id = messages.project_id and p.client_id = auth.uid())
  );

-- Sending requires being the authenticated sender AND a real participant
-- (admin, or the client this project is linked to).
create policy "Only project participants can send messages"
  on public.messages for insert
  with check (
    auth.uid() = sender_id
    and (
      public.is_admin()
      or exists (select 1 from public.projects p where p.id = messages.project_id and p.client_id = auth.uid())
    )
  );

-- Editing: only the original sender may edit their own message, and only
-- the content/attachment/edited_at can change (sender/project stay fixed —
-- enforced on the client by only sending those columns, and on the server
-- because the USING/WITH CHECK clause requires sender_id to stay the same).
create policy "Senders can edit their own messages"
  on public.messages for update
  using (auth.uid() = sender_id)
  with check (auth.uid() = sender_id);

-- Deleting: the original sender can delete their own message; admins can
-- delete any message (moderation), same pattern as event log deletion.
drop policy if exists "Senders and admins can delete messages" on public.messages;
create policy "Senders and admins can delete messages"
  on public.messages for delete
  using (auth.uid() = sender_id or public.is_admin());

-- 5. Payments (client payment history + outstanding balance, shown in sidebar)
create table if not exists public.payments (
  id bigint generated always as identity primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  description text not null default '',
  kind text not null check (kind in ('paid', 'due')),
  occurred_on date not null default current_date,
  settle_by date,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.payments add column if not exists settle_by date;

alter table public.payments enable row level security;

drop policy if exists "Only project participants can view payments" on public.payments;
drop policy if exists "Only admins can insert payments" on public.payments;
drop policy if exists "Only admins can delete payments" on public.payments;
drop policy if exists "Only admins can update payments" on public.payments;

-- Admins manage payment records; the linked client can only view their own.
create policy "Only project participants can view payments"
  on public.payments for select
  using (
    public.is_admin()
    or exists (select 1 from public.projects p where p.id = payments.project_id and p.client_id = auth.uid())
  );

create policy "Only admins can insert payments"
  on public.payments for insert
  with check (public.is_admin());

create policy "Only admins can update payments"
  on public.payments for update
  using (public.is_admin())
  with check (public.is_admin());

create policy "Only admins can delete payments"
  on public.payments for delete
  using (public.is_admin());

-- 6. Chat image attachments (Supabase Storage)
-- One-time manual step (SQL can't create buckets): in Supabase Dashboard ->
-- Storage -> New bucket -> name it exactly "chat-attachments" -> keep it PRIVATE.
-- The policies below then restrict who can upload/view files in it, the same
-- way messages are restricted: only admins and the project's linked client.
drop policy if exists "Only project participants can view chat attachments" on storage.objects;
drop policy if exists "Only project participants can upload chat attachments" on storage.objects;

create policy "Only project participants can view chat attachments"
  on storage.objects for select
  using (
    bucket_id = 'chat-attachments'
    and (
      public.is_admin()
      or exists (
        select 1 from public.projects p
        where p.id::text = (storage.foldername(name))[1]
        and p.client_id = auth.uid()
      )
    )
  );

create policy "Only project participants can upload chat attachments"
  on storage.objects for insert
  with check (
    bucket_id = 'chat-attachments'
    and (
      public.is_admin()
      or exists (
        select 1 from public.projects p
        where p.id::text = (storage.foldername(name))[1]
        and p.client_id = auth.uid()
      )
    )
  );

-- 7. Enable realtime on the tables the dashboard subscribes to
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'projects'
  ) then
    alter publication supabase_realtime add table public.projects;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'event_log'
  ) then
    alter publication supabase_realtime add table public.event_log;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'payments'
  ) then
    alter publication supabase_realtime add table public.payments;
  end if;
end $$;
