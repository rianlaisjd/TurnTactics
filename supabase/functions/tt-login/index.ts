// Turn Tactics sign-in with a username OR an email, plus password.
// The browser never learns which email belongs to a username: resolution and the password check
// both happen here, and every failure returns the same generic answer.
// Deploy:  supabase functions deploy tt-login --no-verify-jwt
// Secrets: TT_ALLOWED_ORIGINS (comma-separated, e.g. https://turntactics.b-cdn.net,https://turntactics.vercel.app)
//          TT_PUBLISHABLE_KEY (the same public key the frontend uses; needed to call the Auth API)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by the platform. Credentials are never logged.
import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import { corsOrigin, identifierKind } from "../_shared/logic.ts";

const GENERIC = "Those sign-in details did not match. Check them and try again.";

Deno.serve(async (req) => {
  const origin = corsOrigin(req.headers.get("origin"), Deno.env.get("TT_ALLOWED_ORIGINS") ?? "");
  const cors: Record<string, string> = origin
    ? { "Access-Control-Allow-Origin": origin, "Vary": "Origin", "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info",
        "Access-Control-Allow-Methods": "POST, OPTIONS", "Cache-Control": "no-store" }
    : { "Cache-Control": "no-store" };
  const reply = (body: unknown, status: number) => Response.json(body, { status, headers: cors });
  if (req.method === "OPTIONS") return new Response(null, { status: origin ? 204 : 403, headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  if (!origin) return reply({ error: "Origin not allowed" }, 403);

  let identifier = "", password = "";
  try {
    const body = await req.json();
    identifier = typeof body?.identifier === "string" ? body.identifier.trim().toLowerCase() : "";
    password = typeof body?.password === "string" ? body.password : "";
  } catch { return reply({ error: GENERIC }, 400); }
  if (!identifierKind(identifier) || password.length < 1 || password.length > 200) return reply({ error: GENERIC }, 400);

  const url = Deno.env.get("SUPABASE_URL")!, publishable = Deno.env.get("TT_PUBLISHABLE_KEY") ?? "";
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  const gate = await admin.rpc("tt_login_gate", { p_identifier: identifier, p_ip: ip });
  if (gate.error) return reply({ error: "Sign-in is temporarily unavailable." }, 503);
  if (!gate.data?.allowed) return reply({ error: "Too many attempts. Wait fifteen minutes and try again." }, 429);

  // Unknown usernames still perform a password request against a placeholder, so timing and
  // response shape do not reveal whether the username exists.
  const email = gate.data.email ?? "no-such-user@invalid.turntactics";
  const auth = await fetch(`${url}/auth/v1/token?grant_type=password`, {
    method: "POST", headers: { "Content-Type": "application/json", apikey: publishable },
    body: JSON.stringify({ email, password }),
  });
  if (!auth.ok) { await auth.body?.cancel(); return reply({ error: GENERIC }, 401); }
  const session = await auth.json();
  if (!session?.access_token || !session?.refresh_token) return reply({ error: GENERIC }, 401);
  return reply({ access_token: session.access_token, refresh_token: session.refresh_token }, 200);
});
