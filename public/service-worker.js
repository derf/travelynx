const CACHE_NAME = 'static-cache-v37';
const FILES_TO_CACHE = [
  '/favicon.ico',
  '/offline.html',
  '/static/v37/css/light.min.css',
  '/static/v37/css/dark.min.css',
  '/static/v37/css/material-icons.css',
  '/static/v37/css/local.css',
  '/static/v37/fonts/MaterialIcons-Regular.woff2',
  '/static/v37/fonts/MaterialIcons-Regular.woff',
  '/static/v37/fonts/MaterialIcons-Regular.ttf',
  '/static/v37/js/jquery-3.4.1.min.js',
  '/static/v37/js/materialize.min.js',
  '/static/v37/js/travelynx-actions.min.js',
  '/static/v37/js/autocomplete.min.js',
  '/static/v37/js/geolocation.min.js',
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
