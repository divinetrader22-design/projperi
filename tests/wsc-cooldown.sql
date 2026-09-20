-- Isolated rollback fixture: no existing quotes, keys, or cooldowns are changed.
begin;
do $$
declare c uuid; a uuid; p uuid:=gen_random_uuid(); r jsonb;
begin
 select id into c from public.profiles where role='client' limit 1;
 select id into a from public.profiles where role='admin' limit 1;
 if c is null or a is null then raise exception 'Test requires existing client and admin profiles'; end if;
 insert into public.projects(id,ref,client_name,client_id) values(p,'WSC-ROLLBACK-TEST','Cooldown test',c);
 insert into public.client_fwp_keys(project_id,client_id,key_value) values(p,c,repeat('x',50));
 insert into public.client_quotes(project_id,client_id,body,required_sol) values(p,c,'0.1 SOL','0.1');
 perform set_config('request.jwt.claim.sub',c::text,true);
 r:=public.claim_wsc_check(p);
 if r->>'allowed'<>'true' or (r->>'retry_after')::int<>60 then raise exception 'First reservation failed'; end if;
 r:=public.claim_wsc_check(p);
 if r->>'allowed'<>'false' or (r->>'retry_after')::int not between 1 and 60 then raise exception 'Repeat allowed'; end if;
 update public.wsc_check_limits set next_check_at=clock_timestamp()-interval '1 second' where project_id=p;
 if public.claim_wsc_check(p)->>'allowed'<>'true' then raise exception 'Expired cooldown blocked'; end if;
 perform set_config('request.jwt.claim.sub',a::text,true);
 begin perform public.claim_wsc_check(p); raise exception 'Admin unexpectedly allowed'; exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 begin perform public.claim_wsc_check(p); raise exception 'Unrelated user unexpectedly allowed'; exception when insufficient_privilege then null; end;
 if has_table_privilege('authenticated','public.wsc_check_limits','INSERT,UPDATE,DELETE') then raise exception 'Direct writes allowed'; end if;
end $$;
select 'PASS: cooldown, expiry, ownership and direct-write protection' as result;
rollback;
