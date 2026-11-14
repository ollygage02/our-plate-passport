/* Plate Passport service worker.
   1. Keeps a copy of the app on the phone so it opens instantly, even before the network answers.
      The page is shown from that copy and quietly re-downloaded; when a newer version arrives,
      the open page is told so it can offer a reload.
   2. Receives notifications while the app is closed. */
const SHELL = "opp-shell-v1";  /* "opp-share" holds a photo shared from Android for a moment */
const SUPABASE_JS = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js";
const WORLD_MAP = "https://cdn.jsdelivr.net/npm/jsvectormap@1.5.3/dist/maps/world.js";
const PAGES = ["/", "/config.js"];                       // fresh copy fetched every launch, cached copy shown first
const FIXED = [SUPABASE_JS, WORLD_MAP, "/icon-192.png", "/apple-touch-icon.png", "/logo-passport.png", "/manifest.webmanifest"];  // versioned or rarely changing

self.addEventListener("install", e => {
  e.waitUntil(caches.open(SHELL).then(c => Promise.all([...PAGES, ...FIXED].map(u => c.add(new Request(u, {cache: "reload"})).catch(() => {})))).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => e.waitUntil(
  caches.keys().then(keys => Promise.all(keys.filter(k => k !== SHELL && k !== "opp-share").map(k => caches.delete(k)))).then(() => self.clients.claim())));

const tell = msg => self.clients.matchAll({type: "window", includeUncontrolled: true}).then(list => list.forEach(c => c.postMessage(msg)));
const sig = r => r ? (r.headers.get("etag") || "") + "|" + (r.headers.get("last-modified") || "") + "|" + (r.headers.get("content-length") || "") : "";

/* show the saved copy now, refresh it in the background, and say so if it changed */
function staleWhileRevalidate(event, key) {
  return caches.open(SHELL).then(async cache => {
    const cached = await cache.match(key);
    const fresh = fetch(event.request.mode === "navigate" ? new Request(key, {cache: "no-store"}) : new Request(event.request, {cache: "no-store"}))
      .then(async res => {
        if (res && res.ok) {
          const changed = cached && sig(cached) !== sig(res);
          await cache.put(key, res.clone());
          if (changed && key === "/") tell({type: "update-ready"});
        }
        return res;
      }).catch(() => null);
    event.waitUntil(fresh.then(() => {}));
    return cached || fresh.then(r => r || Response.error());
  });
}
function cacheFirst(event) {
  return caches.open(SHELL).then(async cache => {
    const hit = await cache.match(event.request.url);
    if (hit) return hit;
    const res = await fetch(event.request);
    if (res && (res.ok || res.type === "opaque")) cache.put(event.request.url, res.clone());
    return res;
  });
}

self.addEventListener("fetch", e => {
  const req = e.request;
  /* Android share sheet: keep the shared photo for a moment and open the meal form */
  if (req.method === "POST" && new URL(req.url).pathname === "/share-target") {
    e.respondWith((async () => {
      try {
        const form = await req.formData(), file = form.getAll("photo").find(f => f && f.type && f.type.startsWith("image/"));
        if (file) await (await caches.open("opp-share")).put("/shared-photo", new Response(file, {headers: {"Content-Type": file.type}}));
      } catch (err) {}
      return Response.redirect("/?log=shared", 303);
    })());
    return;
  }
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin === self.location.origin) {
    if (req.mode === "navigate" || url.pathname === "/" || url.pathname === "/index.html") { e.respondWith(staleWhileRevalidate(e, "/")); return; }
    if (url.pathname === "/config.js") { e.respondWith(staleWhileRevalidate(e, "/config.js")); return; }
    if (FIXED.includes(url.pathname)) { e.respondWith(cacheFirst(e)); return; }
    if (url.pathname.startsWith("/i18n/")) { e.respondWith(cacheFirst(e)); return; }
    return;
  }
  if (req.url === SUPABASE_JS || req.url === WORLD_MAP) { e.respondWith(cacheFirst(e)); return; }
  /* Google fonts: keep them on the phone so text appears in the right font straight away */
  if (url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com") e.respondWith(cacheFirst(e));
});

self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = {body: e.data ? e.data.text() : ""}; }
  e.waitUntil(self.registration.showNotification(d.title || "Plate Passport", {
    body: d.body || "",
    icon: "/icon-192.png",
    badge: "/icon-192.png",
    tag: d.tag || undefined,
    data: {url: d.url || "/"}
  }));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "/", self.location.origin).href;
  e.waitUntil(self.clients.matchAll({type: "window", includeUncontrolled: true}).then(list => {
    for (const c of list) {
      if (c.url.startsWith(self.location.origin) && "focus" in c) { c.postMessage({type: "open", url}); return c.focus(); }
    }
    return self.clients.openWindow(url);
  }));
});
