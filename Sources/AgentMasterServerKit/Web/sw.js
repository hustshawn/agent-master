// AgentMaster service worker: keeps a copy of the static app shell so the PWA opens offline, and relays
// Web Push notifications. Never caches /api — that is always live data. The network comes first, so a
// server upgrade reaches clients on their next load; the copy is only for when the server is unreachable.
"use strict";

const CACHE = "agentmaster-4";
const ASSETS = [
  "./", "index.html", "app.css", "app.js", "icon.png", "manifest.webmanifest",
  "vendor/xterm.css", "vendor/xterm.js", "vendor/addon-fit.js", "vendor/addon-web-links.js", "vendor/marked.min.js",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== location.origin || url.pathname.startsWith("/api")) return;
  event.respondWith(
    fetch(event.request).then((response) => {
      if (response.ok) {
        const copy = response.clone();
        caches.open(CACHE).then((cache) => cache.put(event.request, copy));
      }
      return response;
    }).catch(() => caches.match(event.request).then((cached) => cached ?? Response.error())));
});

// Push payload (see WebPush.swift): {"title", "body", "sessionId", "tag"}.
self.addEventListener("push", (event) => {
  const data = event.data?.json() ?? {};
  event.waitUntil(self.registration.showNotification(data.title ?? "AgentMaster", {
    body: data.body, tag: data.tag, data: { sessionId: data.sessionId },
    icon: "icon.png", badge: "icon.png",
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const sessionId = event.notification.data?.sessionId;
  const url = sessionId ? `./#session=${encodeURIComponent(sessionId)}` : "./";
  event.waitUntil(
    self.clients.matchAll({ type: "window" }).then((clients) => {
      for (const client of clients) {
        if (new URL(client.url).origin === location.origin) {
          client.navigate(url);
          return client.focus();
        }
      }
      return self.clients.openWindow(url);
    }));
});
