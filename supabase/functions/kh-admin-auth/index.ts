// Server-side admin session handling AND gated table writes for
// Khursilo/SEATBOOK.
//
// kh_admin_tokens used to be directly readable/writable by anyone via the
// anon key, so a session token could be forged without ever knowing the
// PIN - the login screens (admin.html and the 7 gated tool pages) were
// checking the PIN correctly, but the *session* they issued afterward
// wasn't actually protected. Direct anon access to kh_admin_tokens is now
// revoked entirely; login/verify/logout all go through here, using
// service_role to touch the table.
//
// The 'write' action additionally lets already-logged-in admin pages
// perform privileged writes (halls, events, organiser management, food
// items, sections) on tables whose direct anon write access has been
// revoked, after checking the caller's session token server-side.
//
// Deploy with:
//   supabase functions deploy kh-admin-auth

import { createClient } from "jsr:@supabase/supabase-js@2";

const WRITABLE_TABLES = new Set([
  "kh_halls", "kh_events", "kh_organisers", "kh_food_items",
  "kh_sections", "kh_event_members",
]);
const ALLOWED_OPS = new Set(["insert", "update", "delete", "upsert"]);

// Browser fetch() calls from khursilo.in are cross-origin to *.supabase.co,
// so every response (including the OPTIONS preflight) needs these headers
// or the browser silently blocks the request before it's ever sent.
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

async function tokenValid(supabaseAdmin: ReturnType<typeof createClient>, token: string | undefined) {
  if (!token) return false;
  const { data } = await supabaseAdmin
    .from("kh_admin_tokens")
    .select("token")
    .eq("token", token)
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();
  return !!data;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  let body: {
    action?: string; pin?: string; token?: string;
    table?: string; op?: string; payload?: unknown;
    filter?: { column: string; value: unknown };
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const { action, pin, token, table, op, payload, filter } = body;
  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  if (action === "login") {
    if (!pin) {
      return json({ error: "pin required" }, 400);
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
    } catch (e) {
      return json({ error: "Could not reach PIN verification service", detail: String(e) }, 502);
    }
    if (!pinValid) {
      return json({ error: "Wrong PIN" }, 401);
    }

    const newToken = crypto.randomUUID();
    const expiresAt = new Date(Date.now() + 8 * 60 * 60 * 1000).toISOString();
    const { error } = await supabaseAdmin
      .from("kh_admin_tokens")
      .insert({ token: newToken, expires_at: expiresAt });
    if (error) {
      return json({ error: error.message }, 500);
    }
    return json({ token: newToken, expires_at: expiresAt });
  }

  if (action === "verify") {
    const valid = await tokenValid(supabaseAdmin, token);
    return json({ valid });
  }

  if (action === "logout") {
    if (token) {
      await supabaseAdmin.from("kh_admin_tokens").delete().eq("token", token);
    }
    return json({ ok: true });
  }

  if (action === "write") {
    if (!(await tokenValid(supabaseAdmin, token))) {
      return json({ error: "Not logged in" }, 401);
    }
    if (!table || !WRITABLE_TABLES.has(table)) {
      return json({ error: "Unknown or disallowed table" }, 400);
    }
    if (!op || !ALLOWED_OPS.has(op)) {
      return json({ error: "Unknown op" }, 400);
    }

    let query;
    if (op === "insert") {
      query = supabaseAdmin.from(table).insert(payload as never).select();
    } else if (op === "upsert") {
      query = supabaseAdmin.from(table).upsert(payload as never).select();
    } else if (op === "update") {
      let q = supabaseAdmin.from(table).update(payload as never);
      if (filter) q = q.eq(filter.column, filter.value as never);
      query = q.select();
    } else {
      let q = supabaseAdmin.from(table).delete();
      if (filter) q = q.eq(filter.column, filter.value as never);
      query = q.select();
    }

    const { data, error } = await query;
    return json({ data, error }, error ? 400 : 200);
  }

  return json({ error: "Unknown action" }, 400);
});
