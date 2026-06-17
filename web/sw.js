// 最小限のサービスワーカー（PWAインストール要件を満たすだけ）
// ゲームはリアルタイム通信のためキャッシュせず常にネットワーク優先
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => e.respondWith(fetch(e.request)));
