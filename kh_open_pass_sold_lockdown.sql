-- Daily audit 2026-11-06 side-observation, investigated and confirmed live:
-- kh_open_pass_sold (the per-day capacity counter kh_booking_integrity_migration.sql
-- added specifically to stop overselling) had anon granted direct INSERT/UPDATE on
-- the table itself, gated only by a bare ALL/true policy ("pass_sold_write_via_trigger").
-- That grant existed because the capacity-guard trigger functions were SECURITY
-- INVOKER - they run as whatever role performs the kh_bookings write, so anon needed
-- the grant just for the trigger's own queries to succeed during a real booking.
--
-- The hole: since the grant is on the TABLE, not scoped to only-via-trigger, anyone
-- can skip kh_bookings entirely and PATCH kh_open_pass_sold directly - set sold_count
-- to 0 (reopen a sold-out day, oversell) or to a huge number (block all real sales).
-- This defeats the exact protection the migration was built for.
--
-- Fix: make both trigger functions SECURITY DEFINER (this file already had one
-- precedent for that - verify_open_pass_amount - for the same "don't trust the
-- client" reason), so they no longer need the invoking role to hold any grant at
-- all. Then revoke anon/authenticated's direct INSERT/UPDATE and drop the
-- now-unnecessary permissive policy, leaving the table reachable only via the
-- trigger (which runs as the function owner, bypassing RLS the same way every
-- other SECURITY DEFINER RPC in this portfolio does). SELECT stays open - no PII,
-- and the "X passes left" display reads it directly.

alter function kh_bookings_guard_pass_capacity() security definer set search_path = public;
alter function kh_bookings_release_pass_capacity() security definer set search_path = public;

drop policy if exists "pass_sold_write_via_trigger" on kh_open_pass_sold;
revoke insert, update, delete on kh_open_pass_sold from anon, authenticated;
