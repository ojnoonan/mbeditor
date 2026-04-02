// Cache-first service worker for Mbeditor static assets.
// Sprockets assets have content-hash fingerprints so they are safe to cache
// indefinitely. Monaco editor files are also immutable between gem updates.
// Bump CACHE_VERSION when deploying a new gem version to force cache eviction.
const CACHE_VERSION = 'mbeditor-v1';

self.addEventListener('install', function(event) {
  self.skipWaiting();
});

self.addEventListener('activate', function(event) {
  // Delete all caches from previous versions on activation.
  event.waitUntil(
    caches.keys().then(function(keys) {
      return Promise.all(
        keys.filter(function(key) { return key !== CACHE_VERSION; })
            .map(function(key) { return caches.delete(key); })
      );
    }).then(function() { return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function(event) {
  if (event.request.method !== 'GET') return;

  var url = event.request.url;

  // Only cache Sprockets-fingerprinted assets and Monaco editor files.
  // Everything else (HTML, API calls) goes through normally.
  var isCacheable = url.includes('/assets/') || url.includes('/monaco-editor/');
  if (!isCacheable) return;

  event.respondWith(
    caches.open(CACHE_VERSION).then(function(cache) {
      return cache.match(event.request).then(function(cached) {
        if (cached) return cached;
        return fetch(event.request).then(function(response) {
          // Only cache successful, non-opaque responses.
          if (response.ok && response.type !== 'opaque') {
            cache.put(event.request, response.clone());
          }
          return response;
        });
      });
    })
  );
});
