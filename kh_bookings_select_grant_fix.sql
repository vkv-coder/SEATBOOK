-- Fixes a live "permission denied for table kh_bookings" regression hit
-- while testing lokhandwala-events' first published event, but confirmed
-- (via a direct anon-key REST call) to actually be platform-wide: ANY
-- select('*') against kh_bookings as anon OR authenticated has been
-- failing since pass_type_id/is_full_event/booking_day (kh_booking_
-- integrity_migration.sql) and manual_payment_confirmed_by/at
-- (kh_bookings_manual_payment_fix.sql) were added to the table - whoever
-- originally narrowed kh_bookings' SELECT grant to an explicit column
-- list never re-ran a GRANT when these columns were added later, so
-- ticket.html / food-prebook.html (public ticket view, anon, select *)
-- and organiser-dashboard.html's main dashboard load + gate manual
-- check-in lookup (authenticated, select *) have all been broken by this
-- for as long as those columns have existed. Narrow explicit-column
-- selects elsewhere in the app were never affected, which is why this
-- went unnoticed.
--
-- Fix: grant SELECT on the specific missing columns each role actually
-- needs, rather than reopening the whole table - anon only gets
-- booker_name/booker_mobile back (both already rendered on the public
-- ticket page itself, so no new exposure - the booking UUID in the
-- ticket link is already the sole access control here); authenticated
-- (organiser login) gets all five internal/admin columns, since the
-- organiser logged into their own dashboard has no reason to be blocked
-- from seeing their own event's pass type, booking day, or manual-payment
-- audit trail.

grant select (booker_name, booker_mobile) on kh_bookings to anon;

grant select (pass_type_id, is_full_event, booking_day,
              manual_payment_confirmed_by, manual_payment_confirmed_at)
  on kh_bookings to authenticated;
