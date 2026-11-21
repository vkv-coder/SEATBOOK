-- Fixes "permission denied for table kh_open_pass_sold", hit live while
-- testing a real pass-type booking on the ALICA event. Same class of
-- issue as kh_bookings_select_grant_fix.sql: kh_booking_integrity_
-- migration.sql originally set this table up with
-- `grant select, insert, update on kh_open_pass_sold to anon,
-- authenticated` plus a permissive "pass_sold_write_via_trigger" RLS
-- policy (using(true) with check(true)) - both were confirmed gone from
-- the live database (anon/authenticated only had SELECT, and the write
-- policy didn't exist at all), presumably dropped by some later
-- hardening pass that didn't realize this table's write policy is
-- deliberately open because the real guarantee comes from the trigger's
-- advisory lock, not RLS (see that migration's own comment).
--
-- Net effect: kh_bookings_guard_pass_capacity()'s internal INSERT/UPDATE
-- into kh_open_pass_sold has been failing for every pass-type booking -
-- never hit before because no event had configured pass types until the
-- ALICA event did. Verified live with a throwaway anon-key booking
-- (failed with the RLS error before this fix, succeeded with HTTP 201
-- after) before trusting it.

grant insert, update on kh_open_pass_sold to anon, authenticated;

-- CREATE POLICY has no IF NOT EXISTS in Postgres - if this already exists
-- (it shouldn't, given it was confirmed missing live), drop it first.
create policy "pass_sold_write_via_trigger" on kh_open_pass_sold
  for all to anon, authenticated using (true) with check (true);
