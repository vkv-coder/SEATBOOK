// ══════════════════════════════════════════════════════════════
//  Khursilo — Booking Confirmation Email + Razorpay Webhook  v4
//  Google Apps Script Web App
//  Handles:
//    1. Supabase webhook (kh_bookings INSERT/UPDATE) → confirmation email
//    2. Razorpay webhook (payment.captured) → auto-confirm or auto-refund
//
//  SETUP STEPS:
//  1. Go to script.google.com → open your project
//  2. Select all → delete → paste this file
//  3. Project Settings (gear icon) → Script Properties → Add property:
//       key:   RAZORPAY_KEY_SECRET
//       value: your Razorpay live key_secret (from Razorpay Dashboard →
//              Settings → API Keys — regenerate it first if the old one
//              was ever committed to git, then use the new value here)
//  4. Save (Ctrl+S)
//  5. Deploy → Manage deployments → pencil → New version → Deploy
//  6. Same URL stays — no change needed anywhere else
//
//  The secret is read from Script Properties at runtime (see
//  RAZORPAY_KEY_SECRET below) — it must NEVER be hardcoded as a
//  constant in this file, since this repo is public on GitHub.
//
//  RAZORPAY WEBHOOK (one time setup):
//  1. Razorpay Dashboard → Settings → Webhooks → Add New Webhook
//  2. Webhook URL: paste your GAS web app URL (same one as Supabase)
//  3. Secret: leave blank or set any string (not used in verification)
//  4. Active Events: tick  payment.captured
//  5. Save
// ══════════════════════════════════════════════════════════════

const FROM_EMAIL    = 'tickets@khursilo.in';
const FROM_NAME     = 'Khursilo Tickets';
const SUPPORT_EMAIL = 'tickets@khursilo.in';
const BRAND_NAME    = 'Khursilo';
const BRAND_URL     = 'https://khursilo.in';

const SUPABASE_URL = 'https://jqqnnkzozjskziaizajg.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpxcW5ua3pvempza3ppYWl6YWpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI5Mjk1ODAsImV4cCI6MjA4ODUwNTU4MH0.sEYeWnm0dvuw8bLSVnQhqmgV8LB-pELjpuVIa3Us1Gg';

const RAZORPAY_KEY_ID = 'rzp_live_TMMa9UriEueeuD';
const RAZORPAY_KEY_SECRET = PropertiesService.getScriptProperties().getProperty('RAZORPAY_KEY_SECRET');

const ADMIN_EMAIL = 'unigoods2026@gmail.com';

// ── MAIN ROUTER ────────────────────────────────────────────────
function doPost(e) {
  try {
    const raw = e.postData ? e.postData.contents : '{}';
    const payload = JSON.parse(raw || '{}');

    // Razorpay webhooks have { event: 'payment.captured', ... }
    if (payload.event && payload.event.startsWith('payment.')) {
      handleRazorpayWebhook(payload);
      return ContentService.createTextOutput('ok');
    }

    // Otherwise it's a Supabase webhook
    return handleSupabaseWebhook(payload);

  } catch(err) {
    Logger.log('doPost error: ' + err.message);
    return ContentService.createTextOutput('error');
  }
}

// ── GET — health check ─────────────────────────────────────────
function doGet(e) {
  return jsonResponse({ status: 'Khursilo email service running ✅', from: FROM_EMAIL });
}

