begin;
-- Existing "Clients manage only their own FWP key" FOR ALL policy already
-- restricts deletion to the linked client and excludes dashboard admins.
grant delete on public.client_fwp_keys to authenticated;
notify pgrst, 'reload schema';
commit;
