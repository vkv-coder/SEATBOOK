-- kh_bookings: close the direct-write exploit behind the food-scanner
-- override PIN finding (2026-09-16 daily audit, Critical).
--
-- Root cause: kh_bookings has an "anon_update_bookings" policy with
-- USING(true) WITH CHECK(true) that makes every other, more careful
-- policy on this table pointless (RLS policies are OR'd - one open
-- policy is all it takes). Nothing about the entry/food scan columns
-- was ever actually gated at the database level; every "supervisor PIN"
-- or "duplicate scan" check anywhere in the app was purely client-side
-- flow control that a direct REST call could always skip.
--
-- Scope of this fix, deliberately narrow: the single-day entry/food
-- scan columns only (entry_scanned_at/entry_scan_count/entry_overridden,
-- food_scanned_at/food_scan_count/food_overridden), used identically by
-- scanner.html, food-scanner.html and ticket.html's staff panel - which
-- turned out to have NO gating at all (any ticket holder could open
-- their own ticket.html and click "Mark Gate Entry"/"Mark Food
-- Collected" themselves, found while tracing every write path).
--
-- Deliberately NOT touched here: the general kh_bookings insert/update
-- surface that the public, un-authenticated booking flow itself needs
-- (booker details, payment status, holds - booking.html alone has a
-- dozen legitimate anon write paths); the multi-day kh_attendance table
-- (also fully open - "Allow public insert/update attendance" with
-- USING(true)), which is a separate, more involved piece given this app
-- was built specifically for multi-day garba-style events and deserves
-- its own careful pass, not a bolt-on here; and organiser-dashboard's
-- confirmManualPayment (status/payment_status), a related but distinct
-- finding flagged separately since fixing it well requires a real
-- payment-verification design decision, not just an auth check.

revoke update (entry_scanned_at, entry_scan_count, entry_overridden,
                food_scanned_at, food_scan_count, food_overridden)
  on kh_bookings from anon, authenticated;

-- Unified scan RPC for scanner.html / food-scanner.html / ticket.html.
-- Handles both the first scan (no code needed) and the supervisor
-- override of an already-scanned ticket (code required, verified
-- against the same daily per-event code kh_verify_scanner_override
-- already used) in one atomic, server-verified step - no more
-- "verify via RPC, then trust the client to also make an open write."
create or replace function public.kh_process_scan(
  p_event_id uuid, p_booking_id uuid, p_scan_type text, p_code text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_booking kh_bookings%rowtype;
  v_current timestamptz;
  v_count int;
begin
  if p_scan_type not in ('entry','food') then
    return jsonb_build_object('status','error','message','invalid scan type');
  end if;

  select * into v_booking from kh_bookings where id = p_booking_id;
  if v_booking.id is null then
    return jsonb_build_object('status','not_found');
  end if;
  if v_booking.event_id <> p_event_id then
    return jsonb_build_object('status','wrong_event','booking',to_jsonb(v_booking));
  end if;
  if v_booking.status <> 'confirmed' then
    return jsonb_build_object('status','not_confirmed','booking',to_jsonb(v_booking));
  end if;

  if p_scan_type = 'entry' then
    v_current := v_booking.entry_scanned_at;
    v_count := coalesce(v_booking.entry_scan_count, 0);
  else
    v_current := v_booking.food_scanned_at;
    v_count := coalesce(v_booking.food_scan_count, 0);
  end if;

  -- First scan - no code required, atomic guard against a race (two
  -- scanners hitting the same ticket at once) via the same
  -- is('...scanned_at', null)-equivalent WHERE clause the old client
  -- code used.
  if v_current is null then
    if p_scan_type = 'entry' then
      update kh_bookings set entry_scanned_at = now(), entry_scan_count = 1, entry_overridden = false
        where id = p_booking_id and entry_scanned_at is null;
    else
      update kh_bookings set food_scanned_at = now(), food_scan_count = 1, food_overridden = false
        where id = p_booking_id and food_scanned_at is null;
    end if;
    if not found then
      -- Lost the race - someone else's scan landed first between our
      -- read and write. Re-fetch and report it as already-given, same
      -- as the old client code's refetch-on-conflict fallback.
      select * into v_booking from kh_bookings where id = p_booking_id;
      return jsonb_build_object('status','already_given','booking',to_jsonb(v_booking));
    end if;
    select * into v_booking from kh_bookings where id = p_booking_id;
    return jsonb_build_object('status','valid','booking',to_jsonb(v_booking));
  end if;

  -- Already scanned. No code -> report it, let the UI offer the
  -- override box; a code -> verify it for real before writing anything.
  if p_code is null or p_code = '' then
    return jsonb_build_object('status','already_given','booking',to_jsonb(v_booking));
  end if;

  if p_code <> kh_compute_scan_code(p_event_id, 'kh_override_supervisor_2026') then
    return jsonb_build_object('status','bad_code');
  end if;

  if p_scan_type = 'entry' then
    update kh_bookings set entry_scan_count = v_count + 1, entry_overridden = true where id = p_booking_id;
  else
    update kh_bookings set food_scan_count = v_count + 1, food_overridden = true where id = p_booking_id;
  end if;
  select * into v_booking from kh_bookings where id = p_booking_id;
  return jsonb_build_object('status','overridden','booking',to_jsonb(v_booking));
end;
$$;

revoke all on function public.kh_process_scan(uuid,uuid,text,text) from public;
grant execute on function public.kh_process_scan(uuid,uuid,text,text) to anon, authenticated;

-- Organiser-dashboard's manual scan toggle (mark/clear entry or food,
-- used for corrections - e.g. "they lost their phone but I saw them
-- come in"). This page already uses real Supabase Auth
-- (auth.signInWithPassword/signInWithOtp), so it gets a real identity
-- check instead of the shared daily code: the caller must be a real,
-- active organiser of the specific event the booking belongs to - same
-- email_1/email_2 match organiser-dashboard.html's own login already
-- uses (loginWithSession). No status='confirmed' requirement here,
-- unlike kh_process_scan - this is a trusted correction tool for
-- someone already verified as this event's organiser, not a
-- first-line gate.
create or replace function public.kh_organiser_set_scan(
  p_booking_id uuid, p_field text, p_value timestamptz
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_event_id uuid;
  v_is_organiser boolean;
begin
  if p_field not in ('entry_scanned_at','food_scanned_at') then
    return jsonb_build_object('ok', false, 'message', 'invalid field');
  end if;

  select event_id into v_event_id from kh_bookings where id = p_booking_id;
  if v_event_id is null then
    return jsonb_build_object('ok', false, 'message', 'booking not found');
  end if;

  select exists(
    select 1 from kh_events e join kh_organisers o on o.id = e.organiser_id
    where e.id = v_event_id
      and lower(coalesce(o.status,'')) = 'active'
      and (lower(o.email_1) = lower(auth.jwt()->>'email') or lower(o.email_2) = lower(auth.jwt()->>'email'))
  ) into v_is_organiser;

  if not v_is_organiser then
    return jsonb_build_object('ok', false, 'message', 'not authorised for this event');
  end if;

  if p_field = 'entry_scanned_at' then
    update kh_bookings set entry_scanned_at = p_value where id = p_booking_id;
  else
    update kh_bookings set food_scanned_at = p_value where id = p_booking_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.kh_organiser_set_scan(uuid,text,timestamptz) from public;
grant execute on function public.kh_organiser_set_scan(uuid,text,timestamptz) to authenticated;
