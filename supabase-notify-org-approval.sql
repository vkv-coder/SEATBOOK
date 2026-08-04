-- Emails the organiser when their kh_organisers.status flips to active
-- (admin.html's toggleOrgStatus sets 'ACTIVE'/'suspended' - matched
-- case-insensitively here since the existing frontend code is inconsistent
-- about casing). Previously nothing emailed the organiser on approval at
-- all. Same pattern as derasar-boli/DealLagi/reminder/etc — shared
-- Cloudflare Worker email relay (telegram-notify.unigoods2026.workers.dev,
-- action:"sendEmail"), no new API key/secret needed.

create or replace function kh_notify_org_approval() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(NEW.status) = 'active' and lower(coalesce(OLD.status,'')) <> 'active' then
    if NEW.email_1 is not null then
      perform net.http_post(
        url := 'https://telegram-notify.unigoods2026.workers.dev/',
        headers := '{"Content-Type":"application/json"}'::jsonb,
        body := jsonb_build_object(
          'action', 'sendEmail',
          'to', NEW.email_1,
          'fromName', 'Khursilo',
          'subject', 'Your Khursilo organiser account is approved',
          'html', '<p>Hi ' || coalesce(NEW.contact_1_name,'') || ',</p>'
            || '<p>Your organisation <b>' || coalesce(NEW.name,'') || '</b> has been approved on Khursilo. You can now log in and start selling tickets:</p>'
            || '<p><a href="https://khursilo.in" style="background:#1A6BFF;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:600;display:inline-block;">Go to Organiser Dashboard</a></p>'
            || '<p style="font-size:13px;color:#666;">Questions? Contact vkvcoder.support@gmail.com</p>'
        )
      );
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists kh_organisers_notify_approval on kh_organisers;
create trigger kh_organisers_notify_approval
after update on kh_organisers
for each row execute function kh_notify_org_approval();
