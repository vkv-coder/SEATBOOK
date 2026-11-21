-- Scope kh_halls to the organiser they're allotted to, so event-create.html's
-- "Select hall" list only shows a venue that the admin has actually given
-- that organiser, instead of every hall in the shared database. Every
-- existing hall has only ever been used by a single organiser (verified via
-- kh_events.hall_id before writing this), so a single nullable owner column
-- is enough - no hall has genuinely been shared across organisers yet.

alter table kh_halls add column if not exists organiser_id uuid references kh_organisers(id);

-- Backfill: assign each existing hall to whichever organiser has actually
-- run events there, so nothing changes for their existing workflow.
update kh_halls set organiser_id = 'caa2bedc-af3c-4094-b04c-b125469e71d1' -- VIJAY VORA
where id in (
  'a8c78b53-c8fb-4e86-8687-25a0556d5ea2', -- CC Mehta Auditorium
  '2b5ca724-c8f1-42d5-9730-00229916618b', -- Dindayal Auditorium
  '6e4d80e5-1443-4e91-bf2a-485cc39c2058', -- Hemu Gadhvi Auditorium, Rajkot
  '5bde155b-4bf1-425b-b23d-7f2dc6e48a5a', -- Sayjirao Nagar Gruha
  'e17763ef-dda4-40e3-aef9-c41bcc93e7a3'  -- Vadodara Medical College Auditorium
);

update kh_halls set organiser_id = 'f0e85c38-13a7-4545-8b42-91401ef34342' -- Rainbow Events (Demo)
where id = 'cec0f858-6c5a-4835-bd49-48e816790ea4'; -- Demo Hall (Preview)

-- lokhandwala-events (745684fe-1e0f-46b7-9b51-73db479e34d2) gets no hall -
-- they'll only see "Open Selection" in event-create.html until the admin
-- allots or builds them a venue, by setting organiser_id on a kh_halls row.
