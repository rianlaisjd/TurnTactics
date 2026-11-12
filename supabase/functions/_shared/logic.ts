// Pure helpers shared by the Edge Functions. No imports, so Node can unit-test this file directly.

const PUSH_HOSTS = ["fcm.googleapis.com", "push.services.mozilla.com", "notify.windows.com", "push.apple.com"];

/** Second line of defence against server-side request forgery: only real browser push services. */
export function endpointAllowed(endpoint: unknown): boolean {
  if (typeof endpoint !== "string" || endpoint.length > 1000) return false;
  let url: URL;
  try { url = new URL(endpoint); } catch { return false; }
  if (url.protocol !== "https:" || url.username || url.password || (url.port && url.port !== "443")) return false;
  const host = url.hostname.toLowerCase();
  return PUSH_HOSTS.some((allowed) => host === allowed || host.endsWith("." + allowed));
}

/** Maps a push-service HTTP status to what the outbox should do next. */
export function classify(status: number | undefined): "ok" | "gone" | "retry" {
  if (status !== undefined && status >= 200 && status < 300) return "ok";
  if (status === 404 || status === 410) return "gone"; // subscription expired or revoked
  return "retry"; // 429, 5xx, network failure: bounded retries happen in SQL
}

/** Length-independent comparison for the cron shared secret. */
export function safeEqual(a: string, b: string): boolean {
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

/** CORS: echo the caller's origin only when it is on the configured allow-list. */
export function corsOrigin(origin: string | null, allowList: string): string | null {
  if (!origin) return null;
  const allowed = allowList.split(",").map((item) => item.trim().replace(/\/$/, "")).filter(Boolean);
  return allowed.includes(origin) ? origin : null;
}

/** Sign-in identifiers: an email, or a 3–20 character username. Anything else is rejected early. */
export function identifierKind(value: unknown): "email" | "username" | null {
  if (typeof value !== "string") return null;
  const text = value.trim().toLowerCase();
  if (/^[a-z0-9_]{3,20}$/.test(text)) return "username";
  if (text.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text)) return "email";
  return null;
}
