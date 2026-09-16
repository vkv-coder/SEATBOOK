-- Correction to kh_bookings_scan_columns_lockdown.sql - two bugs found
-- during post-apply verification (never trust "the statement succeeded",
-- always re-test the actual exploit):
--
-- 1. The original REVOKE UPDATE (col-list) was a no-op. anon/authenticated
--    had a TABLE-WIDE UPDATE grant (not a column-scoped one), and
--    Postgres' column-level REVOKE only removes a column-specific ACL
--    entry - it does nothing to a broader table-wide grant that already
--    covers that column. Confirmed via information_schema.role_column_grants:
--    anon still had UPDATE on food_scanned_at after the "successful" revoke,
--    and a direct exploit re-test proved it - the PATCH went through.
--    Real fix: revoke the table-wide grant entirely, then re-grant UPDATE
--    on an explicit allowlist of every column the live booking flow
--    actually needs (verified against every write call site found across
--    booking.html/organiser-dashboard.html/ticket.html/scanner.html/
--    food-scanner.html), deliberately excluding the scan-tracking columns
--    (now RPC-only) plus id/created_at/event_id (nothing legitimately
--    updates these after insert).
--
-- 2. kh_process_scan's `set search_path to 'public'` broke its own call
--    to kh_compute_scan_code(), which internally calls digest() (pgcrypto,
--    lives outside 'public') with no schema qualification and no
--    search_path override of its own - it has always relied on whatever
--    search_path was active at call time. The sibling functions
--    (kh_verify_scanner_override/login) never restrict search_path for
--    exactly this reason. Matching that existing, already-relied-upon
--    pattern instead of applying the stricter search_path convention used
--    elsewhere in the portfolio, since fixing kh_compute_scan_code itself
--    would touch a shared function two other live RPCs also depend on.

revoke update on kh_bookings from anon, authenticated;

grant update (
  booker_name, booker_mobile, booker_email, customer_name, customer_mobile,
  seat_ids, seat_keys, seat_count, amount, payment_status, status,
  razorpay_order_id, razorpay_payment_id, qr_code,
  booking_type, pass_type_id, is_full_event, booking_day
) on kh_bookings to anon, authenticated;

create or replace function public.kh_process_scan(
  p_event_id uuid, p_booking_id uuid, p_scan_type text, p_code text default null
) returns jsonb
language plpgsql
security definer
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

  if v_current is null then
    if p_scan_type = 'entry' then
      update kh_bookings set entry_scanned_at = now(), entry_scan_count = 1, entry_overridden = false
        where id = p_booking_id and entry_scanned_at is null;
    else
      update kh_bookings set food_scanned_at = now(), food_scan_count = 1, food_overridden = false
        where id = p_booking_id and food_scanned_at is null;
    end if;
    if not found then
      select * into v_booking from kh_bookings where id = p_booking_id;
      return jsonb_build_object('status','already_given','booking',to_jsonb(v_booking));
    end if;
    select * into v_booking from kh_bookings where id = p_booking_id;
    return jsonb_build_object('status','valid','booking',to_jsonb(v_booking));
  end if;

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

-- Reset the real booking I marked during exploit-verification testing
-- (before the column lockdown was actually effective) back to its real
-- state - the test PATCH of food_scanned_at succeeded because of bug #1
-- above.
update kh_bookings set food_scanned_at = null, food_scan_count = 0, food_overridden = false
  where id = 'eed2c0d9-4e6a-47a5-a33c-cd2fc16be811';
