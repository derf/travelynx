const CACHE_NAME = 'static-cache-v91';
const FILES_TO_CACHE = [
  '/favicon.ico',
  '/offline.html',
  '/static/v91/css/light.min.css',
  '/static/v91/css/dark.min.css',
  '/static/v91/css/material-icons.css',
  '/static/v91/fonts/MaterialIcons-Regular.woff2',
  '/static/v91/fonts/MaterialIcons-Regular.woff',
  '/static/v91/fonts/MaterialIcons-Regular.ttf',
  '/static/v91/js/jquery-3.4.1.min.js',
  '/static/v91/js/materialize.min.js',
  '/static/v91/js/travelynx-actions.min.js',
  '/static/v91/js/autocomplete.min.js',
  '/static/v91/js/geolocation.min.js',
];

self.addEventListener('install', (evt) => {
  evt.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(FILES_TO_CACHE);
    })
  );
  self.skipWaiting();
});

self.addEventListener('activate', (evt) => {
  evt.waitUntil(
    caches.keys().then((keyList) => {
      return Promise.all(keyList.map((key) => {
        if (key !== CACHE_NAME) {
          return caches.delete(key);
        }
      }));
    })
  );
  self.clients.claim();
});

self.addEventListener('fetch', (evt) => {
  if (evt.request.mode !== 'navigate') {
    return;
  }
  evt.respondWith(
    fetch(evt.request)
        .catch(() => {
          return caches.open(CACHE_NAME)
              .then((cache) => {
                return cache.match('offline.html');
              });
        })
  );
});