// ══════════════════════════════════════════════════════════════
//  SUPABASE WEBHOOK — confirmation email on booking confirmed
// ══════════════════════════════════════════════════════════════
function handleSupabaseWebhook(payload) {
  try {
    Logger.log('Supabase webhook: ' + JSON.stringify(payload).slice(0, 200));

    const record    = payload.record || payload;
    const oldRecord = payload.old_record || null;

    // For UPDATE: only proceed if status just changed TO confirmed
    if (payload.type === 'UPDATE') {
      const wasConfirmed = oldRecord && oldRecord.status === 'confirmed';
      const isConfirmed  = record.status === 'confirmed';
      if (!isConfirmed || wasConfirmed) {
        return jsonResponse({ success: false, reason: 'Status not newly confirmed — skipped' });
      }
    }

    // For INSERT: only process if already confirmed (free bookings)
    if (payload.type === 'INSERT' && record.status !== 'confirmed') {
      return jsonResponse({ success: false, reason: 'INSERT not confirmed — skipped' });
    }

    // Must have email
    if (!record.booker_email || !record.booker_email.includes('@')) {
      return jsonResponse({ success: false, reason: 'No email — skipped' });
    }

    // Demo bookings use fake @example.com addresses (RFC 2606 reserved — never
    // a real customer). Sending to them just hard-bounces back to tickets@khursilo.in
    // every night when the demo data resets, so skip them outright.
    if (/@example\.com$/i.test(record.booker_email.trim())) {
      return jsonResponse({ success: false, reason: 'Demo booking (example.com) — skipped' });
    }

    const eventData = fetchEvent(record.event_id);
    const orgData   = eventData ? fetchOrganiser(eventData.organiser_id) : null;

    const d = {
      to:              record.booker_email,
      bookerName:      record.booker_name    || '',
      eventName:       eventData ? eventData.name : 'Your Event',
      eventDate:       eventData ? formatDate(eventData.from_date || eventData.event_date, eventData.to_date) : '',
      hallName:        eventData ? fetchHallName(eventData.hall_id) : '',
      seats:           Array.isArray(record.seat_keys) ? record.seat_keys.join(', ') : 'Open Entry',
      amount:          record.amount > 0 ? '₹' + record.amount : 'Free',
      bookingId:       record.id            || '',
      bookedAt:        formatTimestamp(record.created_at),
      totalDays:       eventData ? computeDays(eventData.from_date || eventData.event_date, eventData.to_date) : 1,
      organiserName:   orgData ? (orgData.contact_1_name || orgData.name || '') : '',
      organiserEmail:  orgData ? (orgData.email_1 || '') : '',
      organiserMobile: orgData ? (orgData.contact_1_mobile || '') : '',
    };

    sendBookingEmail(d);

    GmailApp.sendEmail(ADMIN_EMAIL,
      '✅ Booking confirmed — ' + d.bookerName,
      'Booker: ' + d.bookerName + '\nSeats: ' + d.seats +
      '\nAmount: ' + d.amount + '\nEmail: ' + d.to +
      '\nBooking ID: ' + d.bookingId);

    return jsonResponse({ success: true, sentTo: d.to });

  } catch (err) {
    Logger.log('handleSupabaseWebhook error: ' + err.message);
    return jsonResponse({ success: false, error: err.message });
  }
}

