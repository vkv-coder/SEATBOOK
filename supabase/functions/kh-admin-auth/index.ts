// Server-side admin session handling for Khursilo/SEATBOOK.
//
// kh_admin_tokens used to be directly readable/writable by anyone via the
// anon key, so a session token could be forged without ever knowing the
// PIN - the login screens (admin.html and the 7 gated tool pages) were
// checking the PIN correctly, but the *session* they issued afterward
// wasn't actually protected. Direct anon access to kh_admin_tokens is now
// revoked entirely; login/verify/logout all go through here, using
// service_role to touch the table.
//
// Deploy with:
//   supabase functions deploy kh-admin-auth

import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  let body: { action?: string; pin?: string; token?: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400 });
  }

  const { action, pin, token } = body;
  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  if (action === "login") {
    if (!pin) {
      return new Response(JSON.stringify({ error: "pin required" }), { status: 400 });
    }
    let pinValid = false;
    try {
      const res = await fetch("https://telegram-notify.unigoods2026.workers.dev/", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "checkSeatbookPin", pin }),
      });
      const data = await res.json();
      pinValid = !!data.valid;
    } catch {
      pinValid = false;
    }
    if (!pinValid) {
      return new Response(JSON.stringify({ error: "Wrong PIN" }), { status: 401 });
    }

    const newToken = crypto.randomUUID();
    const expiresAt = new Date(Date.now() + 8 * 60 * 60 * 1000).toISOString();
    const { error } = await supabaseAdmin
      .from("kh_admin_tokens")
      .insert({ token: newToken, expires_at: expiresAt });
    if (error) {
      return new Response(JSON.stringify({ error: error.message }), { status: 500 });
    }
    return new Response(JSON.stringify({ token: newToken, expires_at: expiresAt }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (action === "verify") {
    if (!token) {
      return new Response(JSON.stringify({ valid: false }), { status: 200 });
    }
    const { data } = await supabaseAdmin
      .from("kh_admin_tokens")
      .select("token")
      .eq("token", token)
      .gt("expires_at", new Date().toISOString())
      .maybeSingle();
    return new Response(JSON.stringify({ valid: !!data }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (action === "logout") {
    if (token) {
      await supabaseAdmin.from("kh_admin_tokens").delete().eq("token", token);
    }
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ error: "Unknown action" }), { status: 400 });
});
