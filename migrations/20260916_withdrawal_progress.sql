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
