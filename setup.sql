-- ═══════════════════════════════════════════════════════════════
-- Khursilo Security Setup — Run once in Supabase SQL Editor
-- Dashboard → SQL Editor → New query → paste → Run
-- ═══════════════════════════════════════════════════════════════


-- ── 1. Admin session tokens table ──────────────────────────────
CREATE TABLE IF NOT EXISTS kh_admin_tokens (
  id         uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  token      text NOT NULL UNIQUE,
  created_at timestamptz DEFAULT now(),
  expires_at timestamptz NOT NULL
);

ALTER TABLE kh_admin_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin_token_select" ON kh_admin_tokens
  FOR SELECT USING (true);

CREATE POLICY "admin_token_insert" ON kh_admin_tokens
  FOR INSERT WITH CHECK (true);

CREATE POLICY "admin_token_delete" ON kh_admin_tokens
  FOR DELETE USING (true);

CREATE INDEX IF NOT EXISTS idx_admin_tokens_expires ON kh_admin_tokens (expires_at);


-- ── 2. Payment amount verification function ─────────────────────
CREATE OR REPLACE FUNCTION verify_booking_amount(p_event_id uuid, p_seat_keys text[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  price_map  jsonb;
  total      integer := 0;
  key        text;
  raw_price  text;
BEGIN
  SELECT seat_price_map INTO price_map
  FROM kh_events
  WHERE id = p_event_id;

  IF price_map IS NULL THEN
    RETURN 0;
  END IF;

  FOREACH key IN ARRAY p_seat_keys LOOP
    raw_price := price_map ->> key;
    IF raw_price IS NOT NULL AND raw_price <> 'X' AND raw_price ~ '^\d+$' THEN
      total := total + raw_price::integer;
    END IF;
  END LOOP;

  RETURN total;
END;
$$;

GRANT EXECUTE ON FUNCTION verify_booking_amount(uuid, text[]) TO anon;


-- ── 3. Row Level Security ───────────────────────────────────────
-- Strategy: allow SELECT/INSERT/UPDATE from anon (app uses anon key for all
-- operations). Block DELETE entirely — no app flow ever needs to delete rows.
-- This prevents bulk-deletion attacks even if the anon key is discovered.
--
-- Run each block; if a policy already exists the CREATE will error — that's
-- fine, just skip that line and continue.

-- kh_halls
ALTER TABLE kh_halls ENABLE ROW LEVEL SECURITY;

CREATE POLICY "halls_select" ON kh_halls
  FOR SELECT USING (true);

CREATE POLICY "halls_insert" ON kh_halls
  FOR INSERT WITH CHECK (true);

CREATE POLICY "halls_update" ON kh_halls
  FOR UPDATE USING (true) WITH CHECK (true);

-- No DELETE policy → anon cannot delete halls

-- kh_events
ALTER TABLE kh_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "events_select" ON kh_events
  FOR SELECT USING (true);

CREATE POLICY "events_insert" ON kh_events
  FOR INSERT WITH CHECK (true);

CREATE POLICY "events_update" ON kh_events
  FOR UPDATE USING (true) WITH CHECK (true);

-- No DELETE policy → anon cannot delete events

-- kh_bookings
ALTER TABLE kh_bookings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "bookings_select" ON kh_bookings
  FOR SELECT USING (true);

CREATE POLICY "bookings_insert" ON kh_bookings
  FOR INSERT WITH CHECK (true);

CREATE POLICY "bookings_update" ON kh_bookings
  FOR UPDATE USING (true) WITH CHECK (true);

-- No DELETE policy → anon cannot delete bookings

-- kh_organisers
ALTER TABLE kh_organisers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "organisers_select" ON kh_organisers
  FOR SELECT USING (true);

CREATE POLICY "organisers_insert" ON kh_organisers
  FOR INSERT WITH CHECK (true);

CREATE POLICY "organisers_update" ON kh_organisers
  FOR UPDATE USING (true) WITH CHECK (true);

-- No DELETE policy → anon cannot delete organisers


-- ── Done ────────────────────────────────────────────────────────
-- After running this:
-- • Admin login tokens are stored server-side
-- • Payment amounts verified server-side before Razorpay charges
-- • DELETE blocked on all 4 main tables — bulk-delete attacks prevented
-- • SELECT / INSERT / UPDATE work as before for the app