// ══════════════════════════════════════════════════════════════
//  RAZORPAY WEBHOOK — auto-confirm or auto-refund
// ══════════════════════════════════════════════════════════════
function handleRazorpayWebhook(data) {
  try {
    const entity          = data.payload.payment.entity;
    const paymentId       = entity.id;
    const amountPaise     = entity.amount;
    const amountRs        = amountPaise / 100;
    const notes           = entity.notes || {};
    const bookingIdNotes  = notes.booking_id || '';

    Logger.log('Razorpay payment.captured: ' + paymentId + ' ₹' + amountRs + ' booking_id: ' + bookingIdNotes);

    // ── Find the booking ──────────────────────────────────────
    let booking = null;
    let matchedByNotes = false;   // reliable match (payment carried its own booking_id)

    if (bookingIdNotes) {
      const r = supabaseFetch('GET',
        '/rest/v1/kh_bookings?id=eq.' + encodeURIComponent(bookingIdNotes) + '&limit=1');
      if (r && r.length > 0) { booking = r[0]; matchedByNotes = true; }
    }

    // Fallback: match by amount + unconfirmed status (for bookings without notes).
    // ⚠️ This match is UNRELIABLE — multiple unrelated customers can share the same
    // amount. It may ONLY be used to CONFIRM a booking, never to drive a REFUND.
    if (!booking) {
      const r = supabaseFetch('GET',
        '/rest/v1/kh_bookings?status=in.(pending_payment,cancelled)&amount=eq.' + amountRs +
        '&order=created_at.desc&limit=5');
      if (r && r.length > 0) {
        booking = r.find(function(b){ return !b.razorpay_payment_id; }) || r[0];
      }
    }

    if (!booking) {
      Logger.log('No matching booking for payment ' + paymentId);
      GmailApp.sendEmail(ADMIN_EMAIL,
        '⚠️ Razorpay payment — no booking found',
        'Payment ID: ' + paymentId + '\nAmount: ₹' + amountRs + '\nBooking ID in notes: ' + (bookingIdNotes || 'none') +
        '\n\nNo matching booking was found. Check Razorpay and Supabase manually.');
      return;
    }

    Logger.log('Matched booking: ' + booking.id + ' status: ' + booking.status);

    // Idempotent: already confirmed by normal flow — just log, no duplicate email
    if (booking.status === 'confirmed' && booking.razorpay_payment_id) {
      Logger.log('Already confirmed — skipping duplicate');
      return;
    }

    // ── Check if seats are still free ─────────────────────────
    var seatKeys = booking.seat_keys || [];
    var seatsAvailable = true;
    var conflictBooking = null;

    if (booking.status === 'cancelled' && seatKeys.length > 0) {
      var others = supabaseFetch('GET',
        '/rest/v1/kh_bookings?event_id=eq.' + booking.event_id +
        '&status=eq.confirmed&id=neq.' + booking.id + '&limit=100');
      if (others) {
        for (var i = 0; i < others.length; i++) {
          var otherSeats = others[i].seat_keys || [];
          for (var j = 0; j < seatKeys.length; j++) {
            if (otherSeats.indexOf(seatKeys[j]) !== -1) {
              seatsAvailable = false;
              conflictBooking = others[i];
              break;
            }
          }
          if (!seatsAvailable) break;
        }
      }
    }

    // Is the conflicting confirmed booking the SAME customer? Then this is a
    // duplicate payment (they paid twice / retried), not a clash with another person.
    function _norm(m){ return String(m || '').replace(/\D/g, '').slice(-10); }
    var sameCustomer = conflictBooking &&
      _norm(conflictBooking.booker_mobile) &&
      _norm(conflictBooking.booker_mobile) === _norm(booking.booker_mobile);

    // ⚠️ SAFETY GATE: never auto-refund a booking that was matched only by the
    // unreliable amount-fallback. Doing so refunded an unrelated customer once
    // (paid for different seats, same ₹amount). Alert admin for manual review instead.
    if (!seatsAvailable && !matchedByNotes) {
      Logger.log('Seats taken BUT booking matched by amount-fallback — NOT auto-refunding. Manual review.');
      GmailApp.sendEmail(ADMIN_EMAIL,
        '⚠️ Possible seat clash — manual review needed (NOT auto-refunded)',
        'A payment was captured but could only be matched to a booking by AMOUNT (no reliable booking_id),' +
        ' and that booking\'s seats appear taken. Refund was NOT issued automatically to avoid refunding the wrong person.\n\n' +
        'Payment ID: ' + paymentId + '\nAmount: ₹' + amountRs +
        '\nLoosely-matched booking: ' + booking.id + ' (' + (booking.booker_name || '—') + ', seats ' + (booking.seat_keys || []).join(', ') + ')' +
        '\n\nCheck Razorpay (payment contact/email) against Supabase and resolve by hand.');
      return;
    }

    if (!seatsAvailable) {
      // ── REFUND ────────────────────────────────────────────────
      Logger.log('Seats taken — refunding payment ' + paymentId);
      var refundResult = razorpayRefund(paymentId, amountPaise);
      Logger.log('Refund API response: ' + JSON.stringify(refundResult));

      supabaseFetch('PATCH',
        '/rest/v1/kh_bookings?id=eq.' + booking.id,
        { razorpay_payment_id: paymentId, payment_status: 'refund_initiated' });

      if (booking.booker_email && booking.booker_email.indexOf('@') !== -1) {
        sendRefundEmail(booking, paymentId, amountRs, sameCustomer);
      }

      GmailApp.sendEmail(ADMIN_EMAIL,
        sameCustomer ? '🟡 Duplicate payment refunded — customer\'s seats are safe'
                     : '🔴 Refund issued — seats were taken',
        'Booker: ' + (booking.booker_name || '—') + '\nMobile: ' + (booking.booker_mobile || '—') +
        '\nSeats: ' + (booking.seat_keys || []).join(', ') +
        '\nAmount refunded: ₹' + amountRs +
        '\nPayment ID: ' + paymentId +
        '\nBooking ID: ' + booking.id +
        (sameCustomer
          ? '\nConflicting booking: ' + conflictBooking.id + ' (SAME mobile — already confirmed for this customer)' +
            '\n\nThis was a DUPLICATE payment by the same customer. Their original booking is intact and confirmed; the extra charge was refunded. No action needed.'
          : '\n\nSeats were already taken by another booking. Full refund initiated via Razorpay.'));
      return;
    }

    // ── CONFIRM ───────────────────────────────────────────────
    supabaseFetch('PATCH',
      '/rest/v1/kh_bookings?id=eq.' + booking.id,
      { status: 'confirmed', payment_status: 'paid', razorpay_payment_id: paymentId });

    Logger.log('Confirmed booking: ' + booking.id);

    GmailApp.sendEmail(ADMIN_EMAIL,
      '✅ Booking confirmed via Razorpay — ' + (booking.booker_name || '—'),
      'Booker: ' + (booking.booker_name || '—') + '\nMobile: ' + (booking.booker_mobile || '—') +
      '\nSeats: ' + (booking.seat_keys || []).join(', ') +
      '\nAmount: ₹' + amountRs +
      '\nPayment ID: ' + paymentId +
      '\nBooking ID: ' + booking.id);

    // Send confirmation email to booker
    if (booking.booker_email && booking.booker_email.indexOf('@') !== -1) {
      var eventData = fetchEvent(booking.event_id);
      var orgData   = eventData ? fetchOrganiser(eventData.organiser_id) : null;
      var d = {
        to:              booking.booker_email,
        bookerName:      booking.booker_name    || '',
        eventName:       eventData ? eventData.name : 'Your Event',
        eventDate:       eventData ? formatDate(eventData.from_date || eventData.event_date, eventData.to_date) : '',
        hallName:        eventData ? fetchHallName(eventData.hall_id) : '',
        seats:           Array.isArray(booking.seat_keys) ? booking.seat_keys.join(', ') : 'Open Entry',
        amount:          booking.amount > 0 ? '₹' + booking.amount : 'Free',
        bookingId:       booking.id || '',
        bookedAt:        formatTimestamp(booking.created_at),
        totalDays:       eventData ? computeDays(eventData.from_date || eventData.event_date, eventData.to_date) : 1,
        organiserName:   orgData ? (orgData.contact_1_name || orgData.name || '') : '',
        organiserEmail:  orgData ? (orgData.email_1 || '') : '',
        organiserMobile: orgData ? (orgData.contact_1_mobile || '') : '',
      };
      sendBookingEmail(d);
    }

  } catch(err) {
    Logger.log('handleRazorpayWebhook error: ' + err.message);
    try {
      GmailApp.sendEmail(ADMIN_EMAIL,
        '🚨 Razorpay webhook error',
        'Error: ' + err.message + '\n\nCheck GAS Executions log for full details.');
    } catch(e2) {}
  }
}

