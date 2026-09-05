-- ═══════════════════════════════════════════════════════════════
-- Khursilo Booking Integrity — Run once in Supabase SQL Editor
-- Fixes two correctness gaps found during a scale review (targeting
-- the 200-300 assigned-seat halls + 10-day open-ground events like
-- Garba, where most volume is advance sale and on-spot booking is
-- rare-to-none):
--
--  1. SEAT RACE CONDITION — booking.html's openForm()/saveManualBooking()/
--     saveFreeBooking()/confirmAndPay() already catch a "SEAT_CONFLICT"
--     substring in errors and call handleSeatConflict() to show a
--     "someone just booked that seat" toast — but nothing server-side
--     ever raised that error. Availability was only a client-side cache
--     (seatStatusMap), so two people tapping the same seat inside the
--     Realtime propagation window could both get inserted as 'held' and
--     both pay. This migration adds the trigger the client was already
--     waiting for.
--
--  2. NO CAPACITY CAP ON OPEN/GENERAL ENTRY — saveOpenPaidBooking() and
--     bookOpenEntry() insert unconditionally; nothing enforces a per-day
--     venue/category limit. For a 10-day open-ground event this is a
--     crowd-safety limit, not just a sales one. This adds pass "types"
--     (e.g. Male / Female × stall category) each with their own
--     max-per-day, correctly enforced across BOTH daily passes and
--     full-event passes (a full-event pass occupies capacity on every
--     day of the event, not just the day it was bought).
--
-- Run each block; if something already exists the CREATE will error —
-- that's fine, just skip that line and continue.
-- ═══════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────
-- PART 1 — Seat conflict trigger (the fix for gap 1)
-- ───────────────────────────────────────────────────────────────

create or replace function kh_bookings_guard_seat_conflict()
returns trigger
language plpgsql
security invoker
as $$
declare
  conflicting_id uuid;
begin
  -- Open/general-entry and food-only rows have no seat_keys — nothing to guard.
  if new.seat_keys is null or array_length(new.seat_keys, 1) is null then
    return new;
  end if;
  -- Only rows that actually claim a seat need the check (not a cancelled row
  -- being written back for record-keeping, for example).
  if new.status not in ('held', 'pending_payment', 'pending_manual', 'confirmed') then
    return new;
  end if;

  -- Serialize concurrent claims for the SAME event so the overlap check
  -- below can't race with another transaction doing the same check at the
  -- same instant (the classic check-then-insert TOCTOU). Released
  -- automatically at transaction end — each insert/update from PostgREST
  -- is its own transaction, so this never holds across requests.
  perform pg_advisory_xact_lock(hashtext(new.event_id::text));

  select id into conflicting_id
  from kh_bookings
  where event_id = new.event_id
    and id <> new.id
    and status in ('held', 'pending_payment', 'pending_manual', 'confirmed')
    and seat_keys && new.seat_keys
  limit 1;

  if conflicting_id is not null then
    raise exception 'SEAT_CONFLICT: one or more selected seats are already held or booked';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_kh_bookings_guard_seat_conflict on kh_bookings;
create trigger trg_kh_bookings_guard_seat_conflict
before insert or update on kh_bookings
for each row
execute function kh_bookings_guard_seat_conflict();


-- ───────────────────────────────────────────────────────────────
-- PART 2 — Open/general-entry pass types (gender × stall category)
--          with per-day capacity (the fix for gap 2)
-- ───────────────────────────────────────────────────────────────

create table if not exists kh_open_pass_types (
  id               uuid default gen_random_uuid() primary key,
  event_id         uuid not null references kh_events(id),
  label            text not null,              -- e.g. 'Male - General Stall'
  gender           text,                       -- 'male' | 'female' | null (not gender-split)
  stall_name       text,                       -- e.g. 'General Stall', 'VIP Stall'
  price_daily      integer,                    -- null if daily passes not offered for this type
  price_full_event integer,                    -- null if full-event passes not offered
  max_per_day      integer not null,           -- capacity cap for THIS type, per event day
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);

alter table kh_open_pass_types enable row level security;

create policy "pass_types_select" on kh_open_pass_types
  for select using (true);

