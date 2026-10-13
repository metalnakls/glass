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

async function recordInstallation(request, database) {
  if (Number(request.headers.get("content-length")) > 1024) return new Response("Too large", { status: 413 });
  const reader = request.body?.getReader();
  if (!reader) return new Response("Invalid report", { status: 400 });
  let body = new Uint8Array(0);
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    if (body.length + value.length > 1024) { await reader.cancel(); return new Response("Too large", { status: 413 }); }
    const joined = new Uint8Array(body.length + value.length);
    joined.set(body); joined.set(value, body.length); body = joined;
  }
  let report;
  try { report = JSON.parse(new TextDecoder().decode(body)); } catch { return new Response("Invalid report", { status: 400 }); }
  if (!report || typeof report !== "object" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(report.installationID ?? "") ||
      !isVersion(report.appVersion) || !isVersion(report.osVersion) ||
      typeof report.macModel !== "string" || !/^[A-Za-z][A-Za-z0-9,.-]{0,63}$/.test(report.macModel)) {
    return new Response("Invalid report", { status: 400 });
  }
  const now = new Date().toISOString();
  await database.prepare(`
    INSERT INTO installations (installation_id, app_version, os_version, mac_model, first_seen, version_first_seen, last_reported)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (installation_id) DO UPDATE SET
      version_first_seen = CASE WHEN installations.app_version != excluded.app_version THEN excluded.version_first_seen ELSE installations.version_first_seen END,
      app_version = excluded.app_version, os_version = excluded.os_version,
      mac_model = excluded.mac_model, last_reported = excluded.last_reported
  `).bind(report.installationID.toLowerCase(), report.appVersion, report.osVersion, report.macModel, now, now, now).run();
  return new Response(null, { status: 204 });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/installations") {
      if (request.method !== "POST") return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
      try { return await recordInstallation(request, env.DB); }
      catch { return new Response("Report unavailable", { status: 503 }); }
    }
    if (request.method !== "GET") {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET" } });
    }

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
