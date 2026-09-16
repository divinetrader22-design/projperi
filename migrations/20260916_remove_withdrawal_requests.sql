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
