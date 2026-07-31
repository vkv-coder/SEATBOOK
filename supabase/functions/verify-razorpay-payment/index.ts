// Verifies a Razorpay payment server-side before confirming a kh_bookings
// row, closing a free-ticket exploit: the checkout flow (booking.html) uses
// Razorpay's simple "amount + key" mode with no Orders API, so there's no
// signature to check - previously the client just told the database
// "payment succeeded" directly (status='confirmed', payment_status='paid'),
// and kh_bookings SELECT is open, so any booking id was discoverable and
// fakeable via a direct API call, no real payment required.
//
// This calls Razorpay's Payments API (GET /v1/payments/{id}) using the
// organiser's key_secret to check the payment genuinely exists, was
// captured, and the amount matches - then performs the confirmation
// itself via service_role. RLS on kh_bookings now blocks the client from
// setting status='confirmed' + payment_status='paid' directly (see
// kh_bookings_payment_lockdown.sql), so this is the only path left.
//
// Deploy with:
//   supabase functions deploy verify-razorpay-payment

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
    return json({ error: "Method not allowed" }, 405);
  }

  let body: { booking_id?: string; razorpay_payment_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }

  const { booking_id, razorpay_payment_id } = body;
  if (!booking_id || !razorpay_payment_id) {
    return json({ ok: false, error: "booking_id and razorpay_payment_id required" }, 400);
  }

  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: booking, error: bookingErr } = await supabaseAdmin
    .from("kh_bookings")
    .select("id, event_id, amount, status, payment_status, razorpay_payment_id")
    .eq("id", booking_id)
    .maybeSingle();
  if (bookingErr || !booking) {
    return json({ ok: false, error: "Booking not found" }, 404);
  }
  if (booking.status === "confirmed" && booking.payment_status === "paid") {
    // Already confirmed (e.g. a retry) - nothing to do, not an error.
    return json({ ok: true, already: true });
  }

  // Prevent replay: this exact Razorpay payment must not already be
  // attached to a different confirmed booking.
  const { data: reused } = await supabaseAdmin
    .from("kh_bookings")
    .select("id")
    .eq("razorpay_payment_id", razorpay_payment_id)
    .eq("status", "confirmed")
    .neq("id", booking_id)
    .maybeSingle();
  if (reused) {
    return json({ ok: false, error: "This payment has already been used for a different booking" }, 409);
  }

  const { data: event, error: eventErr } = await supabaseAdmin
    .from("kh_events")
    .select("organiser_id")
    .eq("id", booking.event_id)
    .maybeSingle();
  if (eventErr || !event) {
    return json({ ok: false, error: "Event not found for this booking" }, 404);
  }

  const { data: organiser, error: orgErr } = await supabaseAdmin
    .from("kh_organisers")
    .select("razorpay_key_id, razorpay_key_secret")
    .eq("id", event.organiser_id)
    .maybeSingle();
  if (orgErr || !organiser) {
    return json({ ok: false, error: "Organiser not found for this event" }, 404);
  }
  if (!organiser.razorpay_key_id || !organiser.razorpay_key_secret) {
    return json({
      ok: false,
      error: "Payment verification is not configured for this organiser yet (Razorpay Key Secret missing) - booking cannot be confirmed until it is set in the organiser dashboard.",
    }, 503);
  }

  let payment: { status?: string; amount?: number; error?: unknown };
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

  const expectedPaise = Math.round(Number(booking.amount) * 100);
  if (payment.amount !== expectedPaise) {
    return json({
      ok: false,
      error: `Amount mismatch: booking expects ${expectedPaise} paise, payment was for ${payment.amount}`,
    }, 402);
  }

  const { error: updateErr } = await supabaseAdmin
    .from("kh_bookings")
    .update({ status: "confirmed", payment_status: "paid", razorpay_payment_id })
    .eq("id", booking_id);
  if (updateErr) {
    return json({ ok: false, error: updateErr.message }, 500);
  }

  return json({ ok: true });
});
