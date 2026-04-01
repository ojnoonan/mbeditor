// Minimal service worker for installability without intercepting requests.
self.addEventListener('install', function() {
	self.skipWaiting();
});

self.addEventListener('activate', function(event) {
	event.waitUntil(self.clients.claim());
});
