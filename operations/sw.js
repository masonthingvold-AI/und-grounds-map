const CACHE='und-grounds-live-v1';
const FILES=['./','index.html','theme.css','shell.css','styles.css','live-app.mjs','api.mjs','public-config.mjs','worker.mjs','shifts.mjs','store.mjs','proof.mjs','queue.mjs','queue-view.mjs','offline-read.mjs','dispatch.mjs','certifications.mjs','planning.mjs','shell.mjs','views.mjs','assets/und_leaders_rev.png','vendor/supabase.js','vendor/lucide.min.js','../vendor/leaflet.js','../vendor/leaflet.css'];
const allowed=new Set(FILES.map(p=>new URL(p,self.location.href).href));
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(FILES))));
self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));
self.addEventListener('fetch',event=>{if(event.request.method!=='GET'||!allowed.has(event.request.url))return;event.respondWith(fetch(event.request).then(response=>{if(response.ok){const copy=response.clone();event.waitUntil(caches.open(CACHE).then(cache=>cache.put(event.request,copy)));}return response;}).catch(()=>caches.match(event.request)));});
