-- Fixes organiser-dashboard.html's confirmManualPayment() (cash/offline
-- payment confirmation), flagged as a separate finding in PR #3 rather
-- than bundled there.
--
-- Turns out the exploit angle here was ALREADY closed as a side effect of
-- kh_bookings_payment_lockdown.sql (2026-07-28): its BEFORE UPDATE
-- trigger (kh_bookings_guard_confirm) blocks ANY caller that isn't
-- current_user = 'service_role' from setting status='confirmed' +
-- payment_status='paid' together - exactly the transition
-- confirmManualPayment performs from the client. So the button has
-- actually been silently BROKEN since that migration landed, not
-- exploitable - every click fails with the trigger's raised exception.
-- This migration fixes the real problem: give the organiser dashboard a
-- legitimate, identity-gated path to make that exact transition, instead
-- of leaving a dead button.
--
-- A SECURITY DEFINER function does NOT satisfy current_user = 'service_role'
-- on its own - current_user inside one resolves to the function's OWNER
-- (e.g. postgres), not service_role, so the trigger would still block it.
-- Fix: the trigger also accepts a transaction-local flag that only this
-- identity-gated RPC ever sets, immediately before performing the write,
-- inside the same function call/transaction - not reachable directly by a
-- client, since PostgREST only exposes the function call itself, never
-- arbitrary SET statements.
--
-- There is, by definition, no external payment proof to check for a
-- cash/offline confirmation (unlike verify-razorpay-payment, which can
-- call out to Razorpay) - the real-organiser-of-this-event identity check
-- (same pattern kh_organiser_set_scan already uses) plus an audit trail
-- (who confirmed it and when) is the only guard that's actually possible
-- here, which is the "product decision" PR #3 flagged this as needing.

alter table kh_bookings
  add column if not exists manual_payment_confirmed_by text,
  add column if not exists manual_payment_confirmed_at timestamptz;

create or replace function public.kh_bookings_guard_confirm()
returns trigger
language plpgsql
security invoker
as $$
begin
  if new.status = 'confirmed' and new.payment_status = 'paid'
     and (old.status is distinct from 'confirmed' or old.payment_status is distinct from 'paid')
     and current_user <> 'service_role'
     and coalesce(current_setting('kh.manual_payment_authorized', true), '') <> 'true' then
    raise exception 'Booking confirmation must go through payment verification (verify-razorpay-payment) or a real organiser manual-confirm (kh_organiser_confirm_manual_payment)';
  end if;
  return new;
end;
$$;
-- trg_kh_bookings_guard_confirm already exists and points at this
-- function by name - CREATE OR REPLACE on the function body is enough,
-- no need to touch the trigger itself.

create or replace function public.kh_organiser_confirm_manual_payment(
  p_booking_id uuid
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_event_id uuid;
  v_email text;
  v_is_organiser boolean;
begin
  select event_id into v_event_id from kh_bookings where id = p_booking_id;
  if v_event_id is null then
    return jsonb_build_object('ok', false, 'message', 'booking not found');
  end if;

  v_email := auth.jwt()->>'email';

  select exists(
    select 1 from kh_events e join kh_organisers o on o.id = e.organiser_id
    where e.id = v_event_id
      and lower(coalesce(o.status,'')) = 'active'
      and (lower(o.email_1) = lower(v_email) or lower(o.email_2) = lower(v_email))
  ) into v_is_organiser;

  if not v_is_organiser then
    return jsonb_build_object('ok', false, 'message', 'not authorised for this event');
  end if;

  -- Local to this transaction only (PostgREST runs each RPC call in its
  -- own transaction) - lets this exact, already-identity-checked write
  -- through the trigger above without weakening it for anyone else.
  perform set_config('kh.manual_payment_authorized', 'true', true);

  update kh_bookings
    set status = 'confirmed', payment_status = 'paid',
        manual_payment_confirmed_by = v_email, manual_payment_confirmed_at = now()
    where id = p_booking_id;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.kh_organiser_confirm_manual_payment(uuid) from public;
grant execute on function public.kh_organiser_confirm_manual_payment(uuid) to authenticated;
