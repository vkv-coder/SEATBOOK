-- Closes the free-ticket INSERT bypass found by the 2026-11-09 daily
-- audit: kh_bookings_payment_lockdown.sql's guard trigger only fires
-- BEFORE UPDATE, but the anon_insert_bookings policy it created
-- (insert ... with check (true)) is still wide open for brand-new rows.
-- A client could skip booking.html's pending -> verify-razorpay-payment
-- flow entirely by POSTing a new kh_bookings row that's already
-- status='confirmed', payment_status='paid' - no Razorpay check, no
-- real payment, free ticket.
--
-- Checked every legitimate INSERT call site in booking.html,
-- organiser-dashboard.html (complimentary/walk-in tools): none of them
-- ever create a row that's already confirmed+paid - that transition only
-- ever happens via the existing UPDATE path, inside verify-razorpay-
-- payment or kh_organiser_confirm_manual_payment. Free/complimentary/
-- walk-in tickets use payment_status values other than 'paid' (free,
-- complimentary, walk-in), so they're untouched by this guard.

create or replace function kh_bookings_guard_confirm_insert()
returns trigger
language plpgsql
security invoker
as $$
begin
  if new.status = 'confirmed' and new.payment_status = 'paid'
     and current_user <> 'service_role' then
    raise exception 'Booking confirmation must go through payment verification (verify-razorpay-payment)';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_kh_bookings_guard_confirm_insert on kh_bookings;
create trigger trg_kh_bookings_guard_confirm_insert
before insert on kh_bookings
for each row
execute function kh_bookings_guard_confirm_insert();