// ── RAZORPAY REFUND API ────────────────────────────────────────
function razorpayRefund(paymentId, amountPaise) {
  var creds = Utilities.base64Encode(RAZORPAY_KEY_ID + ':' + RAZORPAY_KEY_SECRET);
  var res   = UrlFetchApp.fetch(
    'https://api.razorpay.com/v1/payments/' + paymentId + '/refund',
    {
      method:  'POST',
      headers: { 'Authorization': 'Basic ' + creds, 'Content-Type': 'application/json' },
      payload: JSON.stringify({ amount: amountPaise }),
      muteHttpExceptions: true
    }
  );
  return JSON.parse(res.getContentText());
}

// ── GENERIC SUPABASE FETCH ─────────────────────────────────────
function supabaseFetch(method, path, body) {
  var options = {
    method:  method,
    headers: {
      'apikey':        SUPABASE_KEY,
      'Authorization': 'Bearer ' + SUPABASE_KEY,
      'Content-Type':  'application/json',
      'Prefer':        method === 'GET' ? 'return=representation' : 'return=minimal'
    },
    muteHttpExceptions: true
  };
  if (body) options.payload = JSON.stringify(body);
  var res  = UrlFetchApp.fetch(SUPABASE_URL + path, options);
  var text = res.getContentText();
  return text ? JSON.parse(text) : null;
}

