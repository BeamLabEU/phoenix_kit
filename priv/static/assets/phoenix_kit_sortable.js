/**
 * PhoenixKit Sortable Grid
 *
 * Auto-loads SortableJS from CDN and provides drag-and-drop functionality
 * for the sortable_grid component.
 *
 * SETUP: Add the hook to your app.js:
 *
 *   // In assets/js/app.js, add to your Hooks object:
 *   import "../../../deps/phoenix_kit/priv/static/assets/phoenix_kit_sortable.js"
 *
 *   let Hooks = {
 *     // ... your other hooks ...
 *     SortableGrid: window.SortableGridHook
 *   }
 *
 *   let liveSocket = new LiveSocket("/live", Socket, {
 *     hooks: Hooks,
 *     // ... other options
 *   })
 *
 * That's it! The hook auto-loads SortableJS from CDN when needed.
 */
(function() {
  "use strict";

  // Prevent multiple initializations
  if (window.PhoenixKitSortable) return;
  window.PhoenixKitSortable = true;

  var SORTABLE_CDN = "https://cdn.jsdelivr.net/npm/sortablejs@1.15.0/Sortable.min.js";
  var sortableLoading = false;
  var sortableCallbacks = [];
  var stylesInjected = false;

  /**
   * Inject CSS styles for sortable classes
   */
  function injectStyles() {
    if (stylesInjected) return;
    stylesInjected = true;

    var style = document.createElement("style");
    style.textContent = [
      ".sortable-ghost { opacity: 0.5; }",
      ".sortable-chosen { outline: 2px solid oklch(var(--p)); outline-offset: 2px; }",
      ".sortable-drag { box-shadow: 0 10px 15px -3px rgba(0,0,0,0.1), 0 4px 6px -2px rgba(0,0,0,0.05); }"
    ].join("\n");
    document.head.appendChild(style);
  }

  /**
   * Load SortableJS from CDN if not already loaded
   */
  function loadSortableJS(callback) {
    if (window.Sortable) {
      callback();
      return;
    }

    sortableCallbacks.push(callback);

    if (sortableLoading) return;
    sortableLoading = true;

    var script = document.createElement("script");
    script.src = SORTABLE_CDN;
    script.onload = function() {
      sortableCallbacks.forEach(function(cb) { cb(); });
      sortableCallbacks = [];
    };
    script.onerror = function() {
      console.error("[PhoenixKitSortable] Failed to load SortableJS from CDN");
    };
    document.head.appendChild(script);
  }

  /**
   * LiveView Hook for sortable grids
   */
  var SortableGridHook = {
    mounted: function() {
      var self = this;
      loadSortableJS(function() {
        // Small delay to let LiveView finish any initial DOM morphing
        setTimeout(function() {
          self.initSortable();
        }, 100);
      });
    },

    updated: function() {
      // Re-init if items changed
      if (this.sortable) {
        var currentItems = this.el.querySelectorAll(".sortable-item[data-id]");
        if (currentItems.length !== this._itemCount) {
          this.sortable.destroy();
          this.initSortable();
        }
      }
    },

    destroyed: function() {
      if (this.sortable) {
        this.sortable.destroy();
        this.sortable = null;
      }
    },

    initSortable: function() {
      var self = this;
      var container = this.el;
      var eventName = container.dataset.sortableEvent || "reorder_items";

      // Inject CSS styles for sortable classes
      injectStyles();

      this._itemCount = container.querySelectorAll(".sortable-item[data-id]").length;

      this.sortable = window.Sortable.create(container, {
        animation: 150,
        draggable: ".sortable-item",
        filter: ".sortable-ignore",
        forceFallback: true,  // Use JS-based drag instead of native HTML5 drag (avoids image drag conflicts)
        fallbackOnBody: true,  // Fixes offset in modals with CSS transforms
        ghostClass: "sortable-ghost",
        chosenClass: "sortable-chosen",
        dragClass: "sortable-drag",
        onEnd: function(evt) {
          // Get new order of item IDs
          var items = container.querySelectorAll(".sortable-item[data-id]");
          var orderedIds = Array.from(items).map(function(el) {
            return el.dataset.id;
          });

          // Push event to LiveView
          self.pushEvent(eventName, { ordered_ids: orderedIds });
        }
      });
    }
  };

  // Export for window (hook registration)
  window.SortableGridHook = SortableGridHook;
})();
