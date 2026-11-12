// Turn Tactics push sender. Invoked once a minute by pg_cron (see supabase/024_release_jobs.sql).
// Deploy:  supabase functions deploy tt-push --no-verify-jwt
// Secrets: TT_CRON_SECRET, TT_VAPID_PUBLIC_KEY, TT_VAPID_PRIVATE_KEY, TT_VAPID_SUBJECT (mailto:you@example.com)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by the platform. Nothing here is sent to browsers.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import { classify, endpointAllowed, safeEqual } from "../_shared/logic.ts";

type Delivery = {
  subscription: { id: string; endpoint: string; p256dh: string; auth: string };
  ids: number[];
  payload: { title: string; body: string; tag: string; url: string };
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = Deno.env.get("TT_CRON_SECRET") ?? "";
  if (secret.length < 24 || !safeEqual(req.headers.get("x-tt-cron-secret") ?? "", secret)) {
    return new Response("Unauthorized", { status: 401 });
  }
  const publicKey = Deno.env.get("TT_VAPID_PUBLIC_KEY"), privateKey = Deno.env.get("TT_VAPID_PRIVATE_KEY");
  const subject = Deno.env.get("TT_VAPID_SUBJECT");
  if (!publicKey || !privateKey || !subject) return Response.json({ error: "VAPID secrets are not configured" }, { status: 503 });
  webpush.setVapidDetails(subject, publicKey, privateKey);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  // The database decides WHAT may be sent to WHOM (preferences, quiet hours, current seat owner).
  const { data, error } = await db.rpc("tt_push_claim", { p_limit: 200 });
  if (error) return Response.json({ error: "claim failed" }, { status: 500 });

  const deliveries = (data ?? []) as Delivery[];
  const results = await Promise.all(deliveries.map(async (item) => {
    let status: "ok" | "gone" | "retry";
    if (!endpointAllowed(item.subscription.endpoint)) status = "gone";
    else {
      try {
        const sent = await webpush.sendNotification(
          { endpoint: item.subscription.endpoint, keys: { p256dh: item.subscription.p256dh, auth: item.subscription.auth } },
          JSON.stringify(item.payload), { TTL: 12 * 60 * 60, urgency: "normal", timeout: 10000 });
        status = classify(sent.statusCode);
      } catch (failure) {
        status = classify((failure as { statusCode?: number }).statusCode);
      }
    }
    return { subscription: item.subscription.id, ids: item.ids, status };
  }));
  if (results.length) {
    const report = await db.rpc("tt_push_report", { p_results: results });
    // Unreported leases return to the queue after five minutes; the attempt cap prevents storms.
    if (report.error) return Response.json({ error: "report failed", claimed: results.length }, { status: 500 });
  }
  // Counts only: endpoints, keys and payloads are never logged or returned.
  return Response.json({ claimed: results.length, ok: results.filter((r) => r.status === "ok").length,
    gone: results.filter((r) => r.status === "gone").length, retry: results.filter((r) => r.status === "retry").length });
});