// ── REFUND EMAIL ───────────────────────────────────────────────
function sendRefundEmail(booking, paymentId, amountRs, sameCustomer) {
  var subject, body;
  if (sameCustomer) {
    subject = 'Duplicate payment refunded — your booking is confirmed ✅';
    body    = 'Hi ' + (booking.booker_name || 'there') + ',\n\n' +
      'Good news — your seats are confirmed and safe. We noticed this payment was a duplicate ' +
      '(your booking had already been paid for), so we\'ve refunded the extra charge.\n\n' +
      'Refund of ₹' + amountRs + ' has been initiated for payment ID ' + paymentId + '.\n' +
      'It will appear in your account within 5–7 business days. You do NOT need to pay or book again.\n\n' +
      'Please contact us if you have any questions.\n\n' +
      '– Khursilo Team\n' + BRAND_URL;
  } else {
    subject = 'Refund initiated for your booking — Khursilo';
    body    = 'Hi ' + (booking.booker_name || 'there') + ',\n\n' +
      'We\'re sorry — your seats were no longer available when your payment was processed ' +
      '(Booking ref: ' + booking.id.slice(0, 8) + ').\n\n' +
      'A full refund of ₹' + amountRs + ' has been initiated for payment ID ' + paymentId + '.\n' +
      'It will appear in your account within 5–7 business days.\n\n' +
      'Please contact us if you have any questions.\n\n' +
      '– Khursilo Team\n' + BRAND_URL;
  }
  GmailApp.sendEmail(booking.booker_email, subject, body, { from: FROM_EMAIL });
  Logger.log('Refund email sent to ' + booking.booker_email + (sameCustomer ? ' (duplicate-payment variant)' : ''));
}

// ══════════════════════════════════════════════════════════════
//  EXISTING HELPERS (unchanged)
// ══════════════════════════════════════════════════════════════

function fetchEvent(eventId) {
  if (!eventId) return null;
  try {
    const url = SUPABASE_URL + '/rest/v1/kh_events?id=eq.' + eventId + '&select=*&limit=1';
    const res = UrlFetchApp.fetch(url, {
      headers: { 'apikey': SUPABASE_KEY, 'Authorization': 'Bearer ' + SUPABASE_KEY }
    });
    const data = JSON.parse(res.getContentText());
    return data && data.length > 0 ? data[0] : null;
  } catch(e) { Logger.log('fetchEvent error: ' + e.message); return null; }
}

function fetchOrganiser(orgId) {
  if (!orgId) return null;
  try {
    const url = SUPABASE_URL + '/rest/v1/kh_organisers?id=eq.' + orgId + '&select=name,contact_1_name,contact_1_mobile,email_1&limit=1';
    const res = UrlFetchApp.fetch(url, {
      headers: { 'apikey': SUPABASE_KEY, 'Authorization': 'Bearer ' + SUPABASE_KEY }
    });
    const data = JSON.parse(res.getContentText());
    return data && data.length > 0 ? data[0] : null;
  } catch(e) { Logger.log('fetchOrganiser error: ' + e.message); return null; }
}

function fetchHallName(hallId) {
  if (!hallId) return '';
  try {
    const url = SUPABASE_URL + '/rest/v1/kh_halls?id=eq.' + hallId + '&select=name,city&limit=1';
    const res = UrlFetchApp.fetch(url, {
      headers: { 'apikey': SUPABASE_KEY, 'Authorization': 'Bearer ' + SUPABASE_KEY }
    });
    const data = JSON.parse(res.getContentText());
    if (data && data.length > 0) {
      return data[0].name + (data[0].city ? ', ' + data[0].city : '');
    }
    return '';
  } catch(e) { return ''; }
}

function formatDate(fromDate, toDate) {
  if (!fromDate) return '';
  const opts = { day: 'numeric', month: 'short', year: 'numeric' };
  const f = new Date(fromDate).toLocaleDateString('en-IN', opts);
  if (!toDate || toDate === fromDate) return f;
  const t = new Date(toDate).toLocaleDateString('en-IN', opts);
  return f + ' → ' + t;
}

function formatTimestamp(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  return d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) +
         ' ' + d.toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', hour12: true });
}

function computeDays(fromDate, toDate) {
  if (!fromDate || !toDate || fromDate === toDate) return 1;
  const diff = Math.round((new Date(toDate) - new Date(fromDate)) / (1000 * 60 * 60 * 24)) + 1;
  return Math.max(1, diff);
}

function sendBookingEmail(d) {
  const isMultiDay = (d.totalDays || 1) > 1;
  const subject    = '✅ Booking Confirmed — ' + d.eventName;
  const body       = buildEmailHtml(d, isMultiDay);
  const replyTo    = (d.organiserEmail && d.organiserEmail.includes('@'))
                     ? d.organiserEmail : SUPPORT_EMAIL;

  GmailApp.sendEmail(d.to, subject, '', {
    htmlBody: body,
    name:     FROM_NAME,
    from:     FROM_EMAIL,
    replyTo:  replyTo,
  });
  Logger.log('Email sent to: ' + d.to + ' for event: ' + d.eventName);
}

