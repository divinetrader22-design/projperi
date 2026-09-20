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

-- Supports the newest-first chat view and cursor-based older-message pages.
create index if not exists messages_project_id_id_idx
  on public.messages (project_id, id desc);

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

-- Client wallet addresses and admin-authored client notes.
-- See migrations/20260913_client_wallets_and_notes.sql for the standalone migration.
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

-- Withdrawable balances and request approval workflow.
begin;
create table if not exists public.withdrawable_balances (
 project_id uuid primary key references public.projects(id) on delete cascade,
 amount numeric(14,2) not null default 0 check(amount >= 0 and amount <= 999999999999.99),
 version bigint not null default 0,
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users(id)
);
create table if not exists public.withdrawal_requests (
 id uuid primary key default gen_random_uuid(),
 project_id uuid not null references public.projects(id) on delete cascade,
 requested_by uuid not null references auth.users(id),
 amount numeric(14,2) not null check(amount > 0 and amount <= 999999999999.99),
 status text not null default 'pending' check(status in ('pending','approved','denied')),
 requested_at timestamptz not null default now(),
 reviewed_at timestamptz,
 reviewed_by uuid references auth.users(id),
 wallet_network text,
 wallet_address text
);
create unique index if not exists withdrawal_one_pending_per_project on public.withdrawal_requests(project_id) where status='pending';
create index if not exists withdrawal_project_history on public.withdrawal_requests(project_id,requested_at desc);
alter table public.withdrawable_balances enable row level security;
alter table public.withdrawal_requests enable row level security;
revoke all on public.withdrawable_balances, public.withdrawal_requests from public, anon, authenticated;
grant select on public.withdrawable_balances, public.withdrawal_requests to authenticated;
drop policy if exists "Participants read withdrawable balance" on public.withdrawable_balances;
create policy "Participants read withdrawable balance" on public.withdrawable_balances for select to authenticated
 using(public.is_admin() or exists(select 1 from public.projects p where p.id=project_id and p.client_id=auth.uid()));
drop policy if exists "Participants read withdrawal requests" on public.withdrawal_requests;
create policy "Participants read withdrawal requests" on public.withdrawal_requests for select to authenticated
 using(public.is_admin() or exists(select 1 from public.projects p where p.id=project_id and p.client_id=auth.uid()));

create or replace function public.set_withdrawable_balance(p_project_id uuid,p_amount numeric,p_version bigint)
returns void language plpgsql security definer set search_path=public as $$
declare b public.withdrawable_balances%rowtype;
begin
 if auth.uid() is null or not coalesce(public.is_admin(),false) then raise exception 'Only admins can set balances' using errcode='42501'; end if;
 if p_amount is null or p_amount < 0 or p_amount > 999999999999.99 or p_amount <> round(p_amount,2) then raise exception 'Enter a valid balance with at most two decimal places'; end if;
 insert into public.withdrawable_balances(project_id) values(p_project_id) on conflict do nothing;
 select * into b from public.withdrawable_balances where project_id=p_project_id for update;
 if p_version is null or b.version <> p_version then raise exception 'Balance changed. Refresh and try again.'; end if;
 if exists(select 1 from public.withdrawal_requests where project_id=p_project_id and status='pending') then raise exception 'Approve or deny the pending request before changing this balance'; end if;
 update public.withdrawable_balances set amount=p_amount,version=version+1,updated_at=now(),updated_by=auth.uid() where project_id=p_project_id;
end $$;

create or replace function public.request_withdrawal(p_project_id uuid,p_expected_amount numeric)
returns uuid language plpgsql security definer set search_path=public as $$
declare b public.withdrawable_balances%rowtype; v_id uuid; w public.client_wallets%rowtype;
begin
 if auth.uid() is null or coalesce(public.is_admin(),false) or not exists(select 1 from public.projects where id=p_project_id and client_id=auth.uid()) then raise exception 'Only the linked client can request a withdrawal' using errcode='42501'; end if;
 select * into b from public.withdrawable_balances where project_id=p_project_id for update;
 if not found or b.amount <= 0 then raise exception 'No withdrawable balance is available'; end if;
 if p_expected_amount is null or b.amount <> p_expected_amount then raise exception 'Balance changed. Refresh and request the updated amount.'; end if;
 if exists(select 1 from public.withdrawal_requests where project_id=p_project_id and status='pending') then raise exception 'A withdrawal request is already pending'; end if;
 select * into w from public.client_wallets where project_id=p_project_id;
 insert into public.withdrawal_requests(project_id,requested_by,amount,wallet_network,wallet_address)
 values(p_project_id,auth.uid(),b.amount,w.network,w.address) returning id into v_id;
 return v_id;
end $$;

create or replace function public.review_withdrawal(p_request_id uuid,p_decision text)
returns void language plpgsql security definer set search_path=public as $$
declare r public.withdrawal_requests%rowtype; b public.withdrawable_balances%rowtype; v_project uuid;
begin
 if auth.uid() is null or not coalesce(public.is_admin(),false) then raise exception 'Only admins can review withdrawals' using errcode='42501'; end if;
 if p_decision is null or p_decision not in ('approved','denied') then raise exception 'Invalid decision'; end if;
 select project_id into v_project from public.withdrawal_requests where id=p_request_id;
 if not found then raise exception 'Request not found'; end if;
 -- All operations lock balance first: concurrent approvals cannot double-deduct.
 select * into b from public.withdrawable_balances where project_id=v_project for update;
 select * into r from public.withdrawal_requests where id=p_request_id for update;
 if r.status <> 'pending' then raise exception 'This request has already been reviewed'; end if;
 if p_decision='approved' then
  if b.amount is null or b.amount < r.amount then raise exception 'Insufficient withdrawable balance'; end if;
  update public.withdrawable_balances set amount=amount-r.amount,version=version+1,updated_at=now(),updated_by=auth.uid() where project_id=v_project;
 end if;
 update public.withdrawal_requests set status=p_decision,reviewed_at=now(),reviewed_by=auth.uid() where id=p_request_id;
