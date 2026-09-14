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
