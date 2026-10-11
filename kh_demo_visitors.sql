-- Seatbook/Khursilo: log + notify visitor name+phone on each
-- "Try Demo Dashboard" click. Was previously a bare Telegram ping with no
-- visitor identity at all; now matches the derasar-boli/family-cash
-- demo-visitor pattern. Write-only from the client: anon/authenticated may
-- insert but never read/update/delete other visitors' rows.
create table if not exists kh_demo_visitors (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  phone      text not null,
  created_at timestamptz not null default now()
);

alter table kh_demo_visitors enable row level security;

drop policy if exists "Anyone can log a demo visit" on kh_demo_visitors;
create policy "Anyone can log a demo visit" on kh_demo_visitors
  for insert to anon, authenticated with check (true);

grant insert on kh_demo_visitors to anon, authenticated;
