-- kh_attendance: close the fully-open anon insert/update surface flagged
-- as an explicit follow-up in kh_bookings_scan_columns_lockdown.sql
-- (2026-09-16 daily audit + PR #3 scoping notes). Multi-day event
-- attendance rows (booking_id/event_id/day_number/scanned_at/scanned_by/
-- manually_punched) were insertable and updatable by anyone via a direct
-- REST call - no check that the booking exists, is confirmed, belongs to
-- the stated event, or that the day hasn't already been recorded. Same
-- class of bug as the kh_bookings scan-column exploit PR #3 closed, just
-- on the multi-day table instead of the single-day columns.
--
-- Lesson from kh_bookings_scan_columns_lockdown_v2.sql applies here too:
-- revoke the TABLE-WIDE grant, not a column-scoped one - a column-level
-- REVOKE is a silent no-op against a pre-existing table-wide grant, and
-- anon/authenticated hold exactly that kind of blanket INSERT/UPDATE
-- grant here, same as they did on kh_bookings before that fix.

revoke insert, update on kh_attendance from anon, authenticated;

-- Single RPC covers both real write paths found in scanner.html:
-- confirmDayEntry() (first scan of the CURRENT day - p_manual=false, no
-- code needed, since the scan flow itself is already the gate: the ticket
-- had to pass processBooking()'s confirmed/not-already-today checks to
-- reach this call) and buildManualPunch() (backdating/correcting a
-- DIFFERENT day with no scan flow involved at all - this one had zero
-- verification before this fix, so it now requires the same daily
-- supervisor override code kh_process_scan already uses for the
-- single-day equivalent).
create or replace function public.kh_process_attendance(
  p_event_id uuid, p_booking_id uuid, p_day_number int, p_manual boolean default false, p_code text default null
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_booking kh_bookings%rowtype;
begin
  select * into v_booking from kh_bookings where id = p_booking_id;
  if v_booking.id is null then
    return jsonb_build_object('status','not_found');
  end if;
  if v_booking.event_id <> p_event_id then
    return jsonb_build_object('status','wrong_event');
  end if;
  if v_booking.status <> 'confirmed' then
    return jsonb_build_object('status','not_confirmed');
  end if;

  if p_manual then
    if p_code is null or p_code = '' or p_code <> kh_compute_scan_code(p_event_id, 'kh_override_supervisor_2026') then
      return jsonb_build_object('status','bad_code');
    end if;
  end if;

  -- Atomic dedupe via the existing unique constraint (scanner.html's old
  -- client-side insert already relied on catching 23505 for this same
  -- reason) instead of a check-then-insert, which would race.
  begin
    insert into kh_attendance(booking_id, event_id, day_number, scanned_at, scanned_by, manually_punched)
    values (p_booking_id, p_event_id, p_day_number, now(), 'scanner', p_manual);
  exception when unique_violation then
    return jsonb_build_object('status','already_given');
  end;

  return jsonb_build_object('status','recorded');
end;
$$;

revoke all on function public.kh_process_attendance(uuid,uuid,int,boolean,text) from public;
grant execute on function public.kh_process_attendance(uuid,uuid,int,boolean,text) to anon, authenticated;