function buildEmailHtml(d, isMultiDay) {
  const dayBoxes     = isMultiDay ? buildDayBoxesHtml(d.totalDays) : '';
  const multiDayNote = isMultiDay
    ? `<div style="background:#fff8e1;border:1px solid #f0c040;border-radius:6px;padding:10px 14px;font-size:13px;color:#7a5c00;margin-top:12px;">
        🗓️ This ticket is valid for all <strong>${d.totalDays} days</strong> of the event.
        Present the QR at the gate each day.
       </div>` : '';

  const hasOrg = d.organiserName || d.organiserEmail || d.organiserMobile;
  const orgBlock = hasOrg
    ? `<div style="background:#f0f4ff;border:1px solid #d0d8f0;border-radius:8px;padding:14px 16px;margin-top:16px;">
        <div style="font-size:11px;font-weight:700;color:#2b6fd4;text-transform:uppercase;letter-spacing:.5px;margin-bottom:8px;">Event Organiser</div>
        ${d.organiserName ? `<div style="font-size:13px;font-weight:600;color:#1a1a1a;margin-bottom:4px;">${esc(d.organiserName)}</div>` : ''}
        ${d.organiserMobile ? `<div style="font-size:12px;color:#555;margin-bottom:3px;">📞 ${esc(d.organiserMobile)}</div>` : ''}
        ${d.organiserEmail ? `<div style="font-size:12px;color:#555;">✉️ <a href="mailto:${esc(d.organiserEmail)}" style="color:#2b6fd4;text-decoration:none;">${esc(d.organiserEmail)}</a></div>` : ''}
        <div style="font-size:11px;color:#888;margin-top:8px;">For queries about this event, reply to this email — your message goes directly to the organiser.</div>
      </div>` : '';

  return `<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f5f5f3;font-family:'Segoe UI',Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f3;padding:24px 0;">
<tr><td align="center">
<table width="480" cellpadding="0" cellspacing="0" style="max-width:480px;width:100%;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 16px rgba(0,0,0,0.08);">

  <!-- HEADER -->
  <tr><td style="background:linear-gradient(135deg,#1a1a1a 0%,#333 100%);padding:24px 28px;">
    <div style="font-family:Georgia,serif;font-size:22px;color:#fff;margin-bottom:6px;">Khursilo</div>
    <div style="font-family:Georgia,serif;font-size:20px;color:#c8860a;line-height:1.3;margin-bottom:10px;">${esc(d.eventName)}</div>
    <div style="font-size:12px;color:rgba(255,255,255,0.70);margin-bottom:3px;">📅 ${esc(d.eventDate)}</div>
    <div style="font-size:12px;color:rgba(255,255,255,0.70);">📍 ${esc(d.hallName)}</div>
  </td></tr>

  <!-- SUCCESS BADGE -->
  <tr><td style="background:#e8f5ee;padding:12px 28px;border-bottom:1px solid #d0ead8;">
    <span style="font-size:15px;font-weight:700;color:#2e9e60;">✅ Booking Confirmed!</span>
    <span style="font-size:12px;color:#555;margin-left:8px;">Your ticket is ready.</span>
  </td></tr>

  <!-- BOOKING DETAILS -->
  <tr><td style="padding:22px 28px 8px;">
    <table width="100%" cellpadding="0" cellspacing="0">
      <tr><td style="padding:9px 0;border-bottom:1px solid #f0eeea;">
        <span style="font-size:10px;color:#aaa;text-transform:uppercase;letter-spacing:.6px;display:block;margin-bottom:3px;">Name</span>
        <span style="font-size:15px;font-weight:600;color:#1a1a1a;">${esc(d.bookerName)}</span>
      </td></tr>
      <tr><td style="padding:9px 0;border-bottom:1px solid #f0eeea;">
        <span style="font-size:10px;color:#aaa;text-transform:uppercase;letter-spacing:.6px;display:block;margin-bottom:3px;">Seats / Entry</span>
        <span style="font-size:14px;font-weight:600;color:#1a1a1a;">${esc(d.seats)}</span>
      </td></tr>
      <tr><td style="padding:9px 0;border-bottom:1px solid #f0eeea;">
        <span style="font-size:10px;color:#aaa;text-transform:uppercase;letter-spacing:.6px;display:block;margin-bottom:3px;">Amount Paid</span>
        <span style="font-size:18px;font-weight:700;color:#c8860a;">${esc(d.amount)}</span>
      </td></tr>
      <tr><td style="padding:9px 0;border-bottom:1px solid #f0eeea;">
        <span style="font-size:10px;color:#aaa;text-transform:uppercase;letter-spacing:.6px;display:block;margin-bottom:3px;">Booked At</span>
        <span style="font-size:13px;color:#1a1a1a;">${esc(d.bookedAt)}</span>
      </td></tr>
      <tr><td style="padding:9px 0;">
        <span style="font-size:10px;color:#aaa;text-transform:uppercase;letter-spacing:.6px;display:block;margin-bottom:3px;">Booking ID</span>
        <span style="font-size:11px;color:#aaa;font-family:monospace;">${esc(d.bookingId)}</span>
      </td></tr>
    </table>

    ${multiDayNote}
    ${dayBoxes}

    <!-- VIEW TICKET BUTTON -->
    <div style="text-align:center;margin-top:20px;">
      <a href="${BRAND_URL}/ticket.html?id=${esc(d.bookingId)}" style="display:inline-block;background:#2e9e60;color:#fff;text-decoration:none;padding:14px 36px;border-radius:8px;font-size:15px;font-weight:700;letter-spacing:.3px;">📱 View Your Ticket &amp; QR →</a>
      <div style="font-size:11px;color:#aaa;margin-top:8px;">Open this on your phone at the entry gate</div>
    </div>

    <!-- QR INSTRUCTION -->
    <div style="background:#f0eeea;border-radius:8px;padding:14px 16px;margin-top:16px;font-size:12px;color:#888;line-height:1.7;">
      Click the button above to open your ticket with QR code. Show the QR to gate staff — no printout needed, phone is fine.
    </div>

    ${orgBlock}

    <div style="text-align:center;margin-top:20px;margin-bottom:8px;">
      <a href="${BRAND_URL}" style="display:inline-block;background:#1a1a1a;color:#fff;text-decoration:none;padding:12px 32px;border-radius:8px;font-size:14px;font-weight:600;">khursilo.in →</a>
    </div>
  </td></tr>

  <!-- FOOTER -->
  <tr><td style="background:#f0eeea;padding:14px 28px;border-top:1px solid #e0dedc;">
    <p style="font-size:11px;color:#aaa;margin:0;text-align:center;line-height:1.8;">
      Sent by <strong style="color:#888;">Khursilo</strong> · ${BRAND_URL}<br>
      Platform support: <a href="mailto:${SUPPORT_EMAIL}" style="color:#c8860a;text-decoration:none;">${SUPPORT_EMAIL}</a><br>
      Vadodara, Gujarat · India
    </p>
  </td></tr>

</table>
</td></tr>
</table>
</body>
</html>`;
}

