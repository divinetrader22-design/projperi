begin;
alter table public.client_fwp_keys drop constraint if exists client_fwp_keys_key_value_check;
-- Enforce new inserts/updates without deleting or rewriting previously saved keys.
alter table public.client_fwp_keys add constraint client_fwp_keys_key_value_check
 check(char_length(key_value) between 50 and 98 and char_length(btrim(key_value)) > 0) not valid;
notify pgrst, 'reload schema';
commit;
