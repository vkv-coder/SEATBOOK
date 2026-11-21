-- Fixes "Cannot coerce the result to a single JSON object" on booking.html,
-- confirmed via a live anon-key REST call to be a genuine RLS mismatch, not
-- something introduced by recent changes.
--
-- event-create.html's publishEvent() has always written status='active' for
-- a bookable event, and organiser-dashboard.html's Open/Close booking toggle
-- flips between 'active' and 'closed' - that's the app's one and only
-- status convention for "is this event publicly bookable". But every
-- anon-facing SELECT policy on kh_events only allows status IN
-- ('live','published') - values nothing in this app has ever written. Four
-- near-duplicate policies all carry the same wrong values, presumably
-- accumulated across separate hardening passes that assumed a status
-- convention the app doesn't use. Net effect: no event created through
-- event-create.html has ever actually been visible to a real anon
-- customer via its public booking link - this just happened to be the
-- first time anyone tested a fresh 'active' event's link end-to-end
-- instead of relying on an already-privileged session.
--
-- Fix: add 'active' to each policy's allowed status list. Deliberately not
-- consolidating the four overlapping policies into one - that's a
-- separate cleanup, not needed to fix the actual bug, and touching more
-- than necessary here risks a new regression in a different direction.

alter policy "Public can read live events" on kh_events
  using (status = any (array['live','active']));

alter policy "Public can read published and live events" on kh_events
  using (status = any (array['published','live','active']));

alter policy "Public can view live events" on kh_events
  using (status = any (array['live','active']));

alter policy "events_public_read_live" on kh_events
  using (status = any (array['live','active']));
