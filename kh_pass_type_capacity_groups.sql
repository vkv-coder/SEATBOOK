-- Adds an optional SHARED capacity pool across multiple kh_open_pass_types
-- rows on the same event (e.g. "Section 1 / 2 / 3" together capped at 400
-- combined, while "Terrace" has its own separate 400) - the existing
-- capacity trigger (kh_booking_integrity_migration.sql) only ever enforced
-- max_per_day independently per pass type, with no notion of a shared pool.
--
-- Design: capacity_group is just a free-text key the organiser-side tooling
-- sets identically on every pass type meant to share a pool, plus
-- group_max_per_day repeated on each of those rows (denormalized rather
-- than a separate groups table, since the only writer is trusted
-- organiser-facing tooling, not arbitrary user input). NULL group =
-- unchanged, independent per-pass-type behaviour - every existing pass
-- type across every organiser keeps working exactly as before.

alter table kh_open_pass_types add column if not exists capacity_group text;
alter table kh_open_pass_types add column if not exists group_max_per_day integer;

create or replace function kh_bookings_guard_pass_capacity()
returns trigger
language plpgsql
security invoker
as $$
declare
  v_max        integer;
  v_group      text;
  v_group_max  integer;
  v_from       date;
  v_to         date;
  v_days       date[];
  d            date;
  v_sold       integer;
  v_group_sold integer;
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

  select max_per_day, capacity_group, group_max_per_day
    into v_max, v_group, v_group_max
    from kh_open_pass_types where id = new.pass_type_id;
  if v_max is null then
    raise exception 'Unknown pass type';
  end if;

  -- Lock on the group key when there is one, so two different pass types
  -- in the same group can't race each other past the shared cap - locking
  -- only on new.pass_type_id (as before) would let Section 1 and Section 2
  -- both pass their own check concurrently and jointly blow past 400.
  perform pg_advisory_xact_lock(hashtext(coalesce(v_group, new.pass_type_id::text)));

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

    if v_group is not null then
      -- Sum every sibling pass type's sold_count in the same group for
      -- this day (locking the underlying rows first, then aggregating -
      -- FOR UPDATE can't sit directly on an aggregate query in Postgres).
      select coalesce(sum(locked.sold_count), 0) into v_group_sold
      from (
        select s.sold_count
        from kh_open_pass_sold s
        join kh_open_pass_types pt on pt.id = s.pass_type_id
        where pt.capacity_group = v_group and pt.event_id = new.event_id and s.event_day = d
        for update of s
      ) locked;

      if v_group_sold + new.seat_count > v_group_max then
        raise exception 'PASS_SOLD_OUT: no passes left for % on %', v_group, d;
      end if;
    else
      if v_sold + new.seat_count > v_max then
        raise exception 'PASS_SOLD_OUT: no passes left for % on %', new.pass_type_id, d;
      end if;
    end if;
  end loop;

  update kh_open_pass_sold
  set sold_count = sold_count + new.seat_count
  where pass_type_id = new.pass_type_id and event_day = any(v_days);

  return new;
end;
$$;
-- Trigger already points at this function by name - CREATE OR REPLACE on
-- the body is enough, no need to touch trg_kh_bookings_guard_pass_capacity.
