-- organiser-dashboard.html and event-create.html both already had a proper,
-- separate per-organiser login (Supabase Auth email OTP/magic-link,
-- shouldCreateUser:false so only admin-added organisers can sign in) -
-- independent of the site-wide admin PIN. That system was mistakenly given
-- the same shared admin PIN gate as the true admin-only tool pages, which
-- would have required every organiser to know the internal site PIN just
-- to reach their own dashboard. The gate has been removed from both pages;
-- they rely purely on their own OTP login now.
--
-- kh_events and kh_organisers already had RLS policies scoping writes to
-- an organiser's own rows via auth.jwt()->>'email' - those were preserved
-- during the earlier RLS lockdown and are what now protects these pages'
-- writes, once the PIN gate stopped being the (wrong) enforcement point.
--
-- kh_food_items and kh_event_members had no such scoped policy - only the
-- wide-open one that was removed - so organiser-dashboard.html couldn't
-- write to them at all after that lockdown without a replacement. These
-- two policies add the same "only your own event's rows" scoping.

drop policy if exists organiser_manage_own_food_items on kh_food_items;
create policy organiser_manage_own_food_items on kh_food_items
for all to authenticated
using (event_id in (
  select id from kh_events where organiser_id = (
    select id from kh_organisers where email_1 = (auth.jwt()->>'email') limit 1
  )
))
with check (event_id in (
  select id from kh_events where organiser_id = (
    select id from kh_organisers where email_1 = (auth.jwt()->>'email') limit 1
  )
));

drop policy if exists organiser_manage_own_event_members on kh_event_members;
create policy organiser_manage_own_event_members on kh_event_members
for all to authenticated
using (event_id in (
  select id from kh_events where organiser_id = (
    select id from kh_organisers where email_1 = (auth.jwt()->>'email') limit 1
  )
))
with check (event_id in (
  select id from kh_events where organiser_id = (
    select id from kh_organisers where email_1 = (auth.jwt()->>'email') limit 1
  )
));

drop policy if exists organiser_manage_own_sections on kh_sections;
create policy organiser_manage_own_sections on kh_sections
for all to authenticated
using (event_id in (
  select id from kh_events where organiser_id = (
    select id from kh_organisers where email_1 = (auth.jwt()->>'email') limit 1
  )
))
with check (event_id in (
  select id from kh_events where organiser_id = (
    select id from kh_organisers where email_1 = (auth.jwt()->>'email') limit 1
  )
));

-- Also found while fixing this: razorpay_key_secret was only column-
-- restricted for anon earlier, not authenticated - meaning any logged-in
-- organiser could still read every OTHER organiser's Razorpay secret via
-- select=*, since row-level reads on kh_organisers are intentionally left
-- open (public organiser directory). Locking the column down for
-- authenticated too - it's write-only from the client, never read back
-- for display, so this doesn't break anything legitimate.
revoke select on kh_organisers from authenticated;
grant select (
  id, name, contact_1_name, contact_1_mobile, contact_2_name,
  contact_2_mobile, email_1, email_2, event_type, status,
  razorpay_key_id, created_at, hall_id
) on kh_organisers to authenticated;

-- Note: this column restriction means `select('*')` on kh_organisers now
-- fails outright for both anon and authenticated (Postgres denies the
-- whole query if the role lacks privilege on any referenced column, it
-- doesn't just omit it) - every select('*') on kh_organisers in the
-- codebase (organiser-dashboard.html, event-create.html) was changed to
-- an explicit column list excluding razorpay_key_secret.