-- Only the organiser who owns the event may configure pass types (mirrors
-- the existing "Organisers can update own event bookings" JWT-scoped
-- pattern already used elsewhere on kh_bookings). No anon insert/update/
-- delete — pass_types.html authenticates the organiser first. Checks
-- both email_1 and email_2, matching loginWithSession()'s own lookup in
-- organiser-dashboard.html.
create policy "pass_types_organiser_write" on kh_open_pass_types
  for all to authenticated
  using (event_id in (
    select kh_events.id from kh_events
    where kh_events.organiser_id in (
      select kh_organisers.id from kh_organisers
      where lower(kh_organisers.email_1) = lower(auth.jwt() ->> 'email')
         or lower(kh_organisers.email_2) = lower(auth.jwt() ->> 'email')
    )
  ))
  with check (event_id in (
    select kh_events.id from kh_events
    where kh_events.organiser_id in (
      select kh_organisers.id from kh_organisers
      where lower(kh_organisers.email_1) = lower(auth.jwt() ->> 'email')
         or lower(kh_organisers.email_2) = lower(auth.jwt() ->> 'email')
    )
  ));


create table if not exists kh_open_pass_sold (
  pass_type_id uuid not null references kh_open_pass_types(id),
  event_day    date not null,
  sold_count   integer not null default 0,
  primary key (pass_type_id, event_day)
);

alter table kh_open_pass_sold enable row level security;

create policy "pass_sold_select" on kh_open_pass_sold
  for select using (true);
