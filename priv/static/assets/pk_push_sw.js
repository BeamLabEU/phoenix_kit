/* PhoenixKit push service worker (PhoenixKit.Notifications.Push).
 *
 * Served by core at <prefix>/push/sw.js with `self.PK_PUSH = {key, resubscribe}`
 * in front of this file. Deliberately small:
 *   - a notification is built only from the push's own payload: no fetch in
 *     the push handler (it would fail offline, and on iOS a push that shows
 *     nothing gets the permission taken away);
 *   - every push shows a notification; the `tag` is per account, so a newer
 *     push replaces the older one on screen ("3 notifications pending")
 *     without sounding again (`renotify: false`);
 *   - a click opens the address the server put in the payload, only on this
 *     site's own origin;
 *   - a subscription the browser rotates is re-made and sent to the server,
 *     proven by the old subscription's secret.
 * No fetch handler: this worker never sits between the site and the network.
 */
(function () {
  "use strict";

  var config = self.PK_PUSH || {};

  self.addEventListener("install", function () {
    self.skipWaiting();
  });

  self.addEventListener("activate", function (event) {
    event.waitUntil(self.clients.claim());
  });

  // The worker lives at <prefix>/push/sw.js. A refused or missing click
  // target opens the kit's root, not the host's, when the kit is mounted
  // under a prefix.
  function appHome() {
    var path = self.location.pathname;
    var at = path.lastIndexOf("/push/");
    var root = at >= 0 ? path.slice(0, at) : "";
    return self.location.origin + root + "/";
  }

  function sameOrigin(url) {
    try {
      var parsed = new URL(url, self.location.origin);
      return parsed.origin === self.location.origin ? parsed.href : appHome();
    } catch (_e) {
      return appHome();
    }
  }

  self.addEventListener("push", function (event) {
    var data = {};
    try {
      data = event.data ? event.data.json() : {};
    } catch (_e) {
      data = {};
    }

    var options = {
      body: typeof data.body === "string" ? data.body : "",
      tag: typeof data.tag === "string" ? data.tag : "pk",
      renotify: false,
      data: { url: sameOrigin(data.url || appHome()) }
    };
    if (typeof data.icon === "string" && data.icon) options.icon = data.icon;

    var shown = self.registration.showNotification(
      typeof data.title === "string" && data.title ? data.title : "Notification",
      options
    );

    var badge = Promise.resolve();
    if (self.navigator && typeof self.navigator.setAppBadge === "function" && data.count > 0) {
      badge = self.navigator.setAppBadge(data.count).catch(function () {});
    }

    event.waitUntil(Promise.all([shown, badge]));
  });

  self.addEventListener("notificationclick", function (event) {
    event.notification.close();
    var url = sameOrigin((event.notification.data || {}).url || appHome());

    var clear = Promise.resolve();
    if (self.navigator && typeof self.navigator.clearAppBadge === "function") {
      clear = self.navigator.clearAppBadge().catch(function () {});
    }

    // openWindow stays inside the click's promise chain, or browsers drop it.
    event.waitUntil(Promise.all([clear, self.clients.openWindow(url)]));
  });

  function b64(buffer) {
    if (!buffer) return null;
    var bytes = new Uint8Array(buffer);
    var text = "";
    for (var i = 0; i < bytes.length; i++) text += String.fromCharCode(bytes[i]);
    return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  self.addEventListener("pushsubscriptionchange", function (event) {
    var old = event.oldSubscription;
    if (!old || !config.key || !config.resubscribe) return;

    var key = Uint8Array.from(atob(config.key.replace(/-/g, "+").replace(/_/g, "/")), function (c) {
      return c.charCodeAt(0);
    });

    event.waitUntil(
      self.registration.pushManager
        .subscribe({ userVisibleOnly: true, applicationServerKey: key })
        .then(function (subscription) {
          return fetch(config.resubscribe, {
            method: "POST",
            credentials: "omit",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              old_endpoint: old.endpoint,
              old_auth: b64(old.getKey("auth")),
              subscription: subscription.toJSON()
            })
          });
        })
        .catch(function () {})
    );
  });
})();