function buildDayBoxesHtml(totalDays) {
  let boxes = '';
  for (let d = 1; d <= totalDays; d++) {
    boxes += `<td align="center" style="padding:0 4px 6px;">
      <div style="width:38px;height:38px;border:1.5px solid #ccc;border-radius:7px;text-align:center;line-height:38px;font-size:14px;font-weight:700;color:#888;background:#fff;">${d}</div>
      <div style="font-size:9px;color:#bbb;margin-top:3px;">Day</div>
    </td>`;
  }
  return `<div style="margin-top:16px;padding:14px 0 4px;">
    <div style="font-size:10px;color:#aaa;text-transform:uppercase;letter-spacing:.6px;margin-bottom:10px;font-weight:700;">Entry days — gate staff stamps each day</div>
    <table cellpadding="0" cellspacing="0"><tr>${boxes}</tr></table>
  </div>`;
}

function esc(s) {
  return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function jsonResponse(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

// ══════════════════════════════════════════════════════════════
//  BOOKING SUMMARY — scheduled every 15 min via GAS trigger
//  Logic: event day → sends every run (15 min)
//         other days → sends only at top of hour
//
//  TRIGGER SETUP (one time):
//  GAS → Triggers (clock icon, left sidebar) → + Add Trigger
//  Function: sendBookingSummary
//  Event source: Time-driven
//  Type: Minutes timer → Every 15 minutes
//  Save
// ══════════════════════════════════════════════════════════════
function sendBookingSummary() {
  try {
    // Fetch all active events
    var events = supabaseFetch('GET',
      '/rest/v1/kh_events?status=eq.active&select=id,name,event_date,hall_id,organiser_id&order=event_date.asc');
    if (!events || events.length === 0) return;

    var now       = new Date();
    var todayStr  = Utilities.formatDate(now, 'Asia/Kolkata', 'yyyy-MM-dd');
    var minuteNow = parseInt(Utilities.formatDate(now, 'Asia/Kolkata', 'mm'));
    var hourNow   = parseInt(Utilities.formatDate(now, 'Asia/Kolkata', 'HH'));

    // Only send between 8 AM and 11 PM IST
    if (hourNow < 8 || hourNow >= 23) return;

    var lines = [];

    for (var e = 0; e < events.length; e++) {
      var ev        = events[e];
      var isToday   = (ev.event_date === todayStr);

      // Non-event-day: only send at top of hour (minute 0–14)
      if (!isToday && minuteNow >= 15) continue;

      // Fetch confirmed bookings for this event
      var confirmed = supabaseFetch('GET',
        '/rest/v1/kh_bookings?event_id=eq.' + ev.id +
        '&status=eq.confirmed&select=seat_count,amount');
      var pending = supabaseFetch('GET',
        '/rest/v1/kh_bookings?event_id=eq.' + ev.id +
        '&status=in.(pending_payment,pending_manual)&select=id');

      var totalSeats    = 0;
      var totalAmount   = 0;
      var confirmedCount = 0;
      if (confirmed) {
        confirmedCount = confirmed.length;
        for (var i = 0; i < confirmed.length; i++) {
          totalSeats  += Number(confirmed[i].seat_count) || 0;
          totalAmount += Number(confirmed[i].amount)     || 0;
        }
      }
      var pendingCount = pending ? pending.length : 0;

      // Fetch hall capacity
      var hallCap = 0;
      if (ev.hall_id) {
        var hall = supabaseFetch('GET',
          '/rest/v1/kh_halls?id=eq.' + ev.hall_id + '&select=layout_json&limit=1');
        if (hall && hall.length > 0) {
          var lj = hall[0].layout_json;
          if (typeof lj === 'string') lj = JSON.parse(lj);
          var rows = (lj && lj.rows) ? lj.rows : [];
          for (var r = 0; r < rows.length; r++) {
            if (rows[r].type !== 'row') continue;
            var cells = rows[r].cells || [];
            for (var c = 0; c < cells.length; c++) {
              var t = cells[c].t || '';
              if (cells[c].sn && !['label','empty','aisle','gap','vgap','blocked'].includes(t)) hallCap++;
            }
          }
        }
      }

      var remaining = hallCap > 0 ? (hallCap - totalSeats) : '?';
      var pct       = hallCap > 0 ? Math.round((totalSeats / hallCap) * 100) : '?';
      var tag       = isToday ? ' 🎭 TODAY' : '';

      lines.push(
        '━━━━━━━━━━━━━━━━━━━━━━━━\n' +
        ev.name + tag + '\n' +
        'Date: ' + ev.event_date + '\n' +
        'Seats booked: ' + totalSeats + (hallCap > 0 ? ' / ' + hallCap + ' (' + pct + '%)' : '') + '\n' +
        'Bookings: ' + confirmedCount + ' confirmed' + (pendingCount > 0 ? ', ' + pendingCount + ' pending' : '') + '\n' +
        'Seats remaining: ' + remaining + '\n' +
        'Amount collected: ₹' + totalAmount.toLocaleString('en-IN')
      );
    }

    if (lines.length === 0) return;

    var timeStr = Utilities.formatDate(now, 'Asia/Kolkata', 'dd MMM HH:mm');
    var subject = '📊 Booking update — ' + timeStr;
    var body    = 'Booking summary as of ' + timeStr + ' IST\n\n' + lines.join('\n\n') + '\n\n━━━━━━━━━━━━━━━━━━━━━━━━';

    GmailApp.sendEmail(ADMIN_EMAIL, subject, body, { from: FROM_EMAIL });
    Logger.log('Summary sent: ' + lines.length + ' event(s)');

  } catch(err) {
    Logger.log('sendBookingSummary error: ' + err.message);
  }
}