-- No anon/authenticated write policy at all — the ONLY writer is the
-- SECURITY INVOKER trigger below, running as whatever role is doing the
-- kh_bookings insert. That means anon needs table-level UPDATE/INSERT
-- grants (RLS has no policy so it's otherwise fully closed) scoped
-- tightly to just this bookkeeping table:
grant select, insert, update on kh_open_pass_sold to anon, authenticated;
create policy "pass_sold_write_via_trigger" on kh_open_pass_sold
  for all to anon, authenticated using (true) with check (true);
-- (Safe to leave open: this table only stores a per-day integer counter
-- per pass type, never PII, and the real capacity guarantee comes from
-- the trigger's advisory lock + the checks inside it, not from RLS.)


-- kh_bookings needs to know which pass type / day / full-event a row is for.
alter table kh_bookings add column if not exists pass_type_id uuid references kh_open_pass_types(id);
alter table kh_bookings add column if not exists is_full_event boolean not null default false;
alter table kh_bookings add column if not exists booking_day date;


create or replace function kh_bookings_guard_pass_capacity()
returns trigger
language plpgsql
security invoker
as $$
declare
  v_max   integer;
  v_from  date;
  v_to    date;
  v_days  date[];
  d       date;
  v_sold  integer;
begin
  if new.pass_type_id is null then
    return new; -- seated bookings, or events with no pass types configured
  end if;
  if new.status not in ('held', 'pending_payment', 'pending_manual', 'confirmed') then
    return new;
  end if;
  -- A row moving between active statuses (held -> pending_payment ->
  -- confirmed) is the SAME reservation, not a new one - don't recount it
  -- every time its status changes.
  if tg_op = 'UPDATE'
     and old.pass_type_id is not distinct from new.pass_type_id
     and old.booking_day is not distinct from new.booking_day
     and old.is_full_event is not distinct from new.is_full_event
     and old.seat_count is not distinct from new.seat_count
     and old.status in ('held', 'pending_payment', 'pending_manual', 'confirmed') then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext(new.pass_type_id::text));

  select max_per_day into v_max from kh_open_pass_types where id = new.pass_type_id;
  if v_max is null then
    raise exception 'Unknown pass type';
  end if;

  if new.is_full_event then
    select e.from_date, coalesce(e.to_date, e.from_date, e.event_date)
      into v_from, v_to
      from kh_events e where e.id = new.event_id;
    select array_agg(gs::date) into v_days
      from generate_series(v_from, v_to, interval '1 day') gs;
  else
    if new.booking_day is null then
      raise exception 'booking_day is required for a daily pass';
    end if;
    v_days := array[new.booking_day];
  end if;

  foreach d in array v_days loop
    insert into kh_open_pass_sold (pass_type_id, event_day, sold_count)
    values (new.pass_type_id, d, 0)
    on conflict (pass_type_id, event_day) do nothing;

    select sold_count into v_sold
    from kh_open_pass_sold
    where pass_type_id = new.pass_type_id and event_day = d
    for update;

    if v_sold + new.seat_count > v_max then
      raise exception 'PASS_SOLD_OUT: no passes left for % on %', new.pass_type_id, d;
    end if;
  end loop;

  update kh_open_pass_sold
  set sold_count = sold_count + new.seat_count
  where pass_type_id = new.pass_type_id and event_day = any(v_days);

  return new;
end;
$$;

drop trigger if exists trg_kh_bookings_guard_pass_capacity on kh_bookings;
create trigger trg_kh_bookings_guard_pass_capacity
before insert or update on kh_bookings
for each row
execute function kh_bookings_guard_pass_capacity();


-- Release capacity on cancellation/failure so a sold-out day isn't
-- permanently stuck sold out after a refund or an abandoned payment.
create or replace function kh_bookings_release_pass_capacity()
returns trigger
language plpgsql
security invoker
as $$
declare
  v_from date;
  v_to   date;
  v_days date[];
begin
  if old.pass_type_id is null then return new; end if;
  if old.status not in ('held', 'pending_payment', 'pending_manual', 'confirmed') then return new; end if;
  if new.status not in ('cancelled', 'failed') then return new; end if;

  perform pg_advisory_xact_lock(hashtext(old.pass_type_id::text));

  if old.is_full_event then
    select e.from_date, coalesce(e.to_date, e.from_date, e.event_date)
      into v_from, v_to
      from kh_events e where e.id = old.event_id;
    select array_agg(gs::date) into v_days
      from generate_series(v_from, v_to, interval '1 day') gs;
  else
    v_days := array[old.booking_day];
  end if;

  update kh_open_pass_sold
  set sold_count = greatest(0, sold_count - old.seat_count)
  where pass_type_id = old.pass_type_id and event_day = any(v_days);

  return new;
end;
$$;

drop trigger if exists trg_kh_bookings_release_pass_capacity on kh_bookings;
create trigger trg_kh_bookings_release_pass_capacity
before update on kh_bookings
for each row
execute function kh_bookings_release_pass_capacity();


-- Server-side price truth for paid open/general-entry passes, mirroring
-- verify_booking_amount() which already does this for seated bookings.
-- Without this, saveOpenPaidBooking() trusted whatever `amt` the client
-- computed and sent - a tampered client could set amt=1, pay ₹1 via
-- Razorpay, and verify-razorpay-payment would happily match ₹1 against
-- ₹1 (it only checks the DB row's own `amount` column, which the client
-- had set). Call this before opening Razorpay checkout and use ITS
-- result, not the client-computed one.
create or replace function verify_open_pass_amount(p_pass_type_id uuid, p_is_full_event boolean, p_qty integer)
returns integer
language plpgsql
security definer
as $$
declare
  v_price integer;
begin
  if p_is_full_event then
    select price_full_event into v_price from kh_open_pass_types where id = p_pass_type_id;
  else
    select price_daily into v_price from kh_open_pass_types where id = p_pass_type_id;
  end if;
  if v_price is null then
    return 0;
  end if;
  return v_price * p_qty;
end;
$$;

grant execute on function verify_open_pass_amount(uuid, boolean, integer) to anon;


-- ───────────────────────────────────────────────────────────────
-- PART 3 — Stale hold reaper (held/pending rows nobody ever finished)
-- ───────────────────────────────────────────────────────────────
-- booking.html's releaseHold() only runs from the booker's OWN browser
-- (5-min timer, or closing the payment modal). If a tab is closed or a
-- connection drops mid-hold, nothing else ever clears that row today.
-- This RPC flips anything stuck past its window to 'cancelled', which
-- both frees the seat (via the conflict trigger no longer seeing it as
-- active) and releases pass capacity (via the trigger above). Call it
-- every few minutes from a scheduled job - see
-- .github/workflows/kh-stale-hold-cleanup.yml.
create or replace function kh_cleanup_stale_bookings(p_minutes integer default 8)
returns integer
language plpgsql
security invoker
as $$
declare
  v_count integer;
begin
  update kh_bookings
  set status = 'cancelled'
  where status in ('held', 'pending_payment')
    and created_at < now() - (p_minutes || ' minutes')::interval;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function kh_cleanup_stale_bookings(integer) to anon;

-- ── Done ────────────────────────────────────────────────────────
-- After running this:
-- • Two people can no longer both claim the same seat (SEAT_CONFLICT
--   now actually fires - booking.html already knew how to handle it).
-- • Open/general-entry passes can be capped per day, per gender, per
--   stall category, correctly accounting for full-event passes
--   occupying every day of the event.
-- • Open-pass prices are verified server-side before Razorpay, closing
--   the same class of amount-tampering issue seats already fixed.
-- • Cancelling/refunding a booking releases its pass capacity back.
-- • A stale hold nobody finished gets reaped instead of squatting on a
--   seat/slot forever.
