-- Closes the free-ticket exploit on kh_bookings: booking.html's checkout
-- uses Razorpay's simple "amount + key" mode (no Orders API, so no
-- signature to verify), and previously just told the database "payment
-- succeeded" directly from the client
-- (status='confirmed', payment_status='paid') - combined with open
-- SELECT on kh_bookings, any booking id was discoverable and this
-- transition was fakeable via a direct API call, no real payment
-- required. Real fix: verify-razorpay-payment (Edge Function) checks the
-- payment against Razorpay's Payments API server-side before performing
-- this exact update via service_role.
--
-- IMPORTANT - two attempts were needed here:
--
-- Attempt 1 (RLS only) added a restrictive WITH CHECK to a general
-- update policy blocking the confirmed+paid combination. This did NOT
-- work: Postgres combines WITH CHECK across ALL matching PERMISSIVE
-- policies via OR, independent of which policy granted row visibility.
-- The existing "Scanner mark entry"/"Scanner can mark entry" policies
-- have a weak WITH CHECK (just `status = 'confirmed'`, no check on
-- payment_status or the OLD row) - the moment ANY other policy made a
-- row visible for update, that weak check became a backdoor for the
-- exact transition being blocked elsewhere. Confirmed empirically by
-- isolating policies one at a time.
--
-- Attempt 2 (this one, working) uses a BEFORE UPDATE trigger instead -
-- it sees OLD and NEW directly and isn't subject to that OR-across-
-- policies ambiguity. RLS policies are left essentially open for
-- UPDATE (matching original behavior); the trigger is the real guard.
--
-- Gotcha hit while building the trigger: it must NOT be SECURITY
-- DEFINER. A SECURITY DEFINER function's current_user resolves to the
-- function's OWNER (e.g. postgres), not the actual caller - which
-- blocked service_role too (confirmed via a debug_whoami() RPC that
-- showed current_user='service_role' for a normal call, but the
-- trigger internally saw something else while DEFINER). SECURITY
-- INVOKER (the default) fixes it, and needs no elevated privileges
-- anyway since it only compares values and raises.

-- Restore the pre-existing policies to their original state (this file
-- went through a few iterations while diagnosing the bug above).
drop policy if exists "Organisers can update own event bookings" on kh_bookings;
create policy "Organisers can update own event bookings" on kh_bookings
for update to public
using (event_id in (
  select kh_events.id from kh_events
  where (kh_events.organiser_id)::text = ((current_setting('request.jwt.claims', true))::json ->> 'organiser_id')
));

drop policy if exists "Scanner can mark entry" on kh_bookings;
create policy "Scanner can mark entry" on kh_bookings
for update to public
using (status = 'confirmed')
with check (status = 'confirmed');

drop policy if exists "Scanner mark entry" on kh_bookings;
create policy "Scanner mark entry" on kh_bookings
for update to anon
using (status = 'confirmed')
with check (status = 'confirmed');

drop policy if exists bookings_organiser_update on kh_bookings;
create policy bookings_organiser_update on kh_bookings
for update to authenticated
using (event_id in (
  select kh_events.id from kh_events
  where kh_events.organiser_id = (
    select kh_organisers.id from kh_organisers
    where kh_organisers.email_1 = (auth.jwt() ->> 'email') limit 1
  )
));

-- Also replaces the old wide-open anon_all_bookings (ALL/true) and
-- bookings_update (UPDATE/true) policies - SELECT/INSERT coverage for
-- anon is already provided by other existing policies.
drop policy if exists anon_all_bookings on kh_bookings;
drop policy if exists bookings_update on kh_bookings;

create policy anon_insert_bookings on kh_bookings
for insert to anon
with check (true);

-- Matches the client's existing cleanup pattern (releaseHold in
-- booking.html only ever deletes held/cancelled rows).
create policy anon_delete_own_holds on kh_bookings
for delete to anon
using (status in ('held', 'cancelled'));

create policy anon_update_bookings on kh_bookings
for update to anon, authenticated
using (true)
with check (true);

-- The actual fix.
create or replace function kh_bookings_guard_confirm()
returns trigger
language plpgsql
security invoker
as $$
begin
  if new.status = 'confirmed' and new.payment_status = 'paid'
     and (old.status is distinct from 'confirmed' or old.payment_status is distinct from 'paid')
     and current_user <> 'service_role' then
    raise exception 'Booking confirmation must go through payment verification (verify-razorpay-payment)';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_kh_bookings_guard_confirm on kh_bookings;
create trigger trg_kh_bookings_guard_confirm
before update on kh_bookings
for each row
execute function kh_bookings_guard_confirm();

-- NOT fixed here: kh_food_orders has the identical pattern
-- (saveFoodOrderInline/saveFoodOrderStandalone in booking.html insert
-- status:'confirmed' directly from the client with no verification).
-- Lower value than ticket bookings but the same class of issue - flagged
-- as a separate follow-up, not covered by this migration.
