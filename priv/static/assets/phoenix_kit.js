/**
 * PhoenixKit JavaScript
 *
 * Main entry point for all PhoenixKit JavaScript functionality.
 * Auto-imports all PhoenixKit JS modules and exposes hooks for LiveView.
 *
 * This file is copied to your assets/js/vendor/ directory during installation.
 *
 * SETUP: Import in your app.js BEFORE creating liveSocket:
 *
 *   import "./vendor/phoenix_kit"
 *
 *   let liveSocket = new LiveSocket("/live", Socket, {
 *     hooks: { ...window.PhoenixKitHooks, ...Hooks },
 *     // ... other options
 *   })
 *
 * That's it! All PhoenixKit hooks are automatically registered.
 */

// Import the sortable module (same vendor directory)
import "./phoenix_kit_sortable.js";

(function() {
  "use strict";

  // Prevent double initialization
  if (window.PhoenixKitInitialized) return;
  window.PhoenixKitInitialized = true;

  // Initialize hooks collection
  window.PhoenixKitHooks = window.PhoenixKitHooks || {};

  // Register SortableGrid hook (set by phoenix_kit_sortable.js)
  if (window.SortableGridHook) {
    window.PhoenixKitHooks.SortableGrid = window.SortableGridHook;
  }

  // Log successful initialization in development
  if (typeof console !== "undefined" && console.debug) {
    var hookCount = Object.keys(window.PhoenixKitHooks).length;
    if (hookCount > 0) {
      console.debug("[PhoenixKit] Initialized with " + hookCount + " hook(s):", Object.keys(window.PhoenixKitHooks));
    }
  }
})();