end $$;
revoke all on function public.set_withdrawable_balance(uuid,numeric,bigint), public.request_withdrawal(uuid,numeric), public.review_withdrawal(uuid,text) from public,anon;
grant execute on function public.set_withdrawable_balance(uuid,numeric,bigint), public.request_withdrawal(uuid,numeric), public.review_withdrawal(uuid,text) to authenticated;
do $$ begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='withdrawable_balances') then alter publication supabase_realtime add table public.withdrawable_balances; end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='withdrawal_requests') then alter publication supabase_realtime add table public.withdrawal_requests; end if;
end $$;
notify pgrst,'reload schema';
commit;

-- Admin-reported withdrawal progress.
begin;
alter table public.withdrawal_requests
 add column if not exists progress numeric(5,2) not null default 0 check(progress >= 0 and progress <= 100),
 add column if not exists progress_updated_at timestamptz,
 add column if not exists progress_updated_by uuid references auth.users(id);
create or replace function public.set_withdrawal_progress(p_request_id uuid,p_progress numeric,p_expected_progress numeric)
returns void language plpgsql security definer set search_path=public as $$
declare r public.withdrawal_requests%rowtype;
begin
 if auth.uid() is null or not coalesce(public.is_admin(),false) then raise exception 'Only admins can update withdrawal progress' using errcode='42501'; end if;
 if p_progress is null or p_progress < 0 or p_progress > 100 or p_progress <> round(p_progress,2) then raise exception 'Progress must be from 0 to 100 with at most two decimal places'; end if;
 select * into r from public.withdrawal_requests where id=p_request_id for update;
 if not found then raise exception 'Withdrawal request not found'; end if;
 if r.status='denied' then raise exception 'Denied requests cannot be progressed'; end if;
 if p_expected_progress is null or r.progress <> p_expected_progress then raise exception 'Progress changed. Refresh and try again.'; end if;
 update public.withdrawal_requests set progress=p_progress,progress_updated_at=now(),progress_updated_by=auth.uid() where id=p_request_id;
end $$;
revoke all on function public.set_withdrawal_progress(uuid,numeric,numeric) from public,anon;
grant execute on function public.set_withdrawal_progress(uuid,numeric,numeric) to authenticated;
notify pgrst,'reload schema';
commit;

-- Admin removal of withdrawal requests.
begin;
-- Preserve the audit record while removing it from dashboard history.
alter table public.withdrawal_requests
 add column if not exists deleted_at timestamptz,
 add column if not exists deleted_by uuid references auth.users(id);

create or replace function public.remove_withdrawal_request(p_request_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r public.withdrawal_requests%rowtype; v_project uuid;
begin
 if auth.uid() is null or not coalesce(public.is_admin(),false) then
  raise exception 'Only admins can delete withdrawal requests' using errcode='42501';
 end if;
 select project_id into v_project from public.withdrawal_requests where id=p_request_id;
 if not found then raise exception 'Withdrawal request not found'; end if;
 -- Use the same locking order as approvals; deleting cannot double-deduct or restore money.
 perform 1 from public.withdrawable_balances where project_id=v_project for update;
 select * into r from public.withdrawal_requests where id=p_request_id for update;
 if not found then raise exception 'Withdrawal request not found'; end if;
 if r.deleted_at is not null then return; end if;
 update public.withdrawal_requests
 set deleted_at=now(),deleted_by=auth.uid(),
     status=case when status='pending' then 'denied' else status end,
     reviewed_at=case when status='pending' then now() else reviewed_at end,
     reviewed_by=case when status='pending' then auth.uid() else reviewed_by end
 where id=p_request_id;
end $$;
revoke all on function public.remove_withdrawal_request(uuid) from public,anon;
grant execute on function public.remove_withdrawal_request(uuid) to authenticated;
notify pgrst,'reload schema';
commit;

-- Client-only FWP-Key storage and admin status.
begin;
create table if not exists public.client_fwp_keys (
 project_id uuid not null references public.projects(id) on delete cascade,
 client_id uuid not null references auth.users(id) on delete cascade,
 key_value text not null check(char_length(key_value) between 50 and 98 and char_length(btrim(key_value)) > 0),
 updated_at timestamptz not null default now(),
 primary key(project_id,client_id)
);
alter table public.client_fwp_keys drop constraint if exists client_fwp_keys_key_value_check;
alter table public.client_fwp_keys add constraint client_fwp_keys_key_value_check
 check(char_length(key_value) between 50 and 98 and char_length(btrim(key_value)) > 0) not valid;
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


-- Client quotes, available after saving an app-issued FWP-Key.
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


-- Allow linked clients to delete their own FWP-Key under the existing RLS policy.
begin;
-- Existing "Clients manage only their own FWP key" FOR ALL policy already
-- restricts deletion to the linked client and excludes dashboard admins.
grant delete on public.client_fwp_keys to authenticated;
notify pgrst, 'reload schema';
commit;


-- Read-only SOL validation quote amount.
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


-- Enforce one live SOL validation per client/project per minute.
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
