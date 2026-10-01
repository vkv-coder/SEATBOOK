-- ============================================================================
-- SEATBOOK — document removal of dormant anon grants
-- ============================================================================
-- Already applied directly against the live database. Committed here purely
-- as a record of what changed — safe to re-run, no-op if already revoked.
--
-- CONTEXT
--   A monthly Supabase RLS/RPC audit (2026-10) swept both Supabase projects
--   for tables where the `anon` role held a raw table GRANT (SELECT/INSERT/
--   UPDATE/DELETE) with no RLS policy actually covering that privilege for
--   anon. In Postgres, that combination is inert the moment it happens —
--   with RLS enabled and no matching policy, the role sees/affects zero
--   rows regardless of the grant. But it's a landmine: if a permissive
--   policy for anon/public is ever added later without someone checking
--   existing grants, the table becomes fully exposed with no further step
--   needed. Every instance below was confirmed dormant (live curl tests
--   with the anon key, before and after) before revoking.
-- ============================================================================

REVOKE DELETE ON public.kh_attendance FROM anon;
REVOKE DELETE ON public.kh_food_orders FROM anon;
REVOKE DELETE, INSERT, UPDATE ON public.kh_open_pass_types FROM anon;
REVOKE DELETE, INSERT, UPDATE ON public.kh_platform_fees FROM anon;
