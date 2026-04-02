// Minimal service worker for Mbeditor. Registers the SW scope without
// intercepting fetch requests — the browser handles all network traffic normally.

self.addEventListener('install', function(event) {
  self.skipWaiting();
});

self.addEventListener('activate', function(event) {
  event.waitUntil(self.clients.claim());
});
