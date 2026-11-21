-- Lets an organiser add unlimited co-admins to their own account, self-
-- serve, instead of asking the app admin to add a second login email each
-- time. Previously kh_organisers only supported email_1 + email_2 (a hard
-- cap of 2 logins), and nothing let an organiser set even that second one
-- themselves - only direct SQL by the app admin could.
--
-- No direct anon/authenticated grants on the team table itself - every
-- read/write goes through a SECURITY DEFINER RPC that re-derives the
-- caller's organiser from their own JWT email, matching every other
-- privileged write in this app (kh_organiser_confirm_manual_payment,
-- kh_organiser_set_scan, etc.) rather than relying on RLS policies here.

create table if not exists kh_organiser_team (
  id uuid primary key default gen_random_uuid(),
  organiser_id uuid not null references kh_organisers(id) on delete cascade,
  email text not null,
  name text,
  added_at timestamptz not null default now(),
  unique (organiser_id, email)
);

revoke all on kh_organiser_team from anon, authenticated;

-- Single lookup every organiser-facing login page now calls instead of
-- hand-rolling "try email_1, then try email_2" - also covers team members.
-- Explicit column list (not `select o.*`) so razorpay_key_secret can never
-- end up in a client response.
--
-- Priority ordering is not optional here: confirmed live that
-- vorabits@gmail.com is simultaneously email_1 on lokhandwala-events AND
-- email_2 on the VIJAY VORA account, so a plain OR with no ordering could
-- have non-deterministically resolved a login to the wrong organiser
-- entirely. Preserves the original per-page code's sequential "check
-- email_1 everywhere first, only then fall back to email_2" behaviour,
-- with team membership as the lowest-priority tiebreak.
create or replace function public.kh_resolve_organiser_login(p_email text)
returns table(
  id uuid, name text, contact_1_name text, contact_1_mobile text,
  contact_2_name text, contact_2_mobile text, email_1 text, email_2 text,
  event_type text, status text, razorpay_key_id text, created_at timestamptz, hall_id uuid
)
language sql
security definer
set search_path to 'public'
as $$
  select o.id, o.name, o.contact_1_name, o.contact_1_mobile,
         o.contact_2_name, o.contact_2_mobile, o.email_1, o.email_2,
         o.event_type, o.status, o.razorpay_key_id, o.created_at, o.hall_id
  from kh_organisers o
  left join kh_organiser_team t on t.organiser_id = o.id and lower(t.email) = lower(p_email)
  where lower(o.email_1) = lower(p_email)
     or lower(o.email_2) = lower(p_email)
     or t.id is not null
  order by case when lower(o.email_1) = lower(p_email) then 0
                when lower(o.email_2) = lower(p_email) then 1
                else 2 end
  limit 1;
$$;

revoke all on function public.kh_resolve_organiser_login(text) from public;
grant execute on function public.kh_resolve_organiser_login(text) to anon, authenticated;

-- Helper used by all three RPCs below: resolve the calling organiser's id
-- from their own JWT email, checking email_1/email_2 and existing team
-- membership - so an added team member can also add/remove further
-- teammates, not just the original founder email. Same priority-ordering
-- reasoning as kh_resolve_organiser_login above.
create or replace function public._kh_caller_organiser_id()
returns uuid
language sql
security definer
set search_path to 'public'
as $$
  select o.id
  from kh_organisers o
  left join kh_organiser_team t on t.organiser_id = o.id and lower(t.email) = lower(auth.jwt()->>'email')
  where lower(o.email_1) = lower(auth.jwt()->>'email')
     or lower(o.email_2) = lower(auth.jwt()->>'email')
     or t.id is not null
  order by case when lower(o.email_1) = lower(auth.jwt()->>'email') then 0
                when lower(o.email_2) = lower(auth.jwt()->>'email') then 1
                else 2 end
  limit 1;
$$;

revoke all on function public._kh_caller_organiser_id() from public;

create or replace function public.kh_organiser_add_team_member(p_email text, p_name text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_organiser_id uuid := public._kh_caller_organiser_id();
begin
  if v_organiser_id is null then
    return jsonb_build_object('ok', false, 'message', 'Not recognised as an organiser.');
  end if;
  if p_email is null or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid email address.');
  end if;
  if exists(
    select 1 from kh_organisers o where o.id = v_organiser_id
      and (lower(o.email_1) = lower(p_email) or lower(o.email_2) = lower(p_email))
  ) then
    return jsonb_build_object('ok', false, 'message', 'That email is already the primary login for this account.');
  end if;

  insert into kh_organiser_team(organiser_id, email, name)
  values (v_organiser_id, lower(p_email), nullif(trim(p_name), ''))
  on conflict (organiser_id, email) do nothing;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.kh_organiser_add_team_member(text,text) from public;
grant execute on function public.kh_organiser_add_team_member(text,text) to authenticated;

create or replace function public.kh_organiser_remove_team_member(p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_caller_org_id uuid := public._kh_caller_organiser_id();
  v_target_org_id uuid;
begin
  select organiser_id into v_target_org_id from kh_organiser_team where id = p_member_id;
  if v_target_org_id is null then
    return jsonb_build_object('ok', false, 'message', 'Member not found.');
  end if;
  if v_caller_org_id is null or v_caller_org_id <> v_target_org_id then
    return jsonb_build_object('ok', false, 'message', 'Not authorised.');
  end if;

  delete from kh_organiser_team where id = p_member_id;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.kh_organiser_remove_team_member(uuid) from public;
grant execute on function public.kh_organiser_remove_team_member(uuid) to authenticated;

create or replace function public.kh_organiser_list_team_members()
returns table(id uuid, email text, name text, added_at timestamptz)
language sql
security definer
set search_path to 'public'
as $$
  select t.id, t.email, t.name, t.added_at
  from kh_organiser_team t
  where t.organiser_id = public._kh_caller_organiser_id()
  order by t.added_at;
$$;

revoke all on function public.kh_organiser_list_team_members() from public;
grant execute on function public.kh_organiser_list_team_members() to authenticated;
