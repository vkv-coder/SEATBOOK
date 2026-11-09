-- Closes kh_food_orders' version of the same INSERT bypass fixed in
-- kh_bookings_insert_lockdown.sql, flagged as a known-open follow-up
-- since kh_bookings_payment_lockdown.sql (2026-07-28) and confirmed
-- still live by the 2026-11-09 daily audit. Every food-ordering screen
-- (booking.html's bookFoodInline/bookFoodStandalone, food-prebook.html,
-- ticket.html) used to insert the order as status='confirmed' directly
-- from the client the instant Razorpay's popup closed - a direct REST
-- call could just claim 'confirmed' with no payment at all.
--
-- Free food items (total_amount = 0, e.g. a complimentary item with no
-- paid component) are deliberately left untouched by this guard - those
-- screens already have a dedicated $0 branch that skips Razorpay
-- entirely, same philosophy as kh_bookings' free/complimentary/walk-in
-- tickets. Only a *paid* (total_amount > 0) row arriving pre-confirmed is
-- blocked.
--
-- The real fix (new verify-food-payment Edge Function, replacing the
-- direct insert in all 4 paid call sites) ships in the same change as
-- this migration - do not run this file without also deploying that
-- function and the updated HTML, or "Book Food & Pay" breaks for every
-- paid food item.

create or replace function kh_food_orders_guard_confirm_insert()
returns trigger
language plpgsql
security invoker
as $$
begin
  if new.status = 'confirmed' and coalesce(new.total_amount, 0) > 0
     and current_user <> 'service_role' then
    raise exception 'Food order confirmation must go through payment verification (verify-food-payment)';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_kh_food_orders_guard_confirm_insert on kh_food_orders;
create trigger trg_kh_food_orders_guard_confirm_insert
before insert on kh_food_orders
for each row
execute function kh_food_orders_guard_confirm_insert();
