const CACHE_NAME = "freehand-preguntados-shell-v2";
self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const base = self.registration.scope;
    const cache = await caches.open(CACHE_NAME);
    await cache.addAll([
      base,
      base + "index.html",
      base + "roulette-admin.html",
      base + "manifest.webmanifest",
      base + "manifest-admin.webmanifest",
      base + "assets/freehand-app-icon.svg"
    ]);
    await self.skipWaiting();
  })());
});
self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(key => key.startsWith("freehand-preguntados-") && key !== CACHE_NAME).map(key => caches.delete(key)));
    await self.clients.claim();
  })());
});
self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  const base = self.registration.scope;
  if (url.origin !== self.location.origin || !url.href.startsWith(base)) return;
  if (request.mode === "navigate") {
    event.respondWith((async () => {
      try {
        const response = await fetch(request);
        if (response && response.ok) {
          const cache = await caches.open(CACHE_NAME);
          await cache.put(request, response.clone());
        }
        return response;
      } catch {
        const cached = await caches.match(request) || await caches.match(base + "index.html") || await caches.match(base);
        return cached || new Response("FREEHAND está sin conexión. Volvé a conectarte para jugar y validar premios.", {status:503,headers:{"Content-Type":"text/plain; charset=utf-8"}});
      }
    })());
    return;
  }
  event.respondWith((async () => {
    const cached = await caches.match(request);
    const refresh = fetch(request).then(async response => {
      if (response && response.ok) {
        const cache = await caches.open(CACHE_NAME);
        await cache.put(request, response.clone());
      }
      return response;
    });
    if (cached) {
      event.waitUntil(refresh.catch(() => undefined));
      return cached;
    }
    try { return await refresh; }
    catch { return new Response("", {status:504}); }
  })());
});
