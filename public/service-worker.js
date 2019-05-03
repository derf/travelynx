const CACHE_NAME = 'static-cache-v10';
const FILES_TO_CACHE = [
  '/offline.html',
  '/static/v10/css/materialize.min.css',
  '/static/v10/css/material-icons.css',
  '/static/v10/css/local.css',
  '/static/v10/js/jquery-2.2.4.min.js',
  '/static/v10/js/materialize.min.js',
  '/static/v10/js/travelynx-actions.min.js',
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
