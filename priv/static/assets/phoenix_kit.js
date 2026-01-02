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

// Import the cookie consent module
import "./phoenix_kit_consent.js";

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

  // Register CookieConsent hook (set by phoenix_kit_consent.js)
  // This hook is registered directly in the consent module

  // ResetSelect hook - resets select element to first option on push event
  window.PhoenixKitHooks.ResetSelect = {
    mounted() {
      this.handleEvent("reset_select", ({id}) => {
        if (this.el.id === id) {
          this.el.selectedIndex = 0;
        }
      });
    }
  };

  // TimeAgo hook - client-side relative time updates with variable interval
  // Updates frequently for recent times, less often for older times (accessibility-friendly)
  window.PhoenixKitHooks.TimeAgo = {
    mounted() {
      const timestamp = this.el.getAttribute("data-datetime");
      if (!timestamp) return;

      // Validate timestamp before scheduling updates
      const parsed = new Date(timestamp);
      if (isNaN(parsed.getTime())) {
        console.warn("TimeAgo: Invalid timestamp", timestamp);
        return;
      }

      this.timestamp = timestamp;
      this.parsedTime = parsed.getTime(); // Cache parsed epoch for efficiency
      this.update();
      this.scheduleUpdate();
    },

    destroyed() {
      this.clearTimer();
    },

    // Clear timer when LiveView temporarily disconnects
    disconnected() {
      this.clearTimer();
    },

    // Restart timer when LiveView reconnects
    reconnected() {
      if (this.timestamp) {
        this.update();
        this.scheduleUpdate();
      }
    },

    updated() {
      // Handle LiveView updates (e.g., new datetime value)
      const newTimestamp = this.el.getAttribute("data-datetime");
      if (newTimestamp && newTimestamp !== this.timestamp) {
        const parsed = new Date(newTimestamp);
        if (isNaN(parsed.getTime())) return;

        this.timestamp = newTimestamp;
        this.parsedTime = parsed.getTime();
        this.update();
        this.scheduleUpdate();
      }
    },

    clearTimer() {
      if (this.timer) {
        clearTimeout(this.timer);
        this.timer = null;
      }
    },

    scheduleUpdate() {
      this.clearTimer();
      const interval = this.getInterval();
      this.timer = setTimeout(() => {
        this.update();
        this.scheduleUpdate();
      }, interval);
    },

    update() {
      const text = this.getRelativeTime();
      if (text && this.el.textContent !== text) {
        this.el.textContent = text;
      }
    },

    getRelativeTime() {
      const now = Date.now();
      const seconds = Math.round((now - this.parsedTime) / 1000);

      if (seconds < 0) return "just now";
      if (seconds < 60) return seconds + "s ago";

      const minutes = Math.round(seconds / 60);
      if (minutes < 60) return minutes + "m ago";

      const hours = Math.round(minutes / 60);
      if (hours < 24) return hours + "h ago";

      const days = Math.round(hours / 24);
      return days + "d ago";
    },

    getInterval() {
      const seconds = Math.round((Date.now() - this.parsedTime) / 1000);
      // Update every second for first minute
      if (seconds < 60) return 1000;
      // Update every 30 seconds for first hour
      if (seconds < 3600) return 30000;
      // Update every 5 minutes for first day
      if (seconds < 86400) return 300000;
      // Update every hour for older times
      return 3600000;
    }
  };

  // Log successful initialization in development
  if (typeof console !== "undefined" && console.debug) {
    var hookCount = Object.keys(window.PhoenixKitHooks).length;
    if (hookCount > 0) {
      console.debug("[PhoenixKit] Initialized with " + hookCount + " hook(s):", Object.keys(window.PhoenixKitHooks));
    }
  }
})();
