-- Lightweight "common code" gate for private events (e.g. a residential
-- society's members-only talk) - stops casual/accidental visitors who
-- land on khursilo.in or a forwarded link from booking without the code
-- the organiser shared, without the bigger rework of a full per-member
-- verification system. Deliberately scoped to this threat model (casual
-- discovery, not a determined attacker) - a single shared code, not
-- per-person.
--
-- access_code itself must NEVER be sent to the browser as part of the
-- normal event row (booking.html's loadEvent() used to do a blanket
-- select('*') - if that continued, the code would sit in eventData in
-- the browser's own already-fetched JSON, readable via dev tools with
-- zero effort, defeating the gate entirely). access_code_required is a
-- generated boolean, safe to expose, so the client knows whether to show
-- the gate without ever seeing the code - the actual check happens via
-- the RPC below.

alter table kh_events add column if not exists access_code text;
alter table kh_events add column if not exists access_code_required boolean generated always as (access_code is not null) stored;

create or replace function public.kh_verify_event_access_code(p_event_id uuid, p_code text)
returns boolean
language sql
security definer
set search_path to 'public'
as $$
  select exists(
    select 1 from kh_events
    where id = p_event_id
      and access_code is not null
      and lower(trim(access_code)) = lower(trim(coalesce(p_code,'')))
  );
$$;

revoke all on function public.kh_verify_event_access_code(uuid,text) from public;
grant execute on function public.kh_verify_event_access_code(uuid,text) to anon, authenticated;
