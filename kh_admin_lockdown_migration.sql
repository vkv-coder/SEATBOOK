-- Locks down anon write access on tables that have no legitimate anonymous
-- customer write path (only admin/organiser tools write to them, and those
-- are now behind the PIN gate + kh-admin-auth Edge Function's 'write'
-- action). Tables with real anonymous customer writes (kh_bookings,
-- kh_food_orders, kh_attendance) are intentionally untouched here - see
-- the note on payment verification below.

-- ---------- kh_organisers ----------
-- Remove the wide-open write policies; keep the JWT-scoped self-service ones
-- (organisers_update_own, "Organisers can update own profile").
drop policy if exists "organisers_insert" on kh_organisers;
drop policy if exists "organisers_update" on kh_organisers;
revoke insert, update, delete on kh_organisers from anon;

-- razorpay_key_secret must never be anon-readable, even though it's null
-- today - the column is there to be populated. Column-level REVOKE alone
-- doesn't work while the table-level grant exists, so: revoke table-level
-- SELECT, then re-grant only the columns meant to be public.
revoke select on kh_organisers from anon;
grant select (
  id, name, contact_1_name, contact_1_mobile, contact_2_name,
  contact_2_mobile, email_1, email_2, event_type, status,
  razorpay_key_id, created_at, hall_id
) on kh_organisers to anon;

-- ---------- kh_events ----------
-- Remove the wide-open write policies; keep the JWT-scoped organiser ones.
drop policy if exists "events_insert" on kh_events;
drop policy if exists "events_update" on kh_events;
revoke insert, update, delete on kh_events from anon;

-- ---------- kh_halls ----------
-- No legitimate anonymous write path exists at all; fully proxy-only now.
drop policy if exists "Admin can insert halls" on kh_halls;
drop policy if exists "halls_insert" on kh_halls;
drop policy if exists "Admin can update halls" on kh_halls;
drop policy if exists "halls_update" on kh_halls;
revoke insert, update, delete on kh_halls from anon;

-- ---------- kh_food_items ----------
drop policy if exists "Anon delete food items" on kh_food_items;
drop policy if exists "Anon insert food items" on kh_food_items;
drop policy if exists "Anon update food items" on kh_food_items;
revoke insert, update, delete on kh_food_items from anon;

-- ---------- kh_sections, kh_event_members ----------
-- These already had no permissive write policy (writes were already
-- RLS-denied for anon); revoking the grant too just for consistency/
-- defense-in-depth. Their writes now go through kh-admin-auth's write action.
revoke insert, update, delete on kh_sections from anon;
revoke insert, update, delete on kh_event_members from anon;

-- ---------- kh_seats, kh_seat_holds ----------
-- Confirmed unreferenced by any current frontend code - fully lock down.
drop policy if exists "Public can update seat status" on kh_seats;
drop policy if exists "anon_read_seats" on kh_seats;
drop policy if exists "Public can read seats" on kh_seats;
revoke all on kh_seats from anon;

drop policy if exists "Public can create seat holds" on kh_seat_holds;
drop policy if exists "anon_all_seat_holds" on kh_seat_holds;
drop policy if exists "Public can read seat holds" on kh_seat_holds;
drop policy if exists "Public can delete expired holds" on kh_seat_holds;
revoke all on kh_seat_holds from anon;

-- ---------- kh_refunds ----------
-- Remove only the wide-open catch-all; keep the organiser-JWT-scoped
-- read/create policies in case another part of the platform depends on them.
drop policy if exists "anon_all_refunds" on kh_refunds;
revoke insert, update, delete on kh_refunds from anon;

-- ---------- kh_admin_tokens ----------
-- Was directly readable/writable by anon, letting anyone forge a valid
-- admin session without the PIN. All access now goes through
-- kh-admin-auth (login/verify/logout actions), using service_role.
-- (Policies already dropped in a separate migration step - included here
-- for a complete record of what changed.)
-- drop policy admin_token_delete on kh_admin_tokens;
-- drop policy admin_token_insert on kh_admin_tokens;
-- drop policy admin_token_select on kh_admin_tokens;

-- ---------- NOT fixed here: payment verification ----------
-- booking.html's handlePaymentSuccess() trusts the client's word that
-- Razorpay payment succeeded (UPDATE ... SET status='confirmed',
-- payment_status='paid' with no server-side verification), and kh_bookings
-- SELECT is open, so any booking id is discoverable. This is a distinct,
-- separate issue from the admin-write lockdown above - it needs a
-- Razorpay webhook verified server-side (signature check + Edge Function),
-- not an RLS change, since real anonymous customers legitimately need to
-- write to kh_bookings during checkout.
