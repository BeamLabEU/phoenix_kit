/**
 * PhoenixKit admin hooks
 * ============================================================================
 *
 * The hooks that only the admin area and the user dashboard use, split out of
 * phoenix_kit.js so a public page never downloads them. Nothing includes this
 * file by hand: phoenix_kit.js registers a stub under each hook's name, and
 * the first stub to mount loads this file (vendored by the
 * `:phoenix_kit_js_sources` compiler as a library, named in
 * `window.PHOENIX_KIT_LIBS.admin`) and hands the real hook the LiveView
 * instance. See dev_docs/plans/2026-10-27-public-admin-js-split.md.
 *
 * It registers into `window.PhoenixKitAdminHooks`, never into
 * `window.PhoenixKitHooks`: a host's LiveSocket was built from a copy of that
 * object, so a hook added to it now would not be seen. It must run after
 * phoenix_kit.js (it uses the helpers phoenix_kit.js shares through
 * `window.PhoenixKitInternals`).
 *
 * @license MIT
 */

(function() {
  "use strict";

  if (window.PhoenixKitAdminLoaded) return;

  var PK = window.PhoenixKitInternals;
  if (!PK) {
    throw new Error("[PhoenixKit] phoenix_kit_admin.js must load after phoenix_kit.js");
  }

  window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};

  // Shared with phoenix_kit.js.
  var lazyHook = PK.lazyHook;
  var loadChartJs = PK.loadChartJs;
  var loadVendored = PK.loadVendored;
  var pkLoaders = PK.pkLoaders;




  // ============================================================================
  // 1. SORTABLE MODULE
  // ============================================================================
  //
  // Provides drag-and-drop reordering for grids and lists.
  // Loads SortableJS (the host's vendored copy, see ViewerLibraries) when first used.
  //
  // Usage in LiveView template:
  //   <div id="my-grid" phx-hook="SortableGrid" data-sortable-event="reorder_items">
  //     <div class="sortable-item" data-id="1">Item 1</div>
  //     <div class="sortable-item" data-id="2">Item 2</div>
  //   </div>
  //
  // Handle in LiveView:
  //   def handle_event("reorder_items", %{"ordered_ids" => ids}, socket)
  //
  // ============================================================================

  (function() {
    if (window.PhoenixKitSortable) return;
    window.PhoenixKitSortable = true;

    // ---------------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------------

    var stylesInjected = false;

    // ---------------------------------------------------------------------------
    // Style Injection
    // ---------------------------------------------------------------------------

    function injectStyles() {
      if (stylesInjected) return;
      stylesInjected = true;

      var style = document.createElement("style");
      style.textContent = [
        ".sortable-ghost { opacity: 0.5; }",
        ".sortable-chosen { outline: 2px solid oklch(var(--p)); outline-offset: 2px; }",
        ".sortable-drag { box-shadow: 0 10px 15px -3px rgba(0,0,0,0.1), 0 4px 6px -2px rgba(0,0,0,0.05); }",
        "@keyframes pk-sortable-wiggle { 0%, 100% { transform: rotate(0deg); } 25% { transform: rotate(-1.5deg); } 75% { transform: rotate(1.5deg); } }",
        ".pk-sortable-wiggle { animation: pk-sortable-wiggle 0.4s ease-in-out infinite; }",
        ".pk-sortable-wiggle:nth-child(even) { animation-delay: 0.1s; }",
        ".pk-sortable-wiggle:nth-child(3n) { animation-delay: 0.2s; }",
        "@media (prefers-reduced-motion: reduce) { .pk-sortable-wiggle { animation: none; } }",
        // Selected-card indicator. The `<.table_default>` card view is
        // opaque to consumers (no per-item selected attr), so we lean
        // on :has() to paint any sortable card whose internal checkbox
        // is checked. Stronger than a flat tint: bumped bg + 4px
        // primary left border mirroring the table row treatment so
        // selection is unambiguous at a glance. Specificity (0,3,0) +
        // injection-after-Tailwind in source order means this wins
        // over `bg-base-200` without `!important`.
        ".sortable-item.card:has(input[type=\"checkbox\"]:checked) { background-color: oklch(var(--p) / 0.15); box-shadow: inset 4px 0 0 0 oklch(var(--p)); }",
        // Reorder result flash — green on success, red on failure.
        // The hook applies the class transiently after the LV emits a
        // sortable:flash push_event. We overlay a pseudo-element
        // (::after) instead of animating background-color directly,
        // so cards with their own bg (e.g. bg-base-200) don't briefly
        // become transparent during the keyframe interpolation and
        // bleed the page bg through.
        ".pk-sortable-flash-ok, .pk-sortable-flash-err { position: relative; }",
        ".pk-sortable-flash-ok::after, .pk-sortable-flash-err::after { content: ''; position: absolute; inset: 0; pointer-events: none; border-radius: inherit; z-index: 1; }",
        "@keyframes pk-sortable-flash-ok { 0% { background-color: rgba(34, 197, 94, 0); } 15% { background-color: rgba(34, 197, 94, 0.35); } 100% { background-color: rgba(34, 197, 94, 0); } }",
        "@keyframes pk-sortable-flash-err { 0% { background-color: rgba(239, 68, 68, 0); } 15% { background-color: rgba(239, 68, 68, 0.35); } 100% { background-color: rgba(239, 68, 68, 0); } }",
        ".pk-sortable-flash-ok::after { animation: pk-sortable-flash-ok 1.1s ease-out; }",
        ".pk-sortable-flash-err::after { animation: pk-sortable-flash-err 1.1s ease-out; }",
        "@media (prefers-reduced-motion: reduce) { .pk-sortable-flash-ok::after, .pk-sortable-flash-err::after { animation: none; } }",
        // Every sortable_handle consumer restricts drag-initiation to this
        // class — without `touch-action: none` on it, iOS/Android treat the
        // first touchmove as a page-scroll gesture and claim it before
        // SortableJS's (forceFallback) touch handling ever sees it, so drag
        // silently never starts on a touch device. `-webkit-user-select` /
        // `user-select: none` stop a long-press from opening the text/image
        // selection UI instead of dragging. Purely behavioral — no padding
        // or sizing here, since some consumers (table_default's <td>
        // handle) already size their own tap target and a blanket margin
        // hack would be a no-op-or-worse on a table cell.
        ".pk-drag-handle { touch-action: none; -webkit-user-select: none; user-select: none; }"
      ].join("\n");
      document.head.appendChild(style);
    }

    // ---------------------------------------------------------------------------
    // Loading (the host's vendored copy)
    // ---------------------------------------------------------------------------

    // Through the shared loader; the callback runs only once SortableJS is
    // usable. A failure is reported there, and the list stays unsortable.
    function loadSortableJS(callback) {
      loadVendored("SortableJS", "sortable", {
        check: function() { return typeof window.Sortable === "function"; }
      }).then(callback, function() {});
    }

    // ---------------------------------------------------------------------------
    // SortableGrid Hook
    // ---------------------------------------------------------------------------

    window.PhoenixKitAdminHooks.SortableGrid = {
      mounted: function() {
        var self = this;

        // Server-driven flash: the LV pushes `sortable:flash` after each
        // reorder attempt with `{uuid, status: "ok" | "error"}`. We
        // find the row by `data-id` and apply a transient highlight
        // class. Idempotent — the offsetWidth read forces a reflow so
        // re-flashing the same row restarts the animation.
        this.handleEvent("sortable:flash", function(payload) {
          if (!payload || !payload.uuid) return;
          // Apply to *every* element with the data-id — table view and
          // card view each render the same item, so both DOM nodes
          // need the class. Whichever is currently visible (md:
          // breakpoint controls it) animates in front of the user.
          var items = document.querySelectorAll(
            '[data-id="' + payload.uuid + '"]'
          );
          if (!items.length) return;
          // Explicit map — treat anything that isn't "ok" or "error" as
          // a typo on the server side and bail rather than silently
          // falling into the err-class branch.
          var cls =
            payload.status === "ok"
              ? "pk-sortable-flash-ok"
              : payload.status === "error"
                ? "pk-sortable-flash-err"
                : null;
          if (!cls) return;
          items.forEach(function(item) {
            item.classList.remove(
              "pk-sortable-flash-ok",
              "pk-sortable-flash-err"
            );
            // Force reflow so a second consecutive flash re-runs the
            // keyframes on this element.
            void item.offsetWidth;
            item.classList.add(cls);
          });
          setTimeout(function() {
            items.forEach(function(item) {
              item.classList.remove(cls);
            });
          }, 1200);
        });

        loadSortableJS(function() {
          setTimeout(function() {
            self.initSortable();
          }, 100);
        });
      },

      updated: function() {
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
        var hideSource = container.dataset.sortableHideSource === "true";
        var groupName = container.dataset.sortableGroup;
        // Optional drag-handle selector. When set, SortableJS only initiates
        // a drag when the pointer is over a descendant matching this selector
        // — the rest of the .sortable-item is non-draggable surface (clicks,
        // text selection, button presses pass through normally). Unset →
        // backward-compatible whole-item drag.
        var handleSelector = container.dataset.sortableHandle;

        injectStyles();

        this._itemCount = container.querySelectorAll(".sortable-item[data-id]").length;

        // Helper: read all data-sortable-scope-* attrs off an element and
        // turn them into a `{key: value}` map. dataset already gives
        // camelCase keys; we just strip the "sortableScope" prefix and
        // lowercase the first letter.
        var readScope = function(el) {
          var out = {};
          for (var key in el.dataset) {
            if (key.indexOf("sortableScope") === 0 && key.length > "sortableScope".length) {
              var fieldName = key.substring("sortableScope".length);
              fieldName = fieldName.charAt(0).toLowerCase() + fieldName.slice(1);
              out[fieldName] = el.dataset[key];
            }
          }
          return out;
        };

        // `pushEventTo` routes to the LiveComponent named by the selector;
        // plain `pushEvent` reaches only the host LiveView. LiveView consumers
        // omit `data-sortable-target`, so they keep the original behavior.
        var emitReorder = function(targetSelector, ev, payload) {
          if (targetSelector) {
            self.pushEventTo(targetSelector, ev, payload);
          } else {
            self.pushEvent(ev, payload);
          }
        };

        // SortableJS `group` controls which sortables can exchange items.
        // - String form: simple shared group (any matching name accepts/donates).
        // - Object form: {name, pull: true, put: true} when consumer needs
        //   explicit cross-container behavior. We keep it as a plain string
        //   here; the default pull/put = true is what cross-container DnD
        //   needs.
        var sortableOpts = {
          animation: 150,
          draggable: ".sortable-item",
          filter: ".sortable-ignore",
          forceFallback: true,
          fallbackOnBody: true,
          ghostClass: "sortable-ghost",
          chosenClass: "sortable-chosen",
          dragClass: "sortable-drag",
          // Lock <tr> cell widths before drag — when SortableJS clones
          // the row to <body> for the drag preview (forceFallback +
          // fallbackOnBody), the <tr> loses its <table> ancestor and
          // each <td> collapses to its content width. Snapshot the
          // computed widths and pin them inline so the floating row
          // keeps its column layout. Restore on drag end.
          onChoose: function(evt) {
            var item = evt.item;
            if (item && item.tagName === "TR") {
              item._pkCellWidths = [];
              var cells = item.children;
              for (var i = 0; i < cells.length; i++) {
                item._pkCellWidths.push(cells[i].style.width);
                cells[i].style.width = cells[i].offsetWidth + "px";
              }
            }
          },
          onUnchoose: function(evt) {
            var item = evt.item;
            if (item && item.tagName === "TR" && item._pkCellWidths) {
              var cells = item.children;
              for (var i = 0; i < cells.length && i < item._pkCellWidths.length; i++) {
                cells[i].style.width = item._pkCellWidths[i];
              }
              delete item._pkCellWidths;
            }
          },
          onStart: function() {
            if (hideSource) {
              setTimeout(function() {
                var fallback = document.querySelector("body > .sortable-fallback");
                if (fallback) fallback.style.display = "none";
              }, 0);
            }
          },
          // onEnd assumes the hook has exclusive control over the
          // .sortable-item nodes inside its container — i.e. the LV
          // owns this DOM subtree. If a third-party script ever
          // injects nodes with `class="sortable-item" data-id=...`
          // alongside ours, those IDs will be picked up by the
          // querySelectorAll below; the LV handler should then
          // reject unknown IDs at the server side. Trust your own DOM.
          //
          // The whole body is wrapped in try/catch so a single bad
          // dataset value (e.g. corrupt JSON in a custom scope attr,
          // or a missing source container after a fast unmount) flashes
          // a console error instead of leaving SortableJS in a half-
          // initialized state with the LV unable to reorder again.
          onEnd: function(evt) {
            try {
              var fromContainer = evt.from;
              var toContainer = evt.to;
              var crossContainer = fromContainer !== toContainer;

              // The destination container's items reflect the new ordering;
              // the source's lost one but its remaining order is preserved
              // by SortableJS, so we don't need a server reorder there.
              var destItems = toContainer.querySelectorAll(".sortable-item[data-id]");
              var orderedIds = Array.from(destItems).map(function(el) {
                return el.dataset.id;
              });

              // `moved_id` is always included so the LV can push back
               // a sortable:flash event keyed to the just-moved row.
              var payload = {
                ordered_ids: orderedIds,
                moved_id: evt.item.dataset.id
              };
              var destScope = readScope(toContainer);
              for (var k in destScope) payload[k] = destScope[k];

              if (crossContainer) {
                var fromScope = readScope(fromContainer);
                for (var k2 in fromScope) {
                  // Capitalize first letter so `categoryUuid` becomes
                  // `fromCategoryUuid` (camelCase preserved).
                  var capped = k2.charAt(0).toUpperCase() + k2.slice(1);
                  payload["from" + capped] = fromScope[k2];
                }
                // Use the destination's event name so the LV handler is
                // co-located with the table the item ended up in.
                var destEvent = toContainer.dataset.sortableEvent || eventName;
                emitReorder(toContainer.dataset.sortableTarget, destEvent, payload);
              } else {
                emitReorder(container.dataset.sortableTarget, eventName, payload);
              }
            } catch (err) {
              console.error("PhoenixKitAdminHooks.SortableGrid.onEnd failed:", err);
            }
          }
        };

        if (groupName) {
          sortableOpts.group = groupName;
        }

        if (handleSelector) {
          sortableOpts.handle = handleSelector;
        }

        this.sortable = window.Sortable.create(container, sortableOpts);
      }
    };
  })();


  // ============================================================================
  // 1.5. MEDIA IMAGE ZOOM HOOK
  // ============================================================================
  //
  // Lazy-loads Panzoom (the host's vendored copy, like SortableJS above) and
  // attaches it to a given <img> via the MediaImageZoom hook. Used by the
  // MediaBrowser modal viewer so users can wheel/pinch/double-tap zoom and
  // drag-pan the original image. The hook is only mounted on image files
  // (the modal's cond branch for non-images doesn't render the <img> tag).
  //
  // ============================================================================

  (function() {
    if (window.PhoenixKitMediaZoom) return;
    window.PhoenixKitMediaZoom = true;

    // Through the shared loader; see loadSortableJS.
    function loadPanzoom(callback) {
      loadVendored("Panzoom", "panzoom", {
        check: function() { return typeof window.Panzoom === "function"; }
      }).then(callback, function() {});
    }

    window.PhoenixKitAdminHooks.MediaImageZoom = {
      mounted: function() {
        var self = this;
        loadPanzoom(function() {
          // The element may have been swapped out (e.g. user closed the modal
          // or stepped to another file) while Panzoom was downloading.
          if (!self.el.isConnected) return;

          self.panzoom = window.Panzoom(self.el, {
            maxScale: 8,
            minScale: 1,
            contain: "outside",
            cursor: "grab"
          });

          // Wheel listener attaches to the parent so the cursor doesn't have
          // to land on the image itself. zoomWithWheel calls preventDefault,
          // stopping the wheel event from scrolling the page underneath.
          self._parent = self.el.parentElement;
          if (self._parent) {
            self._wheelHandler = function(e) {
              if (self.panzoom) self.panzoom.zoomWithWheel(e);
            };
            self._parent.addEventListener("wheel", self._wheelHandler);
          }
        });
      },

      destroyed: function() {
        if (this._parent && this._wheelHandler) {
          this._parent.removeEventListener("wheel", this._wheelHandler);
        }
        if (this.panzoom) {
          try { this.panzoom.destroy(); } catch (e) { /* ignore */ }
          this.panzoom = null;
        }
      }
    };
  })();

  // ---------------------------------------------------------------------------
  // MarkdownEditor
  //
  // Drives the core MarkdownEditor LiveComponent's textarea: cursor tracking,
  // list auto-continue, formatting-toolbar actions (data-md-action), insert /
  // prompt-insert pushed from the server (handleEvent), collaborative
  // set-content sync, and unsaved-changes browser-exit protection.
  //
  // Replaces the component's former inline <script> + inline onclick/onmousedown
  // handlers. Those broke under a strict Content-Security-Policy (a nonce never
  // authorizes inline event-handler attributes, and an absent nonce blocks the
  // <script>) and were unreliable on LiveView navigation (a patched-in <script>
  // never re-executes). A hook always mounts on navigation and needs no inline
  // script, so the editor now behaves like every other PhoenixKit feature.
  // ---------------------------------------------------------------------------
  window.PhoenixKitAdminHooks.MarkdownEditor = {
    mounted() {
      this.globalId = this.el.dataset.globalId;
      this.protectNavigation = this.el.dataset.protectNavigation === "true";
      this.lastCursorPosition = 0;
      this.dirty = false;
      this._acquireTextarea();

      // Reaching here means JS + the hook ran — reveal the toolbar(s), which are
      // hidden by default so JS-dependent buttons never show as dead controls.
      this._revealToolbars();

      // Handle formatting-toolbar actions on mousedown, NOT click. preventDefault
      // on mousedown stops focus moving to the button, so the textarea keeps its
      // selection — a click would collapse the selection before we read it, so
      // bold/italic/link would wrap the wrong range. This is the same reason the
      // old markup used inline onmousedown="event.preventDefault()".
      this._onMouseDown = (e) => this._handleToolbarMouseDown(e);
      this.el.addEventListener("mousedown", this._onMouseDown);

      // Server -> client commands. push_event from a LiveComponent fans out to
      // EVERY MarkdownEditor hook on the page, so filter by global_id before
      // acting (a page can host more than one editor).
      this.handleEvent("markdown-editor-insert", ({ global_id, text }) => {
        if (global_id === this.globalId) this._insertAtCursor(text);
      });
      this.handleEvent("markdown-editor-prompt-insert", ({ global_id, prompt, template }) => {
        if (global_id !== this.globalId) return;
        const value = window.prompt(prompt || "");
        if (value && value.trim()) {
          this._insertAtCursor((template || "%{value}").replace("%{value}", value.trim()));
        }
      });
      this.handleEvent("set-content", ({ global_id, content }) => {
        // No global_id → legacy broadcast to the page's editor (back-compat).
        if (global_id && global_id !== this.globalId) return;
        if (!this.textarea || this.textarea.value === content) return;
        // Don't clobber the textarea mid-keystroke (collaborative spectators are
        // read-only, so this is a safety net rather than a common path).
        if (document.activeElement === this.textarea) return;
        this.textarea.value = content;
        this.lastCursorPosition = content ? content.length : 0;
        this.dirty = false;
      });
      // Browser-exit protection for unsaved changes.
      if (this.protectNavigation) {
        this._beforeUnload = (e) => {
          if (this._hasUnsavedChanges()) {
            e.preventDefault();
            e.returnValue = "";
            return "";
          }
        };
        window.addEventListener("beforeunload", this._beforeUnload);
      }
    },

    updated() {
      // morphdom usually preserves the textarea node (stable id), but re-acquire
      // defensively in case it was replaced. Re-reveal the toolbar in case a
      // re-render of the toolbar block restored its default `hidden` class.
      this._acquireTextarea();
      this._revealToolbars();
      // Trust the server once it reports a saved state — otherwise the local
      // `dirty` flag stays true for the page's life after the first keystroke
      // (only set-content clears it, which not every host pushes)
      // and the beforeunload guard fires a bogus "unsaved changes" prompt post-save.
      if (this.el.dataset.saveStatus === "saved") this.dirty = false;
    },

    destroyed() {
      if (this._beforeUnload) window.removeEventListener("beforeunload", this._beforeUnload);
    },

    // --- internals ---------------------------------------------------------

    _revealToolbars() {
      this.el.querySelectorAll("[data-md-toolbar]").forEach((t) => t.classList.remove("hidden"));
    },

    _acquireTextarea() {
      const ta = this.el.querySelector("textarea");
      if (ta === this.textarea) return;
      this.textarea = ta;
      if (!ta) return;
      ta.addEventListener("blur", () => { this.lastCursorPosition = ta.selectionStart; });
      ta.addEventListener("select", () => { this.lastCursorPosition = ta.selectionStart; });
      ta.addEventListener("click", () => { this.lastCursorPosition = ta.selectionStart; });
      ta.addEventListener("keyup", () => { this.lastCursorPosition = ta.selectionStart; });
      ta.addEventListener("input", () => { this.dirty = true; });
      ta.addEventListener("keydown", (e) => this._handleEnter(e));
    },

    _hasUnsavedChanges() {
      const status = this.el.dataset.saveStatus;
      return this.dirty || status === "unsaved" || status === "saving";
    },

    // Mirror the textarea's phx-keyup binding so LiveView sees the new value.
    _notifyChange() {
      this.dirty = true;
      if (this.textarea) {
        this.textarea.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true }));
      }
    },

    _insertAtCursor(text) {
      const ta = this.textarea;
      if (!ta || text == null) return;
      const start = Math.min(this.lastCursorPosition || 0, ta.value.length);
      ta.value = ta.value.substring(0, start) + text + ta.value.substring(start);
      const pos = start + text.length;
      ta.selectionStart = ta.selectionEnd = pos;
      this.lastCursorPosition = pos;
      ta.focus();
      this._notifyChange();
    },

    _wrap(prefix, suffix) {
      const ta = this.textarea;
      if (!ta) return;
      const start = ta.selectionStart;
      const end = ta.selectionEnd;
      const selected = ta.value.substring(start, end);
      const before = ta.value.substring(0, start);
      const after = ta.value.substring(end);
      if (selected.length > 0) {
        ta.value = before + prefix + selected + suffix + after;
        ta.selectionStart = start + prefix.length;
        ta.selectionEnd = end + prefix.length;
      } else {
        const placeholder = "text";
        ta.value = before + prefix + placeholder + suffix + after;
        ta.selectionStart = start + prefix.length;
        ta.selectionEnd = start + prefix.length + placeholder.length;
      }
      ta.focus();
      this.lastCursorPosition = ta.selectionEnd;
      this._notifyChange();
    },

    _linePrefix(prefix) {
      const ta = this.textarea;
      if (!ta) return;
      const start = ta.selectionStart;
      const lineStart = ta.value.lastIndexOf("\n", start - 1) + 1;
      ta.value = ta.value.substring(0, lineStart) + prefix + ta.value.substring(lineStart);
      const pos = start + prefix.length;
      ta.selectionStart = ta.selectionEnd = pos;
      this.lastCursorPosition = pos;
      ta.focus();
      this._notifyChange();
    },

    _link() {
      const ta = this.textarea;
      if (!ta) return;
      const url = window.prompt("Enter URL:");
      if (!url || !url.trim()) return;
      const start = ta.selectionStart;
      const end = ta.selectionEnd;
      const selected = ta.value.substring(start, end);
      const linkText = selected.length > 0 ? selected : "link text";
      ta.value =
        ta.value.substring(0, start) +
        "[" + linkText + "](" + url.trim() + ")" +
        ta.value.substring(end);
      const pos = start + linkText.length + url.trim().length + 4;
      ta.selectionStart = ta.selectionEnd = pos;
      this.lastCursorPosition = pos;
      ta.focus();
      this._notifyChange();
    },

    _handleToolbarMouseDown(e) {
      if (e.button !== 0) return;
      const toolbar = e.target.closest("[data-md-toolbar]");
      if (!toolbar || !this.el.contains(toolbar)) return;
      // Keep the textarea focused/selected through the button press.
      e.preventDefault();
      const btn = e.target.closest("[data-md-action]");
      if (!btn) return;
      switch (btn.dataset.mdAction) {
        case "wrap":
          this._wrap(btn.dataset.mdPrefix || "", btn.dataset.mdSuffix || "");
          break;
        case "line-prefix":
          this._linePrefix(btn.dataset.mdPrefix || "");
          break;
        case "insert":
          this._insertAtCursor(btn.dataset.mdText || "");
          break;
        case "link":
          this._link();
          break;
      }
    },

    _handleEnter(e) {
      if (e.key !== "Enter") return;
      const ta = this.textarea;
      const pos = ta.selectionStart;
      const value = ta.value;
      const lineStart = value.lastIndexOf("\n", pos - 1) + 1;
      const lineEnd = value.indexOf("\n", pos);
      const currentLine = value.substring(lineStart, lineEnd === -1 ? value.length : lineEnd);
      // Only auto-continue when the cursor is at the end of the line.
      if (pos - lineStart < currentLine.length) return;

      const bulletMatch = currentLine.match(/^(\s*)(-|\*|\+)\s(.*)$/);
      if (bulletMatch) {
        e.preventDefault();
        const [, indent, marker, content] = bulletMatch;
        this._continueList(ta, value, pos, lineStart, content, indent + marker + " ");
        return;
      }
      const numberMatch = currentLine.match(/^(\s*)(\d+)\.\s(.*)$/);
      if (numberMatch) {
        e.preventDefault();
        const [, indent, num, content] = numberMatch;
        const next = parseInt(num, 10) + 1;
        this._continueList(ta, value, pos, lineStart, content, indent + next + ". ");
      }
    },

    _continueList(ta, value, pos, lineStart, content, marker) {
      if (content.trim() === "") {
        // Empty list item — remove the marker instead of continuing.
        ta.value = value.substring(0, lineStart) + value.substring(pos);
        ta.selectionStart = ta.selectionEnd = lineStart;
      } else {
        const insertion = "\n" + marker;
        ta.value = value.substring(0, pos) + insertion + value.substring(pos);
        ta.selectionStart = ta.selectionEnd = pos + insertion.length;
      }
      this.lastCursorPosition = ta.selectionStart;
      this._notifyChange();
    }
  };

  // ---------------------------------------------------------------------------
  // AnnotationComposerPosition
  //
  // Positions the MediaBrowser's floating annotation-composer popover
  // directly above the shape it belongs to (falling back to below if
  // there's no room above, then clamping to the viewer container).
  //
  // The popover's element id encodes the annotation uuid as suffix
  // ("annotation-composer-popover-<uuid>"); Etcher tags each shape's
  // root SVG element with the same uuid via `data-uuid`. The hook
  // queries for that element and uses its bounding rect to compute
  // the popover's left/top in the parent container's coordinate space.
  //
  // Etcher 0.3's bulk `annotations-changed` event doesn't carry an
  // anchor for newly-drawn shapes (the old per-op `etcher:created`
  // emitted `anchor_x`/`anchor_y`), so the server can no longer seed
  // container-space coords. Reading the shape's DOM rect on the client
  // sidesteps the need for any image-to-screen math server-side and
  // keeps positioning correct after pan/zoom.
  //
  // Re-runs on mount, server-driven updates, and window resize. An 8px
  // margin keeps the popover from touching the container edge.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // ViewerKeydown — global keydown shortcut handler for the media viewer
  // modal, with two filters that the stock `phx-window-keydown` can't
  // express:
  //
  //   1. Only Escape / ArrowLeft / ArrowRight reach the server. Letter
  //      keys typed into the annotation composer no longer fire the
  //      modal's nav handler and spam the LV logs.
  //   2. Even the navigation keys are suppressed when focus is inside an
  //      <input> / <textarea> / contenteditable so the arrow keys can
  //      move the text caret without flipping the modal to the next
  //      image while the user is typing.
  //
  // Pushes to the hook element's component so the existing
  // `handle_event "viewer_keydown"` clauses keep working unchanged.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // ViewerPaneFit — the stacked pane holds the picture's shape, not a guess.
  //
  // A portrait popup stacks: picture on top, details docked under it. The pane
  // is sized by `aspect-ratio: var(--pk-pane-aspect)` rather than by a share
  // of the popup's height, so the popup ends up as tall as the picture plus
  // the panel instead of 90vh of mostly empty canvas.
  //
  // The server renders that variable from the file's own width and height,
  // which is right for the picture as uploaded and is what makes the FIRST
  // paint correct. It is not always right about what gets painted: the viewer
  // opens on a burned copy wherever one exists, and a burn is not always
  // composed at the picture's ratio — a 1.69 photograph with a 1.33 burn gets
  // a pane too wide for it and a band of empty canvas down each side.
  //
  // So the prediction is corrected from the bitmap on screen, once it is
  // decoded. That element is the truth about rotation, edits and whatever the
  // burn did, and reading `naturalWidth` off it costs nothing.
  // ---------------------------------------------------------------------------

  window.PhoenixKitAdminHooks.ViewerPaneFit = {
    mounted() { this._fit(); },
    updated() { this._fit(); },

    // Is the picture standing on its side? Fresco turns it by transforming
    // the stage, so the answer is in the matrix rather than in a class:
    // matrix(a, b, …) is a·cosθ and a·sinθ scaled alike, so |a| < |b| is a
    // quarter turn at any zoom. Panning changes only the translation and so
    // cannot flip the answer.
    _turned(stage) {
      if (!stage) return false;
      const m = /^matrix\(([^)]+)\)/.exec(getComputedStyle(stage).transform || "");
      if (!m) return false;
      const parts = m[1].split(",").map(Number);
      return Math.abs(parts[0]) < Math.abs(parts[1]);
    },

    _fit() {
      const pane = this.el.querySelector("[data-viewer-pane]");
      if (!pane) return;
      const img = pane.querySelector("img");
      if (!img) return;
      const self = this;
      const stage = img.closest(".fresco-stage") || img.parentElement;

      const apply = function() {
        if (!(img.naturalWidth > 0 && img.naturalHeight > 0)) return;
        // The shape ON SCREEN — the same swap the server applies to a stored
        // rotation and the stand-in applies to the card's own class.
        const turned = self._turned(stage) ||
          /(^|\s|-)rotate-(90|270)\b/.test(img.className);
        const w = turned ? img.naturalHeight : img.naturalWidth;
        const h = turned ? img.naturalWidth : img.naturalHeight;
        const value = w + " / " + h;
        // Written only when it changes: the observer below fires on every
        // frame of a pan, and each write is a style recalculation.
        if (value === self._last) return;
        self._last = value;
        pane.style.setProperty("--pk-pane-aspect", value);
      };

      // Cached bitmaps are already decoded on mount (the grid painted this
      // one), and the viewer's ladder climbs small → large while it is open,
      // so this listens as well as reading: `load` fires again on each rung,
      // and a rung of a different shape would otherwise stay mispredicted.
      if (img.complete) apply();
      if (this._img !== img) {
        if (this._img && this._apply) this._img.removeEventListener("load", this._apply);
        img.addEventListener("load", apply);
        this._img = img;
        this._apply = apply;
      }

      // Rotating is Fresco's own doing and patches nothing, so `updated()`
      // never fires for it. Without this the pane keeps the shape it had and
      // a turned picture is fitted into a slot the wrong way round — 216px
      // wide where it could be the full width of the popup.
      if (stage && this._stage !== stage && typeof MutationObserver === "function") {
        if (this._obs) this._obs.disconnect();
        this._obs = new MutationObserver(apply);
        this._obs.observe(stage, { attributes: true, attributeFilter: ["style", "class"] });
        this._stage = stage;
      }
    },

    destroyed() {
      if (this._img && this._apply) this._img.removeEventListener("load", this._apply);
      if (this._obs) this._obs.disconnect();
    }
  };

  // ---------------------------------------------------------------------------
  // InstantViewer — put the picture on screen on the click, not on the reply.
  //
  // Opening the viewer is a server round trip: the modal does not exist in the
  // DOM until LiveView sends it back. The server's part of that is ~2ms, so on
  // a fast connection it reads as a small hitch and on a slow one as a wait,
  // and in both cases the thing you clicked is a picture the browser ALREADY
  // HAS — the grid painted it.
  //
  // So this paints it immediately, full size, behind a backdrop, and gets out
  // of the way when the real viewer arrives. Nothing here talks to the server
  // or changes what gets opened; it is the same bitmap the card is showing,
  // scaled up, for the length of one round trip.
  //
  // Listens on the document in the CAPTURE phase so it runs before LiveView
  // sends the event, which is the whole point — a listener that waited its turn
  // would be racing the thing it exists to hide.
  // ---------------------------------------------------------------------------

  window.PhoenixKitAdminHooks.InstantViewer = {
    mounted() {
      const self = this;
      const el = self.el;

      // Hidden until a click, and never left showing: `_hide` is called by the
      // real viewer's arrival, by a click that turns out not to open one, and
      // by a timeout — see below for why all three are needed.
      self._hide = function() {
        self._stepping = false;
        el.style.display = "none";
        const img = el.querySelector("img");
        if (img) {
          img.removeAttribute("src");
          // Drop the swapped box a rotated stand-in needed, or the next
          // open inherits a sideways frame.
          img.style.width = "";
          img.style.height = "";
        }
        // Undo the see-through state (below) so the next open starts as a
        // full stand-in again: its own backdrop, an opaque box, a visible
        // skeleton pane.
        el.style.backgroundColor = "";
        el.style.removeProperty("--pk-pane-aspect");
        const box = el.querySelector(".modal-box");
        if (box) box.style.backgroundColor = "";
        const pane = el.querySelector('[data-pane="sidebar"]');
        if (pane) pane.style.visibility = "";
        if (self._timer) { clearTimeout(self._timer); self._timer = null; }
        if (self._closeGrace) { clearTimeout(self._closeGrace); self._closeGrace = null; }
        self._loadingPill(false);
      };

      // The stand-in's "Loading full quality…" pill: up a beat after the
      // stand-in shows (a hand-over inside that beat never flashes it), gone
      // the instant the stand-in goes. The real viewer's pill takes over from
      // there for any sharper rung still on its way.
      self._loadingPill = function(on) {
        const pill = el.querySelector("[data-standin-loading]");
        if (self._pillTimer) { clearTimeout(self._pillTimer); self._pillTimer = null; }
        if (!pill) return;
        if (on) {
          self._pillTimer = setTimeout(function() {
            self._pillTimer = null;
            pill.style.opacity = "1";
          }, 300);
        } else {
          // No fade needed: the stand-in itself is display:none by now.
          pill.style.opacity = "0";
        }
      };
      self._hide();

      // Paint a bitmap into the stand-in and show it — shared by the two
      // triggers: opening from a grid card, and stepping prev/next inside
      // the viewer (whose neighbour bitmaps the warm has already cached).
      // `aspect` is the picture's own ratio ("3000 / 2000"), or null when
      // nobody could say. A portrait popup sizes the picture pane to it
      // instead of to a share of the popup's height, so the stand-in has to
      // predict it along with the sidebar: a stand-in that guessed square
      // for a panorama would hand over by resizing the whole box, which is
      // the jump this exists to prevent. Null leaves the last one in place —
      // a neighbour is usually shaped like the picture you are looking at,
      // and the real viewer corrects it either way.
      self._show = function(src, rotationClass, aspect) {
        const shown = el.querySelector("img");
        if (!shown) return;
        if (aspect) el.style.setProperty("--pk-pane-aspect", aspect);

        // Predict the layout the real viewer is about to use: image column
        // alone, or image + info sidebar — which is open by default, so
        // painting the image over the full popup and shrinking it when the
        // sidebar mounts is its own flash. The last viewer seen this
        // session is the best predictor (the user may have toggled the
        // sidebar inside it); before any viewer has opened, the
        // server-rendered pref decides.
        const pane = el.querySelector('[data-pane="sidebar"]');
        if (pane) {
          const open = self._sidebarWasOpen !== undefined
            ? self._sidebarWasOpen
            : el.dataset.sidebarOpen === "true";
          pane.style.display = open ? "" : "none";
          pane.style.visibility = "";
        }
        el.style.backgroundColor = "";
        const box = el.querySelector(".modal-box");
        if (box) box.style.backgroundColor = "";

        shown.setAttribute("src", src);
        shown.className = shown.dataset.baseClass +
          " " + (rotationClass || "");

        // A quarter turn needs the box turned with it. `object-contain`
        // fits the picture to the element BEFORE the transform, so
        // rotating a wide element 90° leaves a wide picture standing on
        // its side: far too tall for the column, clipped left and right,
        // and enormously magnified — which is exactly the "strange
        // stretched image" this fixes. Sizing the element to the column's
        // height × width first means the fit happens against the box the
        // picture will actually occupy, and the rotation then lands it
        // square in the column. The flex centring keeps it centred, and
        // the rotation turns about its own centre.
        //
        // Shown FIRST, measured second: the stand-in rests at
        // `display:none`, and a frame inside a hidden element measures
        // 0 × 0 — so measuring before the reveal skipped the fit on every
        // open from the grid, which is the case this exists for. The read
        // forces one layout and nothing paints in between. The box is
        // cleared before it is measured, so a frame that cannot be
        // measured falls back to the class-driven size rather than keeping
        // the previous picture's.
        shown.style.width = "";
        shown.style.height = "";
        el.style.display = "";

        var quarter = /rotate-(90|270)/.test(rotationClass || "");
        var frame = shown.parentNode;
        if (quarter && frame && frame.getBoundingClientRect) {
          var fr = frame.getBoundingClientRect();
          if (fr.width && fr.height) {
            shown.style.width = fr.height + "px";
            shown.style.height = fr.width + "px";
          }
        }

        // A trigger that opens nothing — a stale uuid, a server error, a
        // connection that drops between here and there — must not leave a
        // picture stuck over the page. The real viewer normally clears this
        // in well under a second.
        if (self._timer) clearTimeout(self._timer);
        self._timer = setTimeout(self._hide, 8000);
        self._loadingPill(true);
      };

      self._onClick = function(e) {
        // Stepping inside the viewer: the chevron buttons. The neighbour's
        // warmed small paints immediately, blurred, so the press reads as
        // motion instead of the viewer freezing on the old image.
        const step = e.target.closest && e.target.closest('[phx-click="step_viewer"]');
        if (step) {
          const modal = document.querySelector('[id$="-viewer-modal"]');
          const d = (modal && modal.dataset) || {};
          const dir = step.getAttribute("phx-value-dir");
          const src = dir === "prev" ? d.stepPrevSrc : d.stepNextSrc;
          const rot = dir === "prev" ? d.stepPrevRot : d.stepNextRot;
          const asp = dir === "prev" ? d.stepPrevAspect : d.stepNextAspect;
          if (src) {
            self._stepping = true;
            self._show(src, rot || "", asp || null);
          }
          return;
        }

        const card = e.target.closest && e.target.closest('[phx-click="click_file"]');
        if (!card) return;
        // Select mode turns the same click into a checkbox toggle, and a
        // picker's click may open nothing at all. The browser marks which it
        // is, so this can stay out of both.
        if (el.dataset.armed !== "true") return;

        const img = card.querySelector("img");
        const src = img && img.getAttribute("src");
        if (!src) return;

        // Carry the card's rotation across, or a sideways photo would flip
        // upright for a moment and then turn back.
        const rot = (img.className.match(/rotate-\d+/) || [""])[0];

        // The grid already decoded this bitmap, so its true shape is a
        // property read — no load, no round trip. A quarter turn swaps the
        // axes here exactly as it does server-side.
        let aspect = null;
        if (img.naturalWidth > 0 && img.naturalHeight > 0) {
          const turned = /rotate-(90|270)\b/.test(rot);
          aspect = turned
            ? img.naturalHeight + " / " + img.naturalWidth
            : img.naturalWidth + " / " + img.naturalHeight;
        }
        self._show(src, rot, aspect);
      };
      document.addEventListener("click", self._onClick, true);

      // Keyboard steps announce themselves from ViewerKeydown (which owns
      // the arrow keys and the modal's neighbour data).
      self._onStep = function(e) {
        const d = e && e.detail;
        if (!d || !d.src) return;
        self._stepping = true;
        self._show(d.src, d.rotation || "", d.aspect || null);
      };
      window.addEventListener("pk:viewer-step", self._onStep);

      // Start the viewer's downloads BEFORE the click. Opening fetches
      // `small` and then `large` — a third of a megabyte that used to
      // start moving only after the round trip. A pointer rests on a card
      // for a beat before the button goes down, which is enough head
      // start for the fetches to be in cache (immutable, so the browser
      // serves them without revalidating) by the time the viewer asks.
      // pointerdown is the backstop for touch, where there is no hover.
      // Each URL is fetched once per page; a miss costs nothing extra —
      // it is the same download the click was about to start anyway.
      self._prefetched = {};
      self._prefetch = function(e) {
        const card = e.target.closest && e.target.closest('[phx-click="click_file"]');
        if (!card || !card.dataset) return;
        for (const key of ["prefetchSmall", "prefetchLarge"]) {
          const url = card.dataset[key];
          if (!url || self._prefetched[url]) continue;
          self._prefetched[url] = true;
          new Image().src = url;
        }
      };
      // pointerover, not pointerenter: only the former bubbles.
      document.addEventListener("pointerover", self._prefetch, true);
      document.addEventListener("pointerdown", self._prefetch, true);

      // The real viewer says when it is up. Nothing else can: the modal is a
      // different LiveComponent that this hook has no reference to, so it
      // hands its own element over in the event.
      //
      // Mounting is not the same moment as being PAINTED, and the difference
      // is visible: the card shows `thumbnail_annotated` where the viewer
      // loads `small`, so the two are usually different URLs and the real one
      // is not in cache. Hiding on mount would swap the blurred picture for an
      // empty box and then paint — the flash this whole hook exists to remove.
      // So hold on until the real bitmap is actually on screen.
      self._onReady = function(e) {
        self._stepping = false;
        // The viewer is (still) here — a mid-step close signal that was
        // waiting to take the stand-in down was the old one's teardown
        // after all.
        if (self._closeGrace) { clearTimeout(self._closeGrace); self._closeGrace = null; }
        const root = e && e.detail && e.detail.el;

        // Remember the layout this viewer actually used, so the NEXT
        // stand-in predicts it right even after the user toggles the
        // sidebar mid-session — the server-rendered pref cannot follow
        // that, its assign never refreshes on a toggle.
        if (root && root.querySelector) {
          self._sidebarWasOpen = !!root.querySelector("[data-viewer-sidebar]");
        }

        // Nothing to hand over — the viewer opened without the stand-in
        // (select-mode click, a card with no image).
        if (el.style.display === "none") return;

        // No element to align with (defensive) — just get out of the way.
        if (!root || !root.querySelector) { self._hide(); return; }

        // The real modal mounts UNDER this stand-in (the stand-in carries
        // z-index 1000 against .modal's 999) and its sidebar content is
        // ready NOW — only its image is still in flight. So turn the
        // stand-in into a window: its own backdrop, box, and skeleton pane
        // go transparent, leaving just the blurry image column floating
        // exactly over the real modal's identical — and still empty —
        // image column. The real sidebar shows through immediately, and
        // the empty column never shows at all.
        //
        // The darkness swaps in the same frame: the real .modal-open
        // paints its own 40% black as the stand-in's goes transparent —
        // exactly one dark layer at every moment, no doubling and no dip.
        // Both transitions are off (the stand-in's inline in the markup),
        // or daisyUI's 0.3s background fade would turn the swap into a
        // visible dip.
        if (root.style) root.style.transition = "none";
        el.style.backgroundColor = "transparent";
        const box = el.querySelector(".modal-box");
        if (box) box.style.backgroundColor = "transparent";
        const pane = el.querySelector('[data-pane="sidebar"]');
        if (pane) {
          // The real layout is here, so truth replaces prediction: on a
          // mispredicted open the blurry column snaps to the right width
          // now rather than covering the real sidebar until the image
          // loads. visibility (not display) keeps the column's ground.
          pane.style.display = self._sidebarWasOpen ? "" : "none";
          pane.style.visibility = "hidden";
        }

        const real = root.querySelector("img");
        // No image to wait for, or already decoded (same URL as the card, or
        // a warm cache) — hand over now.
        if (!real || real.complete) { self._hide(); return; }

        const done = function() {
          real.removeEventListener("load", done);
          real.removeEventListener("error", done);
          self._hide();
        };
        // `error` too: a broken image must not leave the stand-in up pretending
        // the picture loaded. The 8s fallback still covers anything that fires
        // neither.
        real.addEventListener("load", done);
        real.addEventListener("error", done);
      };
      window.addEventListener("pk:viewer-open", self._onReady);

      // Escape (or anything else) can close the viewer while the hold is
      // still waiting on the image — the modal is torn out from under the
      // floating blurry column, which would otherwise hang over the grid
      // until the fallback timer. The viewer announces its teardown.
      self._onClosed = function() {
        // A step tears the OLD viewer down on its way to the new one —
        // that teardown must not kill the stand-in that exists to bridge
        // it. But a REAL close mid-step (Escape, or a backdrop click that
        // fell through this pointer-events-none overlay onto the actual
        // modal) must: ignoring it outright left the blur orphaned over
        // a viewer that was already gone, until the fallback timer. The
        // two are indistinguishable here, so give the replacement viewer
        // a beat to announce itself — pk:viewer-open cancels the hide —
        // and take the blur down when nothing does.
        if (self._stepping) {
          if (self._closeGrace) clearTimeout(self._closeGrace);
          self._closeGrace = setTimeout(self._hide, 400);
          return;
        }
        self._hide();
      };
      window.addEventListener("pk:viewer-closed", self._onClosed);
    },

    destroyed() {
      document.removeEventListener("click", this._onClick, true);
      document.removeEventListener("pointerover", this._prefetch, true);
      document.removeEventListener("pointerdown", this._prefetch, true);
      window.removeEventListener("pk:viewer-open", this._onReady);
      window.removeEventListener("pk:viewer-closed", this._onClosed);
      window.removeEventListener("pk:viewer-step", this._onStep);
      if (this._timer) { clearTimeout(this._timer); this._timer = null; }
      if (this._pillTimer) { clearTimeout(this._pillTimer); this._pillTimer = null; }
    }
  };

  window.PhoenixKitAdminHooks.ViewerKeydown = {
    mounted() {
      const self = this;
      // Tell the stand-in the real viewer is here. It needs the element to
      // find the image and wait for it to paint — mounted is not painted.
      window.dispatchEvent(new CustomEvent("pk:viewer-open", { detail: { el: self.el } }));

      // Warm the NEIGHBOURS' small + large while this image is being looked
      // at. An arrow press remounts the viewer on the next file, and its
      // small + large variants used to start downloading only then — that
      // download was the whole wait between pressing → and seeing the
      // picture. The files are served immutable, so a warmed URL is a cache
      // hit; each is fetched once per page (the map is module-level and
      // shared across remounts).
      //
      // Three manners, because a warm is a favour to the NEXT press and must
      // never cost the picture on screen anything:
      //   - it waits until the current picture has settled (its sharper
      //     version is in and the canvas has been quiet a moment), so the
      //     warm never races the download the person is actually waiting on;
      //   - it runs at low fetch priority;
      //   - it does not run at all on data-saver or a 2G/3G line.
      //
      // Originals are NOT warmed here: whether a multi-MB original is worth
      // fetching depends on the screen, the line and which way the person is
      // stepping — high-end viewing, which a module decides. Core announces
      // the neighbours once settled (`pk:viewer-neighbours`) and
      // phoenix_kit_photos listens.
      window.__pkWarmedUrls = window.__pkWarmedUrls || {};
      var SETTLE_QUIET_MS = 600;
      var SETTLE_MAX_MS = 4000;
      // Calls `done` once the canvas image is loaded and nothing has loaded
      // for SETTLE_QUIET_MS (Tessera climbs rungs, each a load), or after
      // SETTLE_MAX_MS whatever happens. Returns a cancel function.
      function afterSettled(root, done) {
        var finished = false, quiet = null, cap = null;
        function stop() {
          finished = true;
          clearTimeout(quiet);
          clearTimeout(cap);
          document.removeEventListener("load", poke, true);
          document.removeEventListener("error", poke, true);
        }
        function finish() { if (finished) return; stop(); done(); }
        function poke() {
          if (finished) return;
          clearTimeout(quiet);
          var img = root.querySelector && root.querySelector("img[data-fresco-canvas-img]");
          // No canvas yet, or its picture still arriving: its own load /
          // error event pokes again.
          if (!img || (img.getAttribute && img.getAttribute("src") && !img.complete)) return;
          quiet = setTimeout(finish, SETTLE_QUIET_MS);
        }
        document.addEventListener("load", poke, true);
        document.addEventListener("error", poke, true);
        cap = setTimeout(finish, SETTLE_MAX_MS);
        poke();
        return stop;
      }
      function warmAllowed() {
        var c = (typeof navigator !== "undefined" && navigator.connection) || null;
        if (!c) return true;
        return !(c.saveData || /(^|-)[23]g$/.test(c.effectiveType || ""));
      }
      function warmUrl(url) {
        if (!url || window.__pkWarmedUrls[url]) return;
        window.__pkWarmedUrls[url] = true;
        var im = new Image();
        try { im.fetchPriority = "low"; } catch (_e) { /* older browsers */ }
        im.src = url;
      }
      // Factored so updated() can re-run it: a step PATCHES this modal in
      // place (its id is stable), so mounted() fires once per open. Each
      // step rewrites the dataset with the new neighbours; warming again
      // from here keeps the NEXT press as instant as the first.
      self._direction = "";
      function neighbours(raw) {
        try { return JSON.parse(raw || "{}") || {}; } catch (_e) { return {}; }
      }
      self._warm = function() {
        if (self._cancelWarm) self._cancelWarm();
        var n = neighbours(self.el && self.el.dataset && self.el.dataset.neighbors);
        self._cancelWarm = afterSettled(self.el, function() {
          self._cancelWarm = null;
          if (!warmAllowed()) return;
          // The way the person is heading: the next photo until they step
          // back. Only that side's `large` is worth a speculative fetch;
          // both sides' `open` (small — tens of KB) is, because it is what a
          // step paints at once while the rest arrives. The side just left
          // is already in the cache.
          var ahead = self._direction === "prev" ? "prev" : "next";
          var behind = ahead === "prev" ? "next" : "prev";
          warmUrl(n[ahead] && n[ahead].open);
          warmUrl(n[behind] && n[behind].open);
          warmUrl(n[ahead] && n[ahead].large);
          // For a module deciding on originals (phoenix_kit_photos): what
          // each neighbour offers, and the viewer's box in device terms so
          // it can work out how many pixels the picture will really light —
          // a portrait photo in a wide column is narrow.
          var column = self.el.querySelector('[id^="pk-annotation-actions-"]');
          window.dispatchEvent(new CustomEvent("pk:viewer-neighbours", {
            detail: {
              prev: n.prev ? { original: n.prev.original || "", aspect: n.prev.aspect || "" } : null,
              next: n.next ? { original: n.next.original || "", aspect: n.next.aspect || "" } : null,
              direction: self._direction,
              box: {
                width: (column && column.clientWidth) || window.innerWidth || 0,
                height: (column && column.clientHeight) || window.innerHeight || 0,
                dpr: window.devicePixelRatio || 1
              }
            }
          }));
        });
      };
      self._warm();
      self._handler = function(e) {
        if (e.key !== "Escape" && e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
        const t = document.activeElement;
        if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" ||
                  t.isContentEditable === true)) return;
        // Announce the step so the stand-in can paint the neighbour's
        // warmed bitmap NOW — blurred, in the final geometry — instead of
        // the viewer freezing on the current image until the next one's
        // pixels arrive. src comes off this modal's own data attributes;
        // empty (edge of the list, a video) means no stand-in, and the
        // step behaves as before.
        if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
          self._direction = e.key === "ArrowLeft" ? "prev" : "next";
          const d = self.el.dataset || {};
          const src = e.key === "ArrowLeft" ? d.stepPrevSrc : d.stepNextSrc;
          const rot = e.key === "ArrowLeft" ? d.stepPrevRot : d.stepNextRot;
          const asp = e.key === "ArrowLeft" ? d.stepPrevAspect : d.stepNextAspect;
          if (src) {
            window.dispatchEvent(new CustomEvent("pk:viewer-step", {
              detail: { src: src, rotation: rot || "", aspect: asp || "" }
            }));
          }
        }
        self.pushEventTo(self.el, "viewer_keydown", { key: e.key });
      };
      document.addEventListener("keydown", self._handler);

      // The on-screen chevrons step too: the side being stepped towards is the
      // one whose large variant is warmed, whichever way the step was made.
      self._onChevron = function(e) {
        const btn = e.target && e.target.closest && e.target.closest('[phx-click="step_viewer"]');
        const dir = btn && btn.getAttribute("phx-value-dir");
        if (dir === "prev" || dir === "next") self._direction = dir;
      };
      self.el.addEventListener("click", self._onChevron, true);
    },

    // A step does NOT remount this hook — the modal's id is stable, so
    // LiveView patches it in place and only the canvas child (file uuid
    // in its id) remounts. mounted() above is therefore once per OPEN,
    // and the stand-in a step had painted waited on a pk:viewer-open
    // that never came: it sat opaque over the new image for the full
    // fallback timeout, which read as the step being slow — and as the
    // popup refusing to close, since the click-off had actually closed
    // the real viewer somewhere under the blur. Re-announcing from here
    // gives a step the same hand-off as an open: see-through at once,
    // gone when the new image paints. Extra firings from unrelated
    // patches (sidebar toggle, a comment) are harmless — with the
    // stand-in hidden the listener only refreshes its layout prediction.
    updated() {
      window.dispatchEvent(new CustomEvent("pk:viewer-open", { detail: { el: this.el } }));
      // …and the dataset now names the NEW neighbours.
      if (this._warm) this._warm();
    },

    destroyed() {
      // The stand-in may be holding a blurry overlay over this modal,
      // waiting for an image that is now never going to load.
      window.dispatchEvent(new CustomEvent("pk:viewer-closed"));
      if (this._handler) {
        document.removeEventListener("keydown", this._handler);
        this._handler = null;
      }
      if (this._onChevron) {
        this.el.removeEventListener("click", this._onChevron, true);
        this._onChevron = null;
      }
      if (this._cancelWarm) {
        this._cancelWarm();
        this._cancelWarm = null;
      }
    }
  };

  // ---------------------------------------------------------------------------
  // MediaViewerDialog — opens the media viewer (`MediaViewer` LiveComponent) as a
  // native <dialog> via showModal(), so it renders in the browser top layer.
  //
  // The top layer escapes ALL ancestor stacking contexts and z-index, fixing the
  // case where a deeply-nested viewer (e.g. inside a documents tab) is overlapped
  // by parent-page elements with a higher z-index.
  //
  // The server owns the open/closed lifecycle (the component is mounted only
  // while a preview is open). The hook pushes `viewer_keydown` events so the
  // existing MediaViewer `handle_event "viewer_keydown"` clauses keep working.
  // ---------------------------------------------------------------------------

  window.PhoenixKitAdminHooks.MediaViewerDialog = {
    mounted() {
      const self = this;

      if (typeof this.el.showModal === "function" && !this.el.open) {
        this.el.showModal();
      }

      // Native Escape / programmatic cancel — route to the server so it stays
      // the single source of truth for whether the viewer is open.
      self._onCancel = function(e) {
        e.preventDefault();
        self.pushEventTo(self.el, "viewer_keydown", { key: "Escape" });
      };

      // Arrow-key navigation; suppressed while focus is in a text field.
      self._onKey = function(e) {
        if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
        const t = document.activeElement;
        if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" ||
                  t.isContentEditable)) return;
        self.pushEventTo(self.el, "viewer_keydown", { key: e.key });
      };

      this.el.addEventListener("cancel", self._onCancel);
      this.el.addEventListener("keydown", self._onKey);
    },
    // Re-assert open state after LiveView patches children (e.g. prev/next step).
    // The <dialog> opening tag has only stable attrs so morphdom rarely touches it,
    // but this guard mirrors PkDialog._sync and removes the asymmetry between the
    // two hooks.
    updated() {
      if (!this.el.open && typeof this.el.showModal === "function") this.el.showModal();
    },
    destroyed() {
      if (this._onCancel) this.el.removeEventListener("cancel", this._onCancel);
      if (this._onKey) this.el.removeEventListener("keydown", this._onKey);
      if (this.el.open) this.el.close();
    }
  };

  // ---------------------------------------------------------------------------
  // PkHashHighlight — lights the element the URL fragment names.
  //
  // The CSS `:target` variant only follows a fragment the browser itself
  // navigated to: a page reached through `push_navigate` (a bell notice, for
  // one) is entered by `history.pushState`, which leaves `:target` unset. The
  // hook sets `data-highlight` on the element inside its root whose id the
  // fragment names, on mount, after every patch and on `hashchange`; the
  // markup styles it (`data-[highlight]:ring-2`) next to `target:ring-2` for
  // pages loaded directly.
  //
  //   <div id="page" phx-hook="PkHashHighlight"> <div id="item-1" …> </div>
  // ---------------------------------------------------------------------------
  function hashTargetId(hash) {
    if (typeof hash !== "string" || hash.length < 2 || hash.charAt(0) !== "#") return null;
    try { return decodeURIComponent(hash.slice(1)); } catch (_e) { return null; }
  }

  if (typeof module === "object" && module.exports) {
    module.exports.hashTargetId = hashTargetId;
  }

  window.PhoenixKitAdminHooks.PkHashHighlight = {
    mounted() {
      const self = this;
      self._onHashChange = function() { self._mark(); };
      window.addEventListener("hashchange", self._onHashChange);
      self._mark();
    },
    updated() { this._mark(); },
    destroyed() { window.removeEventListener("hashchange", this._onHashChange); },
    _mark() {
      const id = hashTargetId(window.location.hash);
      this.el.querySelectorAll("[data-highlight]").forEach(function(el) {
        if (el.id !== id) el.removeAttribute("data-highlight");
      });
      if (id === null) return;
      const target = document.getElementById(id);
      if (target && this.el.contains(target)) target.setAttribute("data-highlight", "");
    }
  };

  // ---------------------------------------------------------------------------
  // BulkSelectScope — client-side bulk-select state for admin tables.
  //
  // The hook owns the selection set in the browser; the server only learns
  // about it at action time (when the user clicks an action button). This
  // makes per-checkbox toggles feel instant — no round-trip on every click.
  //
  // Markup contract (inside the hook root element):
  //
  //   data-bulk-total="N"                   on the root, total row count
  //                                         (drives the header's
  //                                         all-selected check)
  //
  //   data-bulk-role="select-all"           the header checkbox. Click
  //                                         toggles every row to match.
  //
  //   data-bulk-role="row"
  //   data-uuid="<row-uuid>"                a per-row checkbox.
  //
  //   data-bulk-action="<lv-event>"         on a button: clicking pushes
  //                                         <lv-event> to the LV with
  //                                         `{ uuids: [...] }` payload. Pair
  //                                         with `data-confirm="..."` for a
  //                                         native confirm() prompt before
  //                                         the event fires (cancelling
  //                                         stops the click here — the
  //                                         event is never pushed). This
  //                                         hook always calls preventDefault
  //                                         on the click, which would
  //                                         otherwise make phoenix_html's
  //                                         own data-confirm handling never
  //                                         run (it bails out early when
  //                                         the event is already
  //                                         defaultPrevented), so this hook
  //                                         handles data-confirm itself.
  //
  //   data-bulk-clear                       on a button: pure client-side
  //                                         clear (uncheck all + reset).
  //
  //   data-bulk-count                       text content gets set to the
  //                                         current selected count.
  //
  //   data-bulk-show="has-selection"        element shown only when
  //                                         count > 0 (hidden otherwise).
  //   data-bulk-show="no-selection"         inverse: shown only when count
  //                                         is 0.
  //
  //   data-bulk-swap="<css-selector>"       on the ROOT: an element OUTSIDE
  //                                         this scope, hidden while the
  //                                         scope holds a selection. For the
  //                                         page toolbar that sits ABOVE a
  //                                         list — a `data-bulk-show` inside
  //                                         the scope cannot reach it, and
  //                                         revealing the action bar without
  //                                         hiding something pushes every row
  //                                         DOWN, so the next click lands on
  //                                         the wrong checkbox (boss via Max,
  //                                         2026-09-20: measured at 52px, more
  //                                         than a row). The bar takes the
  //                                         toolbar's place instead, and the
  //                                         rows do not move. Several scopes
  //                                         on one page may name the same
  //                                         toolbar: it stays hidden while ANY
  //                                         of them has a selection, which is
  //                                         why this restores by re-asking the
  //                                         others rather than by remembering.
  //
  //   data-bulk-text-template="…%{count}…"  element's textContent is
  //                                         re-rendered from the template
  //                                         each time the count changes
  //                                         (%{count} → current count).
  //
  //   data-bulk-label-empty / -selected     button label flips between
  //                                         the two strings based on
  //                                         count (selected supports
  //                                         %{count} interpolation).
  // ---------------------------------------------------------------------------

  // Does any live scope still stand in for this toolbar? Asked of every
  // scope naming it — a page can have several over one toolbar, and clearing
  // one must not restore a toolbar another's action bar is still occupying.
  function anyScopeClaims(selector) {
    return Array.prototype.some.call(
      document.querySelectorAll("[data-bulk-swap]"),
      function (scope) {
        return scope.dataset.bulkSwap === selector && (scope._pkBulkCount || 0) > 0;
      }
    );
  }

  if (typeof module === "object" && module.exports) {
    module.exports.anyScopeClaims = anyScopeClaims;
  }

  window.PhoenixKitAdminHooks.BulkSelectScope = {
    // Hides the toolbar this scope replaces while it holds a selection.
    //
    // A page can carry several scopes (the catalogue's categories AND its
    // items) over ONE toolbar, so "should it be hidden" is asked of every
    // scope naming it, not remembered here: restoring from a private flag
    // would un-hide the toolbar the moment one list cleared, while the
    // other still had rows selected and its action bar on screen.
    _syncSwap(count) {
      // Publish this scope's live count on the ELEMENT before reading the
      // others, so every scope answers from the same place and the result
      // does not depend on which hook ran last.
      //
      // A count, not the row checkboxes. Selection lives in each hook's Set,
      // and the server re-renders every checkbox UNCHECKED — so a scope that
      // has just been patched reads as empty from the DOM until its own
      // `updated()` restores it. A sibling syncing in that window would then
      // un-hide a toolbar whose action bar is still on screen, and the rows
      // jump: the exact regression this exists to prevent (grok, zai and
      // vibe all landed on this independently, 2026-09-20).
      //
      // A property rather than an attribute: morphdom rewrites attributes it
      // rendered and would strip this one on the next patch, which is how the
      // dialog `open` attribute bit earlier the same night.
      this.el._pkBulkCount = count;

      const selector = this.el.dataset.bulkSwap;
      if (!selector) return;

      let target;
      try {
        target = document.querySelector(selector);
      } catch (_e) {
        return; // a malformed selector must not take the page down
      }
      if (!target) return;

      target.style.display = anyScopeClaims(selector) ? "none" : "";
    },
    destroyed() {
      // A scope can be patched away mid-selection (the list empties, a filter
      // removes it). Its count leaves with it, and the toolbar it was
      // standing in for has to come back — otherwise the page keeps a hidden
      // toolbar and no action bar, with nothing left to restore it (codex,
      // 2026-09-20).
      this.el._pkBulkCount = 0;

      const selector = this.el.dataset.bulkSwap;
      if (!selector) return;

      try {
        const target = document.querySelector(selector);
        if (target) target.style.display = anyScopeClaims(selector) ? "none" : "";
      } catch (_e) {
        // malformed selector — nothing to restore
      }
    },
    mounted() {
      this.selected = new Set();
      this._readFromDom();
      this._wire();
      this._sync();
    },
    updated() {
      // LV may have re-rendered the row set (filter, reload, delete,
      // reorder, apply_reorder, load_more). The server always renders
      // checkboxes unchecked — selection lives in this hook's in-
      // memory Set, NOT in the markup. So we restore from the Set
      // against whatever rows are in the DOM now, and prune uuids
      // whose rows are no longer present (filtered, deleted).
      //
      // Always assign `checked` explicitly (true OR false) — never
      // skip the false case. Morphdom can reuse input nodes whose
      // `dataset.uuid` changed (row swapped under the same node), and
      // a stale `checked=true` left over from that reuse would render
      // a phantom selection that this.selected doesn't actually own.
      const surviving = new Set();
      this.el.querySelectorAll('[data-bulk-role="row"]').forEach((r) => {
        const uuid = r.dataset.uuid;
        const want = !!(uuid && this.selected.has(uuid));
        r.checked = want;
        if (want) surviving.add(uuid);
      });
      this.selected = surviving;
      this._wire();
      this._sync();
    },
    _readFromDom() {
      // Initial mount: read whatever is already checked in the markup.
      // Used only by mounted(); updated() restores from the in-memory
      // Set instead so selection survives LV re-renders.
      this.selected.clear();
      this.el.querySelectorAll('[data-bulk-role="row"]').forEach((r) => {
        if (r.checked && r.dataset.uuid) this.selected.add(r.dataset.uuid);
      });
    },
    _wire() {
      const self = this;
      const header = this.el.querySelector('[data-bulk-role="select-all"]');
      if (header && !header._pkBulkWired) {
        header.addEventListener("click", function() { self._onHeaderClick(header); });
        header._pkBulkWired = true;
      }
      this.el.querySelectorAll('[data-bulk-role="row"]').forEach(function(r) {
        if (r._pkBulkWired) return;
        r.addEventListener("click", function() { self._onRowClick(r); });
        r._pkBulkWired = true;
      });
      this.el.querySelectorAll("[data-bulk-action]").forEach(function(btn) {
        if (btn._pkBulkWired) return;
        btn.addEventListener("click", function(e) { self._onActionClick(e, btn); });
        btn._pkBulkWired = true;
      });
      this.el.querySelectorAll("[data-bulk-clear]").forEach(function(btn) {
        if (btn._pkBulkWired) return;
        btn.addEventListener("click", function() { self._clearAll(); });
        btn._pkBulkWired = true;
      });
    },
    _onHeaderClick(header) {
      const rows = this.el.querySelectorAll('[data-bulk-role="row"]');
      const self = this;
      if (header.checked) {
        rows.forEach(function(r) {
          r.checked = true;
          if (r.dataset.uuid) self.selected.add(r.dataset.uuid);
        });
      } else {
        rows.forEach(function(r) { r.checked = false; });
        this.selected.clear();
      }
      this._sync();
    },
    _onRowClick(input) {
      const uuid = input.dataset.uuid;
      if (!uuid) return;
      if (input.checked) this.selected.add(uuid);
      else this.selected.delete(uuid);
      this._sync();
    },
    _onActionClick(e, btn) {
      e.preventDefault();
      const event = btn.dataset.bulkAction;
      if (!event) return;

      // Honor `data-confirm` ourselves: this handler already called
      // `e.preventDefault()` above, and phoenix_html's own window-level
      // click listener bails out early via `if (e.defaultPrevented) return;`
      // — so a button carrying both `data-confirm` and `data-bulk-action`
      // would otherwise never show the native confirm dialog and the
      // action would fire immediately with no prompt.
      const confirmMessage = btn.dataset.confirm;
      if (confirmMessage && !window.confirm(confirmMessage)) return;

      // If the button is paired with a kept-in-DOM dialog, open it
      // locally BEFORE pushing the event. The server still gets the
      // payload + flips its `@show_*_modal` assign for state sync,
      // but the user sees the modal instantly instead of waiting
      // for the round-trip.
      const dialogId = btn.dataset.bulkOpensDialog;
      if (dialogId) {
        const dialog = document.getElementById(dialogId);
        if (dialog && !dialog.open && typeof dialog.showModal === "function") {
          dialog.showModal();
        }
      }

      this.pushEventTo(this.el, event, { uuids: Array.from(this.selected) });
    },
    _clearAll() {
      this.el.querySelectorAll('[data-bulk-role="row"]').forEach(function(r) {
        r.checked = false;
      });
      this.selected.clear();
      this._sync();
    },
    _sync() {
      const total = parseInt(this.el.dataset.bulkTotal || "0", 10);
      const count = this.selected.size;

      const header = this.el.querySelector('[data-bulk-role="select-all"]');
      if (header) {
        header.checked = count > 0 && count === total;
        header.indeterminate = count > 0 && count < total;
      }

      this.el.querySelectorAll("[data-bulk-count]").forEach(function(el) {
        el.textContent = String(count);
      });

      this.el.querySelectorAll("[data-bulk-text-template]").forEach(function(el) {
        el.textContent = el.dataset.bulkTextTemplate.replace("%{count}", String(count));
      });

      this.el.querySelectorAll("[data-bulk-show]").forEach(function(el) {
        const mode = el.dataset.bulkShow;
        const visible =
          mode === "has-selection" ? count > 0 :
          mode === "no-selection" ? count === 0 :
          mode === "has-multiple" ? count > 1 :
          // count is 0 OR > 1 — used by reorder-like buttons whose
          // single-row case is a no-op (count=1 hides the button).
          mode === "not-single" ? count !== 1 : true;
        el.style.display = visible ? "" : "none";
      });

      this._syncSwap(count);

      // Label flip: requires at least the `selected` variant. The
      // `empty` variant is optional — when absent, count <= 1 leaves
      // the server-rendered initial text in place (which is fine,
      // since a button without label-empty is also typically gated
      // to hide at low counts via data-bulk-show).
      //
      // Threshold is `> 1`, not `> 0`: a one-row "Reorder selected"
      // is a no-op (permuting a single row leaves it where it was),
      // and "Delete 1 selected" reads identically to bare "Delete".
      // Showing the empty label at count=1 keeps the button label
      // honest about what's actually going to happen.
      this.el.querySelectorAll("[data-bulk-label-selected]").forEach(function(el) {
        const empty = el.dataset.bulkLabelEmpty;
        const label = count > 1
          ? el.dataset.bulkLabelSelected.replace("%{count}", String(count))
          : empty;
        if (label === undefined) return;
        // Only swap the text node so we don't blow away icon children.
        let updated = false;
        for (const node of el.childNodes) {
          if (node.nodeType === Node.TEXT_NODE && node.textContent.trim() !== "") {
            node.textContent = label;
            updated = true;
            break;
          }
        }
        if (!updated) el.appendChild(document.createTextNode(label));
      });
    }
  };

  // ---------------------------------------------------------------------------
  // TableLocalSearch Hook
  // ---------------------------------------------------------------------------
  //
  // Client-instant narrowing for list tables that use <.search_toolbar>:
  // while the debounced server round-trip is in flight, rows are hidden
  // locally so the filter feels immediate. The server response stays
  // authoritative — its patch replaces the row set, and `updated()`
  // re-applies the live query so the two never fight.
  //
  // Attach to an element wrapping BOTH the search input and the rows:
  //
  //   <div id="..." phx-hook="TableLocalSearch"
  //        data-local-search-enabled={to_string(@all_rows_loaded?)}>
  //     <.search_toolbar ... />
  //     ...rows carrying a lowercase data-search="haystack" attribute...
  //     <p data-local-search-empty class="hidden">No matches</p>
  //   </div>
  //
  // When `data-local-search-enabled` != "true" (the row set is incomplete
  // because server pagination is in play), the hook does nothing — hiding
  // only the loaded rows would falsely report "no matches" for rows that
  // live beyond the current page. The server search covers that case.
  window.PhoenixKitAdminHooks.TableLocalSearch = {
    mounted() {
      this._onInput = (e) => {
        const input = this._input();
        if (!input || e.target !== input) return;
        this._apply();
      };
      this.el.addEventListener("input", this._onInput);
    },
    updated() {
      // A server patch landed (authoritative row set) — re-apply the
      // current query so re-added rows don't flash unfiltered, and so
      // client-added `hidden` classes get reconciled with server truth.
      this._apply();
    },
    destroyed() {
      this.el.removeEventListener("input", this._onInput);
    },
    _input() {
      return this.el.querySelector('input[name="search"]');
    },
    _apply() {
      if (this.el.dataset.localSearchEnabled !== "true") return;
      const input = this._input();
      const q = ((input && input.value) || "").trim().toLowerCase();
      let visible = 0;
      this.el.querySelectorAll("[data-search]").forEach((row) => {
        const match = q === "" || (row.dataset.search || "").includes(q);
        row.classList.toggle("hidden", !match);
        if (match) visible += 1;
      });
      const empty = this.el.querySelector("[data-local-search-empty]");
      if (empty) empty.classList.toggle("hidden", !(q !== "" && visible === 0));
    }
  };

  // ---------------------------------------------------------------------------
  // AdminSidebarScroll — keep the admin menu's scroll position across
  // navigations.
  // ---------------------------------------------------------------------------
  //
  // Every sidebar navigation rebuilds the sidebar DOM: a live redirect
  // replaces the whole main container, and cross-live_session navigation
  // (each feature module has its own session) is a full page reload. Both
  // reset the menu's scrollTop to 0 — on short screens most of the menu
  // lives below the fold, so the user loses their place on every click.
  //
  // Design (per the sidebar-scroll design review):
  //   * scroll position is client/viewport state — it is saved to
  //     sessionStorage (per-tab) and restored, never sent to the server;
  //   * SAVE: one document-level capture listener (scroll doesn't bubble,
  //     but it does capture), rAF-throttled, plus flushes on
  //     phx:page-loading-start and pagehide so the final position right
  //     before a navigation is never lost. Document/window listeners
  //     survive live redirects, so there is nothing to re-bind or clean up.
  //   * RESTORE: the AdminSidebarScroll hook's mounted() — which re-fires
  //     on every live redirect because the container is replaced — runs
  //     synchronously with the DOM patch, before paint (no flash at 0).
  //     Full page loads restore at DOMContentLoaded, before the LiveView
  //     socket connects.
  //   * CORRECTION: when nothing is saved (fresh tab, deep link) or the
  //     restored offset leaves the current page's [aria-current="page"]
  //     link off-screen (menu shape changed: permissions, locale, module
  //     set), center the active link instead. Direct scrollTop math, not
  //     scrollIntoView — the latter can scroll ancestor containers too.
  (function () {
    const EL_ID = "pk-admin-sidebar";
    const KEY = "phoenix_kit:admin:sidebar:scroll";

    function readSaved() {
      try {
        const v = sessionStorage.getItem(KEY);
        if (v == null) return null;
        const n = parseInt(v, 10);
        return isNaN(n) ? null : n;
      } catch (_e) {
        return null;
      }
    }

    function save(el) {
      try {
        sessionStorage.setItem(KEY, String(Math.round(el.scrollTop)));
      } catch (_e) {
        // Storage unavailable (private browsing etc.) — degrade to the
        // active-item fallback on the next load.
      }
    }

    function restore(el) {
      const max = Math.max(0, el.scrollHeight - el.clientHeight);
      const saved = readSaved();
      if (saved != null) {
        el.scrollTop = Math.min(saved, max);
      }

      const active = el.querySelector('[aria-current="page"]');
      if (!active) return;
      const er = el.getBoundingClientRect();
      const ar = active.getBoundingClientRect();
      const visible = ar.top >= er.top && ar.bottom <= er.bottom;
      if (saved == null || !visible) {
        const target = el.scrollTop + (ar.top - er.top) - (el.clientHeight - ar.height) / 2;
        el.scrollTop = Math.min(Math.max(0, target), max);
      }
    }

    // Save side — bound once per full page load, element-independent.
    let saveQueued = false;
    document.addEventListener(
      "scroll",
      function (e) {
        const el = e.target;
        if (!el || el.id !== EL_ID || saveQueued) return;
        saveQueued = true;
        requestAnimationFrame(function () {
          saveQueued = false;
          const live = document.getElementById(EL_ID);
          if (live) save(live);
        });
      },
      { capture: true, passive: true }
    );

    function flush() {
      const el = document.getElementById(EL_ID);
      if (el) save(el);
    }
    window.addEventListener("phx:page-loading-start", flush);
    window.addEventListener("pagehide", flush);

    // Restore on full page loads (before the socket connects).
    function early() {
      const el = document.getElementById(EL_ID);
      if (el) restore(el);
    }
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", early);
    } else {
      early();
    }

    // Restore on live redirects (mounted re-fires on the fresh container,
    // pre-paint). Idempotent with the early restore on full loads.
    window.PhoenixKitAdminHooks.AdminSidebarScroll = {
      mounted() {
        restore(this.el);
      }
    };
  })();

  // PkDialogDraft — preserves an in-progress form across a LiveView RECONNECT
  // (a websocket drop, e.g. on flaky/slow internet). A reconnect re-mounts the
  // LiveView with fresh assigns, so a modal driven by a server flag collapses
  // and the typed data is lost — LiveView's native form recovery can't help
  // because the form isn't rendered after remount (a skeleton is). This hook
  // keeps a live snapshot of the form in a JS variable (memory only — cleared
  // on close and on unload, so a tab close / refresh is NOT preserved, by
  // design) and, once reconnected, pushes it back so the server rebuilds the
  // modal exactly where the user left off.
  //
  // Attach to a STABLE element that is always rendered (NOT the <dialog>,
  // which already carries PkDialog and whose body is conditionally rendered):
  //   <div phx-hook="PkDialogDraft" id="…"
  //        data-draft-form="calendar-event-form"   (the <form> id to snapshot)
  //        data-draft-restore-event="restore_event_draft"
  //        data-draft-scope="#calendar-event-modal" (where owner/tz inputs live,
  //                                                   outside the <form>)
  //        data-draft-active="true|false"           (server: modal open + editable)
  //        data-draft-key="new|<uuid>">             (which event)
  var pkDialogDrafts = {};
  var pkWasDisconnected = false;
  if (typeof window !== "undefined") {
    window.addEventListener("phx:disconnected", function () {
      pkWasDisconnected = true;
    });
  }

  window.PhoenixKitAdminHooks.PkDialogDraft = {
    mounted() {
      var self = this;
      this.formId = this.el.dataset.draftForm;
      this.restoreEvent = this.el.dataset.draftRestoreEvent || "restore_draft";
      this.scopeSel = this.el.dataset.draftScope;

      this._snapshot = function () {
        if (self.el.dataset.draftActive !== "true") {
          delete pkDialogDrafts[self.el.id];
          return;
        }
        var form = document.getElementById(self.formId);
        if (!form) return;
        var ev = {};
        new FormData(form).forEach(function (v, k) {
          var m = k.match(/^event\[(.+)\]$/);
          if (m) ev[m[1]] = v;
        });
        // owner / owner_tz_entry live OUTSIDE the <form> (in the modal box)
        var scope = self.scopeSel ? document.querySelector(self.scopeSel) : document;
        var owner = scope && scope.querySelector('[name="owner"]');
        var ownerTz = scope && scope.querySelector('[name="owner_tz_entry"]');
        pkDialogDrafts[self.el.id] = {
          key: self.el.dataset.draftKey || "new",
          event: ev,
          owner: owner ? owner.value : null,
          owner_tz_entry: ownerTz && ownerTz.checked ? "true" : null,
        };
      };

      this._onInput = function () {
        self._snapshot();
      };
      // capture on every edit (bubbles up from the form's inputs)
      document.addEventListener("input", this._onInput, true);
      document.addEventListener("change", this._onInput, true);

      this._onUnload = function () {
        delete pkDialogDrafts[self.el.id];
      };
      window.addEventListener("beforeunload", this._onUnload);

      // Reconnect restore: mounted() runs again after a reconnect re-mount.
      // If we were disconnected and still hold a draft, hand it back so the
      // server can reopen the modal with the user's data.
      this._maybeRestore();
    },

    updated() {
      // The server closed the modal on a live connection — saved, cancelled
      // or dismissed. The draft is finished with: left in place, the next
      // reconnect would hand it back and reopen a modal the user had closed,
      // or one whose contents were already saved. After a reconnect the flag
      // also reads "false", but that is the re-mount, and the draft is
      // exactly what `_maybeRestore` is about to use.
      if (!pkWasDisconnected && this.el.dataset.draftActive !== "true") {
        delete pkDialogDrafts[this.el.id];
      }
      this._maybeRestore();
    },

    _maybeRestore() {
      if (!pkWasDisconnected) return;
      var draft = pkDialogDrafts[this.el.id];
      if (!draft) {
        pkWasDisconnected = false;
        return;
      }
      // only restore into a modal the server hasn't already reopened
      if (this.el.dataset.draftActive === "true") return;
      pkWasDisconnected = false;
      this.pushEvent(this.restoreEvent, draft);
    },

    destroyed() {
      document.removeEventListener("input", this._onInput, true);
      document.removeEventListener("change", this._onInput, true);
      window.removeEventListener("beforeunload", this._onUnload);
    },
  };

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // AnnotationBurn — keep a copy of the picture with the markup drawn into it
  //
  // The variants a file serves are the picture as uploaded. That is the right
  // thing for an editor and the wrong thing for everywhere else: a grid card,
  // a link someone pastes into a chat, a right-click → Copy Image all show
  // the picture WITHOUT the arrows and measurements that are the reason it
  // was annotated. This burns the annotations in and stores the result over
  // those variants, so the markup travels with the picture.
  //
  // It composes in the BROWSER. The alternative — drawing the shapes again
  // on the server — means a second renderer that has to agree with the first
  // about fonts, label plates, spline smoothing and stroke geometry forever,
  // and every disagreement shows up as a thumbnail that does not match the
  // drawing. Composing from the live overlay is exact by construction: it is
  // the same SVG the user was just looking at. (`Etcher.Raster` stays the
  // server-side path for backfill, where an approximation is the right
  // trade because nobody has the picture open.)
  //
  // When it runs: the end of an editing session — switching Etcher off,
  // closing the viewer, or stepping to another file. All three are "I am
  // done with this" and none should be blocking, so the burn runs in the
  // background with a line of text to say it is happening.
  // ---------------------------------------------------------------------------

  // Properties that carry the look. A serialised SVG cannot see the page's
  // stylesheet, so whatever is not copied onto the element is lost.
  var BURN_STYLE_PROPS = [
    "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity",
    "stroke-dasharray", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
    "opacity", "color", "font-family", "font-size", "font-weight", "font-style",
    "letter-spacing", "text-anchor", "dominant-baseline", "paint-order", "visibility",
    "mix-blend-mode", "filter", "transform", "transform-origin", "display"
  ];

  // Chrome: things you grab, things that only say "this one is selected",
  // and things still being drawn. None of it belongs in the picture.
  //
  // `.etcher-text-editor` is the inline label editor — a <foreignObject>
  // with a live <textarea> over the shape being typed into. Closing or
  // stepping the viewer burns in capture phase, BEFORE Etcher's own
  // click-outside commit can take the editor down, so without this a
  // burn taken mid-edit rendered the input box — placeholder text,
  // borders and all — into the stored copy. The committed label (when
  // there is one) is the <text> the shape itself carries; the editor is
  // only ever the form control.
  var BURN_CHROME = [
    ".etcher-handle", ".etcher-grab", ".etcher-handle-line", ".etcher-handle-midpoint",
    ".etcher-handle-edge", ".etcher-connector-hit", ".etcher-connector-dot",
    ".etcher-title-handle", ".etcher-snap-guide", ".etcher-marquee", ".is-draft",
    ".etcher-badge", ".etcher-text-editor"
  ];

  // Momentary looks, suspended while the styles are read and restored in the
  // same frame: the ring on whatever the cursor happens to be over should not
  // set in the picture.
  var BURN_STATE = ["is-hovered", "is-selected", "is-editing", "is-dragging", "is-close-target"];

  // A drawing written the same way every time, whatever order the keys
  // arrive in.
  //
  // A shape just drawn carries `{x, y, w, h}`; the same shape read back
  // after a round trip through the database carries `{h, w, x, y}` — same
  // numbers, different order, and `JSON.stringify` writes what it is given.
  // Comparing those two strings says "changed" about a drawing nobody
  // touched, which is one needless full-resolution render per visit.
  function burnCanonical(v) {
    if (Array.isArray(v)) return "[" + v.map(burnCanonical).join(",") + "]";
    if (v && typeof v === "object") {
      return "{" + Object.keys(v).sort().map(function(k) {
        return JSON.stringify(k) + ":" + burnCanonical(v[k]);
      }).join(",") + "}";
    }
    return JSON.stringify(v === undefined ? null : v);
  }

  // A cheap, stable hash of the drawing (FNV-1a, 32-bit, hex). Not a
  // security property — just a short thing to compare, computed the same
  // way on the way out and on the way back in.
  function burnHash(str) {
    var h = 0x811c9dc5;
    for (var i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i);
      h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
    }
    return h.toString(16);
  }

  function burnNote(text, ms) {
    var el = document.getElementById("pk-burn-note");
    if (!el) {
      el = document.createElement("div");
      el.id = "pk-burn-note";
      el.className =
        "fixed left-1/2 -translate-x-1/2 top-6 z-[9999] px-4 py-2 rounded-lg shadow-lg " +
        "bg-base-300 text-base-content text-sm";
      document.body.appendChild(el);
    }
    el.textContent = text;
    clearTimeout(el._t);
    if (ms) el._t = setTimeout(function() { el.remove(); }, ms);
    return el;
  }

  // The viewer's image→screen mapping, from three image points. An X-only
  // delta is 0 at 90°/270° and negative at 180°, which used to abandon the
  // burn; `s` is the (positive) scale and cos/sin are the image +X axis in
  // screen space. The burned pixels stay in image space — the viewer
  // reapplies `initial_rotation` when it shows them.
  function burnViewAffine(p0, px, py, rect) {
    if (!p0 || !px || !py || !rect) return null;
    var vx = px.x - p0.x, vy = px.y - p0.y;
    var s = Math.hypot(vx, vy) / 1000;
    if (!(s > 0)) return null;
    return {
      s: s,
      cos: vx / (1000 * s),
      sin: vy / (1000 * s),
      tx: p0.x - rect.left,
      ty: p0.y - rect.top
    };
  }

  // Container px (the overlay's own space) → image px.
  function burnContainerToImage(ax, x, y) {
    var dx = x - ax.tx, dy = y - ax.ty;
    return {
      x: (dx * ax.cos + dy * ax.sin) / ax.s,
      y: (-dx * ax.sin + dy * ax.cos) / ax.s
    };
  }

  // Whether `el` is chrome or sits inside chrome — what the copy below cuts.
  function burnIsChrome(el) {
    for (var i = 0; i < BURN_CHROME.length; i++) {
      if (el.closest && el.closest(BURN_CHROME[i])) return true;
    }
    return false;
  }

  // The box the burned picture spans, in image px: the W×H picture plus
  // every piece of ink the copy keeps. `els` are the overlay's shapes and
  // their descendants; `toImage(x, y)` maps a client point into image px.
  //
  // Only leaves with a size are measured, and nothing that is, or sits
  // inside, chrome. A group's own box is the union of its children's, empty
  // ones included: a dimension's label group (`.etcher-title-group`) keeps
  // a 0×0 leader at the overlay's origin, so the group reached up to the
  // viewer's top-left corner. Burning in live mode stretched the canvas by
  // the whole margin above the picture — the taller the viewer, the bigger
  // — and a landscape photo came back portrait, squeezed into its bottom
  // third under a blank block. Chrome (handles, hit areas, a shape still
  // being drawn — Escape burns before Etcher drops a draft, this hook
  // listens in the capture phase) is cut from the copy, so it must not
  // size the canvas either.
  function burnInkBounds(els, toImage, W, H) {
    var b = { minX: 0, minY: 0, maxX: W, maxY: H };
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (el.firstElementChild || burnIsChrome(el)) continue;
      var r = el.getBoundingClientRect();
      if (!r.width && !r.height) continue;
      [[r.left, r.top], [r.right, r.top], [r.right, r.bottom], [r.left, r.bottom]]
        .forEach(function(corner) {
          var p = toImage(corner[0], corner[1]);
          if (p.x < b.minX) b.minX = p.x;
          if (p.y < b.minY) b.minY = p.y;
          if (p.x > b.maxX) b.maxX = p.x;
          if (p.y > b.maxY) b.maxY = p.y;
        });
    }
    return b;
  }

  // SVG matrix mapping container px into the output bitmap (image px × k,
  // cropped to the union that starts at minX/minY).
  function burnSvgMatrix(ax, k, minX, minY) {
    var m = k / ax.s;
    return [
      m * ax.cos,
      -m * ax.sin,
      m * ax.sin,
      m * ax.cos,
      m * (-ax.cos * ax.tx - ax.sin * ax.ty) - minX * k,
      m * (ax.sin * ax.tx - ax.cos * ax.ty) - minY * k
    ];
  }

  // Everything the render needs, taken while the overlay is still on screen.
  // Split from the render so a burn survives the viewer closing underneath
  // it: by the time anything out here hears about a close, the DOM being
  // composed is already gone.
  function burnCapturePlan(host) {
    if (!host) return null;
    var handle = window.Fresco && window.Fresco.viewerFor && window.Fresco.viewerFor(host.id);
    var img = host.querySelector("img[data-fresco-canvas-img]");
    var svg = host.querySelector(".etcher-overlay svg");
    if (!handle || !img || !svg) return null;

    var W = parseFloat(img.dataset.canvasWidth) || img.naturalWidth;
    var H = parseFloat(img.dataset.canvasHeight) || img.naturalHeight;
    if (!(W > 0 && H > 0)) return null;

    // The widest rung the page knows about — Tessera lists them, signed URLs
    // and all — so the burn is made from the original rather than from
    // whatever the viewer happened to have loaded.
    var sourceUrl = img.getAttribute("src");
    var sourceWidth = img.naturalWidth || W;
    // This picture's own ladder. A document-wide lookup would compose
    // another canvas's source into this file.
    var column = host.closest("[id^='pk-annotation-actions-']") || host.parentElement;
    var listEl = column && column.querySelector("[data-sources]");
    if (listEl) {
      try {
        (JSON.parse(listEl.getAttribute("data-sources")) || []).forEach(function(s) {
          if (s && s.url && s.width > sourceWidth) { sourceUrl = s.url; sourceWidth = s.width; }
        });
      } catch (_) { /* malformed list → the on-screen picture stands */ }
    }
    // Never past the picture's own pixels. The ladder lists each rung at
    // its configured box (large = 1920), not at the size it really came out
    // — a 500px picture's "large" is 500px — so a small picture was composed
    // at nearly four times its size: the burned copy then opened at 100% as
    // a huge image beside the original's true-size one, and a clean burn of
    // it no longer matched the picture it was made from. The canvas width
    // IS the picture's natural width.
    sourceWidth = Math.min(sourceWidth, W);
    var k = sourceWidth / W;

    // The overlay is laid out in CONTAINER px. Three image points recover
    // the full affine, rotation included — two points on X cannot see a
    // quarter turn.
    var rect = host.getBoundingClientRect();
    var ax = burnViewAffine(
      handle.imageToScreen({ x: 0, y: 0 }),
      handle.imageToScreen({ x: 1000, y: 0 }),
      handle.imageToScreen({ x: 0, y: 1000 }),
      rect
    );
    if (!ax) return null;

    // Etcher lets you draw past the edges of the picture, and that ink is as
    // much a part of the markup as the rest — an arrow pointing in from the
    // margin, a note written beside the photo. The output is the union of
    // the picture and everything drawn.
    var ink = burnInkBounds(
      svg.querySelectorAll(".etcher-shape, .etcher-shape *"),
      function(x, y) { return burnContainerToImage(ax, x - rect.left, y - rect.top); },
      W, H
    );
    var minX = Math.floor(ink.minX), minY = Math.floor(ink.minY);
    var maxX = Math.ceil(ink.maxX), maxY = Math.ceil(ink.maxY);

    // Transitions off for the read. The selected and hovered looks fade
    // out (a text's box, for one, eases its stroke over 120ms), so with
    // them running the styles read below would be the look's first frame
    // of fading — and a text that happened to be selected when the session
    // ended was stored with its blue selection box drawn round it.
    var stillStyle = document.createElement("style");
    stillStyle.textContent = ".pk-burn-still, .pk-burn-still * { transition: none !important; }";
    document.head.appendChild(stillStyle);
    svg.classList.add("pk-burn-still");

    var suspended = [];
    var clone, live, copy;
    try {
      svg.querySelectorAll("." + BURN_STATE.join(", .")).forEach(function(el) {
        var had = BURN_STATE.filter(function(c) { return el.classList.contains(c); });
        if (had.length) {
          suspended.push([el, had]);
          had.forEach(function(c) { el.classList.remove(c); });
        }
      });

      clone = svg.cloneNode(true);
      live = [svg].concat(Array.prototype.slice.call(svg.querySelectorAll("*")));
      copy = [clone].concat(Array.prototype.slice.call(clone.querySelectorAll("*")));
      for (var i = 0; i < live.length; i++) {
        var cs = getComputedStyle(live[i]);
        var css = "";
        for (var p = 0; p < BURN_STYLE_PROPS.length; p++) {
          var v = cs.getPropertyValue(BURN_STYLE_PROPS[p]);
          if (v && v !== "normal" && v !== "auto") css += BURN_STYLE_PROPS[p] + ":" + v + ";";
        }
        copy[i].setAttribute("style", css);
        copy[i].removeAttribute("class");
      }
    } finally {
      suspended.forEach(function(pair) {
        pair[1].forEach(function(c) { pair[0].classList.add(c); });
      });
      svg.classList.remove("pk-burn-still");
      if (stillStyle.parentNode) stillStyle.parentNode.removeChild(stillStyle);
    }
    BURN_CHROME.forEach(function(sel) {
      live.forEach(function(el, idx) {
        if (el.matches && el.matches(sel) && copy[idx] && copy[idx].remove) copy[idx].remove();
      });
    });

    var NS = "http://www.w3.org/2000/svg";
    var out = { w: Math.round((maxX - minX) * k), h: Math.round((maxY - minY) * k) };
    var g = document.createElementNS(NS, "g");
    g.setAttribute("transform", "matrix(" + burnSvgMatrix(ax, k, minX, minY).join(",") + ")");
    while (clone.firstChild) g.appendChild(clone.firstChild);
    clone.appendChild(g);
    clone.setAttribute("xmlns", NS);
    clone.setAttribute("width", out.w);
    clone.setAttribute("height", out.h);
    clone.setAttribute("viewBox", "0 0 " + out.w + " " + out.h);
    clone.removeAttribute("style");

    var viewer = host.closest(".fresco-viewer") || host;
    var bg = getComputedStyle(viewer).backgroundColor;

    return {
      svgText: new XMLSerializer().serializeToString(clone),
      sourceUrl: sourceUrl,
      out: out,
      picture: { w: W * k, h: H * k, x: -minX * k, y: -minY * k },
      background: bg && bg !== "rgba(0, 0, 0, 0)" ? bg : "#ffffff"
    };
  }

  // No DOM of the viewer's needed from here on — the plan holds everything.
  function burnRender(plan) {
    var format = plan.format || "jpeg";
    // An animation's frames only exist on the server: the burn sent for it
    // is the markup alone, on a transparent canvas, with the picture's place
    // in it sent alongside (see `burnUpload`).
    var markupOnly = format === "gif";
    return new Promise(function(resolve, reject) {
      function compose(picture) {
        var overlay = new Image();
        overlay.onload = function() {
          var canvas = document.createElement("canvas");
          canvas.width = plan.out.w;
          canvas.height = plan.out.h;
          var ctx = canvas.getContext("2d");
          ctx.imageSmoothingQuality = "high";
          // JPEG has no alpha: every pixel the picture does not cover would
          // encode as black without this. Every other format keeps what
          // the picture doesn't cover see-through.
          if (format === "jpeg") {
            ctx.fillStyle = plan.background;
            ctx.fillRect(0, 0, plan.out.w, plan.out.h);
          }
          if (picture) {
            ctx.drawImage(picture, plan.picture.x, plan.picture.y, plan.picture.w, plan.picture.h);
          }
          ctx.drawImage(overlay, 0, 0, plan.out.w, plan.out.h);
          // A browser that cannot encode WebP hands back a PNG; the server
          // re-encodes either way.
          var type = format === "jpeg" ? "image/jpeg" : format === "webp" ? "image/webp" : "image/png";
          canvas.toBlob(function(blob) {
            blob ? resolve(blob) : reject(new Error("the browser produced no image"));
          }, type, 0.9);
        };
        overlay.onerror = function() { reject(new Error("the markup did not rasterise")); };
        overlay.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(plan.svgText);
      }
      if (markupOnly) { compose(null); return; }
      var picture = new Image();
      picture.onload = function() { compose(picture); };
      picture.onerror = function() { reject(new Error("the picture did not load")); };
      picture.src = plan.sourceUrl;
    });
  }

  function burnUpload(uuid, blob, variants, sourceVersion, fingerprint, plan) {
    var body = new FormData();
    var ext = blob.type === "image/png" ? "png" : blob.type === "image/webp" ? "webp" : "jpg";
    body.append("image", blob, "burn." + ext);
    // A markup-only burn says where the picture goes in it.
    if (plan && plan.format === "gif") {
      body.append("canvas_w", plan.out.w);
      body.append("canvas_h", plan.out.h);
      body.append("picture_x", plan.picture.x);
      body.append("picture_y", plan.picture.y);
      body.append("picture_w", plan.picture.w);
      body.append("picture_h", plan.picture.h);
    }
    body.append("variants", variants);
    if (sourceVersion) body.append("source_version", sourceVersion);
    // Recorded against the stored copy, so the next visit can tell whether
    // this drawing has already been burned.
    if (fingerprint) body.append("fingerprint", fingerprint);
    var csrf = document.querySelector("meta[name='csrf-token']");
    // Same prefix derivation the consent widget uses: PHOENIX_KIT_PREFIX is
    // emitted by the js_sources compiler, and the literal is the fallback
    // for a host that predates it.
    var prefix = window.PHOENIX_KIT_PREFIX || "/phoenix_kit";
    if (prefix === "/") prefix = "";

    return fetch(prefix + "/api/files/" + uuid + "/burn", {
      method: "POST",
      body: body,
      headers: csrf ? { "x-csrf-token": csrf.getAttribute("content") } : {},
      credentials: "same-origin"
    }).then(function(res) {
      return res.json().catch(function() { return {}; }).then(function(json) {
        if (!res.ok) throw new Error(json.message || res.status + " " + res.statusText);
        return json;
      });
    });
  }

  window.PhoenixKitAdminHooks.AnnotationBurn = {
    mounted() {
      var self = this;
      this._uuid = this.el.dataset.fileUuid;
      // thumbnail = list rows, burned = grid cards (card-sized),
      // burned_large = the copy this viewer opens with. small/medium/large
      // are the editor's own ladder; burning those draws the shapes twice.
      this._variants = this.el.dataset.burnVariants || "thumbnail,burned,burned_large";
      this._host = function() {
        var column = self.el.closest("[id^='pk-annotation-actions-']");
        return column && column.querySelector('[phx-hook="FrescoCanvas"]');
      };
      // What the STORED burn was made from. The comparison is against this,
      // not against a baseline taken at mount: Etcher hydrates its shapes
      // after the hook mounts, so a mount-time baseline reads an empty
      // drawing and makes the first close look like a change — burning a
      // full-resolution copy of a picture nobody touched.
      this._burned = this.el.dataset.burnFingerprint || null;
      this._running = false;
      this._pending = null;
      this._inFlight = null;

      this._allowCopy();

      // The pencil goes in Fresco's own nav rail, beside fullscreen and
      // zoom, through the rail's own API. An absolutely-positioned button
      // of ours lands ON TOP of that rail instead of in it: technically
      // clickable, invisible to a person, and covering fullscreen.
      this._addModeButton();

      // Switching Etcher off ends an editing session.
      this._onMode = function(e) {
        if (e.detail && e.detail.annotationMode) return;

        // Etcher off means done editing, so: render what was drawn (only
        // if it changed), and go back to the burned picture. Capture
        // happens here, before the canvas is replaced and the overlay
        // being composed goes with it.
        self.burnIfChanged();

        if (self.el.dataset.burnMode !== "true" && self.el.dataset.hasBurn === "true") {
          self.pushEventTo(self.el, "toggle_burn_mode", {});
        }
      };
      document.addEventListener("etcher:mode-changed", this._onMode);

      // Came here from the pencil in the burned view: the live layer is up
      // now, so turn Etcher on — that press meant "let me draw", not "show
      // me the shapes".
      if (this.el.dataset.autoAnnotate === "true") this._armEtcher();

      // So does closing the viewer, and stepping to the neighbour: an arrow
      // or a chevron remounts the viewer on the next file and tears this
      // overlay down. Caught on the way IN, while the overlay is still
      // there to compose from. A keystroke into a field is not a step.
      this._onClosing = function(e) {
        var t = e.target;
        var typing = t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" ||
                           t.isContentEditable === true);
        var stepping = !typing && (
          (e.type === "keydown" && (e.key === "ArrowLeft" || e.key === "ArrowRight")) ||
          (e.type === "pointerdown" && t && t.closest && t.closest('[phx-click="step_viewer"]'))
        );
        var closing =
          (e.type === "keydown" && e.key === "Escape") ||
          (t && t.closest && (t.closest('[phx-click="close_viewer"]') || t.closest(".modal-backdrop")));
        if (closing || stepping) self.burnIfChanged();
      };
      document.addEventListener("pointerdown", this._onClosing, true);
      document.addEventListener("keydown", this._onClosing, true);
    },

    // The viewer's own nav buttons, on whichever canvas is up:
    //
    // - The pencil: picture ⇄ editor. The burn is one flat picture with
    //   the markup already in it; the live layer is the picture with
    //   shapes you can select and edit over the top. Only one of them
    //   can be on screen, so this is the switch between them rather
    //   than a visibility toggle. Offered on the burned picture and on
    //   the clean one; in the editor, Etcher's own pencil is the one on
    //   screen.
    // - The eye: markup shown ⇄ the clean original. Hiding the etchings
    //   cannot be a client-side flip — on the burned picture the markup
    //   is baked into the bitmap — so the press asks the server to swap
    //   the canvas for the picture with nothing in it. From the editor
    //   it also ends the session: the drawing is composed for the burn
    //   first, while the overlay still exists. Deliberately not
    //   persisted: every open starts with the markup showing.
    //
    // The one surface that gets neither is a read-only live layer (no
    // burn to show, nothing to edit): Etcher's own :visibility eye is
    // there, and hiding the locked overlay is the whole job.
    _addModeButton() {
      var self = this;

      var burned = this.el.dataset.burnMode === "true";
      var hidden = this.el.dataset.etchingsHidden === "true";
      var canAnnotate = this.el.dataset.canAnnotate === "true";
      if (!burned && !hidden && !canAnnotate) return;

      var frescoId = this.el.dataset.frescoId;
      var handle = window.Fresco && window.Fresco.viewerFor && window.Fresco.viewerFor(frescoId);

      // Fresco mounts its canvas on its own schedule; if the handle is not
      // there yet, wait for it to announce itself.
      if (!handle) {
        if (window.Fresco && window.Fresco.onViewerReady) {
          window.Fresco.onViewerReady(frescoId, function() { self._addModeButton(); });
        }
        return;
      }

      // Already on THIS nav: nothing to do. On a different one — the mode
      // flipped, so the canvas and its whole nav were replaced — drop the
      // stale handles and append to the new rail.
      if (this._modeButtonFor === frescoId && (this._pencilButton || this._eyeButton)) return;
      if (this._modeButton) {
        try { this._modeButton(); } catch (_) {}
        this._modeButton = null;
      }
      if (this._pencilButton) {
        try { this._pencilButton(); } catch (_) {}
        this._pencilButton = null;
      }
      if (this._eyeButton) {
        try { this._eyeButton(); } catch (_) {}
        this._eyeButton = null;
      }

      var pencil =
        '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" ' +
        'stroke-width="1.5" stroke="currentColor" aria-hidden="true">' +
        '<path stroke-linecap="round" stroke-linejoin="round" d="m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652' +
        'L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Zm0 0L19.5 7.125"/></svg>';

      var eye =
        '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" ' +
        'stroke-width="1.5" stroke="currentColor" aria-hidden="true">' +
        '<path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5' +
        'c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"/>' +
        '<path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/></svg>';

      var eyeSlash =
        '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" ' +
        'stroke-width="1.5" stroke="currentColor" aria-hidden="true">' +
        '<path stroke-linecap="round" stroke-linejoin="round" d="M3.98 8.223A10.477 10.477 0 0 0 1.934 12C3.226 16.338 7.244 19.5 12 19.5' +
        'c.993 0 1.953-.138 2.863-.395M6.228 6.228A10.451 10.451 0 0 1 12 4.5c4.756 0 8.773 3.162 10.065 7.498a10.522 10.522 0 0 1' +
        '-4.293 5.774M6.228 6.228 3 3m3.228 3.228 3.65 3.65m7.894 7.894L21 21m-3.228-3.228-3.65-3.65m0 0a3 3 0 1 0-4.243-4.243' +
        'm4.242 4.242L9.88 9.88"/></svg>';

      this._modeButtonFor = frescoId;

      // The nav leads with the pencil, then the eye — by Fresco slot, the
      // same numbers Etcher's own pair uses (pencil 0, its chevron 1, eye 2),
      // so the row reads the same on the finished picture and in the editor,
      // and the pencil is at the end of the row the "more" button is not.
      // Everyone gets the eye, drawer or not: seeing the picture under the
      // markup is a viewing affordance, not an editing one.
      //
      // Pressed in the editor (!burned && !hidden), the session ends —
      // so the drawing is composed for the burn HERE, before the server
      // replaces the canvas and the overlay being composed goes with it.
      // Same capture discipline as _onMode and _onClosing.
      this._eyeButton = handle.appendNavButton(
        hidden ? eyeSlash : eye,
        hidden ? "Show annotations" : "Hide annotations",
        function() {
          if (!burned && !hidden) self.burnIfChanged();
          self.pushEventTo(self.el, "toggle_etchings", {});
        },
        { slot: 2 }
      );

      // The pencil IS the mode. On, you are in the editor — the picture
      // with a live layer over it. Off, you are looking at a finished
      // picture (burned or clean). The eye never arms the tools; the
      // pencil is how you ask to work, from either picture.
      //
      // On the finished pictures there is no Etcher to own a pencil, so
      // this is ours; in the editor Etcher's own is the one on screen,
      // and switching it off brings the burned picture back (`_onMode`).
      if ((burned || hidden) && canAnnotate) {
        this._pencilButton = handle.appendNavButton(pencil, "Annotate", function() {
          self.pushEventTo(self.el, "toggle_burn_mode", { annotate: true });
        }, { slot: 0 });
      }
    },

    // The mode flip replaces the canvas (its id changes, so LiveView mounts
    // a fresh one) but patches this element in place — so the rail the eye
    // was on is gone and the new one has no eye until this runs.
    // The burned picture and the live layer are the same drawing on two
    // canvases of different extents: the burn spans the picture AND every
    // bit of ink past its edges, the live canvas just the picture, with the
    // ink drawn around it. Each opened on its own fit, so switching the
    // pencil on or off moved the picture — left, right, left — whenever
    // anything was drawn beside it. Instead the switch carries the view:
    // where the picture-plus-ink frame sat on screen before the patch is
    // where it sits after, zoom and all.
    beforeUpdate() {
      this._viewCarry = this._captureFrame();
    },

    updated() {
      this._addModeButton();
      this._allowCopy();
      if (this.el.dataset.autoAnnotate === "true") this._armEtcher();
      var carry = this._viewCarry;
      this._viewCarry = null;
      if (carry && carry.from !== this.el.dataset.frescoId) this._applyFrame(carry);
    },

    // The frame in a canvas's own units: a burn's whole extent; on the live
    // layer the picture plus the ink, measured the way the burn measures
    // it (`burnInkBounds`), so the two describe the same piece of drawing.
    // Null for the clean picture, and for a turned view.
    _frameOf(id) {
      var handle = window.Fresco && window.Fresco.viewerFor && window.Fresco.viewerFor(id);
      var host = document.getElementById(id);
      if (!handle || !host || !handle.fitBounds || !handle.imageToScreen || !handle.screenToImage) return null;
      if (handle.getRotation && handle.getRotation()) return null;
      var W = parseFloat(host.dataset.canvasWidth), H = parseFloat(host.dataset.canvasHeight);
      if (!(W > 0 && H > 0)) return null;
      if (id.indexOf("media-burn-") === 0) return { handle: handle, x: 0, y: 0, w: W, h: H };
      if (id.indexOf("media-zoom-") !== 0) return null;
      var svg = host.querySelector(".etcher-overlay svg");
      var b = svg
        ? burnInkBounds(svg.querySelectorAll(".etcher-shape, .etcher-shape *"),
            function(x, y) { return handle.screenToImage({ x: x, y: y }); }, W, H)
        : { minX: 0, minY: 0, maxX: W, maxY: H };
      return { handle: handle, x: b.minX, y: b.minY, w: b.maxX - b.minX, h: b.maxY - b.minY };
    },

    _captureFrame() {
      var id = this.el.dataset.frescoId;
      var f = id && this._frameOf(id);
      if (!f) return null;
      var a = f.handle.imageToScreen({ x: f.x, y: f.y });
      var b = f.handle.imageToScreen({ x: f.x + f.w, y: f.y + f.h });
      return { from: id, x: a.x, y: a.y, w: b.x - a.x, h: b.y - a.y };
    },

    // Put the new canvas's frame where the old one's was. Its own fit is
    // kept off screen until then — the live layer's frame is only known
    // once Etcher has drawn its shapes — and given up on after a moment.
    _applyFrame(carry, tries) {
      var self = this;
      var id = this.el.dataset.frescoId;
      var host = document.getElementById(id);
      var left = tries == null ? 30 : tries;
      if (!host) return;
      if (left === 30) host.style.visibility = "hidden";
      var reveal = function() { host.style.visibility = ""; };
      var live = id.indexOf("media-zoom-") === 0;
      var ready = window.Fresco && window.Fresco.viewerFor && window.Fresco.viewerFor(id) &&
        (!live || (window.Etcher && window.Etcher.layerFor && window.Etcher.layerFor(id) &&
                   host.querySelector(".etcher-overlay svg")));
      if (!ready) {
        if (left > 0) setTimeout(function() { self._applyFrame(carry, left - 1); }, 30);
        else reveal();
        return;
      }
      requestAnimationFrame(function() {
        if (self.el.dataset.frescoId !== id) { reveal(); return; }
        var f = self._frameOf(id);
        if (f && f.w > 0 && f.h > 0 && carry.w > 0 && carry.h > 0) {
          // The view as a rectangle of this canvas: the viewport, seen from
          // the old frame, carried into the new one. Fitting it puts the
          // frame exactly where it was.
          var c = host.getBoundingClientRect();
          var kx = f.w / carry.w, ky = f.h / carry.h;
          f.handle.fitBounds({
            x: f.x + (c.left - carry.x) * kx,
            y: f.y + (c.top - carry.y) * ky,
            width: c.width * kx,
            height: c.height * ky
          });
        }
        requestAnimationFrame(reveal);
      });
    },

    // Right-click → Copy image, on the burned picture — and on the clean
    // original the eye swaps in (copying the picture without the markup
    // is what the eye is FOR).
    //
    // Fresco sets `pointer-events: none` on its stage images so a drag
    // anywhere over the picture pans instead of dragging the bitmap. That
    // also means a right-click never lands ON the image, so the browser
    // offers no Copy image / Save image at all — the menu is for the div
    // underneath. In the burned and plain views there is nothing to drag
    // and nothing drawn over the picture, so the image can take its own
    // context menu; panning is unaffected, because Fresco listens on the
    // container these bubble to.
    _allowCopy(tries) {
      var self = this;
      var left = tries == null ? 20 : tries;
      var finished = this.el.dataset.burnMode === "true" ||
                     this.el.dataset.etchingsHidden === "true";
      var host = document.getElementById(this.el.dataset.frescoId);
      var img = host && host.querySelector("img[data-fresco-canvas-img]");

      if (!img) {
        if (left > 0) setTimeout(function() { self._allowCopy(left - 1); }, 150);
        return;
      }
      // Live view: leave Fresco's rule alone. The picture there is the
      // plain one anyway — copying it would leave the markup behind.
      img.style.pointerEvents = finished ? "auto" : "";
    },

    // Etcher mounts with the canvas it decorates, which may be a moment
    // behind this patch; retry briefly rather than miss the arming.
    _armEtcher(tries) {
      var self = this;
      var left = tries == null ? 20 : tries;
      var layer = window.Etcher && window.Etcher.layerFor &&
                  window.Etcher.layerFor(this.el.dataset.frescoId);

      if (layer && typeof layer.setMode === "function") {
        if (!layer.getMode()) layer.setMode(true);
        return;
      }
      if (left > 0) setTimeout(function() { self._armEtcher(left - 1); }, 150);
    },

    destroyed() {
      [this._modeButton, this._pencilButton, this._eyeButton].forEach(function(off) {
        if (typeof off === "function") {
          try { off(); } catch (_) {}
        }
      });
      this._modeButton = null;
      this._pencilButton = null;
      this._eyeButton = null;
      this._modeButtonFor = null;
      document.removeEventListener("etcher:mode-changed", this._onMode);
      document.removeEventListener("pointerdown", this._onClosing, true);
      document.removeEventListener("keydown", this._onClosing, true);
    },

    // What the drawing IS, as far as a burn cares. Compared against the
    // state the last one was made from, so ending a session in which
    // nothing was drawn re-renders nothing.
    _signature() {
      var host = this._host && this._host();
      var layer = host && window.Etcher && window.Etcher.layerFor &&
                  window.Etcher.layerFor(host.id);
      if (!layer || typeof layer.getShapes !== "function") return null;
      try {
        // Sorted by uuid as well: the order shapes come back in is the
        // server's business, not a change to the drawing.
        return (layer.getShapes() || [])
          .map(function(s) {
            return burnCanonical([s.uuid, s.kind, s.geometry, s.style, s.metadata, s.title]);
          })
          .sort()
          .join("");
      } catch (_) {
        return null;
      }
    },

    burnIfChanged() {
      if (!this._uuid) return;
      // A burn re-renders the drawing and stores it: part of an editing
      // session. A viewer that cannot draw — a readonly MediaBrowser embed,
      // or any viewer mounted with `can_annotate: false` — must not write on
      // its way out, and a visitor the endpoint would refuse must not be
      // shown "Could not update the burned image" for merely closing it.
      if (this.el.dataset.canAnnotate !== "true") return;
      var now = this._signature();
      // `null` is "Etcher has not hydrated yet": nothing to compare, and
      // nothing worth rendering from a drawing that is not on screen.
      //
      // An EMPTY board is `""`, which is a different answer to a different
      // question — and a falsy one, so testing truthiness here swallowed
      // it. That is what made rubbing out the last shape the one edit a
      // burn never noticed: the copy on file kept the markup, the card
      // kept showing it, and the fix was to draw something else. The rule
      // below is the one that decides what an empty board means; it could
      // not be reached from here.
      if (now == null) return;

      // Nothing drawn and nothing burned — a picture opened and closed.
      // A picture whose last shape was just rubbed out has a burn on file
      // and does not match this, so it goes on to render the clean one.
      // "A burn on file" is asked of the page too, not only of the
      // fingerprint: a copy whose fingerprint never reached this page is
      // still a copy with the old markup in it.
      if (now === "" && !this._burned && this.el.dataset.hasBurn !== "true") return;

      var fingerprint = burnHash(now);
      // The stored copy was made from exactly this drawing. Re-rendering it
      // would cost a full-resolution compose and an upload to produce the
      // same bytes.
      if (fingerprint === this._burned) return;
      // …and so was the one on the wire. Turning Etcher off ends the
      // session once, but the canvas swap that follows tears the layer
      // down, and a teardown turns the mode off again — a second
      // session-end for the same drawing, arriving before the first
      // upload has answered and while `_burned` still names the old copy.
      // It composed and uploaded the whole picture a second time.
      if (fingerprint === this._inFlight) return;

      var plan = burnCapturePlan(this._host());
      if (!plan) return;
      // How the burn is kept, decided by the server from the stored file:
      //   "png"  — a see-through picture, transparency kept;
      //   "webp" — a photo: small, and a margin the markup opens up past the
      //            picture's edges stays see-through instead of white;
      //   "gif"  — an animation: only the markup is sent, and the server
      //            draws it onto every frame so the burn still plays.
      // Missing (an older page): the JPEG it always was.
      plan.format = this.el.dataset.burnFormat || "jpeg";

      var pending = {
        fingerprint: fingerprint,
        plan: plan,
        version: this.el.dataset.sourceVersion || ""
      };

      // Take the plan NOW. A second session-end while a burn is uploading
      // used to be remembered as a flag and recaptured when the upload
      // finished — by which point closing the viewer had already removed
      // the overlay, so the drawing made in between never landed.
      if (this._running) {
        this._pending = pending;
        return;
      }
      this._start(pending);
    },

    _start(pending) {
      var self = this;
      this._running = true;
      this._pending = null;
      this._inFlight = pending.fingerprint;
      burnNote("Updating the burned image…");

      burnRender(pending.plan)
        .then(function(blob) {
          return burnUpload(self._uuid, blob, self._variants, pending.version,
                            pending.fingerprint, pending.plan);
        })
        .then(function(res) {
          // What the stored copy is now made from. Held only after the
          // store succeeded: a failed burn leaves the old fingerprint, so
          // the next session end knows it is still stale.
          self._burned = pending.fingerprint;
          self._refresh(res.written || []);

          // Tell the viewer a burn was stored, so the burned view it shows
          // next is this one. Without it the canvas keeps the URL it
          // mounted with — the previous rendering, until a page reload.
          // Only the slot is named: the viewer reads the stored instance
          // (URL, size, version) itself rather than trusting these.
          var written = res.written || [];
          var made = written.find(function(v) { return v.variant === "burned_large"; }) ||
                     written.find(function(v) { return v.variant === "burned"; });
          if (made) {
            self.pushEventTo(self.el, "burn_stored", {
              variant: made.variant,
              fingerprint: pending.fingerprint
            });
          }

          burnNote("Burned image updated", 3500);
        })
        .catch(function(err) {
          // The session is over either way; say so, and leave the stored
          // fingerprint alone so the next attempt still knows it is stale.
          burnNote("Could not update the burned image: " + (err && err.message || err), 6000);
        })
        .then(function() {
          self._running = false;
          self._inFlight = null;
          var next = self._pending;
          self._pending = null;
          if (next) self._start(next);
        });
    },

    // Every picture on the page showing a variant this replaced. The
    // viewer's own image is left alone: it still has the live shapes drawn
    // over it, and swapping it for the burned copy would draw them twice.
    _refresh(written) {
      var host = this._host && this._host();
      var uuid = this._uuid;
      written.forEach(function(v) {
        var marker = "/file/" + uuid + "/" + v.variant + "/";
        document.querySelectorAll("img").forEach(function(img) {
          var src = img.getAttribute("src") || "";
          if (src.indexOf(marker) !== -1 && !(host && host.contains(img))) {
            img.setAttribute("src", v.url);
          }
        });
      });
    }
  };

  // EtcherTooltipActions
  //
  // Routes Etcher's `etcher:tooltip-action` CustomEvent (a tooltip button
  // press — the tooltip swallows raw clicks, so Etcher 0.13 re-dispatches
  // them on the layer host, bubbling). Sits on the viewer column that wraps
  // the canvas + layer:
  //   pk-reply → pushEventTo the owning LiveComponent ("annotation_reply"),
  //              which ensures the shape's master comment and opens the
  //              body-only reply popup.
  //   pk-edit  → pure client-side: layer.editLabel(uuid) opens Etcher's
  //              inline label editor, same as double-clicking the shape.
  // ---------------------------------------------------------------------------
  window.PhoenixKitAdminHooks.EtcherTooltipActions = {
    mounted() {
      var self = this;
      this._onTooltipAction = function(e) {
        var d = (e && e.detail) || {};
        if (!d.uuid) return;
        if (d.action === "pk-reply") {
          self.pushEventTo(self.el, "annotation_reply", { uuid: d.uuid });
        } else if (d.action === "pk-edit") {
          var layer = window.Etcher && window.Etcher.layerFor &&
                      window.Etcher.layerFor(d.fresco_id);
          if (layer && typeof layer.editLabel === "function") layer.editLabel(d.uuid);
        } else if (d.action === "pk-view") {
          // Take the user to the shape's thread: the sidebar comment cards
          // carry data-annotation-uuid (CommentsComponent), same document.
          var card = document.querySelector(
            '[data-annotation-uuid="' + d.uuid + '"]'
          );
          if (card) {
            card.scrollIntoView({ behavior: "smooth", block: "center" });
            card.style.transition = "box-shadow 200ms ease";
            card.style.boxShadow = "0 0 0 2px #3b82f6";
            setTimeout(function() { card.style.boxShadow = ""; }, 1600);
          }
        }
      };
      this.el.addEventListener("etcher:tooltip-action", this._onTooltipAction);
    },
    destroyed() {
      if (this._onTooltipAction) {
        this.el.removeEventListener("etcher:tooltip-action", this._onTooltipAction);
      }
    }
  };

  window.PhoenixKitAdminHooks.AnnotationComposerPosition = {
    mounted() {
      this._reposition = () => this.reposition();
      this.reposition();
      window.addEventListener("resize", this._reposition);
    },

    updated() {
      this.reposition();
    },

    destroyed() {
      window.removeEventListener("resize", this._reposition);
    },

    reposition() {
      const el = this.el;
      const container = el.parentElement;
      if (!container) return;

      const margin = 8;
      const popW = el.offsetWidth;
      const popH = el.offsetHeight;
      const cw = container.clientWidth;
      const ch = container.clientHeight;

      // Try to anchor to the associated shape. Element id is
      // `annotation-composer-popover-<uuid>`; Etcher renders shapes
      // with the matching `data-uuid`.
      const uuid = el.id.replace(/^annotation-composer-popover-/, "");
      const shapeEl = uuid
        ? document.querySelector('[data-uuid="' + uuid + '"]')
        : null;

      let left;
      let top;

      if (shapeEl) {
        const shapeRect = shapeEl.getBoundingClientRect();
        const containerRect = container.getBoundingClientRect();

        // Center horizontally on the shape; place bottom-of-popover
        // `margin` px above the shape's top.
        const shapeCenterX = shapeRect.left + shapeRect.width / 2 - containerRect.left;
        const shapeTopY = shapeRect.top - containerRect.top;

        left = shapeCenterX - popW / 2;
        top = shapeTopY - popH - margin;

        // No room above → flip below the shape.
        if (top < margin) {
          top = shapeRect.bottom - containerRect.top + margin;
        }
      } else {
        // Fall back to whatever the server seeded (or zero).
        left = parseFloat(el.style.left) || 0;
        top = parseFloat(el.style.top) || 0;
      }

      // Clamp horizontally: keep right edge inside the container, then
      // keep left edge inside. Order matters when the popover is wider
      // than the container — `Math.max(margin, …)` wins, leaving the
      // popover flush-left with a margin.
      const maxLeft = cw - popW - margin;
      if (left > maxLeft) left = maxLeft;
      if (left < margin) left = margin;

      // Same for vertical. If the popover doesn't fit (popover taller
      // than the container), it pins to the top with a margin.
      const maxTop = ch - popH - margin;
      if (top > maxTop) top = maxTop;
      if (top < margin) top = margin;

      el.style.left = `${left}px`;
      el.style.top = `${top}px`;
    }
  };

  // ---------------------------------------------------------------------------
  // ListFilter Hook
  // ---------------------------------------------------------------------------
  //
  // Client-side filter for a short list — the breadcrumb switcher's
  // (PhoenixKitWeb.Components.Core.CrumbSwitcher), or any list small enough
  // to render whole. No server round trip per keystroke.
  //
  //   <input phx-hook="ListFilter" id="…" data-filter-list="#my-list" />
  //   <ul id="my-list">
  //     <li data-filter-text="Kitchen"><a …>Kitchen</a></li>
  //     <li data-filter-empty class="hidden">No results.</li>
  //   </ul>
  //
  // Case and accents are ignored ("kasitoo" finds "Käsitöö"). Enter opens the
  // first visible match's link, ArrowDown moves into the list, and focusing
  // the input selects its text so a reopened switcher starts a new search.
  // ---------------------------------------------------------------------------

  function listFilterNormalize(s) {
    return String(s == null ? "" : s)
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .trim();
  }

  function listFilterMatches(text, query) {
    var q = listFilterNormalize(query);
    return q === "" || listFilterNormalize(text).indexOf(q) !== -1;
  }

  window.PhoenixKitAdminHooks.ListFilter = {
    mounted() {
      this._onInput = () => this.apply();
      this._onFocus = () => this.el.select();
      this._onKey = (e) => {
        // Enter that confirms an IME composition is not a pick.
        if (e.isComposing || e.keyCode === 229) return;
        var first = this.visibleItems()[0];
        var link = first && first.querySelector("a");
        if (e.key === "Enter") {
          e.preventDefault();
          if (link) link.click();
        } else if (e.key === "ArrowDown" && link) {
          e.preventDefault();
          link.focus();
        }
      };
      this.el.addEventListener("input", this._onInput);
      this.el.addEventListener("focus", this._onFocus);
      this.el.addEventListener("keydown", this._onKey);
      // A server re-render of the list strips the inline styles this hook
      // set (morphdom syncs attributes to the server's markup), showing
      // every row under a query that still reads "kitch" — and Enter would
      // then open the unfiltered first row. Re-filter whenever the list
      // changes; disconnect while filtering so our own writes don't loop.
      this._observer = new MutationObserver(() => this.apply());
      this.observe();
    },
    updated() {
      this.apply();
    },
    destroyed() {
      this.el.removeEventListener("input", this._onInput);
      this.el.removeEventListener("focus", this._onFocus);
      this.el.removeEventListener("keydown", this._onKey);
      if (this._observer) this._observer.disconnect();
    },
    observe() {
      var list = this.list();
      if (list && this._observer) {
        this._observer.observe(list, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ["style", "data-filter-text"]
        });
      }
    },
    list() {
      var sel = this.el.dataset.filterList;
      return sel ? document.querySelector(sel) : null;
    },
    visibleItems() {
      var list = this.list();
      if (!list) return [];
      return Array.prototype.filter.call(
        list.querySelectorAll("[data-filter-text]"),
        function(item) { return item.style.display !== "none"; }
      );
    },
    apply() {
      var list = this.list();
      if (!list) return;
      if (this._observer) this._observer.disconnect();
      var query = this.el.value;
      var shown = 0;
      list.querySelectorAll("[data-filter-text]").forEach(function(item) {
        var match = listFilterMatches(item.dataset.filterText, query);
        var display = match ? "" : "none";
        if (item.style.display !== display) item.style.display = display;
        if (match) shown++;
      });
      var empty = list.querySelector("[data-filter-empty]");
      if (empty) empty.classList.toggle("hidden", shown > 0);
      this.observe();
    }
  };

  // ---------------------------------------------------------------------------
  // TreePickerSearch Hook
  // ---------------------------------------------------------------------------
  //
  // The search box of PhoenixKitWeb.Components.TreePicker. The query goes to
  // the component from here, not through a form's phx-change: the picker
  // often sits inside a host form, whose own phx-change and submit must not
  // see what is typed here. Typing is debounced; Enter searches at once
  // (except while an input method is still composing, where Enter confirms
  // the composition).
  //
  //   <input phx-hook="TreePickerSearch" phx-target={@myself} id="…" />
  // ---------------------------------------------------------------------------

  function treePickerEnter(e) {
    return !!e && e.key === "Enter" && !e.isComposing;
  }

  window.PhoenixKitAdminHooks.TreePickerSearch = {
    mounted() {
      this._onInput = (e) => {
        e.stopPropagation();
        if (!e.isComposing) this.queue();
      };
      this._onChange = (e) => e.stopPropagation();
      this._onKey = (e) => {
        if (treePickerEnter(e)) {
          e.preventDefault();
          e.stopPropagation();
          this.push();
        }
      };
      this._onComposed = () => this.queue();
      this.el.addEventListener("input", this._onInput);
      this.el.addEventListener("change", this._onChange);
      this.el.addEventListener("keydown", this._onKey);
      this.el.addEventListener("compositionend", this._onComposed);
    },
    queue() {
      clearTimeout(this._timer);
      this._timer = setTimeout(() => this.push(), 200);
    },
    push() {
      clearTimeout(this._timer);
      this.pushEventTo(this.el, "search", { value: this.el.value });
    },
    destroyed() {
      clearTimeout(this._timer);
    }
  };

  if (typeof module === "object" && module.exports) {
    module.exports.treePickerEnter = treePickerEnter;
  }

  // ---------------------------------------------------------------------------
  // CrumbSwitcher Hook
  // ---------------------------------------------------------------------------
  //
  // The breadcrumb switcher's open/close bookkeeping
  // (PhoenixKitWeb.Components.Core.CrumbSwitcher). The panel opens and closes
  // through LiveView JS (PopoverPanel) from several places — the ▾, Escape, a
  // click away, picking a row — so this watches the panel rather than each
  // path:
  //   * opened → the search starts empty (a panel reused across a patch
  //     would otherwise keep the last level's query) and takes focus;
  //   * closed → focus returns to the ▾ when it was inside the panel (or
  //     dropped to the page), never when the user has moved on elsewhere;
  //   * the ▾'s aria-expanded follows the panel.
  //   * a picked row closes the panel again once the patch it triggered has
  //     landed. The row's own hide runs through a 200ms transition and the
  //     patch re-renders the header around it; on a page that re-renders a lot
  //     the panel was seen left open over the new library (Media, 2026-10-08).
  // Deliberately not done in PopoverPanel's Escape handler: every panel on a
  // page listens for Escape, so a focus move there would fire for all of them.
  // ---------------------------------------------------------------------------

  window.PhoenixKitAdminHooks.CrumbSwitcher = {
    mounted() {
      this._open = false;
      this._picked = false;
      // Capture-phase on the element: LiveView's own link handler stops the
      // click at the window, after this has run.
      this._onClick = (e) => {
        var target = e.target;
        if (!target || !target.closest || !target.closest("[data-filter-text] a")) return;
        this._picked = true;
        clearTimeout(this._pickedTimer);
        // A pick that changes nothing never reaches updated(); do not let the
        // flag close a panel the user opens later.
        this._pickedTimer = setTimeout(() => { this._picked = false; }, 3000);
      };
      this.el.addEventListener("click", this._onClick, true);
      this._sync = () => this.sync();
      this._observer = new MutationObserver(this._sync);
      this._observer.observe(this.el, {
        attributes: true,
        subtree: true,
        attributeFilter: ["style", "class"]
      });
      this.sync();
    },
    updated() {
      if (this._picked) {
        this._picked = false;
        clearTimeout(this._pickedTimer);
        var panel = document.getElementById(this.el.dataset.panel);
        if (panel) this.js().hide(panel);
      }
      this.sync();
    },
    destroyed() {
      clearTimeout(this._pickedTimer);
      this.el.removeEventListener("click", this._onClick, true);
      if (this._observer) this._observer.disconnect();
    },
    sync() {
      var panel = document.getElementById(this.el.dataset.panel);
      var trigger = this.el.querySelector("[data-switcher-trigger]");
      if (!panel || !trigger) return;
      var open = window.getComputedStyle(panel).display !== "none";
      if (trigger.getAttribute("aria-expanded") !== String(open)) {
        trigger.setAttribute("aria-expanded", String(open));
      }
      if (open && !this._open) this.opened(panel);
      if (!open && this._open) this.closed(panel, trigger);
      this._open = open;
    },
    opened(panel) {
      var input = panel.querySelector("[data-filter-list]");
      if (!input) return;
      input.value = "";
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.focus();
    },
    closed(panel, trigger) {
      var active = document.activeElement;
      if (!active || active === document.body || panel.contains(active)) trigger.focus();
    }
  };

  // Exported for the Node test harness (test/js); harmless in a browser.
  if (typeof module === "object" && module.exports) {
    module.exports.listFilterMatches = listFilterMatches;
  }


  // ============================================================================
  // Section: TableFit - drop the least important columns that do not fit
  // ============================================================================
  //
  // On the scroll wrapper of a `<.table_default fit>`. Header cells carry
  // `data-col-priority`; the hook hides whole columns, by position, through
  // one stylesheet in <head> — so rows that arrive later (streams, patches)
  // are already right without touching a cell, and LiveView has no attribute
  // of ours to strip. It measures the real table against the wrapper rather
  // than trusting declared widths: a badge is as wide as its translation.

  // Pure: header cells -> [{index, head, priority}]. `index` is the 1-based
  // child position the BODY cells of that column have, `head` the position
  // of the header cell itself — they differ once a header cell spans two
  // columns. A spanning header is never a candidate: hiding one position
  // would take half of it.
  function fitColumns(headers) {
    let next = 1;
    return headers.map((h, i) => {
      const span = h.colSpan > 1 ? h.colSpan : 1;
      const col = {
        index: next,
        head: i + 1,
        priority: span > 1 || h.priority === undefined ? NaN : Number(h.priority)
      };
      next += span;
      return col;
    });
  }

  // Pure: the order columns are dropped in. Highest priority number first;
  // among equals the rightmost first. Returns the columns, not positions.
  function fitEvictionOrder(cols) {
    return cols
      .filter((c) => Number.isFinite(c.priority))
      .slice()
      .sort((a, b) => b.priority - a.priority || b.index - a.index);
  }

  // Pure: what the header row looks like, as a string. The remembered
  // stylesheet is positional, so it is only put back on a table whose
  // columns are the ones it was computed for.
  function fitSignature(headers) {
    return headers
      .map((h) => (h.priority === undefined ? "" : h.priority) + (h.colSpan > 1 ? "x" + h.colSpan : ""))
      .join(",");
  }

  // An id is not always a valid CSS identifier (a leading digit — a uuid —
  // a dot, a colon), so it is escaped; the fallback is for node, which has
  // no CSS object.
  function fitEscapeId(id) {
    if (typeof CSS !== "undefined" && CSS && typeof CSS.escape === "function") {
      return CSS.escape(id);
    }
    return String(id).replace(/^(\d)/, "\\3$1 ").replace(/([^\w\s\\-])/g, "\\$1");
  }

  // Pure: the stylesheet hiding the given columns ({index, head}), plus a
  // "+N" on the last visible header cell so dropped columns do not read as missing
  // data. Header and body are addressed apart because their positions can
  // differ; a cell with a colspan (an empty-state row) is left alone.
  function fitHideCss(wrapperId, cols, headerCount) {
    if (cols.length === 0) return "";
    const id = fitEscapeId(wrapperId);
    const table = `#${id} > table`;
    const sel = cols
      .flatMap((c) => [
        `${table} > thead > tr > :nth-child(${c.head})`,
        `${table} > :not(thead) > tr > :nth-child(${c.index}):not([colspan])`
      ])
      .join(",\n");
    let badgeHead = headerCount;
    while (badgeHead > 0 && cols.some((c) => c.head === badgeHead)) badgeHead--;
    const more = badgeHead > 0 ?
      `${table} > thead > tr > :nth-child(${badgeHead})::before { content: "+${cols.length}"; ` +
      "margin-inline-end: 0.25rem; font-size: 0.6875rem; font-weight: 600; opacity: 0.6; white-space: nowrap; }" : "";
    return `@media screen {\n${sel} { display: none; }\n${more}\n}`;
  }

  window.PhoenixKitAdminHooks.TableFit = {
    mounted() {
      // A table removed without destroyed() running leaves its stylesheet
      // behind, still hiding positions of whatever takes its id next; and
      // the component's inline script may have restored one for first paint.
      document.head
        .querySelectorAll("style[data-pk-table-fit]")
        .forEach((el) => {
          if (el.getAttribute("data-pk-table-fit") === this.el.id) el.remove();
        });
      this.styleEl = document.createElement("style");
      this.styleEl.setAttribute("data-pk-table-fit", this.el.id);
      document.head.appendChild(this.styleEl);
      this.lastWidth = -1;
      if (typeof ResizeObserver === "function") {
        this.observer = new ResizeObserver(() => {
          // Only a width change can alter what fits; a row arriving (height)
          // comes through updated().
          const w = this.el.clientWidth;
          if (w === this.lastWidth) return;
          this.fit();
        });
        this.observer.observe(this.el);
      }
      this.fit();
    },
    updated() {
      this.fit();
    },
    destroyed() {
      if (this.observer) this.observer.disconnect();
      if (this.styleEl) this.styleEl.remove();
    },
    headers() {
      const row = this.el.querySelector(":scope > table > thead > tr");
      if (!row) return [];
      return Array.from(row.children).map((th) => ({
        colSpan: th.colSpan,
        priority: th.dataset.colPriority
      }));
    },
    fit() {
      const table = this.el.querySelector(":scope > table");
      const width = this.el.clientWidth;
      // Not laid out (the card view is showing, a hidden tab): keep what we
      // had; the observer fires again when the wrapper gets a width.
      if (!table || width === 0) return;
      this.lastWidth = width;
      const headers = this.headers();
      const order = fitEvictionOrder(fitColumns(headers));
      const hidden = [];
      // All in one task: show everything, then drop columns until the table
      // stops overflowing. The browser paints only the final state.
      this.styleEl.textContent = "";
      while (table.scrollWidth > this.el.clientWidth && hidden.length < order.length) {
        hidden.push(order[hidden.length]);
        this.styleEl.textContent = fitHideCss(this.el.id, hidden, headers.length);
      }
      // For the next hard load: the component's inline script puts this back
      // before first paint, so the table does not flash its full width. Kept
      // with the header's signature — the stylesheet is positional, and the
      // same id can show other columns on another page.
      try {
        const key = "phoenix_kit:table-fit:" + this.el.id;
        if (hidden.length > 0) {
          localStorage.setItem(
            key,
            JSON.stringify({ sig: fitSignature(headers), css: this.styleEl.textContent })
          );
        } else {
          localStorage.removeItem(key);
        }
      } catch (_e) {}
    }
  };

  if (typeof module === "object" && module.exports) {
    module.exports.fitEvictionOrder = fitEvictionOrder;
    module.exports.fitHideCss = fitHideCss;
    module.exports.fitColumns = fitColumns;
    module.exports.fitEscapeId = fitEscapeId;
    module.exports.fitSignature = fitSignature;
  }

  // ============================================================================
  // Section: TableCardView - Card/Table view toggle
  // ============================================================================
  window.PhoenixKitAdminHooks.TableCardView = {
    mounted() {
      var key = this.el.dataset.storageKey || (this.el.id + "-view");
      // "comfy" (comfortable rows — the table with more space per row and
      // larger thumbs, via the `pk-comfy` marker class) is the default; the
      // dense table and the card grid are the explicit alternatives.
      var saved = localStorage.getItem(key) || "comfy";
      this.storageKey = key;
      this.currentMode = saved;
      this.applyMode(saved);

      var self = this;
      this.el.querySelectorAll("[data-view-action]").forEach(function(btn) {
        btn.addEventListener("click", function() {
          var mode = btn.dataset.viewAction;
          localStorage.setItem(self.storageKey, mode);
          self.currentMode = mode;
          self.applyMode(mode);
          // Notify other TableCardView instances sharing the same key
          window.dispatchEvent(new CustomEvent("phx:table-view-change", {
            detail: { key: self.storageKey, mode: mode }
          }));
        });
      });

      // Listen for view changes from other instances with the same key
      this._onViewChange = function(e) {
        if (e.detail.key === self.storageKey) {
          self.currentMode = e.detail.mode;
          self.applyMode(e.detail.mode);
        }
      };
      window.addEventListener("phx:table-view-change", this._onViewChange);
    },

    updated() {
      // The LV re-render may have reset the inner divs' class attrs back
      // to their template defaults (e.g. tableEl class="hidden md:block",
      // cardEl class="md:hidden ..."). Re-apply the user's chosen mode so
      // a SortableJS drop or any other LV-driven update doesn't snap the
      // view back to the default.
      if (this.currentMode) {
        this.applyMode(this.currentMode);
      }
    },

    destroyed() {
      if (this._onViewChange) {
        window.removeEventListener("phx:table-view-change", this._onViewChange);
      }
    },

    applyMode(mode) {
      var tableEl = this.el.querySelector("[data-table-view]");
      var cardEl  = this.el.querySelector("[data-card-view]");
      var btns    = this.el.querySelectorAll("[data-view-action]");

      if (!tableEl || !cardEl) return;

      if (mode === "card") {
        tableEl.classList.add("md:hidden");
        tableEl.classList.remove("md:block");
        cardEl.classList.remove("md:hidden");
      } else {
        // "table" (compact) and "comfy" (comfortable) both show the table
        // branch; comfy additionally marks it so `[.pk-comfy_&]` utilities
        // in the table markup can widen paddings and thumbnails.
        tableEl.classList.remove("md:hidden");
        tableEl.classList.add("md:block");
        cardEl.classList.add("md:hidden");
      }
      tableEl.classList.toggle("pk-comfy", mode === "comfy");

      btns.forEach(function(b) {
        b.classList.toggle("btn-active", b.dataset.viewAction === mode);
      });
    }
  };


  // ============================================================================
  // 5. ROW MENU HOOK
  // ============================================================================
  //
  // Positions table row action dropdown menus using position: fixed to escape
  // the overflow-x-auto overflow-y-clip table container — a common DaisyUI
  // issue where dropdowns nested inside tables get clipped.
  //
  // The menu opens below the trigger by default, flips above if out of space,
  // and aligns to the right edge (shifting left if that would clip off-screen).
  // Closes on outside click, Escape key, and LiveView navigation.
  //
  // Usage in HEEX (via table_row_menu component):
  //   <.table_row_menu id={"row-menu-\#{item.uuid}"}>
  //     <.table_row_menu_link navigate={...} icon="hero-eye" label="View" />
  //     <.table_row_menu_button phx-click="delete" icon="hero-trash" label="Delete" variant="error" />
  //   </.table_row_menu>
  //
  // RIGHT-CLICK: an element flagged `data-row-menu-context` opens the row
  // menu rendered INSIDE it at the pointer (see `rowMenuFor` for why it is a
  // flag, not the menu's id). Not Core.ContextMenu, deliberately —
  // its one menu element serves every row, so it stamps `phx-value-*` and
  // cannot carry a per-row `navigate=`. This component already renders one
  // menu per row, so the items are per-row and correct as they stand; all
  // that is missing is a second way to open them.
  //
  // Where a menu of w x h opens for a pointer at (x, y). Down-right of the
  // pointer, flipping to the other side of it rather than overflowing, then
  // clamping for a menu too big to fit either way. Published on `window`
  // because Core.ContextMenu lives in a separate IIFE in this bundle and
  // needs the identical rule — two copies of it would drift.
  var MENU_POINTER_PAD = 8;

  function pointerMenuPosition(x, y, w, h, vw, vh) {
    var left = x;
    if (left + w > vw - MENU_POINTER_PAD) left = x - w;
    left = Math.max(MENU_POINTER_PAD, Math.min(left, vw - w - MENU_POINTER_PAD));

    var top = y;
    if (top + h > vh - MENU_POINTER_PAD) top = y - h;
    top = Math.max(MENU_POINTER_PAD, Math.min(top, vh - h - MENU_POINTER_PAD));

    return { left: left, top: top };
  }

  window.PhoenixKitMenus = window.PhoenixKitMenus || {};
  window.PhoenixKitMenus.pointerPosition = pointerMenuPosition;

  // One document listener serves every row menu on the page, so a table of a
  // hundred rows adds one listener, not a hundred.
  var openRowMenu = null;
  var rowMenuListening = false;

  // Android fires `contextmenu` for a long press, and the RELEASE then
  // dispatches a click on whatever the finger was on — the row's link, or
  // the ⋮ trigger, which would toggle the just-opened menu shut. Eat that one
  // click, exactly as Core.ContextMenu does after its own long press. Only
  // after a touch/pen gesture: a mouse right-click is followed by no click.
  var ROW_SWALLOW_CLICK_MS = 700;
  var swallowRowClick = false;
  var swallowRowClickTimer = null;
  var lastPointerType = "mouse";
  var lastPointerDownAt = 0;

  function onRowPointerDown(e) {
    lastPointerType = e.pointerType || "mouse";
    lastPointerDownAt = Date.now();
  }

  function armRowClickSwallow() {
    swallowRowClick = true;
    // Backstop for a release that dispatches no click at all, which would
    // otherwise eat the user's next tap — the menu item they came for.
    if (swallowRowClickTimer) clearTimeout(swallowRowClickTimer);
    swallowRowClickTimer = setTimeout(function () {
      swallowRowClickTimer = null;
      swallowRowClick = false;
    }, ROW_SWALLOW_CLICK_MS);
  }

  // Capture phase on `document`, installed before any menu's own
  // outside-click listener, so it runs first — and stops the others too:
  // the release lands OUTSIDE the menu, and the outside-click listener would
  // close it again the instant it opened.
  function onRowDocClick(e) {
    if (!swallowRowClick) return;
    swallowRowClick = false;
    if (swallowRowClickTimer) {
      clearTimeout(swallowRowClickTimer);
      swallowRowClickTimer = null;
    }
    e.preventDefault();
    e.stopImmediatePropagation();
  }

  // Text selected inside the row is a request to copy it. Whole-row
  // right-click is the owner's call; a selection is the one case where the
  // browser's menu is plainly what was wanted.
  function selectionInside(row) {
    var sel = window.getSelection && window.getSelection();
    if (!sel || sel.isCollapsed || String(sel).trim() === "") return false;
    return row.contains(sel.anchorNode) || row.contains(sel.focusNode);
  }

  // `data-row-menu-context` is a FLAG on the row, not the menu's id: the row
  // element is usually rendered by a shared table component that never sees
  // the id its caller built for the menu in the actions slot. So the row says
  // "right-click me" and the menu is found inside it.
  //
  // The hook itself is reached through a PROPERTY on the wrapper, never an
  // attribute — LiveView's patcher strips attributes the server did not
  // render.
  function rowMenuFor(target) {
    if (!target || !target.closest) return null;
    // A field keeps the browser's menu: right-clicking the inline rename box
    // is a request to paste, and taking that away for a row menu the user
    // can still reach one pixel over would be a straight loss.
    if (target.closest("input, textarea, select, [contenteditable]:not([contenteditable=false])")) {
      return null;
    }
    var row = target.closest("[data-row-menu-context]");
    if (!row) return null;
    if (selectionInside(row)) return null;

    // This row's OWN menu. `closest` above already picked the innermost row,
    // so a wrapper that belongs to a nested row is that row's business.
    var wrappers = row.querySelectorAll("[data-row-menu-wrapper]");
    for (var i = 0; i < wrappers.length; i++) {
      if (wrappers[i].closest("[data-row-menu-context]") === row) {
        return wrappers[i]._pkRowMenu || null;
      }
    }
    return null;
  }

  function onRowContextMenu(e) {
    var hook = rowMenuFor(e.target);

    // No row here, or its menu is not rendered in this view mode: leave the
    // browser's own menu alone. Suppressing it everywhere would cost the user
    // Copy/Inspect on a page that has nothing to offer in its place. Close
    // ours first so it does not sit under the browser's — unless the
    // right-click is ON our menu, where a link item's native "Open in new
    // tab" is exactly what the user is after.
    if (!hook) {
      if (openRowMenu && !openRowMenu.menu.contains(e.target)) openRowMenu._close();
      return;
    }

    e.preventDefault();
    if (openRowMenu && openRowMenu !== hook) openRowMenu._close();

    // Only a gesture that began with a finger or pen within the last couple
    // of seconds — a long press is well under that — arms the swallow. A
    // keyboard Menu key sends no pointerdown and must not inherit a stale one.
    if (lastPointerType !== "mouse" && Date.now() - lastPointerDownAt < 2000) {
      armRowClickSwallow();
    }

    // The Menu key and Shift+F10 report the pointer at 0,0. Anchor to the ⋮
    // trigger then, rather than to the viewport's corner.
    var fromKeyboard = e.clientX === 0 && e.clientY === 0;
    hook._open(fromKeyboard ? undefined : { x: e.clientX, y: e.clientY });
  }

  function ensureRowMenuListener() {
    if (rowMenuListening) return;
    document.addEventListener("contextmenu", onRowContextMenu);
    // Registered here, before any menu opens, so it precedes every menu's own
    // capture-phase outside-click listener.
    document.addEventListener("click", onRowDocClick, true);
    document.addEventListener("pointerdown", onRowPointerDown, { capture: true, passive: true });
    rowMenuListening = true;
  }

  window.PhoenixKitAdminHooks.RowMenu = {
    mounted() {
      this.trigger = this.el.querySelector("[data-row-menu-trigger]");
      this.menu = this.el.querySelector("[data-row-menu-content]");
      this.isOpen = false;
      // Track where the menu element originally lives so we can restore
      // it on close. We portal it to <body> while open so `position: fixed`
      // coords escape any containing block created by a `<dialog>` in the
      // top layer or any ancestor with `transform`/`contain`/`filter` (all
      // of which establish a new fixed-positioning origin). Without the
      // portal, `getBoundingClientRect()` returns viewport coords but the
      // browser applies them relative to the nearest containing block,
      // shoving the menu hundreds of pixels off-screen inside modals.
      this._homeParent = this.menu.parentNode;
      this._homeNextSibling = this.menu.nextSibling;

      // Inside a popup shown with showModal() the portal must NOT be <body>:
      // the dialog is in the top layer, which paints over everything outside
      // it, and a modal dialog makes everything outside it inert — a menu on
      // <body> is hidden behind the popup and takes no click. The portal is
      // then the open <dialog> itself (a descendant is not inert, and the
      // dialog element — unlike its transformed box — is a plain fixed
      // origin); and where the Popover API exists the menu is a manual
      // popover as well, so the top layer paints it over the dialog's own
      // content. Measured in Chrome, 2026-10-05.
      this.popover = typeof this.menu.showPopover === "function";

      // The <ul> is server-rendered without `popover`, so a patch of the row
      // while the menu is closed strips what this sets (the patcher removes
      // attributes the server did not render) — and showPopover() on an
      // element with no `popover` attribute throws. Applied again on every
      // open, so it cannot go stale.
      this._armPopover = () => {
        if (!this.popover) return;
        if (this.menu.getAttribute("popover") !== "manual") {
          this.menu.setAttribute("popover", "manual");
        }
        // The UA sheet centres a popover and gives it a border, padding and
        // colours of its own; `inset: auto` + `margin: 0` leave only ours.
        this.menu.style.inset = "auto";
        this.menu.style.margin = "0";
      };
      this._armPopover();

      // A patch strips the dialog's `open` attribute until PkDialog puts it
      // back, while the dialog is still modal — `:modal` is the truer test.
      this._portal = () => {
        var dialog = this.el.closest ? this.el.closest("dialog") : null;
        var shown = dialog && (dialog.open || (dialog.matches && dialog.matches(":modal")));
        return shown ? dialog : document.body;
      };

      this._onTriggerClick = (e) => {
        e.stopPropagation();
        this.isOpen ? this._close() : this._open();
      };

      // Checked against both `this.el` and `this.menu` — while open, the menu
      // is portaled to <body> (see `_open()`), so it's no longer a descendant
      // of `this.el`. Without the `this.menu.contains` check, tapping a menu
      // item is treated as an "outside" click: this capture-phase listener
      // fires before the item's own click handler, closes the menu, and
      // moves it back out from under <body> mid-dispatch. WebKit (desktop and
      // iPadOS Safari — the only engine on iOS/iPadOS) drops the in-flight
      // click when its target is relocated during capture, so the item's
      // action (navigate/phx-click) never runs even though other engines
      // tolerate the move and still deliver it.
      this._onOutsideClick = (e) => {
        if (!this.el.contains(e.target) && !this.menu.contains(e.target)) this._close();
      };

      this._onKeydown = (e) => {
        if (e.key === "Escape") {
          this._close();
          this.trigger.focus();
        }
        // Arrow key navigation inside menu
        if (e.key === "ArrowDown" || e.key === "ArrowUp") {
          e.preventDefault();
          var items = Array.from(this.menu.querySelectorAll("[role='menuitem']:not([disabled])"));
          if (items.length === 0) return;
          var idx = items.indexOf(document.activeElement);
          var next = e.key === "ArrowDown"
            ? (idx + 1) % items.length
            : (idx - 1 + items.length) % items.length;
          items[next].focus();
        }
      };

      // Close when any item is clicked
      this._onMenuClick = () => { this._close(); };

      // A fixed menu does not follow the page. Scrolled, it would sit over a
      // DIFFERENT row while still acting on its own — so it closes, as
      // Core.ContextMenu's does.
      this._onScrollClose = (e) => {
        if (e && e.target && e.target !== document && this.menu.contains(e.target)) return;
        this._close();
      };

      this.trigger.addEventListener("click", this._onTriggerClick);
      this.menu.addEventListener("click", this._onMenuClick);

      // How a right-click on the row finds this hook. A property, not an
      // attribute — see `rowMenuFor`.
      this.el._pkRowMenu = this;
      ensureRowMenuListener();
    },

    updated() {
      // While open, the menu is portaled to <body>; a server diff to this
      // row makes morphdom re-create a duplicate inside the wrapper. That
      // duplicate is the CURRENT truth — an action may have gone ("Retry"
      // once an extraction succeeds) — so its items move into the menu the
      // user is looking at before it is dropped. Keeping the pre-patch items
      // would let a click fire an action the server no longer offers.
      if (this.isOpen) {
        var dup = this.el.querySelector("[data-row-menu-content]");
        if (dup && dup !== this.menu) {
          // The swap detaches the focused item, dropping focus to <body>
          // mid-navigation; put it back on the item in the same slot.
          var sel = "[role='menuitem']";
          var idx = Array.from(this.menu.querySelectorAll(sel)).indexOf(document.activeElement);
          var fresh = Array.prototype.slice.call(dup.childNodes);
          this.menu.replaceChildren.apply(this.menu, fresh);
          dup.remove();
          if (idx >= 0) {
            var items = this.menu.querySelectorAll(sel);
            var again = items[Math.min(idx, items.length - 1)];
            if (again) again.focus({ preventScroll: true });
          }
        }
      }
      // A patch that covers the dialog the menu was portaled into finds its
      // keyed <ul> and moves it back into the row — hidden again, without the
      // popover attribute and positioning. It is the same node (`dup` above is
      // not), so nothing was swapped; but the menu the user opened is gone
      // while `isOpen` still says it is there, and the next trigger click
      // would close what is not showing. Put it back where it was.
      if (this.isOpen && this._reclaimed()) this._present(this._at);
      // morphdom can hand the wrapper back as a fresh node; re-publish.
      this.el._pkRowMenu = this;
    },

    // True when an open menu is no longer showing: put back under the server's
    // `hidden` class, or (with the Popover API) no longer in the top layer.
    _reclaimed() {
      if (this.menu.classList.contains("hidden")) return true;
      return !!(this.popover && !this.menu.matches(":popover-open"));
    },

    // Portal, show and place the menu — the part of opening that a patch can
    // undo. `at` is `{x, y}` for a right-click, absent for the ⋮ trigger.
    _present(at) {
      // Portal to <body> before measuring. If the menu sits inside a
      // <dialog> or any ancestor that establishes a fixed-positioning
      // containing block, `position: fixed` coords would be interpreted
      // relative to that ancestor instead of the viewport. Moving the
      // menu to <body> makes `getBoundingClientRect()` and the resulting
      // `left`/`top` values consistent.
      var portal = this._portal();
      if (this.menu.parentNode !== portal) {
        portal.appendChild(this.menu);
      }

      var triggerRect = this.trigger.getBoundingClientRect();
      var vw = window.innerWidth;
      var vh = window.innerHeight;
      var gap = 4;

      // Show briefly to measure dimensions
      this.menu.classList.remove("hidden");
      this._armPopover();
      if (this.popover && !this.menu.matches(":popover-open")) this.menu.showPopover();
      var menuWidth = this.menu.offsetWidth || 160;
      var menuHeight = this.menu.offsetHeight || 200;

      var left;
      var top;

      if (at) {
        // Right-click: the pointer is the anchor, not the ⋮ button — which on
        // a wide table sits far to the right of where the user clicked.
        var pos = pointerMenuPosition(at.x, at.y, menuWidth, menuHeight, vw, vh);
        left = pos.left;
        top = pos.top;
      } else {
        // Horizontal: align right edge of menu with right edge of trigger
        left = triggerRect.right - menuWidth;
        if (left < 8) left = triggerRect.left;
        left = Math.max(8, Math.min(left, vw - menuWidth - 8));

        // Vertical: prefer below, flip above if not enough space
        top = triggerRect.bottom + gap;
        if (top + menuHeight > vh - 8 && triggerRect.top - menuHeight - gap > 8) {
          top = triggerRect.top - menuHeight - gap;
        }
        top = Math.max(8, Math.min(top, vh - menuHeight - 8));
      }

      this.menu.style.top = top + "px";
      this.menu.style.left = left + "px";
    },

    // `at` is `{x, y}` for a right-click, absent for the ⋮ trigger.
    _open(at) {
      this._at = at;
      this._present(at);

      this.isOpen = true;
      openRowMenu = this;
      this.trigger.setAttribute("aria-expanded", "true");

      document.addEventListener("click", this._onOutsideClick, true);
      document.addEventListener("keydown", this._onKeydown);
      document.addEventListener("scroll", this._onScrollClose, true);
      window.addEventListener("resize", this._onScrollClose);

      // Focus first item for keyboard navigation. `preventScroll`: a focus
      // that scrolled the page would fire the scroll-close just registered.
      var first = this.menu.querySelector("[role='menuitem']");
      if (first) first.focus({ preventScroll: true });
    },

    _close() {
      if (!this.isOpen) return;
      if (this.popover && this.menu.matches(":popover-open")) this.menu.hidePopover();
      this.menu.classList.add("hidden");
      this.isOpen = false;
      if (openRowMenu === this) openRowMenu = null;
      this.trigger.setAttribute("aria-expanded", "false");
      document.removeEventListener("click", this._onOutsideClick, true);
      document.removeEventListener("keydown", this._onKeydown);
      document.removeEventListener("scroll", this._onScrollClose, true);
      window.removeEventListener("resize", this._onScrollClose);

      // Restore the menu to its original location so LiveView's diff
      // patching can find it on subsequent updates. Without this the
      // menu would stay parented to <body> and LV's morphdom pass would
      // see a "missing" element inside the row and re-create it,
      // doubling the DOM and breaking the next open.
      if (this._homeParent && this.menu.parentNode !== this._homeParent) {
        if (this._homeNextSibling && this._homeNextSibling.parentNode === this._homeParent) {
          this._homeParent.insertBefore(this.menu, this._homeNextSibling);
        } else {
          this._homeParent.appendChild(this.menu);
        }
      }
    },

    destroyed() {
      this._close();
      this.trigger.removeEventListener("click", this._onTriggerClick);
      this.menu.removeEventListener("click", this._onMenuClick);
      // A row patched away mid-selection leaves its wrapper behind in some
      // paths; drop the back-reference so a stale hook is never reopened.
      if (this.el._pkRowMenu === this) this.el._pkRowMenu = null;
    }
  };


  // ============================================================================
  // 5b. ROW MENU AUTO HOOK
  // ============================================================================
  //
  // Smart auto-collapsing row menu: shows inline buttons when they fit in the
  // available space, collapses into a ⋮ dropdown when they overflow.
  // Uses ResizeObserver for dynamic detection — no fixed breakpoints.
  //
  window.PhoenixKitAdminHooks.RowMenuAuto = {
    mounted() {
      this.inlineEl = this.el.querySelector("[data-row-menu-inline]");
      this.dropdownEl = this.el.querySelector("[data-row-menu-dropdown]");
      this.trigger = this.el.querySelector("[data-row-menu-trigger]");
      this.menu = this.el.querySelector("[data-row-menu-content]");
      this.isOpen = false;

      if (!this.inlineEl || !this.dropdownEl) return;

      // Start with both hidden
      this.inlineEl.classList.add("hidden");
      this.dropdownEl.classList.add("hidden");

      // Set up dropdown click handlers
      this._onTriggerClick = (e) => {
        e.stopPropagation();
        this.isOpen ? this._closeMenu() : this._openMenu();
      };
      this._onOutsideClick = (e) => {
        if (!this.el.contains(e.target)) this._closeMenu();
      };
      this._onKeydown = (e) => {
        if (e.key === "Escape") {
          this._closeMenu();
          if (this.trigger) this.trigger.focus();
        }
      };
      this._onMenuClick = () => { this._closeMenu(); };

      if (this.trigger) this.trigger.addEventListener("click", this._onTriggerClick);
      if (this.menu) this.menu.addEventListener("click", this._onMenuClick);

      // Listen to window resize
      this._onResize = () => this._check();
      window.addEventListener("resize", this._onResize);

      // Initial check
      this._check();
    },

    updated() {
      this._check();
    },

    _check() {
      if (!this.inlineEl || !this.dropdownEl) return;

      var table = this.el.closest("table");
      var scrollContainer = table ? table.parentElement : null;
      if (!table || !scrollContainer) {
        // Not in a table — show dropdown as fallback
        this.inlineEl.classList.add("hidden");
        this.dropdownEl.classList.remove("hidden");
        return;
      }

      // Step 1: show inline, hide dropdown
      this.inlineEl.classList.remove("hidden");
      this.dropdownEl.classList.add("hidden");

      // Step 2: check if showing inline causes the table to overflow
      if (table.scrollWidth > scrollContainer.clientWidth) {
        // Overflows — switch to dropdown
        this.inlineEl.classList.add("hidden");
        this.dropdownEl.classList.remove("hidden");
      }
      // else: fits, keep inline showing
    },

    _openMenu() {
      if (!this.menu || !this.trigger) return;

      var triggerRect = this.trigger.getBoundingClientRect();
      var vw = window.innerWidth;
      var vh = window.innerHeight;
      var gap = 4;

      this.menu.classList.remove("hidden");
      var menuWidth = this.menu.offsetWidth || 160;
      var menuHeight = this.menu.offsetHeight || 200;

      var left = triggerRect.right - menuWidth;
      if (left < 8) left = triggerRect.left;
      left = Math.max(8, Math.min(left, vw - menuWidth - 8));

      var top = triggerRect.bottom + gap;
      if (top + menuHeight > vh - 8 && triggerRect.top - menuHeight - gap > 8) {
        top = triggerRect.top - menuHeight - gap;
      }
      top = Math.max(8, Math.min(top, vh - menuHeight - 8));

      this.menu.style.top = top + "px";
      this.menu.style.left = left + "px";

      this.isOpen = true;
      this.trigger.setAttribute("aria-expanded", "true");

      document.addEventListener("click", this._onOutsideClick, true);
      document.addEventListener("keydown", this._onKeydown);
    },

    _closeMenu() {
      if (!this.isOpen || !this.menu) return;
      this.menu.classList.add("hidden");
      this.isOpen = false;
      if (this.trigger) this.trigger.setAttribute("aria-expanded", "false");
      document.removeEventListener("click", this._onOutsideClick, true);
      document.removeEventListener("keydown", this._onKeydown);
    },

    destroyed() {
      this._closeMenu();
      if (this._onResize) window.removeEventListener("resize", this._onResize);
      if (this.trigger) this.trigger.removeEventListener("click", this._onTriggerClick);
      if (this.menu) this.menu.removeEventListener("click", this._onMenuClick);
    }
  };


  // ============================================================================
  // 6. EMAIL CHARTS HOOK
  // ============================================================================
  //
  // Initializes Chart.js delivery trend and engagement charts on the email
  // metrics dashboard. Loads Chart.js dynamically so charts work on LiveView
  // navigation (inline <script> tags are not executed on DOM patching).
  //
  // Usage in template:
  //   <div id="email-charts-container" phx-hook="EmailCharts">
  //     <div id="delivery-chart-container" data-chart-data={...}>
  //       <canvas id="delivery-trend-chart" phx-update="ignore"></canvas>
  //     </div>
  //     <div id="engagement-chart-container" data-chart-data={...}>
  //       <canvas id="engagement-chart" phx-update="ignore"></canvas>
  //     </div>
  //   </div>
  //
  window.PhoenixKitAdminHooks.EmailCharts = {
    mounted() {
      var self = this;
      this.deliveryChart = null;
      this.engagementChart = null;
      this._gone = false;
      // Registered now, not after the library arrives: a push that lands
      // while Chart.js loads finds no chart yet and does nothing, and the
      // first draw reads the page's data as it is by then.
      this.handleEvent("email-charts-update", function(data) {
        if (data.charts) { this._updateCharts(data.charts); }
      }.bind(this));
      loadChartJs().then(function() {
        if (!self._gone) { self._initCharts(); }
      }, function() {
        // Already reported by the loader (console + admin notice).
        if (!self._gone) { self._showUnavailable(); }
      });
    },

    updated() {
      if (this.deliveryChart && this.engagementChart) {
        this._readAndUpdateCharts();
      }
    },

    destroyed() {
      this._gone = true;
      if (this.deliveryChart) { this.deliveryChart.destroy(); this.deliveryChart = null; }
      if (this.engagementChart) { this.engagementChart.destroy(); this.engagementChart = null; }
    },

    _initCharts() {
      if (typeof Chart === "undefined") { this._showUnavailable(); return; }
      var deliveryContainer = document.getElementById("delivery-chart-container");
      var deliveryCanvas = document.getElementById("delivery-trend-chart");
      var engagementContainer = document.getElementById("engagement-chart-container");
      var engagementCanvas = document.getElementById("engagement-chart");

      if (!deliveryCanvas || !engagementCanvas) { return; }

      if (this.deliveryChart) { this.deliveryChart.destroy(); }
      if (this.engagementChart) { this.engagementChart.destroy(); }

      var deliveryData = this._parseData(deliveryContainer);
      var hasDeliveryData = deliveryData.labels && deliveryData.labels.length > 0;

      this.deliveryChart = new Chart(deliveryCanvas, {
        type: "line",
        data: hasDeliveryData ? deliveryData : {
          labels: [],
          datasets: [
            { label: "Delivered", data: [], borderColor: "rgb(34,197,94)", backgroundColor: "rgba(34,197,94,0.1)", tension: 0.1, fill: true },
            { label: "Bounced", data: [], borderColor: "rgb(239,68,68)", backgroundColor: "rgba(239,68,68,0.1)", tension: 0.1, fill: true }
          ]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          scales: {
            y: { beginAtZero: true, grid: { color: "rgba(0,0,0,0.1)" } },
            x: { grid: { color: "rgba(0,0,0,0.1)" } }
          },
          plugins: {
            legend: { position: "top" },
            tooltip: { mode: "index", intersect: false }
          }
        }
      });

      var engagementData = this._parseData(engagementContainer);
      var hasEngagementData = engagementData.labels && engagementData.labels.length > 0;

      this.engagementChart = new Chart(engagementCanvas, {
        type: "doughnut",
        data: hasEngagementData ? engagementData : {
          labels: ["Opens", "Clicks", "Bounces", "Complaints"],
          datasets: [{ data: [0, 0, 0, 0], backgroundColor: ["rgb(59,130,246)", "rgb(34,197,94)", "rgb(251,191,36)", "rgb(239,68,68)"] }]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: {
            legend: { position: "bottom" },
            tooltip: {
              callbacks: {
                label: function(context) {
                  var total = context.dataset.data.reduce(function(a, b) { return a + b; }, 0);
                  var pct = total > 0 ? ((context.parsed / total) * 100).toFixed(1) : 0;
                  return (context.label || "") + ": " + context.parsed + " (" + pct + "%)";
                }
              }
            }
          }
        }
      });
    },

    _parseData(container) {
      if (!container) { return {}; }
      try {
        var raw = container.getAttribute("data-chart-data");
        return raw ? JSON.parse(raw) : {};
      } catch(e) { return {}; }
    },

    _updateCharts(chartsData) {
      if (this.deliveryChart && chartsData.delivery_trend) {
        this.deliveryChart.data = chartsData.delivery_trend;
        this.deliveryChart.update();
      }
      if (this.engagementChart && chartsData.engagement) {
        this.engagementChart.data = chartsData.engagement;
        this.engagementChart.update();
      }
    },

    _readAndUpdateCharts() {
      var deliveryContainer = document.getElementById("delivery-chart-container");
      var engagementContainer = document.getElementById("engagement-chart-container");
      var deliveryData = this._parseData(deliveryContainer);
      var engagementData = this._parseData(engagementContainer);
      if (this.deliveryChart && deliveryData.labels) {
        this.deliveryChart.data = deliveryData;
        this.deliveryChart.update();
      }
      if (this.engagementChart && engagementData.labels) {
        this.engagementChart.data = engagementData;
        this.engagementChart.update();
      }
    },

    _showUnavailable() {
      ["delivery-chart-container", "engagement-chart-container"].forEach(function(id) {
        var container = document.getElementById(id);
        if (!container) { return; }
        var wrapper = document.createElement("div");
        wrapper.className = "flex items-center justify-center h-full text-base-content/40 text-sm gap-1";
        var text = document.createTextNode("Charts unavailable: Chart.js could not be loaded. Run ");
        var code = document.createElement("code");
        code.className = "font-mono mx-1";
        code.textContent = "mix phoenix_kit.update";
        var text2 = document.createTextNode(" and check the browser console");
        wrapper.appendChild(text);
        wrapper.appendChild(code);
        wrapper.appendChild(text2);
        container.textContent = "";
        container.appendChild(wrapper);
      });
    }
  };


  // ============================================================================
  // INTEGRATION PICKER SEARCH HOOK
  // ============================================================================

  window.PhoenixKitAdminHooks.IntegrationPickerSearch = {
    mounted() {
      this.el.addEventListener("input", function(e) {
        var query = e.target.value.toLowerCase();
        var pickerId = e.target.dataset.pickerId;
        var picker = document.getElementById(pickerId);
        if (!picker) return;

        var cards = picker.querySelectorAll("button[data-search-text]");
        cards.forEach(function(card) {
          var text = card.getAttribute("data-search-text") || "";
          card.style.display = (query === "" || text.indexOf(query) !== -1) ? "" : "none";
        });
      });
    }
  };

  // ============================================================================
  // MEDIA DRAG & DROP HOOK
  // ============================================================================

  // Box select on the media browser: a press on empty space in the content
  // column (`[data-box-area]`) and a drag draws a box; every card it touches
  // is outlined as it goes, and on release becomes the selection
  // (`box_select`, which turns select mode on). Shift or Cmd/Ctrl adds to the
  // selection instead of replacing it. A press on a card is still that card's
  // own drag; a touch screen keeps long-press. Near the column's top or
  // bottom edge it scrolls, and the box keeps its far end where the content
  // was. Escape lets go without selecting.
  //
  // Installed on the document when this script loads rather than by the
  // MediaDragDrop hook: until LiveView connects (a second or two after a
  // reload) there is no hook, and the first box used to become a text
  // selection instead.
  function startBoxSelect(e, root) {
    var THRESHOLD = 5;
    var EDGE = 48;
    var NOT_EMPTY = "[data-draggable-file], [data-draggable-folder], button, a, input, textarea, " +
      "select, label, summary, [contenteditable], [phx-click], [role='button'], dialog, .modal, .dropdown";

    function selectables(area) {
      return Array.prototype.slice.call(
        area.querySelectorAll("[data-draggable-file], [data-draggable-folder]")
      ).filter(function(el) { return el.offsetParent; });
    }

    if (e.button !== 0 || e.pointerType === "touch") return;
    var area = e.target.closest && e.target.closest("[data-box-area]");
    if (!area || !root.contains(area)) return;
    if (e.target.closest(NOT_EMPTY)) return;

    if (root.__pkCancelBox) root.__pkCancelBox();
    var additive = e.shiftKey || e.metaKey || e.ctrlKey;
    var previousUserSelect = document.documentElement.style.userSelect;
    // Content coordinates: the press point travels with the content
    // when the column scrolls.
    var start = { x: e.clientX, y: e.clientY, scroll: area.scrollTop };
    var last = { x: e.clientX, y: e.clientY };
    var box = null, cards = null, hits = [], raf = 0, scrollRaf = 0;

    function rectNow() {
      var dy = area.scrollTop - start.scroll;
      var x1 = start.x, y1 = start.y - dy;
      return {
        left: Math.min(x1, last.x), top: Math.min(y1, last.y),
        right: Math.max(x1, last.x), bottom: Math.max(y1, last.y)
      };
    }

    function mark(el, on) {
      el.style.outline = on ? "2px solid var(--color-primary)" : "";
      el.style.outlineOffset = on ? "2px" : "";
    }

    function paint() {
      raf = 0;
      if (!box) return;
      var r = rectNow();
      var a = area.getBoundingClientRect();
      // The drawn box stays inside the column; the hit test uses the
      // whole of it, scrolled-away part included.
      var left = Math.max(r.left, a.left), top = Math.max(r.top, a.top);
      box.style.left = left + "px";
      box.style.top = top + "px";
      box.style.width = Math.max(0, Math.min(r.right, a.right) - left) + "px";
      box.style.height = Math.max(0, Math.min(r.bottom, a.bottom) - top) + "px";
      var next = cards.filter(function(el) {
        var c = el.getBoundingClientRect();
        return c.right > r.left && c.left < r.right && c.bottom > r.top && c.top < r.bottom;
      });
      hits.forEach(function(el) { if (next.indexOf(el) === -1) mark(el, false); });
      next.forEach(function(el) { if (hits.indexOf(el) === -1) mark(el, true); });
      hits = next;
    }

    function autoScroll() {
      scrollRaf = 0;
      if (!box) return;
      var a = area.getBoundingClientRect();
      var v = 0;
      if (last.y < a.top + EDGE) v = -Math.ceil((a.top + EDGE - last.y) / 4);
      else if (last.y > a.bottom - EDGE) v = Math.ceil((last.y - (a.bottom - EDGE)) / 4);
      if (!v) return;
      var before = area.scrollTop;
      area.scrollTop += v;
      if (area.scrollTop === before) return;
      paint();
      scrollRaf = requestAnimationFrame(autoScroll);
    }

    function begin() {
      cards = selectables(area);
      box = document.createElement("div");
      box.setAttribute("data-box-select-rect", "");
      box.style.cssText = "position:fixed;z-index:60;pointer-events:none;border-radius:4px;" +
        "border:1px solid var(--color-primary);" +
        "background:color-mix(in oklab, var(--color-primary) 12%, transparent);";
      document.body.appendChild(box);
      document.documentElement.style.userSelect = "none";
      try { window.getSelection().removeAllRanges(); } catch (_e) {}
    }

    function finish(commit) {
      if (root.__pkCancelBox === cancel) root.__pkCancelBox = null;
      window.removeEventListener("pointermove", onMove, true);
      window.removeEventListener("pointerup", onUp, true);
      window.removeEventListener("pointercancel", onCancel, true);
      window.removeEventListener("keydown", onKey, true);
      if (raf) cancelAnimationFrame(raf);
      if (scrollRaf) cancelAnimationFrame(scrollRaf);
      raf = scrollRaf = 0;
      if (!box) return;
      if (commit) paint();
      hits.forEach(function(el) { mark(el, false); });
      box.remove();
      box = null;
      document.documentElement.style.userSelect = previousUserSelect;
      // The click this release makes belongs to the box, not the page.
      var swallow = function(ev) { ev.stopPropagation(); ev.preventDefault(); };
      window.addEventListener("click", swallow, true);
      setTimeout(function() { window.removeEventListener("click", swallow, true); }, 0);
      if (!commit) return;
      var files = [], folders = [];
      hits.forEach(function(el) {
        if (el.dataset.draggableFile) files.push(el.dataset.draggableFile);
        else if (el.dataset.draggableFolder) folders.push(el.dataset.draggableFolder);
      });
      var payload = { files: files, folders: folders, additive: additive };
      var hook = root.__pkBoxHook;
      if (hook && hook.el === root) {
        hook.pushEventTo(root, "box_select", payload);
      } else {
        // Not connected yet: keep the cards outlined and hand the box to
        // the hook when it mounts (`setupBoxSelect`).
        var kept = hits.slice();
        kept.forEach(function(el) { mark(el, true); });
        window.__pkPendingBox = {
          root: root.id,
          payload: payload,
          unmark: function() { kept.forEach(function(el) { mark(el, false); }); }
        };
      }
    }

    function onMove(ev) {
      if (ev.pointerId !== e.pointerId) return;
      last = { x: ev.clientX, y: ev.clientY };
      if (!box) {
        if (Math.abs(last.x - start.x) < THRESHOLD && Math.abs(last.y - start.y) < THRESHOLD) return;
        begin();
      }
      ev.preventDefault();
      if (!raf) raf = requestAnimationFrame(paint);
      if (!scrollRaf) scrollRaf = requestAnimationFrame(autoScroll);
    }
    function onUp(ev) { if (ev.pointerId === e.pointerId) finish(true); }
    function onCancel(ev) { if (ev.pointerId === e.pointerId) finish(false); }
    function cancel() { finish(false); }
    function onKey(ev) {
      if (ev.key === "Escape" && box) {
        ev.preventDefault();
        ev.stopPropagation();
        finish(false);
      }
    }

    root.__pkCancelBox = cancel;
    window.addEventListener("pointermove", onMove, true);
    window.addEventListener("pointerup", onUp, true);
    window.addEventListener("pointercancel", onCancel, true);
    window.addEventListener("keydown", onKey, true);
  }

  document.addEventListener("pointerdown", function(e) {
    var root = e.target && e.target.closest && e.target.closest('[phx-hook="MediaDragDrop"]');
    if (root) startBoxSelect(e, root);
  });

  // Shift-click range select: Shift-clicking a card selects every card from
  // the anchor (the last card clicked or long-pressed while selecting) to it,
  // in the order they are on screen, added to what is selected. With nothing
  // selected yet it selects just that card, which becomes the anchor. Sent as
  // a `box_select`, so only what is on screen can be picked.
  var rangeAnchor = null; // {root, key}
  function cardKey(card) {
    return card.dataset.draggableFile ? "f:" + card.dataset.draggableFile
      : card.dataset.draggableFolder ? "d:" + card.dataset.draggableFolder : null;
  }
  function rangeCard(e) {
    var root = e.target && e.target.closest && e.target.closest('[phx-hook="MediaDragDrop"]');
    if (!root) return null;
    var card = e.target.closest("[data-draggable-file], [data-draggable-folder]");
    if (!card || !root.contains(card) || !card.closest("[data-box-area]")) return null;
    // A card's own menu and its rename / description fields keep their
    // clicks (a folder card's body is itself a button, which ranges).
    var control = e.target.closest(".dropdown, [role='menu'], [aria-haspopup], form, textarea, " +
      "input:not([type='checkbox'])");
    if (control && card.contains(control)) return null;
    return { root: root, card: card };
  }

  // Shift + press on a card would extend the page's text selection.
  document.addEventListener("pointerdown", function(e) {
    if (e.shiftKey && e.button === 0 && rangeCard(e)) e.preventDefault();
  }, true);

  document.addEventListener("click", function(e) {
    var hit = rangeCard(e);
    if (!hit) return;
    var root = hit.root, card = hit.card, key = cardKey(card);
    if (!key) return;
    if (!e.shiftKey) {
      // A plain click while selecting moves the anchor.
      if (root.querySelector('[data-selected="true"]') || root.dataset.selectionCount) {
        rangeAnchor = { root: root.id, key: key };
      }
      return;
    }
    var hook = root.__pkBoxHook;
    if (!hook || hook.el !== root) return;
    e.preventDefault();
    e.stopPropagation();
    var area = card.closest("[data-box-area]");
    var cards = Array.prototype.slice.call(
      area.querySelectorAll("[data-draggable-file], [data-draggable-folder]")
    ).filter(function(el) { return el.offsetParent; });
    var to = cards.indexOf(card);
    var from = -1;
    // Escape / Clear ends the old range even when its anchor is still on
    // screen. The next Shift-click starts a new selection at this card.
    if (!root.querySelector('[data-selected="true"]') &&
        !(parseInt(root.dataset.selectionCount || "0", 10) > 0)) rangeAnchor = null;
    if (rangeAnchor && rangeAnchor.root === root.id) {
      from = cards.findIndex(function(el) { return cardKey(el) === rangeAnchor.key; });
    }
    if (from === -1) {
      // No anchor on screen: the selected card nearest before this one,
      // else the first selected after it.
      for (var i = to - 1; i >= 0 && from === -1; i--) if (cards[i].dataset.selected === "true") from = i;
      for (var j = to + 1; j < cards.length && from === -1; j++) if (cards[j].dataset.selected === "true") from = j;
    }
    var picked = from === -1 ? [card] : cards.slice(Math.min(from, to), Math.max(from, to) + 1);
    if (from === -1) rangeAnchor = { root: root.id, key: key };
    var files = [], folders = [];
    picked.forEach(function(el) {
      if (el.dataset.draggableFile) files.push(el.dataset.draggableFile);
      else folders.push(el.dataset.draggableFolder);
    });
    hook.pushEventTo(root, "box_select", { files: files, folders: folders, additive: true });
  }, true);

  window.PhoenixKitAdminHooks.MediaDragDrop = {
    mounted: function() {
      // View mode (grid/list) AND the sidebar folder-tree state (expanded
      // folders + collapsed flag) are both persisted server-side in the user's
      // meta and rendered on first paint. There is intentionally no
      // localStorage→push restore here anymore — that ran only after connect
      // and made the grid flash to list / the tree flash from collapsed to its
      // open positions.

      // Bulk download: server pushes a list of {url, name}; we trigger one anchor click per file
      this.handleEvent("download_files", function(data) {
        var files = (data && data.files) || [];
        files.forEach(function(f, i) {
          setTimeout(function() {
            var a = document.createElement("a");
            a.href = f.url;
            a.download = f.name || "";
            a.rel = "noopener";
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
          }, i * 150);
        });
      });

      this.setupDragDrop();
      this.setupLongPress();
      this.setupBoxSelect();
    },

    destroyed: function() {
      if (this.el.__pkCancelBox) this.el.__pkCancelBox();
      if (this.el.__pkBoxHook === this) this.el.__pkBoxHook = null;
    },

    updated: function() {
      this.setupDragDrop();
      this.setupLongPress();
    },

    // Box select (see `startBoxSelect`, outside the hook): the listener is
    // installed when the script loads, not when the hook mounts, so a box
    // drawn in the second or two before LiveView connects is not lost to a
    // text selection. A box finished before the hook exists waits here.
    setupBoxSelect: function() {
      this.el.__pkBoxHook = this;
      var pending = window.__pkPendingBox;
      if (pending && pending.root === this.el.id) {
        window.__pkPendingBox = null;
        pending.unmark();
        this.pushEventTo(this.el, "box_select", pending.payload);
      }
    },

    // Long-press (hold ~450ms without moving) on a file/folder card enters
    // select mode and selects that item — the standard touch gesture for
    // multi-select. Moving (scroll/drag) or releasing early cancels it. The
    // click that follows the release is swallowed so the item isn't also
    // opened/navigated. Native HTML5 drag is mouse-only, so this doesn't
    // fight drag-to-move on touch.
    setupLongPress: function() {
      var self = this;
      var LONG_PRESS_MS = 450;
      var MOVE_TOLERANCE = 10;
      var items = this.el.querySelectorAll("[data-draggable-file], [data-draggable-folder]");
      items.forEach(function(el) {
        var fileUuid = el.dataset.draggableFile;
        var folderUuid = el.dataset.draggableFolder;
        var type = fileUuid ? "file" : "folder";
        var uuid = fileUuid || folderUuid;
        if (!uuid) return;

        el.removeEventListener("pointerdown", el._lpDown);
        el.removeEventListener("pointermove", el._lpMove);
        el.removeEventListener("pointerup", el._lpUp);
        el.removeEventListener("pointercancel", el._lpUp);
        el.removeEventListener("pointerleave", el._lpUp);
        if (el._lpClick) el.removeEventListener("click", el._lpClick, true);

        var timer = null, startX = 0, startY = 0;
        var cancel = function() { if (timer) { clearTimeout(timer); timer = null; } };

        el._lpDown = function(e) {
          if (typeof e.button === "number" && e.button !== 0) return;
          startX = e.clientX; startY = e.clientY;
          cancel();
          timer = setTimeout(function() {
            timer = null;
            el._lpFired = true;
            if (navigator.vibrate) { try { navigator.vibrate(30); } catch (_) {} }
            self.pushEventTo(self.el, "long_press_select", { type: type, uuid: uuid });
            // The held card anchors a later Shift-click range.
            rangeAnchor = { root: self.el.id, key: (type === "folder" ? "d:" : "f:") + uuid };
          }, LONG_PRESS_MS);
        };
        el._lpMove = function(e) {
          if (!timer) return;
          if (Math.abs(e.clientX - startX) > MOVE_TOLERANCE ||
              Math.abs(e.clientY - startY) > MOVE_TOLERANCE) {
            cancel();
          }
        };
        el._lpUp = function() { cancel(); };
        // Capture phase beats LiveView's window/bubble click listener, so this
        // reliably swallows the post-long-press click.
        el._lpClick = function(e) {
          if (el._lpFired) { e.preventDefault(); e.stopPropagation(); el._lpFired = false; }
        };

        el.addEventListener("pointerdown", el._lpDown);
        el.addEventListener("pointermove", el._lpMove);
        el.addEventListener("pointerup", el._lpUp);
        el.addEventListener("pointercancel", el._lpUp);
        el.addEventListener("pointerleave", el._lpUp);
        el.addEventListener("click", el._lpClick, true);
      });
    },

    setupDragDrop: function() {
      var self = this;
      var container = this.el;

      // The folder a dragged card already sits in: the drop zone around it
      // (the main area of the folder being shown, or a stack's section).
      // That zone is not a destination — dropping there leaves everything
      // where it is — so it neither lights up nor takes the drop, and the
      // same goes for every other zone naming that folder (its sidebar
      // node). A batch counts only when all of it shares one home.
      function originOf(el) {
        var zone = el.parentElement && el.parentElement.closest("[data-drop-folder]");
        return zone ? zone.dataset.dropFolder : null;
      }
      function dragOrigin(el) {
        if (el.dataset.selected !== "true") return originOf(el);
        var origin;
        var same = true;
        document.querySelectorAll('[data-selected="true"]').forEach(function(s) {
          var o = originOf(s);
          if (origin === undefined) origin = o;
          else if (o !== origin) same = false;
        });
        return same ? origin || null : null;
      }

      // A selection picked up shows as one: a small pile of its pictures
      // (the grabbed one on top) and a badge with how many are moving, in
      // place of the browser's snapshot of the single card under the mouse.
      function selectionGhost(e, grabbed) {
        var count = parseInt(self.el.dataset.selectionCount || "0", 10) ||
          document.querySelectorAll('[data-selected="true"]').length;
        if (count < 2 || !e.dataTransfer.setDragImage) return;
        var others = Array.prototype.slice.call(document.querySelectorAll('[data-selected="true"]'))
          .filter(function(el) { return el !== grabbed; });
        // Pictures before folders: a pile reads as what is being carried.
        var pictured = function(el) { return el.querySelector("img") ? 0 : 1; };
        others.sort(function(a, b) { return pictured(a) - pictured(b); });
        var pile = [grabbed].concat(others).slice(0, 3);
        var SIZE = 84;
        var ghost = document.createElement("div");
        ghost.style.cssText = "position:fixed;top:-1000px;left:-1000px;width:" + (SIZE + 40) + "px;height:" +
          (SIZE + 40) + "px;pointer-events:none;z-index:9999;";
        var tilt = [0, -9, 8];
        var shift = [[0, 0], [-7, 3], [8, 5]];
        for (var i = pile.length - 1; i >= 0; i--) {
          var card = document.createElement("div");
          card.style.cssText = "position:absolute;left:16px;top:20px;width:" + SIZE + "px;height:" + SIZE + "px;" +
            "border-radius:12px;overflow:hidden;background:var(--color-base-300, #ddd);" +
            "border:2px solid var(--color-base-100, #fff);box-shadow:0 6px 16px rgba(0,0,0,0.25);" +
            "display:flex;align-items:center;justify-content:center;" +
            "transform:translate(" + shift[i][0] + "px," + shift[i][1] + "px) rotate(" + tilt[i] + "deg);";
          var src = pile[i].querySelector("img");
          if (src && (src.currentSrc || src.src)) {
            var img = document.createElement("img");
            img.src = src.currentSrc || src.src;
            img.style.cssText = "width:100%;height:100%;object-fit:cover;";
            card.appendChild(img);
          } else {
            var icon = pile[i].querySelector("svg, [class*='hero-']");
            if (icon) {
              var c = icon.cloneNode(true);
              c.style.width = "48px";
              c.style.height = "48px";
              card.appendChild(c);
            }
          }
          ghost.appendChild(card);
        }
        var badge = document.createElement("div");
        badge.textContent = String(count);
        badge.style.cssText = "position:absolute;right:6px;top:6px;min-width:28px;height:28px;padding:0 8px;" +
          "box-sizing:border-box;border-radius:14px;background:var(--color-primary, #3b82f6);" +
          "color:var(--color-primary-content, #fff);font:700 14px/28px system-ui,sans-serif;text-align:center;" +
          "box-shadow:0 2px 6px rgba(0,0,0,0.3);border:2px solid var(--color-base-100, #fff);";
        ghost.appendChild(badge);
        document.body.appendChild(ghost);
        e.dataTransfer.setDragImage(ghost, 16 + SIZE / 2, 20 + SIZE / 2);
        // The snapshot is taken now; the element is not needed after.
        setTimeout(function() { ghost.remove(); }, 0);
      }

      // Make file items draggable
      var files = container.querySelectorAll("[data-draggable-file]");
      files.forEach(function(el) {
        el.setAttribute("draggable", "true");

        el.removeEventListener("dragstart", el._dragstart);
        el._dragstart = function(e) {
          e.dataTransfer.setData("text/plain", el.dataset.draggableFile);
          e.dataTransfer.effectAllowed = "move";
          self._dragOrigin = dragOrigin(el);
          self._internalDrag = true;
          // Batch mode: if the dragged item is part of the current
          // selection, the drag moves the WHOLE selection. Marker type
          // `application/x-pk-batch` tells the drop handler to fire the
          // existing `move_selected_to_folder` event (which iterates
          // `@selected_files` + `@selected_folders` server-side) rather
          // than the single-item move. All selected items get
          // opacity-50 for visual feedback.
          if (el.dataset.selected === "true") {
            e.dataTransfer.setData("application/x-pk-batch", "1");
            self._draggedBatch = true;
            selectionGhost(e, el);
            setBatchVisuals(true);
          } else {
            el.classList.add("opacity-50");
          }
        };
        el.addEventListener("dragstart", el._dragstart);

        el.removeEventListener("dragend", el._dragend);
        el._dragend = function() {
          self._dragOrigin = null;
          self._internalDrag = false;
          if (self._draggedBatch) {
            setBatchVisuals(false);
            self._draggedBatch = false;
          } else {
            el.classList.remove("opacity-50");
          }
          // Clear any lingering highlight if the drag was cancelled
          // (Esc, dropped outside) while still hovering a target.
          if (self._activeDropTarget) {
            clearHighlight(self._activeDropTarget);
            self._activeDropTarget = null;
          }
        };
        el.addEventListener("dragend", el._dragend);
      });

      // Make folder rows draggable. Same payload shape as files
      // (`text/plain` carries the uuid) but with an extra marker type so
      // drop targets can branch on folder vs file at hover time —
      // dataTransfer values aren't readable on dragover, only types
      // are, so the marker is the only way to make hover-time decisions
      // like "this drop target is the dragged folder itself, suppress
      // the drop indicator." Tracked in `self._draggedFolderUuid` for
      // the dragover self-check below.
      var folders = container.querySelectorAll("[data-draggable-folder]");
      folders.forEach(function(el) {
        el.setAttribute("draggable", "true");

        el.removeEventListener("dragstart", el._folderDragstart);
        el._folderDragstart = function(e) {
          e.dataTransfer.setData("text/plain", el.dataset.draggableFolder);
          e.dataTransfer.setData("application/x-pk-folder", "1");
          e.dataTransfer.effectAllowed = "move";
          self._draggedFolderUuid = el.dataset.draggableFolder;
          self._dragOrigin = dragOrigin(el);
          self._internalDrag = true;
          // Batch mode (same logic as the file dragstart above): if
          // the folder is part of the current selection, the drag
          // represents the whole selection. The folder-marker stays
          // set so self-drop suppression in dragover still works for
          // the source folder; the batch marker takes precedence in
          // the drop handler.
          if (el.dataset.selected === "true") {
            e.dataTransfer.setData("application/x-pk-batch", "1");
            self._draggedBatch = true;
            selectionGhost(e, el);
            setBatchVisuals(true);
          } else {
            el.classList.add("opacity-50");
          }
          e.stopPropagation();
        };
        el.addEventListener("dragstart", el._folderDragstart);

        el.removeEventListener("dragend", el._folderDragend);
        el._folderDragend = function() {
          self._draggedFolderUuid = null;
          self._dragOrigin = null;
          self._internalDrag = false;
          if (self._draggedBatch) {
            setBatchVisuals(false);
            self._draggedBatch = false;
          } else {
            el.classList.remove("opacity-50");
          }
          if (self._activeDropTarget) {
            clearHighlight(self._activeDropTarget);
            self._activeDropTarget = null;
          }
        };
        el.addEventListener("dragend", el._folderDragend);
      });

      // Make folder targets droppable (grid, list rows, and sidebar).
      // Accepts both file and folder drags — the `application/x-pk-folder`
      // marker type distinguishes them. Folder-on-self drops are
      // suppressed at hover time so the user doesn't get a "yes you can
      // drop here" indicator on the very folder they're dragging.

      // Single-active-target tracking: nested drop targets (folder card
      // inside the main-area wrapper) need exclusivity — only the
      // innermost should highlight. When a new target lights up, we
      // clear the previous one. stopPropagation alone doesn't suffice
      // because the wrapper can already be highlighted before the
      // cursor enters a child and dragleave timing on the wrapper
      // varies across browsers.
      function clearHighlight(t) {
        if (!t) return;
        if (!t.dataset.dropNoBg) {
          t.classList.remove("bg-primary/10");
          if (t._origBg !== undefined) {
            t.style.backgroundColor = t._origBg;
            t._origBg = undefined;
          }
        }
        t.style.outline = "";
        t.style.outlineOffset = "";
      }

      // When the user picks up a selected item (during select_mode),
      // the drag represents the whole selection — gray out every
      // selected element so it's visually clear what's coming along.
      // Each selected file/folder element carries `data-selected="true"`
      // from heex, so a single querySelectorAll handles all four
      // rendering paths (grid/list × file/folder).
      function setBatchVisuals(active) {
        document.querySelectorAll('[data-selected="true"]').forEach(function(el) {
          if (active) {
            el.classList.add("opacity-50");
          } else {
            el.classList.remove("opacity-50");
          }
        });
      }

      // Files dragged in from the computer, not a card of this page.
      function fromComputer(e) {
        return !self._internalDrag && e.dataTransfer &&
          Array.prototype.indexOf.call(e.dataTransfer.types || [], "Files") !== -1;
      }

      var dropTargets = document.querySelectorAll("[data-drop-folder]");
      dropTargets.forEach(function(target) {
        target.removeEventListener("dragover", target._dragover);
        target._dragover = function(e) {
          // Files from the computer are an upload, not a move: only the zone
          // of the folder being shown (`data-drop-upload`) takes them —
          // outlined a little outside the cards, dashed — and the drop
          // carries on up to FolderDropUpload, which uploads them. Folder
          // cards and the sidebar stay dark so the outline is where they go.
          if (fromComputer(e)) {
            if (target.dataset.dropUpload !== "true") return;
            e.preventDefault();
            e.dataTransfer.dropEffect = "copy";
            if (self._activeDropTarget && self._activeDropTarget !== target) {
              clearHighlight(self._activeDropTarget);
            }
            self._activeDropTarget = target;
            target.style.outline = "2px dashed var(--color-primary)";
            target.style.outlineOffset = "6px";
            return;
          }
          var isFolder = e.dataTransfer.types.indexOf("application/x-pk-folder") !== -1;
          if (isFolder && target.dataset.dropFolder === self._draggedFolderUuid) {
            // Drop-on-self for a folder — skip preventDefault so the
            // browser shows the "no-drop" cursor and we don't paint the
            // accept indicator. Drop-on-descendant still slips through
            // (we can't detect descendancy in JS without the tree); the
            // server rejects it with `{:error, :cycle}`.
            return;
          }
          // The folder the dragged card is already in (see `originOf`):
          // no accept indicator, no drop.
          if (self._dragOrigin && target.dataset.dropFolder === self._dragOrigin) {
            if (self._activeDropTarget === target) {
              clearHighlight(target);
              self._activeDropTarget = null;
            }
            return;
          }
          e.preventDefault();
          e.stopPropagation();
          e.dataTransfer.dropEffect = "move";

          // Exclusivity: if a different target was lit, clear it before
          // we paint the new one. Then mark this target as active so
          // dragleave / drop know whether to release the tracker.
          if (self._activeDropTarget && self._activeDropTarget !== target) {
            clearHighlight(self._activeDropTarget);
          }
          self._activeDropTarget = target;

          // Grid/list folder cards carry an inline
          // `style="background-color: ..."` from `folder_bg_style`, which
          // beats any class-based bg (inline > class). Stash and clear
          // the inline bg so `bg-primary/10` can take effect, then add
          // the highlight outline inline.
          //
          // CSS `outline` instead of Tailwind's `ring-*`: ring uses
          // `box-shadow`, which `<tr>` elements (list view rows) don't
          // render reliably — outline works on every element type and
          // follows border-radius in modern browsers.
          //
          // `data-drop-no-bg`: opt-out for large drop surfaces (the
          // main content-area target) where a 10% primary tint over a
          // huge area is overwhelming. Outline-only there.
          if (!target.dataset.dropNoBg) {
            if (target._origBg === undefined) {
              target._origBg = target.style.backgroundColor;
            }
            target.style.backgroundColor = "";
            target.classList.add("bg-primary/10");
          }
          // Outline colour: a target may carry `data-drop-color` (a folder's
          // own colour) so the accept indicator matches the folder instead of
          // a generic blue; otherwise fall back to the primary. daisyUI 5
          // exposes the primary as a complete oklch() value in
          // `--color-primary` (not the legacy `--p` raw components), so we use
          // it directly without wrapping it in oklch().
          // `outlineOffset: -2px` insets the outline so the table's
          // `overflow-x-auto` wrapper can't clip the left/right edges
          // of list-view rows. Visually it looks like a "highlighted
          // row" instead of an outline that sticks out — same effect.
          target.style.outline = "2px solid " + (target.dataset.dropColor || "var(--color-primary)");
          target.style.outlineOffset = "-2px";
        };
        target.addEventListener("dragover", target._dragover);

        target.removeEventListener("dragleave", target._dragleave);
        target._dragleave = function() {
          clearHighlight(target);
          if (self._activeDropTarget === target) {
            self._activeDropTarget = null;
          }
        };
        target.addEventListener("dragleave", target._dragleave);

        target.removeEventListener("drop", target._drop);
        target._drop = function(e) {
          if (fromComputer(e)) {
            // Left for FolderDropUpload, further up, to upload.
            clearHighlight(target);
            if (self._activeDropTarget === target) self._activeDropTarget = null;
            return;
          }
          e.preventDefault();
          e.stopPropagation();
          clearHighlight(target);
          if (self._activeDropTarget === target) {
            self._activeDropTarget = null;
          }
          var draggedUuid = e.dataTransfer.getData("text/plain");
          var dropFolderUuid = target.dataset.dropFolder;
          if (!draggedUuid || !dropFolderUuid) return;
          // Let go over the folder it came from: nothing moves, so nothing
          // is asked of the server (LiveView's page-wide dragover lets the
          // drop happen even though this zone declined it).
          if (self._dragOrigin && dropFolderUuid === self._dragOrigin) return;

          var isFolder = e.dataTransfer.types.indexOf("application/x-pk-folder") !== -1;
          var isBatch = e.dataTransfer.types.indexOf("application/x-pk-batch") !== -1;
          var resolvedTarget = dropFolderUuid === "root" ? "" : dropFolderUuid;

          if (isBatch) {
            // Drag started on a selected item — move the whole
            // selection. `move_selected_to_folder` is the existing bulk
            // handler used by the move modal; it reads
            // `@selected_files` + `@selected_folders` from socket state
            // and clears them + resets select_mode after. Drag-on-self
            // for a folder in the batch is handled server-side (the
            // bulk handler skips moving a folder onto itself).
            // The same key the move dialog sends (`phx-value-folder-uuid`).
            self.pushEventTo(self.el, "move_selected_to_folder", {
              "folder-uuid": resolvedTarget
            });
          } else if (isFolder) {
            if (draggedUuid === dropFolderUuid) return;
            self.pushEventTo(self.el, "move_folder_to_folder", {
              folder_uuid: draggedUuid,
              target_uuid: resolvedTarget
            });
          } else {
            self.pushEventTo(self.el, "move_file_to_folder", {
              file_uuid: draggedUuid,
              folder_uuid: resolvedTarget
            });
          }
        };
        target.addEventListener("drop", target._drop);
      });

      // Trash drop target — any element carrying `data-drop-trash`, looked
      // up across the document rather than inside this hook's element, so a
      // consumer can put the target in a page header. Mirrors the folder drop
      // wiring above but pushes `trash_file` / `trash_folder`, and uses
      // error-colored hover feedback so the destructive action reads as
      // different from a folder move at a glance.
      //
      // Files, folders and batches are all accepted. (This comment used to say
      // folders were refused; V119 added recursive folder trash and the
      // comment was left behind, which cost a consumer an afternoon of
      // believing it.)
      var trashTargets = document.querySelectorAll("[data-drop-trash]");
      trashTargets.forEach(function(target) {
        target.removeEventListener("dragover", target._trashDragover);
        target._trashDragover = function(e) {
          // Folders + batches are now valid drop targets — V119 added
          // recursive folder trash, and batches route to
          // `delete_selected` which handles trash vs permanent per
          // `@filter_trash`.
          e.preventDefault();
          e.dataTransfer.dropEffect = "move";
          target.classList.add("ring-2", "ring-error", "bg-error/10");
        };
        target.addEventListener("dragover", target._trashDragover);

        target.removeEventListener("dragleave", target._trashDragleave);
        target._trashDragleave = function() {
          target.classList.remove("ring-2", "ring-error", "bg-error/10");
        };
        target.addEventListener("dragleave", target._trashDragleave);

        target.removeEventListener("drop", target._trashDrop);
        target._trashDrop = function(e) {
          e.preventDefault();
          e.stopPropagation();
          target.classList.remove("ring-2", "ring-error", "bg-error/10");
          var draggedUuid = e.dataTransfer.getData("text/plain");
          if (!draggedUuid) return;

          var isFolder = e.dataTransfer.types.indexOf("application/x-pk-folder") !== -1;
          var isBatch = e.dataTransfer.types.indexOf("application/x-pk-batch") !== -1;

          if (isBatch) {
            // Reuses the bulk delete handler — it reads
            // `@selected_files` + `@selected_folders` on the server
            // and trashes (or permanent-deletes in trash view)
            // according to `@filter_trash`.
            self.pushEventTo(self.el, "delete_selected", {});
          } else if (isFolder) {
            self.pushEventTo(self.el, "trash_folder", { folder_uuid: draggedUuid });
          } else {
            self.pushEventTo(self.el, "trash_file", { file_uuid: draggedUuid });
          }
        };
        target.addEventListener("drop", target._trashDrop);
      });
    }
  };

  // A press the public file kept while this file was on its way
  // (`__pkEarlyPress`, phoenix_kit.js): take it over. Still held, the box carries
  // on from the next move; already released, it is replayed through the same code
  // and waits in `__pkPendingBox` for the hook, like a box finished before
  // LiveView connected.
  (function() {
    var early = window.__pkEarlyPress;
    window.__pkEarlyPress = null;
    if (!early) return;
    early.done();
    var e = early.e;
    var root = e.target.closest && e.target.closest('[phx-hook="MediaDragDrop"]');
    if (!root) return;
    startBoxSelect(e, root);
    if (!early.end) return;
    ["pointermove", "pointerup"].forEach(function(type) {
      window.dispatchEvent(new PointerEvent(type, {
        pointerId: e.pointerId, clientX: early.end.x, clientY: early.end.y, bubbles: true, cancelable: true
      }));
    });
  })();

  // ============================================================================
  // EtcherReset — the browser half of "reset annotation settings"
  // ============================================================================
  //
  // Etcher keeps how-you-work answers (background dots, connector anchors,
  // which tools are on the bar, how much of the style panel is open, the
  // per-tool palettes and colours, the label defaults) in localStorage under
  // its own key: it works with no host involvement at all, and a viewer that
  // does not know who you are cannot do better. The palette and ink the
  // toolbar saves DO live on the user row, and the settings page clears
  // those server-side — this clears the other half, in the same round trip,
  // so a reset is a reset rather than a half-fix.
  //
  // Cleared, not rewritten with defaults: Etcher falls back to its own
  // defaults for anything absent, so removing the key is the honest way to
  // say "no answers of mine". A live viewer on another tab picks them up on
  // its next mount.
  // ----------------------------------------------------------------------------

  window.PhoenixKitAdminHooks.EtcherReset = {
    mounted() {
      this.handleEvent("phoenix_kit:etcher-reset", function() {
        try {
          window.localStorage.removeItem("etcher:prefs");
        } catch (_) {
          // Private mode, storage disabled, a browser that refuses: the
          // server half still happened, and there is nothing here worth
          // interrupting the page for.
        }
      });
    }
  };

  // ============================================================================
  // ViewerSwipe — swipe left/right on a fully zoomed-out picture to step
  // ============================================================================
  //
  // Fresco announces a one-finger swipe across a picture at its fitted view as
  // a bubbling `fresco:swipe` event (zoomed in, the same drag is a pan and is
  // never announced). This sits in the viewer pane and turns it into the same
  // step the side tabs send: swipe left for the next file, right for the
  // previous one. Listening on the pane rather than a Fresco handle means a
  // canvas remount (the eye, the pencil, a new burn) needs nothing re-wired.
  //
  // Not while annotating: with the drawing tools up, a sideways drag is a
  // stroke or a grab, and losing the picture to it would be worse than the
  // swipe not working there.
  // ----------------------------------------------------------------------------

  window.PhoenixKitAdminHooks.ViewerSwipe = {
    mounted() {
      var self = this;
      this._pane = this.el.parentElement;
      this._onSwipe = function(e) {
        var dir = e.detail && e.detail.direction === "left" ? "next" : "prev";
        if (self.el.dataset[dir === "next" ? "hasNext" : "hasPrev"] !== "true") return;
        if (self._pane.querySelector(".etcher-pencil-active")) return;
        // Only an initialized gallery in this viewer owns the swipe. Its
        // library may still be loading, or another browser may have a gallery.
        var modal = self._pane.closest('[phx-hook="ViewerKeydown"]');
        if (modal && modal._pkGallery) return;
        self.pushEventTo(self.el.dataset.target, "step_viewer", { dir: dir });
      };
      if (this._pane) this._pane.addEventListener("fresco:swipe", this._onSwipe);
    },

    destroyed() {
      if (this._pane) this._pane.removeEventListener("fresco:swipe", this._onSwipe);
    }
  };

  // ============================================================================
  // ViewerGallery — the Apple Photos way of stepping through pictures
  // ============================================================================
  //
  // Gallery mode (MediaBrowser `gallery_mode`). A drag, a swipe or a sideways
  // trackpad scroll on a picture at its opening zoom slides the next picture
  // in beside it, already decoded — Fresco.gallery draws the strip over the
  // viewer. Nothing waits on the server: once the strip settles the hook
  // names the new file (`gallery_go`), the viewer patches to it underneath,
  // and the strip hands over as soon as that viewer's picture has painted.
  // The arrow keys and the side tabs slide the same way.
  //
  // Not while annotating (a drag is a stroke there) and not zoomed in (a drag
  // is a pan): the viewer keeps those gestures, exactly as before.
  // ----------------------------------------------------------------------------

  var GALLERY_SETTLE_MS = 250;    // the strip still this long before telling the server
  var GALLERY_HOLD_MAX_MS = 8000; // the viewer never painted: stop covering it
  var GALLERY_SHARP_MAX_MS = 2500; // painted but still blurry: hand over anyway
  var GALLERY_RESEND_MS = 2000;   // no sign of the server following: ask again

  // In gallery mode the viewer is for looking at pictures, so the dot grid
  // stays away until the pencil is on — then the person's own grid setting
  // (Etcher's, which toggles `fresco--no-grid`) decides, as everywhere else.
  // Pure CSS on what is in the modal, so no state to keep in step.
  var GALLERY_SCOPE = '[phx-hook="ViewerKeydown"]:has(> [phx-hook="ViewerGallery"]):not(:has(.etcher-pencil-active)) ';
  // A tap on the picture hides the viewer's controls and the next brings
  // them back, as in Photos. The flag lives on <html>, which LiveView never
  // patches; annotating always shows them (the scope above excludes it).
  var GALLERY_CHROME = ['button[phx-click="close_viewer"]', 'button[phx-click="toggle_viewer_sidebar"]',
    "[phx-value-dir]", ".fresco-nav", ".fresco-zoom"];
  var GALLERY_GRID_CSS =
    GALLERY_SCOPE + ".fresco-viewer { background-image: none !important; }\n" +
    GALLERY_CHROME.map(function(sel) { return GALLERY_SCOPE + sel; }).join(",\n") +
    " { transition: opacity 120ms ease-out; }\n" +
    GALLERY_CHROME.map(function(sel) { return 'html[data-pk-gallery-chrome="hidden"] ' + GALLERY_SCOPE + sel; }).join(",\n") +
    " { opacity: 0 !important; visibility: hidden !important; pointer-events: none !important; }\n" +
    // Under a frozen copy (ViewerGallery `_freezeChrome`) the real controls
    // are rebuilding; they stay out of sight until the copy goes.
    'html[data-pk-chrome-frozen] ' + GALLERY_SCOPE + '.fresco-viewer .fresco-nav, ' +
    'html[data-pk-chrome-frozen] ' + GALLERY_SCOPE + '.fresco-viewer .fresco-zoom { visibility: hidden !important; }';
  var GALLERY_TAP_SLOP = 10;      // px a tap may wander
  var GALLERY_TAP_MS = 350;       // longer is a press, not a tap
  var GALLERY_DOUBLE_TAP_MS = 300; // a second tap this soon is a double-tap (zoom)

  // In now, not at mount: the rules key on markup the server already sent,
  // and a viewer opened from a link otherwise showed the dot grid for the
  // second or more before the socket connected and the hook mounted.
  function ensureGalleryCss() {
    if (document.getElementById("pk-gallery-css")) return;
    var css = document.createElement("style");
    css.id = "pk-gallery-css";
    css.textContent = GALLERY_GRID_CSS;
    (document.head || document.documentElement).appendChild(css);
  }
  ensureGalleryCss();

  var viewerGalleryHook = {
    mounted() {
      var self = this;
      ensureGalleryCss();
      if (!window.Fresco || !window.Fresco.gallery) return;
      self._modal = self.el.parentElement;
      // The strip goes in the ignored layer beside this element: a child the
      // template does not render would be dropped by the next patch.
      var layer = document.getElementById(self.el.id + "-layer") || self._modal;

      function canvasEl() {
        return self._modal && self._modal.querySelector('[phx-hook="FrescoCanvas"]');
      }
      function handle() {
        var c = canvasEl();
        return c && window.Fresco.viewerFor(c.id);
      }
      function canvasImg(c) {
        return c && c.querySelector("img[data-fresco-canvas-img]");
      }
      // The pane colour behind the picture, so the strip's gaps match it.
      function background() {
        var n = canvasEl();
        while (n && n !== document.body) {
          var bg = window.getComputedStyle(n).backgroundColor;
          if (bg && bg !== "transparent" && !/rgba\(.*,\s*0\)$/.test(bg)) return bg;
          n = n.parentElement;
        }
        return "#000";
      }
      // Where the viewer has its picture on screen, unturned.
      function currentRect() {
        var img = canvasImg(canvasEl());
        var h = handle();
        if (!img) return null;
        var r = img.getBoundingClientRect();
        var rot = h && h.getRotation ? ((((h.getRotation() || 0) % 360) + 360) % 360) : 0;
        var quarter = rot === 90 || rot === 270;
        return {
          cx: r.left + r.width / 2, cy: r.top + r.height / 2,
          w: quarter ? r.height : r.width, h: quarter ? r.width : r.height,
          rotation: rot
        };
      }

      self._gallery = window.Fresco.gallery({
        container: layer,
        getRect: function() { var c = canvasEl(); return c ? c.getBoundingClientRect() : null; },
        getTarget: canvasEl,
        background: background,
        canStart: function() {
          if (self._modal.querySelector(".etcher-pencil-active, .etcher-actionbar.is-active")) return false;
          var h = handle();
          return !h || !h.isAtHome || h.isAtHome();
        },
        getCurrentRect: currentRect,
        // The strip is drawn over the whole viewer, controls and all; still
        // copies of the controls ride above it (see `_freezeChrome`).
        onShow: function() { self._freezeChrome(); },
        onHide: function() { self._thawChrome(); },
        onChange: function(_i, item) {
          // Only once the strip has been still a moment: the viewer's
          // re-render (Fresco, Etcher, Tessera mounting) is heavy main-thread
          // work, and landing in the middle of the next swipe it stuttered.
          // The strip keeps showing the picture meanwhile, so nothing waits.
          clearTimeout(self._goTimer);
          var go = function() {
            var g = self._gallery;
            if (!g || !item || !item.key || g.currentKey() !== item.key) return;
            if (g.isBusy()) { self._goTimer = setTimeout(go, GALLERY_SETTLE_MS); return; }
            self.pushEventTo(self.el, "gallery_go", { uuid: item.key });
          };
          self._goTimer = setTimeout(go, GALLERY_SETTLE_MS);
          self._watchFor(item);
        }
      });
      self._modal._pkGallery = self._gallery;

      // Hand over once the viewer shows `key` as sharply as the strip does:
      // its canvas (the file uuid is in its id) mounted, and a picture loaded
      // with the pixels its size on screen needs. The viewer opens on the
      // small copy and climbs; handing over to that small copy read as the
      // picture snapping blurry the moment the slide finished.
      self._watchFor = function(item) {
        clearInterval(self._watch);
        var key = item && item.key;
        if (!key) return;
        var started = Date.now(), seen = 0, resent = started;
        self._watch = setInterval(function() {
          var g = self._gallery;
          if (!g || !g.isShown() || g.currentKey() !== key) { clearInterval(self._watch); return; }
          var t = Date.now();
          // Mid-gesture nothing is handed over or re-sent; the clock waits.
          if (g.isBusy()) { started = resent = t; seen = seen && t; return; }
          // Videos, PDFs and file cards have no Fresco canvas to wait for.
          // Once LiveView follows, expose their actual player or preview.
          if (item.kind !== "image" && self.el.dataset.current === key) {
            clearInterval(self._watch);
            g.hide();
            return;
          }
          var c = canvasEl();
          if (!c || c.id.indexOf(key) === -1) {
            // The server has not followed (a dropped event): ask again.
            if (t - resent > GALLERY_RESEND_MS) {
              resent = t;
              self.pushEventTo(self.el, "gallery_go", { uuid: key });
            }
            if (t - started > GALLERY_HOLD_MAX_MS) { clearInterval(self._watch); g.hide(); }
            return;
          }
          if (!seen) seen = t;
          var sharpest = 0;
          c.querySelectorAll("img[data-fresco-canvas-img]").forEach(function(im) {
            if (im.complete && im.naturalWidth > sharpest) sharpest = im.naturalWidth;
          });
          if (!sharpest) {
            if (t - seen > GALLERY_HOLD_MAX_MS) { clearInterval(self._watch); g.hide(); }
            return;
          }
          var r = currentRect();
          var need = r ? r.w * (window.devicePixelRatio || 1) : 0;
          if (item.width) need = Math.min(need, item.width);
          if (sharpest < need * 0.7 && t - seen < GALLERY_SHARP_MAX_MS) return;
          clearInterval(self._watch);
          // A frame for the viewer to lay it out, then glide onto it.
          requestAnimationFrame(function() {
            if (self._gallery !== g || !g.isShown() || g.currentKey() !== key) return;
            if (!g.release(key, currentRect())) self._watchFor(item);
          });
        }, 50);
      };

      self._load = function() {
        var data;
        try { data = JSON.parse(self.el.dataset.gallery || "{}"); } catch (_e) { data = {}; }
        self._gallery.setItems(data.items || [], data.index || 0);
      };
      self._load();

      // Arrow keys and the side tabs: the same slide. Captured on window so
      // the viewer's own step (ViewerKeydown, the tab's phx-click) does not
      // also run; when the strip cannot slide they pass through untouched.
      self._onKey = function(e) {
        if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        var t = document.activeElement;
        if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable === true)) return;
        if (!self._gallery.isShown() && !self.galleryAllowed()) return;
        if (self._gallery.step(e.key === "ArrowLeft" ? -1 : 1)) {
          e.preventDefault();
          e.stopImmediatePropagation();
        }
      };
      self._onTab = function(e) {
        var btn = e.target && e.target.closest && e.target.closest('[phx-click="step_viewer"]');
        if (!btn || !self._modal.contains(btn)) return;
        if (!self._gallery.isShown() && !self.galleryAllowed()) return;
        var dir = btn.getAttribute("phx-value-dir") === "prev" ? -1 : 1;
        if (self._gallery.step(dir)) {
          e.preventDefault();
          e.stopImmediatePropagation();
        }
      };
      // Tap to hide / show the controls, at once either way so the tap
      // feels answered. A double-tap's second tap does not toggle back —
      // it just zooms, leaving the controls as the first tap set them.
      self._onTapDown = function(e) {
        var c = canvasEl();
        self._tap = null;
        if (!e.isPrimary || (e.pointerType === "mouse" && e.button !== 0)) return;
        if (!c || !c.contains(e.target) || !self.galleryAllowed()) return;
        if (e.target.closest && e.target.closest("button, a, input, .fresco-nav, .fresco-zoom")) return;
        self._tap = { x: e.clientX, y: e.clientY, t: Date.now(), id: e.pointerId };
      };
      self._onTapUp = function(e) {
        var tp = self._tap;
        self._tap = null;
        if (!tp || e.pointerId !== tp.id) return;
        if (Math.abs(e.clientX - tp.x) > GALLERY_TAP_SLOP || Math.abs(e.clientY - tp.y) > GALLERY_TAP_SLOP) return;
        if (Date.now() - tp.t > GALLERY_TAP_MS) return;
        if (self._tapTimer) { clearTimeout(self._tapTimer); self._tapTimer = null; return; } // the double-tap's second
        var root = document.documentElement;
        if (root.getAttribute("data-pk-gallery-chrome") === "hidden") root.removeAttribute("data-pk-gallery-chrome");
        else { root.setAttribute("data-pk-gallery-chrome", "hidden"); self._dropFrozenChrome(); }
        self._tapTimer = setTimeout(function() { self._tapTimer = null; }, GALLERY_DOUBLE_TAP_MS);
      };
      document.addEventListener("pointerdown", self._onTapDown, true);
      document.addEventListener("pointerup", self._onTapUp, true);

      self.galleryAllowed = function() {
        return !self._modal.querySelector(".etcher-pencil-active, .etcher-actionbar.is-active");
      };
      window.addEventListener("keydown", self._onKey, true);
      window.addEventListener("click", self._onTab, true);
    },

    updated() {
      if (this._load) this._load();
    },

    // The controls stay put while the picture under them changes, as in
    // Photos. The strip is drawn above the whole viewer while it runs —
    // over the toolbar, the zoom pill, the side tabs — and the next file's
    // canvas then builds a new toolbar of its own (briefly a different one:
    // the whole row before its overflow folds, the zoom pill empty). Both
    // read as the controls vanishing for a second and coming back. So from
    // the moment the strip shows, still copies of the controls sit above
    // it, exactly where the real ones are; they go once the strip has gone
    // and the new canvas's controls have settled underneath. A press goes
    // through them (and through the strip) to the real controls.
    _freezeChrome() {
      if (this._frozen) { this._frozen.thawing = false; return; }
      var modal = this._modal;
      var layer = document.getElementById(this.el.id + "-layer");
      if (!modal || !layer) return;
      if (document.documentElement.getAttribute("data-pk-gallery-chrome") === "hidden") return;
      var canvas = modal.querySelector('[phx-hook="FrescoCanvas"]');
      var picks = [];
      if (canvas) {
        picks = picks.concat(Array.prototype.slice.call(
          canvas.querySelectorAll(".fresco-nav:not(.fresco-nav-overflow), .fresco-zoom")));
      }
      picks = picks.concat(Array.prototype.slice.call(modal.querySelectorAll(
        'button[phx-click="close_viewer"], button[phx-click="toggle_viewer_sidebar"], button[phx-value-dir]')));
      var vars = canvas ? window.getComputedStyle(canvas) : null;
      var copies = [];
      picks.forEach(function(el) {
        if (!el.offsetParent) return;
        var r = el.getBoundingClientRect();
        if (!(r.width > 0 && r.height > 0)) return;
        var copy = el.cloneNode(true);
        [copy].concat(Array.prototype.slice.call(copy.querySelectorAll("*"))).forEach(function(n) {
          Array.prototype.slice.call(n.attributes).forEach(function(at) {
            if (at.name === "id" || at.name.indexOf("phx-") === 0) n.removeAttribute(at.name);
          });
        });
        if (vars && canvas.contains(el)) {
          for (var k = 0; k < vars.length; k++) {
            if (vars[k].indexOf("--") === 0) copy.style.setProperty(vars[k], vars.getPropertyValue(vars[k]));
          }
        }
        var st = copy.style;
        st.position = "fixed";
        st.left = r.left + "px"; st.top = r.top + "px";
        st.right = "auto"; st.bottom = "auto";
        st.width = r.width + "px"; st.height = r.height + "px";
        st.margin = "0"; st.transform = "none"; st.translate = "none";
        st.maxWidth = "none"; st.maxHeight = "none";
        st.zIndex = "1002";
        st.pointerEvents = "none";
        st.transition = "none";
        st.opacity = window.getComputedStyle(el).opacity;
        copy.setAttribute("aria-hidden", "true");
        copy.setAttribute("inert", "");
        copy.setAttribute("data-pk-frozen-chrome", "");
        layer.appendChild(copy);
        copies.push(copy);
      });
      if (!copies.length) return;
      this._frozen = { els: copies, thawing: false };
      document.documentElement.setAttribute("data-pk-chrome-frozen", "");
    },

    // The strip has gone: drop the copies once the canvas on screen is the
    // picture the strip ended on and its controls have held still a few
    // frames (or straight away when the swipe went back where it started).
    _thawChrome() {
      var self = this;
      var st = this._frozen;
      if (!st) return;
      st.thawing = true;
      var key = this._gallery && this._gallery.currentKey && this._gallery.currentKey();
      var started = Date.now(), seenAt = 0, lastSig = "", steady = 0;
      var tick = function() {
        if (self._frozen !== st || !st.thawing) return;
        var c = self._modal && self._modal.querySelector('[phx-hook="FrescoCanvas"]');
        var hidden = document.documentElement.getAttribute("data-pk-gallery-chrome") === "hidden";
        var done = hidden || !key || (!c && self.el.dataset.current === key) || Date.now() - started > 5000;
        if (!done && c && c.id.indexOf(key) !== -1) {
          var nav = c.querySelector(".fresco-nav:not(.fresco-nav-overflow)");
          var zoom = c.querySelector(".fresco-zoom");
          var sig = nav ? nav.querySelectorAll("button:not([hidden])").length + "|" +
            (zoom ? zoom.textContent : "") + "|" + Math.round(nav.getBoundingClientRect().width) : "";
          if (sig && (!zoom || zoom.textContent)) {
            if (!seenAt) seenAt = Date.now();
            steady = sig === lastSig ? steady + 1 : 0;
            lastSig = sig;
            done = steady >= 6 && Date.now() - seenAt > 150;
          }
        }
        if (done) self._dropFrozenChrome();
        else requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    },

    _dropFrozenChrome() {
      var st = this._frozen;
      this._frozen = null;
      document.documentElement.removeAttribute("data-pk-chrome-frozen");
      if (st) st.els.forEach(function(el) { if (el.parentNode) el.parentNode.removeChild(el); });
    },

    destroyed() {
      if (this._modal && this._modal._pkGallery === this._gallery) delete this._modal._pkGallery;
      this._dropFrozenChrome();
      clearTimeout(this._goTimer);
      clearInterval(this._watch);
      if (this._onKey) window.removeEventListener("keydown", this._onKey, true);
      if (this._onTab) window.removeEventListener("click", this._onTab, true);
      if (this._onTapDown) document.removeEventListener("pointerdown", this._onTapDown, true);
      if (this._onTapUp) document.removeEventListener("pointerup", this._onTapUp, true);
      clearTimeout(this._tapTimer);
      // The next viewer opens with its controls.
      document.documentElement.removeAttribute("data-pk-gallery-chrome");
      if (this._gallery) this._gallery.destroy();
      this._gallery = null;
    }
  };
  window.PhoenixKitAdminHooks.ViewerGallery = lazyHook(pkLoaders.fresco, function() {
    return viewerGalleryHook;
  });

  // ============================================================================
  // ViewerHiresLoading — "Loading full quality…" while a sharper picture arrives
  // ============================================================================
  //
  // The media viewer opens on the small bitmap the grid already painted, and
  // Tessera climbs to a bigger rung once the screen asks for one. On a slow
  // line that climb can take a long time, and nothing said it was happening:
  // people sat looking at a blurry photograph wondering whether that was all
  // there was.
  //
  // Fresco swaps a rung by setting the visible <img>'s src, and the browser
  // keeps painting the old bitmap until the new one has loaded — so "a
  // sharper picture is on its way" is exactly "the canvas image's src is not
  // complete yet", and its load (or error) is "done". This watches the pane's
  // canvas image for that and shows the pill the template renders; nothing
  // in Fresco or Tessera has to know. A canvas remount (the eye, the pencil,
  // a new burn) brings a new <img>, which the observer picks up too.
  //
  // HIRES_SHOW_DELAY_MS keeps a load that finishes quickly — a cache hit, a
  // fast line — from flashing the pill for a frame.
  // ----------------------------------------------------------------------------

  var HIRES_SHOW_DELAY_MS = 300;

  window.PhoenixKitAdminHooks.ViewerHiresLoading = {
    mounted() {
      var self = this;
      this._pane = this.el.parentElement;
      this._img = null;
      this._timer = null;
      this._onSettle = function() { self._track(); };
      this._observer = new MutationObserver(function() { self._track(); });
      if (this._pane) {
        this._observer.observe(this._pane, {
          subtree: true, childList: true, attributes: true, attributeFilter: ["src"]
        });
      }
      this._track();
    },

    destroyed() {
      if (this._observer) this._observer.disconnect();
      this._watch(null);
      clearTimeout(this._timer);
    },

    _track() {
      var img = this._pane && this._pane.querySelector("img[data-fresco-canvas-img]");
      if (img !== this._img) this._watch(img);
      this._set(!!img && !!img.getAttribute("src") && !img.complete);
    },

    _watch(img) {
      if (this._img) {
        this._img.removeEventListener("load", this._onSettle);
        this._img.removeEventListener("error", this._onSettle);
      }
      this._img = img || null;
      if (img) {
        img.addEventListener("load", this._onSettle);
        img.addEventListener("error", this._onSettle);
      }
    },

    _set(loading) {
      var self = this;
      if (loading) {
        if (this.el.dataset.state === "loading" || this._timer) return;
        this._timer = setTimeout(function() {
          self._timer = null;
          if (self._img && !self._img.complete) self._show(true);
        }, HIRES_SHOW_DELAY_MS);
      } else {
        clearTimeout(this._timer);
        this._timer = null;
        this._show(false);
      }
    },

    _show(on) {
      this.el.dataset.state = on ? "loading" : "idle";
      this.el.setAttribute("aria-hidden", on ? "false" : "true");
      if (this.el.style) this.el.style.opacity = on ? "1" : "0";
    }
  };

  // ============================================================================
  // UploadResume — keep picked files until the server has them
  // ============================================================================
  //
  // A transfer cut short — the page refreshed, the tab closed, the connection
  // dropped — used to take its files with it, and nothing said which. Every
  // file picked or dropped into a media browser is now copied into IndexedDB
  // the moment it is chosen, and the copy is dropped when the server says it
  // has the bytes (`phoenix_kit:upload-received`, pushed on receipt or on
  // rejection). Whatever is still here when a page loads is a transfer that
  // never finished: it is reported to the browser component, which lists it
  // with a Resume button; Resume pushes the keys back
  // (`phoenix_kit:upload-resume`) and the files are fed to the upload input
  // again, exactly as a drop would.
  //
  // Files over UPLOAD_STASH_MAX_BYTES keep their name but not their bytes —
  // a copy of a 2 GB video in the browser's storage is a worse failure than
  // asking for it again — and are listed as "add it again".
  //
  // Records are scoped to the page path (a library page resumes into that
  // library) and the signed-in user, and owned by the tab that made them: each tab keeps its live
  // records' `touched` fresh, so a second tab never mistakes another's
  // in-flight files for leftovers.
  // ----------------------------------------------------------------------------

  var UPLOAD_STASH_DB = "phoenix_kit_upload_stash";
  var UPLOAD_STASH_STORE = "files";
  var UPLOAD_STASH_MAX_BYTES = 250 * 1000 * 1000;
  var UPLOAD_STASH_STALE_MS = 15000;
  var UPLOAD_STASH_HEARTBEAT_MS = 5000;
  var UPLOAD_STASH_KEEP_MS = 7 * 24 * 3600 * 1000;

  // The same three things the server's `client_key/1` reads off an upload
  // entry — LiveView sends the File's own name, size and lastModified.
  function uploadStashKey(file) {
    return file.name + "|" + file.size + "|" + file.lastModified;
  }

  function uploadStashOpen() {
    return new Promise(function(resolve) {
      try {
        if (!window.indexedDB) return resolve(null);
        var req = window.indexedDB.open(UPLOAD_STASH_DB, 1);
        req.onupgradeneeded = function() {
          req.result.createObjectStore(UPLOAD_STASH_STORE, { keyPath: "id" });
        };
        req.onsuccess = function() { resolve(req.result); };
        req.onerror = function() { resolve(null); };
        req.onblocked = function() { resolve(null); };
      } catch (_) {
        resolve(null);
      }
    });
  }

  // One transaction; `fn(store)` does the work. Never rejects — the stash
  // is a safety net, and a browser refusing storage must not break uploads.
  function uploadStashRun(mode, fn) {
    return uploadStashOpen().then(function(db) {
      if (!db) return null;
      return new Promise(function(resolve) {
        try {
          var tx = db.transaction(UPLOAD_STASH_STORE, mode);
          var out = fn(tx.objectStore(UPLOAD_STASH_STORE));
          tx.oncomplete = function() { db.close(); resolve(out && out.result !== undefined ? out.result : out); };
          tx.onerror = tx.onabort = function() { db.close(); resolve(null); };
        } catch (_) {
          db.close();
          resolve(null);
        }
      });
    });
  }

  function uploadStashAll() {
    return uploadStashRun("readonly", function(store) { return store.getAll(); })
      .then(function(rows) { return rows || []; });
  }

  // Records are keyed by scope + file key, so the same picture picked on two
  // library pages is two records.
  function uploadStashId(scope, key) { return scope + "\u0000" + key; }

  window.PhoenixKitAdminHooks.UploadResume = {
    mounted() {
      var self = this;
      this._tab = Math.random().toString(36).slice(2) + Date.now().toString(36);
      // The path (a library page resumes into that library) and the user: the
      // stash holds file bytes, and the next person to sign in on this browser
      // must not be offered the last one's files.
      this._user = this.el.dataset.user || "";
      this._scopes = {};
      this._live = {};
      this._root = this.el.parentElement || document.body;

      // Capture phase on the browser's root: runs before LiveView's own
      // listener on the input reads (and the drop hook replaces) the files.
      this._onPick = function(e) {
        var input = e.target;
        if (!input || input.tagName !== "INPUT" || input.type !== "file") return;
        if (!input.hasAttribute("data-phx-upload-ref")) return;
        if (!input.files || !input.files.length) return;
        self._stash(Array.prototype.slice.call(input.files));
      };
      this._root.addEventListener("input", this._onPick, true);
      this._root.addEventListener("change", this._onPick, true);

      this._beat = setInterval(function() { self._heartbeat(); }, UPLOAD_STASH_HEARTBEAT_MS);
      this._rescan = null;

      this.handleEvent("phoenix_kit:upload-received", function(p) { self._forget(p.keys); });
      this.handleEvent("phoenix_kit:upload-discard", function(p) { self._forget(p.keys); });
      this.handleEvent("phoenix_kit:upload-resume", function(p) { self._resume(p.keys); });

      // A just-loaded page may still be restoring; give it a moment, then
      // report whatever an earlier page load left behind.
      this._scan = setTimeout(function() { self._reportLeftovers(false); }, 1500);
    },

    // A reconnect ends every transfer this tab had in flight — upload
    // channels do not survive it — so those are leftovers now, not live.
    reconnected() {
      this._reportLeftovers(true);
    },

    destroyed() {
      clearInterval(this._beat);
      clearTimeout(this._scan);
      clearTimeout(this._rescan);
      if (this._root) {
        this._root.removeEventListener("input", this._onPick, true);
        this._root.removeEventListener("change", this._onPick, true);
      }
    },

    // Where a file picked now belongs: the page's path (a library switch
    // patches the same LiveView, so it is read each time, not once), the folder
    // open in it, and the signed-in user. The stash holds file bytes, and the
    // next person to sign in on this browser must not be offered the last
    // one's files.
    _scopeNow() {
      var folder = "";
      try { folder = new URLSearchParams(window.location.search).get("folder") || ""; } catch (_) {}
      return window.location.pathname + "\u0000" + folder + "\u0000" + this._user;
    },

    // The scope a file was picked under — what the server's acknowledgement of
    // it names, even if the page has moved on to another library since.
    _scopeOf(key) {
      return this._scopes[key] || this._scopeNow();
    },

    _stash(files) {
      var self = this;
      var now = Date.now();
      files.forEach(function(file) {
        var key = uploadStashKey(file);
        var scope = self._scopeNow();
        self._live[key] = true;
        self._scopes[key] = scope;
        var keep = file.size <= UPLOAD_STASH_MAX_BYTES;
        uploadStashRun("readwrite", function(store) {
          store.put({
            id: uploadStashId(scope, key),
            key: key,
            scope: scope,
            name: file.name,
            type: file.type,
            size: file.size,
            lastModified: file.lastModified,
            blob: keep ? file : null,
            tab: self._tab,
            touched: now
          });
        });
      });
    },

    _heartbeat() {
      var self = this;
      var keys = Object.keys(this._live);
      if (!keys.length) return;
      var now = Date.now();
      uploadStashRun("readwrite", function(store) {
        keys.forEach(function(key) {
          var req = store.get(uploadStashId(self._scopeOf(key), key));
          req.onsuccess = function() {
            var row = req.result;
            if (row && row.tab === self._tab) { row.touched = now; store.put(row); }
          };
        });
      });
    },

    _forget(keys) {
      var self = this;
      var ids = (keys || []).map(function(key) { return uploadStashId(self._scopeOf(key), key); });
      (keys || []).forEach(function(key) { delete self._live[key]; delete self._scopes[key]; });
      uploadStashRun("readwrite", function(store) {
        ids.forEach(function(id) { store.delete(id); });
      });
    },

    // `mine`: this tab's own live records (after a reconnect). Otherwise:
    // records nobody has touched lately, from any earlier page load.
    _reportLeftovers(mine) {
      var self = this;
      var now = Date.now();
      uploadStashAll().then(function(rows) {
        var expired = [];
        var scope = self._scopeNow();
        var nextLook = null;
        var items = rows.filter(function(row) {
          if (now - row.touched > UPLOAD_STASH_KEEP_MS) { expired.push(row.id); return false; }
          if (row.scope !== scope) return false;
          if (mine) return row.tab === self._tab && self._live[row.key];
          if (row.tab === self._tab) return false;
          if (now - row.touched > UPLOAD_STASH_STALE_MS) return true;
          // Another page load's record that is still fresh: a refresh leaves
          // its records for the heartbeat to age out, so look again when this
          // one would be stale — it is either gone by then (its page finished)
          // or a leftover to offer.
          var wait = UPLOAD_STASH_STALE_MS - (now - row.touched) + 500;
          nextLook = nextLook === null ? wait : Math.min(nextLook, wait);
          return false;
        });
        if (nextLook !== null && !mine) {
          clearTimeout(self._rescan);
          self._rescan = setTimeout(function() { self._reportLeftovers(false); }, nextLook);
        }
        if (expired.length) {
          uploadStashRun("readwrite", function(store) { expired.forEach(function(id) { store.delete(id); }); });
        }
        if (mine) items.forEach(function(row) { delete self._live[row.key]; });
        if (!items.length) return;
        self.pushEventTo(self.el, "upload_resume_available", {
          items: items.map(function(row) {
            return { key: row.key, name: row.name, size: row.size, blob: !!row.blob };
          })
        });
      });
    },

    // Feed stashed files back to the upload input, the way the drop hook
    // does: a DataTransfer's FileList on the input, then the input event
    // LiveView listens for.
    _resume(keys) {
      var self = this;
      var want = {};
      (keys || []).forEach(function(key) { want[key] = true; });
      uploadStashAll().then(function(rows) {
        var files = rows
          .filter(function(row) { return row.scope === self._scopeNow() && want[row.key] && row.blob; })
          .map(function(row) {
            return new File([row.blob], row.name, { type: row.type, lastModified: row.lastModified });
          });
        if (!files.length) return;
        var input = self._root.querySelector("#folder-drop-upload-form input[type=file]") ||
                    self._root.querySelector("input[type=file][data-phx-upload-ref]");
        if (!input || typeof DataTransfer === "undefined") return;
        var dt = new DataTransfer();
        files.forEach(function(f) { dt.items.add(f); });
        input.files = dt.files;
        input.dispatchEvent(new Event("input", { bubbles: true }));
      });
    }
  };

  // ============================================================================
  // FolderDropUpload Hook — drag files from device to upload into current folder
  // ============================================================================

  window.PhoenixKitAdminHooks.FolderDropUpload = {
    mounted: function() {
      var self = this;
      var el = this.el;
      var dragCounter = 0;

      // The folder being shown paints its own upload outline
      // (`[data-drop-upload]`, MediaDragDrop); the ring here is for views
      // without one (all files).
      var ringed = function() { return !el.querySelector('[data-drop-upload="true"]'); };

      el.addEventListener("dragenter", function(e) {
        // Only respond to external file drags, not internal file-to-folder moves
        if (!e.dataTransfer.types.includes("Files")) return;
        e.preventDefault();
        dragCounter++;
        if (dragCounter === 1 && ringed()) {
          el.classList.add("ring-2", "ring-primary", "ring-dashed", "bg-primary/5");
        }
      });

      el.addEventListener("dragover", function(e) {
        if (!e.dataTransfer.types.includes("Files")) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = "copy";
      });

      el.addEventListener("dragleave", function(e) {
        // Counted like dragenter, Files only: a card dragged about the page
        // drove it negative and the next upload's ring never showed.
        if (!e.dataTransfer.types.includes("Files")) return;
        e.preventDefault();
        dragCounter = Math.max(0, dragCounter - 1);
        if (dragCounter === 0) {
          el.classList.remove("ring-2", "ring-primary", "ring-dashed", "bg-primary/5");
        }
      });

      el.addEventListener("drop", function(e) {
        // Ignore internal drags (file-to-folder moves) — only accept device files
        var files = e.dataTransfer.files;
        if (!files || files.length === 0) return;

        e.preventDefault();
        dragCounter = 0;
        el.classList.remove("ring-2", "ring-primary", "ring-dashed", "bg-primary/5");

        // Inject files directly into the hidden upload input (no modal)
        self._pendingFiles = files;
        self._injectFiles();
      });
    },

    _injectFiles: function() {
      var self = this;
      var attempts = 0;
      var maxAttempts = 20;

      function tryInject() {
        // Walk outward to the NEAREST scope containing an upload input.
        // This used to be a hard closest(".flex-1") hop, which silently
        // broke when a second flex-1 wrapper landed between the drop area
        // and the hidden upload form: closest() resolved to the inner
        // wrapper, found no input, and every OS drop no-opped after the
        // retry loop gave up. The walk also finds the drawer's own input
        // when the drawer is open (the hidden form only renders while it
        // is closed) — same upload, either input — and stays inside this
        // browser's subtree before it ever reaches the page.
        var uploadInput = null;
        for (var scope = self.el; scope && !uploadInput; scope = scope.parentElement) {
          uploadInput = scope.querySelector("[data-phx-upload-ref]");
        }
        if (uploadInput && self._pendingFiles) {
          var dt = new DataTransfer();
          for (var i = 0; i < self._pendingFiles.length; i++) {
            dt.items.add(self._pendingFiles[i]);
          }
          uploadInput.files = dt.files;
          uploadInput.dispatchEvent(new Event("input", { bubbles: true }));
          self._pendingFiles = null;
        } else if (attempts < maxAttempts) {
          attempts++;
          setTimeout(tryInject, 50);
        }
      }

      tryInject();
    }
  };

  // ---------------------------------------------------------------------------
  // StackExpand
  //
  // Stacks media view: when a folder "stack" is opened, its images fly out of
  // the pile into their grid slots (a FLIP animation). The hook sits on the
  // expanded section; on mount it finds the matching stack tile
  // ([data-stack-tile="<uuid>"]) and parks each card ([data-stack-card]) at the
  // stack's position scaled down, then releases them to their natural slots with
  // a per-card stagger. Inline styles are cleared afterwards so hover/selection
  // transforms aren't pinned. Respects prefers-reduced-motion; never throws.
  // ---------------------------------------------------------------------------
  // Persists which media stacks the user has open across refresh / navigation
  // away-and-back, in localStorage. On mount it pushes the saved open-set to
  // the LiveComponent (which reopens them); after every toggle/restore the
  // server echoes the authoritative open-set via "pk:stacks" and we persist
  // it. We persist from the server echo rather than reading the DOM because a
  // closing stack lingers briefly during its fly-back animation and would be
  // misread as still-open. Key is scoped per virtual-root so scoped browsers
  // remember independently.
  window.PhoenixKitAdminHooks.StackMemory = {
    mounted() {
      var key = this.el.dataset.storageKey;
      var self = this;
      var el = this.el;

      var reveal = function () {
        if (self._revealT) {
          clearTimeout(self._revealT);
          self._revealT = null;
        }
        el.style.visibility = "";
      };

      this.handleEvent("pk:stacks", function (payload) {
        try {
          localStorage.setItem(key, JSON.stringify((payload && payload.uuids) || []));
        } catch (e) {
          /* private mode / quota — degrade to no-memory */
        }
        // The restore round-trip has landed (server reopened the stacks) —
        // show the already-open view in one shot.
        reveal();
      });

      var saved = [];
      try {
        saved = JSON.parse(localStorage.getItem(key) || "[]");
      } catch (e) {
        saved = [];
      }
      if (Array.isArray(saved) && saved.length) {
        // Hide the stacks body before first paint so the user never sees the
        // closed state flash open. mounted() runs before the browser paints
        // the patch, so this suppresses the intermediate "stacks closed"
        // frame; we reveal once the server echoes the reopened set. A safety
        // timeout guarantees we never leave the view stuck hidden if the echo
        // never arrives.
        el.style.visibility = "hidden";
        self._revealT = setTimeout(reveal, 600);
        this.pushEventTo(this.el, "restore_stacks", { uuids: saved });
      }
    },
    destroyed() {
      if (this._revealT) clearTimeout(this._revealT);
    }
  };

  window.PhoenixKitAdminHooks.StackExpand = {
    mounted() {
      // Closing is driven client-side: the stack tile dispatches
      // "pk:close-stack", we play the fly-back, then tell the server to drop
      // the section. There's no phx-remove, so navigating away (opening a
      // media detail page) just leaves instantly with no animation or delay.
      this._onClose = function () {
        try {
          this.flyBack();
        } catch (e) {
          // If the animation can't run, still drop the section server-side.
          this._removeServerSide();
        }
      }.bind(this);
      this.el.addEventListener("pk:close-stack", this._onClose);

      // Only an explicitly-opened stack animates out of the pile. Restored
      // stacks (refresh / navigate-back) carry no data-animate-open, so they
      // appear instantly.
      if (this.el.dataset.animateOpen) {
        try {
          this.flyOut();
        } catch (e) {
          /* an animation must never break the page */
        }
      }
    },
    destroyed() {
      if (this._onClose) this.el.removeEventListener("pk:close-stack", this._onClose);
    },
    // Tell the LiveComponent to collapse this stack. The uuid is still in the
    // server's expanded list (the client animated first), so toggling removes
    // it. Runs after the fly-back so removal is seamless.
    _removeServerSide() {
      try {
        this.pushEventTo(this.el, "toggle_stack_expand", {
          "folder-uuid": this.el.dataset.stackFolder
        });
      } catch (e) {
        /* component may already be gone */
      }
    },
    // Shared geometry: the delta + scale to map a card to the stack pile.
    _toStack(card) {
      var folder = this.el.dataset.stackFolder;
      var stack = folder && document.querySelector('[data-stack-tile="' + folder + '"]');
      var sr = stack ? stack.getBoundingClientRect() : null;
      var cr = card.getBoundingClientRect();
      if (!sr) return { dx: 0, dy: -24, scale: 0.35 };
      return {
        dx: (sr.left + sr.width / 2) - (cr.left + cr.width / 2),
        dy: (sr.top + sr.height / 2) - (cr.top + cr.height / 2),
        scale: Math.max(0.18, Math.min(sr.width / Math.max(cr.width, 1), 0.6))
      };
    },
    // Reverse of flyOut: send each card back into the pile, collapse the
    // section, then ask the server to remove it. (No prefers-reduced-motion
    // animation, but we still remove it.)
    flyBack() {
      var self = this;
      var el = this.el;

      if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        self._removeServerSide();
        return;
      }

      var cards = Array.prototype.slice.call(el.querySelectorAll("[data-stack-card]"));
      cards.forEach(function (card) {
        var t = self._toStack(card);
        var i = parseInt(card.dataset.stackCard || "0", 10);
        var delay = Math.min(i, 16) * 18;
        card.style.transformOrigin = "center center";
        card.style.willChange = "transform, opacity";
        card.style.transition =
          "transform 420ms cubic-bezier(0.4,0,1,1) " + delay + "ms, " +
          "opacity 380ms ease " + delay + "ms";
        card.style.transform =
          "translate(" + t.dx + "px," + t.dy + "px) scale(" + t.scale + ")";
        card.style.opacity = "0";
      });

      // Once the images have retreated into the pile, collapse the section's
      // height + margin to 0 so the stacks/Everything-else below slide up
      // smoothly to fill the gap, instead of jumping when LiveView removes it.
      // Deferred so the cards (which fly up out of the box) aren't clipped.
      setTimeout(function () {
        var rect = el.getBoundingClientRect();
        var mt = window.getComputedStyle(el).marginTop;
        el.style.height = rect.height + "px";
        el.style.marginTop = mt;
        el.style.overflow = "hidden";
        el.getBoundingClientRect(); // commit the fixed height before transitioning
        el.style.transition =
          "height 320ms cubic-bezier(0.4,0,0.2,1), margin-top 320ms cubic-bezier(0.4,0,0.2,1)";
        el.style.height = "0px";
        el.style.marginTop = "0px";
      }, 320);

      // Once the cards have retreated and the section has collapsed, tell the
      // server to remove it (cards ~420ms+stagger, collapse 320ms@+320ms).
      setTimeout(function () {
        self._removeServerSide();
      }, 720);
    },
    flyOut() {
      if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        return;
      }

      var cards = Array.prototype.slice.call(this.el.querySelectorAll("[data-stack-card]"));
      if (!cards.length) return;

      var folder = this.el.dataset.stackFolder;
      var stack = folder && document.querySelector('[data-stack-tile="' + folder + '"]');
      var sr = stack ? stack.getBoundingClientRect() : null;

      // FIRST → INVERT: start every card at the stack's position, scaled down.
      cards.forEach(function (card) {
        var cr = card.getBoundingClientRect();
        var dx = 0;
        var dy = -24;
        var scale = 0.35;
        if (sr) {
          dx = (sr.left + sr.width / 2) - (cr.left + cr.width / 2);
          dy = (sr.top + sr.height / 2) - (cr.top + cr.height / 2);
          scale = Math.max(0.18, Math.min(sr.width / Math.max(cr.width, 1), 0.6));
        }
        card.style.transition = "none";
        card.style.transformOrigin = "center center";
        card.style.transform = "translate(" + dx + "px," + dy + "px) scale(" + scale + ")";
        card.style.opacity = "0";
        card.style.willChange = "transform, opacity";
      });

      // PLAY: next frame, release each card to its slot with a stagger.
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          cards.forEach(function (card) {
            var i = parseInt(card.dataset.stackCard || "0", 10);
            var delay = Math.min(i, 16) * 35;
            card.style.transition =
              "transform 460ms cubic-bezier(0.2,0.7,0.3,1) " + delay + "ms, " +
              "opacity 340ms ease " + delay + "ms";
            card.style.transform = "translate(0,0) scale(1)";
            card.style.opacity = "1";
          });
        });
      });

      // Clear inline styles once the last card settles, so hover / selection
      // transforms aren't pinned by the leftover inline transform.
      var last = cards[cards.length - 1];
      var cleanup = function (e) {
        if (e && e.propertyName && e.propertyName !== "transform") return;
        cards.forEach(function (card) {
          card.style.transition = "";
          card.style.transform = "";
          card.style.transformOrigin = "";
          card.style.willChange = "";
          card.style.opacity = "";
        });
        last.removeEventListener("transitionend", cleanup);
      };
      last.addEventListener("transitionend", cleanup);
      setTimeout(cleanup, 1300);
    }
  };

  // Interactive waveform for audio files. WaveSurfer is fetched via a lazy
  // dynamic import the first time an audio file is opened in the viewer, so it
  // costs nothing on any page without audio. It renders over the native <audio>
  // element (used as both playback source and fallback), giving click-to-seek,
  // a moving play cursor, a timeline, and zoom. If the library can't load, the
  // native <audio controls> still plays.
  //
  // The module is the host's vendored copy (same origin, so a strict CSP
  // and CORS are both satisfied), its URL resolved at runtime from the
  // install facts — never a string literal a bundler would try to resolve.
  window.PhoenixKitAdminHooks.WaveformPlayer = {
    mounted() {
      var el = this.el;
      var waveDiv = el.querySelector("[data-waveform]");
      var audioEl = el.querySelector("[data-waveform-audio]");
      var toggleBtn = el.querySelector("[data-waveform-toggle]");
      var playIcon = el.querySelector('[data-waveform-icon="play"]');
      var pauseIcon = el.querySelector('[data-waveform-icon="pause"]');
      if (!waveDiv || !audioEl) return;

      var self = this;
      self._ws = null;

      var showPlay = function (playing) {
        if (playIcon) playIcon.classList.toggle("hidden", playing);
        if (pauseIcon) pauseIcon.classList.toggle("hidden", !playing);
      };

      // Through the shared loader (a failure is recorded and reported); the
      // catch below keeps playback working.
      loadVendored("wavesurfer", "wavesurfer", { module: true })
        .then(function (mod) {
          if (self._destroyed) return;
          var WaveSurfer = mod.default;

          var ws = WaveSurfer.create({
            container: waveDiv,
            media: audioEl,
            height: 96,
            waveColor: "#94a3b8",
            progressColor: "#6366f1",
            cursorColor: "#4338ca",
            cursorWidth: 2,
            barWidth: 2,
            barGap: 1,
            barRadius: 2
          });
          self._ws = ws;

          ws.on("play", function () {
            showPlay(true);
          });
          ws.on("pause", function () {
            showPlay(false);
          });
          ws.on("finish", function () {
            showPlay(false);
          });

          if (toggleBtn) {
            toggleBtn.addEventListener("click", function () {
              try {
                ws.playPause();
              } catch (e) {
                /* not ready yet — ignore */
              }
            });
          }
        })
        .catch(function () {
          // Library unavailable (offline / CSP) — reveal the native controls so
          // playback still works, and hide the waveform + custom button.
          audioEl.controls = true;
          if (waveDiv) waveDiv.style.display = "none";
          if (toggleBtn) toggleBtn.style.display = "none";
        });
    },
    destroyed() {
      this._destroyed = true;
      try {
        if (this._ws) this._ws.destroy();
      } catch (e) {
        /* ignore */
      }
    }
  };


// SearchPicker — generic instant typeahead for "search a source, pick an
// entry" fields (extracted from phoenix_kit_crm's involved-parties picker).
// The dropdown is rendered and shown ENTIRELY client-side (opening, the
// optional "Add … as free text" row, spinners), so nothing visual waits on
// the server; the server only runs the actual search and returns rows via
// push_event. Rows: {kind, uuid, label, sublabel?, icon?}.
//
// Configured via data attributes on the input:
//   data-dropdown        id of the dropdown container (phx-update="ignore")
//   data-search-event    pushed as {q, limit}            (default "picker_search")
//   data-results-event   handleEvent name for rows       (default "picker_results";
//                        payload {q, results, has_more})
//   data-pick-event      pushed as {kind, uuid, label}   (default "picker_pick")
//   data-text-event      pushed as {name}; free-text row only renders when set
//   data-staged-event    handleEvent confirming a pick   (default "picker_staged")
//   data-search-on-focus when present, focusing/clicking the input runs a
//                        search immediately (empty query included) so the
//                        full list opens on click — suits short curated
//                        sources like locations
//   data-mode            "multi" (default) or "single" — single sets the
//                        input's value to the picked label client-side,
//                        dispatches an input event (so a surrounding form's
//                        phx-change sees it) and closes; no staging round-trip
//   data-t-*             translated strings (searching/add-prefix/add-suffix/
//                        adding/more/loading-more/no-matches)
(function () {
  function esc(s) {
    var d = document.createElement("div");
    d.textContent = s == null ? "" : String(s);
    return d.innerHTML;
  }
  function escAttr(s) {
    return esc(s).replace(/"/g, "&quot;");
  }

  // Stable identity for de-duplicating rows across "Load more" pages. The
  // server may send `dedup_id` (a PERSON identity that survives a row
  // changing source/kind between pages); otherwise fall back to kind:uuid.
  function dedupKey(r) {
    return r.dedup_id != null ? "d:" + r.dedup_id : r.kind + ":" + r.uuid;
  }

  window.PhoenixKitAdminHooks.SearchPicker = {
    mounted() {
      this.dd = document.getElementById(this.el.dataset.dropdown);
      this.target = this.el.dataset.target || this.el;
      this.mode = this.el.dataset.mode === "single" ? "single" : "multi";
      this.searchOnFocus = this.el.dataset.searchOnFocus != null;
      this.evSearch = this.el.dataset.searchEvent || "picker_search";
      this.evResults = this.el.dataset.resultsEvent || "picker_results";
      this.evPick = this.el.dataset.pickEvent || "picker_pick";
      this.evText = this.el.dataset.textEvent || null;
      this.evStaged = this.el.dataset.stagedEvent || "picker_staged";
      this.results = [];
      this.searching = false;
      this.limit = 8;
      this.hasMore = false;
      this.loadingMore = false;
      this.closeOnPick = this.el.dataset.closeOnPick != null;
      this.stacked = this.el.dataset.rowLayout === "stacked";
      // The list opens in the top layer where the Popover API exists, so an
      // overflow ancestor (a modal body) cannot clip it; the old absolute
      // positioning is the fallback.
      this.usePopover = typeof this.dd.showPopover === "function";
      // Whether the user is still asking for the list: results that arrive
      // after it was closed, or for a field nobody is in, are kept, not shown.
      this.wantOpen = false;
      this._place = () => {
        if (this._placeQueued) return;
        this._placeQueued = true;
        requestAnimationFrame(() => {
          this._placeQueued = false;
          this.place();
        });
      };
      this._dialog = this.el.closest("dialog");
      this._dialogClose = () => this.close();
      if (this._dialog) this._dialog.addEventListener("close", this._dialogClose);

      this.el.addEventListener("input", (e) => {
        if (e._pkPickerSynthetic) return;
        this.onInput();
      });
      this.el.addEventListener("keydown", (e) => this.onKeydown(e));
      // Focus moving to another element closes the list (and so drops a
      // late answer). Not when the whole window lost focus — the user is
      // coming back — and not when focus went into the list itself.
      this.el.addEventListener("blur", () => {
        setTimeout(() => {
          if (!document.hasFocus()) return;
          var active = document.activeElement;
          if (active === this.el || this.dd.contains(active)) return;
          this.close();
        }, 200);
      });
      this.el.addEventListener("focus", () => {
        // A close_on_pick picker refocuses its input after a pick; that
        // focus must not reopen the list.
        if (this._quiet) {
          this._quiet = false;
          return;
        }
        if (this.searchOnFocus) this.kickSearch();
        else if (this.el.value.trim()) {
          this.wantOpen = true;
          this.render();
        }
      });
      if (this.searchOnFocus) {
        this.el.addEventListener("click", () => {
          if (this.dd.classList.contains("hidden")) this.kickSearch();
        });
      }

      this._docClick = (e) => {
        if (!this.el.contains(e.target) && !this.dd.contains(e.target)) this.close();
      };
      document.addEventListener("click", this._docClick);

      // mousedown (not click) so a pick registers before the input's blur.
      // After a touch has been handled, the browser's late mouse events for
      // the same tap are ignored.
      this.dd.addEventListener("mousedown", (e) => {
        if (this._touchAt && Date.now() - this._touchAt < 800) {
          e.preventDefault();
          return;
        }
        this.onPick(e);
      });

      // Touch: pick when the finger lifts without having moved (a move is a
      // scroll of the list). On an iPhone with the keyboard up the tap's
      // mouse events arrive late and land on the input, so picking on
      // mousedown alone missed the first tap.
      this.dd.addEventListener(
        "touchstart",
        (e) => {
          var t = e.touches[0];
          this._touchStart = t ? { x: t.clientX, y: t.clientY } : null;
        },
        { passive: true },
      );
      this.dd.addEventListener("touchend", (e) => {
        var t = e.changedTouches[0];
        var s = this._touchStart;
        this._touchStart = null;
        if (!t || !s) return;
        if (Math.abs(t.clientX - s.x) > 10 || Math.abs(t.clientY - s.y) > 10) return;
        var target = document.elementFromPoint(t.clientX, t.clientY) || e.target;
        if (!target.closest || !target.closest("[data-pick]")) return;
        e.preventDefault();
        this._touchAt = Date.now();
        this.onPick({ target: target, preventDefault: function () {} });
      });

      this.handleEvent(this.evResults, (payload) => {
        // push_event broadcasts to every hook listening on this name — a
        // second picker sharing the event name would render our rows.
        // Servers echoing back the `id` we send get exact routing; the
        // check is skipped when absent for backwards compatibility.
        if (payload.id && payload.id !== this.el.id) return;
        if (this.stagingNow) return;
        if (this.el.value.trim() !== (payload.q || "")) return; // stale
        // Closed since the search went out (Escape, a pick, a click
        // elsewhere, or focus moved to another field — see the blur
        // listener): a slow answer must not reopen it.
        if (!this.wantOpen) return;
        var incoming = payload.results || [];

        if (this.loadingMore) {
          // "Load more" grows a per-source page, so a naive replace would
          // re-order the flattened list (new rows land BETWEEN sources) and
          // the user loses their place. APPEND only rows not already shown,
          // so everything on screen stays put and the new ones arrive at the
          // end. Dedup by `dedup_id` (a stable PERSON identity the server
          // sends) rather than kind+uuid, so a person whose row flips source
          // between pages (staff -> user once their user row enters the
          // window) isn't shown twice. Falls back to kind:uuid when the
          // server doesn't send dedup_id.
          var seen = {};
          this.results.forEach((r) => {
            seen[dedupKey(r)] = true;
          });
          incoming.forEach((r) => {
            if (!seen[dedupKey(r)]) {
              this.results.push(r);
              seen[dedupKey(r)] = true;
            }
          });
        } else {
          this.results = incoming;
        }

        this.hasMore = !!payload.has_more;
        this.searching = false;
        this.loadingMore = false;
        this.render();
      });

      this.handleEvent(this.evStaged, (payload) => {
        if (payload && payload.id && payload.id !== this.el.id) return;
        this.stagingNow = false;
        clearTimeout(this.stageT);
        this.clear();
      });
    },

    destroyed() {
      document.removeEventListener("click", this._docClick);
      if (this._dialog) this._dialog.removeEventListener("close", this._dialogClose);
      this.unfollow();
      if (this.usePopover && this.dd.matches && this.dd.matches(":popover-open")) {
        try {
          this.dd.hidePopover();
        } catch (_e) {}
      }
      clearTimeout(this.t);
      clearTimeout(this.stageT);
    },

    onInput() {
      var q = this.el.value.trim();
      if (!q && !this.searchOnFocus) {
        this.close();
        return;
      }
      this.wantOpen = true;
      this.searching = true;
      this.results = [];
      this.limit = 8;
      this.hasMore = false;
      this.loadingMore = false;
      this._restoreScroll = null;
      this.render();
      clearTimeout(this.t);
      this.t = setTimeout(() => this.search(q), 180);
    },

    search(q) {
      this.pushEventTo(this.target, this.evSearch, {
        q: q,
        limit: this.limit,
        id: this.el.id,
      });
    },

    kickSearch() {
      this.wantOpen = true;
      this.searching = true;
      this.results = [];
      this.limit = 8;
      this.hasMore = false;
      this.loadingMore = false;
      this._restoreScroll = null;
      this.render();
      clearTimeout(this.t);
      this.t = setTimeout(() => this.search(this.el.value.trim()), 100);
    },

    loadMore() {
      this.wantOpen = true;
      this.limit += 8;
      this.loadingMore = true;
      this._restoreScroll = this.scrollEl ? this.scrollEl.scrollTop : null;
      this.render();
      clearTimeout(this.t);
      this.search(this.el.value.trim());
    },

    onKeydown(e) {
      if (e.key === "Enter") {
        e.preventDefault();
        var q = this.el.value.trim();
        if (q && this.evText && this.mode !== "single") {
          this.pushEventTo(this.target, this.evText, { name: q, id: this.el.id });
          this.staging();
        }
      } else if (e.key === "Escape") {
        // Inside a <dialog>, Escape would also close the dialog; while the
        // list is open it closes only the list.
        if (this.isOpen()) {
          e.preventDefault();
          e.stopPropagation();
        }
        this.close();
      }
    },

    onPick(e) {
      var btn = e.target.closest("[data-pick]");
      if (!btn) return;
      e.preventDefault();
      if (btn.dataset.pick === "more") {
        this.loadMore();
        return;
      }
      if (this.mode === "single") {
        // client-side value set; a synthetic input event lets a surrounding
        // form's phx-change (and its server-side value mapping) see it
        this.el.value = btn.dataset.label || "";
        var ev = new Event("input", { bubbles: true });
        ev._pkPickerSynthetic = true;
        this.el.dispatchEvent(ev);
        this.close();
        return;
      }
      if (btn.dataset.pick === "text") {
        var q = this.el.value.trim();
        if (!q || !this.evText) return;
        this.pushEventTo(this.target, this.evText, { name: q, id: this.el.id });
      } else {
        this.pushEventTo(this.target, this.evPick, {
          kind: btn.dataset.kind,
          uuid: btn.dataset.uuid,
          label: btn.dataset.label,
          id: this.el.id,
        });
      }
      this.staging();
    },

    staging() {
      this.stagingNow = true;
      clearTimeout(this.t);
      var tAdding = esc(this.el.dataset.tAdding || "Adding…");
      this.dd.innerHTML =
        '<div class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/60">' +
        '<span class="loading loading-spinner loading-xs"></span>' +
        tAdding +
        "</div>";
      this.open();
      clearTimeout(this.stageT);
      this.stageT = setTimeout(() => {
        this.stagingNow = false;
        this.clear();
      }, 3000);
    },

    render() {
      var q = this.el.value.trim();
      if (!q && !this.searchOnFocus) {
        this.close();
        return;
      }
      var tSearching = esc(this.el.dataset.tSearching || "Searching…");
      var tAddPrefix = esc(this.el.dataset.tAddPrefix || "Add");
      var tAddSuffix = esc(this.el.dataset.tAddSuffix || "as text");
      var tMore = esc(this.el.dataset.tMore || "Load more");
      var tLoadingMore = esc(this.el.dataset.tLoadingMore || "Loading…");
      var tNoMatches = esc(this.el.dataset.tNoMatches || "No matches");

      var top = "";
      if (this.searching) {
        top +=
          '<div class="flex items-center gap-2 px-3 py-2 text-sm text-base-content/60 border-b border-base-200">' +
          '<span class="loading loading-spinner loading-xs"></span>' +
          tSearching +
          "</div>";
      }

      var list = "";
      this.results.forEach((r) => {
        if (this.stacked) {
          list +=
            '<button type="button" data-pick="result" data-kind="' +
            escAttr(r.kind) +
            '" data-uuid="' +
            escAttr(r.uuid) +
            '" data-label="' +
            escAttr(r.label) +
            '" class="flex items-start gap-2 w-full px-3 py-2 hover:bg-base-200 text-left cursor-pointer">' +
            '<span class="' +
            escAttr(r.icon || "hero-user") +
            ' w-4 h-4 shrink-0 mt-0.5 text-base-content/50"></span>' +
            '<span class="flex flex-col items-start min-w-0">' +
            '<span class="line-clamp-2 break-words">' +
            esc(r.label) +
            "</span>" +
            (r.sublabel
              ? '<span class="text-xs text-base-content/50 truncate max-w-full">' + esc(r.sublabel) + "</span>"
              : "") +
            "</span></button>";
          return;
        }
        list +=
          '<button type="button" data-pick="result" data-kind="' +
          escAttr(r.kind) +
          '" data-uuid="' +
          escAttr(r.uuid) +
          '" data-label="' +
          escAttr(r.label) +
          '" class="flex items-center justify-between w-full px-3 py-2 hover:bg-base-200 text-left cursor-pointer">' +
          '<span class="flex items-center gap-2 min-w-0">' +
          '<span class="' +
          escAttr(r.icon || "hero-user") +
          ' w-4 h-4 shrink-0 text-base-content/50"></span>' +
          '<span class="truncate">' +
          esc(r.label) +
          "</span></span>" +
          '<span class="text-xs text-base-content/50 shrink-0 ml-2 truncate">' +
          esc(r.sublabel || "") +
          "</span></button>";
      });
      if (!this.searching && !this.loadingMore && this.results.length === 0) {
        list +=
          '<div class="px-3 py-2 text-sm text-base-content/50">' + tNoMatches + "</div>";
      }
      if (this.loadingMore) {
        list +=
          '<div class="flex items-center justify-center gap-2 px-3 py-2 text-xs text-base-content/50">' +
          '<span class="loading loading-spinner loading-xs"></span>' +
          tLoadingMore +
          "</div>";
      } else if (this.hasMore) {
        list +=
          '<button type="button" data-pick="more" class="w-full px-3 py-2 text-xs text-center text-primary hover:bg-base-200 cursor-pointer">' +
          tMore +
          "</button>";
      }

      var bottom = "";
      if (q && this.evText && this.mode !== "single") {
        bottom =
          '<button type="button" data-pick="text" class="flex items-center gap-2 w-full px-3 py-2 hover:bg-base-200 text-left border-t border-base-200 cursor-pointer">' +
          '<span class="hero-plus-mini w-4 h-4 shrink-0 text-base-content/50"></span>' +
          "<span>" +
          tAddPrefix +
          ' "' +
          esc(q) +
          '" ' +
          tAddSuffix +
          "</span></button>";
      }

      this.dd.innerHTML =
        top + '<div data-scroll class="max-h-56 overflow-y-auto">' + list + "</div>" + bottom;

      this.scrollEl = this.dd.querySelector("[data-scroll]");
      if (this._restoreScroll != null && this.scrollEl) {
        this.scrollEl.scrollTop = this._restoreScroll;
        if (!this.loadingMore) this._restoreScroll = null;
      }
      this.open();
    },

    isOpen() {
      return !this.dd.classList.contains("hidden");
    },
    open() {
      var wasOpen = this.isOpen();
      this.dd.classList.remove("hidden");
      if (this.usePopover) {
        if (!this.dd.matches(":popover-open")) {
          try {
            this.dd.showPopover();
          } catch (_e) {
            this.usePopover = false;
          }
        }
        this.place();
        if (!wasOpen) this.follow();
      }
    },
    close() {
      this.wantOpen = false;
      this.dd.classList.add("hidden");
      this.dd.innerHTML = "";
      this.unfollow();
      if (this.usePopover && this.dd.matches(":popover-open")) {
        try {
          this.dd.hidePopover();
        } catch (_e) {}
      }
    },
    clear() {
      this.el.value = "";
      this.results = [];
      this.searching = false;
      this.stagingNow = false;
      clearTimeout(this.stageT);
      this.close();
      if (this.closeOnPick) this._quiet = true;
      this.el.focus();
    },

    // Places the top-layer list under (or over) the input, in viewport
    // coordinates. The visual viewport counts: with a phone keyboard up the
    // room below the field is what is left above the keyboard.
    place() {
      if (!this.usePopover || !this.isOpen()) return;
      var r = this.el.getBoundingClientRect();
      var vv = window.visualViewport;
      var viewBottom = vv ? vv.offsetTop + vv.height : window.innerHeight;
      var viewTop = vv ? vv.offsetTop : 0;
      if (r.bottom < viewTop || r.top > viewBottom) {
        this.close();
        return;
      }
      var below = viewBottom - r.bottom;
      var above = r.top - viewTop;
      var up = this.el.dataset.direction === "up" || (below < 180 && above > below);
      var style = this.dd.style;
      style.position = "fixed";
      style.margin = "0";
      style.inset = "auto";
      style.left = r.left + "px";
      style.width = r.width + "px";
      if (up) {
        style.top = "auto";
        style.bottom = window.innerHeight - r.top + 4 + "px";
      } else {
        style.bottom = "auto";
        style.top = r.bottom + 4 + "px";
      }
      var scroll = this.dd.querySelector("[data-scroll]");
      if (scroll) scroll.style.maxHeight = Math.max(Math.min(224, (up ? above : below) - 48), 80) + "px";
    },
    follow() {
      window.addEventListener("scroll", this._place, true);
      window.addEventListener("resize", this._place);
      if (window.visualViewport) {
        window.visualViewport.addEventListener("resize", this._place);
        window.visualViewport.addEventListener("scroll", this._place);
      }
    },
    unfollow() {
      window.removeEventListener("scroll", this._place, true);
      window.removeEventListener("resize", this._place);
      if (window.visualViewport) {
        window.visualViewport.removeEventListener("resize", this._place);
        window.visualViewport.removeEventListener("scroll", this._place);
      }
    },
  };
})();

// ---------------------------------------------------------------------------
// MentionInput — @ pings and # record links in any plain textarea.
//
// The surface this has to reach is ~70 ordinary `<textarea>` fields, not a
// rich editor, so this attaches to the field itself and owns nothing else.
// It watches for a trigger character at a word boundary, tracks the query
// the user types after it, asks the server, and renders a small list
// anchored under the caret.
//
// The server decides WHAT can be inserted; this decides only where the menu
// sits and when it closes. Everything it inserts is a complete token, so a
// half-typed mention is always just text.
//
// State is per-hook-instance, never global: several LiveViews can share a
// page, and two textareas on one page must not fight over one menu.
// ---------------------------------------------------------------------------
(function() {
  if (typeof window === "undefined") return;
  window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};

  // A trigger only counts at the start of a word. Without this, an email
  // address turns the rest of the line into a search box.
  function triggerAt(value, caret) {
    var i = caret - 1;
    while (i >= 0) {
      var ch = value[i];
      if (ch === "@" || ch === "#") {
        var before = i === 0 ? " " : value[i - 1];
        if (/[\s(\[]/.test(before) || i === 0) {
          return { char: ch, start: i, query: value.slice(i + 1, caret) };
        }
        return null;
      }
      // A query is one short run of ordinary characters. Newlines and the
      // token's own delimiters end it, so an unclosed menu can't swallow a
      // paragraph.
      if (/[\n\r\]|]/.test(ch)) return null;
      if (caret - i > 40) return null;
      i--;
    }
    return null;
  }

  // Where a character of the textarea's value sits, in pixels from the
  // field's top-left corner (scrolling already subtracted): a hidden mirror
  // with the field's own type and box metrics holds the text up to that
  // index and a marker span from there on, so the marker lands where the
  // character does. The menu opens under the `@`/`#` itself, not under the
  // whole field.
  var MIRROR_PROPS = [
    "boxSizing", "width", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
    "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth",
    "fontFamily", "fontSize", "fontWeight", "fontStyle", "fontVariant", "letterSpacing",
    "lineHeight", "textTransform", "wordSpacing", "textIndent", "tabSize", "textRendering"
  ];

  function charBox(el, index) {
    var cs = window.getComputedStyle(el);
    var mirror = document.createElement("div");
    MIRROR_PROPS.forEach(function(prop) { mirror.style[prop] = cs[prop]; });
    mirror.style.position = "absolute";
    mirror.style.visibility = "hidden";
    mirror.style.top = "0";
    mirror.style.left = "-9999px";
    mirror.style.height = "auto";
    mirror.style.overflow = "hidden";
    mirror.style.whiteSpace = "pre-wrap";
    mirror.style.overflowWrap = "break-word";
    mirror.setAttribute("aria-hidden", "true");
    mirror.textContent = el.value.slice(0, index);
    var marker = document.createElement("span");
    marker.textContent = el.value.slice(index) || ".";
    mirror.appendChild(marker);
    document.body.appendChild(mirror);
    var lineHeight = parseFloat(cs.lineHeight);
    var box = {
      top: marker.offsetTop + (parseFloat(cs.borderTopWidth) || 0) - el.scrollTop,
      left: marker.offsetLeft + (parseFloat(cs.borderLeftWidth) || 0) - el.scrollLeft,
      height: isNaN(lineHeight) ? marker.offsetHeight || 16 : lineHeight
    };
    document.body.removeChild(mirror);
    return box;
  }

  window.PhoenixKitAdminHooks.MentionInput = {
    mounted: function() {
      var self = this;
      this.el.setAttribute("autocomplete", "off");
      this.active = null;
      this.results = [];
      this.cursor = 0;
      this.seq = 0;

      this.menu = document.createElement("ul");
      this.menu.className =
        "pk-mention-menu menu menu-sm bg-base-100 rounded-box shadow-lg border border-base-300 " +
        "absolute z-[9999] hidden max-h-64 overflow-y-auto w-72 p-1";
      this.menu.setAttribute("role", "listbox");
      document.body.appendChild(this.menu);

      // A field inside an open <dialog> (a popup shown with showModal())
      // sits in the browser's top layer, which paints over everything
      // outside it whatever its z-index — a menu left on <body> is there,
      // open, and invisible behind the popup; and a modal dialog makes
      // everything outside it inert, so a top-layer popover on <body> is
      // painted but takes no click (measured in Chrome, 2026-10-05). The
      // menu therefore lives INSIDE the open dialog while the field is in
      // one, as a manual popover — the top layer paints it over the
      // dialog's own content, and as a dialog descendant it is not inert.
      // The dialog is LiveView's to patch, and a patch discards any node it
      // did not render: a MutationObserver puts the menu back the moment
      // that happens, before the frame is painted.
      this.popover = typeof this.menu.showPopover === "function";
      if (this.popover) {
        this.menu.setAttribute("popover", "manual");
        // The UA sheet centres a popover (inset: 0; margin: auto) and gives
        // it a border, padding and colours of its own.
        this.menu.style.inset = "auto";
        this.menu.style.margin = "0";
        this.menu.style.position = "fixed";
      }

      this.host = function() {
        var dialog = self.el.closest ? self.el.closest("dialog") : null;
        return dialog && dialog.open ? dialog : document.body;
      };

      this.mount = function() {
        var host = self.host();
        if (self.menu.parentNode !== host) host.appendChild(self.menu);
        // Viewport coordinates whenever the menu does not scroll with the
        // document: in the top layer, or inside a fixed dialog.
        self.fixed = self.popover || host !== document.body;
        if (!self.popover) self.menu.style.position = self.fixed ? "fixed" : "";
        self.observe(host);
      };

      this.observe = function(host) {
        if (self.observedHost === host) return;
        if (self.observer) self.observer.disconnect();
        self.observer = null;
        self.observedHost = host;
        if (host === document.body || typeof MutationObserver !== "function") return;
        self.observer = new MutationObserver(function() {
          if (!self.active || self.menu.parentNode === host || !host.isConnected) return;
          host.appendChild(self.menu);
          // Leaving the DOM closed the popover; back in, it reopens.
          self.show();
        });
        self.observer.observe(host, { childList: true });
      };

      this.show = function() {
        self.menu.classList.remove("hidden");
        if (self.popover && self.menu.isConnected !== false && !self.menu.matches(":popover-open")) {
          self.menu.showPopover();
        }
      };

      this.hide = function() {
        if (self.popover && self.menu.matches(":popover-open")) self.menu.hidePopover();
        self.menu.classList.add("hidden");
      };

      this.close = function() {
        self.active = null;
        self.results = [];
        self.cursor = 0;
        self.hide();
      };

      this.render = function() {
        if (!self.active || !self.results.length) {
          self.hide();
          return;
        }
        self.menu.innerHTML = "";
        self.results.forEach(function(r, idx) {
          var li = document.createElement("li");
          var a = document.createElement("a");
          a.className = idx === self.cursor ? "active" : "";
          a.setAttribute("role", "option");
          var title = document.createElement("span");
          title.className = "font-medium truncate";
          title.textContent = r.title;
          a.appendChild(title);
          if (r.subtitle) {
            var sub = document.createElement("span");
            sub.className = "text-xs opacity-60 truncate";
            sub.textContent = r.subtitle;
            a.appendChild(sub);
          }
          // mousedown, not click: click fires after blur, and blur has
          // already closed the menu by then.
          a.addEventListener("mousedown", function(e) {
            e.preventDefault();
            self.choose(idx);
          });
          li.appendChild(a);
          self.menu.appendChild(li);
        });
        // Shown first, so the menu has a size to place.
        self.mount();
        self.show();
        self.position();
      };

      // The trigger character's box in the field — overridable, so the
      // placement arithmetic can be exercised without a layout engine.
      this.anchor = function() {
        var index = self.active ? self.active.start : self.el.selectionStart || 0;
        return charBox(self.el, index);
      };

      // Under the `@`/`#` the user typed: its line's bottom, its column —
      // kept inside the field's width and the viewport, and flipped above
      // the line when there is no room below.
      this.position = function() {
        self.mount();
        var rect = self.el.getBoundingClientRect();
        var box = self.anchor();
        var scrollY = self.fixed ? 0 : window.scrollY;
        var scrollX = self.fixed ? 0 : window.scrollX;
        var viewportWidth = document.documentElement.clientWidth;
        var viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
        var width = self.menu.offsetWidth || 0;
        var height = self.menu.offsetHeight || 0;

        var lineTop = rect.top + Math.max(0, Math.min(box.top, rect.height - box.height));
        var top = lineTop + box.height + 2;
        if (viewportHeight && top + height > viewportHeight - 8 && lineTop - height - 2 >= 8) {
          top = lineTop - height - 2;
        }
        var left = rect.left + Math.max(0, Math.min(box.left, rect.width));
        var maxLeft = viewportWidth - width - 8;

        self.menu.style.top = top + scrollY + "px";
        self.menu.style.left = Math.max(8, Math.min(left, maxLeft)) + scrollX + "px";
      };

      this.choose = function(idx) {
        var r = self.results[idx];
        if (!r || !self.active) return;
        var value = self.el.value;
        var before = value.slice(0, self.active.start);
        var after = value.slice(self.el.selectionStart);
        // The server sends the finished token: building it here by
        // concatenation produced something unparseable whenever a
        // record's own name contained a `|` or a `]`.
        var token = r.token;
        if (!token) return;
        self.el.value = before + token + " " + after;
        var caret = (before + token + " ").length;
        self.el.setSelectionRange(caret, caret);
        self.close();
        // The field is inside a phx-change form; without this the server
        // never sees the inserted token and the next save writes the old
        // text back over it.
        self.el.dispatchEvent(new Event("input", { bubbles: true }));
        self.el.focus();
      };

      // The page's context for the search, from `data-mention-context`;
      // null when the field carries none or the JSON is broken.
      this.context = function() {
        var raw = self.el.dataset ? self.el.dataset.mentionContext : null;
        if (!raw) return null;
        try {
          var parsed = JSON.parse(raw);
          return parsed && typeof parsed === "object" ? parsed : null;
        } catch (_e) {
          return null;
        }
      };

      this.search = function() {
        var caret = self.el.selectionStart;
        var found = triggerAt(self.el.value, caret);
        if (!found) {
          self.close();
          return;
        }
        self.active = found;
        self.seq += 1;
        var seq = self.seq;
        self.pushEvent(
          "pk_mention_search",
          {
            kind: found.char === "@" ? "user" : "resource",
            query: found.query,
            seq: seq,
            // Where the field is: `data-mention-context` (JSON) names the
            // record the page is about, so a `#` offers what belongs with
            // it rather than everything the viewer may see.
            context: self.context()
          },
          function(reply) {
            // Out-of-order replies: the user kept typing while this one was
            // in flight, so its results describe a query that no longer
            // exists. Dropping them stops the list flickering backwards.
            if (!reply || reply.seq !== self.seq) return;
            self.results = reply.results || [];
            self.cursor = 0;
            self.render();
          }
        );
      };

      this.onInput = function() { self.search(); };

      this.onKeyDown = function(e) {
        if (!self.active || !self.results.length) {
          if (e.key === "Escape") self.close();
          return;
        }
        if (e.key === "ArrowDown") {
          e.preventDefault();
          self.cursor = (self.cursor + 1) % self.results.length;
          self.render();
        } else if (e.key === "ArrowUp") {
          e.preventDefault();
          self.cursor = (self.cursor - 1 + self.results.length) % self.results.length;
          self.render();
        } else if (e.key === "Enter" || e.key === "Tab") {
          e.preventDefault();
          self.choose(self.cursor);
        } else if (e.key === "Escape") {
          e.preventDefault();
          self.close();
        }
      };

      this.onBlur = function() { window.setTimeout(self.close, 120); };

      this.el.addEventListener("input", this.onInput);
      this.el.addEventListener("click", this.onInput);
      this.el.addEventListener("keydown", this.onKeyDown);
      this.el.addEventListener("blur", this.onBlur);
      this.repositionHandler = function() { if (self.active) self.position(); };
      window.addEventListener("scroll", this.repositionHandler, true);
      window.addEventListener("resize", this.repositionHandler);
    },

    destroyed: function() {
      // The menu lives on document.body, so it outlives the hook's element
      // unless it is taken down explicitly — a LiveView patch that replaces
      // the textarea would otherwise leave an orphan floating over the page.
      if (this.observer) this.observer.disconnect();
      if (this.menu && this.hide) this.hide();
      if (this.menu && this.menu.parentNode) this.menu.parentNode.removeChild(this.menu);
      window.removeEventListener("scroll", this.repositionHandler, true);
      window.removeEventListener("resize", this.repositionHandler);
    }
  };
})();


// ============================================================================
// UploadStats - live transfer stats under upload progress bars
// ============================================================================
//
// Attached to a text element rendered next to a LiveView upload entry's
// progress bar. The server only patches `data-progress` (0-100); everything
// shown is computed in the browser, so the numbers reflect the network as the
// user experiences it:
//
//   uploading:   "3.2 MB / 12.4 MB · 2.8 MB/s · 4s left"
//   at 100%:     "12.4 MB · Processing on server… 3s"   (tick continues while
//                the server consumes the entry and the bar sits frozen)
//
// Markup contract: id (required for hooks), data-progress={entry.progress},
// data-size={entry.client_size}, plus gettext'd labels in
// data-label-processing / data-label-left. The hook owns the element's text.
(function() {
  "use strict";

  // Decimal units, matching the Elixir-side Format.bytes(base: 1000) used in
  // the media file listings.
  function formatBytes(n) {
    if (!isFinite(n) || n < 0) n = 0;
    if (n < 1000) return Math.round(n) + " B";
    var units = ["KB", "MB", "GB", "TB"];
    var v = n;
    for (var i = 0; i < units.length; i++) {
      v = v / 1000;
      if (v < 1000 || i === units.length - 1) {
        return (v >= 100 ? String(Math.round(v)) : v.toFixed(1)) + " " + units[i];
      }
    }
  }

  function formatDuration(ms) {
    var s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return s + "s";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m " + (s % 60) + "s";
    var h = Math.floor(m / 60);
    return h + "h " + (m % 60) + "m";
  }

  // Transfer rate in bytes/sec over a trailing window. `samples` is an
  // ordered list of {t (ms), bytes} pairs. The denominator ends at `now`,
  // not at the last sample, so a stalled transfer decays toward 0 instead
  // of freezing at its last good speed.
  function windowSpeed(samples, now, windowMs) {
    windowMs = windowMs || 5000;
    if (!samples || samples.length < 2) return 0;
    var latest = samples[samples.length - 1];
    var cutoff = now - windowMs;
    // Baseline: the newest sample before `latest` that falls outside the
    // window (anchors the span as the window slides), or the oldest sample
    // we still hold. Never `latest` itself — during a hard stall every
    // sample is old, and the span must still run from real data to `now`
    // so the rate decays rather than snapping to 0.
    var base = latest;
    for (var i = samples.length - 2; i >= 0; i--) {
      base = samples[i];
      if (samples[i].t < cutoff) break;
    }
    if (base === latest) return 0;
    var seconds = (now - base.t) / 1000;
    if (seconds <= 0) return 0;
    return Math.max(0, (latest.bytes - base.bytes) / seconds);
  }

  // The whole line as a pure function of the tracked state (node-testable).
  function uploadStatsText(opts) {
    var labels = opts.labels || {};
    if (opts.doneAt != null) {
      var label = labels.processing || "Processing on server…";
      return formatBytes(opts.size) + " · " + label + " " +
        formatDuration(opts.now - opts.doneAt);
    }
    var parts = [formatBytes(opts.bytes) + " / " + formatBytes(opts.size)];
    var speed = windowSpeed(opts.samples, opts.now);
    if (speed > 0) {
      parts.push(formatBytes(speed) + "/s");
      var etaMs = (Math.max(0, opts.size - opts.bytes) / speed) * 1000;
      if (isFinite(etaMs)) parts.push(formatDuration(etaMs) + " " + (labels.left || "left"));
    }
    return parts.join(" · ");
  }

  window.PhoenixKitAdminHooks.UploadStats = {
    mounted() {
      this.size = parseInt(this.el.dataset.size || "0", 10) || 0;
      this.samples = [];
      this.bytes = 0;
      this.doneAt = null;
      this.sample();
      var self = this;
      // The interval keeps elapsed/ETA moving between LiveView patches —
      // that is what makes a stall or a long server phase visibly tick.
      this.timer = setInterval(function() { self.render(); }, 500);
      this.render();
    },

    updated() {
      this.sample();
      this.render();
    },

    sample() {
      var progress = parseFloat(this.el.dataset.progress || "0") || 0;
      var now = Date.now();
      this.bytes = Math.round(this.size * Math.min(progress, 100) / 100);
      if (progress >= 100 && this.doneAt == null) this.doneAt = now;
      var last = this.samples[this.samples.length - 1];
      if (!last || last.bytes !== this.bytes) {
        this.samples.push({ t: now, bytes: this.bytes });
        // Progress events arrive per chunk; keep enough to cover the speed
        // window at any realistic event rate without growing unbounded.
        if (this.samples.length > 128) this.samples.shift();
      }
    },

    render() {
      this.el.textContent = uploadStatsText({
        size: this.size,
        bytes: this.bytes,
        samples: this.samples,
        now: Date.now(),
        doneAt: this.doneAt,
        labels: {
          processing: this.el.dataset.labelProcessing,
          left: this.el.dataset.labelLeft
        }
      });
    },

    destroyed() {
      clearInterval(this.timer);
    }
  };

  if (typeof module === "object" && module.exports) {
    module.exports.formatBytes = formatBytes;
    module.exports.formatDuration = formatDuration;
    module.exports.windowSpeed = windowSpeed;
    module.exports.uploadStatsText = uploadStatsText;
  }
})();

// ============================================================================
// UploadGuard - native leave-page guard while uploads are in flight
// ============================================================================
//
// Attached to an upload component's root. The server patches
// `data-active` ("true" while any upload entry exists); while active, the
// browser's own beforeunload dialog blocks an accidental refresh / tab
// close that would kill the transfer (interrupted LiveView uploads are not
// resumed). This replaces disclaimer prose with actual protection. Note it
// guards full page unloads only — LiveView patch/navigate stays free.
(function() {
  "use strict";

  window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};

  window.PhoenixKitAdminHooks.UploadGuard = {
    mounted() {
      var self = this;
      this.handler = function(e) {
        if (self.el.dataset.active === "true") {
          e.preventDefault();
          // Chrome requires returnValue to show the dialog; the text is
          // browser-controlled either way.
          e.returnValue = "";
        }
      };
      window.addEventListener("beforeunload", this.handler);
    },

    destroyed() {
      window.removeEventListener("beforeunload", this.handler);
    }
  };
})();


// ============================================================================
// CONTEXT MENU HOOK
// ============================================================================
//
// Desktop-style context menu: right-click (or touch-and-hold) an element the
// menu selects, and an action menu opens at the pointer.
//
// One menu element serves every row it matches — a tree of five hundred nodes
// renders one hidden <ul>, not five hundred. On open the hook finds the row
// under the pointer, copies its identifier onto every item's `phx-value-*`,
// and positions the menu. Opening costs no round-trip; the event fired
// afterwards still carries the right target.
//
// Config comes from data attributes on the hook element (see the
// Core.ContextMenu component):
//   data-context-selector       CSS selector for the rows
//   data-context-within         optional container selector
//   data-context-value-attr     row attribute holding the identifier
//   data-context-value-name     stamped as phx-value-<name>
//   data-context-label-attr     row attribute holding the menu heading
//   data-context-long-press     "false" disables the touch gesture
//   data-context-long-press-ms  hold duration, default 450
//
(function() {
  "use strict";

  window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};

  // Every mounted menu registers here and one document-level listener serves
  // them all. That is what lets a right-click matched by two menus (a note row
  // nested inside a folder row) pick the DEEPEST match instead of letting DOM
  // order decide it.
  var menus = [];
  var listening = false;
  var openMenu = null;

  // Android fires a native `contextmenu` at the end of a long press, on top of
  // our own timer. Remember when we opened so the native one is swallowed
  // rather than reopening (and re-vibrating).
  var lastLongPressAt = 0;
  // The release after a long press dispatches a click on the row. Eat it, or
  // holding a row also activates it.
  var swallowClick = false;

  var MOVE_TOLERANCE = 10;
  var NATIVE_MENU_GRACE_MS = 800;
  var SWALLOW_CLICK_MS = 700;

  function depthOf(el) {
    var d = 0;
    while ((el = el.parentElement)) d++;
    return d;
  }

  // Where a menu of w x h opens for a pointer at (x, y) in a vw x vh viewport.
  // Down-right of the pointer by default; flips to the other side of it rather
  // than overflowing, then clamps for a menu too big to fit either way.
  //
  // One implementation, shared with RowMenu's right-click path
  // (`window.PhoenixKitMenus.pointerPosition`, defined in the hooks IIFE
  // above): a right-click menu and a row menu opened by right-click must land
  // in the same place, and a second copy of this arithmetic would drift.
  // Still a local name, and still exported, so test/js/context_menu.test.cjs
  // exercises the shared rule.
  function contextMenuPosition(x, y, w, h, vw, vh) {
    return window.PhoenixKitMenus.pointerPosition(x, y, w, h, vw, vh);
  }

  function rowFor(menu, target) {
    if (!target || !target.closest) return null;
    var row = target.closest(menu.selector);
    if (!row) return null;
    if (menu.within) {
      // closest(), not querySelector(): a class-based `within` routinely
      // matches several containers, and taking only the first left rows in
      // the others with no menu at all.
      if (!row.closest(menu.within)) return null;
    }
    return row;
  }

  function bestMatch(target) {
    var best = null;
    for (var i = 0; i < menus.length; i++) {
      var row = rowFor(menus[i], target);
      if (!row) continue;
      var d = depthOf(row);
      if (!best || d > best.depth) best = { menu: menus[i], row: row, depth: d };
    }
    return best;
  }

  function closeOpen() {
    if (openMenu) openMenu._close();
  }

  // ---- long press (touch/pen only — a mouse gets `contextmenu`) ------------

  var lpTimer = null, lpX = 0, lpY = 0, swallowTimer = null;

  function cancelLongPress() {
    if (lpTimer) { clearTimeout(lpTimer); lpTimer = null; }
  }

  function onPointerDown(e) {
    if (e.pointerType === "mouse") return;
    var m = bestMatch(e.target);
    if (!m || !m.menu.longPress) return;
    lpX = e.clientX;
    lpY = e.clientY;
    cancelLongPress();
    lpTimer = setTimeout(function() {
      lpTimer = null;
      // The hook may have been destroyed during the press (a patch, a stream
      // reset). Opening now would append a detached menu to <body> and leave
      // it there.
      if (menus.indexOf(m.menu) === -1) return;
      lastLongPressAt = Date.now();
      swallowClick = true;
      // Cleared on the click too; this is the backstop for a release that
      // dispatches no click at all, which would otherwise eat the user's
      // next tap (the menu item they came for). Tracked, so a second long
      // press inside the window cannot have its flag cleared by the first
      // press's backstop.
      if (swallowTimer) clearTimeout(swallowTimer);
      swallowTimer = setTimeout(function() {
        swallowTimer = null;
        swallowClick = false;
      }, SWALLOW_CLICK_MS);
      if (navigator.vibrate) { try { navigator.vibrate(30); } catch (_) {} }
      m.menu._open(m.row, lpX, lpY);
    }, m.menu.longPressMs);
  }

  function onPointerMove(e) {
    if (!lpTimer) return;
    if (Math.abs(e.clientX - lpX) > MOVE_TOLERANCE ||
        Math.abs(e.clientY - lpY) > MOVE_TOLERANCE) {
      cancelLongPress();
    }
  }

  // ---- document listeners --------------------------------------------------

  function onContextMenu(e) {
    cancelLongPress();
    if (openMenu && Date.now() - lastLongPressAt < NATIVE_MENU_GRACE_MS) {
      // Our own menu is already open from the long press. Gated on openMenu:
      // if it was dismissed (Escape) the grace window must not go on
      // suppressing the browser's menu with nothing shown in its place.
      e.preventDefault();
      return;
    }
    var m = bestMatch(e.target);
    if (!m) {
      // No row here. A `contextmenu` produces no click, and the mouse path
      // arms no long press, so nothing else would take the open menu down —
      // it would sit under the browser's native one.
      closeOpen();
      return;
    }
    e.preventDefault();
    m.menu._open(m.row, e.clientX, e.clientY);
  }

  // Capture phase, so this runs before an item's own click handler.
  function onDocClick(e) {
    if (swallowClick) {
      swallowClick = false;
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    if (!openMenu) return;
    // Tested against the menu element, not the hook element: the menu is
    // portaled to <body> while open, so it is no longer a descendant of the
    // hook. Treating an item click as "outside" would close the menu and move
    // it mid-dispatch — WebKit then drops the in-flight click and the item's
    // action never runs.
    if (!openMenu.menuEl.contains(e.target)) openMenu._close();
  }

  function onKeydown(e) {
    if (!openMenu) return;
    if (e.key === "Escape") {
      e.preventDefault();
      openMenu._close();
      return;
    }
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      var items = Array.prototype.slice.call(
        openMenu.menuEl.querySelectorAll("[role='menuitem']:not([disabled])")
      );
      if (items.length === 0) return;
      var idx = items.indexOf(document.activeElement);
      var next = e.key === "ArrowDown"
        ? (idx + 1) % items.length
        : (idx - 1 + items.length) % items.length;
      items[next].focus();
    }
  }

  function install() {
    if (listening) return;
    listening = true;
    document.addEventListener("contextmenu", onContextMenu);
    // Permanent, not tied to a menu being open: the post-long-press click has
    // to be swallowed even when the menu was closed again in between (Escape,
    // a scroll, an Android resize), or the row underneath activates — the very
    // thing the swallow exists to prevent. onDocClick no-ops when idle.
    document.addEventListener("click", onDocClick, true);
    document.addEventListener("pointerdown", onPointerDown, true);
    document.addEventListener("pointermove", onPointerMove, true);
    document.addEventListener("pointerup", cancelLongPress, true);
    document.addEventListener("pointercancel", cancelLongPress, true);
  }

  // ---- the hook ------------------------------------------------------------

  window.PhoenixKitAdminHooks.ContextMenu = {
    mounted() {
      this.menuEl = this.el.querySelector("[data-context-menu-content]");
      if (!this.menuEl) return;
      this.labelEl = this.menuEl.querySelector("[data-context-menu-label]");
      this.isOpen = false;

      // Where the menu lives when closed, so it can be put back — LiveView's
      // diff patching has to find it there on the next update.
      this._homeParent = this.menuEl.parentNode;
      this._homeNextSibling = this.menuEl.nextSibling;

      this._readConfig();

      this._onMenuClick = () => { this._close(); };
      this.menuEl.addEventListener("click", this._onMenuClick);

      menus.push(this);
      install();
    },

    updated() {
      this._readConfig();
      // While open the menu is portaled to <body>, so morphdom re-creates a
      // duplicate in the wrapper. Drop it: the portaled node is the one
      // carrying the current stamps.
      if (this.isOpen) {
        var dup = this.el.querySelector("[data-context-menu-content]");
        if (dup && dup !== this.menuEl) dup.remove();
      }
    },

    destroyed() {
      // Cancel first: the pending timer captured this menu, so without it a
      // press in flight would open a detached menu into <body> 450ms later.
      cancelLongPress();
      this._close();
      if (this.menuEl && this._onMenuClick) {
        this.menuEl.removeEventListener("click", this._onMenuClick);
      }
      var i = menus.indexOf(this);
      if (i !== -1) menus.splice(i, 1);
    },

    _readConfig() {
      var d = this.el.dataset;
      this.selector = d.contextSelector;
      this.within = d.contextWithin || null;
      this.valueAttr = d.contextValueAttr || "data-context-value";
      // Comma-separated: a menu whose items were written against handlers that
      // spell the param differently ("folder-uuid" for one, "folder_uuid" for
      // another) stamps both rather than making the consumer add a shim clause.
      this.valueNames = (d.contextValueName || "uuid")
        .split(",")
        .map(function(n) { return n.trim(); })
        .filter(Boolean);
      this.labelAttr = d.contextLabelAttr || null;
      this.longPress = d.contextLongPress !== "false";
      this.longPressMs = parseInt(d.contextLongPressMs, 10) || 450;
    },

    // Copy the row's identifier onto every item, so the event a click fires
    // names the row that was right-clicked. LiveView reads `phx-value-*` off
    // the clicked element at click time, which is after this runs.
    _stamp(row) {
      var value = row.getAttribute(this.valueAttr);
      var items = this.menuEl.querySelectorAll("[role='menuitem']");
      for (var i = 0; i < items.length; i++) {
        for (var n = 0; n < this.valueNames.length; n++) {
          var name = "phx-value-" + this.valueNames[n];
          if (value === null) items[i].removeAttribute(name);
          else items[i].setAttribute(name, value);
        }
      }

      if (this.labelEl) {
        var label = this.labelAttr ? row.getAttribute(this.labelAttr) : null;
        if (label) {
          this.labelEl.textContent = label;
          this.labelEl.classList.remove("hidden");
        } else {
          this.labelEl.classList.add("hidden");
        }
      }
    },

    _open(row, x, y) {
      if (openMenu && openMenu !== this) openMenu._close();

      this._stamp(row);

      // Portal to <body> before measuring: inside a <dialog> or any ancestor
      // with transform/contain/filter, `position: fixed` resolves against that
      // ancestor rather than the viewport, and the menu lands off-screen.
      if (this.menuEl.parentNode !== document.body) {
        document.body.appendChild(this.menuEl);
      }
      this.menuEl.classList.remove("hidden");

      var pos = contextMenuPosition(
        x,
        y,
        this.menuEl.offsetWidth || 176,
        this.menuEl.offsetHeight || 200,
        window.innerWidth,
        window.innerHeight
      );
      this.menuEl.style.left = pos.left + "px";
      this.menuEl.style.top = pos.top + "px";

      this.isOpen = true;
      openMenu = this;

      document.addEventListener("keydown", onKeydown);
      document.addEventListener("scroll", closeOpen, true);
      window.addEventListener("resize", closeOpen);

      var first = this.menuEl.querySelector("[role='menuitem']");
      if (first) first.focus();
    },

    _close() {
      if (!this.isOpen) return;
      this.menuEl.classList.add("hidden");
      this.isOpen = false;
      if (openMenu === this) openMenu = null;

      document.removeEventListener("keydown", onKeydown);
      document.removeEventListener("scroll", closeOpen, true);
      window.removeEventListener("resize", closeOpen);

      // Put the menu back where the server rendered it, or morphdom sees a
      // missing element, re-creates it, and the next open finds a stale node.
      if (this._homeParent && this.menuEl.parentNode !== this._homeParent) {
        if (this._homeNextSibling && this._homeNextSibling.parentNode === this._homeParent) {
          this._homeParent.insertBefore(this.menuEl, this._homeNextSibling);
        } else {
          this._homeParent.appendChild(this.menuEl);
        }
      }
    }
  };

  if (typeof module === "object" && module.exports) {
    module.exports.contextMenuPosition = contextMenuPosition;
  }
})();

// ---------------------------------------------------------------------------
// AvatarCrop — the non-destructive avatar crop editor.
//
// The crop is data (focal point x/y, zoom, aspect ratio), applied as CSS by
// the server-rendered avatar component; this hook is only the editor for
// those four numbers. Drag pans the focal point, the slider and the wheel
// zoom toward it, and the end of every gesture pushes the current values to
// the owning LiveComponent (the element carries phx-target) so "Save"
// persists exactly what the preview shows.
//
// avatarCropLayout mirrors PhoenixKit.Users.AvatarCrop.layout/1 — the
// preview must use the same math the avatar later renders with, or the
// saved crop drifts from what the person approved. Change one, change both.
// ---------------------------------------------------------------------------
(function () {
  if (window.PhoenixKitAvatarCrop) return;
  window.PhoenixKitAvatarCrop = true;
  window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};

  function clamp(v, lo, hi) {
    return Math.min(hi, Math.max(lo, v));
  }

  // The image's placement inside its square frame, in percent of the frame.
  // Mirror of PhoenixKit.Users.AvatarCrop.layout/1.
  function avatarCropLayout(crop) {
    var zoom = crop.zoom;
    var ar = crop.ar;
    var width, height;
    if (ar >= 1) {
      width = 100 * zoom * ar;
      height = 100 * zoom;
    } else {
      width = 100 * zoom;
      height = (100 * zoom) / ar;
    }
    return {
      width: width,
      height: height,
      left: clamp(50 - crop.x * width, 100 - width, 0),
      top: clamp(50 - crop.y * height, 100 - height, 0)
    };
  }

  // Focal coordinates that would render clamped are snapped back into the
  // reachable range, so a drag never has a dead zone at the edges: with the
  // image W% wide, the frame center can only sit between 50/W and 1 - 50/W
  // of the image (the whole axis collapses to 0.5 when the image just fits).
  function clampAvatarCropFocal(crop) {
    var l = avatarCropLayout(crop);
    var x = l.width <= 100 ? 0.5 : clamp(crop.x, 50 / l.width, 1 - 50 / l.width);
    var y = l.height <= 100 ? 0.5 : clamp(crop.y, 50 / l.height, 1 - 50 / l.height);
    return { x: x, y: y, zoom: crop.zoom, ar: crop.ar };
  }

  window.PhoenixKitAdminHooks.AvatarCrop = {
    mounted() {
      var self = this;
      var maxZoom = parseFloat(this.el.dataset.maxZoom || "8");

      var stored = {};
      try {
        stored = JSON.parse(this.el.dataset.crop || "{}") || {};
      } catch (_e) {
        stored = {};
      }

      this.crop = {
        x: typeof stored.x === "number" ? stored.x : 0.5,
        y: typeof stored.y === "number" ? stored.y : 0.5,
        zoom: typeof stored.zoom === "number" ? stored.zoom : 1,
        ar: typeof stored.ar === "number" ? stored.ar : 1
      };

      this.frame = this.el.querySelector("[data-crop-frame]");
      this.img = this.el.querySelector("[data-crop-img]");
      this.slider = this.el.querySelector("[data-crop-zoom]");

      // The stored aspect ratio was captured from this same file, but the
      // image itself is the authority once it arrives — a freshly picked
      // avatar has no stored crop and starts from ar = 1 until then.
      var adoptNaturalRatio = function () {
        if (self.img.naturalWidth > 0 && self.img.naturalHeight > 0) {
          var ar = self.img.naturalWidth / self.img.naturalHeight;
          // Only bother the server when the truth differs from the stored
          // value — on a reopened editor they already match.
          if (Math.abs(ar - self.crop.ar) > 0.001) {
            self.crop.ar = ar;
            self._render();
            self._push();
          } else {
            self._render();
          }
        }
      };
      if (this.img.complete && this.img.naturalWidth > 0) {
        adoptNaturalRatio();
      } else {
        this.img.addEventListener("load", adoptNaturalRatio);
      }

      if (this.slider) {
        this.slider.value = String(this.crop.zoom);
        this.slider.addEventListener("input", function () {
          // About the frame's centre: what is in the middle stays there.
          var r = self.frame.getBoundingClientRect();
          self._zoomAt(r.left + r.width / 2, r.top + r.height / 2, parseFloat(self.slider.value) || 1);
        });
        this.slider.addEventListener("change", function () {
          self._push();
        });
      }

      // Zoom to `zoom`, keeping the image point under (clientX, clientY)
      // where it is on screen — the way a photo app zooms toward the cursor
      // or the fingers. The slider passes the frame's centre.
      this._zoomAt = function (clientX, clientY, zoom) {
        var rect = self.frame.getBoundingClientRect();
        if (!(rect.width > 0 && rect.height > 0)) return;
        var px = ((clientX - rect.left) / rect.width) * 100;
        var py = ((clientY - rect.top) / rect.height) * 100;
        var before = avatarCropLayout(self.crop);
        var u = (px - before.left) / before.width;
        var v = (py - before.top) / before.height;
        self.crop.zoom = clamp(zoom, 1, maxZoom);
        var after = avatarCropLayout(self.crop);
        self.crop.x = (50 - (px - u * after.width)) / after.width;
        self.crop.y = (50 - (py - v * after.height)) / after.height;
        self.crop = clampAvatarCropFocal(self.crop);
        if (self.slider) self.slider.value = String(self.crop.zoom);
        self._render();
      };

      // Pan by a screen distance: moving the image right means the point
      // being looked at sits further LEFT in the image.
      this._panBy = function (dx, dy, rect) {
        var l = avatarCropLayout(self.crop);
        self.crop.x -= dx / ((rect.width * l.width) / 100);
        self.crop.y -= dy / ((rect.height * l.height) / 100);
        self.crop = clampAvatarCropFocal(self.crop);
        self._render();
      };

      // One pointer pans; two (fingers on a phone) pinch to zoom about
      // their midpoint and pan as the midpoint moves.
      var pointers = {};
      var gesture = null;
      var pointerList = function () {
        return Object.keys(pointers).map(function (k) { return pointers[k]; });
      };
      var startGesture = function () {
        var list = pointerList();
        var rect = self.frame.getBoundingClientRect();
        if (list.length >= 2) {
          var a = list[0], b = list[1];
          gesture = {
            rect: rect,
            dist: Math.hypot(b.x - a.x, b.y - a.y) || 1,
            mid: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
          };
        } else if (list.length === 1) {
          gesture = { rect: rect, last: { x: list[0].x, y: list[0].y } };
        } else {
          gesture = null;
        }
      };
      this._onPointerDown = function (e) {
        if (e.pointerType === "mouse" && e.button !== 0) return;
        e.preventDefault();
        pointers[e.pointerId] = { x: e.clientX, y: e.clientY };
        try { self.frame.setPointerCapture(e.pointerId); } catch (_e) {}
        self.frame.style.cursor = "grabbing";
        startGesture();
      };
      this._onPointerMove = function (e) {
        if (!pointers[e.pointerId] || !gesture) return;
        pointers[e.pointerId] = { x: e.clientX, y: e.clientY };
        var list = pointerList();
        if (list.length >= 2 && gesture.dist) {
          var a = list[0], b = list[1];
          var dist = Math.hypot(b.x - a.x, b.y - a.y) || 1;
          var mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
          self._panBy(mid.x - gesture.mid.x, mid.y - gesture.mid.y, gesture.rect);
          self._zoomAt(mid.x, mid.y, self.crop.zoom * (dist / gesture.dist));
          gesture.dist = dist;
          gesture.mid = mid;
        } else if (gesture.last) {
          self._panBy(e.clientX - gesture.last.x, e.clientY - gesture.last.y, gesture.rect);
          gesture.last = { x: e.clientX, y: e.clientY };
        }
      };
      this._onPointerUp = function (e) {
        if (!pointers[e.pointerId]) return;
        delete pointers[e.pointerId];
        try {
          if (self.frame.hasPointerCapture(e.pointerId)) self.frame.releasePointerCapture(e.pointerId);
        } catch (_e) {}
        // A finger lifted mid-pinch: the other carries on panning.
        startGesture();
        if (!gesture) {
          self.frame.style.cursor = "grab";
          self._push();
        }
      };
      // A wheel notch, a trackpad scroll or a trackpad pinch (ctrlKey)
      // zooms toward the cursor, in proportion to how far it turned, so a
      // trackpad is smooth and a mouse steps.
      this._onWheel = function (e) {
        e.preventDefault();
        var dy = e.deltaY;
        if (e.deltaMode === 1) dy *= 40;
        else if (e.deltaMode === 2) dy *= 800;
        var k = Math.exp(-dy * (e.ctrlKey ? 0.01 : 0.0015));
        self._zoomAt(e.clientX, e.clientY, self.crop.zoom * k);
        clearTimeout(self._wheelTimer);
        self._wheelTimer = setTimeout(function () {
          self._push();
        }, 250);
      };

      this.frame.addEventListener("pointerdown", this._onPointerDown);
      this.frame.addEventListener("pointermove", this._onPointerMove);
      this.frame.addEventListener("pointerup", this._onPointerUp);
      this.frame.addEventListener("pointercancel", this._onPointerUp);
      this.frame.addEventListener("wheel", this._onWheel, { passive: false });

      // The wheel push is debounced, so a Save clicked inside the window
      // would persist the pre-wheel crop — and the modal's teardown would
      // cancel the pending push outright. Flushing on the Save button's
      // capture phase puts the final crop on the wire before the phx-click
      // does; same websocket, so order is guaranteed.
      this._saveBtn =
        (this.el.closest("dialog") || document).querySelector("[data-crop-save-btn]");
      this._onSaveClick = function () {
        if (self._wheelTimer) {
          clearTimeout(self._wheelTimer);
          self._wheelTimer = null;
          self._push();
        }
      };
      if (this._saveBtn) {
        this._saveBtn.addEventListener("click", this._onSaveClick, true);
      }

      this._render();
    },

    _render() {
      var l = avatarCropLayout(this.crop);
      this.img.style.width = l.width + "%";
      this.img.style.height = l.height + "%";
      this.img.style.left = l.left + "%";
      this.img.style.top = l.top + "%";
    },

    _push() {
      // phx-target on the element routes this to the owning LiveComponent.
      this.pushEventTo(this.el, "avatar_crop_changed", {
        x: this.crop.x,
        y: this.crop.y,
        zoom: this.crop.zoom,
        ar: this.crop.ar
      });
    },

    destroyed() {
      clearTimeout(this._wheelTimer);
      if (this._saveBtn) {
        this._saveBtn.removeEventListener("click", this._onSaveClick, true);
      }
      if (this.frame) {
        this.frame.removeEventListener("pointerdown", this._onPointerDown);
        this.frame.removeEventListener("pointermove", this._onPointerMove);
        this.frame.removeEventListener("pointerup", this._onPointerUp);
        this.frame.removeEventListener("pointercancel", this._onPointerUp);
        this.frame.removeEventListener("wheel", this._onWheel);
      }
    }
  };

  // Exported for the Node test harness (test/js); harmless in a browser.
  if (typeof module === "object" && module.exports) {
    module.exports.avatarCropLayout = avatarCropLayout;
    module.exports.clampAvatarCropFocal = clampAvatarCropFocal;
  }
})();

// ---------------------------------------------------------------------------
// ImageEditor — drawing on the image editor's preview.
//
// The editor (PhoenixKitWeb.Components.ImageEditor) is a complete form
// without this hook: crop and redaction areas are percentage fields. The
// hook lets you draw them instead: a drag on the preview frame becomes a
// rectangle in percent of the frame, pushed to the owning LiveComponent
// (the element carries phx-target) as "drawn". With a crop aspect chosen
// (data-aspect "w/h"), the rectangle keeps that shape.
//
// It also reports the preview's natural size: the recorded dimensions of
// an older upload are its stored pixels', which for a photo with an EXIF
// rotation are the displayed ones turned a quarter.
// ---------------------------------------------------------------------------
(function () {
  if (window.PhoenixKitImageEditor) return;
  window.PhoenixKitImageEditor = true;
  window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};

  function clamp(v, lo, hi) {
    return Math.min(hi, Math.max(lo, v));
  }

  // The rectangle spanned by two points (percent of the frame), kept inside
  // the frame. `aspect` is [w, h] in pixels and `frame` the frame's pixel
  // size: the rectangle then has that shape, grown from `start` toward
  // `end` and shrunk (not distorted) where it would leave the frame.
  function imageEditorRect(start, end, aspect, frame) {
    var a = { x: clamp(start.x, 0, 100), y: clamp(start.y, 0, 100) };
    var b = { x: clamp(end.x, 0, 100), y: clamp(end.y, 0, 100) };

    if (!aspect || !frame) {
      return {
        x: Math.min(a.x, b.x),
        y: Math.min(a.y, b.y),
        w: Math.abs(b.x - a.x),
        h: Math.abs(b.y - a.y)
      };
    }

    var ratio = aspect[0] / aspect[1];
    var dirX = b.x < a.x ? -1 : 1;
    var dirY = b.y < a.y ? -1 : 1;
    // Room from the start point to the frame edge in the drag direction, px.
    var roomW = ((dirX < 0 ? a.x : 100 - a.x) / 100) * frame[0];
    var roomH = ((dirY < 0 ? a.y : 100 - a.y) / 100) * frame[1];

    var wPx = (Math.abs(b.x - a.x) / 100) * frame[0];
    var hPx = (Math.abs(b.y - a.y) / 100) * frame[1];
    // The larger side of the drag decides the size.
    if (wPx / ratio >= hPx) {
      hPx = wPx / ratio;
    } else {
      wPx = hPx * ratio;
    }
    // Shrink to fit, keeping the shape.
    var fit = Math.min(1, wPx > 0 ? roomW / wPx : 1, hPx > 0 ? roomH / hPx : 1);
    wPx *= fit;
    hPx *= fit;

    var w = (wPx / frame[0]) * 100;
    var h = (hPx / frame[1]) * 100;
    return {
      x: dirX < 0 ? a.x - w : a.x,
      y: dirY < 0 ? a.y - h : a.y,
      w: w,
      h: h
    };
  }

  // Whether an image of natural size `natural` shows the recorded `size`
  // turned a quarter: its shape matches the swapped size clearly better than
  // the size itself (within 2%). Square images never are.
  function imageEditorSwapped(size, natural) {
    if (!size || !natural || !natural[0] || !natural[1]) return false;
    var shown = natural[0] / natural[1];
    var recorded = size[0] / size[1];
    var turned = size[1] / size[0];
    if (Math.abs(recorded - turned) < 0.02 * turned) return false;
    return Math.abs(shown - turned) < 0.02 * turned &&
      Math.abs(shown - turned) < Math.abs(shown - recorded);
  }

  window.PhoenixKitAdminHooks.ImageEditor = {
    mounted() {
      var self = this;

      this._onPointerDown = function (e) {
        var tool = self.el.dataset.tool;
        if (e.button !== 0) return;
        if (tool !== "crop" && tool !== "redact") return;
        if (tool === "crop" && self.el.dataset.locked === "true") return;

        e.preventDefault();
        // One layout read per gesture: the frame cannot resize mid-drag.
        self._box = self.el.getBoundingClientRect();
        self._tool = tool;
        self._start = self._point(e);
        self.el.setPointerCapture(e.pointerId);
      };
      this._onPointerMove = function (e) {
        if (!self._start) return;
        self._show(self._rect(self._point(e)));
      };
      this._onPointerUp = function (e) {
        if (!self._start) return;
        var rect = self._rect(self._point(e));
        self._start = null;
        self._show(null);
        if (self.el.hasPointerCapture(e.pointerId)) {
          self.el.releasePointerCapture(e.pointerId);
        }
        // A click, not a drag.
        if (rect.w < 0.5 || rect.h < 0.5) return;
        self.pushEventTo(self.el, "drawn", {
          tool: self._tool,
          x: rect.x,
          y: rect.y,
          w: rect.w,
          h: rect.h
        });
      };
      this._onCancel = function () {
        self._start = null;
        self._show(null);
      };

      this.el.addEventListener("pointerdown", this._onPointerDown);
      this.el.addEventListener("pointermove", this._onPointerMove);
      this.el.addEventListener("pointerup", this._onPointerUp);
      this.el.addEventListener("pointercancel", this._onCancel);

      this._onImageLoad = function () {
        self._reportSize();
      };
      this._watchImage();
    },

    updated() {
      this._watchImage();
    },

    // The server resets the recorded size on every reload of the file (a
    // save, a finished render, a retry, a revert) while morphdom keeps the
    // same <img> node. Reporting only when the node changed left the frame at
    // the unturned aspect after any of those: a stretched preview, and crop
    // and redaction rectangles drawn against the wrong frame. So every update
    // re-checks a loaded image — `_reportSize` compares against the size the
    // server currently renders and stays quiet once they agree — and the load
    // listener stays on for a `src` swapped on the same node.
    _watchImage() {
      var img = this.el.querySelector("img");
      if (img !== this._img) {
        if (this._img) this._img.removeEventListener("load", this._onImageLoad);
        this._img = img;
        if (img) img.addEventListener("load", this._onImageLoad);
      }
      if (img && img.complete && img.naturalWidth > 0) this._reportSize();
    },

    _reportSize() {
      var img = this._img;
      var size = [parseFloat(this.el.dataset.sourceWidth), parseFloat(this.el.dataset.sourceHeight)];
      if (img && imageEditorSwapped(size, [img.naturalWidth, img.naturalHeight])) {
        this.pushEventTo(this.el, "turned_source", {});
      }
    },

    _point(e) {
      var box = this._box;
      return {
        x: ((e.clientX - box.left) / box.width) * 100,
        y: ((e.clientY - box.top) / box.height) * 100
      };
    },

    _rect(end) {
      var aspect = null;
      if (this._tool === "crop" && this.el.dataset.aspect) {
        aspect = this.el.dataset.aspect.split("/").map(Number);
      }
      var frame = [
        parseFloat(this.el.dataset.frameWidth),
        parseFloat(this.el.dataset.frameHeight)
      ];
      return imageEditorRect(this._start, end, aspect, frame);
    },

    _show(rect) {
      var draft = this.el.querySelector("[data-draft]");
      if (!draft) return;
      if (!rect) {
        draft.classList.add("hidden");
        return;
      }
      draft.classList.remove("hidden");
      draft.style.left = rect.x + "%";
      draft.style.top = rect.y + "%";
      draft.style.width = rect.w + "%";
      draft.style.height = rect.h + "%";
    },

    destroyed() {
      this.el.removeEventListener("pointerdown", this._onPointerDown);
      this.el.removeEventListener("pointermove", this._onPointerMove);
      this.el.removeEventListener("pointerup", this._onPointerUp);
      this.el.removeEventListener("pointercancel", this._onCancel);
      if (this._img) this._img.removeEventListener("load", this._onImageLoad);
    }
  };

  // Exported for the Node test harness (test/js); harmless in a browser.
  if (typeof module === "object" && module.exports) {
    module.exports.imageEditorRect = imageEditorRect;
    module.exports.imageEditorSwapped = imageEditorSwapped;
  }
})();

  // A hook defined here that nothing stubs is unreachable: say so while
  // developing. (A module's admin hooks are stubbed by phoenix_kit_modules.js.)
  Object.keys(window.PhoenixKitAdminHooks).forEach(function(name) {
    var stub = window.PhoenixKitHooks && window.PhoenixKitHooks[name];
    if (!(stub && stub.__pkAdminStub)) {
      console.warn("[PhoenixKit] The admin hook " + name + " has no stub in phoenix_kit.js, so no page can mount it.");
    }
  });

  window.PhoenixKitAdminLoaded = true;
})();
