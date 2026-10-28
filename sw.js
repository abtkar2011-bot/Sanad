// سند: يحفظ ملفات الموقع ليفتح بسرعة ويعمل كتطبيق، حتى لو النت ضعيف.
// الصفحة وملفات الإعداد تُجلب من النت أولًا عشان التحديثات توصل على طول.
const CACHE = "sanad-v3";
const FONTS = "sanad-fonts-v1";
const SHELL = ["./", "./index.html", "./config.js", "./cloud.js", "./manifest.webmanifest",
  "./icons/icon-192.png", "./icons/icon-512.png", "./icons/apple-touch-icon.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((ks) => Promise.all(ks.filter((k) => k !== CACHE && k !== FONTS).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com") {
    e.respondWith(caches.open(FONTS).then((c) => c.match(req).then((hit) => {
      const net = fetch(req).then((r) => { if (r.ok || r.type === "opaque") c.put(req, r.clone()); return r; }).catch(() => hit);
      return hit || net;
    })));
    return;
  }
  if (url.origin !== location.origin) return; // قاعدة البيانات تمشي عادي
  if (req.mode === "navigate" || /\.(html|js)$/.test(url.pathname) || url.pathname.endsWith("/")) {
    e.respondWith(fetch(req, { cache: "no-cache" }).then((r) => {
      if (r.ok) { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
      return r;
    }).catch(() => caches.match(req, { ignoreSearch: true }).then((r) => r || caches.match("./index.html"))));
    return;
  }
  e.respondWith(caches.match(req).then((r) => r || fetch(req)));
});

// الإشعارات: تصل حتى لو سند مسكّر، وبالضغط عليها يفتح الطلب نفسه
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data ? e.data.text() : "" }; }
  const opts = { body: d.body || "", icon: "icons/icon-192.png", lang: "ar", dir: "rtl", data: { url: d.url || "./" } };
  if (d.tag) { opts.tag = d.tag; opts.renotify = true; }
  e.waitUntil((async () => {
    await self.registration.showNotification(d.title || "سند", opts);
    if (typeof d.badge === "number" && self.navigator && self.navigator.setAppBadge) { try { await self.navigator.setAppBadge(d.badge); } catch (err) { /* not supported */ } }
    const open = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    open.forEach((c) => c.postMessage({ type: "sanad-push" }));
  })());
});
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "./", self.registration.scope).href;
  e.waitUntil((async () => {
    const open = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of open) {
      if (c.url.startsWith(self.registration.scope)) {
        c.postMessage({ type: "sanad-open", url });
        try { return await c.focus(); } catch (err) { return undefined; }
      }
    }
    return self.clients.openWindow(url);
  })());
});
