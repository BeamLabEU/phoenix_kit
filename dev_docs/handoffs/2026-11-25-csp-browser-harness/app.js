window.liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  hooks: window.PhoenixKitHooks || {},
  params: { _csrf_token: document.querySelector("meta[name='csrf-token']").getAttribute("content") },
});
window.liveSocket.connect();
