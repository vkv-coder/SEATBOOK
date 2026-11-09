// Verifies a Razorpay payment server-side before confirming a paid
// kh_food_orders row - closes the free-food exploit: every food-ordering
// screen (booking.html inline/standalone, food-prebook.html, ticket.html)
// used to insert the order as status='confirmed' directly from the
// client the instant Razorpay's popup closed, with nothing double-
// checking that real money actually arrived. kh_food_orders_insert_
// lockdown.sql's trigger now blocks any client INSERT of a paid
// (total_amount>0) row as status='confirmed' - this function is the only
// path left for that transition, mirroring verify-razorpay-payment's
// design for kh_bookings.
//
// Known limitation: a food item can set its own "vendor_razorpay_key" (a
// separate Razorpay account from the organiser's), but only the
// organiser's own razorpay_key_secret is ever stored anywhere - there is
// no secret to look up for a *different* key. When vendor_razorpay_key is
// set and differs from the organiser's own key_id, this function can't
// call Razorpay to verify the payment and fails closed (503) rather than
// trusting the client. Properly supporting that needs a product decision
// (e.g. a vendor_razorpay_key_secret column + a dashboard field for it) -
// not done here.
//
// Deploy with:
//   supabase functions deploy verify-food-payment

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ ok: false, error: "Method not allowed" }, 405);
  }

  let body: {
    event_id?: string;
    booking_id?: string | null;
    booker_name?: string | null;
    booker_mobile?: string | null;
    quantity?: number;
    razorpay_payment_id?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }

  const {
    event_id,
    booking_id = null,
    booker_name = null,
    booker_mobile = null,
    quantity,
    razorpay_payment_id,
  } = body;
  if (!event_id || !quantity || quantity < 1 || !razorpay_payment_id) {
    return json({ ok: false, error: "event_id, quantity and razorpay_payment_id are required" }, 400);
  }

  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: foodItem, error: foodItemErr } = await supabaseAdmin
    .from("kh_food_items")
    .select("paid_item_name, paid_item_price, vendor_razorpay_key")
    .eq("event_id", event_id)
    .eq("is_active", true)
    .maybeSingle();
  if (foodItemErr || !foodItem) {
    return json({ ok: false, error: "Food item not found for this event" }, 404);
  }

  const expectedAmount = Math.round(Number(foodItem.paid_item_price) * Number(quantity));
  if (!expectedAmount || expectedAmount <= 0) {
    return json({ ok: false, error: "This food item is free - use the free-order flow instead" }, 400);
  }

  // Prevent replay: this exact Razorpay payment must not already be
  // attached to a different confirmed order.
  const { data: reused } = await supabaseAdmin
    .from("kh_food_orders")
    .select("id")
    .eq("razorpay_payment_id", razorpay_payment_id)
    .eq("status", "confirmed")
    .maybeSingle();
  if (reused) {
    return json({ ok: false, error: "This payment has already been used for a different food order" }, 409);
  }

  const { data: event, error: eventErr } = await supabaseAdmin
    .from("kh_events")
    .select("organiser_id")
    .eq("id", event_id)
    .maybeSingle();
  if (eventErr || !event) {
    return json({ ok: false, error: "Event not found" }, 404);
  }

  const { data: organiser, error: orgErr } = await supabaseAdmin
    .from("kh_organisers")
    .select("razorpay_key_id, razorpay_key_secret")
    .eq("id", event.organiser_id)
    .maybeSingle();
  if (orgErr || !organiser || !organiser.razorpay_key_id || !organiser.razorpay_key_secret) {
    return json({
      ok: false,
      error: "Payment verification is not configured for this organiser yet - food order cannot be confirmed until a Razorpay Key Secret is set in the organiser dashboard.",
    }, 503);
  }

  if (foodItem.vendor_razorpay_key && foodItem.vendor_razorpay_key !== organiser.razorpay_key_id) {
    // Separate vendor Razorpay account - no secret is stored for it
    // anywhere, so it can't be verified. Fail closed rather than trust
    // the client. See the comment at the top of this file.
    return json({
      ok: false,
      error: "This food item uses a separate vendor Razorpay account that isn't set up for server-side verification yet. Contact the organiser.",
    }, 503);
  }

  let payment: { status?: string; amount?: number };
  try {
    const auth = btoa(`${organiser.razorpay_key_id}:${organiser.razorpay_key_secret}`);
    const res = await fetch(`https://api.razorpay.com/v1/payments/${encodeURIComponent(razorpay_payment_id)}`, {
      headers: { Authorization: `Basic ${auth}` },
    });
    payment = await res.json();
    if (!res.ok) {
      return json({ ok: false, error: "Razorpay rejected the lookup", detail: payment }, 502);
    }
  } catch (e) {
    return json({ ok: false, error: "Could not reach Razorpay", detail: String(e) }, 502);
  }

  if (payment.status !== "captured") {
    return json({ ok: false, error: `Payment status is "${payment.status}", not captured` }, 402);
  }

  const expectedPaise = expectedAmount * 100;
  if (payment.amount !== expectedPaise) {
    return json({
      ok: false,
      error: `Amount mismatch: order expects ${expectedPaise} paise, payment was for ${payment.amount}`,
    }, 402);
  }

  const { data: order, error: insertErr } = await supabaseAdmin
    .from("kh_food_orders")
    .insert({
      event_id,
      booking_id,
      booker_name,
      booker_mobile,
      quantity,
      paid_item_name: foodItem.paid_item_name,
      free_item_name: null,
      amount_per_unit: foodItem.paid_item_price,
      total_amount: expectedAmount,
      razorpay_payment_id,
      status: "confirmed",
      created_at: new Date().toISOString(),
    })
    .select()
    .single();
  if (insertErr) {
    return json({ ok: false, error: insertErr.message }, 500);
  }

  return json({ ok: true, order });
});
