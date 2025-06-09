const CACHE_NAME = 'static-cache-v86';
const FILES_TO_CACHE = [
  '/favicon.ico',
  '/offline.html',
  '/static/v86/css/light.min.css',
  '/static/v86/css/dark.min.css',
  '/static/v86/css/material-icons.css',
  '/static/v86/fonts/MaterialIcons-Regular.woff2',
  '/static/v86/fonts/MaterialIcons-Regular.woff',
  '/static/v86/fonts/MaterialIcons-Regular.ttf',
  '/static/v86/js/jquery-3.4.1.min.js',
  '/static/v86/js/materialize.min.js',
  '/static/v86/js/travelynx-actions.min.js',
  '/static/v86/js/autocomplete.min.js',
  '/static/v86/js/geolocation.min.js',
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
