const CACHE_VERSION = 'v1';
const STATIC_CACHE = 'notekeeper-static-' + CACHE_VERSION;
const NOTES_CACHE = 'notekeeper-notes-' + CACHE_VERSION;

// App shell files to cache on install
const STATIC_FILES = [
  './',
  './bootstrap.5.3.3.min.css',
  './bootstrap.5.3.3.min.js',
  './htmx.2.0.7.min.js',
  './ws.2.0.1.js',
  './debug.2.0.1.js',
  './loading-states.2.0.1.js',
  './morphdom-esm.2.7.4.js',
  './app-notekeeper.js',
  './notes.css',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './manifest.json'
];

// Install: cache static assets
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(STATIC_CACHE)
      .then((cache) => cache.addAll(STATIC_FILES))
      .then(() => self.skipWaiting())
  );
});

// Activate: clean old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys
          .filter((key) => key !== STATIC_CACHE && key !== NOTES_CACHE)
          .map((key) => caches.delete(key))
      );
    }).then(() => self.clients.claim())
  );
});

// Fetch: handle requests
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Only handle same-origin requests
  if (url.origin !== location.origin) {
    return;
  }

  // Block mutations when offline
  if (!navigator.onLine && ['POST', 'PUT', 'DELETE', 'PATCH'].includes(event.request.method)) {
    // We should store the request in our local storage here, keyed by the
    // resource key (uri) -> (parameters)
    // for later replay once we go online again
    event.respondWith(
      new Response(
        '<div class="alert alert-warning">You are offline. Changes cannot be saved.</div>',
        {
          status: 503,
          headers: { 'Content-Type': 'text/html' }
        }
      )
    );
    return;
  }

  // For note pages: network-first, cache on success
  if (url.pathname.startsWith('/note/')) {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(NOTES_CACHE).then((cache) => cache.put(event.request, clone));
          }
          return response;
        })
        .catch(() => caches.match(event.request))
        .then((response) => response || offlineFallback('note'))
    );
    return;
  }

  // For documents list: network-first, cache fallback
  if (url.pathname === '/documents' || url.pathname === '/') {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(NOTES_CACHE).then((cache) => cache.put(event.request, clone));
          }
          return response;
        })
        .catch(() => caches.match(event.request))
        .then((response) => response || offlineFallback('list'))
    );
    return;
  }

  // For static assets: cache-first
  event.respondWith(
    caches.match(event.request)
      .then((cached) => cached || fetch(event.request))
  );
});

function offlineFallback(type) {
  const messages = {
    note: '<div class="alert alert-info m-3">This note is not available offline yet. View a note while online to cache it.</div>',
    list: '<div class="alert alert-info m-3">Your notes list is not available offline. Please connect to the internet.</div>'
  };
  return new Response(messages[type] || messages.list, {
    status: 200,
    headers: { 'Content-Type': 'text/html' }
  });
}
