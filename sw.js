// BeRightBack service worker.
// 1) lets the app show pop-up notifications on phones and laptops
// 2) keeps a copy of the app page so it can open even without internet (it always loads the newest version first)
// It never stores your messages or personal data.
const CACHE = 'brb-shell-v1';
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET' || new URL(r.url).origin !== location.origin) return;
  e.respondWith(fetch(r).then(res => { if (res.ok) { const c = res.clone(); caches.open(CACHE).then(ch => ch.put(r, c)); } return res; })
    .catch(() => caches.match(r).then(m => m || caches.match('./index.html'))));
});
self.addEventListener('push', e => {
  let d = {}; try { d = e.data.json(); } catch (x) {}
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    if (list.some(c => c.visibilityState === 'visible')) return;   // the app is open in front: it already shows the message
    return self.registration.showNotification(d.title || 'BeRightBack', { body: d.body || 'New message', tag: d.tag || 'brb', icon: 'icon-192.png', badge: 'icon-192.png', renotify: true, data: { open: d.open || '' } });
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const open = (e.notification.data && e.notification.data.open) || '';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) { if ('focus' in c) { if (open) c.postMessage({ open }); return c.focus(); } }
    return self.clients.openWindow('./');
  }));
});
