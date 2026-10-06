const APPCAST_URL = "https://github.com/metalnakls/glass/releases/latest/download/appcast.xml";
const PROFILE_KEYS = ["appName", "appVersion", "osVersion"];

function isVersion(value) {
  return typeof value === "string" && /^[0-9A-Za-z.-]{1,64}$/.test(value);
}

function weekStartUTC(now = new Date()) {
  const date = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const daysSinceMonday = (date.getUTCDay() + 6) % 7;
  date.setUTCDate(date.getUTCDate() - daysSinceMonday);
  return date.toISOString().slice(0, 10);
}

async function recordProfile(url, database) {
  if (url.searchParams.get("appName") !== "Glass") return;

  const appVersion = url.searchParams.get("appVersion");
  const osVersion = url.searchParams.get("osVersion");
  if (!isVersion(appVersion) || !isVersion(osVersion)) return;

  await database.prepare(`
    INSERT INTO weekly_install_checks (week_start, app_version, os_version, request_count)
    VALUES (?, ?, ?, 1)
    ON CONFLICT (week_start, app_version, os_version)
    DO UPDATE SET request_count = request_count + 1
  `).bind(weekStartUTC(), appVersion, osVersion).run();
}

export default {
  async fetch(request, env) {
    if (request.method !== "GET") {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET" } });
    }

    const url = new URL(request.url);
    if (url.pathname !== "/" && url.pathname !== "/appcast.xml") {
      return new Response("Not found", { status: 404 });
    }

    if (PROFILE_KEYS.every((key) => url.searchParams.has(key))) {
      try {
        await recordProfile(url, env.DB);
      } catch {
        // A metrics write must never prevent Sparkle from receiving its appcast.
      }
    }

    const upstream = await fetch(APPCAST_URL, { redirect: "follow" });
    const headers = new Headers(upstream.headers);
    headers.set("Cache-Control", "no-store");
    headers.set("X-Content-Type-Options", "nosniff");
    headers.delete("content-length");
    return new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers,
    });
  },
};
