/**
 * PhoenixKit JavaScript Bundle (public)
 * ============================================================================
 *
 * What every page loads: the shared library loader, the hooks a public page can
 * render, and a STUB under the name of every hook that belongs to the admin
 * area or the user dashboard. The code of those hooks is in
 * phoenix_kit_admin.js, which the first stub to mount loads (once, as a
 * vendored library). Nothing else changes for a host: the names are all here,
 * so they are in the object a host spreads into LiveSocket.
 * See dev_docs/plans/2026-10-27-public-admin-js-split.md.
 *
 * SETUP: Add to your assets/js/app.js:
 *
 *   import "../../deps/phoenix_kit/priv/static/assets/phoenix_kit.js"
 *
 *   let liveSocket = new LiveSocket("/live", Socket, {
 *     hooks: { ...window.PhoenixKitHooks, ...Hooks },
 *     // ... other options
 *   })
 *
 * or, with the `:phoenix_kit_js_sources` compiler (the installer's layout), load
 * the vendored copy and the module bundles with two <script> tags before app.js.
 * Either way `mix phoenix_kit.update` / `mix compile` puts phoenix_kit_admin.js
 * and the install facts that name it next to them.
 *
 * PUBLIC HOOKS (real, in this file):
 *   - CookieConsent ........... Cookie consent banner and preferences modal
 *   - FlashAutoDismiss ........ Auto-dismiss flash messages with progress bar
 *   - PkDialog, PkDialogTrigger  Modal dialogs and their openers
 *   - PkDateInput ............. Date field with a calendar popup
 *   - LanguageSwitcherSearch / LanguageSwitcherPosition
 *   - TimezoneDetector / TimezoneOffset, TimeAgo, ResetSelect, PopupLink,
 *     CopyToClipboard, FadeOut, PreserveScroll, InfiniteScroll, PageSizeAutoFit,
 *     PkShiftEnter, PkUrlMirror, PhoenixKitUrlState, PkCheckboxIndeterminate,
 *     PkChartCrosshair, ViewportPopover, SelectOnMount, MaintenanceCountdown,
 *     LibraryLoadNotice
 *   - MentionInput ............ @ and # menu in plain textareas
 *   - UploadStats, UploadGuard  Transfer line under an upload bar; leave-page guard
 *   - PkUploadEdit ............ Crop/turn a photo before upload (<.file_upload edit_images>)
 *   - FormDraft ............... Opt-in drafts of a form's fields in the browser
 *   - AudioRecorder ........... Microphone recorder behind <.audio_recorder>
 *   - PasskeySignIn, PasskeyRegister  Passkeys of the sign-in page and the Security tab
 *   - Turnstile ............... Cloudflare bot check on the public sign-up, magic-link,
 *                               confirmation and password-reset forms
 *   - Leaf, FrescoViewer, FrescoCanvas, TesseraLayer, EtcherLayer: wrappers that
 *     load the vendored viewer/editor library on first mount
 *
 * ADMIN HOOKS (stubs here, code in phoenix_kit_admin.js): see ADMIN_HOOKS below.
 *
 * @version 2.0.0
 * @license MIT
 */

// How many times this file has run on the page. A second include (a <script> tag
// in the layout and an import in the host's app.js) must be a no-op: the first
// section returns on PhoenixKitInitialized, and each later section returns on
// this count, so no document listener is installed twice.
if (typeof window !== "undefined") window.__pkBundleLoads = (window.__pkBundleLoads || 0) + 1;

(function() {
  "use strict";

  // Prevent double initialization
  if (window.PhoenixKitInitialized) return;
  window.PhoenixKitInitialized = true;

  // Keep the native disclosure usable on controller-rendered pages. In browsers
  // with popovers, lift its list above the scrolling account menu's clipping edge.
  if (window.customElements && !customElements.get("pk-session-languages")) {
    customElements.define("pk-session-languages", class extends HTMLElement {
      connectedCallback() {
        this.listeners = new AbortController();
        const options = { signal: this.listeners.signal };
        this.addEventListener("pointerenter", event => {
          if (event.pointerType === "mouse" && !this.details.open) {
            this.preview = true;
            this.details.open = true;
          }
        }, options);
        this.addEventListener("pointerleave", () => {
          if (this.preview && !this.panel.contains(document.activeElement)) this.close();
        }, options);
        this.addEventListener("click", event => {
          if (this.preview && event.target.closest("summary")) {
            event.preventDefault();
            this.preview = false;
          } else if (this.panel.contains(event.target) && event.target.closest("a,button")) {
            this.close();
          }
        }, options);
        this.addEventListener("toggle", event => {
          if (event.target !== this.details) return;
          if (this.details.open) this.openPanel();
          else this.close();
        }, { ...options, capture: true });
      }

      get details() { return this.querySelector("details"); }
      get panel() { return this.details.lastElementChild; }

      openPanel() {
        this.openListeners?.abort();
        this.openListeners = new AbortController();
        const options = { signal: this.openListeners.signal };
        const closeOutside = event => {
          if (!this.contains(event.target)) this.close();
        };
        document.addEventListener("pointerdown", closeOutside, options);
        // Safari (iPad, Mac) does not focus a button or a link that is pressed:
        // it focuses the nearest focusable ancestor, here the account menu's own
        // list. That is no way out of the panel, and closing on it would hide the
        // language under the finger before its click arrives.
        document.addEventListener("focusin", event => {
          if (!event.target.contains(this)) closeOutside(event);
        }, options);
        document.addEventListener("keydown", event => {
          if (event.key === "Escape") {
            event.preventDefault();
            this.close();
            this.details.firstElementChild.focus();
          }
        }, options);

        const panel = this.panel;
        if (!panel.showPopover) return;
        // Focus in the top layer can drop :focus-within on the outer dropdown.
        this.dropdown = this.closest(".dropdown");
        this.dropdown?.classList.add("dropdown-open");
        panel.popover = "manual";
        panel.showPopover({ source: this.details.firstElementChild });
        const position = () => {
          const row = this.details.firstElementChild.getBoundingClientRect();
          const width = Math.min(Math.max(row.width, 192), window.innerWidth - 16);
          const left = row.left >= width + 8 ? row.left - width : row.right;
          const beside = left + width <= window.innerWidth - 8;
          const above = !beside && row.top > window.innerHeight - row.bottom;
          const room = beside ? window.innerHeight : above ? row.top : window.innerHeight - row.bottom;
          Object.assign(panel.style, {
            position: "fixed", inset: "auto", margin: "0", width: width + "px",
            maxHeight: "min(15rem, " + Math.max(0, room - 8) + "px)",
            left: (beside ? left : Math.max(8, Math.min(row.left, window.innerWidth - width - 8))) + "px"
          });
          const top = beside ? Math.min(row.top, window.innerHeight - panel.offsetHeight - 8)
            : above ? row.top - panel.offsetHeight : row.bottom;
          panel.style.top = Math.max(8, top) + "px";
        };
        position();
        window.addEventListener("resize", position, options);
        document.addEventListener("scroll", event => {
          if (event.target !== panel) position();
        }, { ...options, capture: true });
      }

      close() {
        this.openListeners?.abort();
        this.preview = false;
        this.dropdown?.classList.remove("dropdown-open");
        if (!this.details) return;
        this.details.open = false;
        if (this.panel.popover) this.panel.hidePopover();
      }

      disconnectedCallback() {
        this.listeners.abort();
        this.close();
      }
    });
  }

  // ============================================================================
  // WEBSOCKET TRANSPORT CACHE CLEARING
  // ============================================================================
  //
  // Phoenix LiveView caches transport fallback preferences in browser storage.
  // If WebSocket fails once, Phoenix remembers this and uses LongPoll for all
  // subsequent page loads, even after the WebSocket issue is fixed.
  //
  // This clears the cached preference on every page load to ensure WebSocket
  // is always tried first, providing much better performance when available.
  //
  // See: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.Socket.html
  //
  // ============================================================================

  (function clearPhoenixTransportCache() {
    try {
      // Clear the transport fallback cache. Phoenix stores the sticky
      // longpoll flag under `phx:fallback:<transport>` — a "phx:"-prefixed
      // key — and the old filter here EXCLUDED everything "phx:"-prefixed
      // on the theory that those are PhoenixKit's own (phx:theme). So this
      // code never cleared the one key it exists for, and a browser that
      // fell back once (a slow dev load was enough) stayed on longpoll for
      // the life of the tab: laggy, and prone to full-page reloads when a
      // longpoll POST died mid-flight — which read as "the page refreshed
      // itself and ate my work". Target the fallback keys BY NAME and
      // keep excluding the rest of the phx:* namespace.
      function isTransportKey(k) {
        return k.startsWith('phx:fallback:') ||
          (k.includes('phx') && !k.startsWith('phx:'));
      }
      var lsKeys = Object.keys(localStorage).filter(isTransportKey);
      if (lsKeys.length > 0) {
        console.debug("[PhoenixKit] Clearing cached transport preferences from localStorage:", lsKeys);
        lsKeys.forEach(function(k) { localStorage.removeItem(k); });
      }

      // Same for sessionStorage — which is where Phoenix actually keeps
      // the fallback flag (getSession/storeSession).
      var ssKeys = Object.keys(sessionStorage).filter(isTransportKey);
      if (ssKeys.length > 0) {
        console.debug("[PhoenixKit] Clearing cached transport preferences from sessionStorage:", ssKeys);
        ssKeys.forEach(function(k) { sessionStorage.removeItem(k); });
      }
    } catch (e) {
      // Storage might be unavailable in some contexts (e.g., private browsing)
      console.debug("[PhoenixKit] Could not clear transport cache:", e);
    }
  })();

  // ============================================================================
  // PERSON CARD
  // ============================================================================
  // A click on a person chip (`[data-mention-user]`: core's <.person_chip>,
  // which <.mention_text> renders, and the comments module's chips) opens
  // that person's card in a small box next to the chip — above or below it,
  // wherever there is room; a bottom sheet on a narrow screen (Max,
  // 2026-11-25). The card is PhoenixKitWeb.PersonCardController's, fetched
  // on every open (what a viewer may see is decided on the server).
  //
  // Several people at once: any element with `data-people="uuid,uuid,…"`
  // (a task's assignees, say) opens the side drawer with every person's
  // card in it. A chip inside such an element still opens its own card.
  //
  //   <span data-people="uuid-1,uuid-2">…faces…</span>
  //   window.PhoenixKitInternals.openPersonCard(uuid, anchorEl)
  //   window.PhoenixKitInternals.openPeopleDrawer([uuid, …])
  //
  // Both are a <dialog> of their own opened with showModal(): over an open
  // task popup only the TOPMOST modal is not inert, so a box appended
  // anywhere else could be seen but not clicked. Esc and a click outside
  // close it; focus goes back to the chip. Ctrl/⌘/Shift/middle clicks follow
  // the chip's link; a chip inside an editor is left to the editor. A card
  // that cannot be loaded says so — the page never navigates away.
  (function personCard() {
    if (typeof window === "undefined" || window.PhoenixKitPersonDrawer) return;
    window.PhoenixKitPersonDrawer = true;

    var pop = null;
    var drawer = null;
    var anchorEl = null;
    var seq = 0;
    var MAX_PEOPLE = 20;

    function cardUrl(uuid) {
      var prefix = window.PHOENIX_KIT_PREFIX || "/phoenix_kit";
      if (prefix === "/") prefix = "";
      // The card has no locale in its URL: it is told the page's language.
      var lang = document.documentElement.getAttribute("lang");
      return prefix + "/people/" + encodeURIComponent(uuid) + "/card" + (lang ? "?lang=" + encodeURIComponent(lang) : "");
    }

    function fetchCard(uuid) {
      return fetch(cardUrl(uuid), { credentials: "same-origin", headers: { accept: "text/html" } }).then(
        function (resp) {
          if (!resp.ok) throw new Error("no card");
          return resp.text();
        }
      );
    }

    function spinner() {
      return '<div class="flex justify-center py-6"><span class="loading loading-spinner loading-md"></span></div>';
    }

    // The words come from the chip (<.person_chip> renders them translated);
    // English for a chip that carries none.
    function failure(href, chip) {
      var said = function (attr, fallback) {
        return (chip && chip.getAttribute && chip.getAttribute(attr)) || fallback;
      };
      var box = document.createElement("div");
      box.className = "flex flex-col items-center gap-2 py-4 text-center text-sm";
      var p = document.createElement("p");
      p.className = "text-base-content/70";
      p.textContent = said("data-card-error", "Couldn't load this person.");
      box.appendChild(p);
      // A same-site link only: the chip's own href, as it was rendered.
      if (href && href.charAt(0) === "/" && !/^[/][/\\]|[\x00-\x1f\x7f]/.test(href)) {
        var a = document.createElement("a");
        a.href = href;
        a.className = "link link-primary";
        a.textContent = said("data-card-profile", "Open profile");
        box.appendChild(a);
      }
      return box;
    }

    // A dialog closes when its own element (the transparent backdrop area)
    // is clicked, not its box; its links close it as they are followed.
    function wireClose(dialog, body) {
      dialog.addEventListener("click", function (e) {
        if (e.target === dialog) {
          dialog.close();
          return;
        }
        var a = e.target.closest && e.target.closest("a[href]");
        if (a && dialog.contains(a)) dialog.close();
      });
      // The close event is queued: a card reopened meanwhile is not emptied.
      dialog.addEventListener("close", function () {
        if (!dialog.open) body.innerHTML = "";
      });
    }

    function buildPop() {
      pop = document.createElement("dialog");
      pop.className = "pk-person-pop";
      pop.setAttribute("aria-label", "Person");
      // Its own placement: no centring, no UA margins, an invisible backdrop.
      pop.style.cssText =
        "position:fixed;margin:0;padding:0;border:0;background:transparent;max-width:none;max-height:none;overflow:visible;";
      pop.innerHTML =
        '<div data-pk-pop-box class="w-72 max-w-[calc(100vw-1rem)] rounded-box border border-base-300 bg-base-100 p-4 shadow-xl">' +
        '<div data-pk-pop-body></div></div>';
      document.body.appendChild(pop);
      var style = document.createElement("style");
      pkAdoptStyle(style);
      style.textContent = ".pk-person-pop::backdrop{background:transparent}";
      pop.appendChild(style);
      wireClose(pop, pop.querySelector("[data-pk-pop-body]"));
      // A scroll anywhere (the chip's own container too, so capture): the
      // card follows its chip, and closes once the chip has left the view.
      document.addEventListener("scroll", followAnchor, { capture: true, passive: true });
    }

    function followAnchor() {
      if (!pop || !pop.open || !anchorEl) return;
      if (!anchorEl.isConnected) return pop.close();
      var r = anchorEl.getBoundingClientRect();
      if (r.bottom < 0 || r.top > window.innerHeight || r.right < 0 || r.left > window.innerWidth) {
        pop.close();
      } else {
        place(anchorEl);
      }
    }

    // Below the chip when it fits, else above; left edge on the chip's,
    // kept inside the viewport. Under 640 px wide: a sheet at the bottom.
    function place(anchor) {
      var box = pop.querySelector("[data-pk-pop-box]");
      var vw = window.innerWidth;
      var vh = window.innerHeight;
      if (vw < 640 || !anchor || !anchor.isConnected) {
        pop.style.left = "0.5rem";
        pop.style.right = "0.5rem";
        pop.style.top = "auto";
        pop.style.bottom = "0.5rem";
        // A modal dialog is width: fit-content in the browser's own styles,
        // which beat left/right: the sheet was 173 px wide (grok).
        pop.style.width = "calc(100vw - 1rem)";
        box.style.width = "100%";
        return;
      }
      pop.style.width = "";
      box.style.width = "";
      pop.style.right = "auto";
      pop.style.bottom = "auto";
      var r = anchor.getBoundingClientRect();
      var w = box.offsetWidth;
      var h = box.offsetHeight;
      var gap = 6;
      var top = r.bottom + gap;
      if (top + h > vh - 8 && r.top - gap - h >= 8) top = r.top - gap - h;
      top = Math.max(8, Math.min(top, vh - h - 8));
      var left = Math.max(8, Math.min(r.left, vw - w - 8));
      pop.style.top = top + "px";
      pop.style.left = left + "px";
    }

    function openCard(uuid, anchor) {
      if (!pop || !pop.isConnected) buildPop();
      if (drawer && drawer.open) drawer.close();
      var body = pop.querySelector("[data-pk-pop-body]");
      var mine = ++seq;
      var href = anchor && anchor.getAttribute && anchor.getAttribute("href");
      anchorEl = anchor || null;
      body.innerHTML = spinner();
      if (!pop.open) pop.showModal();
      place(anchor);

      fetchCard(uuid)
        .then(function (html) {
          if (mine !== seq || !pop.open) return;
          body.innerHTML = html;
          place(anchor);
          var first = body.querySelector("a[href], button");
          if (first) first.focus();
        })
        .catch(function () {
          if (mine !== seq || !pop.open) return;
          body.innerHTML = "";
          body.appendChild(failure(href, anchor));
          place(anchor);
        });
    }

    function buildDrawer() {
      drawer = document.createElement("dialog");
      drawer.className = "modal modal-end pk-person-drawer";
      drawer.setAttribute("aria-label", "People");
      drawer.innerHTML =
        '<div class="modal-box h-full max-h-full w-80 max-w-[90vw] rounded-none p-5 relative">' +
        '<button type="button" data-pk-drawer-close class="btn btn-ghost btn-sm btn-circle absolute right-3 top-3" aria-label="Close">✕</button>' +
        '<div data-pk-drawer-body class="pt-6 flex flex-col divide-y divide-base-200"></div>' +
        "</div>" +
        '<form method="dialog" class="modal-backdrop"><button aria-label="Close">close</button></form>';
      document.body.appendChild(drawer);
      var body = drawer.querySelector("[data-pk-drawer-body]");
      drawer.querySelector("[data-pk-drawer-close]").addEventListener("click", function () {
        drawer.close();
      });
      wireClose(drawer, body);
    }

    function openDrawer(uuids) {
      uuids = uuids.filter(function (u, i) {
        return u && uuids.indexOf(u) === i;
      }).slice(0, MAX_PEOPLE);
      if (!uuids.length) return;
      if (!drawer || !drawer.isConnected) buildDrawer();
      if (pop && pop.open) pop.close();
      var body = drawer.querySelector("[data-pk-drawer-body]");
      var mine = ++seq;
      body.innerHTML = "";
      var slots = uuids.map(function () {
        var slot = document.createElement("div");
        slot.className = "py-4 first:pt-0";
        slot.innerHTML = spinner();
        body.appendChild(slot);
        return slot;
      });
      if (!drawer.open) drawer.showModal();
      uuids.forEach(function (uuid, i) {
        fetchCard(uuid)
          .then(function (html) {
            if (mine === seq && drawer.open) slots[i].innerHTML = html;
          })
          .catch(function () {
            if (mine !== seq || !drawer.open) return;
            slots[i].innerHTML = "";
            slots[i].appendChild(failure(null, null));
          });
      });
    }

    document.addEventListener(
      "click",
      function (e) {
        if (e.defaultPrevented || e.button !== 0) return;
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        var t = e.target;
        if (!t || !t.closest) return;
        // Any editing value ("true", "", "plaintext-only"): the editor's own.
        if (t.closest("[contenteditable]:not([contenteditable='false']), textarea")) return;
        // Inside an open card or drawer: its own links and buttons.
        if (t.closest(".pk-person-pop, .pk-person-drawer")) return;

        var chip = t.closest("[data-mention-user]");
        var uuid = chip && chip.getAttribute("data-mention-user");
        if (uuid) {
          // Ahead of LiveView's own link handling (it would navigate).
          e.preventDefault();
          e.stopPropagation();
          openCard(uuid, chip);
          return;
        }

        var group = t.closest("[data-people]");
        var list = group && (group.getAttribute("data-people") || "").split(",").map(function (s) {
          return s.trim();
        });
        if (list && list.filter(Boolean).length) {
          e.preventDefault();
          e.stopPropagation();
          openDrawer(list);
        }
      },
      true
    );

    // From the keyboard: a chip or group that is not a link (role="button",
    // tabindex="0") opens on Enter or Space, like a button. A link chip gets
    // Enter's click from the browser already.
    document.addEventListener(
      "keydown",
      function (e) {
        if (e.key !== "Enter" && e.key !== " ") return;
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        var t = e.target;
        if (!t || !t.closest || t.tagName === "A") return;
        if (t.closest("[contenteditable]:not([contenteditable='false']), textarea, input")) return;
        if (t.closest(".pk-person-pop, .pk-person-drawer")) return;
        var uuid = t.getAttribute("data-mention-user");
        if (uuid) {
          e.preventDefault();
          openCard(uuid, t);
          return;
        }
        var people = t.getAttribute("data-people");
        if (people) {
          e.preventDefault();
          openDrawer(people.split(",").map(function (s) { return s.trim(); }));
        }
      },
      true
    );

    // A LiveView navigation (a server push_navigate) leaves no stale card open.
    window.addEventListener("phx:page-loading-start", function (e) {
      var kind = e.detail && e.detail.kind;
      if (kind !== "redirect" && kind !== "patch") return;
      if (pop && pop.open) pop.close();
      if (drawer && drawer.open) drawer.close();
    });
    window.addEventListener("resize", function () {
      if (pop && pop.open) place(anchorEl);
    });

    window.PhoenixKitInternals = window.PhoenixKitInternals || {};
    window.PhoenixKitInternals.openPersonCard = openCard;
    window.PhoenixKitInternals.openPeopleDrawer = openDrawer;
    // The name the first version had.
    window.PhoenixKitInternals.openPersonDrawer = function (uuid, chip) {
      openCard(uuid, chip);
    };
  })();

  // Initialize hooks collection
  window.PhoenixKitHooks = window.PhoenixKitHooks || {};

  // ============================================================================
  // SHARED LIBRARY LOADER
  // ============================================================================
  //
  // Every lazily-loaded library (Fresco, Tessera, Etcher, Leaf, SortableJS,
  // Panzoom, wavesurfer) loads through `loadLibrary`, which replaced six
  // copied loaders whose only failure report was a console.error (see
  // dev_docs/plans/2026-10-07-self-hosted-viewer-libraries.md, Part A).
  //
  //   - A pre-imported library wins: `check()` is asked first.
  //   - One in-flight attempt per library; every waiter settles either way.
  //   - Success means `check()` passes after onload, not just a 200.
  //   - A failed script may retry (LIBRARY_MAX_ATTEMPTS per page); a failed
  //     module import() is terminal for the document.
  //   - Final failures go to window.__pkLibFailures and a `pk:library-failed`
  //     event, which the admin-only LibraryLoadNotice shows.
  //   - A library the install facts do not name is a "facts" failure, refined
  //     to "stale" when the server's copy of the facts file names it.
  //
  // A script error has no HTTP status, so failures are "load" unless a
  // matching, enforced `securitypolicyviolation` makes them "csp" — and that
  // event may arrive after onerror, so it can refine an earlier failure.
  // ----------------------------------------------------------------------------

  // Where the libraries live, in this order:
  //   1. window.PHOENIX_KIT_LIB_BASE — the host said so (itself, or through
  //      `config :phoenix_kit, library_base_url:`, which the install facts
  //      turn into this variable without overriding one the host set);
  //   2. next to the tag that loads this file, when it is the vendored bundle
  //      itself (phoenix_kit.js, or the digested phoenix_kit-<md5>.js): a host
  //      serving its assets from a CDN or under a path prefix is right here with
  //      no configuration;
  //   3. the compiler's default (window.PHOENIX_KIT_LIB_BASE_DEFAULT,
  //      `/assets/vendor/lib/`) — what is left when no tag loads this file,
  //      i.e. a host that bundles it into its own app.js, where the script
  //      being evaluated is app.js and says nothing about the library files.
  //      It does not depend on where the facts file is served from, so a host
  //      that moves, defers or re-minifies that file is unaffected;
  //   4. the directory of whatever script this was (facts from an older
  //      version carry no default).
  // The script's address is captured NOW, while the bundle evaluates:
  // document.currentScript is gone in every later callback.
  var PK_SCRIPT_SRC = (document.currentScript && document.currentScript.src) || "";
  var PK_SCRIPT_NONCE = (document.currentScript && document.currentScript.nonce) || "";
  var PK_SCRIPT_IS_BUNDLE = /(^|\/)phoenix_kit(-[0-9a-f]{32})?\.js$/.test(PK_SCRIPT_SRC.split(/[?#]/)[0]);

  // A <style> this file creates is dropped by style-src 'nonce-…' unless the
  // element carries the document's style nonce before it is inserted. The
  // nonce attribute is hidden from selectors and from getAttribute; the IDL
  // property is what a script can read. A style already on the page wins, so
  // a host with a different nonce per kind is not given the script's. The
  // script nonce is only the fallback for one nonce used for both, put on
  // the tag that loads this file (currentScript is null in every callback).
  function pkStyleNonce() {
    var list = document.getElementsByTagName ? document.getElementsByTagName("style") : [];
    for (var i = 0; i < list.length; i++) {
      if (list[i].nonce) return list[i].nonce;
    }
    return PK_SCRIPT_NONCE;
  }

  function pkAdoptStyle(el) {
    var nonce = el && pkStyleNonce();
    if (nonce) el.nonce = nonce;
    return el;
  }

  window.PhoenixKitInternals = window.PhoenixKitInternals || {};
  window.PhoenixKitInternals.adoptStyle = pkAdoptStyle;

  function pkLibDir(src) {
    return src.split(/[?#]/)[0].replace(/[^\/]*$/, "") + "lib/";
  }

  // Only a string is the host's word. `<a id="PHOENIX_KIT_LIB_BASE" href="…">` in the
  // page's markup puts an element on `window` under that name, and `String()` of it
  // is its href: the loader would fetch and run a file from wherever the markup says.
  function pkLibSetting(name) {
    var value = window[name];
    return typeof value === "string" && value ? value : null;
  }

  function pkLibBase() {
    var own = pkLibSetting("PHOENIX_KIT_LIB_BASE");
    if (own) return own.replace(/\/?$/, "/");
    if (PK_SCRIPT_IS_BUNDLE) return pkLibDir(PK_SCRIPT_SRC);
    var dflt = pkLibSetting("PHOENIX_KIT_LIB_BASE_DEFAULT");
    if (dflt) return dflt.replace(/\/?$/, "/");
    if (!PK_SCRIPT_SRC) return null;
    return pkLibDir(PK_SCRIPT_SRC);
  }

  // The file names come from the install facts (window.PHOENIX_KIT_LIBS,
  // written by the compiler into phoenix_kit_modules.js), looked up when a
  // library is first needed — that file loads after this one. No facts, no
  // guess: a version guessed in the browser could mismatch the server's half
  // and quietly stop honouring its API, so the failure is reported instead.
  function pkLibUrls(key) {
    var facts = window.PHOENIX_KIT_LIBS;
    var entry = facts && facts[key];
    var base = pkLibBase();
    if (!entry || !entry.file || !base) return null;
    // `?vsn=` is what makes Plug.Static send the one-year immutable cache header;
    // the file name already carries the version and content hash, so it is only
    // the switch, never a cache key.
    // A script's src resolves against the document, but import() resolves
    // against this bundle. Normalize a host's relative base once so both
    // loaders fetch the same file (especially wavesurfer's ES module).
    return { local: pkLibNormalize(base + entry.file + "?vsn=d"), cdn: entry.cdn || null };
  }

  var LIBRARY_MAX_ATTEMPTS = 2;
  var pkLibInflight = {};
  var pkLibAttempts = {};
  var pkLibPending = []; // { name, url, origin } for in-flight attempts
  var pkLibFailures = window.__pkLibFailures = window.__pkLibFailures || {};

  function pkLibNormalize(url) {
    try { return new URL(url, window.location.href).href; } catch (_) { return String(url || ""); }
  }

  function pkLibOrigin(url) {
    try { return new URL(url, window.location.href).origin; } catch (_) { return ""; }
  }

  function pkLibAnnounce(name) {
    var f = pkLibFailures[name];
    if (!f) return;
    var cause = f.reason === "csp"
      ? "blocked by the page's Content-Security-Policy (" + (f.directive || "script-src") + ")"
      : f.reason === "facts"
        ? "has no file: PhoenixKit's install facts (window.PHOENIX_KIT_LIBS) are missing or do not name it"
        : f.reason === "stale"
          ? "has no file in the outdated copy of the install facts this page ran (the server's copy names it)"
          : "could not be loaded or run (network, a missing file, or an error in the file)";
    console.error("[PhoenixKit] The " + name + " library " + cause + ": " + f.url +
      ". Features that need it are unavailable on this page. " +
      (f.reason === "csp"
        ? "Check that the page's policy allows " + (pkLibOrigin(f.url) || f.url) + "."
        : f.reason === "stale"
          ? "Reload the page."
          : "Check the network, and that the host build vendors PhoenixKit's JavaScript " +
            "(:phoenix_kit_js_sources in compilers, or mix phoenix_kit.update)."));
    try {
      window.dispatchEvent(new CustomEvent("pk:library-failed", {
        detail: { name: name, url: f.url, reason: f.reason, directive: f.directive || null }
      }));
    } catch (_) { /* very old browsers: the console line above still stands */ }
  }

  function pkLibFail(name, url, reason, directive) {
    var prev = pkLibFailures[name];
    // Already recorded with at least this much evidence: nothing new to say.
    if (prev && prev.url === url && (prev.reason === "csp" || reason !== "csp")) return;
    pkLibFailures[name] = { url: url, reason: reason, directive: directive || null };
    pkLibAnnounce(name);
  }

  // Matches a violation to one of our attempts by full URL, or by origin when
  // the browser stripped the blocked URI to one; anything else is ignored.
  if (!window.__pkLibCspListener) {
    window.__pkLibCspListener = true;
    document.addEventListener("securitypolicyviolation", function(e) {
      if (e.disposition === "report") return;
      var blocked = e.blockedURI || "";
      // "inline", "eval", "data", "blob", "" and the like are keywords, not
      // URLs: resolved against the page they would read as the page's own
      // origin and pin a same-origin library failure on an unrelated violation.
      if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(blocked)) return;
      var full = pkLibNormalize(blocked);
      var origin = pkLibOrigin(blocked);
      var directive = e.effectiveDirective || e.violatedDirective || null;
      var candidates = pkLibPending.concat(Object.keys(pkLibFailures).map(function(n) {
        return { name: n, url: pkLibFailures[n].url };
      }));
      for (var i = 0; i < candidates.length; i++) {
        var c = candidates[i];
        var cFull = pkLibNormalize(c.url);
        var match = cFull === full ||
          (origin && blocked.indexOf("/", blocked.indexOf("//") + 2) === -1 && pkLibOrigin(c.url) === origin);
        if (!match) continue;
        if (pkLibFailures[c.name]) {
          pkLibFail(c.name, c.url, "csp", directive);
        } else {
          c.csp = directive || "script-src";
        }
        return;
      }
    }, true);
  }

  // `opts.check()` — true once the library is usable (its global/hook).
  // `opts.module` — load with dynamic import() and resolve with the module.
  function loadLibrary(name, url, opts) {
    opts = opts || {};
    var check = opts.check || function() { return false; };

    if (!opts.module && check()) return Promise.resolve();
    if (pkLibInflight[name]) return pkLibInflight[name];

    if (opts.module && pkLibFailures[name] && pkLibFailures[name].terminal) {
      return Promise.reject(new Error(name + " failed to load earlier on this page"));
    }
    var attempts = pkLibAttempts[name] = (pkLibAttempts[name] || 0) + 1;
    if (!opts.module && !opts.unlimitedAttempts && attempts > LIBRARY_MAX_ATTEMPTS) {
      return Promise.reject(new Error(name + " failed to load"));
    }

    var attempt = { name: name, url: url, csp: null };
    pkLibPending.push(attempt);
    function settled() {
      pkLibPending = pkLibPending.filter(function(a) { return a !== attempt; });
      delete pkLibInflight[name];
    }

    var p;
    var urls = [url].concat(opts.fallback && opts.fallback !== url ? [opts.fallback] : []);
    if (opts.module) {
      // Same order as a script: the local copy, then an opted-in CDN once.
      var importAt = function(i) {
        attempt.url = urls[i];
        attempt.csp = null;
        return import(urls[i]).then(function(mod) {
          settled();
          delete pkLibFailures[name];
          return mod;
        }, function(err) {
          if (i + 1 < urls.length) return importAt(i + 1);
          settled();
          pkLibFail(name, urls[i], attempt.csp ? "csp" : "load", attempt.csp);
          if (pkLibFailures[name]) pkLibFailures[name].terminal = true;
          throw err;
        });
      };
      p = importAt(0);
    } else {
      // The local file first; the CDN only when the host opted in (the facts
      // name one). One failure report, after the last permitted attempt — a
      // failed local load rescued by the fallback leaves no alert behind.
      p = new Promise(function(resolve, reject) {
        function tryUrl(i) {
          var current = urls[i];
          attempt.url = current;
          attempt.csp = null;
          var script = document.createElement("script");
          script.src = current;
          // A page whose policy needs a nonce on every script (and does not grant
          // 'strict-dynamic') would refuse this one: carry the nonce of the script
          // that is loading it, when it had one. Only the host's own copy gets it
          // (urls[0]): the CDN fallback, which a host opts into, must still pass the
          // host's script-src allowlist, not skip it on a borrowed nonce.
          if (PK_SCRIPT_NONCE && i === 0) script.nonce = PK_SCRIPT_NONCE;
          // `ran`: the file arrived and was executed, but did not define what `check()` looks
          // for (it threw part-way, or is from another version). Unlike a failed request,
          // that will not heal by asking again, and a caller can tell the two apart.
          function failed(reason, ran) {
            // Removed so a later attempt (a remount, a reconnect) can try anew.
            script.remove();
            if (i + 1 < urls.length) { tryUrl(i + 1); return; }
            settled();
            pkLibFail(name, current, reason, attempt.csp);
            var err = new Error(name + " failed to load");
            if (ran) err.pkRan = true;
            reject(err);
          }
          script.onload = function() {
            if (check()) {
              settled();
              delete pkLibFailures[name];
              resolve();
            } else {
              failed("load", true);
            }
          };
          script.onerror = function() { failed(attempt.csp ? "csp" : "load"); };
          document.head.appendChild(script);
        }
        tryUrl(0);
      });
    }
    pkLibInflight[name] = p;
    return p;
  }

  // The page's undigested facts tag (a digested name changes with its content,
  // so it cannot be outdated), and the text of the server's copy of it,
  // fetched past the cache once per page (null when unreadable).
  function pkFactsSrc() {
    var list = document.scripts || [];
    for (var i = 0; i < list.length; i++) {
      var src = (list[i] && list[i].src) || "";
      if (/(^|\/)phoenix_kit_modules\.js$/.test(src.split(/[?#]/)[0])) return src;
    }
    return null;
  }

  var pkFreshFactsAt = {};
  function pkFreshFacts(src) {
    if (!pkFreshFactsAt[src]) {
      pkFreshFactsAt[src] = window.fetch(src, { cache: "reload", credentials: "same-origin" })
        .then(function(r) { return r.ok ? r.text() : null; })
        .catch(function() { return null; });
    }
    return pkFreshFactsAt[src];
  }

  // Whether facts text gives `key` a file. Read loosely, as the doctor does: a
  // host may run the file through its own minifier, which unquotes the keys
  // and joins the statements on one line. Nothing in the object holds a brace
  // in a string, so its end is found by counting them.
  function pkFactsName(text, key) {
    var at = text ? text.indexOf("PHOENIX_KIT_LIBS") : -1;
    var start = at < 0 ? -1 : text.indexOf("{", at);
    if (start < 0) return false;
    var depth = 0, i = start;
    for (; i < text.length; i++) {
      var c = text.charAt(i);
      if (c === "{") depth++;
      else if (c === "}" && --depth === 0) break;
    }
    if (depth !== 0) return false;
    var q = "[\"']?";
    return new RegExp(q + "\\b" + key.replace(/\W/g, "\\$&") + q + "\\s*:\\s*\\{[^{}]*?" + q +
      "\\bfile" + q + "\\s*:\\s*[\"'][^\"']+[\"']").test(text.slice(start, i + 1));
  }

  // Reported as missing facts at once; turned into "stale" when the page ran
  // a copy of the facts that lacks the file and the server's copy names it:
  // an outdated (cached) copy, which a reload cures — the fetch having
  // refreshed the cache.
  function pkFactsFail(name, key) {
    var prev = pkLibFailures[name];
    if (prev && prev.reason === "stale") return;
    pkLibFail(name, "lib/" + key, "facts");
    // The page ran some copy of the facts: one naming libraries, or one from
    // before PHOENIX_KIT_LIBS existed (2026-10), which still set
    // PHOENIX_KIT_CONSENT_AVAILABLE — only the facts file writes that one
    // (PHOENIX_KIT_PREFIX also comes from the globals component, so it
    // proves nothing).
    var ran = window.PHOENIX_KIT_LIBS;
    var ranFacts = !!ran || typeof window.PHOENIX_KIT_CONSENT_AVAILABLE === "boolean";
    var src = typeof window.fetch === "function" && ranFacts && !(ran && ran[key] && ran[key].file) && pkFactsSrc();
    if (!src) return;
    pkFreshFacts(src).then(function(fresh) {
      var now = pkLibFailures[name];
      if (now && now.reason === "facts" && pkFactsName(fresh, key)) pkLibFail(name, src, "stale");
    });
  }

  // A vendored library by its key in window.PHOENIX_KIT_LIBS. A pre-imported
  // copy still wins; with no facts there is nothing to load and the failure
  // says so (the notice tells the host to recompile or run phoenix_kit.update).
  function loadVendored(name, key, opts) {
    opts = opts || {};
    if (opts.check && opts.check()) return Promise.resolve();
    var urls = pkLibUrls(key);
    if (!urls) {
      pkFactsFail(name, key);
      var noFacts = new Error(name + ": no install facts name its file");
      noFacts.pkNoFacts = true; // no request was made, so a caller's pause after a failed request has nothing to protect
      return Promise.reject(noFacts);
    }
    return loadLibrary(name, urls.local, Object.assign({}, opts, { fallback: urls.cdn }));
  }

  // A hook that loads its library (`load()` chains any dependencies), then
  // becomes the library's own hook. One destroyed while loading never
  // mounts late.
  function lazyHook(load, pick) {
    return {
      mounted: function() {
        var self = this;
        self.__pkGone = false;
        load().then(function() {
          if (self.__pkGone) return;
          var real = pick();
          if (!real) return;
          Object.keys(real).forEach(function(key) {
            if (key !== "mounted") self[key] = real[key];
          });
          if (typeof real.mounted === "function") real.mounted.call(self);
        }, function() {
          // Already reported by loadLibrary; the feature stays unavailable.
        });
      },
      destroyed: function() {
        this.__pkGone = true;
      }
    };
  }

  // Loaders other blocks depend on (Tessera and Etcher wait for Fresco).
  var pkLoaders = {};

  // Chart.js, for the email dashboard and for a host's own charts. It used to be
  // pasted into the top of this file, so every page downloaded and parsed it;
  // now it is a vendored library like the others. Resolves to `window.Chart`
  // (a copy the host already provides wins, as before) and rejects once the
  // failure has been reported.
  function loadChartJs() {
    return loadVendored("Chart.js", "chartjs", {
      check: function() { return !!window.Chart; }
    }).then(function() { return window.Chart; });
  }

  window.PhoenixKitLibraries = {
    load: loadLibrary,
    loadVendored: loadVendored,
    urls: pkLibUrls,
    lazyHook: lazyHook,
    chartjs: loadChartJs,
    failures: pkLibFailures
  };

  // LibraryLoadNotice — fills the admin-only shell rendered beside the flash
  // group, from failures already recorded and from `pk:library-failed`. The
  // copy follows the evidence (CSP from another origin, CSP on this origin,
  // facts missing or outdated, or "could not load", cause unknown); text goes
  // in as textContent only.
  // Dismissal lasts the session, per library and URL.
  var LIB_NOTICE_KEY = "pk:library-notice:dismissed";

  function libNoticeDismissed() {
    try { return JSON.parse(sessionStorage.getItem(LIB_NOTICE_KEY) || "[]"); } catch (_) { return []; }
  }

  window.PhoenixKitHooks.LibraryLoadNotice = {
    mounted() {
      var self = this;
      this._onFailed = function() { self._render(); };
      window.addEventListener("pk:library-failed", this._onFailed);
      var dismiss = this.el.querySelector("[data-notice-dismiss]");
      if (dismiss) {
        dismiss.addEventListener("click", function() {
          var seen = libNoticeDismissed().concat(self._shown || []);
          try { sessionStorage.setItem(LIB_NOTICE_KEY, JSON.stringify(seen)); } catch (_) {}
          self.el.hidden = true;
        });
      }
      this._render();
    },

    destroyed() {
      window.removeEventListener("pk:library-failed", this._onFailed);
    },

    _render() {
      var el = this.el;
      var failures = window.__pkLibFailures || {};
      var dismissed = libNoticeDismissed();
      var names = Object.keys(failures).filter(function(name) {
        return dismissed.indexOf(name + "|" + failures[name].url) === -1;
      });
      this._shown = names.map(function(name) { return name + "|" + failures[name].url; });
      if (!names.length) { el.hidden = true; return; }

      var d = el.dataset;
      el.querySelector("[data-notice-title]").textContent = d.title || "";
      el.querySelector("[data-notice-audience]").textContent = d.audience || "";
      var list = el.querySelector("[data-notice-list]");
      list.textContent = "";
      names.forEach(function(name) {
        var f = failures[name];
        var origin = "";
        try { origin = new URL(f.url, window.location.href).origin; } catch (_) {}
        var text;
        if (f.reason === "csp") {
          text = (origin === window.location.origin ? d.cspSelf : d.cspOther) || "";
          text = text.replace("%{directive}", f.directive || "script-src").replace("%{origin}", origin);
        } else if (f.reason === "facts") {
          text = d.facts || "";
        } else if (f.reason === "stale") {
          text = d.stale || d.facts || "";
        } else {
          text = d.load || "";
        }
        var li = document.createElement("li");
        var strong = document.createElement("strong");
        strong.textContent = name + ": ";
        var reason = document.createElement("span");
        reason.textContent = text + " ";
        var url = document.createElement("code");
        url.style.wordBreak = "break-all";
        url.style.fontSize = "0.75em";
        url.textContent = f.url;
        li.appendChild(strong);
        li.appendChild(reason);
        li.appendChild(url);
        list.appendChild(li);
      });
      el.hidden = false;
    }
  };

  // ============================================================================
  // FRESCO DAISYUI THEME INTEGRATION
  // ============================================================================
  //
  // Map Fresco's six --fresco-* custom properties to daisyUI tokens so any
  // viewer that opts into `theme={:inherit}` follows whichever daisyUI theme
  // is active on <html>. Injected here (not in a stylesheet) because
  // phoenix_kit's app.css isn't necessarily loaded by every parent app —
  // the JS bundle, however, always is.
  //
  // base-200 / base-300 read as light grays on light themes and dark grays
  // on dark themes, so nav buttons render as subtle chips on either side.
  // Using --color-neutral here would give near-black chips on every theme,
  // which fights with the typical light/dark expectation.
  // ============================================================================

  (function injectFrescoDaisyUIStyles() {
    try {
      if (document.querySelector("style[data-phoenix-kit-fresco]")) return;
      var style = document.createElement("style");
      style.setAttribute("data-phoenix-kit-fresco", "");
      pkAdoptStyle(style);
      style.textContent = [
        ".fresco-viewer[data-fresco-theme=\"inherit\"] {",
        "  --fresco-bg: var(--color-base-100);",
        "  --fresco-grid-dot: var(--color-base-300);",
        "  --fresco-nav-bg: var(--color-base-200);",
        "  --fresco-nav-bg-hover: var(--color-base-300);",
        "  --fresco-nav-fg: var(--color-base-content);",
        "  --fresco-nav-focus: var(--color-primary);",
        "}"
      ].join("\n");
      (document.head || document.documentElement).appendChild(style);
    } catch (e) {
      console.debug("[PhoenixKit] Fresco theme injection failed:", e);
    }
  })();


  // ============================================================================
  // 2. COOKIE CONSENT MODULE
  // ============================================================================
  //
  // GDPR/CCPA compliant cookie consent management with:
  // - Configurable consent frameworks (GDPR, CCPA, etc.)
  // - Google Consent Mode v2 integration
  // - Script blocking/unblocking by category
  // - Cross-tab synchronization
  // - Customizable UI with banner and modal
  //
  // Usage: The module auto-initializes by fetching config from the server.
  // Or use the CookieConsent hook with data attributes on an element.
  //
  // ============================================================================

  (function() {
    if (window.PhoenixKitConsent) return;

    // ---------------------------------------------------------------------------
    // Constants & Configuration
    // ---------------------------------------------------------------------------

    var STORAGE_KEY = "pk_consent";
    var VERSION_KEY = "pk_consent_version";
    var CATEGORIES = ["necessary", "analytics", "marketing", "preferences"];
    var OPT_IN_FRAMEWORKS = ["gdpr", "uk_gdpr", "lgpd", "pipeda"];

    var PhoenixKitConsent = {
      initialized: false,
      config: {
        frameworks: [],
        policyVersion: "1.0",
        googleConsentMode: false,
        iconPosition: "bottom-right",
        showIcon: false,
        cookiePolicyUrl: "/legal/cookie-policy",
        privacyPolicyUrl: "/legal/privacy-policy"
      },
      consent: null,
      elements: { root: null, icon: null, banner: null, modal: null }
    };

    // ---------------------------------------------------------------------------
    // Utility Functions
    // ---------------------------------------------------------------------------

    function log(message, data) {
      if (typeof console !== "undefined" && console.debug) {
        console.debug("[PhoenixKit:Consent] " + message, data || "");
      }
    }

    function getConfigEndpoint() {
      // PHOENIX_KIT_PREFIX is emitted by the phoenix_kit_js_sources compiler.
      // The "/phoenix_kit" fallback is for a host that predates it — which is
      // exactly how a custom-prefix install ended up requesting a path that
      // does not exist on it.
      var prefix = window.PHOENIX_KIT_PREFIX || "/phoenix_kit";
      // Handle case when prefix is "/" to avoid double slash (//api/...)
      if (prefix === "/") {
        return "/api/consent-config";
      }
      return prefix + "/api/consent-config";
    }

    function isOptInMode() {
      var frameworks = PhoenixKitConsent.config.frameworks;
      for (var i = 0; i < OPT_IN_FRAMEWORKS.length; i++) {
        if (frameworks.indexOf(OPT_IN_FRAMEWORKS[i]) !== -1) return true;
      }
      return false;
    }

    // ---------------------------------------------------------------------------
    // Storage Functions
    // ---------------------------------------------------------------------------

    function loadConsent() {
      try {
        var stored = localStorage.getItem(STORAGE_KEY);
        if (stored) return JSON.parse(stored);
      } catch (e) {
        log("Could not load consent", e);
      }
      return null;
    }

    function saveConsent(consent) {
      try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(consent));
        localStorage.setItem(VERSION_KEY, PhoenixKitConsent.config.policyVersion);
        log("Consent saved", consent);
      } catch (e) {
        log("Could not save consent", e);
      }
    }

    function getStoredVersion() {
      try {
        return localStorage.getItem(VERSION_KEY);
      } catch (e) {
        return null;
      }
    }

    function shouldShowBanner() {
      var stored = loadConsent();
      var storedVersion = getStoredVersion();
      var currentVersion = PhoenixKitConsent.config.policyVersion;
      var consentMode = PhoenixKitConsent.config.consentMode;

      if (consentMode === "notice") return !stored;
      if (!stored || storedVersion !== currentVersion) return true;
      return false;
    }

    // ---------------------------------------------------------------------------
    // Cross-Tab Synchronization
    // ---------------------------------------------------------------------------

    function setupCrossTabSync() {
      window.addEventListener("storage", function(e) {
        if (e.key === STORAGE_KEY && e.newValue) {
          try {
            var newConsent = JSON.parse(e.newValue);
            PhoenixKitConsent.consent = newConsent;
            applyConsent(newConsent);
            updateUI();
            log("Cross-tab sync: consent updated");
          } catch (err) {
            log("Cross-tab sync error", err);
          }
        }
      });
    }

    // ---------------------------------------------------------------------------
    // Google Consent Mode v2 Integration
    // ---------------------------------------------------------------------------

    function initGoogleConsentMode() {
      if (!PhoenixKitConsent.config.googleConsentMode) return;

      window.dataLayer = window.dataLayer || [];
      function gtag() { window.dataLayer.push(arguments); }

      gtag("consent", "default", {
        "ad_storage": "denied",
        "analytics_storage": "denied",
        "ad_user_data": "denied",
        "ad_personalization": "denied",
        "personalization_storage": "denied",
        "functionality_storage": "granted",
        "security_storage": "granted",
        "wait_for_update": 500
      });
      gtag("set", "ads_data_redaction", true);
      gtag("set", "url_passthrough", true);

      log("Google Consent Mode v2 initialized");
    }

    function updateGoogleConsent(consent) {
      if (!PhoenixKitConsent.config.googleConsentMode) return;

      window.dataLayer = window.dataLayer || [];
      function gtag() { window.dataLayer.push(arguments); }

      gtag("consent", "update", {
        "analytics_storage": consent.analytics ? "granted" : "denied",
        "ad_storage": consent.marketing ? "granted" : "denied",
        "ad_user_data": consent.marketing ? "granted" : "denied",
        "ad_personalization": consent.marketing ? "granted" : "denied",
        "personalization_storage": consent.preferences ? "granted" : "denied"
      });

      log("Google Consent Mode updated", consent);
    }

    function resetGoogleConsentMode() {
      if (typeof window.dataLayer === "undefined") return;

      function gtag() { window.dataLayer.push(arguments); }
      gtag("consent", "update", {
        "ad_storage": "granted",
        "analytics_storage": "granted",
        "ad_user_data": "granted",
        "ad_personalization": "granted",
        "personalization_storage": "granted",
        "functionality_storage": "granted",
        "security_storage": "granted"
      });

      log("Google Consent Mode reset to granted (widget disabled)");
    }

    // ---------------------------------------------------------------------------
    // Script Blocking/Unblocking
    // ---------------------------------------------------------------------------

    function blockScripts() {
      var scripts = document.querySelectorAll("script[data-consent-category]");
      scripts.forEach(function(script) {
        var category = script.getAttribute("data-consent-category");
        if (category !== "necessary") {
          script.setAttribute("type", "text/plain");
          script.setAttribute("data-blocked", "true");
        }
      });
      log("Non-essential scripts blocked");
    }

    function unblockScripts(category) {
      var scripts = document.querySelectorAll(
        'script[data-consent-category="' + category + '"][data-blocked="true"]'
      );
      scripts.forEach(function(script) {
        var newScript = document.createElement("script");
        Array.from(script.attributes).forEach(function(attr) {
          if (attr.name !== "type" && attr.name !== "data-blocked" && attr.name !== "nonce") {
            newScript.setAttribute(attr.name, attr.value);
          }
        });
        // The browser hides a script's nonce in its content attribute (`nonce=""`)
        // while keeping the value on `script.nonce`. Skipping "nonce" above
        // avoids `setAttribute("nonce", "")` clearing it on spec-compliant
        // engines, and copying `.nonce` preserves it. An original with none
        // stays without one.
        if (script.nonce) newScript.nonce = script.nonce;
        if (script.src) {
          newScript.src = script.src;
        } else {
          newScript.textContent = script.textContent;
        }
        script.parentNode.replaceChild(newScript, script);
      });
      if (scripts.length > 0) {
        log("Scripts unblocked for category: " + category);
      }
    }

    function applyConsent(consent) {
      CATEGORIES.forEach(function(category) {
        if (consent[category]) unblockScripts(category);
      });
      updateGoogleConsent(consent);
      window.dispatchEvent(new CustomEvent("phx:consent-updated", {
        detail: { consent: consent }
      }));
    }

    // ---------------------------------------------------------------------------
    // UI Helper Functions
    // ---------------------------------------------------------------------------

    function getIconPositionClass(position) {
      switch (position) {
        case "bottom-left": return "bottom: 1rem; left: 1rem;";
        case "top-left": return "top: 1rem; left: 1rem;";
        case "top-right": return "top: 1rem; right: 1rem;";
        default: return "bottom: 1rem; right: 1rem;";
      }
    }

    function createCategoryHTML(id, icon, name, description, required) {
      var checkedAttr = required ? ' checked disabled' : '';
      var requiredBadge = required
        ? '<span class="badge badge-ghost badge-xs" style="margin-left:0.5rem">Required</span>'
        : '';

      return '<div class="pk-category-card" style="border-radius:0.75rem;padding:1rem;margin-bottom:0.75rem">' +
        '<div style="display:flex;align-items:flex-start;justify-content:space-between;gap:0.75rem">' +
          '<div style="display:flex;align-items:flex-start;gap:0.75rem;flex:1">' +
            '<span style="font-size:1.25rem">' + icon + '</span>' +
            '<div>' +
              '<div style="display:flex;align-items:center">' +
                '<span style="font-weight:500;font-size:0.875rem;color:var(--pk-text)">' + name + '</span>' +
                requiredBadge +
              '</div>' +
              '<p style="font-size:0.75rem;color:var(--pk-text-muted);margin:0.25rem 0 0 0">' + description + '</p>' +
            '</div>' +
          '</div>' +
          '<label style="position:relative;display:inline-flex;cursor:pointer;flex-shrink:0">' +
            '<input type="checkbox" id="pk-consent-' + id + '" class="toggle toggle-primary toggle-sm" data-category="' + id + '"' + checkedAttr + '>' +
          '</label>' +
        '</div>' +
      '</div>';
    }

    // ---------------------------------------------------------------------------
    // Widget HTML Generation
    // ---------------------------------------------------------------------------

    function createWidgetHTML(config) {
      var showIcon = isOptInMode();
      var iconStyle = getIconPositionClass(config.icon_position || config.iconPosition);
      var cookiePolicyUrl = config.cookie_policy_url || '/legal/cookie-policy';
      var privacyPolicyUrl = config.privacy_policy_url || '/legal/privacy-policy';

      // The widget's rules. A <style> inside the HTML string below is ignored
      // under a nonce policy (innerHTML cannot carry a nonce); injectWidget
      // builds the element and stamps the page's style nonce on it.
      var styles = 
        '.pk-consent-widget{' +
          '--pk-bg:oklch(var(--b1));' +
          '--pk-bg-alt:oklch(var(--b2));' +
          '--pk-border:oklch(var(--b3));' +
          '--pk-text:oklch(var(--bc));' +
          '--pk-text-muted:oklch(var(--bc)/0.6);' +
          '--pk-primary:oklch(var(--p));' +
          '--pk-primary-content:oklch(var(--pc));' +
          '--pk-primary-soft:oklch(var(--p)/0.1);' +
          '--pk-primary-glow:oklch(var(--p)/0.4);' +
          '--pk-shadow:0 8px 32px oklch(var(--bc)/0.12);' +
        '}' +
        '@keyframes pk-breathe{' +
          '0%,100%{box-shadow:0 0 0 0 var(--pk-primary-glow),0 4px 12px oklch(var(--bc)/0.15)}' +
          '50%{box-shadow:0 0 0 8px transparent,0 4px 16px oklch(var(--bc)/0.2)}' +
        '}' +
        '@keyframes pk-slide-up{from{opacity:0;transform:translateY(20px)}to{opacity:1;transform:translateY(0)}}' +
        '@keyframes pk-fade-in{from{opacity:0}to{opacity:1}}' +
        '.pk-floating-icon{' +
          'animation:pk-breathe 3s ease-in-out infinite;' +
          'transition:transform 0.2s cubic-bezier(0.34,1.56,0.64,1),box-shadow 0.2s ease' +
        '}' +
        '.pk-floating-icon:hover{' +
          'transform:scale(1.1);' +
          'animation:none;' +
          'box-shadow:0 0 0 4px var(--pk-primary-glow),0 8px 24px oklch(var(--bc)/0.25)' +
        '}' +
        '.pk-floating-icon:active{transform:scale(0.95)}' +
        '.pk-banner{animation:pk-slide-up 0.4s cubic-bezier(0.16,1,0.3,1) forwards}' +
        '.pk-modal-backdrop{animation:pk-fade-in 0.2s ease forwards}' +
        '.pk-modal-content{animation:pk-slide-up 0.3s cubic-bezier(0.16,1,0.3,1) forwards}' +
        '.pk-glass{' +
          'background:oklch(var(--b1)/0.95);' +
          'backdrop-filter:blur(20px) saturate(180%);' +
          '-webkit-backdrop-filter:blur(20px) saturate(180%);' +
          'border:1px solid var(--pk-border);' +
          'box-shadow:var(--pk-shadow)' +
        '}' +
        '.pk-category-card{' +
          'transition:all 0.2s ease;' +
          'background:var(--pk-bg-alt);' +
          'border:1px solid var(--pk-border)' +
        '}' +
        '.pk-category-card:hover{transform:translateY(-2px);box-shadow:0 4px 12px oklch(var(--bc)/0.1)}' +
        '.pk-toggle-track{background:var(--pk-border);transition:background 0.2s}' +
        '.pk-toggle-track.active{background:var(--pk-primary)}' +
        '.pk-toggle-thumb{background:var(--pk-bg);box-shadow:0 1px 3px oklch(var(--bc)/0.2)}';

      // Floating Icon (only shown in opt-in mode)
      var iconHTML = showIcon
        ? '<button id="pk-consent-icon" type="button" data-pk-consent="openPreferences" ' +
            'class="pk-floating-icon pk-glass" ' +
            'style="position:fixed;z-index:50;width:3rem;height:3rem;border-radius:9999px;display:flex;align-items:center;justify-content:center;cursor:pointer;background:var(--pk-primary);' + iconStyle + '" ' +
            'aria-label="Cookie preferences" title="Cookie preferences">' +
            '<svg style="width:1.5rem;height:1.5rem;color:var(--pk-primary-content)" viewBox="0 0 24 24" fill="currentColor">' +
              '<path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/>' +
            '</svg>' +
          '</button>'
        : '';

      // Cookie icon SVG (reused in banner and modal)
      var cookieIconSVG = '<svg style="width:1.25rem;height:1.25rem;color:var(--pk-primary)" viewBox="0 0 24 24" fill="currentColor">' +
        '<path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93z"/>' +
      '</svg>';

      // Shield icon SVG for modal header
      var shieldIconSVG = '<svg style="width:1.25rem;height:1.25rem;color:var(--pk-primary)" viewBox="0 0 24 24" fill="currentColor">' +
        '<path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/>' +
      '</svg>';

      // Close icon SVG
      var closeIconSVG = '<svg style="width:1.25rem;height:1.25rem" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">' +
        '<path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/>' +
      '</svg>';

      // Banner HTML
      var bannerHTML = '<div id="pk-consent-banner" class="pk-banner pk-glass" ' +
        'style="position:fixed;bottom:0;left:0;right:0;z-index:50;display:none;border-radius:0" ' +
        'role="dialog" aria-label="Cookie consent" aria-hidden="true">' +
        '<div style="max-width:64rem;margin:0 auto;padding:1rem 1.5rem">' +
          '<div style="display:flex;flex-wrap:wrap;align-items:center;gap:1rem">' +
            '<div style="flex:1;display:flex;align-items:flex-start;gap:0.75rem;min-width:200px">' +
              '<div style="flex-shrink:0;width:2.5rem;height:2.5rem;border-radius:9999px;background:var(--pk-primary-soft);display:flex;align-items:center;justify-content:center">' +
                cookieIconSVG +
              '</div>' +
              '<div>' +
                '<h3 style="font-weight:600;font-size:0.875rem;margin:0;color:var(--pk-text)">We value your privacy</h3>' +
                '<p style="font-size:0.75rem;color:var(--pk-text-muted);margin:0.25rem 0 0 0">' +
                  'We use cookies to enhance your experience. ' +
                  '<a href="' + cookiePolicyUrl + '" style="color:var(--pk-primary);text-decoration:underline" target="_blank">Cookie Policy</a>' +
                '</p>' +
              '</div>' +
            '</div>' +
            '<div style="display:flex;gap:0.5rem;flex-wrap:wrap">' +
              '<button type="button" data-pk-consent="openPreferences" class="btn btn-ghost btn-sm" style="font-size:0.75rem">Customize</button>' +
              '<button type="button" data-pk-consent="rejectAll" class="btn btn-outline btn-sm" style="font-size:0.75rem">Reject</button>' +
              '<button type="button" data-pk-consent="acceptAll" class="btn btn-primary btn-sm" style="font-size:0.75rem">Accept All</button>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>';

      // Modal HTML
      var modalHTML = '<div id="pk-consent-modal" ' +
        'style="position:fixed;inset:0;z-index:100;display:none" ' +
        'role="dialog" aria-modal="true" aria-label="Cookie preferences">' +
        '<div class="pk-modal-backdrop" data-pk-consent="closePreferences" ' +
          'style="position:absolute;inset:0;background:oklch(var(--bc)/0.4);backdrop-filter:blur(4px)"></div>' +
        '<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:1rem;pointer-events:none">' +
          '<div class="pk-modal-content pk-glass" style="width:100%;max-width:28rem;max-height:85vh;overflow:hidden;border-radius:1rem;pointer-events:auto">' +
            // Modal Header
            '<div style="display:flex;align-items:center;justify-content:space-between;padding:1rem 1.5rem;border-bottom:1px solid var(--pk-border)">' +
              '<div style="display:flex;align-items:center;gap:0.75rem;flex:1">' +
                '<div style="width:2.5rem;height:2.5rem;border-radius:9999px;background:var(--pk-primary-soft);display:flex;align-items:center;justify-content:center">' +
                  shieldIconSVG +
                '</div>' +
                '<div>' +
                  '<h2 style="font-weight:600;font-size:1.125rem;margin:0;color:var(--pk-text)">Privacy Preferences</h2>' +
                  '<p style="font-size:0.75rem;color:var(--pk-text-muted);margin:0">Manage your cookie settings</p>' +
                '</div>' +
              '</div>' +
              '<button type="button" data-pk-consent="closePreferences" class="btn btn-ghost btn-sm btn-circle" aria-label="Close">' +
                closeIconSVG +
              '</button>' +
            '</div>' +
            // Modal Body - Category Cards
            '<div style="padding:1rem 1.5rem;overflow-y:auto;max-height:50vh">' +
              createCategoryHTML("necessary", "🔒", "Essential", "Required for core functionality. Cannot be disabled.", true) +
              createCategoryHTML("analytics", "📊", "Analytics", "Help us understand how you use our site.") +
              createCategoryHTML("marketing", "📢", "Marketing", "Used for personalized advertising.") +
              createCategoryHTML("preferences", "⚙️", "Preferences", "Remember your settings and preferences.") +
            '</div>' +
            // Modal Footer
            '<div style="padding:1rem 1.5rem;border-top:1px solid var(--pk-border);background:var(--pk-bg-alt)">' +
              '<div style="display:flex;flex-wrap:wrap;align-items:center;gap:0.75rem">' +
                '<div style="font-size:0.75rem;color:var(--pk-text-muted)">' +
                  '<a href="' + privacyPolicyUrl + '" style="color:inherit;text-decoration:underline" target="_blank">Privacy Policy</a>' +
                  ' • ' +
                  '<a href="' + cookiePolicyUrl + '" style="color:inherit;text-decoration:underline" target="_blank">Cookie Policy</a>' +
                '</div>' +
                '<div style="margin-left:auto;display:flex;gap:0.5rem">' +
                  '<button type="button" data-pk-consent="rejectAll" class="btn btn-ghost btn-sm" style="font-size:0.75rem">Reject All</button>' +
                  '<button type="button" data-pk-consent="savePreferences" class="btn btn-primary btn-sm" style="font-size:0.75rem">Save Preferences</button>' +
                '</div>' +
              '</div>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>';

      return {
        css: styles,
        html: '<div id="pk-consent-root" class="pk-consent-widget">' +
          iconHTML + bannerHTML + modalHTML +
        '</div>'
      };
    }

    // ---------------------------------------------------------------------------
    // UI Show/Hide Functions
    // ---------------------------------------------------------------------------

    // The widget's buttons name their action (`data-pk-consent="acceptAll"`);
    // an inline onclick would be blocked by a strict Content-Security-Policy.
    var CONSENT_ACTIONS = ["openPreferences", "closePreferences", "acceptAll", "rejectAll", "savePreferences"];

    function onConsentClick(e) {
      var el = e.target && typeof e.target.closest === "function"
        ? e.target.closest("[data-pk-consent]")
        : null;
      if (!el) return;
      var action = el.getAttribute("data-pk-consent");
      if (CONSENT_ACTIONS.indexOf(action) === -1) return;
      var fn = window.PhoenixKitConsent && window.PhoenixKitConsent[action];
      if (typeof fn === "function") fn();
    }

    if (typeof module === "object" && module.exports) {
      module.exports.onConsentClick = onConsentClick;
    }

    document.addEventListener("click", onConsentClick);

    function injectWidget(config) {
      var existing = document.getElementById("pk-consent-root");
      if (existing) existing.remove();

      var built = createWidgetHTML(config);
      var container = document.createElement("div");
      container.innerHTML = built.html;
      var root = container.firstChild;
      var style = document.createElement("style");
      pkAdoptStyle(style);
      style.textContent = built.css;
      root.insertBefore(style, root.firstChild);
      document.body.appendChild(root);

      log("Widget injected into DOM");
    }

    function showBanner() {
      var banner = document.getElementById("pk-consent-banner");
      if (banner) {
        banner.style.display = "block";
        banner.setAttribute("aria-hidden", "false");
      }
    }

    function hideBanner() {
      var banner = document.getElementById("pk-consent-banner");
      if (banner) {
        banner.style.display = "none";
        banner.setAttribute("aria-hidden", "true");
      }
    }

    function showIcon() {
      var icon = document.getElementById("pk-consent-icon");
      if (icon && isOptInMode()) {
        icon.style.display = "flex";
        icon.style.opacity = "1";
      }
    }

    function hideIcon() {
      var icon = document.getElementById("pk-consent-icon");
      if (icon) {
        icon.style.opacity = "0";
      }
    }

    function showModal() {
      var modal = document.getElementById("pk-consent-modal");
      if (modal) {
        modal.style.display = "block";
        hideBanner();
        setTimeout(function() {
          var firstButton = modal.querySelector("button");
          if (firstButton) firstButton.focus();
        }, 100);
      }
    }

    function hideModal() {
      var modal = document.getElementById("pk-consent-modal");
      if (modal) {
        modal.style.display = "none";
      }
    }

    function updateCheckboxes() {
      var consent = PhoenixKitConsent.consent || {};
      CATEGORIES.forEach(function(category) {
        var checkbox = document.getElementById("pk-consent-" + category);
        if (checkbox && !checkbox.disabled) {
          checkbox.checked = !!consent[category];
        }
      });
    }

    function readCheckboxes() {
      var preferences = { necessary: true };
      CATEGORIES.forEach(function(category) {
        if (category === "necessary") return;
        var checkbox = document.getElementById("pk-consent-" + category);
        preferences[category] = checkbox ? checkbox.checked : false;
      });
      return preferences;
    }

    function updateUI() {
      if (shouldShowBanner()) {
        showBanner();
        hideIcon();
      } else {
        hideBanner();
        showIcon();
      }
      updateCheckboxes();
    }

    // ---------------------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------------------

    PhoenixKitConsent.acceptAll = function() {
      var consent = {
        necessary: true,
        analytics: true,
        marketing: true,
        preferences: true,
        timestamp: new Date().toISOString()
      };
      PhoenixKitConsent.consent = consent;
      saveConsent(consent);
      applyConsent(consent);
      hideBanner();
      hideModal();
      showIcon();
      log("All cookies accepted");
    };

    PhoenixKitConsent.rejectAll = function() {
      var consent = {
        necessary: true,
        analytics: false,
        marketing: false,
        preferences: false,
        timestamp: new Date().toISOString()
      };
      PhoenixKitConsent.consent = consent;
      saveConsent(consent);
      applyConsent(consent);
      hideBanner();
      hideModal();
      showIcon();
      log("Non-essential cookies rejected");
    };

    PhoenixKitConsent.savePreferences = function() {
      var preferences = readCheckboxes();
      preferences.timestamp = new Date().toISOString();
      PhoenixKitConsent.consent = preferences;
      saveConsent(preferences);
      applyConsent(preferences);
      hideModal();
      showIcon();
      log("Preferences saved", preferences);
    };

    PhoenixKitConsent.openPreferences = function() {
      updateCheckboxes();
      showModal();
      log("Preferences modal opened");
    };

    PhoenixKitConsent.closePreferences = function() {
      hideModal();
      log("Preferences modal closed");
    };

    PhoenixKitConsent.getConsent = function() {
      return PhoenixKitConsent.consent;
    };

    PhoenixKitConsent.hasConsent = function(category) {
      return PhoenixKitConsent.consent && !!PhoenixKitConsent.consent[category];
    };

    PhoenixKitConsent.revokeConsent = function() {
      try {
        localStorage.removeItem(STORAGE_KEY);
        localStorage.removeItem(VERSION_KEY);
        PhoenixKitConsent.consent = null;
        updateUI();
        log("Consent revoked");
      } catch (e) {
        log("Could not revoke consent", e);
      }
    };

    // ---------------------------------------------------------------------------
    // Initialization Functions
    // ---------------------------------------------------------------------------

    function initFromConfig(config) {
      if (config.should_show === false) {
        log("Widget hidden (user authenticated or disabled)");
        return;
      }

      PhoenixKitConsent.config = {
        frameworks: config.frameworks || [],
        consentMode: config.consent_mode || "strict",
        policyVersion: config.policy_version || "1.0",
        googleConsentMode: config.google_consent_mode || false,
        iconPosition: config.icon_position || "bottom-right",
        showIcon: config.show_icon || false,
        cookiePolicyUrl: config.cookie_policy_url || "/legal/cookie-policy",
        privacyPolicyUrl: config.privacy_policy_url || "/legal/privacy-policy"
      };

      injectWidget(config);

      PhoenixKitConsent.elements = {
        root: document.getElementById("pk-consent-root"),
        icon: document.getElementById("pk-consent-icon"),
        banner: document.getElementById("pk-consent-banner"),
        modal: document.getElementById("pk-consent-modal")
      };

      if (PhoenixKitConsent.config.consentMode === "strict") {
        initGoogleConsentMode();
      }

      setupCrossTabSync();

      var stored = loadConsent();
      if (stored) {
        PhoenixKitConsent.consent = stored;
        applyConsent(stored);
      } else if (isOptInMode() && PhoenixKitConsent.config.consentMode === "strict") {
        blockScripts();
      }

      updateUI();

      document.addEventListener("keydown", function(e) {
        if (e.key === "Escape") hideModal();
      });

      PhoenixKitConsent.initialized = true;
      log("Initialized with config", PhoenixKitConsent.config);
    }

    function initFromElement(rootElement) {
      var config = {
        frameworks: JSON.parse(rootElement.dataset.frameworks || "[]"),
        consent_mode: rootElement.dataset.consentMode || "strict",
        policy_version: rootElement.dataset.policyVersion || "1.0",
        google_consent_mode: rootElement.dataset.googleConsentMode === "true",
        icon_position: rootElement.dataset.iconPosition || "bottom-right",
        show_icon: rootElement.dataset.showIcon === "true",
        cookie_policy_url: rootElement.dataset.cookiePolicyUrl || "/legal/cookie-policy",
        privacy_policy_url: rootElement.dataset.privacyPolicyUrl || "/legal/privacy-policy"
      };

      PhoenixKitConsent.config = {
        frameworks: config.frameworks,
        consentMode: config.consent_mode,
        policyVersion: config.policy_version,
        googleConsentMode: config.google_consent_mode,
        iconPosition: config.icon_position,
        showIcon: config.show_icon,
        cookiePolicyUrl: config.cookie_policy_url,
        privacyPolicyUrl: config.privacy_policy_url
      };

      PhoenixKitConsent.elements = {
        root: rootElement,
        icon: document.getElementById("pk-consent-icon"),
        banner: document.getElementById("pk-consent-banner"),
        modal: document.getElementById("pk-consent-modal")
      };

      if (PhoenixKitConsent.config.consentMode === "strict") {
        initGoogleConsentMode();
      }

      setupCrossTabSync();

      var stored = loadConsent();
      if (stored) {
        PhoenixKitConsent.consent = stored;
        applyConsent(stored);
      } else if (isOptInMode() && PhoenixKitConsent.config.consentMode === "strict") {
        blockScripts();
      }

      updateUI();

      document.addEventListener("keydown", function(e) {
        if (e.key === "Escape") hideModal();
      });

      PhoenixKitConsent.initialized = true;
      log("Initialized from element", PhoenixKitConsent.config);
    }

    function fetchConfigAndInit() {
      // Set by the phoenix_kit_js_sources compiler. When phoenix_kit_legal is
      // not installed there is nothing to fetch, so skip the round-trip
      // entirely rather than making one request per page load to be told 204.
      if (window.PHOENIX_KIT_CONSENT_AVAILABLE === false) {
        log("Legal module not installed; consent widget unavailable");
        return;
      }

      fetch(getConfigEndpoint(), { credentials: "same-origin" })
        .then(function(response) {
          // 204 = no Legal module. It carries no body ON PURPOSE: a body
          // saying consent is disabled would be read as a live config by
          // bundles vendored before this endpoint existed, and they respond by
          // calling resetGoogleConsentMode() — GRANTING every category on an
          // install that never opted into consent management at all. Treat it
          // as "nothing to do" and touch nothing.
          if (response.status === 204) return null;
          if (!response.ok) {
            throw new Error("Config endpoint returned " + response.status);
          }
          return response.json();
        })
        .then(function(config) {
          if (!config) return;
          if (config.enabled && config.should_show !== false) {
            initFromConfig(config);
          } else {
            log("Consent widget is disabled");
            resetGoogleConsentMode();
          }
        })
        .catch(function(err) {
          log("Could not fetch config (widget disabled or endpoint unavailable)", err);
        });
    }

    // ---------------------------------------------------------------------------
    // CookieConsent Hook
    // ---------------------------------------------------------------------------

    window.PhoenixKitHooks.CookieConsent = {
      mounted: function() {
        if (!PhoenixKitConsent.initialized) {
          initFromElement(this.el);
        }
      },
      destroyed: function() {
        PhoenixKitConsent.initialized = false;
      }
    };

    // ---------------------------------------------------------------------------
    // Export & Auto-Initialize
    // ---------------------------------------------------------------------------

    window.PhoenixKitConsent = PhoenixKitConsent;

    document.addEventListener("DOMContentLoaded", function() {
      var existingRoot = document.getElementById("pk-consent-root");
      if (existingRoot) {
        log("Widget already in DOM, waiting for LiveView hook");
        return;
      }
      fetchConfigAndInit();
    });
  })();


  // ============================================================================
  // 3. UTILITY HOOKS
  // ============================================================================
  //
  // Small, focused hooks for common UI interactions.
  //
  // ============================================================================

  // ---------------------------------------------------------------------------
  // TimezoneOffset Hook
  // ---------------------------------------------------------------------------
  //
  // Fills a hidden input with the browser's UTC offset in hours (e.g. "2",
  // "-5.5") on mount, so a new account starts with a timezone instead of
  // "Not set" — the server has no way to know the visitor's timezone on its
  // own. Rounded to the nearest quarter hour to match the offsets PhoenixKit
  // actually offers (whole and half/45-minute zones like UTC+5:30, +5:45).
  // Never overwrites a value the server already rendered (e.g. re-render
  // after a validation error), and the field pairs with phx-update="ignore"
  // so LiveView leaves it alone after this first mount.
  //
  // Usage in LiveView template:
  //   <input type="hidden" name="user[user_timezone]" phx-hook="TimezoneOffset" phx-update="ignore" />
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.TimezoneOffset = {
    mounted() {
      if (this.el.value) return;
      var offsetHours = -new Date().getTimezoneOffset() / 60;
      var rounded = Math.round(offsetHours * 4) / 4;
      this.el.value = String(rounded);
    }
  };

  // ---------------------------------------------------------------------------
  // TimezoneDetector Hook
  // ---------------------------------------------------------------------------
  //
  // Reports the browser's IANA zone (e.g. "Europe/Warsaw") and its current UTC
  // offset to the LiveView, so the profile can say what it detected and warn
  // when the saved zone disagrees.
  //
  // Sends on mount and whenever the timezone select changes, as a plain
  // pushEvent rather than by injecting hidden inputs into the form the way the
  // original did — the form is owned by LiveView, and appending fields to it
  // from outside is how this stopped working the first time.
  //
  // Usage in LiveView template:
  //   <div id="..." phx-hook="TimezoneDetector" phx-target={@myself}>
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.TimezoneDetector = {
    mounted() {
      this.report();
      this.el.addEventListener("change", () => this.report());
    },

    report() {
      var name = null;
      try {
        name = Intl.DateTimeFormat().resolvedOptions().timeZone;
      } catch (_) {
        // Very old browsers have no Intl timezone support. Nothing to report;
        // the server simply never shows a detected zone.
      }
      if (!name) return;

      var payload = {
        name: name,
        offset: String(-new Date().getTimezoneOffset() / 60)
      };
      var event = this.el.dataset.event || "phoenix_kit:timezone_detected";

      // Two mount points, one hook. In the layout there is no phx-target and
      // the event goes to the LiveView, where an attached handle_event hook
      // picks it up for every page. On the profile it targets the settings
      // LiveComponent, which owns the picker and the warning.
      // Wrapped: a hook can mount during a reconnect or a back/forward cache
      // restore, before the channel this pushes over is joined. Reporting a
      // timezone is a courtesy — it must never surface as an error to someone
      // who was only navigating.
      try {
        if (this.el.getAttribute("phx-target")) {
          this.pushEventTo(this.el, event, payload);
        } else {
          this.pushEvent(event, payload);
        }
      } catch (_) {
        // Next mount reports again.
      }
    }
  };

  // ---------------------------------------------------------------------------
  // ResetSelect Hook
  // ---------------------------------------------------------------------------
  //
  // Resets a select element to its first option when triggered by a server event.
  //
  // Usage in LiveView template:
  //   <select id="my-select" phx-hook="ResetSelect">...</select>
  //
  // Trigger from server:
  //   push_event(socket, "reset_select", %{id: "my-select"})
  //
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.ResetSelect = {
    mounted() {
      this.handleEvent("reset_select", ({ id }) => {
        if (this.el.id === id) {
          this.el.selectedIndex = 0;
        }
      });
    }
  };

  // ---------------------------------------------------------------------------
  // PhoenixKitUrlState Hook
  // ---------------------------------------------------------------------------
  //
  // Carries list state (search / filters / sort / page) in the address bar for
  // a LiveView that cannot use push_patch.
  //
  // Why it exists: push_patch requires handle_params/3 to be exported, and
  // exporting it makes a LiveView impossible to embed with live_render/3. An
  // embeddable list therefore has to drive the URL from the client instead.
  //
  // Rendered by PhoenixKitWeb.Live.UrlState.url_state_sync/1 when the LiveView
  // declares `mode: :history`; nothing else should mount it by hand.
  //
  // Three jobs:
  //   1. on connect, report the query the page was opened with — an embedded
  //      LiveView receives :not_mounted_at_router instead of params, so this is
  //      the only way it can learn its own state;
  //   2. rewrite the address bar when the server pushes a new query;
  //   3. report Back and Forward, which is what makes history navigation work
  //      without a router.
  //
  // Only the query is exchanged. The path stays client-side deliberately: an
  // embedded LiveView has no idea which page it is on.
  //
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.PhoenixKitUrlState = {
    mounted() {
      this.pushEvent("phoenix_kit_url_state", { query: window.location.search });

      // Keep the ref: handleEvent registers on the LiveSocket, not on the
      // element, so without removeHandleEvent in destroyed() every remount of
      // this hook leaves another live callback behind and one server push runs
      // the history write N times.
      this.pkHandleRef = this.handleEvent("phoenix_kit_url_state", ({ query, replace }) => {
        var next = window.location.pathname + (query ? "?" + query : "");

        // Nothing moved — recording it would put a duplicate in the history
        // stack and make one Back press look like it did nothing.
        if (next === window.location.pathname + window.location.search) return;

        if (replace) {
          window.history.replaceState({}, "", next);
        } else {
          window.history.pushState({}, "", next);
        }
      });

      this.pkOnPopState = function () {
        this.pushEvent("phoenix_kit_url_state", { query: window.location.search });
      }.bind(this);

      window.addEventListener("popstate", this.pkOnPopState);
    },

    destroyed() {
      if (this.pkOnPopState) {
        window.removeEventListener("popstate", this.pkOnPopState);
        this.pkOnPopState = null;
      }

      if (this.pkHandleRef) {
        this.removeHandleEvent(this.pkHandleRef);
        this.pkHandleRef = null;
      }
    }
  };

  // ---------------------------------------------------------------------------
  // PopupLink Hook
  // ---------------------------------------------------------------------------
  //
  // Opens a same-origin link in a named popup instead of navigating the page.
  // Nothing about it is OAuth-specific — connect_account_button/1 is simply its
  // first consumer. Replaces an inline onclick= (CSP-hostile, and the kit
  // removed inline handlers everywhere else for the same reason).
  //
  // The element is a real <a href>, so this degrades correctly: with JS off, or
  // when the popup is blocked, the browser performs the normal full-page
  // navigation rather than dead-ending on a cancelled click.
  //
  // Geometry and window name come from data attributes so nothing is
  // interpolated into a script string.
  //
  // Usage:
  //   <a href="/oauth/start" phx-hook="PopupLink"
  //      data-window-name="oauth-connect" data-window-width="480"
  //      data-window-height="680">Connect</a>
  //
  // ---------------------------------------------------------------------------

  // Pure: should this click be turned into a popup at all? A user asking for a
  // new tab (middle-click, cmd/ctrl-click) or a handler that already claimed
  // the event must be left alone.
  function shouldOpenPopup(event) {
    if (!event) return false;
    if (event.defaultPrevented) return false;
    if (typeof event.button === "number" && event.button !== 0) return false;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false;
    return true;
  }

  // Pure: window.open feature string, centred on the screen the browser window
  // is actually on. screenLeft/Top describe the WINDOW, so a multi-monitor
  // setup needs them as the origin — centring on innerWidth alone throws the
  // popup onto the primary display.
  function popupFeatures(width, height, view) {
    var v = view || {};
    var w = Math.max(1, parseInt(width, 10) || 480);
    var h = Math.max(1, parseInt(height, 10) || 680);

    var originX = v.screenLeft !== undefined ? v.screenLeft : (v.screenX || 0);
    var originY = v.screenTop !== undefined ? v.screenTop : (v.screenY || 0);
    var outerW = v.outerWidth || w;
    var outerH = v.outerHeight || h;

    // Clamp the OFFSET, not the final coordinate: a monitor left of, or above,
    // the primary one has negative screen coordinates, and flooring those at 0
    // threw the popup back onto the primary display.
    var left = Math.round(originX + Math.max(0, (outerW - w) / 2));
    var top = Math.round(originY + Math.max(0, (outerH - h) / 2));

    return (
      "width=" + w + ",height=" + h + ",left=" + left + ",top=" + top +
      ",menubar=no,toolbar=no,location=yes,status=no,resizable=yes,scrollbars=yes"
    );
  }

  // Pure: is this link one we may open in a popup at all? The popup keeps its
  // `window.opener`, so a cross-origin target would hand that reference away.
  // The Elixir component enforces this too, but the bundle is copied verbatim
  // into host apps and the hook is a public name — a host wiring it onto an
  // arbitrary <a> must not be able to bypass the rule.
  function sameOrigin(href, base) {
    // A non-string href would otherwise be stringified and resolved as a
    // RELATIVE path ("undefined"), which lands back on our own origin and
    // quietly passes the check.
    if (typeof href !== "string" || href === "") return false;

    try {
      return new URL(href, base).origin === new URL(base).origin;
    } catch (_err) {
      return false;
    }
  }

  window.PhoenixKitHooks.PopupLink = {
    mounted() {
      this.onClick = (event) => {
        if (!shouldOpenPopup(event)) return;

        var el = this.el;
        if (!sameOrigin(el.href, window.location.href)) return;

        var name = el.dataset.windowName || "oauth-connect";
        var features = popupFeatures(el.dataset.windowWidth, el.dataset.windowHeight, window);

        var popup;
        try {
          popup = window.open(el.href, name, features);
        } catch (_err) {
          popup = null;
        }

        // Blocked or failed → let the click through so the plain href still
        // starts the flow full-page. Cancelling here unconditionally is what
        // made the old inline onclick a dead button behind a popup blocker.
        // Some blockers hand back a window that is already closed, and others
        // return one whose `closed` is undefined — treat both as blocked.
        if (!popup || popup.closed || typeof popup.closed === "undefined") return;

        event.preventDefault();
        try {
          popup.focus();
        } catch (_err) {
          /* focus is best-effort; a blocked focus must not break the flow */
        }
      };

      this.el.addEventListener("click", this.onClick);
    },

    destroyed() {
      if (this.onClick) {
        this.el.removeEventListener("click", this.onClick);
        this.onClick = null;
      }
    }
  };

  // Exported for the Node test harness (test/js); harmless in a browser.
  if (typeof module === "object" && module.exports) {
    module.exports.shouldOpenPopup = shouldOpenPopup;
    module.exports.popupFeatures = popupFeatures;
    module.exports.sameOrigin = sameOrigin;
  }

  // ---------------------------------------------------------------------------
  // SelectOnMount
  //
  // Focuses an input and selects all of its current value on mount. Use
  // for inline-rename inputs and similar type-to-replace flows where
  // JS.focus() alone leaves the cursor at the end and forces the user
  // to reach for the mouse / select-all shortcut before retyping.
  // ---------------------------------------------------------------------------
  window.PhoenixKitHooks.SelectOnMount = {
    mounted() {
      this.el.focus();
      this.el.select();
    }
  };

  // ---------------------------------------------------------------------------
  // PkDialog — generic native <dialog> controller for server-driven modals.
  //
  // Renders the modal in the browser top layer (showModal()), so it is immune to
  // ancestor stacking contexts / z-index — fixes modals being overlapped by
  // parent-page elements. The dialog also covers the FULL visual viewport
  // (top-layer rendering bypasses the daisyUI `scrollbar-gutter: stable` trick
  // that previously left a 15px gap on the right of `<div class="modal">`).
  //
  //   data-show        "true" / "false" — desired open state (synced each update)
  //   data-close-event event pushed to the component on Escape / cancel / backdrop
  //   data-closeable   "false" → Escape + backdrop click are no-ops (modal still
  //                    closable only via an explicit action button). Default:
  //                    closeable.
  //   data-close-guard "confirm" (what `<.modal>` renders by default) → once a
  //                    submittable form inside THIS dialog has been typed
  //                    into, the first Escape or backdrop click is refused
  //                    with a nudge of the box and only a second one within
  //                    a few seconds closes. See "Unsaved input" above.
  //                    "input" → while a submittable form (`form[phx-submit]`)
  //                    inside THIS dialog holds a field that differs from its
  //                    default value, Escape + backdrop are no-ops on the
  //                    client — before the server hears of the edit; a
  //                    debounced change event and an Esc inside the debounce
  //                    window would otherwise discard the text. Recomputed on
  //                    every input event and every server patch, so it lets
  //                    go the moment the form is saved, reset, or re-rendered
  //                    with the value (the server's data-closeable is the
  //                    authority from then on) — never a latch. Filter /
  //                    search forms (phx-change only, role="search",
  //                    type="search") do not count.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // PkShiftEnter — gives an input a second Enter.
  //
  // Plain Enter in a text input is the browser's implicit submission: it
  // presses the form's FIRST submit button. Shift+Enter submits exactly the
  // same way, so a form cannot tell "add" from "add and start the next"
  // without help. This hook makes Shift+Enter click the element named by
  // `data-shift-enter-click` (a selector — typically a second submit button
  // carrying `name`/`value`, which LiveView then includes as the submitter)
  // and leaves plain Enter alone. Never fires during IME composition.
  //
  //   <input phx-hook="PkShiftEnter" data-shift-enter-click="#add-next" …>
  //   <button type="submit">Add</button>                       ← Enter
  //   <button type="submit" id="add-next" name="then" value="next">Add & next</button>
  // ---------------------------------------------------------------------------
  function shiftEnter(e) {
    return !!e && e.key === "Enter" && e.shiftKey === true && !e.isComposing &&
      !e.metaKey && !e.ctrlKey && !e.altKey;
  }

  if (typeof module === "object" && module.exports) {
    module.exports.shiftEnter = shiftEnter;
  }

  window.PhoenixKitHooks.PkShiftEnter = {
    mounted() {
      const self = this;
      self._onKeydown = function(e) {
        if (!shiftEnter(e)) return;
        const selector = self.el.dataset.shiftEnterClick;
        if (!selector) return;
        const target = document.querySelector(selector);
        if (!target) return;
        e.preventDefault();
        target.click();
      };
      this.el.addEventListener("keydown", self._onKeydown);
    },
    destroyed() {
      if (this._onKeydown) this.el.removeEventListener("keydown", this._onKeydown);
    }
  };

  // ---------------------------------------------------------------------------
  // PkUrlMirror — keeps the address bar on the element's `data-url`.
  //
  // For a LiveView that switches views in place but cannot export
  // handle_params/3 (an embeddable LV — LiveView refuses to mount one with
  // that callback outside a router route). The server renders the canonical
  // URL of the current view into `data-url`; on every mount/update the hook
  // `replaceState`s to it when it differs. Replace, never push: a pushed
  // entry would be a foreign history state that LiveView's popstate handler
  // treats as live navigation into a callback that does not exist. Back /
  // forward therefore leave the page, as before; copy / reload / deep links
  // land on the view that was showing.
  //
  //   <div id="tabs" phx-hook="PkUrlMirror" data-url="/admin/projects/1/tasks/board">
  // ---------------------------------------------------------------------------
  // Only a root-relative PATH is honoured: not a network-path reference
  // ("//host", "/\\host" — same-origin-looking, other-origin-going), not
  // anything with control characters, not a fragment (the comparison
  // below never sees the hash, so a fragment would re-fire on every
  // update). Codex, 2026-09-05.
  function urlMirrorTarget(dataset, current) {
    const url = dataset && dataset.url;
    if (typeof url !== "string" || url === "" || url.charAt(0) !== "/") return null;
    if (url.charAt(1) === "/" || url.charAt(1) === "\\") return null;
    if (/[\u0000-\u001f\u007f#]/.test(url)) return null;
    if (url === current) return null;
    return url;
  }

  if (typeof module === "object" && module.exports) {
    module.exports.urlMirrorTarget = urlMirrorTarget;
  }

  window.PhoenixKitHooks.PkUrlMirror = {
    mounted() { this._sync(); },
    updated() { this._sync(); },
    _sync() {
      const current = window.location.pathname + window.location.search;
      const target = urlMirrorTarget(this.el.dataset, current);
      if (target === null) return;
      try {
        window.history.replaceState(window.history.state, "", target);
      } catch (_e) {
        // A cross-origin or otherwise refused URL: leave the address bar alone.
      }
    }
  };

  // ---------------------------------------------------------------------------
  // Password fields with an eye button (`<.input password_toggle>`).
  //
  // The button itself is LiveView JS commands and needs nothing from this file.
  // What they cannot do is hide the password again when its form is sent: a
  // revealed field is a plain text input, which a browser may keep in its form
  // history and which its password manager may not offer to save. So a submit
  // presses every pressed button of that form first, which also keeps the icon
  // and `aria-pressed` right on a form that comes back with errors. Capture
  // phase: this has to happen before LiveView or the browser reads the form.
  // ---------------------------------------------------------------------------
  function hideRevealedPasswords(form) {
    if (!form || typeof form.querySelectorAll !== "function") return;
    form.querySelectorAll('[data-pk-password-toggle][aria-pressed="true"]').forEach(function(button) {
      button.click();
    });
  }

  if (typeof module === "object" && module.exports) {
    module.exports.hideRevealedPasswords = hideRevealedPasswords;
  }

  document.addEventListener("submit", function(e) { hideRevealedPasswords(e.target); }, true);

  // ---------------------------------------------------------------------------
  // DECLARATIVE HANDLERS
  // ---------------------------------------------------------------------------
  //
  // What the kit's markup used to do with inline handlers (`onclick="…"`,
  // `onerror="…"`). A Content-Security-Policy without 'unsafe-inline' blocks
  // those, and no nonce can be put on an attribute, so the markup now only
  // names what it wants and one listener per event, on the document, does it.
  // No hook: the same markup is rendered by controller pages and dead views.
  //
  //   data-pk-blur                 a click inside drops the focus (closes a
  //                                daisyUI dropdown after a choice)
  //   data-pk-copy="text"          a click copies the text
  //   data-pk-copy-from="id"       a click copies that element's value/text
  //   data-pk-img-error="hide|remove|placeholder"
  //                                what a broken <img> does; "placeholder"
  //                                shows the .image-error-placeholder next to it
  //   data-pk-no-submit            a <form> that is never submitted
  //   data-pk-no-enter             Enter in this field does nothing
  //   data-pk-zero-clear           <.decimal_input>: a zero clears on focus
  //   data-pk-language-filter      the language switcher's search field
  //   data-pc-track / -step / -jump   <.preview_card>'s carousel
  //
  // Capture phase where the event does not bubble (error, focus, blur, scroll,
  // submit) and for keydown, so a host's own inline handler on the same
  // element still runs after the kit's, as it did when both were chained.
  // ---------------------------------------------------------------------------

  function pkClosest(target, selector) {
    return target && typeof target.closest === "function" ? target.closest(selector) : null;
  }

  function pkHas(el, name) {
    return !!el && typeof el.hasAttribute === "function" && el.hasAttribute(name);
  }

  // Pure: the text a copy button asks for, or null.
  function copyTextFor(button, doc) {
    if (!button) return null;
    if (pkHas(button, "data-pk-copy")) return button.getAttribute("data-pk-copy");
    var id = button.getAttribute("data-pk-copy-from");
    var source = id ? doc.getElementById(id) : null;
    if (!source) return null;
    // Only a form control's `value` is its text: <li>, <button>, <meter> and
    // others have a `value` property of their own (an <li>'s is 0).
    var tag = String(source.tagName || "").toUpperCase();
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" ? source.value : source.textContent;
  }

  function onImageError(img) {
    switch (img.getAttribute("data-pk-img-error")) {
      case "hide":
        img.style.display = "none";
        break;
      case "remove":
        img.remove();
        break;
      case "placeholder":
        var holder = img.parentElement && img.parentElement.querySelector(".image-error-placeholder");
        if (holder) holder.style.display = "grid";
        break;
    }
  }

  // <.decimal_input>: a zero-like text (optional sign, zeros, optional decimal
  // zeros) is cleared on focus so typing replaces it, and comes back if the
  // field is left empty. The zero is kept in expando properties, never
  // `dataset`: LiveView's patch of a focused input drops every attribute the
  // server did not render. A readonly field is never cleared.
  var ZERO_TEXT = /^\s*[-+]?(?:0+(?:[.,]0*)?|[.,]0+)\s*$/;

  function zeroFocus(el) {
    if (el.readOnly || !ZERO_TEXT.test(el.value)) return;
    el.__pkZero = el.value;
    el.__pkZeroEdited = false;
    // One stable function, so adding it on every focus registers it once.
    el.__pkZeroOnInput || (el.__pkZeroOnInput = function() { el.__pkZeroEdited = true; });
    el.addEventListener("input", el.__pkZeroOnInput);
    el.value = "";
  }

  function zeroBlur(el) {
    if (el.__pkZero == null) return;
    if (el.value.trim() === "") {
      el.value = el.__pkZero;
      // Typed-then-erased: the server last heard "" from phx-change, so the
      // restore announces itself with an input event of its own.
      if (el.__pkZeroEdited) el.dispatchEvent(new Event("input", { bubbles: true }));
    }
    delete el.__pkZero;
  }

  // Enter submits the form before any blur: restore the zero first.
  function zeroEnter(el) {
    if (el.__pkZero != null && el.value.trim() === "") {
      el.value = el.__pkZero;
      delete el.__pkZero;
    }
  }

  function filterLanguages(input) {
    var term = input.value.toLowerCase().trim();
    var list = pkClosest(input, "ul");
    if (!list) return;
    var any = false;
    list.querySelectorAll(".language-item").forEach(function(item) {
      var name = item.dataset.name || "";
      var native = item.dataset.native || "";
      var match = !term || name.includes(term) || native.includes(term);
      item.style.display = match ? "" : "none";
      if (match) any = true;
    });
    var empty = list.querySelector(".ls-no-results");
    if (empty) empty.style.display = any ? "none" : "";
  }

  // <.preview_card>: the slide the track shows, and the jump strip's mark.
  function previewTrack(el) {
    var root = pkClosest(el, "[data-pc-root]");
    return root ? root.querySelector("[data-pc-track]") : null;
  }

  function previewMark(track) {
    var root = pkClosest(track, "[data-pc-root]");
    var strip = root && root.querySelector("[data-pc-strip]");
    if (!strip || !track.clientWidth) return;
    var current = Math.round(track.scrollLeft / track.clientWidth);
    Array.from(strip.children).forEach(function(tile, index) {
      tile.classList.toggle("border-primary", index === current);
      tile.classList.toggle("border-base-300", index !== current);
      if (index === current) tile.setAttribute("aria-current", "true");
      else tile.removeAttribute("aria-current");
    });
  }

  function onDeclaredClick(e) {
    var el;

    if ((el = pkClosest(e.target, "[data-pk-copy],[data-pk-copy-from]"))) {
      var text = copyTextFor(el, document);
      if (text != null && navigator.clipboard) navigator.clipboard.writeText(text).catch(function() {});
    }

    if ((el = pkClosest(e.target, "[data-pc-step]"))) {
      var track = previewTrack(el);
      var step = parseInt(el.getAttribute("data-pc-step"), 10) || 0;
      if (track) track.scrollBy({ left: step * track.clientWidth, behavior: "smooth" });
    }

    if ((el = pkClosest(e.target, "[data-pc-jump]"))) {
      var jumpTrack = previewTrack(el);
      var slide = jumpTrack && jumpTrack.children[parseInt(el.getAttribute("data-pc-jump"), 10)];
      if (slide) slide.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "start" });
    }

    var active = document.activeElement;
    if (pkClosest(e.target, "[data-pk-blur]") && active && typeof active.blur === "function") {
      active.blur();
    }
  }

  // An image that failed before this file ran (a deferred or late-loaded
  // bundle) never fires its error again: look once the document is parsed.
  function sweepBrokenImages() {
    document.querySelectorAll("img[data-pk-img-error]").forEach(function(img) {
      // An SVG with no intrinsic size can report a natural width of 0 while
      // it shows fine, so it is left to its own error event.
      var src = img.getAttribute("src") || "";
      if (!src || /\.svg(\?|#|$)/i.test(src) || src.indexOf("data:image/svg") === 0) return;
      if (img.complete && img.naturalWidth === 0) onImageError(img);
    });
  }

  if (typeof module === "object" && module.exports) {
    module.exports.copyTextFor = copyTextFor;
    module.exports.onImageError = onImageError;
    module.exports.zeroFocus = zeroFocus;
    module.exports.zeroBlur = zeroBlur;
    module.exports.zeroEnter = zeroEnter;
    module.exports.filterLanguages = filterLanguages;
    module.exports.previewMark = previewMark;
    module.exports.onDeclaredClick = onDeclaredClick;
    module.exports.sweepBrokenImages = sweepBrokenImages;
  }

  document.addEventListener("click", onDeclaredClick);

  document.addEventListener("error", function(e) {
    if (pkHas(e.target, "data-pk-img-error")) onImageError(e.target);
  }, true);

  document.addEventListener("submit", function(e) {
    if (pkHas(e.target, "data-pk-no-submit")) e.preventDefault();
  }, true);

  document.addEventListener("keydown", function(e) {
    if (e.key !== "Enter") return;
    if (pkHas(e.target, "data-pk-zero-clear")) zeroEnter(e.target);
    if (pkHas(e.target, "data-pk-no-enter")) e.preventDefault();
  }, true);

  document.addEventListener("focus", function(e) {
    if (pkHas(e.target, "data-pk-zero-clear")) zeroFocus(e.target);
  }, true);

  document.addEventListener("blur", function(e) {
    if (pkHas(e.target, "data-pk-zero-clear")) zeroBlur(e.target);
  }, true);

  document.addEventListener("input", function(e) {
    if (pkHas(e.target, "data-pk-language-filter")) filterLanguages(e.target);
  });

  document.addEventListener("scroll", function(e) {
    var track = e.target;
    if (!pkHas(track, "data-pc-track")) return;
    clearTimeout(track._pc);
    track._pc = setTimeout(function() { previewMark(track); }, 80);
  }, true);

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", sweepBrokenImages);
  } else {
    sweepBrokenImages();
  }

  // ---------------------------------------------------------------------------
  // PkDateInput — the hook behind `<.date_input>` (core/date_input.ex): a
  // visible text input in the site's date format plus a real
  // `<input type="date" data-date-value>` that carries the caller's name and
  // the ISO value. The server renders the native date input as the visible
  // control (what a page with no LiveView keeps); `enhance` swaps the roles.
  // See the component's moduledoc for the contract.
  //
  // The pure parts (format table, parser, formatter) are exported for
  // test/js/date_input.test.cjs.
  // ---------------------------------------------------------------------------
  var DATE_ORDERS = {
    "Y-m-d": "ymd",
    "m/d/Y": "mdy",
    "d/m/Y": "dmy",
    "d.m.Y": "dmy",
    "d-m-Y": "dmy",
    "F j, Y": "mdy"
  };
  var DATE_MONTHS = ["January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December"];

  // Same fallback as PhoenixKit.Utils.Date.format_date/2 for an unknown format.
  function dateOrder(format) {
    return DATE_ORDERS[format] || "ymd";
  }

  function pad2(n) {
    return (n < 10 ? "0" : "") + n;
  }

  function pad4(n) {
    return ("000" + n).slice(-4);
  }

  // The real calendar date, or null (31.02, month 13, year 0).
  function validYmd(y, m, d) {
    if (!(y >= 1 && m >= 1 && m <= 12 && d >= 1 && d <= 31)) return null;
    var dt = new Date(Date.UTC(2000, 0, 1));
    dt.setUTCFullYear(y, m - 1, d);
    if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null;
    return pad4(y) + "-" + pad2(m) + "-" + pad2(d);
  }

  function monthFromName(token) {
    var t = token.toLowerCase();
    if (t.length < 3) return 0;
    for (var i = 0; i < 12; i++) {
      var name = DATE_MONTHS[i].toLowerCase();
      if (name === t || (t.length === 3 && name.slice(0, 3) === t)) return i + 1;
    }
    return 0;
  }

  // Two digits take the century that puts the date within 50 years before
  // to 49 after today (2026: 76 → 1976, 75 → 2075, 85 → 1985, 30 → 2030).
  function yearFromToken(token, todayYear) {
    if (!/^\d+$/.test(token)) return 0;
    if (token.length === 4) return parseInt(token, 10);
    if (token.length !== 2) return 0;
    var yy = parseInt(token, 10);
    var base = todayYear - 50;
    return yy + 100 * Math.ceil((base - yy) / 100);
  }

  function todayYearOf(today) {
    var m = /^(\d{4})-/.exec(String(today || ""));
    return m ? parseInt(m[1], 10) : new Date().getFullYear();
  }

  function isYearPart(order, idx) {
    return order === "ymd" ? idx === 0 : idx === 2;
  }

  function assembleDate(order, parts) {
    if (order === "ymd") return { y: parts[0], m: parts[1], d: parts[2] };
    if (order === "mdy") return { m: parts[0], d: parts[1], y: parts[2] };
    return { d: parts[0], m: parts[1], y: parts[2] };
  }

  // What a date input's `value` is for an attribute text: the date itself when
  // it is a real `YYYY-MM-DD`, else "" (the browser's sanitising).
  function isoOrEmpty(text) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(text || ""));
    return m ? validYmd(+m[1], +m[2], +m[3]) || "" : "";
  }

  // Text → "YYYY-MM-DD", or null when it is not a date (or lies outside
  // min/max, which are ISO strings). `today` (ISO) anchors two-digit years. Never throws; empty text is the caller's
  // business (it clears the field).
  function checkDateText(text, format, min, max, today) {
    var s = String(text == null ? "" : text).trim();
    if (s === "") return { error: "format" };
    var order = dateOrder(format);
    var ty = todayYearOf(today);
    var iso = null;
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);

    if (m) {
      iso = validYmd(+m[1], +m[2], +m[3]);
    } else if (/^\d+$/.test(s)) {
      // Digits only: ddmmyyyy / ddmmyy in the format's order.
      var cuts;
      if (s.length === 8) cuts = order === "ymd" ? [4, 2, 2] : [2, 2, 4];
      else if (s.length === 6) cuts = [2, 2, 2];
      else return { error: "format" };
      var nums = [];
      var at = 0;
      for (var i = 0; i < 3; i++) {
        var part = s.slice(at, at + cuts[i]);
        at += cuts[i];
        nums.push(isYearPart(order, i) ? yearFromToken(part, ty) : parseInt(part, 10));
      }
      var a = assembleDate(order, nums);
      iso = validYmd(a.y, a.m, a.d);
    } else {
      var tokens = s.split(/[.\/\-\s,]+/).filter(Boolean);
      if (tokens.length !== 3) return { error: "format" };
      var namePos = format === "F j, Y" ? 0 : -1;
      var vals = [];
      for (var j = 0; j < 3; j++) {
        var tok = tokens[j];
        if (isYearPart(order, j)) vals.push(yearFromToken(tok, ty));
        else if (j === namePos && /^[A-Za-z]+$/.test(tok)) vals.push(monthFromName(tok));
        else if (/^\d{1,2}$/.test(tok)) vals.push(parseInt(tok, 10));
        else return { error: "format" };
      }
      var b = assembleDate(order, vals);
      iso = validYmd(b.y, b.m, b.d);
    }

    if (iso === null) return { error: "format" };
    if ((min && iso < min) || (max && iso > max)) return { error: "range" };
    return { iso: iso };
  }

  // Text → "YYYY-MM-DD", or null when it is not an acceptable date.
  function parseDateText(text, format, min, max, today) {
    return checkDateText(text, format, min, max, today).iso || null;
  }

  // "YYYY-MM-DD" → text in the site format (`F` is the English month name,
  // as the server renders it); "" for anything that is not an ISO date.
  function formatDateIso(iso, format) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || ""));
    if (!m) return "";
    var y = m[1];
    var mo = m[2];
    var d = m[3];
    switch (format) {
      case "m/d/Y": return mo + "/" + d + "/" + y;
      case "d/m/Y": return d + "/" + mo + "/" + y;
      case "d.m.Y": return d + "." + mo + "." + y;
      case "d-m-Y": return d + "-" + mo + "-" + y;
      case "F j, Y": return DATE_MONTHS[+mo - 1] + " " + (+d) + ", " + y;
      default: return y + "-" + mo + "-" + d;
    }
  }

  // Where the calendar popup goes: under the field, flipped above it when
  // the room below is short and the room above is enough, kept inside the
  // viewport sideways. `anchor` is the field's rect, `size` the popup's,
  // `view` the viewport's; all in CSS pixels.
  function popupPlacement(anchor, size, view) {
    var gap = 4;
    var top = anchor.bottom + gap;
    if (top + size.height > view.height && anchor.top - gap - size.height >= 0) {
      top = anchor.top - gap - size.height;
    }
    // No room on either side: keep as much of it as fits on screen.
    if (top + size.height > view.height) top = Math.max(gap, Math.min(top, view.height - size.height - gap));
    var left = Math.max(gap, Math.min(anchor.left, view.width - size.width - gap));
    return { top: top, left: left };
  }

  // The grid is Gregorian whatever the language's default calendar is (`th`,
  // `ar-SA`, `fa`): without it the month and year headings would not match.
  function calendarLocale(tag) {
    tag = tag || "en";
    return /-u-/i.test(tag) ? tag : tag + "-u-ca-gregory";
  }

  if (typeof module === "object" && module.exports) {
    module.exports.calendarLocale = calendarLocale;
    module.exports.popupPlacement = popupPlacement;
    module.exports.dateOrder = dateOrder;
    module.exports.parseDateText = parseDateText;
    module.exports.checkDateText = checkDateText;
    module.exports.formatDateIso = formatDateIso;
  }

  var warnedNoUtilities = false;

  window.PhoenixKitHooks.PkDateInput = {
    mounted() {
      var self = this;
      var t = this.textEl();
      this.baseText = t.value;
      this.lastIso = this.valueEl().value;
      this.rejected = null;
      this.pendingSync = false;
      this.gone = false;
      this.serverAttr = this.valueEl().getAttribute("value");
      this.enhance(true);

      this.onEvent = function(e) { self.handle(e); };
      ["input", "change", "click", "mousedown", "keydown", "focusin", "focusout"].forEach(function(type) {
        self.el.addEventListener(type, self.onEvent);
      });

      // The owning form is the value element's (`form="…"` goes to it).
      this.form = this.valueEl().form;
      this.onReset = function() {
        // The browser restored both fields' defaults; make them agree again.
        setTimeout(function() { self.syncText(); }, 0);
      };
      if (this.form) this.form.addEventListener("reset", this.onReset);

      // A date picked in the native input before the socket connected: the
      // server has not heard of it, the text is still the old date. A browser
      // sanitises a non-ISO `value` to "", so the default to compare with is
      // the sanitised one: a value the server echoed as given (`03.05.2024`)
      // is not a pick.
      var v = this.valueEl();
      var pick = v.value !== isoOrEmpty(v.defaultValue);
      // A half-edited native control (`badInput`) holds no date yet: not a pick.
      if (pick && v.validity && v.validity.badInput) pick = false;
      if (pick && v.value === "" && this.el.dataset.required === "true") {
        // Emptied during the connect window, on a required field: that is not
        // a value. Keep the server's date (put back into the date input) and say so.
        v.value = isoOrEmpty(v.defaultValue);
        this.reject("format");
      } else if (pick) {
        this.syncText();
        v.dispatchEvent(new Event("input", { bubbles: true }));
      } else if (t.value !== t.defaultValue) {
        // Text that differs from what the server rendered was typed before the
        // socket connected. Still typing in it: leave it to blur/Enter (a
        // partial `16.10.20` must not be committed under the caret).
        if (document.activeElement === t) this.baseText = t.defaultValue;
        else this.commit();
      } else if (v.value === "" && t.value.trim() !== "") {
        this.adoptStored();
      }
      this.refresh();

      // `autofocus` sits on the text field, which was `hidden` when the
      // browser looked for something to focus. The socket connects after the
      // person may have started typing elsewhere: take the focus only when
      // nothing holds it (the date input's own focus went to the text field in
      // `enhance`).
      var active = document.activeElement;
      if (t.hasAttribute("autofocus") && (!active || active === document.body)) t.focus();
    },

    // The server echoed a stored value the date input cannot hold (`03.05.2024`,
    // a changeset's bad input): the text shows it, the date input is empty, and
    // a save would erase it without a word. A text that is a date in the site
    // format is taken into the date input (no event: the server has it); any
    // other is marked, so the person corrects or clears it. A field nobody can
    // edit is not marked.
    adoptStored() {
      var t = this.textEl();
      var v = this.valueEl();
      var res = this.check(t.value);
      if (!res.error) {
        v.value = res.iso;
        this.lastIso = res.iso;
      } else if (!(t.matches && t.matches(":disabled")) && !t.readOnly) {
        this.reject(res.error);
      }
    },

    updated() {
      var v = this.valueEl();
      var t = this.textEl();
      if (!v || !t) return;
      var focused = document.activeElement === t;
      // The server's own value (the attribute): a stored text the date input
      // cannot hold sanitises to "" however the server moves it.
      var attr = v.getAttribute("value");
      var attrMoved = attr !== this.serverAttr;
      this.serverAttr = attr;
      // The echo of the value the hook itself sent is not the server moving it.
      if (attrMoved && (attr || "") === this.sentIso) attrMoved = false;
      var stored = !!attr && isoOrEmpty(attr) === "";
      // The same stored text again: keep the date taken from it at mount.
      if (stored && !attrMoved && v.value === "" && this.lastIso) v.value = this.lastIso;
      var changed = v.value !== this.lastIso || attrMoved;
      this.lastIso = v.value;

      if (changed) {
        // The server moved the date: it wins over rejected text.
        this.rejected = null;
        if (focused) this.pendingSync = true;
        else if (stored) this.adoptStored();
        else this.syncText();
      } else if (this.rejected && !focused) {
        // A patch rewrote the field from the server's (unchanged) date: the
        // rejected text is what the person should still see.
        t.value = this.rejected.text;
      }
      // A patch also rewrites every attribute the server rendered.
      this.refresh();
    },

    destroyed() {
      this.gone = true;
      this.closePopup(false);
      if (this.form) this.form.removeEventListener("reset", this.onReset);
    },

    // The server renders the native date input as the visible control and the
    // text field `hidden`. From here on the text field is the control and the
    // date input is its invisible value element: the wrapper's `data-enhanced`
    // flips the classes, and `required` moves to the text field (a `required`
    // control that is not displayed would block the form's submit). A patch
    // puts the server's markup back, so `refresh` does this again.
    enhance(atMount) {
      var t = this.textEl();
      var v = this.valueEl();
      if (!t || !v || this.degraded) return;
      this.el.setAttribute("data-enhanced", "");
      if (atMount) {
        // A host stylesheet without the swap utilities leaves the text field
        // undisplayed: keep the browser's date input (visible, focusable,
        // `required`) instead of an invisible one.
        var css = typeof window.getComputedStyle === "function" ? window.getComputedStyle(t) : null;
        if (css && css.display === "none") {
          this.el.removeAttribute("data-enhanced");
          this.degraded = true;
          if (!warnedNoUtilities && typeof console !== "undefined") console.warn("PkDateInput: the stylesheet lacks the group-data-[enhanced] utilities; rebuild the CSS. Using the browser's date input.");
          warnedNoUtilities = true;
          return;
        }
        // Sticky across patches: morphdom would strip a plain attribute the
        // server does not render, and the text field would blink away.
        if (typeof this.js === "function") this.js().setAttribute(this.el, "data-enhanced", "");
      }
      v.setAttribute("tabindex", "-1");
      v.setAttribute("aria-hidden", "true");
      v.removeAttribute("required");
      t.required = this.el.dataset.required === "true";
      // The date input that was displayed (and focused) until now is invisible
      // from here on: the keystrokes go to the field the person sees. Only at
      // mount: later it holds the focus for its own picker.
      if (atMount && document.activeElement === v) t.focus();
    },

    textEl() { return this.el.querySelector("[data-date-text]"); },
    valueEl() { return this.el.querySelector("[data-date-value]"); },
    format() { return this.el.dataset.format || "Y-m-d"; },

    check(raw) {
      var d = this.el.dataset;
      return checkDateText(raw, this.format(), d.min, d.max, d.today);
    },

    handle(e) {
      var text = this.textEl();
      var value = this.valueEl();
      var target = e.target;

      // Escape with the calendar open closes only the calendar: the event
      // must not reach a PkDialog / modal around the field.
      if (e.type === "keydown" && e.key === "Escape" && this.popupOpen()) {
        e.preventDefault();
        e.stopPropagation();
        this.closePopup(true);
        return;
      }

      // Focus left the component (Tab past the calendar): the popup goes too.
      if (e.type === "focusout" && this.popupOpen() &&
          e.relatedTarget && !this.el.contains(e.relatedTarget)) {
        this.closePopup(false);
      }

      if (target === text) {
        if (e.type === "input" || e.type === "change") {
          // The visible text never talks to LiveView.
          e.stopPropagation();
          this.toggleClear();
        } else if (e.type === "focusin") {
          this.baseText = text.value;
        } else if (e.type === "focusout") {
          this.onTextBlur();
        } else if (e.type === "keydown") {
          this.onTextKeydown(e);
        }
        return;
      }

      if (target === value) {
        // The native picker (or our own commit) changed the value element.
        if (e.type === "input" || e.type === "change") this.syncText();
        return;
      }

      var clear = target.closest && target.closest("[data-clear]");
      if (clear && this.el.contains(clear)) {
        if (e.type === "mousedown") e.preventDefault();
        else if (e.type === "click") this.clear();
        return;
      }

      var open = target.closest && target.closest("[data-open]");
      if (open && this.el.contains(open) && e.type === "click") {
        this.open();
        return;
      }

      if (e.type !== "click" || !target.closest) return;
      if (target.closest("[data-popup-today]")) this.pick(this.el.dataset.today);
      else if (target.closest("[data-popup-clear]")) {
        this.clear();
        this.closePopup(true);
      }
    },

    onTextBlur() {
      var text = this.textEl();
      if (this.pendingSync && text.value === this.baseText) {
        // The server changed the date while the field was focused.
        this.pendingSync = false;
        this.syncText();
        return;
      }
      if (text.value !== this.baseText) this.commit();
    },

    onTextKeydown(e) {
      if (e.key === "Enter" && !e.isComposing) {
        var ok = this.commit();
        var form = this.form;
        // Submit stays natural for a phx-submit form; in a phx-change-only
        // form LiveView would turn it into a native POST.
        if (!ok || !form || !form.hasAttribute("phx-submit")) e.preventDefault();
      } else if (e.key === "ArrowDown" && e.altKey) {
        e.preventDefault();
        this.open();
      }
    },

    // Parse the text and, when it is a (different) date, hand it to the form.
    // Returns false only for text that is not accepted.
    commit() {
      var text = this.textEl();
      if (this.pendingSync && text.value === this.baseText) {
        this.pendingSync = false;
        this.syncText();
        return true;
      }
      this.pendingSync = false;
      var raw = text.value.trim();
      if (raw === "") {
        // Emptying a required field is not a value: keep the date.
        if (text.required) {
          this.reject("format");
          return false;
        }
        this.setValue("");
        this.accept();
        this.baseText = text.value;
        this.toggleClear();
        return true;
      }
      var res = this.check(raw);
      if (res.error) {
        this.reject(res.error);
        return false;
      }
      this.setValue(res.iso);
      this.syncText();
      return true;
    },

    setValue(iso) {
      var v = this.valueEl();
      if (!v || v.value === iso) return;
      v.value = iso;
      this.lastIso = iso;
      this.sentIso = iso;
      v.dispatchEvent(new Event("input", { bubbles: true }));
    },

    clear() {
      var text = this.textEl();
      text.value = "";
      this.setValue("");
      this.accept();
      this.baseText = "";
      this.pendingSync = false;
      this.toggleClear();
      text.focus();
    },

    // Visible text := the value element's date, in the site format.
    syncText() {
      var text = this.textEl();
      var v = this.valueEl();
      if (!text || !v) return;
      text.value = formatDateIso(v.value, this.format());
      this.baseText = text.value;
      this.pendingSync = false;
      this.accept();
      this.toggleClear();
    },

    // The calendar button. Phones get the browser's own picker on the value
    // element; so does a desktop where the calendar cannot load. With no
    // showPicker (or one that throws) the calendar is the way, and failing
    // that the focus stays in the text field.
    open() {
      var v = this.valueEl();
      var text = this.textEl();
      if (!v || v.disabled) return;
      if (this.popupOpen()) {
        this.closePopup(true);
        return;
      }
      // What was typed counts before the calendar reads the date.
      if (text && text.value !== this.baseText) this.commit();
      var popup = this.popupEl();
      var canNative = typeof v.showPicker === "function";
      var canPopup = !!popup && typeof popup.showPopover === "function";
      var coarse = window.matchMedia && window.matchMedia("(pointer: coarse)").matches;
      if (coarse && canNative) this.tryNative(canPopup);
      else if (canPopup) this.openPopup(canNative);
      else if (canNative) this.tryNative(false);
      else this.focusText();
    },

    focusText() {
      var t = this.textEl();
      if (t) t.focus();
    },

    // The browser's picker; if it throws, the calendar (when there is one).
    tryNative(thenPopup) {
      try {
        this.valueEl().showPicker();
      } catch (_e) {
        if (thenPopup) this.openPopup(false);
        else this.focusText();
      }
    },

    // Load Cally and show it; on a failed load the browser's picker when
    // `nativeOnFail`, else the text field keeps the focus.
    openPopup(nativeOnFail) {
      var self = this;
      this.loadCally().then(function() {
        if (self.gone || !self.el.isConnected) return;
        self.showPopup();
      }, function() {
        if (self.gone) return;
        if (!window.__pkDateCallyWarned) {
          window.__pkDateCallyWarned = true;
          console.warn("[PhoenixKit] date_input: the calendar failed to load; using the browser's date picker.");
        }
        if (nativeOnFail) self.tryNative(false);
        else self.focusText();
      });
    },

    loadCally() {
      return loadVendored("Cally", "cally", {
        module: true,
        check: function() {
          return !!(window.customElements && window.customElements.get("calendar-date"));
        }
      });
    },

    popupEl() { return this.el.querySelector("[data-popup]"); },

    popupOpen() {
      var popup = this.popupEl();
      try {
        return !!popup && popup.matches(":popover-open");
      } catch (_e) {
        return false;
      }
    },

    calendarEl() {
      var popup = this.popupEl();
      return popup && popup.querySelector("calendar-date");
    },

    // The server rendered the calendar into a <template> (strings included);
    // the first open clones it into the ignored popup container.
    buildPopup(popup) {
      var self = this;
      var tpl = this.el.querySelector("[data-popup-template]");
      if (!tpl) return false;
      popup.appendChild(tpl.content.cloneNode(true));
      var cal = popup.querySelector("calendar-date");
      if (!cal) return false;
      cal.setAttribute("locale", calendarLocale(this.el.dataset.locale));
      cal.setAttribute("first-day-of-week", this.el.dataset.weekStart || "1");
      if (this.el.dataset.today) cal.setAttribute("today", this.el.dataset.today);
      // `change` does not bubble out of Cally: listen on the element.
      cal.addEventListener("change", function(e) { self.pick(e.target.value); });
      return true;
    },

    showPopup() {
      var self = this;
      var popup = this.popupEl();
      if (!popup || this.popupOpen()) return;
      if (!this.calendarEl() && !this.buildPopup(popup)) {
        this.focusText();
        return;
      }
      var cal = this.calendarEl();
      var d = this.el.dataset;
      var v = this.valueEl().value;
      if (v) cal.setAttribute("value", v);
      else cal.removeAttribute("value");
      if (d.min) cal.setAttribute("min", d.min);
      else cal.removeAttribute("min");
      if (d.max) cal.setAttribute("max", d.max);
      else cal.removeAttribute("max");
      this.syncFooter(popup);
      // Cally pins the month it was last paged to; start on the date's.
      cal.focusedDate = v || d.today || undefined;

      // Hidden until placed: the first frames would otherwise show it at the
      // viewport's origin.
      popup.style.visibility = "hidden";
      popup.showPopover();
      this.setExpanded(true);
      this.bindClosers();
      // Cally renders its shadow DOM asynchronously: measure after it has.
      requestAnimationFrame(function() {
        requestAnimationFrame(function() {
          if (!self.popupOpen()) return;
          self.position();
          popup.style.visibility = "";
          if (typeof cal.focus === "function") cal.focus();
        });
      });
    },

    // The footer buttons live in a <template> LiveView never patches, so they
    // follow the wrapper's `data-*` each time the calendar opens: "Today" is
    // off when today lies outside min/max, "Clear" shows for a clearable field.
    syncFooter(popup) {
      var d = this.el.dataset;
      var today = popup.querySelector("[data-popup-today]");
      var clear = popup.querySelector("[data-popup-clear]");
      if (today) today.disabled = parseDateText(d.today, "Y-m-d", d.min, d.max) === null;
      if (clear) clear.classList.toggle("hidden", d.clearable !== "true");
    },

    position() {
      var popup = this.popupEl();
      var spot = popupPlacement(
        this.el.getBoundingClientRect(),
        { width: popup.offsetWidth, height: popup.offsetHeight },
        { width: document.documentElement.clientWidth, height: document.documentElement.clientHeight }
      );
      popup.style.top = spot.top + "px";
      popup.style.left = spot.left + "px";
    },

    // A day picked in the calendar, or "Today".
    pick(iso) {
      var ok = parseDateText(iso, "Y-m-d", this.el.dataset.min, this.el.dataset.max);
      if (ok === null) return;
      this.setValue(ok);
      this.syncText();
      this.closePopup(true);
    },

    bindClosers() {
      var self = this;
      var popup = this.popupEl();
      var close = function() { self.closePopup(false); };
      var dialog = this.el.closest("dialog");
      this.closers = [
        [document, "pointerdown", function(e) {
          if (popup.contains(e.target)) return;
          if (e.target.closest && e.target.closest("[data-open]") && self.el.contains(e.target)) return;
          self.closePopup(false);
        }, true],
        // A scroll of the page or of an ancestor of the field moves the field
        // away from the popup; an unrelated panel scrolling does not.
        [window, "scroll", function(e) {
          var t = e.target;
          if (popup.contains(t)) return;
          if (t === document || t === document.documentElement || (t.contains && t.contains(self.el))) close();
        }, true],
        [window, "resize", close, false],
        [window, "pagehide", close, false]
      ];
      if (dialog) this.closers.push([dialog, "close", close, false]);
      this.closers.forEach(function(c) { c[0].addEventListener(c[1], c[2], c[3]); });
      // Cally's own height changes (a 6-week month): keep it clear of the field.
      if (typeof ResizeObserver === "function") {
        this.resizer = new ResizeObserver(function() {
          if (self.popupOpen() && popup.style.visibility !== "hidden") self.position();
        });
        this.resizer.observe(popup);
      }
    },

    closePopup(refocus) {
      if (this.closers) {
        this.closers.forEach(function(c) { c[0].removeEventListener(c[1], c[2], c[3]); });
        this.closers = null;
      }
      if (this.resizer) {
        this.resizer.disconnect();
        this.resizer = null;
      }
      var popup = this.popupEl();
      if (popup && this.popupOpen()) {
        try { popup.hidePopover(); } catch (_e) { /* already closed */ }
      }
      this.setExpanded(false);
      if (refocus) {
        var t = this.textEl();
        if (t) t.focus();
      }
    },

    setExpanded(open) {
      var btn = this.el.querySelector("[data-open]");
      if (btn) btn.setAttribute("aria-expanded", open ? "true" : "false");
    },

    toggleClear() {
      var btn = this.el.querySelector("[data-clear]");
      var text = this.textEl();
      if (btn && text) btn.classList.toggle("hidden", text.value === "");
    },

    // The text was refused: remember it (a patch may rewrite the field) and mark it.
    reject(reason) {
      this.rejected = { text: this.textEl().value, reason: reason };
      this.markInvalid();
    },

    // The text is, or became, the date: forget any refusal.
    accept() {
      this.rejected = null;
      this.markValid();
    },

    markInvalid() {
      var t = this.textEl();
      var d = this.el.dataset;
      var expected = (this.rejected && this.rejected.reason === "range" && d.rangeMessage) || d.expected || "";
      t.setCustomValidity(expected || "invalid");
      t.setAttribute("aria-invalid", "true");
      t.classList.add("input-error");
      if (expected) {
        var cur = t.getAttribute("title");
        if (!this.ownTitle(cur)) this.callerTitle = cur;
        t.setAttribute("title", expected);
      }
      this.say(expected);
    },

    // Is this title one the hook wrote (rather than the caller's)?
    ownTitle(title) {
      var d = this.el.dataset;
      return title == null || title === d.expected || title === d.rangeMessage;
    },

    // The rejection hint is a live region: a screen reader announces the text
    // that appears in it, and the text input points at it (aria-describedby).
    say(message) {
      var hint = this.el.querySelector("[data-date-hint]");
      if (hint && hint.textContent !== message) hint.textContent = message;
    },

    markValid() {
      var t = this.textEl();
      if (!t) return;
      t.setCustomValidity("");
      if (this.ownTitle(t.getAttribute("title"))) {
        if (this.callerTitle != null) t.setAttribute("title", this.callerTitle);
        else t.removeAttribute("title");
      }
      this.say("");
      // Errors the server rendered stay.
      if (!t.hasAttribute("data-has-errors")) {
        t.removeAttribute("aria-invalid");
        t.classList.remove("input-error");
      }
    },

    // After a patch: put back the marks only the hook knows about.
    refresh() {
      var t = this.textEl();
      if (!t) return;
      this.enhance();
      if (this.rejected) this.markInvalid();
      else this.markValid();
      this.toggleClear();
      this.setExpanded(this.popupOpen());
    }
  };

  // ---------------------------------------------------------------------------
  // PkCheckboxIndeterminate — applies the `indeterminate` property to a
  // checkbox based on `data-indeterminate="true"`. HTML has no attribute
  // form of `indeterminate`, so a small hook is needed to read the dataset
  // and assign the JS property after every LV patch.
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.PkCheckboxIndeterminate = {
    _apply() {
      this.el.indeterminate = this.el.dataset.indeterminate === "true";
    },
    mounted() { this._apply(); },
    updated() { this._apply(); }
  };

  // Resolves the push target that OWNS `el`: the numeric CID of the nearest
  // LiveComponent ancestor, or null when nothing but the LiveView is above it.
  // pushEventTo with an ELEMENT resolves the target from that element's
  // phx-target attribute — which the elements here (a <dialog>, a load-more
  // sentinel) don't carry, so the push silently landed on the host LiveView.
  // The numeric CID is a first-class target in LiveView's `withinTargets`.
  //
  // The search stops at a nested LiveView root: a [data-phx-component] on the
  // far side of one belongs to a DIFFERENT view, and its cid means nothing to
  // this hook's socket. Whichever boundary is nearer wins.
  function ownerComponentCid(el) {
    if (!el || typeof el.closest !== "function") return null;
    const scope = el.closest("[data-phx-component],[data-phx-session]");
    if (!scope || !scope.hasAttribute("data-phx-component")) return null;
    const cid = parseInt(scope.getAttribute("data-phx-component"), 10);
    return Number.isNaN(cid) ? null : cid;
  }

  // Pushes `event` to whoever owns `el` — its LiveComponent when there is one,
  // the LiveView otherwise. `hook` is any object with LiveView's pushEvent /
  // pushEventTo (a hook, or another hook acting on a stacked child's behalf).
  function pushToOwner(hook, el, event, payload) {
    const cid = ownerComponentCid(el);
    if (cid === null) {
      hook.pushEvent(event, payload || {});
    } else {
      hook.pushEventTo(cid, event, payload || {});
    }
  }

  // True when an `input` event's target belongs to a submittable form of
  // THIS dialog — not a nested dialog's, not a filter/search form's. The
  // cheap pre-check behind PkDialog's `data-close-guard="input"`; the
  // decision itself is `guardedDirty` below.
  function guardedInput(dialog, target) {
    if (!dialog || !target || typeof target.closest !== "function") return false;
    if (target.closest("dialog") !== dialog) return false;
    if (target.type === "search" || target.closest("form[role=search]")) return false;
    return !!target.closest("form[phx-submit]");
  }

  // Does a field of a submittable form of THIS dialog differ from its
  // default (the value the server rendered)? Checkboxes/radios by
  // checkedness, selects by selection, everything else by value. A
  // search field never counts. This is what "holds unsaved input" means
  // on the client: a form the server re-rendered with the typed value, or
  // reset after a save, reads clean again — no latch to get stuck on.
  function fieldDirty(el) {
    if (!el || !el.name || el.disabled) return false;
    const type = (el.type || "").toLowerCase();
    if (type === "hidden" || type === "submit" || type === "button" || type === "search") return false;
    if (el.closest && el.closest("form[role=search]")) return false;
    if (type === "checkbox" || type === "radio") return el.checked !== el.defaultChecked;
    if (el.tagName === "SELECT") {
      for (const o of Array.from(el.options || [])) if (o.selected !== o.defaultSelected) return true;
      return false;
    }
    if (typeof el.value === "string" && typeof el.defaultValue === "string") {
      return el.value !== el.defaultValue;
    }
    return false;
  }

  function guardedDirty(dialog) {
    if (!dialog || typeof dialog.querySelectorAll !== "function") return false;
    for (const form of Array.from(dialog.querySelectorAll("form[phx-submit]"))) {
      if (form.closest && form.closest("dialog") !== dialog) continue;
      for (const el of Array.from(form.elements || [])) if (fieldDirty(el)) return true;
    }
    return false;
  }

  // The `phx-value-*` attributes of an element as an event payload — the
  // same convention LiveView applies to `phx-click`, so a hook-driven
  // element (PkDialog's close) can carry identifiers exactly like a
  // clicked button would (`phx-value-frame-ref` → `{"frame-ref": …}`).
  // Elements without any such attribute yield `{}`, the pre-existing
  // payload, so every current consumer is unaffected.
  function phxValuePayload(el) {
    const payload = {};
    if (!el || !el.attributes) return payload;
    for (const attr of Array.from(el.attributes)) {
      if (attr.name.startsWith("phx-value-")) {
        payload[attr.name.slice("phx-value-".length)] = attr.value;
      }
    }
    return payload;
  }

  if (typeof module === "object" && module.exports) {
    module.exports.ownerComponentCid = ownerComponentCid;
    module.exports.pushToOwner = pushToOwner;
    module.exports.phxValuePayload = phxValuePayload;
    module.exports.guardedInput = guardedInput;
    module.exports.guardedDirty = guardedDirty;
  }

  // Returns true if the given <dialog> is in the browser's top layer
  // (was opened via showModal()). Uses the `:modal` pseudo-class as
  // the truth source, with a graceful fallback to the `open`
  // attribute for older engines that lack `:modal` support.
  function isDialogOpenInBrowser(el) {
    if (!el || typeof el.matches !== "function") return false;
    try {
      return el.matches(":modal");
    } catch (_e) {
      // `matches()` throws SyntaxError on the `:modal` selector when
      // the engine doesn't recognise it (pre-2022 browsers). The
      // fallback loses fidelity to morphdom-strip cases but is the
      // best we can do without the pseudo-class.
      return !!el.open;
    }
  }

  if (typeof module === "object" && module.exports) {
    module.exports.isDialogOpenInBrowser = isDialogOpenInBrowser;
  }

  // True when a click on a dialog is a click on its backdrop: the press AND
  // the release must both land on the <dialog> element itself. The browser
  // dispatches a click to the nearest common ancestor of the two, so a drag
  // that starts inside the box and is let go past its edge — selecting the
  // text of a field, pulling a textarea's resize grip — also arrives with the
  // dialog as its target, and closed the modal under the user's cursor with
  // whatever they had typed. So does the opposite drag, from the backdrop
  // into the box, which is why the click's own target proves nothing and the
  // release is checked separately.
  function backdropClick(dialog, pressTarget, releaseTarget, clickTarget) {
    return !!dialog && pressTarget === dialog && releaseTarget === dialog && clickTarget === dialog;
  }

  // Keeps the size a user dragged a <textarea> to. The resize grip writes
  // inline `height`/`width`, which the server never rendered, so the next
  // LiveView patch drops the `style` attribute and the field snaps back to
  // its default size mid-edit. A press on a textarea that leaves its inline
  // size changed is a resize; from then on the size is put back whenever a
  // patch takes it away. Bound once on the document, so every textarea is
  // covered — core's components, a module's own markup, inside a dialog or
  // not — with nothing to opt into.
  function textareaSizeChanged(before, after) {
    return !!before && !!after && (before.height !== after.height || before.width !== after.width);
  }

  function inlineSize(el) {
    return { height: el.style.height || "", width: el.style.width || "" };
  }

  // Sizes by element id, for a textarea that is REPLACED rather than patched
  // — a language switch re-mounts every translatable field. The replacement
  // carries the same id and takes the size its predecessor was dragged to.
  // The document is only watched once something has actually been resized.
  const keptSizesById = {};
  let replacementObserver = null;

  function adoptKeptSize(el) {
    if (!el || el.tagName !== "TEXTAREA" || !el.id || el._pkKeptSize) return;
    const size = keptSizesById[el.id];
    if (!size) return;
    el.style.height = size.height;
    el.style.width = size.width;
    keepTextareaSize(el, size);
  }

  function watchForReplacements() {
    if (replacementObserver || typeof MutationObserver !== "function" || !document.body) return;
    replacementObserver = new MutationObserver(function(records) {
      for (const record of records) {
        for (const node of record.addedNodes) {
          if (node.nodeType !== 1) continue;
          if (node.tagName === "TEXTAREA") adoptKeptSize(node);
          else if (node.querySelectorAll) node.querySelectorAll("textarea[id]").forEach(adoptKeptSize);
        }
      }
    });
    replacementObserver.observe(document.body, { childList: true, subtree: true });
  }

  function keepTextareaSize(el, size) {
    el._pkKeptSize = size;
    if (el.id) {
      keptSizesById[el.id] = size;
      watchForReplacements();
    }
    if (el._pkSizeObserver || typeof MutationObserver !== "function") return;
    el._pkSizeObserver = new MutationObserver(function() {
      const kept = el._pkKeptSize;
      // Mid-drag the browser is the one writing the style; leave it alone.
      if (!kept || el._pkResizing) return;
      if (el.style.height !== kept.height) el.style.height = kept.height;
      if (el.style.width !== kept.width) el.style.width = kept.width;
    });
    el._pkSizeObserver.observe(el, { attributes: true, attributeFilter: ["style"] });
  }

  if (typeof document !== "undefined" && document.addEventListener && !window.__pkTextareaSizeBound) {
    window.__pkTextareaSizeBound = true;
    document.addEventListener("pointerdown", function(e) {
      const el = e.target;
      if (!el || el.tagName !== "TEXTAREA") return;
      const before = inlineSize(el);
      el._pkResizing = true;
      const done = function() {
        window.removeEventListener("pointerup", done, true);
        window.removeEventListener("pointercancel", done, true);
        window.removeEventListener("pointermove", released, true);
        el._pkResizing = false;
        const after = inlineSize(el);
        if (textareaSizeChanged(before, after)) keepTextareaSize(el, after);
      };
      // A button let go outside the window may never deliver its pointerup.
      // The first move that reports no button down ends the press instead, or
      // the field would stay "mid-drag" and the next patch would take its size.
      const released = function(move) { if (move.buttons === 0) done(); };
      window.addEventListener("pointerup", done, true);
      window.addEventListener("pointercancel", done, true);
      window.addEventListener("pointermove", released, true);
    }, true);
  }

  // The same drag, caught for everything that is not a PkDialog. A press that
  // begins in a text field and is released outside it — a selection dragged
  // past the field's edge — is dispatched as a click on their common ancestor:
  // a wrapper carrying `phx-click` (a hand-rolled modal's backdrop, a row or
  // card that opens something) then fires and takes the half-typed text with
  // it. Nobody means that gesture as a click on the ancestor, so it is
  // stopped before any handler sees it. Only pointer clicks count: a keyboard
  // activation reports `detail` 0 and has no press to compare against.
  function textEntryField(el) {
    if (!el || !el.tagName) return false;
    if (el.isContentEditable) return true;
    if (el.tagName === "TEXTAREA") return true;
    if (el.tagName !== "INPUT") return false;
    const type = (el.type || "text").toLowerCase();
    return ["text", "search", "email", "url", "tel", "password", "number"].indexOf(type) !== -1;
  }

  function strayFieldClick(pressTarget, clickTarget, detail) {
    if (!pressTarget || !clickTarget || !detail) return false;
    if (pressTarget === clickTarget) return false;
    if (!textEntryField(pressTarget)) return false;
    return typeof clickTarget.contains === "function" && clickTarget.contains(pressTarget);
  }

  if (typeof document !== "undefined" && document.addEventListener && !window.__pkStrayClickBound) {
    window.__pkStrayClickBound = true;
    let pressedOn = null;
    document.addEventListener("pointerdown", function(e) { pressedOn = e.target; }, true);
    document.addEventListener("click", function(e) {
      const pressed = pressedOn;
      pressedOn = null;
      if (strayFieldClick(pressed, e.target, e.detail)) e.stopPropagation();
    }, true);
  }

  // --- Unsaved input -------------------------------------------------------
  //
  // A modal holding a form the user has typed into does not close on the
  // first Escape or backdrop click: the attempt is refused with a nudge of
  // the box, and only a second one within a few seconds goes through. One
  // stray click or key no longer costs a filled-in form, and nobody is ever
  // trapped — the modal's own Cancel / ✕ / Save are untouched, and so is a
  // deliberate second try.
  //
  // "Typed into" is a flag set by a real input/change event in a submittable
  // form, not a comparison with the rendered values: a form with `phx-change`
  // is re-rendered with what was typed after every keystroke, and would read
  // clean again the moment the server answered.
  const DISCARD_WINDOW_MS = 4000;
  // The same Escape reaches a stacked dialog twice (its own cancel and the
  // parent's relay); anything this close to the refusal is that same attempt.
  const SAME_ATTEMPT_MS = 250;

  function discardAttempt(lastRefusedAt, now) {
    if (!lastRefusedAt) return "refuse";
    const since = now - lastRefusedAt;
    if (since < SAME_ATTEMPT_MS) return "same";
    return since <= DISCARD_WINDOW_MS ? "allow" : "refuse";
  }

  function nudgeBox(box) {
    if (!box || typeof box.animate !== "function") return;
    const still = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const frames = still
      ? [{ opacity: 1 }, { opacity: 0.6 }, { opacity: 1 }]
      : [
          { transform: "translateX(0)" },
          { transform: "translateX(-8px)" },
          { transform: "translateX(8px)" },
          { transform: "translateX(-4px)" },
          { transform: "translateX(0)" }
        ];
    box.animate(frames, { duration: 220, easing: "ease-in-out" });
  }

  // Refuses or allows one close attempt on `holder`, an object carrying the
  // `_pkTouched` / `_pkRefusedAt` state. True means: do not close.
  function refuseUnsavedClose(holder, box) {
    if (!holder || !holder._pkTouched) return false;
    const verdict = discardAttempt(holder._pkRefusedAt, Date.now());
    if (verdict === "allow") {
      holder._pkTouched = false;
      holder._pkRefusedAt = 0;
      return false;
    }
    if (verdict === "refuse") {
      holder._pkRefusedAt = Date.now();
      nudgeBox(box);
    }
    return true;
  }

  // The same protection for a modal that is NOT a PkDialog: daisyUI's
  // class-driven shape, `.modal.modal-open` around a `.modal-box` and a
  // `.modal-backdrop`, closed by a `phx-click` on the backdrop and often a
  // `phx-window-keydown` for Escape. Those are plain LiveView bindings, so the
  // attempt is stopped here, in the capture phase, before LiveView's own
  // window listeners hear it.
  function classModalOf(el) {
    if (!el || typeof el.closest !== "function") return null;
    const dialog = el.closest("dialog");
    if (dialog && dialog.getAttribute("phx-hook") === "PkDialog") return null;
    const modal = el.closest(".modal-open");
    if (!modal || modal.getAttribute("phx-hook") === "PkDialog") return null;
    return modal;
  }

  function submittableField(target) {
    if (!target || typeof target.closest !== "function") return false;
    if (target.type === "search" || target.closest("form[role=search]")) return false;
    return !!target.closest("form[phx-submit]");
  }

  if (typeof document !== "undefined" && document.addEventListener && !window.__pkUnsavedGuardBound) {
    window.__pkUnsavedGuardBound = true;
    const touch = function(e) {
      if (e.isTrusted === false || !submittableField(e.target)) return;
      const modal = classModalOf(e.target);
      if (modal) modal._pkTouched = true;
    };
    document.addEventListener("input", touch, true);
    document.addEventListener("change", touch, true);
    // Submission may fail validation or persistence. Only a confirmed save
    // clears the guard: an add-another flow can dispatch this on its modal
    // after the server reports success, for either modal implementation.
    document.addEventListener("pk:dialog-saved", function(e) {
      const target = e.target;
      if (!target || typeof target.closest !== "function") return;
      const modal = target.closest("dialog") || classModalOf(target);
      if (modal) {
        modal._pkTouched = false;
        modal._pkRefusedAt = 0;
      }
    }, true);
    window.addEventListener("phx:pk:dialog-saved", function(e) {
      const id = e.detail && e.detail.id;
      if (typeof id !== "string" || !id) return;
      const modal = document.getElementById(id);
      if (modal) {
        modal._pkTouched = false;
        modal._pkRefusedAt = 0;
      }
    });
    document.addEventListener("click", function(e) {
      const backdrop = e.target && e.target.closest && e.target.closest(".modal-backdrop");
      if (!backdrop) return;
      const modal = classModalOf(backdrop);
      if (modal && refuseUnsavedClose(modal, modal.querySelector(".modal-box"))) {
        e.stopPropagation();
        e.preventDefault();
      }
    }, true);
    document.addEventListener("keydown", function(e) {
      if (e.key !== "Escape") return;
      // Escape that only dismisses an input method's candidate list is not a
      // request to close anything; a `phx-window-keydown` binding cannot tell.
      if (e.isComposing) { e.stopPropagation(); return; }
      // A native dialog lives above every CSS modal in the browser's top
      // layer, and need not carry .modal-open. Its own cancel handler decides.
      if (Array.from(document.querySelectorAll("dialog")).some(isDialogOpenInBrowser)) return;
      // Only the topmost modal answers an Escape. A touched modal underneath an
      // untouched (or PkDialog) one must not swallow the key meant to close the
      // one on top.
      const open = document.querySelectorAll(".modal-open");
      const modal = open[open.length - 1];
      if (!modal || modal.getAttribute("phx-hook") === "PkDialog" || !modal._pkTouched) return;
      if (refuseUnsavedClose(modal, modal.querySelector(".modal-box"))) {
        e.stopPropagation();
        e.preventDefault();
      }
    }, true);
  }

  if (typeof module === "object" && module.exports) {
    module.exports.backdropClick = backdropClick;
    module.exports.textareaSizeChanged = textareaSizeChanged;
    module.exports.strayFieldClick = strayFieldClick;
    module.exports.discardAttempt = discardAttempt;
  }

  // NOTE: no scrollbar-gutter games here. Old daisyUI (5.0.x) reserved a
  // scrollbar gutter unconditionally while a modal was open, and this hook
  // used to counter it with an inline `scrollbar-gutter: auto` override —
  // which traded the phantom right-edge strip on non-scrolling pages for a
  // ~15px content reflow on pages that DO scroll (classic-scrollbar users saw
  // the scrollbar pop in/out around every modal). daisyUI >= 5.1 reserves the
  // gutter only when the page really has a scrollbar (rootscrollgutter.css),
  // which handles both page types correctly — PhoenixKit pins such a version
  // (see PhoenixKit.Install.DaisyUI), so the override is gone. Don't re-add it.
  window.PhoenixKitHooks.PkDialog = {
    _isCloseable() {
      if (this._guardTripped) return false;
      return this.el.dataset.closeable !== "false";
    },
    // data-close-guard="confirm" (the default): true when this Escape or
    // backdrop click is the first attempt on a form that has been typed into.
    _refuseUnsaved() {
      if (this.el.dataset.closeGuard !== "confirm") return false;
      return refuseUnsavedClose(this.el, this.el.querySelector(".modal-box"));
    },
    _forgetUnsaved() {
      this.el._pkTouched = false;
      this.el._pkRefusedAt = 0;
    },
    // A dialog in the top layer whose `open` attribute has gone missing still
    // LOOKS open but behaves as closed: the Escape close steps and `close()`
    // both return early, so no `close` event fires and `_onClose` never pushes
    // the server's close event — the modal vanishes from the screen while the
    // server still believes it is open, and re-opens on the next patch. The
    // server deliberately never renders `open` (see the note in `modal/1`:
    // showModal() throws on a dialog that already carries it), so morphdom
    // strips the attribute on every patch and this guard is the only thing
    // that puts it back before a close.
    _restoreOpenAttr() {
      if (!this.el.open && isDialogOpenInBrowser(this.el)) {
        this.el.setAttribute("open", "");
      }
    },
    _pushClose() {
      const ev = this.el.dataset.closeEvent;
      if (!ev) return;
      // Route to the LiveComponent that OWNS the dialog — a component-owned
      // modal's close event landed on the host LV instead (2026-08-31 — the
      // item selector's stacked details popup never closed on Esc; the
      // selector itself only "closed" because the misrouted event hit the
      // host). LV-owned dialogs have no component ancestor and keep routing
      // to the LV. See `pushToOwner`. The payload is the dialog's own
      // `phx-value-*` attributes (a stacked popup host stamps its frame
      // reference there so a close can be matched against the top frame).
      pushToOwner(this, this.el, ev, phxValuePayload(this.el));
    },
    _sync() {
      // `data-show` drives visibility for keep_in_dom modals. Conditional
      // modals (rendered only when @show=true) get the same attribute
      // value, so this works for both paths.
      // Absent attribute defaults to "true" so a consumer that doesn't
      // set data-show (legacy callers) keeps the original mount-opens
      // behavior.
      const wantOpen = this.el.dataset.show !== "false";
      // `:modal` matches whenever the dialog is in the browser's top
      // layer (showModal was called). This is the truth source — `el.open`
      // is just the reflected attribute, which Phoenix LV's DOM patcher
      // strips on re-render if it wasn't in the server template (the
      // browser added it via showModal(), the server didn't). Using
      // `:modal` keeps state in sync even after that attribute gets
      // stripped on a patch.
      //
      // `:modal` is a relatively new CSS pseudo-class (Chrome 105+,
      // Safari 15.6+, Firefox 117+). On browsers that have `matches()`
      // but not `:modal` it throws SyntaxError, which would break the
      // hook entirely — fall back to the `open` attribute so older
      // engines degrade to the pre-fix behavior rather than crash.
      const isOpenForBrowser = isDialogOpenInBrowser(this.el);
      if (
        wantOpen &&
        !isOpenForBrowser &&
        typeof this.el.showModal === "function"
      ) {
        this._forgetUnsaved();
        this.el.showModal();
      } else if (wantOpen && isOpenForBrowser) {
        // Dialog is in the top layer but the `open` attribute may have
        // been stripped by Phoenix LV's DOM patch (the server template
        // doesn't include `open=""` — the browser added it when
        // showModal() ran). CSS treats `dialog:not([open])` as
        // `display: none`, so the dialog becomes invisible AND
        // uninteractable while still blocking clicks elsewhere from
        // the top layer. Restore the attribute so the dialog renders.
        if (!this.el.open) {
          this.el.setAttribute("open", "");
        }
      } else if (!wantOpen && isOpenForBrowser) {
        // LV-driven close. If morphdom stripped the `open` attr after
        // the external showModal, restore it so close() can actually
        // release the top layer (close() needs `open` to fire 'close'
        // and detach from the top layer on every UA).
        if (!this.el.open) {
          this.el.setAttribute("open", "");
        }
        // Mark the close as LV-initiated so _onClose skips the echo
        // push (LV already knows data-show=false).
        this._closeFromLV = true;
        this._forgetUnsaved();
        this.el.close();
      }
    },
    mounted() {
      const self = this;
      this._closeFromLV = false;

      self._onCancel = function(e) {
        if (!self._isCloseable()) { e.preventDefault(); return; }
        // Escape's close steps do nothing without the `open` attribute, and
        // then no `close` event reaches `_onClose` to push the server's close.
        self._restoreOpenAttr();
        // A child dialog is stacked open INSIDE this one (the item
        // selector's product-details popup is the shipped case). Esc
        // must close only the TOP popup — but Chromium groups the close
        // watchers of dialogs whose showModal() ran without user
        // activation (ours run from LiveView patches), so a single Esc
        // fires 'cancel' on EVERY dialog in the group (2026-08-31: "Esc
        // closes both popups, but only top one needs to go"). Keep THIS
        // dialog open and RELAY the close request to the deepest stacked
        // child in its own semantics: a synthetic cancelable 'cancel',
        // then close() unless the child prevented it (a server-driven
        // child prevents and pushes its own event). preventDefault alone
        // is not enough — Chromium stops the grouped chain at the first
        // prevented watcher, so the child's own cancel never fires
        // (verified: neither popup closed).
        // Match by the browser's own notion of "open" (:modal), not the
        // `open` attribute — morphdom can strip the attribute between a
        // patch and the next _sync, and `dialog[open]` would miss the
        // child in that window (2026-08-31 external review). DOM order
        // stands in for top-layer order; the shipped stacks nest one
        // child, where the two agree.
        const stacked = Array.prototype.filter.call(
          self.el.querySelectorAll("dialog"),
          isDialogOpenInBrowser
        );
        if (stacked.length > 0) {
          e.preventDefault();
          const top = stacked[stacked.length - 1];
          // The child holds unsaved input of its own: its guard decides.
          if (top._pkRefuseUnsaved && top._pkRefuseUnsaved()) return;
          // Drive the child's SERVER close directly (its data-close-event
          // to its owning component by CID) and close its element for the
          // instant visual — relying on the child's own 'close' echo
          // proved fragile (the queued close event was observed not to
          // fire at all in this stack). Flag the child so its own
          // 'close' handler, when the event DOES fire, skips the echo
          // push — otherwise a non-idempotent close event (a toggle)
          // would fire twice (2026-08-31 external review).
          const closeEv = top.dataset && top.dataset.closeEvent;
          // The child's OWN cancel handler now pushes its close too (see
          // "Escape on THIS dialog" below). When the grouped chain reaches
          // the child before this parent, a fresh stamp says that push has
          // already gone out — pushing again would double-fire a
          // non-idempotent close event, the very thing the stamp guards.
          const childPushed =
            top._pkStackClosePushedAt &&
            Date.now() - top._pkStackClosePushedAt < 1000;
          if (closeEv && !childPushed) {
            // Stamped, not flagged: the child's own 'close' handler clears
            // this, but that handler is exactly what was observed not to
            // run here — a boolean would then suppress the child's NEXT
            // genuine close for the life of the element, leaving a dialog
            // the server never hears about (and re-opens on the next
            // patch). A stamp self-heals.
            top._pkStackClosePushedAt = Date.now();
            pushToOwner(self, top, closeEv, phxValuePayload(top));
          }
          top.close();
          return;
        }
        // Escape on THIS dialog. `cancel` is the only event we can rely on:
        // Chromium dismisses a close-watcher dialog — one whose showModal()
        // ran without user activation, which is every server-driven modal
        // here — WITHOUT ever firing `close` (measured on a live page,
        // 2026-09-20: cancel fires with `open` still set, the dialog leaves
        // the top layer, and no close event is dispatched; the same shape
        // the stacked note above records). `_onClose` therefore never runs,
        // the hook never pushes `on_close`, and the server goes on believing
        // the modal is open — re-opening it on the next patch. Push here,
        // and stamp the element so a `close` that DOES arrive (an explicit
        // close() from the backdrop path, or destroyed()) skips the echo.
        if (self._refuseUnsaved()) { e.preventDefault(); return; }
        self._forgetUnsaved();
        self.el._pkStackClosePushedAt = Date.now();
        self._pushClose();
      };
      // 'close' fires for our own el.close() in destroyed(), the backdrop
      // click (via _onClick → el.close()) and form `method="dialog"`
      // submits. It does NOT reliably fire for Escape — see `_onCancel`.
      self._onClose = function() {
        // `_pkStackClosePushedAt` is stamped by a stacked PARENT dialog that
        // already pushed this dialog's close event during a grouped cancel —
        // echoing here would double-fire the server handler. `close()` queues
        // its event as a task, so a real echo lands immediately; anything
        // older is a stamp whose close event never arrived and must not
        // suppress this close.
        const stackPushed =
          self.el._pkStackClosePushedAt &&
          Date.now() - self.el._pkStackClosePushedAt < 1000;
        if (!self._closeFromLV && !stackPushed) self._pushClose();
        self._forgetUnsaved();
        // Reset both now that the close event has been fully processed. The
        // next user-initiated close (Esc, backdrop) will fall through to the
        // echo push as intended.
        self._closeFromLV = false;
        self.el._pkStackClosePushedAt = 0;
      };
      // Backdrop click: a click event whose target is the <dialog> itself
      // (rather than a descendant) means the user clicked outside the
      // modal-box on the ::backdrop surface. Children stop propagation
      // naturally because event.target lands on them, not on the dialog.
      // The press and the release must both have landed there too — see
      // `backdropClick`. A release outside the dialog never reaches these
      // listeners, which leaves the release unset and the click refused.
      self._pressTarget = null;
      self._releaseTarget = null;
      self._onPointerDown = function(e) {
        self._pressTarget = e.target;
        self._releaseTarget = null;
      };
      self._onPointerUp = function(e) { self._releaseTarget = e.target; };
      self._onClick = function(e) {
        const pressTarget = self._pressTarget;
        const releaseTarget = self._releaseTarget;
        self._pressTarget = null;
        self._releaseTarget = null;
        if (!backdropClick(self.el, pressTarget, releaseTarget, e.target) || !self._isCloseable()) return;
        if (self._refuseUnsaved()) return;
        // Same reason as the Escape path: `close()` is a no-op, and fires no
        // `close` event, on a top-layer dialog whose `open` attribute is gone.
        self._restoreOpenAttr();
        self.el.close();
      };
      this.el.addEventListener("cancel", self._onCancel);
      this.el.addEventListener("close", self._onClose);
      this.el.addEventListener("pointerdown", self._onPointerDown);
      this.el.addEventListener("pointerup", self._onPointerUp);

      // data-close-guard="confirm": remember that a submittable form of THIS
      // dialog was typed into. Kept on the element so a stacked parent's
      // Escape relay can ask the child (`_pkRefuseUnsaved`).
      self._onTouch = function(e) {
        if (e.isTrusted === false) return;
        if (guardedInput(self.el, e.target)) self.el._pkTouched = true;
      };
      this.el.addEventListener("input", self._onTouch);
      this.el.addEventListener("change", self._onTouch);
      this.el._pkRefuseUnsaved = function() { return self._refuseUnsaved(); };
      this.el.addEventListener("click", self._onClick);

      // data-close-guard="input": see the header comment. Local state only —
      // the server's data-closeable remains the source of truth once it
      // arrives; this covers the round trip (and a debounce window) before it.
      // Recomputed, never latched: a frame whose LiveView never reports
      // dirtiness (a page with a plain submit form) must not lose Esc for
      // good after one keystroke (the sweep, 2026-09-05).
      self._guardTripped = false;
      if (self.el.dataset.closeGuard === "input") {
        self._onInput = function(e) {
          if (guardedInput(self.el, e.target)) self._guardTripped = guardedDirty(self.el);
        };
        this.el.addEventListener("input", self._onInput);
      }

      // Instant client-side open: a trigger can dispatch this custom
      // event (Phoenix.LiveView.JS.dispatch("pk:dialog-show", to: "#id"))
      // ALONGSIDE its server push, so the dialog appears the same frame
      // as the click while the server round-trip fills the content in.
      // The subsequent LV patch (data-show=true) finds the dialog already
      // open and no-ops; server-driven close keeps working unchanged.
      self._onShowEvent = function() {
        if (
          !isDialogOpenInBrowser(self.el) &&
          typeof self.el.showModal === "function"
        ) {
          self.el.showModal();
        }
      };
      this.el.addEventListener("pk:dialog-show", self._onShowEvent);

      // Server-initiated close for a dialog that was opened CLIENT-side
      // (pk:dialog-show) but whose content the server declined to load —
      // without this, an error path that never flips data-show would
      // leave the skeleton dialog open forever. LV removes hook
      // handleEvent listeners automatically on destroy.
      this.handleEvent("pk:dialog-close", function(payload) {
        if (payload && payload.id && payload.id !== self.el.id) return;
        if (isDialogOpenInBrowser(self.el)) {
          if (!self.el.open) self.el.setAttribute("open", "");
          self._closeFromLV = true;
          self.el.close();
        }
      });

      this._sync();
    },
    updated() {
      // Every server patch re-reads the forms: a save/reset renders them
      // clean, a re-render with the typed value makes data-closeable the
      // authority — either way the local guard lets go.
      if (this.el.dataset.closeGuard === "input") {
        this._guardTripped = guardedDirty(this.el);
      }
      this._sync();
    },
    destroyed() {
      // LV is removing the element. Tell _onClose not to echo a close
      // event back (LV already initiated this).
      this._closeFromLV = true;
      // Close the dialog so the browser releases it from the top layer.
      // Use the same "is the browser holding this dialog open?" predicate
      // as `_sync()` — `el.open` alone is unreliable when morphdom stripped
      // the attribute earlier. Restore `open` first if needed so `close()`
      // can release the top layer cleanly.
      if (isDialogOpenInBrowser(this.el)) {
        if (!this.el.open) this.el.setAttribute("open", "");
        this.el.close();
      }
      if (this._onCancel) this.el.removeEventListener("cancel", this._onCancel);
      if (this._onClose) this.el.removeEventListener("close", this._onClose);
      if (this._onClick) this.el.removeEventListener("click", this._onClick);
      if (this._onPointerDown) this.el.removeEventListener("pointerdown", this._onPointerDown);
      if (this._onPointerUp) this.el.removeEventListener("pointerup", this._onPointerUp);
      if (this._onTouch) {
        this.el.removeEventListener("input", this._onTouch);
        this.el.removeEventListener("change", this._onTouch);
      }
      if (this._onShowEvent) this.el.removeEventListener("pk:dialog-show", this._onShowEvent);
      if (this._onInput) this.el.removeEventListener("input", this._onInput);
    }
  };

  // PkResizable — lets the person resize a box by grips on its edges and
  // corners (`<.resizable_modal>`'s modal-box). The grips are children with
  // `data-pk-resize="n|s|e|w|ne|nw|se|sw"`, rendered by the component.
  //
  //   data-size-key    name of the kept size in localStorage
  //   data-min-width   pixels, default 320
  //   data-min-height  pixels, default 240
  //
  // The box is centred by its dialog, so a drag changes the size by twice
  // the pointer's travel: the edge under the pointer follows the pointer and
  // the opposite one mirrors it. The size the person chose lives in inline
  // styles, which a LiveView patch strips, so `updated()` puts them back. The
  // server's own initial height is never inline (the component renders it as
  // a custom property that a class applies from `sm` up), so letting go of
  // the inline size — a double click, a window below 640px — leaves it as it
  // was. Below 640px nothing is applied: there the box is the component's
  // full-screen sheet. A double click on a grip forgets the size. What is
  // kept is the size the person saw (clamped to the minimum and the
  // viewport), and a press that moves less than a few pixels is a click, not
  // a resize.
  window.PhoenixKitHooks.PkResizable = {
    mounted() {
      const self = this;
      const el = this.el;
      this._size = this._read();
      this._drag = null;
      this._margin = 16;
      this._threshold = 4;

      this._onDown = function(e) {
        const grip = e.target.closest ? e.target.closest("[data-pk-resize]") : null;
        if (self._drag || !grip || !el.contains(grip) || e.button > 0 || !self._wide()) return;
        e.preventDefault();
        const rect = el.getBoundingClientRect();
        self._drag = {
          dir: grip.getAttribute("data-pk-resize"),
          x: e.clientX,
          y: e.clientY,
          w: rect.width,
          h: rect.height,
          id: e.pointerId,
          grip: grip,
          previousUserSelect: document.documentElement.style.userSelect,
          moved: false
        };
        try { grip.setPointerCapture(e.pointerId); } catch (_e) {}
        document.documentElement.style.userSelect = "none";
      };
      this._onMove = function(e) {
        const d = self._drag;
        if (!d || e.pointerId !== d.id) return;
        // Capture lost and the button let go elsewhere: the drag is over.
        if (e.buttons === 0) { self._end(); return; }
        if (!d.moved) {
          if (Math.abs(e.clientX - d.x) < self._threshold && Math.abs(e.clientY - d.y) < self._threshold) return;
          d.moved = true;
        }
        let w = d.w;
        let h = d.h;
        if (d.dir.indexOf("e") !== -1) w = d.w + 2 * (e.clientX - d.x);
        if (d.dir.indexOf("w") !== -1) w = d.w - 2 * (e.clientX - d.x);
        if (d.dir.indexOf("s") !== -1) h = d.h + 2 * (e.clientY - d.y);
        if (d.dir.indexOf("n") !== -1) h = d.h - 2 * (e.clientY - d.y);
        const horizontal = d.dir.indexOf("e") !== -1 || d.dir.indexOf("w") !== -1;
        const vertical = d.dir.indexOf("s") !== -1 || d.dir.indexOf("n") !== -1;
        const size = self._size || {};
        self._size = {
          w: horizontal ? Math.round(w) : size.w,
          h: vertical ? Math.round(h) : size.h
        };
        self._apply();
      };
      this._onUp = function(e) {
        const d = self._drag;
        if (!d || e.pointerId !== d.id) return;
        self._end();
      };
      this._onDblClick = function(e) {
        const grip = e.target.closest ? e.target.closest("[data-pk-resize]") : null;
        if (!grip || !el.contains(grip)) return;
        self._size = null;
        self._write();
        self._apply();
      };
      this._onWindowResize = function() { self._apply(); };

      el.addEventListener("pointerdown", this._onDown);
      el.addEventListener("pointermove", this._onMove);
      el.addEventListener("pointerup", this._onUp);
      el.addEventListener("pointercancel", this._onUp);
      el.addEventListener("lostpointercapture", this._onUp);
      el.addEventListener("dblclick", this._onDblClick);
      window.addEventListener("resize", this._onWindowResize);
      this._apply();
    },
    updated() { this._apply(); },
    destroyed() {
      window.removeEventListener("resize", this._onWindowResize);
      this._end();
    },
    // Ends a drag. A press that never moved past the threshold changes and
    // keeps nothing; otherwise the size kept is the one on screen.
    _end() {
      const d = this._drag;
      if (!d) return;
      this._drag = null;
      try { d.grip.releasePointerCapture(d.id); } catch (_e) {}
      document.documentElement.style.userSelect = d.previousUserSelect;
      if (!d.moved) return;
      this._size = this._bounded(this._size);
      this._write();
    },
    _limits() {
      const el = this.el;
      return {
        minW: parseInt(el.getAttribute("data-min-width"), 10) || 320,
        minH: parseInt(el.getAttribute("data-min-height"), 10) || 240,
        maxW: window.innerWidth - 2 * this._margin,
        maxH: window.innerHeight - 2 * this._margin
      };
    },
    // The size as `_apply` shows it: within the minimum and the viewport.
    _bounded(size) {
      if (!size) return size;
      const l = this._limits();
      return {
        w: size.w !== undefined ? this._clamp(size.w, l.minW, l.maxW) : size.w,
        h: size.h !== undefined ? this._clamp(size.h, l.minH, l.maxH) : size.h
      };
    },
    _wide() { return window.innerWidth >= 640; },
    _key() {
      const key = this.el.getAttribute("data-size-key");
      return key ? "pk:resizable:" + key : null;
    },
    _read() {
      try {
        const key = this._key();
        const raw = key && window.localStorage.getItem(key);
        const size = raw ? JSON.parse(raw) : null;
        if (!size || typeof size !== "object") return null;
        return {
          w: typeof size.w === "number" ? size.w : undefined,
          h: typeof size.h === "number" ? size.h : undefined
        };
      } catch (_e) { return null; }
    },
    _write() {
      try {
        const key = this._key();
        if (!key) return;
        if (this._size && (this._size.w || this._size.h)) {
          window.localStorage.setItem(key, JSON.stringify(this._size));
        } else {
          window.localStorage.removeItem(key);
        }
      } catch (_e) {}
    },
    _clamp(value, min, max) { return Math.max(1, Math.min(max, Math.max(min, value))); },
    // The kept size as inline styles, clamped to the minimum and to the
    // viewport as it is now; with nothing kept (or on a narrow screen) the
    // styles this hook owns are taken away and the component's own apply.
    _apply() {
      const el = this.el;
      const size = this._size;
      const props = ["width", "max-width", "height", "max-height"];
      if (!this._wide() || !size) {
        if (el.dataset.pkResized) {
          props.forEach(function(p) { el.style.removeProperty(p); });
          delete el.dataset.pkResized;
        }
        return;
      }
      const shown = this._bounded(size);
      if (shown.w) {
        el.style.setProperty("width", shown.w + "px");
        el.style.setProperty("max-width", "none");
      }
      if (shown.h) {
        el.style.setProperty("height", shown.h + "px");
        el.style.setProperty("max-height", "none");
      }
      el.dataset.pkResized = "true";
    }
  };

  // PkFitHeight — keeps an element that hangs over the page (a menu under a
  // field, a list in a dialog) inside what the person can see: its
  // max-height is the room between its own top and the bottom of the nearest
  // scrolling ancestor (a dialog's content area), or of the viewport when
  // there is none — so the ancestor gets no scrollbar because of it.
  // Measured when it is put on the page, after every patch, when it is shown
  // (it is observed itself, so a menu mounted hidden and revealed on the
  // client is measured then), and whenever the window, that ancestor or
  // anything scrolls.
  //
  //   data-fit-margin  pixels kept free under it, default 8
  //   data-fit-min     pixels it never goes below, default 160
  //
  // Below the minimum the overlay MAY overflow: with less than `data-fit-min`
  // pixels left it is that tall anyway, so it runs past the area and the area
  // scrolls. A field that low wants its menu above it, which this hook does
  // not do (ViewportPopover flips); `data-fit-min="0"` keeps the promise
  // strictly, at the price of a menu that can shrink to nothing.
  //
  // An element's own ceiling stays: a `max-height` from its classes is read
  // (with the inline value cleared) and the smaller of the two wins.
  //
  // The element scrolls its own content (give it `overflow-y: auto`, or make
  // it a flex column with a `min-h-0 overflow-y-auto` child) and is anchored by
  // its top edge, which is the edge the room is counted from. A LiveView patch
  // strips the inline style, so `updated()` measures again.
  //
  // The boundary is the nearest ancestor whose `overflow-y` is `auto` or
  // `scroll`. An `overflow: hidden` or `clip` ancestor between the two clips
  // the overlay sooner and is not seen; a `position: fixed` overlay is not
  // clipped by the scroller at all, yet is still limited by it. Both are the
  // caller's to avoid. `window.innerHeight` does not shrink for an on-screen
  // keyboard.
  //
  // Re-measuring from the observers and scroll is deferred to the next frame:
  // setting `max-height` inside a ResizeObserver callback resizes what that
  // observer watches and the browser reports "ResizeObserver loop completed
  // with undelivered notifications". The price: the first frame after a
  // hidden overlay is shown is painted before its height is limited. And a
  // ceiling that is not in pixels (a percentage) is not read as a cap.
  window.PhoenixKitHooks.PkFitHeight = {
    mounted() {
      const self = this;
      this._frame = null;
      this._fit = function() {
        if (self._frame !== null) return;
        self._frame = window.requestAnimationFrame(function() {
          self._frame = null;
          self._measure();
        });
      };
      // A scroll inside the element itself (its own list) changes nothing.
      // The target of a scroll can be the document or the window (a
      // synthetic `window.dispatchEvent(new Event("scroll"))`), which are not
      // elements and which `contains` refuses: those are the page's scroll.
      this._onScroll = function(event) {
        const t = event.target;
        if (t && t.nodeType === 1 && self.el.contains(t)) return;
        self._fit();
      };
      this._boundary = this._scroller();
      window.addEventListener("resize", this._fit);
      window.addEventListener("scroll", this._onScroll, { capture: true, passive: true });
      if (window.ResizeObserver) {
        this._observer = new window.ResizeObserver(this._fit);
        this._observer.observe(this.el);
        if (this._boundary) this._observer.observe(this._boundary);
      }
      this._measure();
    },
    updated() { this._measure(); },
    destroyed() {
      window.removeEventListener("resize", this._fit);
      window.removeEventListener("scroll", this._onScroll, { capture: true });
      if (this._observer) this._observer.disconnect();
      if (this._frame !== null) window.cancelAnimationFrame(this._frame);
      this._frame = null;
    },
    // The nearest ancestor that scrolls up and down, or null for the viewport.
    _scroller() {
      let node = this.el.parentElement;
      while (node && node !== document.body) {
        const overflow = window.getComputedStyle(node).overflowY;
        if (overflow === "auto" || overflow === "scroll") return node;
        node = node.parentElement;
      }
      return null;
    },
    _measure() {
      const el = this.el;
      // Hidden: no box, so no top to measure from. Shown later, the observer
      // on the element itself calls this again.
      if (el.getClientRects().length === 0) return;
      const margin = parseInt(el.getAttribute("data-fit-margin"), 10);
      const min = parseInt(el.getAttribute("data-fit-min"), 10);
      // The geometry first, while the overlay is as it is: clearing the
      // inline value below puts it at full height and the next read would
      // lay the page out with that.
      const bottom = this._boundary
        ? Math.min(this._boundary.getBoundingClientRect().top + this._boundary.clientTop + this._boundary.clientHeight, window.innerHeight)
        : window.innerHeight;
      const room = bottom - el.getBoundingClientRect().top - (isNaN(margin) ? 8 : margin);
      // The element's own ceiling, read with ours out of the way.
      el.style.maxHeight = "";
      const style = window.getComputedStyle(el);
      const cap = /px$/.test(style.maxHeight) ? parseFloat(style.maxHeight) : Infinity;
      const fit = Math.max(isNaN(min) ? 160 : min, Math.floor(room));
      // The measured room includes the padding and borders of the overlay.
      const edges = style.boxSizing === "content-box"
        ? parseFloat(style.paddingTop) + parseFloat(style.paddingBottom)
          + parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth)
        : 0;
      el.style.maxHeight = Math.min(cap, Math.max(0, fit - edges)) + "px";
    }
  };

  // PkDialogTrigger — makes a REGION instant-open a kept-in-DOM PkDialog.
  // Attach to a container whose descendants push server events that end in
  // a modal (e.g. a calendar grid where event/date clicks open an editor):
  //
  //   <div phx-hook="PkDialogTrigger" id="grid"
  //        data-dialog="my-modal"
  //        data-trigger=".cal-event, .cal-day-cell">
  //
  // On click it finds the closest [phx-click] ancestor — the SAME element
  // LiveView will hand the event to — and, if that element matches
  // data-trigger, dispatches pk:dialog-show to the dialog so it opens in
  // the same frame while the server round-trip fills the content in.
  // Elements with their own phx-click that don't match (a "+N more" link)
  // correctly don't open the dialog.
  window.PhoenixKitHooks.PkDialogTrigger = {
    mounted() {
      this._onTriggerClick = (e) => {
        var sel = this.el.dataset.trigger;
        var dlg = document.getElementById(this.el.dataset.dialog);
        if (!sel || !dlg) return;
        var clickEl = e.target.closest("[phx-click]");
        if (clickEl && this.el.contains(clickEl) && clickEl.matches(sel)) {
          dlg.dispatchEvent(new CustomEvent("pk:dialog-show"));
        }
      };
      this.el.addEventListener("click", this._onTriggerClick);
    },
    destroyed() {
      this.el.removeEventListener("click", this._onTriggerClick);
    }
  };

  // ---------------------------------------------------------------------------
  // CopyToClipboard Hook
  // ---------------------------------------------------------------------------
  //
  // Mount on a button. The button must have `data-copy-target` pointing
  // at a CSS selector for the element whose value should be copied
  // (typically a sibling `<input>`). Optional: an inner element with
  // `data-copy-feedback` whose `hidden` class is toggled briefly to
  // show "Copied!" feedback, and an inner element with `data-copy-idle`
  // whose `hidden` class is the inverse so only one shows at a time.
  //
  // Usage in LiveView template:
  //   <button phx-hook="CopyToClipboard"
  //           id="copy-foo"
  //           data-copy-target="#field-foo"
  //           type="button">
  //     <span data-copy-idle>Copy</span>
  //     <span data-copy-feedback class="hidden">Copied!</span>
  //   </button>
  //
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.CopyToClipboard = {
    mounted() {
      const targetSelector = this.el.getAttribute("data-copy-target");
      if (!targetSelector) return;

      this.handler = async (e) => {
        e.preventDefault();
        const target = document.querySelector(targetSelector);
        if (!target) return;
        const value = target.value !== undefined ? target.value : target.textContent;
        if (!value) return;

        try {
          await navigator.clipboard.writeText(value);
        } catch (_err) {
          // Fallback for older browsers or insecure contexts: select the
          // input and execCommand("copy"). Best-effort; if both paths
          // fail we just bail without feedback.
          if (target.select) {
            const masked = target.type === "password";
            if (masked) target.type = "text";
            target.select();
            try { document.execCommand("copy"); } catch (_) {}
            if (masked) target.type = "password";
            window.getSelection && window.getSelection().removeAllRanges();
          }
        }

        const idle = this.el.querySelector("[data-copy-idle]");
        const feedback = this.el.querySelector("[data-copy-feedback]");
        if (idle) idle.classList.add("hidden");
        if (feedback) feedback.classList.remove("hidden");

        clearTimeout(this.feedbackTimer);
        this.feedbackTimer = setTimeout(() => {
          if (idle) idle.classList.remove("hidden");
          if (feedback) feedback.classList.add("hidden");
        }, 1500);
      };

      this.el.addEventListener("click", this.handler);
    },
    destroyed() {
      clearTimeout(this.feedbackTimer);
      if (this.handler) {
        this.el.removeEventListener("click", this.handler);
      }
    }
  };


  // ---------------------------------------------------------------------------
  // TimeAgo Hook
  // ---------------------------------------------------------------------------
  //
  // Displays relative time (e.g., "5m ago") and updates automatically.
  // Uses variable update intervals for efficiency:
  //   - < 1 minute: updates every second
  //   - < 1 hour: updates every 30 seconds
  //   - < 1 day: updates every 5 minutes
  //   - > 1 day: updates every hour
  //
  // Usage in LiveView template:
  //   <span phx-hook="TimeAgo" data-datetime={DateTime.to_iso8601(timestamp)}></span>
  //
  // Core's `time_ago` component no longer uses this hook: the hook writes its
  // text in English only, so on a translated page it replaced the server's
  // translated text once the page went live. The component is now rendered by
  // the server alone, in the user's language. The hook stays for hosts that
  // put `phx-hook="TimeAgo"` on their own markup.
  //
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.TimeAgo = {
    mounted() {
      const timestamp = this.el.getAttribute("data-datetime");
      if (!timestamp) return;

      const parsed = new Date(timestamp);
      if (isNaN(parsed.getTime())) {
        console.warn("[PhoenixKit:TimeAgo] Invalid timestamp", timestamp);
        return;
      }

      this.timestamp = timestamp;
      this.parsedTime = parsed.getTime();
      this.update();
      this.scheduleUpdate();
    },

    destroyed() {
      this.clearTimer();
    },

    disconnected() {
      this.clearTimer();
    },

    reconnected() {
      if (this.timestamp) {
        this.update();
        this.scheduleUpdate();
      }
    },

    updated() {
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

      if (seconds < 60) return 1000;        // Update every second
      if (seconds < 3600) return 30000;     // Update every 30 seconds
      if (seconds < 86400) return 300000;   // Update every 5 minutes
      return 3600000;                        // Update every hour
    }
  };

  // ---------------------------------------------------------------------------
  // LanguageSwitcherSearch Hook
  // ---------------------------------------------------------------------------
  //
  // Provides client-side search filtering for the language switcher dropdown.
  // Filters languages by name as the user types, without server round-trips.
  //
  // Usage in LiveView template:
  //   <input phx-hook="LanguageSwitcherSearch" id="language-search-input" />
  //
  // The language items should have data-name and optionally data-native attributes:
  //   <li class="language-item" data-name="english" data-native="english">...</li>
  //
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.LanguageSwitcherSearch = {
    mounted() {
      this.el.addEventListener("input", (e) => {
        const searchTerm = e.target.value.toLowerCase().trim();
        const container = this.el.closest(".dropdown-content") || this.el.closest(".dropdown");
        if (!container) return;

        const items = container.querySelectorAll(".language-item");

        items.forEach(item => {
          const name = (item.dataset.name || "").toLowerCase();
          const native = (item.dataset.native || "").toLowerCase();

          // Show if search term is found in name or native name
          const matches = searchTerm === "" ||
                          name.includes(searchTerm) ||
                          native.includes(searchTerm);

          item.style.display = matches ? "" : "none";
        });
      });

      // Clear search when dropdown closes
      this.el.addEventListener("blur", () => {
        // Small delay to allow click events to fire first
        setTimeout(() => {
          this.el.value = "";
          const container = this.el.closest(".dropdown-content") || this.el.closest(".dropdown");
          if (container) {
            container.querySelectorAll(".language-item").forEach(item => {
              item.style.display = "";
            });
          }
        }, 200);
      });
    }
  };

  // ---------------------------------------------------------------------------
  // LanguageSwitcherPosition Hook
  // ---------------------------------------------------------------------------
  //
  // Automatically positions the language switcher dropdown above or below
  // based on available viewport space. Opens downward by default, switches
  // to upward when there's not enough space below.
  //
  // Usage in LiveView template:
  //   <details class="dropdown" phx-hook="LanguageSwitcherPosition">
  //     <summary>...</summary>
  //     <div class="dropdown-content">...</div>
  //   </details>
  //
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.LanguageSwitcherPosition = {
    mounted() {
      this.el.addEventListener("toggle", (e) => {
        if (e.target.open) {
          const rect = this.el.getBoundingClientRect();
          const dropdownContent = this.el.querySelector(".dropdown-content");
          if (!dropdownContent) return;

          // Get actual or estimated content height
          const contentHeight = dropdownContent.offsetHeight || 300;
          const spaceBelow = window.innerHeight - rect.bottom;
          const spaceAbove = rect.top;

          // Remove existing position classes
          this.el.classList.remove("dropdown-top", "dropdown-bottom");

          // Add appropriate position class based on available space
          if (spaceBelow < contentHeight && spaceAbove > spaceBelow) {
            this.el.classList.add("dropdown-top");
          } else {
            this.el.classList.add("dropdown-bottom");
          }
        }
      });
    }
  };

  // ---------------------------------------------------------------------------
  // ViewportPopover Hook
  // ---------------------------------------------------------------------------
  //
  // Keeps an absolutely-positioned popover (one that drops from the bottom of
  // its anchor wrapper) inside the viewport. Clamps its max-height to the space
  // left below the anchor, and flips it to open upward when there's little room
  // below and more above. Without this, a tall editor opened low in the page
  // (e.g. an embedded media browser scrolled down) runs off the bottom of the
  // screen, leaving its footer buttons (Save) unreachable.
  //
  // Inline styles override the element's max-h / top classes; the server sets
  // no style attribute on the element, so morphdom won't clobber them on
  // re-render. Re-runs on mount, update, resize and scroll.
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.ViewportPopover = {
    mounted() {
      this._reposition = this.position.bind(this);
      window.addEventListener("resize", this._reposition);
      window.addEventListener("scroll", this._reposition, true);
      this.position();
    },
    updated() {
      this.position();
    },
    destroyed() {
      window.removeEventListener("resize", this._reposition);
      window.removeEventListener("scroll", this._reposition, true);
    },
    position() {
      var el = this.el;
      var margin = 12;
      var anchor = el.parentElement || el;
      var ar = anchor.getBoundingClientRect();
      var spaceBelow = window.innerHeight - ar.bottom - margin;
      var spaceAbove = ar.top - margin;
      var cap = Math.round(window.innerHeight * 0.85);

      if (spaceBelow < 220 && spaceAbove > spaceBelow) {
        // More room above: flip the popover to open upward.
        el.style.top = "auto";
        el.style.bottom = "100%";
        el.style.marginTop = "0px";
        el.style.marginBottom = "0.5rem";
        el.style.maxHeight = Math.max(140, Math.min(spaceAbove, cap)) + "px";
      } else {
        el.style.bottom = "auto";
        el.style.top = "100%";
        el.style.marginBottom = "0px";
        el.style.marginTop = "0.5rem";
        el.style.maxHeight = Math.max(140, Math.min(spaceBelow, cap)) + "px";
      }
    }
  };

  // ---------------------------------------------------------------------------
  // FadeOut Hook
  // ---------------------------------------------------------------------------
  //
  // Handles smooth fade-out animations by listening for CSS animationend event
  // before notifying the server to remove the element. This prevents the race
  // condition where LiveView removes the element before the animation completes.
  //
  // Usage in LiveView template:
  //   <div id="progress-bar"
  //        phx-hook="FadeOut"
  //        data-status={@status}
  //        data-fade-event="animation_finished"
  //        class={@status == :completed && "animate-fade-out"}>
  //     ...content...
  //   </div>
  //
  // Handle in LiveView:
  //   def handle_event("animation_finished", %{"id" => id}, socket)
  //
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.FadeOut = {
    mounted() {
      this.handleStatusChange();
    },
    updated() {
      this.handleStatusChange();
    },
    handleStatusChange() {
      const status = this.el.dataset.status;
      const eventName = this.el.dataset.fadeEvent || "animation_finished";

      if (status === "completed" || status === "exiting") {
        // Add the fade-out class if not already present
        if (!this.el.classList.contains("animate-fade-out")) {
          this.el.classList.add("animate-fade-out");
        }

        // Remove any existing listener to avoid duplicates
        if (this._animationHandler) {
          this.el.removeEventListener("animationend", this._animationHandler);
        }

        // Listen for animation to complete, then notify server
        this._animationHandler = () => {
          this.pushEvent(eventName, { id: this.el.id });
        };
        this.el.addEventListener("animationend", this._animationHandler, { once: true });
      }
    },
    destroyed() {
      if (this._animationHandler) {
        this.el.removeEventListener("animationend", this._animationHandler);
      }
    }
  };

  // ---------------------------------------------------------------------------
  // PreserveScroll Hook
  // ---------------------------------------------------------------------------
  //
  // Preserves scroll position during LiveView updates. Useful for pages with
  // toggles or interactive elements that trigger re-renders.
  //
  // Usage in LiveView template:
  //   <div id="content" phx-hook="PreserveScroll">
  //     ...content with toggles...
  //   </div>
  //
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.PreserveScroll = {
    mounted() {
      this.scrollPosition = 0;
      this.openDetails = [];
    },
    beforeUpdate() {
      // Save scroll position
      this.scrollPosition = window.scrollY;

      // Save which details elements are open (by their index or id)
      this.openDetails = [];
      this.el.querySelectorAll("details").forEach((detail, index) => {
        if (detail.open) {
          // Use id if available, otherwise use index
          this.openDetails.push(detail.id || "idx-" + index);
        }
      });
    },
    updated() {
      // Restore scroll position
      window.scrollTo(0, this.scrollPosition);

      // Restore open state of details elements
      this.el.querySelectorAll("details").forEach((detail, index) => {
        const identifier = detail.id || "idx-" + index;
        if (this.openDetails.includes(identifier)) {
          detail.open = true;
        }
      });
    }
  };


  // ---------------------------------------------------------------------------
  // InfiniteScroll — fires a "load more" LV event when the sentinel scrolls
  // into view. Pair with the core `<.load_more infinite>` component, which
  // renders this hook plus a manual fallback button. The event name is read
  // from `data-load-more-event` (default "load_more").
  //
  // `data-cursor` is an opaque per-page marker that changes whenever a new
  // page lands. `updated()` only re-fires when it actually changes — so an
  // unrelated LV diff that happens to touch the sentinel (flash, PubSub row
  // update, sibling assign) won't spuriously trigger another load. A single
  // in-flight guard (`loading`) prevents stacking multiple pushes before the
  // server responds; the cursor change clears it on the happy path.
  //
  // The guard also has a timeout watchdog: if a load resolves WITHOUT
  // advancing the cursor (an empty/no-op page, a stale `total`, or a
  // replace-in-place list where `loaded` stays constant), the cursor-change
  // path never clears the guard. The watchdog releases it after a short
  // window so auto-load can never wedge permanently — worst case is a brief
  // stall, after which the next scroll (or the manual button) recovers.
  // ---------------------------------------------------------------------------

  window.PhoenixKitHooks.InfiniteScroll = {
    loadMoreEvent() {
      return this.el.dataset.loadMoreEvent || "load_more";
    },
    clearGuard() {
      this.loading = false;
      clearTimeout(this.loadTimer);
    },
    maybeLoad() {
      if (this.loading) return;
      this.loading = true;
      // Route to the LiveComponent that OWNS the sentinel — the old
      // pushEvent always hit the LV and made the sentinel useless inside
      // components (2026-08-31). See `pushToOwner`.
      pushToOwner(this, this.el, this.loadMoreEvent(), {});
      // Watchdog: release the guard even if the cursor never advances, so a
      // no-op load can't wedge the sentinel. The cursor-change path in
      // updated() clears it sooner on the normal (page-grew) path.
      clearTimeout(this.loadTimer);
      this.loadTimer = setTimeout(() => { this.loading = false; }, 2000);
    },
    mounted() {
      this.intersecting = false;
      this.loading = false;
      this.lastCursor = this.el.dataset.cursor;
      this.observer = new IntersectionObserver(
        (entries) => {
          this.intersecting = entries[0].isIntersecting;
          if (this.intersecting) {
            this.maybeLoad();
          }
        },
        { rootMargin: "200px" }
      );
      this.observer.observe(this.el);
    },
    updated() {
      // Only react to a genuinely new page (cursor changed), not to every
      // diff that happens to touch this element. The cursor change also means
      // the previous load resolved, so clear the in-flight guard.
      if (this.el.dataset.cursor !== this.lastCursor) {
        this.lastCursor = this.el.dataset.cursor;
        this.clearGuard();
        if (this.intersecting) {
          this.maybeLoad();
        }
      }
    },
    destroyed() {
      clearTimeout(this.loadTimer);
      if (this.observer) this.observer.disconnect();
    }
  };


  // ---------------------------------------------------------------------------
  // PageSizeAutoFit — the "Auto" option of `<.page_size_selector auto_fit>`.
  // Measures how many rows of the table named in `data-table-id` fit between
  // the table's top edge and the bottom of the viewport (minus room for the
  // pagination bar) and pushes `data-event` with the LARGEST option from
  // `data-options` that fits — so the value always lands inside the LV's
  // allowlist and the page never needs a scrollbar just for the table.
  // Active only while `data-auto="true"`; re-measures on resize (debounced)
  // and after every LV diff, but pushes only when the answer changed, so a
  // steady viewport costs nothing.
  // ---------------------------------------------------------------------------

  // Pure: the option that fits `rows` rows, clamped into the option range.
  function fitPageSize(available, rowHeight, options) {
    const sorted = options.map(Number).filter((n) => n > 0).sort((a, b) => a - b);
    if (sorted.length === 0) return null;
    if (!(rowHeight > 0)) return sorted[0];
    const rows = Math.floor(available / rowHeight);
    let fit = sorted[0];
    for (const n of sorted) if (n <= rows) fit = n;
    return fit;
  }

  window.PhoenixKitHooks.PageSizeAutoFit = {
    active() {
      return this.el.dataset.auto === "true";
    },
    measure() {
      if (!this.active()) return;
      const table = document.getElementById(this.el.dataset.tableId);
      const row = table && table.querySelector("tbody tr");
      if (!table || !row) return;
      const reserve = 96; // pagination bar + breathing room below the table
      const available = window.innerHeight - table.getBoundingClientRect().top - reserve;
      const options = (this.el.dataset.options || "").split(",");
      const size = fitPageSize(available, row.getBoundingClientRect().height, options);
      if (size === null || String(size) === this.lastPushed) return;
      this.lastPushed = String(size);
      pushToOwner(this, this.el, this.el.dataset.event || "change_per_page", {
        per_page: String(size),
        auto: "1"
      });
    },
    mounted() {
      this.lastPushed = null;
      this.onResize = () => {
        clearTimeout(this.resizeTimer);
        this.resizeTimer = setTimeout(() => this.measure(), 250);
      };
      window.addEventListener("resize", this.onResize);
      this.measure();
    },
    updated() {
      // A number picked by hand switches auto off: forget the last push so
      // re-enabling Auto measures afresh instead of assuming nothing moved.
      if (!this.active()) this.lastPushed = null;
      this.measure();
    },
    destroyed() {
      clearTimeout(this.resizeTimer);
      window.removeEventListener("resize", this.onResize);
    }
  };

  if (typeof module === "object" && module.exports) {
    module.exports.fitPageSize = fitPageSize;
  }


  // ============================================================================
  // 4. FLASH AUTO-DISMISS HOOK
  // ============================================================================

  window.PhoenixKitHooks.FlashAutoDismiss = {
    mounted() {
      this.duration = parseInt(this.el.dataset.dismissAfter || "5000");
      this.lastMessage = this.el.dataset.flashMessage;
      this.startTimer();

      this.el.addEventListener("mouseenter", () => this.pauseTimer());
      this.el.addEventListener("mouseleave", () => this.resumeTimer());
    },
    // A same-kind flash id (e.g. "flash-info") is a stable id — a second
    // flash of the same kind gets morphdom-patched into the SAME node
    // rather than mounted fresh, so without this the original mounted()
    // timer (already consumed, or already mid-flight) is all this message
    // ever gets: on a page like Organization settings where one save
    // after another keeps landing an :info flash, the second message can
    // sit un-timed indefinitely, or inherit a prior dismiss()'s
    // opacity:0/display:none and never even become visible. Reset both
    // the timer and whatever dismiss() left behind, every patch.
    //
    // But `@flash` is ONE Phoenix assign covering all three kinds — putting
    // or clearing a DIFFERENT kind marks the whole assign dirty and
    // re-diffs THIS node too, even though its own message never changed.
    // Unconditionally restarting here meant a flash on a page where
    // anything else touched flash state could never count down to zero.
    // `data-flash-message` fingerprints the actual text, so the timer only
    // restarts for a genuinely new message.
    updated() {
      var message = this.el.dataset.flashMessage;
      if (message === this.lastMessage) return;
      this.lastMessage = message;

      clearTimeout(this.timer);
      this.el.style.transition = "";
      this.el.style.opacity = "";
      this.el.style.transform = "";
      this.el.style.display = "";
      this.duration = parseInt(this.el.dataset.dismissAfter || "5000");
      this.startTimer();
    },
    startTimer() {
      this.remaining = this.duration;
      this.startTime = Date.now();
      var bar = this.el.querySelector("[data-flash-progress]");
      if (bar) {
        bar.style.transition = "width " + this.duration + "ms linear";
        requestAnimationFrame(function() {
          bar.style.width = "0%";
        });
      }
      var self = this;
      this.timer = setTimeout(function() { self.dismiss(); }, this.duration);
    },
    pauseTimer() {
      clearTimeout(this.timer);
      this.elapsed = Date.now() - this.startTime;
      this.remaining = this.remaining - this.elapsed;
      var bar = this.el.querySelector("[data-flash-progress]");
      if (bar) {
        var computedWidth = getComputedStyle(bar).width;
        var parentWidth = bar.parentElement ? bar.parentElement.offsetWidth : 1;
        var widthPx = parseFloat(computedWidth);
        bar.style.transition = "none";
        bar.style.width = (widthPx / parentWidth * 100) + "%";
      }
    },
    resumeTimer() {
      this.startTime = Date.now();
      var bar = this.el.querySelector("[data-flash-progress]");
      if (bar) {
        bar.style.transition = "width " + this.remaining + "ms linear";
        requestAnimationFrame(function() {
          bar.style.width = "0%";
        });
      }
      var self = this;
      this.timer = setTimeout(function() { self.dismiss(); }, this.remaining);
    },
    dismiss() {
      this.pushEvent("lv:clear-flash", {key: this.el.dataset.flashKind});
      this.el.style.transition = "opacity 200ms ease-out, transform 200ms ease-out";
      this.el.style.opacity = "0";
      this.el.style.transform = "translateX(0.5rem)";
      var el = this.el;
      setTimeout(function() {
        if (el) el.style.display = "none";
      }, 200);
    },
    destroyed() {
      clearTimeout(this.timer);
    }
  };


  // ============================================================================
  // LEAF EDITOR (vendored, loaded on demand)
  //
  // Loads Leaf's editor JS when the hook mounts, so a page with no editor on
  // it pays nothing. The file is the host's own copy of the INSTALLED :leaf
  // dependency (PhoenixKit.Install.ViewerLibraries), so the browser half can
  // no longer drift from the server half: there is no tag to keep in step.
  // ============================================================================

  (function() {

    function loadLeaf() {
      return loadVendored("Leaf", "leaf", {
        check: function() { return !!(window.LeafHooks && window.LeafHooks.Leaf); }
      });
    }

    // Wrapper hook that lazy-loads Leaf JS then becomes the real hook.
    window.PhoenixKitHooks.Leaf = lazyHook(loadLeaf, function() {
      return window.LeafHooks && window.LeafHooks.Leaf;
    });
  })();


  // ============================================================================
  // FRESCO (vendored, loaded on demand)
  //
  // Loads Fresco when one of its hooks mounts. The single fresco.js exports
  // all three component hooks; PhoenixKit wraps the two it uses
  // (`FrescoViewer` for plain images, `FrescoCanvas` for the annotation
  // host), so one load covers both. A host that pre-imports Fresco in its own
  // app.js short-circuits the load entirely. The file is the host's copy of
  // the installed :fresco dependency (PhoenixKit.Install.ViewerLibraries).
  // ============================================================================

  (function() {

    // Usable means the engine (window.Fresco — what Tessera and Etcher
    // attach through) AND the hooks are there, pre-imported or loaded.
    function loadFresco() {
      return loadVendored("Fresco", "fresco", {
        check: function() {
          return !!(window.Fresco && window.FrescoHooks && window.FrescoHooks.FrescoViewer);
        }
      });
    }
    pkLoaders.fresco = loadFresco;

    window.PhoenixKitHooks.FrescoViewer = lazyHook(loadFresco, function() {
      return window.FrescoHooks && window.FrescoHooks.FrescoViewer;
    });

    // FrescoCanvas — the layered scene component MediaBrowser uses to
    // host annotations (Etcher). Both hooks come out of the same fresco.js
    // bundle, so a single fetch covers either / both.
    window.PhoenixKitHooks.FrescoCanvas = lazyHook(loadFresco, function() {
      return window.FrescoHooks && window.FrescoHooks.FrescoCanvas;
    });
  })();


  // ============================================================================
  // TESSERA LAYER (vendored, loaded on demand)
  //
  // Tessera's progressive-resolution + DZI deep-zoom layer. Attaches to a
  // Fresco viewer via `fresco_id`, so it loads only after Fresco has (below).
  // Same pre-import short-circuit; the file is the host's copy of the
  // installed :tessera dependency.
  // ============================================================================

  (function() {

    // Chained through Fresco: Tessera's mounted gives up when window.Fresco
    // is absent, and two async script loads finish in either order — a fast
    // Tessera beside a slow Fresco silently lost the sharper rungs.
    function loadTessera() {
      return pkLoaders.fresco().then(function() {
        return loadVendored("Tessera", "tessera", {
          check: function() { return !!(window.TesseraHooks && window.TesseraHooks.TesseraLayer); }
        });
      });
    }

    pkLoaders.tessera = loadTessera;

    window.PhoenixKitHooks.TesseraLayer = lazyHook(loadTessera, function() {
      return window.TesseraHooks && window.TesseraHooks.TesseraLayer;
    });
  })();


  // ============================================================================
  // ETCHER LAYER (vendored, loaded on demand)
  //
  // Etcher's annotation layer: attaches to a Fresco viewer/canvas via
  // `fresco_id` and adds the pencil toolbar, draw tools and shape
  // persistence. Same pre-import short-circuit; the file is the host's copy
  // of the installed :etcher dependency, so a toolbar hook the server is
  // wired for can no longer be missing from a stale CDN copy.
  // ============================================================================

  (function() {

    // Etcher's Customise dialog loads SortableJS itself. Point it at this
    // host's copy and turn its built-in CDN load off — in every mode, so a
    // failed local copy falls back to native drag-and-drop, never to
    // jsDelivr (Etcher >= 0.20; the `sortableUrl` is authoritative). A host
    // that opted into a CDN fallback gets it from the shared loader instead,
    // which supplies window.Sortable (Etcher prefers it) before Etcher mounts.
    // The settings themselves. A host that set its own wins. Also applied
    // once the page has parsed (below): a host that pre-imports Etcher in
    // its own app.js replaces this wrapper hook entirely, and would
    // otherwise keep Etcher's CDN load. Etcher reads both lazily and keeps
    // an existing window.Etcher when it loads, so either order works.
    function applyEtcherSortableSettings() {
      window.Etcher = window.Etcher || {};
      var urls = pkLibUrls("sortable");
      if (urls && window.Etcher.sortableUrl === undefined) window.Etcher.sortableUrl = urls.local;
      if (window.Etcher.loadSortableFromCdn === undefined) window.Etcher.loadSortableFromCdn = false;
      return urls;
    }
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", applyEtcherSortableSettings);
    } else {
      setTimeout(applyEtcherSortableSettings, 0);
    }

    function configureEtcherSortable() {
      var urls = applyEtcherSortableSettings();
      if (urls && urls.cdn) {
        return loadVendored("SortableJS", "sortable", {
          check: function() { return typeof window.Sortable === "function"; }
        }).catch(function() { /* reported; the dialog reorders natively */ });
      }
      return Promise.resolve();
    }

    // Chained through Fresco for the same reason as Tessera: Etcher attaches
    // through window.Fresco.onReady and gives up when it is absent.
    function loadEtcher() {
      return pkLoaders.fresco().then(function() {
        var sortable = configureEtcherSortable();
        var etcher = loadVendored("Etcher", "etcher", {
          check: function() { return !!(window.EtcherHooks && window.EtcherHooks.EtcherLayer); }
        });
        return Promise.all([etcher, sortable]);
      });
    }

    window.PhoenixKitHooks.EtcherLayer = lazyHook(loadEtcher, function() {
      return window.EtcherHooks && window.EtcherHooks.EtcherLayer;
    });

    // A page answered by Etcher's offline service worker (`PhoenixKit.Offline`;
    // the worker marks it with this meta tag) has no server behind it: the
    // LiveView never joins, so no hook mounts and nothing above would ever
    // load the viewer. Etcher starts the canvas itself from this device's copy
    // — once it is here, so load it, and Tessera for the zoom ladder.
    function loadForOfflineCopy() {
      if (!document.querySelector('meta[name="etcher-offline-copy"]')) return;
      loadEtcher().catch(function() { /* reported by the loader */ });
      if (pkLoaders.tessera) pkLoaders.tessera().catch(function() { /* reported by the loader */ });
    }
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", loadForOfflineCopy);
    } else {
      setTimeout(loadForOfflineCopy, 0);
    }
  })();

  // ============================================================================
  // MAINTENANCE COUNTDOWN HOOK
  // ============================================================================
  // Powers the "Expected back in Xh Ym Zs" countdown on the maintenance page.
  // Reads the scheduled end time from data-end (ISO 8601), updates #countdown-value
  // every second, and shows the value from data-elapsed-text (translatable) when
  // the countdown reaches zero.

  window.PhoenixKitHooks.MaintenanceCountdown = {
    mounted() {
      this.endTime = new Date(this.el.dataset.end).getTime();
      this.timerEl = this.el.querySelector("#countdown-value");
      this.elapsedText = this.el.dataset.elapsedText || "";
      this.tick();
      this.interval = setInterval(() => this.tick(), 1000);
    },
    tick() {
      var diff = Math.max(0, Math.floor((this.endTime - Date.now()) / 1000));
      if (diff <= 0) {
        clearInterval(this.interval);
        if (this.timerEl) this.timerEl.textContent = this.elapsedText;
        return;
      }
      var h = Math.floor(diff / 3600);
      var m = Math.floor((diff % 3600) / 60);
      var s = diff % 60;
      var text = "";
      if (h > 0) text += h + "h ";
      if (h > 0 || m > 0) text += m + "m ";
      text += s + "s";
      if (this.timerEl) this.timerEl.textContent = text;
    },
    destroyed() {
      if (this.interval) clearInterval(this.interval);
    }
  };

  // ============================================================================
  // Etcher tooltip — comment-flavored slot overrides
  // ============================================================================
  //
  // Etcher exposes `window.Etcher.tooltipSlots` (header / body / footer)
  // for downstream consumers to customize its hover tooltip. PhoenixKit's
  // MediaBrowser flows comment-thread metadata through `metadata.comment_*`
  // keys; the three slots below translate those into the rich tooltip
  // (author header, date · count subheader, thumbnail + quoted text body)
  // that's been the PhoenixKit out-of-the-box look.
  //
  // PhoenixKit owns the tooltip layout — this assignment overwrites
  // whatever was on `window.Etcher.tooltipSlots`. Load order: when
  // phoenix_kit.js runs before etcher.js, Etcher's bootstrap honors the
  // pre-set slots (it uses `||` against defaults); when phoenix_kit.js
  // runs after, this assignment takes effect immediately. If a downstream
  // consumer wants to override these, their script must load AFTER
  // phoenix_kit.js. If Etcher never loads the only cost is a few dormant
  // fields on `window.Etcher`.
  //
  // The `comment_*` key naming is PhoenixKit's internal contract with
  // itself — Etcher knows nothing about them.

  window.Etcher = window.Etcher || {};

  var pkEscape = function(v) {
    return String(v == null ? "" : v)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  };

  // Paperclip icon used as the body-slot's attachment fallback when a
  // comment has media but no preview-able image (PDFs, audio, zips,
  // broken-image URLs).
  var pkPaperclip =
    '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"' +
    ' stroke-width="1.5" stroke="currentColor" aria-hidden="true">' +
    '<path stroke-linecap="round" stroke-linejoin="round"' +
    ' d="m18.375 12.739-7.693 7.693a4.5 4.5 0 0 1-6.364-6.364l10.94-10.94A3 3 0 1 1 19.5 7.372L8.552 18.32m.009-.01-.01.01m5.699-9.941-7.81 7.81a1.5 1.5 0 0 0 2.112 2.13"/>' +
    "</svg>";

  function pkCapitalize(s) {
    if (!s) return "";
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  // ============================================================================
  // Etcher live-metadata patch bridge
  // ============================================================================
  //
  // Listens for the `etcher:patch-shape` LiveView push_event emitted by
  // MediaBrowser when annotation comments are posted server-side. Calls
  // Etcher's `layerFor(fresco_id).patchShape(uuid, {metadata})` (added
  // in Etcher 0.3) so the in-DOM shape's metadata reflects the new
  // comment_* fields immediately — the tooltip shows the rich content
  // on the next hover without waiting for a layer remount.
  //
  // Why this bridge exists: <Fresco.canvas> uses `phx-update="ignore"`,
  // which freezes its `data-extensions` attribute at initial mount.
  // Server-side rebuilds of the canvas's `extensions.etcher` blob
  // don't reach the DOM, so Etcher's `handle.getExtension("etcher")`
  // keeps returning the old annotations. patchShape sidesteps that by
  // mutating Etcher's internal `self.shapes[i]` directly.
  window.addEventListener("phx:etcher:patch-shape", function(e) {
    var detail = e && e.detail;
    if (!detail || !detail.fresco_id || !detail.uuid) return;
    var layer = window.Etcher && window.Etcher.layerFor &&
                window.Etcher.layerFor(detail.fresco_id);
    if (!layer || typeof layer.patchShape !== "function") return;
    var fields = {};
    if (detail.metadata) fields.metadata = detail.metadata;
    if (detail.style) fields.style = detail.style;
    layer.patchShape(detail.uuid, fields);
  });

  // Server-driven shape removal. MediaBrowser uses this on annotation
  // composer Cancel — the user signalled the just-drawn shape was a
  // mistake, so we drop it from Etcher's local state instead of
  // leaving an untitled placeholder on the canvas. layer.deleteShape
  // pushes the deletion onto Etcher's undo stack (Cmd+Z restores) and
  // fires `etcher:annotations-changed`, which routes through the
  // server's sync_annotations to delete the DB row + cascade comments.
  window.addEventListener("phx:etcher:delete-shape", function(e) {
    var detail = e && e.detail;
    if (!detail || !detail.fresco_id || !detail.uuid) return;
    var layer = window.Etcher && window.Etcher.layerFor &&
                window.Etcher.layerFor(detail.fresco_id);
    if (!layer || typeof layer.deleteShape !== "function") return;
    layer.deleteShape(detail.uuid);
  });

  // Deep-link shape selection. A comment's "file" resource link (e.g. from the
  // comments moderation admin) can carry `?annotation=<uuid>`; MediaDetail
  // pushes `etcher:select-shape` so the shape is pinned (selected) as if the
  // user clicked it. The Etcher layer mounts asynchronously after the canvas
  // hook initializes, so retry until the layer + shape exist (give up after
  // ~6s). selectShape no-ops on readonly shapes.
  window.addEventListener("phx:etcher:select-shape", function(e) {
    var detail = e && e.detail;
    if (!detail || !detail.fresco_id || !detail.uuid) return;
    var attempts = 0;
    (function trySelect() {
      var layer = window.Etcher && window.Etcher.layerFor &&
                  window.Etcher.layerFor(detail.fresco_id);
      if (layer && typeof layer.selectShape === "function" &&
          typeof layer.getShape === "function" && layer.getShape(detail.uuid)) {
        layer.selectShape(detail.uuid);
        return;
      }
      if (attempts++ < 60) setTimeout(trySelect, 100);
    })();
  });

  window.Etcher.tooltipSlots = {
    // Header → annotation title (user-chosen label) if present;
    // otherwise the first comment's author (preview), then a marker's
    // stored byline; otherwise the shape kind.
    header: function(shape) {
      var m = shape.metadata || {};
      return pkEscape(m.title || m.comment_preview_author || m.comment_author || pkCapitalize(shape.kind));
    },

    // Footer → "May 12, 2026 · 3 comments". Date and count are both
    // optional; if neither is set the row is omitted entirely. (The
    // Reply / Edit / View actions are HEADER buttons — see
    // `window.Etcher.tooltipActions` below.)
    footer: function(shape) {
      var m = shape.metadata || {};
      var parts = [];
      if (m.comment_created_at) parts.push(pkEscape(m.comment_created_at));
      var count = m.comment_count || 0;
      if (count > 0) {
        parts.push(count + " " + (count === 1 ? "comment" : "comments"));
      }
      return parts.length ? parts.join(" · ") : null;
    },

    // Body → optional thumbnail (image or paperclip) + truncated
    // quoted text. Uses Etcher's opt-in styling primitives
    // (`.etcher-tooltip-body`, `.etcher-tooltip-thumb`,
    // `.etcher-tooltip-text`, `.etcher-tooltip-quote`).
    body: function(shape) {
      var m = shape.metadata || {};
      var text = m.comment_text || null;
      var thumb = m.comment_thumbnail_url || null;
      var hasAttachment = m.comment_has_attachment === true;

      if (!text && !thumb && !hasAttachment) return null;

      var html = '<div class="etcher-tooltip-body">';
      if (thumb) {
        html +=
          '<img class="etcher-tooltip-thumb" src="' + pkEscape(thumb) + '" alt="">';
      } else if (hasAttachment) {
        html +=
          '<span class="etcher-tooltip-thumb etcher-tooltip-thumb-icon">' +
          pkPaperclip +
          "</span>";
      }
      html += '<div class="etcher-tooltip-text">';
      if (text) {
        html += '<div class="etcher-tooltip-quote">' + pkEscape(text) + "</div>";
      }
      html += "</div></div>";
      return html;
    }
  };

  // ==========================================================================
  // Etcher tooltip header actions — Reply / Edit / View
  // ==========================================================================
  //
  // Real buttons on the tooltip's header row, next to Etcher's trash
  // (Etcher 0.13's `window.Etcher.tooltipActions`). Only on surfaces that
  // hydrate PhoenixKit's comment contract (`comment_count` present — the
  // media viewer, or `comments_off` — the same viewer with the discussion
  // switched off, which keeps Edit and drops Reply / View); boards shapes
  // carry no comment metadata and keep the plain tooltip. Clicks re-dispatch
  // as `etcher:tooltip-action`, routed by the EtcherTooltipActions hook below:
  //   Reply — anyone, any persisted shape: opens the discussion flow.
  //   Edit  — non-readonly shapes: Etcher's inline label editor.
  //   View  — only when discussion exists: scrolls the sidebar to the
  //           shape's comment thread and flashes it.
  var pkTooltipIcons = {
    reply:
      '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"' +
      ' stroke-width="1.8" stroke="currentColor" aria-hidden="true">' +
      '<path stroke-linecap="round" stroke-linejoin="round"' +
      ' d="M2.25 12.76c0 1.6 1.123 2.994 2.707 3.227 1.068.157 2.148.279 3.238.364.466.037.893.281 1.153.671L12 20.25l2.652-3.978c.26-.39.687-.634 1.153-.67 1.09-.086 2.17-.208 3.238-.365 1.584-.233 2.707-1.626 2.707-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0 0 12 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018Z"/></svg>',
    edit:
      '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"' +
      ' stroke-width="1.8" stroke="currentColor" aria-hidden="true">' +
      '<path stroke-linecap="round" stroke-linejoin="round"' +
      ' d="m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L6.832 19.82a4.5 4.5 0 0 1-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 0 1 1.13-1.897L16.863 4.487Zm0 0L19.5 7.125"/></svg>',
    view:
      '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"' +
      ' stroke-width="1.8" stroke="currentColor" aria-hidden="true">' +
      '<path stroke-linecap="round" stroke-linejoin="round"' +
      ' d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"/>' +
      '<path stroke-linecap="round" stroke-linejoin="round"' +
      ' d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/></svg>'
  };

  window.Etcher.tooltipActions = function(shape) {
    var m = shape.metadata || {};
    // `comments_off`: a viewer with the discussion switched off. The shape
    // still has a label to edit; Reply and View are what goes away.
    var commentsOff = m.comments_off === true;
    if (!shape.uuid || (m.comment_count == null && !commentsOff)) return [];

    var actions = [];
    if (!commentsOff) {
      actions.push({ action: "pk-reply", title: "Reply", icon: pkTooltipIcons.reply });
    }
    if (!shape.readonly) {
      actions.push({ action: "pk-edit", title: "Edit label", icon: pkTooltipIcons.edit });
    }
    if (!commentsOff && (m.comment_count || 0) > 0) {
      actions.push({ action: "pk-view", title: "View discussion", icon: pkTooltipIcons.view });
    }
    return actions;
  };
  // ============================================================================
  // ADMIN HOOKS — the names stay here, the code is in phoenix_kit_admin.js
  // ============================================================================
  //
  // A host spreads `window.PhoenixKitHooks` into LiveSocket once, when it builds
  // it, so every hook has to have its NAME in this object by then. The hooks
  // below belong to the admin area and the user dashboard; a public page never
  // mounts them, so their code is not in this file. Each one is registered as a
  // stub: on its first mount it loads `phoenix_kit_admin.js` (a vendored
  // library — one request however many of these hooks a page has), then takes
  // the real hook's callbacks onto the very hook instance LiveView made, and
  // calls its `mounted`.
  //
  // Correctness does not depend on this list being right — only speed does. A
  // hook missing from it is simply not stubbed, and has to be defined here; a
  // hook listed here that a public page needs costs that page one request.
  // `test/js/admin_split.test.cjs` pins the list to what the admin file
  // defines.
  //
  // A callback that reaches a stubbed hook before the bundle arrives
  // (`updated`, `beforeUpdate`, `disconnected`, `reconnected`) is dropped: the
  // stub has none, and `mounted` reads the DOM as it is when it finally runs. A
  // hook destroyed in that window never mounts.

  var ADMIN_HOOKS = [
    "SortableGrid",
    "MediaImageZoom",
    "MarkdownEditor",
    "ViewerPaneFit",
    "InstantViewer",
    "ViewerKeydown",
    "MediaViewerDialog",
    "PkHashHighlight",
    "BulkSelectScope",
    "TableLocalSearch",
    "AdminSidebarScroll",
    "PkDialogDraft",
    "AnnotationBurn",
    "EtcherTooltipActions",
    "AnnotationComposerPosition",
    "ListFilter",
    "TreePickerSearch",
    "CrumbSwitcher",
    "NavTabsOverflow",
    "TableFit",
    "TableCardView",
    "RowMenu",
    "RowMenuAuto",
    "EmailCharts",
    "IntegrationPickerSearch",
    "MediaDragDrop",
    "EtcherReset",
    "ViewerSwipe",
    "ViewerGallery",
    "ViewerHiresLoading",
    "UploadResume",
    "UploadManager",
    "FolderDropUpload",
    "RemovalModal",
    "StackMemory",
    "StackExpand",
    "WaveformPlayer",
    "SearchPicker",
    "ContextMenu",
    "AvatarCrop",
    "PkPush",
    "ImageEditor"
  ];

  // No cap on attempts, unlike the viewer libraries: the early start and the
  // first mount would otherwise use up the two a library gets, and a page whose
  // admin bundle failed once (a deploy in progress, a network blip) would stay
  // dead until reloaded. Simultaneous mounts share one request. After a failure
  // there is a short pause (ADMIN_RETRY_PAUSE_MS) in which a mount is refused at
  // once, without a request — a page with thirty admin hooks would otherwise
  // ask thirty times, one after another — and the first mount after it asks again.
  //
  // A stub that was refused or whose request failed is not mounted again by
  // LiveView (a hook mounts once per element), and the first mount after the pause
  // may never come on a page the person is reading. So the page keeps such stubs
  // (adminWaiting) and asks for the bundle itself: after the pause, then at doubling
  // intervals up to ADMIN_RETRY_MAX_MS, for as long as one still waits. Whichever
  // request gets the bundle, a retry or the mount of another hook, mounts every
  // stub that waits.
  var ADMIN_RETRY_PAUSE_MS = 4000;
  var ADMIN_RETRY_MAX_MS = 60000;
  var adminRetryAt = 0;
  var adminWaiting = [];
  var adminRetryTimer = null;
  var adminRetryDelay = ADMIN_RETRY_PAUSE_MS;
  // Set when the admin file arrived and threw while running: asking again would run its
  // top-level code a second time (every document listener it installs, twice) and fail the
  // same way, so for the life of the page that is the answer to every mount.
  var adminRanError = null;

  // The request itself: no pause in front of it, because a retry is the pause's end.
  function requestAdminBundle() {
    return loadVendored("PhoenixKit admin", "admin", {
      check: function() { return !!window.PhoenixKitAdminLoaded; },
      unlimitedAttempts: true
    }).catch(function(err) {
      if (err && err.pkRan) adminRanError = err;
      // The pause keeps thirty mounts from making thirty requests; with the facts
      // missing there is no request to keep them from, and the facts file may be
      // only late (a deferred tag), so the next mount must be free to try.
      if (!(err && err.pkNoFacts)) adminRetryAt = Date.now() + ADMIN_RETRY_PAUSE_MS;
      throw err;
    });
  }

  function loadAdminBundle() {
    if (adminRanError) return Promise.reject(adminRanError);
    if (Date.now() < adminRetryAt) {
      return Promise.reject(new Error("the admin bundle failed a moment ago"));
    }
    return requestAdminBundle();
  }

  // The bundle is here: every stub that gave up mounts, and the retry stops.
  function mountWaitingStubs() {
    clearTimeout(adminRetryTimer);
    adminRetryTimer = null;
    adminRetryDelay = ADMIN_RETRY_PAUSE_MS;
    var waiting = adminWaiting;
    adminWaiting = [];
    waiting.forEach(function(stub) { stub.mount(); });
  }

  var ADMIN_RAN_MESSAGE = "The admin bundle was loaded but failed while running (see the error above), so the " +
    "admin hooks stay off until the page is reloaded. Check that phoenix_kit.js and phoenix_kit_admin.js are from " +
    "the same PhoenixKit version: run mix phoenix_kit.update, then mix compile.";

  function scheduleAdminRetry() {
    if (adminRetryTimer !== null) return;
    adminRetryTimer = setTimeout(function() {
      adminRetryTimer = null;
      // A stub destroyed meanwhile (its element is gone) needs nothing.
      adminWaiting = adminWaiting.filter(function(stub) { return !stub.hook.__pkGone; });
      if (!adminWaiting.length) {
        adminRetryDelay = ADMIN_RETRY_PAUSE_MS;
        return;
      }
      requestAdminBundle().then(mountWaitingStubs, function(err) {
        if (err && err.pkRan) {
          adminWaiting = [];
          console.error("[PhoenixKit] " + ADMIN_RAN_MESSAGE);
          return;
        }
        adminRetryDelay = Math.min(adminRetryDelay * 2, ADMIN_RETRY_MAX_MS);
        scheduleAdminRetry();
      });
    }, adminRetryDelay);
  }

  var DROPPED_MESSAGE = "[PhoenixKit] A file chosen before the admin bundle arrived was dropped: the page reconnected to the server meanwhile. Choose it again.";

  // The upload manager registers the chunked uploader (`PkChunked`) with the
  // page's LiveSocket when it starts, and a stub starts it only once the bundle
  // is here. A file chosen before then is preflighted all the same, and LiveView
  // looks the uploader up when the server answers: finding none it throws, and
  // the entry stays on the server at 0%, holding a `max_entries` slot that the
  // manager's queue knows nothing about. Until the real uploader is registered
  // a stand-in takes the entries, waits for the bundle and passes them, with
  // the same arguments, to the real one (or fails them, when the bundle does
  // not come). The stand-in leaves as soon as the bundle has arrived.
  function holdChunkedUploader(hook) {
    var sock = hook.liveSocket;
    if (!hook.el || !hook.el.dataset || hook.el.dataset.resumable !== "true") return;
    if (!sock || !sock.uploaders || sock.uploaders.PkChunked) return;

    // The script is already on the page (the standalone file, run after LiveSocket was built):
    // the real uploader goes in now, whether or not the bundle comes.
    if (window.PhoenixKitUploadManager) {
      window.PhoenixKitUploadManager.chunked.register(sock);
      return;
    }

    function handOver() {
      return loadAdminBundle().then(function() {
        if (sock.uploaders.PkChunked === standIn) delete sock.uploaders.PkChunked;
        if (window.PhoenixKitUploadManager) window.PhoenixKitUploadManager.chunked.register(sock);
      });
    }

    // LiveView hands every uploader a second argument: a function that takes a
    // callback to run when the channel of the join that preflighted these entries
    // errors (the socket drops, the process dies). From then on the entries belong
    // to a process that is gone, and what is pushed for them fails it or is
    // ignored: one still waiting here is let go (neither started nor failed, a
    // failed mark is a push too), one already sending is stopped.
    function standIn(entries, onError) {
      var args = arguments;
      var lost = false;
      if (typeof onError === "function") {
        onError(function() {
          lost = true;
          var chunked = window.PhoenixKitUploadManager && window.PhoenixKitUploadManager.chunked;
          var sending = chunked ? entries.filter(function(entry) { return chunked.info(entry.ref); }) : [];
          sending.forEach(function(entry) { chunked.stop(entry.ref); });
          if (sending.length) console.warn(DROPPED_MESSAGE);
        });
      }
      function dropped() {
        if (lost) console.warn(DROPPED_MESSAGE);
        return lost;
      }
      return handOver().then(function() {
        if (dropped()) return;
        var real = sock.uploaders.PkChunked;
        if (typeof real !== "function" || real === standIn) throw new Error("the admin bundle defines no chunked uploader");
        return real.apply(null, args);
      }).catch(function(err) {
        if (dropped()) return;
        console.error("[PhoenixKit] A file chosen before the admin bundle arrived could not be sent:", err);
        entries.forEach(function(entry) { entry.error("failed"); });
      });
    }

    standIn.__pkStandIn = true;
    sock.uploaders.PkChunked = standIn;
    handOver().catch(function() { /* the loader has reported it; the stand-in fails what reaches it */ });
  }

  // A stub gets no `disconnected` / `reconnected` of the real hook, and LiveView
  // calls them only on the hook instance it made. The upload manager has to know
  // that the socket is down when it starts (a bundle that arrives during an
  // outage), or a file picked then is fed to a dead socket, judged not accepted
  // and never sent again: every stub of it keeps the state as LiveView reports it
  // and tells the real hook once it is mounted.
  function holdConnectionState(hook) {
    var down = false;
    hook.disconnected = function() { down = true; };
    hook.reconnected = function() { down = false; };
    return function(mounted) { if (down) mounted.disconnected(); };
  }

  // The stand-in leaves when the bundle arrives, but only through the stub that
  // installed it, and only if that stub's own request was the one that succeeded.
  // After a failed load and a later one (another mount asked again) it is still
  // under `PkChunked`, and the first file the manager queued would go through it.
  // Whichever stub the real hook is mounted for takes it away.
  function releaseStandIn(hook) {
    var uploaders = hook.liveSocket && hook.liveSocket.uploaders;
    if (!uploaders || !uploaders.PkChunked || !uploaders.PkChunked.__pkStandIn) return;
    delete uploaders.PkChunked;
    if (window.PhoenixKitUploadManager) window.PhoenixKitUploadManager.chunked.register(hook.liveSocket);
  }

  // What a stub does on every mount, before it waits for the bundle; what it
  // returns is called with the hook once the real one has mounted.
  var ADMIN_STUB_SETUP = {
    UploadManager: function(hook) {
      var replay = holdConnectionState(hook);
      holdChunkedUploader(hook);
      return function(mounted) {
        replay(mounted);
        releaseStandIn(mounted);
      };
    }
  };

  function adminStub(name) {
    return {
      __pkAdminStub: true,
      mounted: function() {
        var self = this;
        self.__pkGone = false;
        var started = Object.prototype.hasOwnProperty.call(ADMIN_STUB_SETUP, name) ? ADMIN_STUB_SETUP[name](self) : null;
        function mountReal() {
          if (self.__pkGone) return;
          var real = window.PhoenixKitAdminHooks && window.PhoenixKitAdminHooks[name];
          if (!real) {
            console.error("[PhoenixKit] The admin bundle loaded but defines no hook named " + name + ". " +
              "If " + name + " belongs to a module, that module's js_sources/0 entry lists it in `hooks:` " +
              "but its bundle does not export it under that name; otherwise phoenix_kit.js and " +
              "phoenix_kit_admin.js are from different PhoenixKit versions.");
            return;
          }
          if (typeof real === "function") {
            // `Object.keys` of a class is its statics, and LiveView would have made an instance of
            // it; a stub can only take callbacks off an object and put them on the hook it has.
            console.error("[PhoenixKit] The admin hook " + name + " is a class or a function. A hook behind a stub has " +
              "to be an object of callbacks (`{ mounted() { … }, destroyed() { … } }`), so it did not start.");
            return;
          }
          Object.keys(real).forEach(function(key) {
            if (key !== "mounted") self[key] = real[key];
          });
          // One hook that throws must not take the others with it: the stubs that
          // waited are mounted in a loop, off the list they were on, so an exception
          // here would leave the rest on no list at all (and it would surface as an
          // unhandled rejection instead of a message that names the hook).
          try {
            if (typeof real.mounted === "function") real.mounted.call(self);
            if (typeof started === "function") started(self);
          } catch (err) {
            console.error("[PhoenixKit] The " + name + " hook threw while mounting:", err);
          }
        }
        // With the bundle here, mount in this very turn. LiveView mounts the hooks of a
        // diff and then dispatches the diff's events in one synchronous stack, so a
        // `handleEvent` registered a microtask later would miss an event the same diff
        // pushed. A promise would have deferred it even when it had already settled.
        if (window.PhoenixKitAdminLoaded) {
          mountReal();
          if (adminWaiting.length) mountWaitingStubs();
          return;
        }
        loadAdminBundle().then(function() {
          mountReal();
          mountWaitingStubs();
        }, function(err) {
          if (err && err.pkRan) {
            // The file ran and threw: nothing to retry. The hook that went without is named.
            console.error("[PhoenixKit] The " + name + " hook did not start. " + ADMIN_RAN_MESSAGE);
            return;
          }
          // loadLibrary has reported the failure; this names the hook that went without.
          var urls = pkLibUrls("admin");
          console.error("[PhoenixKit] The " + name + " hook did not start: the admin bundle could not be loaded (" +
            (urls ? urls.local : "no install facts name it") + "). Run mix phoenix_kit.update, then check the network and the page's Content-Security-Policy. " +
            "It is tried again in a few seconds.");
          adminWaiting.push({ hook: self, mount: mountReal });
          scheduleAdminRetry();
        });
      },
      destroyed: function() {
        this.__pkGone = true;
      }
    };
  }

  // A module bundle that ran first (a deferred phoenix_kit_modules.js placed
  // ahead of an app.js that holds this file) has already put its hooks here; a
  // name it chose to define stays its own.
  function registerAdminStubs(names) {
    names.forEach(function(name) {
      if (!window.PhoenixKitHooks[name]) window.PhoenixKitHooks[name] = adminStub(name);
    });
  }

  // The admin hooks of modules (js_sources/0 `scope: :admin`) are named in
  // phoenix_kit_modules.js, which runs before or after this file depending on
  // the host's layout: names it left on the window are stubbed now, and it calls
  // this function itself when it runs second.
  registerAdminStubs(ADMIN_HOOKS.concat(window.PhoenixKitModuleAdminHooks || []));
  window.PhoenixKitRegisterAdminStubs = registerAdminStubs;

  // Early start. The stubs load the bundle on the first mount, which for a
  // page loaded cold is after the socket has joined. The admin and dashboard
  // layouts carry `data-pk-admin`; finding it once the document is parsed
  // starts the download then, in parallel with the connect, and the stubs join
  // the same request. An optimisation only: a page without the marker (a live
  // navigation from a public page, a host's own layout) still works, one
  // round trip later.
  //
  // The file names come from the install facts (phoenix_kit_modules.js), which
  // may not have run yet: a host that defers both tags runs this file while the
  // document is "interactive", ahead of a slower facts file. Asking then would
  // report a failure that is only lateness and open the pause that refuses the
  // first real mounts. So with no facts the start waits, and tries once more when
  // the document has been parsed, which is after every deferred script.
  function startAdminBundleEarly() {
    if (!document.querySelector("[data-pk-admin]")) return;
    if (!window.PHOENIX_KIT_LIBS) return;
    loadAdminBundle().catch(function() { /* reported by the loader */ });
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", startAdminBundleEarly);
  } else {
    setTimeout(startAdminBundleEarly, 0);
    if (document.readyState === "interactive") document.addEventListener("DOMContentLoaded", startAdminBundleEarly);
  }

  // The first moments of a box select on the media browser. The box select is
  // admin code (phoenix_kit_admin.js); until that file has run, a press on the
  // browser's content column (`[data-box-area]`) and a drag would select text,
  // the very thing the box replaces. So the press is kept (`__pkEarlyPress`),
  // the selection refused, and the admin file takes the press over when it
  // arrives. Nothing is drawn or sent from here.
  document.addEventListener("pointerdown", function(e) {
    if (window.PhoenixKitAdminLoaded) return;
    // A press whose release never came (the window lost focus) ends with the
    // next press of that pointer.
    var old = window.__pkEarlyPress;
    if (old && !old.end && old.e.pointerId === e.pointerId) {
      old.done();
      window.__pkEarlyPress = null;
    }
    var t = e.target;
    if (e.button !== 0 || e.pointerType === "touch" || !t.closest || !t.closest("[data-box-area]")) return;
    // Shift + press on a card would extend the page's text selection.
    if (e.shiftKey && t.closest("[data-draggable-file], [data-draggable-folder]")) return e.preventDefault();
    var press = { e: e, t: Date.now(), last: null, end: null, done: done };
    function refuse(ev) { ev.preventDefault(); }
    function move(ev) {
      if (ev.pointerId === e.pointerId) press.last = { x: ev.clientX, y: ev.clientY };
    }
    function done() {
      document.removeEventListener("selectstart", refuse, true);
      window.removeEventListener("pointermove", move, true);
      window.removeEventListener("pointerup", up, true);
      window.removeEventListener("pointercancel", drop, true);
    }
    function up(ev) {
      if (ev.pointerId !== e.pointerId) return;
      press.end = { x: ev.clientX, y: ev.clientY };
      done();
    }
    function drop(ev) {
      if (ev.pointerId !== e.pointerId) return;
      window.__pkEarlyPress = null;
      done();
    }
    if (window.__pkEarlyPress) window.__pkEarlyPress.done();
    window.__pkEarlyPress = press;
    document.addEventListener("selectstart", refuse, true);
    window.addEventListener("pointermove", move, true);
    window.addEventListener("pointerup", up, true);
    window.addEventListener("pointercancel", drop, true);
  }, true);

  // The admin menu's scroll position on a full page load. AdminSidebarScroll
  // (phoenix_kit_admin.js) saves it and restores it on a live redirect, but a full load
  // waits for the bundle, which is requested at DOMContentLoaded at the earliest: the menu
  // would paint at the top and then jump. So the restore is here, run as soon as the
  // document is parsed: the saved offset, and, when nothing is saved (a fresh tab, a deep
  // link) or the offset hides the current page's link, the link centred. The admin
  // hook calls this same function through PhoenixKitInternals, so the two cannot drift apart.
  var SIDEBAR_SCROLL = {
    id: "pk-admin-sidebar",
    key: "phoenix_kit:admin:sidebar:scroll",
    saved: function() {
      try {
        var v = sessionStorage.getItem(SIDEBAR_SCROLL.key);
        if (v == null) return null;
        var n = parseInt(v, 10);
        return isNaN(n) ? null : n;
      } catch (_e) {
        return null;
      }
    }
  };

  // Direct scrollTop arithmetic rather than scrollIntoView, which can scroll ancestors too.
  function restoreSidebar(el) {
    var max = Math.max(0, el.scrollHeight - el.clientHeight);
    var saved = SIDEBAR_SCROLL.saved();
    if (saved != null) el.scrollTop = Math.min(saved, max);
    var active = el.querySelector('[aria-current="page"]');
    if (!active) return;
    var er = el.getBoundingClientRect();
    var ar = active.getBoundingClientRect();
    if (saved == null || ar.top < er.top || ar.bottom > er.bottom) {
      var target = el.scrollTop + (ar.top - er.top) - (el.clientHeight - ar.height) / 2;
      el.scrollTop = Math.min(Math.max(0, target), max);
    }
  }
  SIDEBAR_SCROLL.restore = restoreSidebar;

  function restoreSidebarOnLoad() {
    var el = document.getElementById(SIDEBAR_SCROLL.id);
    if (el) restoreSidebar(el);
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", restoreSidebarOnLoad);
  } else {
    restoreSidebarOnLoad();
  }

  // What phoenix_kit_admin.js reads from this file. Not an API: it is the
  // closure this file's own helpers live in, handed to the one file that was
  // cut out of it.
  // Merged, never replaced: the person card put its openers here earlier in
  // this file, and a fresh object wiped them (grok, 2026-11-25).
  window.PhoenixKitInternals = Object.assign(window.PhoenixKitInternals || {}, {
    adminHookNames: ADMIN_HOOKS,
    adoptStyle: pkAdoptStyle,
    lazyHook: lazyHook,
    loadChartJs: loadChartJs,
    loadVendored: loadVendored,
    pkLoaders: pkLoaders,
    sidebarScroll: SIDEBAR_SCROLL
  });



  // ============================================================================
  // INITIALIZATION COMPLETE
  // ============================================================================

  if (typeof console !== "undefined" && console.debug) {
    var hookCount = Object.keys(window.PhoenixKitHooks).length;
    if (hookCount > 0) {
      console.debug(
        "[PhoenixKit] Initialized with " + hookCount + " hook(s):",
        Object.keys(window.PhoenixKitHooks)
      );
    }
  }

})();

// ---------------------------------------------------------------------------
// Collapse scroll keeper. Closing an expanded <details class="collapse"> near
// the bottom of the page shrinks the document; the browser clamps the scroll
// position to the new maximum and the viewport jumps upward under the reader.
// Just before the collapse, pad the document with a body spacer so it cannot
// become shorter than the reader's current position — they stay put, looking
// at the now-closed section, with blank space below the fold. Every pixel
// they then scroll up releases a pixel of that spacer (height leaving from
// entirely below the viewport is invisible), so the page works its way back
// to its natural length without ever moving underfoot.
//
// Two deliberate choices, both learned from getting it wrong first:
//
//   * Measured on the summary ACTIVATION, not the `toggle` event. By the time
//     `toggle` fires the element may already be collapsed — no animation
//     under prefers-reduced-motion — leaving nothing to measure, and that is
//     exactly the case where the jump is most jarring.
//   * Released against the READER'S SCROLLING, not the live document height.
//     Mid-collapse the document still contains the content that is on its way
//     out, so height-based math reads the spacer as unnecessary and hands it
//     back before the shrink lands — the clamp then happens anyway. Scroll
//     distance is exact and needs no animation-timing machinery.
//
// The held height goes on the layout's [data-pk-collapse-pad] element when one
// is present (PhoenixKit's admin layout marks its content column), so sticky
// sidebars and page backgrounds extend through the blank area; otherwise a
// body-level div is injected, which holds the position just as well but leaves
// the blank area outside any app chrome. Only the window-scrolled case is
// handled: inside an inner scroll container neither helps, so those bail out
// to the browser default.
(function() {
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  if (typeof window === "undefined" || typeof document === "undefined") return;

  // Extra spacer height so (scrollTop + viewport) still fits inside the
  // document after `shrink` px of content collapses away. `docHeight`
  // includes any existing spacer, so the result stacks on top of it.
  // Pure — unit-tested in test/js/collapse_space.test.cjs.
  function extraSpaceNeeded(scrollTop, viewport, docHeight, shrink) {
    var overshoot = scrollTop + viewport - (docHeight - shrink);
    return overshoot > 0 ? Math.ceil(overshoot) : 0;
  }

  // Height the spacer still needs once the reader has scrolled up away from
  // the position it was installed to protect. `highestTop` is the smallest
  // scrollTop seen since it was installed, so scrolling back down cannot
  // re-claim space that was already given up — the page only ever gets
  // shorter, and only from below the fold.
  function spacerAfterScrollUp(installedHeight, installedTop, highestTop) {
    var released = Math.max(0, installedTop - highestTop);
    return Math.max(0, installedHeight - released);
  }

  if (typeof module === "object" && module.exports) {
    module.exports.extraSpaceNeeded = extraSpaceNeeded;
    module.exports.spacerAfterScrollUp = spacerAfterScrollUp;
  }

  var spacer = null;
  var injected = false;
  var installedHeight = 0;
  var installedTop = 0;
  var highestTop = 0;

  function scrollTopNow() {
    return (document.scrollingElement || document.documentElement).scrollTop;
  }

  function metrics() {
    var el = document.scrollingElement || document.documentElement;
    return { top: el.scrollTop, view: window.innerHeight, height: el.scrollHeight };
  }

  function insideInnerScroller(el) {
    var node = el.parentElement;
    while (node && node !== document.body) {
      var oy = window.getComputedStyle(node).overflowY;
      if (oy === "auto" || oy === "scroll") return true;
      node = node.parentElement;
    }
    return false;
  }

  // The element that carries the held height. A layout that marks its content
  // column with data-pk-collapse-pad gets the space INSIDE its own chrome, so
  // sticky sidebars and page backgrounds extend through it; anything else
  // falls back to a body-level div, which holds the scroll position just as
  // well but leaves the blank area outside the app's layout.
  function ensureSpacer() {
    if (spacer && spacer.isConnected) return spacer;

    var pad = document.querySelector("[data-pk-collapse-pad]");
    if (pad) {
      spacer = pad;
      injected = false;
    } else {
      spacer = document.createElement("div");
      spacer.setAttribute("data-pk-collapse-spacer", "");
      spacer.setAttribute("aria-hidden", "true");
      spacer.style.width = "100%";
      spacer.style.flex = "0 0 auto";
      spacer.style.pointerEvents = "none";
      document.body.appendChild(spacer);
      injected = true;
    }

    window.addEventListener("scroll", onScroll, { passive: true });
    return spacer;
  }

  function releaseSpacer() {
    if (!spacer) return;
    if (injected) spacer.remove();
    else spacer.style.height = "";
    spacer = null;
    installedHeight = 0;
    window.removeEventListener("scroll", onScroll);
  }

  function onScroll() {
    if (!spacer) return;
    var top = scrollTopNow();
    if (top < highestTop) highestTop = top;
    var next = spacerAfterScrollUp(installedHeight, installedTop, highestTop);
    if (next <= 0) releaseSpacer();
    else spacer.style.height = next + "px";
  }

  function hold(shrink) {
    var m = metrics();
    var extra = extraSpaceNeeded(m.top, m.view, m.height, shrink);
    if (extra <= 0) return;

    ensureSpacer();

    // A second close stacks onto whatever is left and re-anchors: from here
    // on, this is the position being protected.
    installedHeight = spacer.offsetHeight + extra;
    installedTop = m.top;
    highestTop = m.top;
    spacer.style.height = installedHeight + "px";
  }

  // Runs BEFORE the default action toggles the element, so the height read
  // here is the full expanded one that is about to disappear.
  function onSummaryActivate(e) {
    var target = e.target;
    if (!target || !target.closest) return;

    var summary = target.closest("summary");
    if (!summary) return;

    var details = summary.closest("details");
    if (!details || !details.classList.contains("collapse")) return;
    if (!details.open) return; // opening: the document only grows
    if (insideInnerScroller(details)) return;

    var shrink = details.offsetHeight - summary.offsetHeight;
    if (isFinite(shrink) && shrink > 0) hold(shrink);
  }

  document.addEventListener("click", onSummaryActivate, true);
  document.addEventListener(
    "keydown",
    function(e) {
      if (e.key === "Enter" || e.key === " " || e.key === "Spacebar") {
        onSummaryActivate(e);
      }
    },
    true
  );

  // Live navigation swaps the page content and resets the scroll position;
  // whatever the old page was holding open is meaningless now.
  window.addEventListener("phx:page-loading-stop", function() {
    if (spacer && scrollTopNow() <= 0) releaseSpacer();
  });
})();

// ---------------------------------------------------------------------------
// Change cue — "that choice changed something you can't see".
// Server side: PhoenixKitWeb.Components.Core.ChangeCue.push/3, whose
// moduledoc is the reference. This is the client half.
//
// The server sends only WHAT changed (element ids). It cannot decide how to
// show it, because it doesn't know what's on screen: whether a <details> is
// open is client state, and so is the scroll position. So the client
// resolves each id, walks up to its [data-change-region], and picks:
//
//   * region open   -> highlight the changed rows. Highlighting the whole
//     region tells someone already reading it nothing.
//   * region closed -> highlight the region and MARK it. Opening it replays
//     the row highlights and clears the mark.
//
// The mark, not a timer, is what makes this survive reality. A highlight
// that plays while the reader is scrolled away is simply lost, and an
// N-second memory turns "what changed in here?" into a race against a
// stopwatch. The mark waits.
//
// Won't scroll, open anything, or move focus.
(function() {
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  if (typeof window === "undefined" || typeof document === "undefined") return;

  var STYLE_ID = "pk-change-cue-style";
  var CLASS = "pk-cued";
  var REGION = "[data-change-region]";
  var DURATION = 1400;
  var MAX_TARGETS = 6;
  var ANNOUNCE_GAP = 1000;

  // Pending rows per region id. Kept off the DOM node: LiveView can replace
  // an element between the change and the reader opening it, and state on
  // the old node would go with it.
  var pending = {};
  var lastAnnounce = 0;

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;

    var style = document.createElement("style");
    style.id = STYLE_ID;
    if (window.PhoenixKitInternals && window.PhoenixKitInternals.adoptStyle) {
      window.PhoenixKitInternals.adoptStyle(style);
    }
    style.textContent =
      "@keyframes pk-cue-pulse {" +
      "  0% { box-shadow: 0 0 0 0 var(--pk-cue-color, oklch(0.7 0.15 250 / 0.55)); }" +
      "  70% { box-shadow: 0 0 0 6px var(--pk-cue-color, oklch(0.7 0.15 250 / 0)); }" +
      "  100% { box-shadow: 0 0 0 0 var(--pk-cue-color, oklch(0.7 0.15 250 / 0)); }" +
      "}" +
      "." + CLASS + " {" +
      "  animation: pk-cue-pulse 1.4s ease-out 1;" +
      "  border-radius: 0.5rem;" +
      "}" +
      // The marker rides the region's own state, so it survives patches
      // (the region declares data-changed client-owned) and needs no
      // server round-trip to clear.
      "[data-change-region][data-changed] [data-change-marker] { display: inline-flex; }" +
      "@media (prefers-reduced-motion: reduce) {" +
      "  ." + CLASS + " { animation: none; outline: 2px solid var(--pk-cue-color, currentColor); }" +
      "}";

    document.head.appendChild(style);
  }

  function cue(el) {
    if (!el) return;

    // Restart rather than re-add: a class an element already has changes
    // nothing, so a rapid second change would look like nothing happened.
    el.classList.remove(CLASS);
    void el.offsetWidth;
    el.classList.add(CLASS);

    window.clearTimeout(el.__pkCueTimer);
    el.__pkCueTimer = window.setTimeout(function() {
      el.classList.remove(CLASS);
    }, DURATION);
  }

  function announce(text) {
    if (!text) return;

    var now = Date.now();
    if (now - lastAnnounce < ANNOUNCE_GAP) return;
    lastAnnounce = now;

    var live = document.getElementById("pk-change-cue-status");

    if (!live) {
      live = document.createElement("div");
      live.id = "pk-change-cue-status";
      live.setAttribute("role", "status");
      live.setAttribute("aria-live", "polite");
      live.setAttribute("aria-atomic", "true");
      live.className = "sr-only";
      document.body.appendChild(live);
    }

    live.textContent = text;
  }

  function onScreen(el) {
    var r = el.getBoundingClientRect();
    return r.bottom > 0 && r.top < (window.innerHeight || 0);
  }

  // Opening a long section puts most of it below the fold, so a highlight
  // down there plays to nobody — the reader opens it, sees nothing, and
  // the cue has cost them a click and told them less than nothing. Cue
  // what is on screen now, and watch the rest until they scroll to it.
  function replay(ids) {
    var waiting = [];

    ids.forEach(function(id) {
      var el = document.getElementById(id);
      if (!el) return;

      if (onScreen(el)) {
        cue(el);
      } else {
        waiting.push(el);
      }
    });

    if (!waiting.length || typeof IntersectionObserver === "undefined") return;

    var observer = new IntersectionObserver(
      function(entries) {
        entries.forEach(function(entry) {
          if (!entry.isIntersecting) return;
          cue(entry.target);
          observer.unobserve(entry.target);
        });
      },
      { threshold: 0.5 }
    );

    waiting.forEach(function(el) {
      observer.observe(el);
    });

    // Don't watch forever: a section left open and never scrolled to
    // shouldn't hold observers for the life of the page.
    window.setTimeout(function() {
      observer.disconnect();
    }, 30000);
  }

  // One utterance per pushed change, however many regions it touched, and
  // only for changes the reader cannot see: an open region announces
  // itself by being visible.
  function announceOnce(payload) {
    if (payload.__announced) return;
    payload.__announced = true;
    announce(payload.announce);
  }

  function markRegion(region, ids) {
    region.setAttribute("data-changed", "");

    var key = region.getAttribute("data-change-region") || region.id;
    if (!key) return;

    var held = pending[key] || [];
    // Union: a second change while still closed adds to the answer rather
    // than replacing it.
    ids.forEach(function(id) {
      if (held.indexOf(id) === -1) held.push(id);
    });

    pending[key] = held;
  }

  function apply(payload) {
    var targets = (payload.targets || []).map(function(t) {
      // Ids alone are still accepted; the grouped form carries a fallback
      // region for targets that may not exist any more.
      return typeof t === "string" ? { id: t } : t;
    });

    if (!targets.length) return;

    ensureStyle();

    var byRegion = new Map();
    var loose = [];
    // Regions whose change REMOVED the element. There is nothing left to
    // highlight, so the region itself carries the news — and nothing is
    // queued for replay, because a missing id will still be missing when
    // they open it.
    var vanished = new Set();

    targets.forEach(function(target) {
      var el = document.getElementById(target.id);

      if (!el) {
        var anchor = target.region && document.getElementById(target.region);
        if (anchor) vanished.add(anchor);
        return;
      }

      var region = el.closest(REGION);

      if (!region) {
        loose.push(el);
        return;
      }

      if (!byRegion.has(region)) byRegion.set(region, []);
      byRegion.get(region).push(target.id);
    });

    loose.forEach(cue);

    vanished.forEach(function(region) {
      // Don't double-cue a region that also has surviving targets — those
      // are handled below, and a row highlight says more than a region one.
      if (byRegion.has(region)) return;

      cue(region);

      if (region.tagName === "DETAILS" && !region.open) {
        region.setAttribute("data-changed", "");
        announceOnce(payload);
      }
    });

    byRegion.forEach(function(regionIds, region) {
      var closed = region.tagName === "DETAILS" && !region.open;

      if (closed) {
        cue(region);
        markRegion(region, regionIds);
        announceOnce(payload);
        return;
      }

      // Past a handful, individual highlights read as strobing rather than
      // as information.
      if (regionIds.length > MAX_TARGETS) {
        cue(region);
      } else {
        regionIds.forEach(function(id) {
          cue(document.getElementById(id));
        });
      }
    });
  }

  // Opening a marked region answers the question the mark raised.
  // Capture phase: `toggle` doesn't bubble.
  document.addEventListener(
    "toggle",
    function(e) {
      var region = e.target;
      if (!region || region.tagName !== "DETAILS" || !region.open) return;
      if (!region.hasAttribute("data-changed")) return;

      var key = region.getAttribute("data-change-region") || region.id;
      var ids = (key && pending[key]) || [];

      region.removeAttribute("data-changed");
      if (key) delete pending[key];
      if (!ids.length) return;

      ensureStyle();

      // Let the reveal start first, or the highlight plays against content
      // that is still zero-height. Deliberately silent for screen readers:
      // the change was already announced when it landed.
      window.setTimeout(function() {
        replay(ids.slice(0, MAX_TARGETS));
      }, 160);
    },
    true
  );

  function clearRegions(ids) {
    ids.forEach(function(id) {
      var region = document.getElementById(id);
      if (region) region.removeAttribute("data-changed");
      delete pending[id];
    });
  }

  window.addEventListener("phx:pk:change-cue", function(event) {
    var detail = event.detail || {};
    // A region whose state went back to what the reader last saw has
    // nothing to show. Without this, flipping a choice back and forth
    // leaves every section marked.
    if (detail.clear) clearRegions(detail.clear);
    apply(detail);
  });
})();

// ---------------------------------------------------------------------------
// A suggestion's face: the person's picture (the rule of every face,
// `UserInfo.avatar_brief/2`), else initials on the person's gradient. Built
// from text and a URL only (no markup from the server); a stored crop goes
// on through the style API, which a policy without inline style attributes
// still allows. Every class is written out whole so Tailwind sees it.
function pkMentionFace(av) {
  var face = document.createElement("span");
  face.className =
    "relative inline-flex size-6 shrink-0 items-center justify-center overflow-hidden rounded-full text-[10px] font-bold text-white bg-gradient-to-br " +
    (av.gradient || "from-primary to-secondary");
  face.setAttribute("aria-hidden", "true");
  face.textContent = av.initials || "?";
  if (av.url) {
    var img = document.createElement("img");
    img.src = av.url;
    img.alt = "";
    if (av.style) img.style.cssText = av.style;
    else img.className = "absolute inset-0 h-full w-full object-cover";
    img.addEventListener("error", function () { img.remove(); });
    face.appendChild(img);
  }
  return face;
}

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
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  if (typeof window === "undefined") return;
  window.PhoenixKitHooks = window.PhoenixKitHooks || {};

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

  window.PhoenixKitHooks.MentionInput = {
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
          a.className += " flex items-center gap-2";
          // A person's face beside the name (`avatar`: url | initials).
          if (r.avatar) a.appendChild(pkMentionFace(r.avatar));
          var text = document.createElement("span");
          text.className = "flex flex-col min-w-0";
          var title = document.createElement("span");
          title.className = "font-medium truncate";
          title.textContent = r.title;
          text.appendChild(title);
          if (r.subtitle) {
            var sub = document.createElement("span");
            sub.className = "text-xs opacity-60 truncate";
            sub.textContent = r.subtitle;
            text.appendChild(sub);
          }
          a.appendChild(text);
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
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;

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

  window.PhoenixKitHooks.UploadStats = {
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
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;

  window.PhoenixKitHooks = window.PhoenixKitHooks || {};

  window.PhoenixKitHooks.UploadGuard = {
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
// AudioRecorder — the microphone behind `<.audio_recorder>`
// (PhoenixKitWeb.Components.Core.AudioRecorder)
// ============================================================================
//
// Records, turns the clip into what was asked for, and uploads it through the
// component's own LiveView upload. The states are idle, recording and preparing
// (converting and uploading), each a `[data-recorder-state]` block of the
// `phx-update="ignore"` element, so a re-render leaves the one showing alone.
//
//   data-recorder     the component's id, on the events that come back
//   data-format       "wav_16k" or "native"
//   data-busy         "true" disables the start button
//   data-max-seconds  recording stops and sends at this length
//   data-upload-form  id of the component's upload form
//   data-upload-name  the name of its upload, or of the page's (with data-upload-ref)
//   data-upload-ref   set when the clip goes into a page's own upload: the ref of
//                     that upload, which is the id of its file input
//   data-start-button "false" when the page starts the recorder itself
//                     (`AudioRecorder.start/2` dispatches phoenix_kit:audio_recorder_start)
//
// `phx-target` on the element is for `render_hook/3` in tests. In a browser
// `pushEventTo(this.el, ...)` finds the component from the DOM.
(function () {
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  const WAV_RATE = 16000;
  const TICK_MS = 100;
  // How long a clip may sit in "preparing" with no sign of life. The server reports
  // each step of an upload (`watch`), so this is one that stopped moving, not a slow
  // one. A dropped connection is caught sooner, by `reconnected`.
  const PREPARING_TIMEOUT_MS = 120000;

  // Mono 16-bit PCM behind the 44-byte header the component reads the length from.
  function encodeWav(samples, rate) {
    const view = new DataView(new ArrayBuffer(44 + samples.length * 2));
    const text = (at, s) => {
      for (let i = 0; i < s.length; i++) view.setUint8(at + i, s.charCodeAt(i));
    };
    text(0, "RIFF");
    view.setUint32(4, 36 + samples.length * 2, true);
    text(8, "WAVE");
    text(12, "fmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, rate, true);
    view.setUint32(28, rate * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    text(36, "data");
    view.setUint32(40, samples.length * 2, true);
    for (let i = 0; i < samples.length; i++) {
      const s = Math.max(-1, Math.min(1, samples[i]));
      view.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
    return view.buffer;
  }

  function clock(seconds) {
    return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0");
  }

  // 0 to 100 from an AnalyserNode's time-domain bytes, where silence is 128. Doubled
  // because speech rarely gets near full scale, and a meter that barely moves reads
  // as a microphone that is not working.
  function meterLevel(bytes) {
    let peak = 0;
    for (let i = 0; i < bytes.length; i++) peak = Math.max(peak, Math.abs(bytes[i] - 128));
    return Math.min(100, Math.round((peak / 128) * 200));
  }

  // The upload's `accept` goes by extension.
  function extensionFor(mimeType) {
    const type = String(mimeType || "");
    if (type.indexOf("ogg") >= 0) return "ogg";
    if (type.indexOf("mp4") >= 0 || type.indexOf("aac") >= 0) return "mp4";
    return "webm";
  }

  // The type a clip is uploaded as: the recording's own, without
  // `;codecs=opus` (no part of what a server matches on), and when the
  // browser names none, the type of the extension the clip is given. A clip
  // sent with no type is judged by its name alone, and a host whose `accept`
  // lists `audio/*` but not `.webm` refused it: "recording-….webm: File
  // type not allowed" (Max, 2026-11-27).
  function clipType(blobType) {
    const type = String(blobType || "").split(";")[0].trim();
    return type || "audio/" + extensionFor(type);
  }

  function errorReason(error) {
    const name = error && error.name;
    return name === "NotAllowedError" || name === "SecurityError" ? "denied" : "unavailable";
  }

  function canRecord(win, format) {
    const media = win.navigator && win.navigator.mediaDevices;
    if (!win.isSecureContext || !media || !media.getUserMedia || !win.MediaRecorder) return false;
    if (format !== "wav_16k") return true;
    return !!((win.AudioContext || win.webkitAudioContext) && win.OfflineAudioContext);
  }

  async function toWav(blob) {
    const context = new (window.AudioContext || window.webkitAudioContext)();
    let decoded;
    try {
      decoded = await context.decodeAudioData(await blob.arrayBuffer());
    } finally {
      context.close();
    }
    const length = Math.max(1, Math.ceil(decoded.duration * WAV_RATE));
    const offline = new OfflineAudioContext(1, length, WAV_RATE);
    const source = offline.createBufferSource();
    source.buffer = decoded;
    source.connect(offline.destination);
    source.start();
    const rendered = await offline.startRendering();
    return encodeWav(rendered.getChannelData(0), WAV_RATE);
  }

  // "recording-2026-11-06-203015", for a clip that joins a page's own files.
  function recordingName(date) {
    const two = (n) => String(n).padStart(2, "0");
    return "recording-" + date.getFullYear() + "-" + two(date.getMonth() + 1) + "-" +
      two(date.getDate()) + "-" + two(date.getHours()) + two(date.getMinutes()) +
      two(date.getSeconds());
  }

  window.PhoenixKitHooks.AudioRecorder = {
    mounted() {
      this.state = "idle";
      this.format = this.el.dataset.format;
      this.chunks = [];
      // A page's own button starts the recorder with this event. Listened for even
      // where recording cannot work, so that button gets an answer, not silence.
      this.onStart = () => {
        // With no button of its own, this is where the focus goes back to.
        this.opener = document.activeElement;
        if (this.ready) this.start();
        else this.push("recorder_error", {reason: "unavailable"});
      };
      this.el.addEventListener("phoenix_kit:audio_recorder_start", this.onStart);
      if (!canRecord(window, this.format)) return;

      this.ready = true;
      this.onClick = (event) => {
        if (event.target.closest("[data-recorder-start]")) this.start();
        else if (event.target.closest("[data-recorder-send]")) this.stop(true);
        else if (event.target.closest("[data-recorder-cancel]")) this.stop(false);
      };
      // On the element, not the page: focus is on Send while recording, and a key
      // pressed elsewhere is not about this recorder. Stopped here, or the same
      // press closes the dialog the recorder sits in.
      this.onKey = (event) => {
        if (event.key !== "Escape" || this.state !== "recording") return;
        event.preventDefault();
        event.stopPropagation();
        this.stop(false);
      };
      this.el.addEventListener("click", this.onClick);
      this.el.addEventListener("keydown", this.onKey);
      this.handleEvent("audio_recorder_settled", (payload) => {
        if (payload.id !== this.el.dataset.recorder) return;
        clearTimeout(this.preparing);
        if (this.state === "preparing") this.backToIdle();
      });
      this.handleEvent("audio_recorder_progress", (payload) => {
        if (payload.id === this.el.dataset.recorder && this.state === "preparing") this.watch();
      });
      this.el.hidden = false;
      this.show("idle");
    },

    updated() {
      if (this.ready && this.part("start")) this.part("start").disabled = this.busy();
    },

    // The upload died with the connection. The server has no entry left, so
    // nothing else would ever end this.
    reconnected() {
      if (this.state === "preparing") {
        this.settle();
        this.push("recorder_error", {reason: "failed"});
      }
    },

    destroyed() {
      this.gone = true;
      this.el.removeEventListener("phoenix_kit:audio_recorder_start", this.onStart);
      if (!this.ready) return;
      this.el.removeEventListener("click", this.onClick);
      this.el.removeEventListener("keydown", this.onKey);
      clearTimeout(this.preparing);
      if (this.recorder) this.recorder.onstop = null;
      if (this.recorder && this.recorder.state === "recording") this.recorder.stop();
      this.release();
    },

    part(name) {
      return this.el.querySelector("[data-recorder-" + name + "]");
    },

    push(event, payload) {
      return this.pushEventTo(this.el, event, payload);
    },

    busy() {
      return this.el.dataset.busy === "true";
    },

    show(state) {
      this.state = state;
      this.el.querySelectorAll("[data-recorder-state]").forEach((block) => {
        block.hidden = block.dataset.recorderState !== state;
      });
      const start = this.part("start");
      if (start) start.disabled = this.busy();
      // Started from the page's own button: nothing to show while idle.
      if (this.el.dataset.startButton === "false") this.el.hidden = state === "idle";
    },

    async start() {
      if (this.starting || this.state !== "idle" || this.busy()) return;
      this.starting = true;
      let stream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({audio: true});
      } catch (error) {
        this.starting = false;
        if (!this.gone) this.push("recorder_error", {reason: errorReason(error)});
        return;
      }
      this.starting = false;
      // The permission prompt can outlive the page, and a late stream still holds
      // the microphone.
      if (this.gone) {
        stream.getTracks().forEach((track) => track.stop());
        return;
      }
      this.stream = stream;
      this.chunks = [];
      // Until someone says otherwise: a recording also ends by itself, when the
      // microphone is unplugged or the permission withdrawn, and what it caught is sent.
      this.sending = true;
      try {
        this.recorder = new MediaRecorder(stream);
        this.recorder.ondataavailable = (event) => {
          if (event.data && event.data.size > 0) this.chunks.push(event.data);
        };
        this.recorder.onstop = () => this.finish();
        this.recorder.onerror = () => {
          this.sending = false;
          this.push("recorder_error", {reason: "unavailable"});
          this.stop(false);
        };
        this.recorder.start();
      } catch (_error) {
        this.release();
        this.push("recorder_error", {reason: "unavailable"});
        return;
      }
      this.startedAt = Date.now();
      this.startMeter(stream);
      this.push("recorder_started", {});
      this.show("recording");
      this.part("send").focus();
      this.tick();
      this.timer = setInterval(() => this.tick(), TICK_MS);
    },

    // A level meter is a nicety: a browser that cannot run one still records.
    startMeter(stream) {
      try {
        this.meter = new (window.AudioContext || window.webkitAudioContext)();
        this.analyser = this.meter.createAnalyser();
        this.analyser.fftSize = 256;
        this.meter.createMediaStreamSource(stream).connect(this.analyser);
        this.levels = new Uint8Array(this.analyser.fftSize);
      } catch (_error) {
        this.analyser = null;
      }
    },

    tick() {
      const seconds = Math.floor((Date.now() - this.startedAt) / 1000);
      this.part("time").textContent = clock(seconds);
      if (this.analyser) {
        this.analyser.getByteTimeDomainData(this.levels);
        this.part("level").value = meterLevel(this.levels);
      }
      if (seconds >= Number(this.el.dataset.maxSeconds)) this.stop(true);
    },

    stop(send) {
      if (!this.recorder || this.recorder.state !== "recording") return;
      this.sending = send;
      clearInterval(this.timer);
      this.recorder.stop();
    },

    // Everything that keeps the browser's "recording" indicator on.
    release() {
      clearInterval(this.timer);
      if (this.stream) this.stream.getTracks().forEach((track) => track.stop());
      this.stream = null;
      if (this.meter) this.meter.close();
      this.meter = null;
      this.analyser = null;
    },

    async finish() {
      const seconds = (Date.now() - this.startedAt) / 1000;
      const mimeType = this.recorder.mimeType;
      this.release();
      if (!this.sending) return this.backToIdle();
      if (this.chunks.length === 0) return this.unreadable();

      this.show("preparing");
      try {
        const file = await this.fileFrom(new Blob(this.chunks, {type: mimeType}));
        if (this.abandoned()) return;
        if (this.el.dataset.uploadRef) return this.handOver(file);
        await this.push("recorder_clip", {duration: seconds});
        if (this.abandoned()) return;
        this.watch();
        // To this component's own form, by element: `this.upload/2` looks through
        // the whole LiveView, and with two recorders logs a duplicate input and
        // drops the clip without an error.
        const form = document.getElementById(this.el.dataset.uploadForm);
        this.uploadTo(form, this.el.dataset.uploadName, [file]);
      } catch (_error) {
        if (!this.abandoned()) this.unreadable();
      }
    },

    // Into the page's own upload, through that upload's form, found by its input (whose
    // id is the upload's ref). The page's upload shows it from here on, so this
    // recorder is ready for the next clip at once.
    handOver(file) {
      // Off the connection the page's upload would drop it without a word. Still
      // "preparing", this is `reconnected`'s to report, as for a clip of the recorder's own.
      if (!this.liveSocket.isConnected()) return this.watch();
      const input = document.getElementById(this.el.dataset.uploadRef);
      const form = input && input.form;
      if (!form) {
        this.push("recorder_error", {reason: "failed"});
        return this.settle();
      }
      this.uploadTo(form, this.el.dataset.uploadName, [file]);
      this.settle();
    },

    // The hook is gone, or `reconnected` ended this clip while it was being made ready:
    // going on would upload it after the person was told it failed.
    abandoned() {
      return this.gone || this.state !== "preparing";
    },

    watch() {
      clearTimeout(this.preparing);
      this.preparing = setTimeout(() => {
        this.settle();
        this.push("recorder_error", {reason: "failed"});
      }, PREPARING_TIMEOUT_MS);
    },

    async fileFrom(blob) {
      // A clip that joins a page's files is named so it can be told apart there.
      const base = this.el.dataset.uploadRef ? recordingName(new Date()) : "clip";
      if (this.format === "wav_16k") {
        return new File([await toWav(blob)], base + ".wav", {type: "audio/wav"});
      }
      const type = clipType(blob.type);
      return new File([blob], base + "." + extensionFor(type), {type: type});
    },

    unreadable() {
      this.push("recorder_error", {reason: "unreadable"});
      this.settle();
    },

    settle() {
      clearTimeout(this.preparing);
      this.backToIdle();
    },

    // The Send that had focus is hidden now, which leaves a keyboard user at the top
    // of the page. A clip that stopped on its own must not pull focus from elsewhere.
    backToIdle() {
      const active = document.activeElement;
      const lost = !active || active === document.body || this.el.contains(active);
      this.show("idle");
      const back = this.part("start") || this.opener;
      if (lost && back) back.focus();
    }
  };

  // Exported for the Node test harness (test/js); harmless in a browser.
  if (typeof module === "object" && module.exports) {
    module.exports.encodeWav = encodeWav;
    module.exports.clock = clock;
    module.exports.meterLevel = meterLevel;
    module.exports.extensionFor = extensionFor;
    module.exports.clipType = clipType;
    module.exports.errorReason = errorReason;
    module.exports.canRecord = canRecord;
    module.exports.recordingName = recordingName;
  }
})();

// ---------------------------------------------------------------------------
// PasskeySignIn / PasskeyRegister
//
// WebAuthn for `PhoenixKit.Users.Passkeys`. The server makes every challenge
// and keeps it (in the LiveView's memory); these hooks only carry bytes between
// the server and `navigator.credentials`, base64url both ways. Each attempt
// asks for a fresh challenge (a `pushEvent` with a reply), so nothing is made
// for a visitor who never uses a passkey, and a failed attempt cannot be
// replayed.
//
// PasskeySignIn (the sign-in page): starts the browser's passkey suggestions in
// the email field (conditional mediation) when the browser has them, and the
// modal prompt from a `[data-passkey-sign-in]` button inside the hook element.
// The suggestion request is aborted before the modal one starts, and on destroy.
//
// PasskeyRegister (account settings, a LiveComponent): a
// `[data-passkey-register]` button inside the hook element runs
// `navigator.credentials.create`; events go to the component (`pushEventTo`).
//
// Where the browser has no WebAuthn, the hook element gets
// `data-passkey-unsupported` and its buttons are hidden.
// ---------------------------------------------------------------------------
(function () {
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  function toBase64Url(buffer) {
    var bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
    var binary = "";
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function fromBase64Url(text) {
    var base64 = String(text).replace(/-/g, "+").replace(/_/g, "/");
    while (base64.length % 4) base64 += "=";
    var binary = atob(base64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function descriptors(list) {
    return (list || []).map(function (d) {
      var out = { type: d.type || "public-key", id: fromBase64Url(d.id) };
      if (d.transports && d.transports.length) out.transports = d.transports;
      return out;
    });
  }

  // The server's JSON options for navigator.credentials.create, with every
  // byte field turned into bytes.
  function creationOptions(json) {
    var options = Object.assign({}, json);
    options.challenge = fromBase64Url(json.challenge);
    options.user = Object.assign({}, json.user, { id: fromBase64Url(json.user.id) });
    options.excludeCredentials = descriptors(json.excludeCredentials);
    return options;
  }

  // The same for navigator.credentials.get.
  function requestOptions(json) {
    var options = Object.assign({}, json);
    options.challenge = fromBase64Url(json.challenge);
    options.allowCredentials = descriptors(json.allowCredentials);
    return options;
  }

  function registrationPayload(credential, userAgent) {
    var response = credential.response;
    return {
      rawId: toBase64Url(credential.rawId),
      attestationObject: toBase64Url(response.attestationObject),
      clientDataJSON: toBase64Url(response.clientDataJSON),
      transports: typeof response.getTransports === "function" ? response.getTransports() : [],
      userAgent: userAgent || ""
    };
  }

  function assertionPayload(credential) {
    var response = credential.response;
    return {
      rawId: toBase64Url(credential.rawId),
      authenticatorData: toBase64Url(response.authenticatorData),
      clientDataJSON: toBase64Url(response.clientDataJSON),
      signature: toBase64Url(response.signature),
      userHandle: response.userHandle ? toBase64Url(response.userHandle) : null
    };
  }

  function supported() {
    return (
      typeof window !== "undefined" &&
      typeof window.PublicKeyCredential === "function" &&
      typeof navigator !== "undefined" &&
      !!navigator.credentials
    );
  }

  function markUnsupported(el, selector) {
    el.setAttribute("data-passkey-unsupported", "");
    el.querySelectorAll(selector).forEach(function (button) {
      button.classList.add("hidden");
    });
  }

  // A cancelled prompt and an aborted suggestion are not failures to report.
  function quietError(error) {
    return error && (error.name === "AbortError" || error.name === "NotAllowedError");
  }

  var PasskeySignIn = {
    mounted() {
      this.controller = null;

      if (!supported()) {
        markUnsupported(this.el, "[data-passkey-sign-in]");
        return;
      }

      this.onClick = (event) => {
        if (!event.target.closest("[data-passkey-sign-in]")) return;
        event.preventDefault();
        this.start(false);
      };

      this.el.addEventListener("click", this.onClick);
      this.resumeSuggestions();
    },

    start(conditional) {
      this.abort();
      var controller = new AbortController();
      this.controller = controller;

      this.pushEvent("passkey_options", {}, async (reply) => {
        if (!reply || !reply.options || controller.signal.aborted) return;

        try {
          var request = { publicKey: requestOptions(reply.options), signal: controller.signal };
          if (conditional) request.mediation = "conditional";

          var credential = await navigator.credentials.get(request);
          if (controller.signal.aborted || !credential) return;

          var payload = assertionPayload(credential);
          // The page's "Keep me logged in" box, when the site offers one.
          var selector = this.el.getAttribute("data-remember-me");
          var remember = selector ? document.querySelector(selector) : null;
          payload.remember_me = remember && remember.checked ? "true" : "false";
          this.pushEvent("passkey_sign_in", payload);
        } catch (error) {
          if (controller.signal.aborted) return;
          if (!quietError(error)) this.pushEvent("passkey_failed", {});
          if (!conditional) this.resumeSuggestions();
        }
      });
    },

    async resumeSuggestions() {
      var conditional = window.PublicKeyCredential.isConditionalMediationAvailable;
      if (typeof conditional !== "function") return;

      var controller = this.controller;
      try {
        var available = await conditional.call(window.PublicKeyCredential);
        if (available && !this.destroyedAt && this.controller === controller) this.start(true);
      } catch (_error) {
        // The explicit sign-in button still works when suggestions are unavailable.
      }
    },

    abort() {
      if (this.controller) {
        this.controller.abort();
        this.controller = null;
      }
    },

    disconnected() {
      this.abort();
    },

    reconnected() {
      if (supported()) this.resumeSuggestions();
    },

    destroyed() {
      this.destroyedAt = Date.now();
      this.abort();
      if (this.onClick) this.el.removeEventListener("click", this.onClick);
    }
  };

  var PasskeyRegister = {
    mounted() {
      this.controller = null;

      if (!supported()) {
        markUnsupported(this.el, "[data-passkey-register]");
        return;
      }

      this.onClick = (event) => {
        if (!event.target.closest("[data-passkey-register]")) return;
        event.preventDefault();
        this.register();
      };

      this.el.addEventListener("click", this.onClick);
    },

    register() {
      if (this.controller) return;
      var controller = new AbortController();
      this.controller = controller;

      this.pushEventTo(this.el, "passkey_registration_options", {}, async (reply) => {
        try {
          if (!reply || !reply.options || controller.signal.aborted) return;

          var credential = await navigator.credentials.create({
            publicKey: creationOptions(reply.options),
            signal: controller.signal
          });
          if (controller.signal.aborted || !credential) return;

          this.pushEventTo(
            this.el,
            "passkey_register",
            registrationPayload(credential, navigator.userAgent)
          );
        } catch (error) {
          if (!controller.signal.aborted) {
            this.pushEventTo(this.el, "passkey_register_failed", {
              name: quietError(error) ? "cancelled" : "failed"
            });
          }
        } finally {
          if (this.controller === controller) this.controller = null;
        }
      });
    },

    disconnected() {
      if (this.controller) this.controller.abort();
      this.controller = null;
    },

    destroyed() {
      this.disconnected();
      if (this.onClick) this.el.removeEventListener("click", this.onClick);
    }
  };

  if (typeof window !== "undefined") {
    window.PhoenixKitHooks = window.PhoenixKitHooks || {};
    window.PhoenixKitHooks.PasskeySignIn = PasskeySignIn;
    window.PhoenixKitHooks.PasskeyRegister = PasskeyRegister;
  }

  // Exported for the Node test harness (test/js); harmless in a browser.
  if (typeof module === "object" && module.exports) {
    module.exports.passkeyToBase64Url = toBase64Url;
    module.exports.passkeyFromBase64Url = fromBase64Url;
    module.exports.passkeyCreationOptions = creationOptions;
    module.exports.passkeyRequestOptions = requestOptions;
    module.exports.passkeyRegistrationPayload = registrationPayload;
    module.exports.passkeyAssertionPayload = assertionPayload;
  }
})();

// ---------------------------------------------------------------------------
// phoenix_kit:set_input
//
// Lets a LiveView put a value into an input it cannot re-render: the sign-up
// form is a temporary assign (it holds the typed password), so taking the
// "Did you mean ...@gmail.com?" hint sets the email field here and fires the
// field's own input event, which sends the whole form back through its
// phx-change. `push_event(socket, "phoenix_kit:set_input", %{id:, value:})`.
//
// A field with `phx-debounce="blur"` holds that change until it loses focus,
// and the person who clicked the hint is no longer in it: a blur is fired too,
// so the change goes now instead of at the submit.
// ---------------------------------------------------------------------------
if (typeof window !== "undefined" && !(window.__pkBundleLoads > 1)) {
  window.addEventListener("phx:phoenix_kit:set_input", function (event) {
    var detail = event.detail || {};
    var el = typeof detail.id === "string" ? document.getElementById(detail.id) : null;
    if (!el || !("value" in el) || typeof detail.value !== "string") return;
    el.value = detail.value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    if (el.getAttribute("phx-debounce") === "blur" && document.activeElement !== el) {
      el.dispatchEvent(new Event("blur"));
    }
  });
}

// ---------------------------------------------------------------------------
// Turnstile
//
// The Cloudflare Turnstile widget of a public form
// (`PhoenixKitWeb.Components.Core.TurnstileWidget`, `PhoenixKit.Users.Turnstile`).
// Loads Cloudflare's script once, on the first page that has a widget, and
// renders into the hook element, which sits inside the form with
// `phx-update="ignore"`: the script adds the hidden `cf-turnstile-response`
// field there and the form's submit carries it. A token is good for one
// verification, so the server asks for a new one after each submit it checked
// (`phoenix_kit:turnstile_reset`).
//
// If the script cannot load (blocked, offline, a Content-Security-Policy
// without challenges.cloudflare.com), the element gets `data-turnstile-failed`
// and shows the sentence the server put in `data-failed-text`. Without it the
// visitor saw an empty box, and every submit answered "wait for the
// verification to finish" about a verification that was never going to start.
// ---------------------------------------------------------------------------
(function () {
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  var SCRIPT_URL = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
  var loading = null;

  function loadTurnstile() {
    if (window.turnstile) return Promise.resolve(window.turnstile);
    if (loading) return loading;

    loading = new Promise(function (resolve, reject) {
      var script = document.createElement("script");
      script.src = SCRIPT_URL;
      script.async = true;
      script.defer = true;
      script.onload = function () {
        if (window.turnstile) resolve(window.turnstile);
        else { loading = null; reject(new Error("Turnstile did not initialise")); }
      };
      script.onerror = function () {
        loading = null;
        script.remove();
        reject(new Error("Turnstile could not be loaded"));
      };
      document.head.appendChild(script);
    });

    return loading;
  }

  // A daisyUI modal keeps its contents in the DOM while closed. Rendering
  // into that box sizes the widget at nothing and it fails. Wait until the
  // toggle that opens the modal is checked. A widget that is already on
  // screen renders immediately.
  function closedModalToggle(el) {
    var modal = el.closest(".modal");
    if (!modal || !modal.previousElementSibling) return null;
    var toggle = modal.previousElementSibling;
    if (toggle.classList && toggle.classList.contains("modal-toggle") && !toggle.checked) {
      return toggle;
    }
    return null;
  }

  function renderWidget(self, turnstile) {
    self.widgetId = turnstile.render(self.el, {
      sitekey: self.el.dataset.sitekey,
      theme: "auto",
      size: "flexible"
    });
  }

  function markFailed(el) {
    el.setAttribute("data-turnstile-failed", "");
    var text = el.dataset.failedText;
    if (text) {
      el.setAttribute("role", "alert");
      el.textContent = text;
    }
  }

  var Turnstile = {
    mounted() {
      var self = this;
      this.widgetId = null;
      this.gone = false;
      this._openToggle = null;
      this._onOpen = null;

      loadTurnstile().then(function (turnstile) {
        // The page may have been left while the script was loading.
        if (self.gone || !self.el.isConnected) return;
        var toggle = closedModalToggle(self.el);
        if (toggle) {
          self._openToggle = toggle;
          self._onOpen = function () {
            if (!toggle.checked || self.gone || !self.el.isConnected || self.widgetId !== null) return;
            toggle.removeEventListener("change", self._onOpen);
            self._onOpen = null;
            renderWidget(self, turnstile);
          };
          toggle.addEventListener("change", self._onOpen);
          return;
        }
        // "flexible": as wide as the form (at least 300px) instead of the
        // widget's fixed 300px, which left it short of every field above it.
        renderWidget(self, turnstile);
      }).catch(function () {
        if (self.gone || !self.el.isConnected) return;
        markFailed(self.el);
      });

      this.handleEvent("phoenix_kit:turnstile_reset", function () {
        if (self.widgetId !== null && window.turnstile) {
          try { window.turnstile.reset(self.widgetId); } catch (_err) { /* already gone */ }
        }
      });
    },

    destroyed() {
      this.gone = true;
      if (this._onOpen && this._openToggle) {
        this._openToggle.removeEventListener("change", this._onOpen);
      }
      this._onOpen = null;
      this._openToggle = null;
      if (this.widgetId !== null && window.turnstile) {
        try { window.turnstile.remove(this.widgetId); } catch (_err) { /* already gone */ }
      }
      this.widgetId = null;
    }
  };

  if (typeof window !== "undefined") {
    window.PhoenixKitHooks = window.PhoenixKitHooks || {};
    window.PhoenixKitHooks.Turnstile = Turnstile;
  }
})();

// ===========================================================================
// PhoenixKitHooks bridge — adopts any hooks exposed by sibling libraries
// (fresco, tessera, etcher) into the single `window.PhoenixKitHooks`
// namespace the parent app spreads into LiveSocket.
//
// Default setup (zero-config): the FrescoViewer / TesseraLayer /
// EtcherLayer wrapper hooks above lazy-load the host's vendored copies of
// the sibling libs on first mount, so the parent app only needs to spread
// `...window.PhoenixKitHooks` into LiveSocket:
//
//   let liveSocket = new LiveSocket("/live", Socket, {
//     hooks: { ...window.PhoenixKitHooks, ...colocatedHooks }
//   });
//
// Optional pre-import (for offline / CSP-strict / pre-bundled apps):
// import the libs in your own `app.js` before phoenix_kit.js and the
// wrappers will detect `window.{Fresco|Tessera|Etcher}Hooks` and skip
// the CDN load:
//
//   import "../../deps/fresco/priv/static/fresco.js"
//   import "../../deps/tessera/priv/static/tessera.js"
//   import "../../deps/etcher/priv/static/etcher.js"
//
// The `adopt` calls below are a defensive backstop for any sibling hook
// the wrappers above don't explicitly cover (e.g. a future hook added by
// one of the libs). No-ops when the global is missing.
// ===========================================================================
(function() {
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  if (typeof window === "undefined") return;
  window.PhoenixKitHooks = window.PhoenixKitHooks || {};

  function adopt(src) {
    if (!src) return;
    Object.keys(src).forEach(function(name) {
      if (!window.PhoenixKitHooks[name]) {
        window.PhoenixKitHooks[name] = src[name];
      }
    });
  }

  adopt(window.FrescoHooks);
  adopt(window.TesseraHooks);
  adopt(window.EtcherHooks);
})();

// ---------------------------------------------------------------------------
// PkChartCrosshair — the client half of `line_chart hover={:crosshair}`
// (PhoenixKitWeb.Components.Core.Chart). The server sends the rows once and
// one entry per datum, already positioned and formatted:
//
//   {rows: [[label, colour]], points: [[left%, right%, x%, y%, x_label,
//    y_label, note, [row index]]]}
//
// so this only finds the entry under the pointer (or the keyboard's) and
// places the crosshair, the dot and the readout. The hook sits on a
// pointer-events-none layer and listens on the chart wrapper (its parent),
// because a style it set on its own element would be dropped by the next
// patch.
(function () {
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  if (typeof window === "undefined") return;
  window.PhoenixKitHooks = window.PhoenixKitHooks || {};

  var STYLE_ID = "pk-chart-crosshair-style";

  // The native per-point tooltips are the no-JavaScript readout; once the
  // hook runs they would show on top of the crosshair's, so turn them off.
  function ensureStyle() {
    if (typeof document === "undefined" || document.getElementById(STYLE_ID)) return;
    var style = document.createElement("style");
    style.id = STYLE_ID;
    if (window.PhoenixKitInternals && window.PhoenixKitInternals.adoptStyle) {
      window.PhoenixKitInternals.adoptStyle(style);
    }
    style.textContent = "[data-pk-crosshair] svg rect[data-x]{pointer-events:none}";
    document.head.appendChild(style);
  }

  // The entry whose band holds `pct` (0–100 across the chart), or -1 where
  // no datum stands (left of the first point of a step series).
  function crosshairPick(points, pct) {
    if (!points || !points.length) return -1;
    for (var i = 0; i < points.length; i++) {
      if (pct >= points[i][0] && pct < points[i][1]) return i;
    }
    // The right edge itself belongs to the last band.
    var last = points[points.length - 1];
    if (pct >= last[1] && pct <= 100) return points.length - 1;
    return -1;
  }

  // Which side of the line the readout goes: right of it, unless that would
  // run off the chart.
  function crosshairTipSide(xPct) {
    return xPct > 55 ? "left" : "right";
  }

  // The entry a key moves to from `current` (-1 = nothing shown), or null
  // for a key the chart does not handle.
  function crosshairStep(key, current, count) {
    if (!count) return null;
    switch (key) {
      case "ArrowRight":
        return current < 0 ? 0 : Math.min(current + 1, count - 1);
      case "ArrowLeft":
        return current < 0 ? count - 1 : Math.max(current - 1, 0);
      case "Home":
        return 0;
      case "End":
        return count - 1;
      default:
        return null;
    }
  }

  // The readout as plain text, for the live region.
  function crosshairText(point, rows) {
    var parts = [];
    if (point[4]) parts.push(point[4]);
    parts.push(point[5]);
    if (point[6]) parts.push(point[6]);
    (point[7] || []).forEach(function (i) {
      if (rows[i]) parts.push(rows[i][0]);
    });
    return parts.join(", ");
  }

  function line(tag, text, className) {
    var el = document.createElement(tag);
    el.textContent = text;
    if (className) el.className = className;
    return el;
  }

  window.PhoenixKitHooks.PkChartCrosshair = {
    mounted() {
      ensureStyle();
      this.host = this.el.parentElement;
      this.lineEl = this.el.querySelector("[data-crosshair-line]");
      this.dotEl = this.el.querySelector("[data-crosshair-dot]");
      this.tipEl = this.el.querySelector("[data-crosshair-tip]");
      this.liveEl = this.el.querySelector("[data-crosshair-live]");
      this.shown = -1;

      this.onMove = (event) => this.showAt(event.clientX);
      this.onDown = (event) => {
        this.pinned = event.pointerType === "touch";
        this.showAt(event.clientX);
      };
      // A finger lifting fires pointerleave at once; a tapped readout stays
      // up until a tap elsewhere.
      this.onLeave = (event) => {
        if (!(event && event.pointerType === "touch" && this.pinned)) this.hide();
      };
      this.onCancel = () => this.hide();
      this.onOutside = (event) => {
        if (this.shown >= 0 && !this.host.contains(event.target)) this.hide();
      };
      this.onKey = (event) => {
        if (event.key === "Escape") {
          if (this.shown >= 0) {
            this.hide();
            event.stopPropagation();
          }
          return;
        }
        var next = crosshairStep(event.key, this.shown, this.data().points.length);
        if (next === null) return;
        event.preventDefault();
        this.show(next, true);
      };
      this.onBlur = () => this.hide();

      this.host.addEventListener("pointermove", this.onMove);
      this.host.addEventListener("pointerdown", this.onDown);
      this.host.addEventListener("pointerleave", this.onLeave);
      this.host.addEventListener("pointercancel", this.onCancel);
      this.host.addEventListener("keydown", this.onKey);
      this.host.addEventListener("blur", this.onBlur);
      document.addEventListener("pointerdown", this.onOutside);
    },

    updated() {
      // New data: the entry on screen may be gone or moved.
      this.cache = null;
      this.hide();
    },

    data() {
      if (!this.cache) {
        try {
          var parsed = JSON.parse(this.el.dataset.points || "{}");
          this.cache = { rows: parsed.rows || [], points: parsed.points || [] };
        } catch (_err) {
          this.cache = { rows: [], points: [] };
        }
      }
      return this.cache;
    },

    showAt(clientX) {
      var rect = this.host.getBoundingClientRect();
      if (!rect.width) return;
      var i = crosshairPick(this.data().points, ((clientX - rect.left) / rect.width) * 100);
      if (i < 0) return this.hide();
      this.show(i, false);
    },

    show(i, announce) {
      if (i === this.shown) return;
      this.shown = i;
      var data = this.data();
      var p = data.points[i];

      this.lineEl.style.left = p[2] + "%";
      this.dotEl.style.left = p[2] + "%";
      this.dotEl.style.top = p[3] + "%";

      var tip = this.tipEl;
      tip.replaceChildren();
      if (p[4]) tip.appendChild(line("div", p[4], "opacity-70"));
      tip.appendChild(line("div", p[5], "font-semibold"));
      if (p[6]) tip.appendChild(line("div", p[6], "opacity-70"));
      (p[7] || []).forEach(function (index) {
        var row = data.rows[index];
        if (!row) return;
        var el = line("div", "", "flex items-center gap-1.5");
        var swatch = document.createElement("span");
        swatch.className = "inline-block w-2 h-2 rounded-full bg-current";
        if (row[1]) swatch.style.background = row[1];
        el.appendChild(swatch);
        el.appendChild(document.createTextNode(row[0]));
        tip.appendChild(el);
      });

      tip.style.left = p[2] + "%";
      tip.style.transform =
        crosshairTipSide(p[2]) === "right" ? "translateX(8px)" : "translateX(calc(-100% - 8px))";

      this.lineEl.hidden = false;
      this.dotEl.hidden = false;
      tip.hidden = false;
      // Only a keyboard step is announced; a pointer sweeping across the
      // chart would queue one announcement per band.
      if (announce && this.liveEl) this.liveEl.textContent = crosshairText(p, data.rows);
    },

    hide() {
      this.shown = -1;
      this.pinned = false;
      if (this.lineEl) this.lineEl.hidden = true;
      if (this.dotEl) this.dotEl.hidden = true;
      if (this.tipEl) this.tipEl.hidden = true;
    },

    destroyed() {
      document.removeEventListener("pointerdown", this.onOutside);
      if (!this.host) return;
      this.host.removeEventListener("pointermove", this.onMove);
      this.host.removeEventListener("pointerdown", this.onDown);
      this.host.removeEventListener("pointerleave", this.onLeave);
      this.host.removeEventListener("pointercancel", this.onCancel);
      this.host.removeEventListener("keydown", this.onKey);
      this.host.removeEventListener("blur", this.onBlur);
    }
  };

  // Exported for the Node test harness (test/js); harmless in a browser.
  if (typeof module === "object" && module.exports) {
    module.exports.crosshairPick = crosshairPick;
    module.exports.crosshairTipSide = crosshairTipSide;
    module.exports.crosshairStep = crosshairStep;
    module.exports.crosshairText = crosshairText;
  }
})();

// ---------------------------------------------------------------------------
// PHOTO GALLERY — the client half of `<.photo_gallery>`
// (PhoenixKitWeb.Components.Core.PhotoGallery).
//
// Delegated, not a hook: the component renders on controller pages too.
//
//   [data-pk-gallery-root]            one gallery (its id is the gallery's)
//   [data-pk-gallery-open="2"]        a click opens photo 2 (inside the root,
//                                     or anywhere with data-pk-gallery="<id>")
//   "pk:photo-gallery-open" event     on the root, detail {index}
//                                     (PhotoGallery.open/3, a JS.dispatch)
//   "phx:pk:photo-gallery-open"       push_event(socket, …, %{id:, index:})
//
// The lightbox is a native <dialog> (showModal: the page behind is inert, so
// the focus cannot leave it). What moves — the strip of slides, a zoomed
// photo, the drag-down — is style on elements under a phx-update="ignore"
// container, so a LiveView patch never undoes it. Every listener of an open
// gallery is added on open and removed on close.
// ---------------------------------------------------------------------------
(function () {
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  if (typeof window === "undefined") return;

  var SWIPE_COMMIT = 0.25;   // of the width, to settle on a neighbour
  var FLICK = 0.35;          // px/ms — a quick flick settles too
  var DISMISS_COMMIT = 0.18; // of the height, to close by dragging down
  var DISMISS_FLICK = 0.5;   // px/ms
  var AXIS_SLOP = 8;         // px before a drag picks a direction
  var TAP_SLOP = 10;         // px a tap may wander
  var DOUBLE_TAP_MS = 300;
  var DOUBLE_TAP_SCALE = 2.5;
  var EASE = "cubic-bezier(0.22, 0.8, 0.25, 1)";
  var SLIDE_MS = 300;

  // ── Pure helpers (exported for test/js/photo_gallery.test.cjs) ─────────

  function galleryClamp(index, count) {
    if (!(count > 0)) return 0;
    index = Math.round(Number(index) || 0);
    return Math.max(0, Math.min(count - 1, index));
  }

  // "x" or "y" once the pointer has moved past the slop, else null.
  function galleryAxis(dx, dy, slop) {
    var ax = Math.abs(dx), ay = Math.abs(dy);
    if (Math.max(ax, ay) < (slop == null ? AXIS_SLOP : slop)) return null;
    return ax >= ay ? "x" : "y";
  }

  // Past the first or the last photo the strip gives way only a little.
  function galleryRubber(dx, index, count) {
    if ((index <= 0 && dx > 0) || (index >= count - 1 && dx < 0)) return dx * 0.35;
    return dx;
  }

  // Where a horizontal drag of dx px (negative: towards the next photo),
  // let go at vx px/ms, settles.
  function gallerySwipeTarget(index, count, dx, vx, width) {
    var far = Math.abs(dx) > (width || 1) * SWIPE_COMMIT;
    var flick = Math.abs(vx) > FLICK && Math.abs(dx) > TAP_SLOP && (vx < 0) === (dx < 0);
    if (!far && !flick) return galleryClamp(index, count);
    return galleryClamp(index + (dx < 0 ? 1 : -1), count);
  }

  // Whether a downward drag of dy px, let go at vy px/ms, closes the lightbox.
  function galleryDismiss(dy, vy, height) {
    if (dy <= 0) return false;
    return dy > (height || 1) * DISMISS_COMMIT || (vy > DISMISS_FLICK && dy > 30);
  }

  // The backdrop fades as the photo is dragged away.
  function galleryDismissOpacity(dy, height) {
    var h = height || 1;
    return Math.max(0.15, 1 - Math.abs(dy) / (h * 0.6));
  }

  // A zoom {scale, x, y} (x, y: px the photo's centre is moved) kept so the
  // photo, `w` × `h` at scale 1, covers what it can of a `vw` × `vh` box.
  function galleryClampPan(z, w, h, vw, vh) {
    var maxX = Math.max(0, (w * z.scale - vw) / 2);
    var maxY = Math.max(0, (h * z.scale - vh) / 2);
    return {
      scale: z.scale,
      x: Math.max(-maxX, Math.min(maxX, z.x)),
      y: Math.max(-maxY, Math.min(maxY, z.y))
    };
  }

  // Zoom to `scale` (clamped to 1…max) keeping the point (px, py) — measured
  // from the photo's unzoomed centre — under the pointer.
  function galleryZoomAt(z, scale, px, py, max) {
    var s = Math.max(1, Math.min(max || 4, scale));
    var k = s / z.scale;
    if (s === 1) return { scale: 1, x: 0, y: 0 };
    return { scale: s, x: px - (px - z.x) * k, y: py - (py - z.y) * k };
  }

  function galleryWheelScale(scale, deltaY, deltaMode) {
    var per = deltaMode === 1 ? 0.05 : deltaMode === 2 ? 0.5 : 0.002;
    var d = Math.max(-300, Math.min(300, deltaY));
    return scale * Math.exp(-d * per);
  }

  function galleryDoubleTapScale(scale, max) {
    return scale > 1.01 ? 1 : Math.min(DOUBLE_TAP_SCALE, max || 4);
  }

  // What a key does; ← and → swap on a right-to-left page.
  function galleryKeyAction(key, rtl) {
    switch (key) {
      case "ArrowLeft": return rtl ? "next" : "prev";
      case "ArrowRight": return rtl ? "prev" : "next";
      case "Home": return "first";
      case "End": return "last";
      case "+": case "=": return "zoomIn";
      case "-": case "_": return "zoomOut";
      case "0": return "reset";
      default: return null;
    }
  }

  // The photos to load now: the one shown and its neighbours.
  function galleryNeighbours(index, count) {
    var out = [];
    for (var i = index - 1; i <= index + 1; i++) if (i >= 0 && i < count) out.push(i);
    return out;
  }

  function galleryFormat(template, n, count) {
    return String(template || "{n} / {count}").replace("{n}", n).replace("{count}", count);
  }

  if (typeof module === "object" && module.exports) {
    module.exports.photoGallery = {
      clamp: galleryClamp, axis: galleryAxis, rubber: galleryRubber,
      swipeTarget: gallerySwipeTarget, dismiss: galleryDismiss,
      dismissOpacity: galleryDismissOpacity, clampPan: galleryClampPan,
      zoomAt: galleryZoomAt, wheelScale: galleryWheelScale,
      doubleTapScale: galleryDoubleTapScale, keyAction: galleryKeyAction,
      neighbours: galleryNeighbours, format: galleryFormat
    };
  }

  if (typeof document === "undefined" || !document.addEventListener) return;

  // ── The lightbox ────────────────────────────────────────────────────────

  function reducedMotion() {
    return !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }

  function isRtl(el) {
    var d = el && el.closest && el.closest("[dir]");
    return !!d && String(d.getAttribute("dir")).toLowerCase() === "rtl";
  }

  function Gallery(root) {
    this.root = root;
    this.index = 0;
    this.z = { scale: 1, x: 0, y: 0 };
    this.pointers = {};
    this.gesture = null;
    this.lastTap = null;
    this.opener = null;
    this.listeners = null;
  }

  Gallery.prototype.parts = function() {
    var dialog = this.root.querySelector("[data-pk-gallery-dialog]");
    var stage = dialog && dialog.querySelector("[data-pk-gallery-stage]");
    if (!stage) return null;
    return {
      dialog: dialog,
      stage: stage,
      viewport: stage.querySelector("[data-pk-gallery-viewport]"),
      track: stage.querySelector("[data-pk-gallery-track]"),
      backdrop: stage.querySelector("[data-pk-gallery-backdrop]"),
      slides: stage.querySelectorAll("[data-pk-gallery-slide]"),
      count: stage.querySelectorAll("[data-pk-gallery-slide]").length
    };
  };

  Gallery.prototype.maxZoom = function() {
    var m = parseFloat(this.root.getAttribute("data-pk-gallery-max-zoom"));
    return m >= 1 ? m : 4;
  };

  Gallery.prototype.open = function(index, opener) {
    var p = this.parts();
    if (!p || !p.count) return;
    this.p = p;
    this.opener = opener || document.activeElement;
    this.rtl = isRtl(this.root);
    if (!p.dialog.open) {
      if (typeof p.dialog.showModal === "function") p.dialog.showModal();
      else p.dialog.setAttribute("open", "");
      this.bind();
    }
    this.go(index, false);
    var close = p.stage.querySelector("[data-pk-gallery-close]");
    if (close && close.focus) close.focus({ preventScroll: true });
  };

  Gallery.prototype.bind = function() {
    var self = this, p = this.p;
    var ctl = typeof AbortController === "function" ? new AbortController() : null;
    var list = [];
    function on(el, type, fn, opts) {
      if (!el) return;
      opts = opts || {};
      if (ctl) opts.signal = ctl.signal;
      el.addEventListener(type, fn, opts);
      list.push([el, type, fn, opts]);
    }
    on(p.viewport, "pointerdown", function(e) { self.down(e); });
    on(p.viewport, "pointermove", function(e) { self.move(e); });
    on(p.viewport, "pointerup", function(e) { self.up(e); });
    on(p.viewport, "pointercancel", function(e) { self.up(e, true); });
    on(p.viewport, "wheel", function(e) { self.wheel(e); }, { passive: false });
    on(p.viewport, "dragstart", function(e) { e.preventDefault(); });
    on(p.stage, "click", function(e) { self.click(e); });
    on(p.dialog, "keydown", function(e) { self.key(e); });
    // Esc: the dialog's own cancel. Closed however it was: tidy up.
    on(p.dialog, "close", function() { self.closed(); });
    on(window, "resize", function() { if (!self.gone()) self.resized(); });
    // Removed while open (a live navigation or a patch) fires no `close`:
    // watch for the dialog leaving the page and tidy up then.
    var mo = null;
    if (typeof MutationObserver === "function" && document.body) {
      mo = new MutationObserver(function() { self.gone(); });
      mo.observe(document.body, { childList: true, subtree: true });
    }
    this.listeners = { ctl: ctl, list: list, mo: mo };
  };

  // True (and the lightbox torn down) once its dialog is no longer in the page.
  Gallery.prototype.gone = function() {
    var d = this.p && this.p.dialog;
    if (!d || d.isConnected !== false) return false;
    this.closed();
    return true;
  };

  Gallery.prototype.unbind = function() {
    var l = this.listeners;
    this.listeners = null;
    if (!l) return;
    if (l.mo) l.mo.disconnect();
    if (l.ctl) { l.ctl.abort(); return; }
    l.list.forEach(function(x) { x[0].removeEventListener(x[1], x[2], x[3]); });
  };

  Gallery.prototype.close = function() {
    var p = this.p;
    if (p && p.dialog.open && typeof p.dialog.close === "function") p.dialog.close();
    else this.closed();
  };

  Gallery.prototype.closed = function() {
    this.unbind();
    this.resetZoom(false);
    this.dragY(0, false);
    this.pointers = {};
    this.gesture = null;
    if (this.p && this.p.dialog.hasAttribute("open") && typeof this.p.dialog.close !== "function") {
      this.p.dialog.removeAttribute("open");
    }
    var back = this.opener;
    this.opener = null;
    if (back && back.isConnected !== false && back.focus) back.focus({ preventScroll: true });
  };

  Gallery.prototype.width = function() {
    return (this.p && this.p.viewport && this.p.viewport.clientWidth) || window.innerWidth || 1;
  };

  Gallery.prototype.height = function() {
    return (this.p && this.p.viewport && this.p.viewport.clientHeight) || window.innerHeight || 1;
  };

  Gallery.prototype.transition = function(el, animate, prop) {
    el.style.transition = animate && !reducedMotion() ? (prop || "transform") + " " + SLIDE_MS + "ms " + EASE : "none";
  };

  Gallery.prototype.layout = function(animate, offset) {
    var t = this.p && this.p.track;
    if (!t) return;
    this.transition(t, animate);
    var x = -this.index * this.width() + (offset || 0);
    t.style.transform = "translate3d(" + x + "px,0,0)";
  };

  // A new viewport: the strip moves with it and a zoomed photo is kept
  // within the new bounds (the old pan could leave it off-screen).
  Gallery.prototype.resized = function() {
    this.layout(false);
    if (this.z.scale > 1) this.applyZoom(this.z, false);
  };

  Gallery.prototype.go = function(index, animate) {
    var p = this.p;
    if (!p) return;
    var next = galleryClamp(index, p.count);
    var changed = next !== this.index;
    if (changed) this.resetZoom(false);
    this.index = next;
    this.layout(animate !== false);
    var near = galleryNeighbours(next, p.count);
    p.slides.forEach(function(slide, i) {
      var on = i === next;
      if (on) { slide.removeAttribute("aria-hidden"); slide.removeAttribute("inert"); }
      else { slide.setAttribute("aria-hidden", "true"); slide.setAttribute("inert", ""); }
      if (near.indexOf(i) !== -1) {
        var img = slide.querySelector("img");
        if (img && img.getAttribute("loading") === "lazy") img.setAttribute("loading", "eager");
      }
    });
    p.stage.setAttribute("data-index", String(next));
    p.stage.querySelectorAll("[data-pk-gallery-caption],[data-pk-gallery-actions]").forEach(function(el) {
      var i = parseInt(el.getAttribute("data-pk-gallery-caption") || el.getAttribute("data-pk-gallery-actions"), 10);
      el.hidden = i !== next;
    });
    var counter = p.stage.querySelector("[data-pk-gallery-counter]");
    if (counter) counter.textContent = galleryFormat(counter.getAttribute("data-template"), next + 1, p.count);
    var prev = p.stage.querySelector("[data-pk-gallery-prev]");
    var fwd = p.stage.querySelector("[data-pk-gallery-next]");
    if (prev) prev.disabled = next === 0;
    if (fwd) fwd.disabled = next === p.count - 1;
    var live = p.stage.querySelector("[data-pk-gallery-live]");
    if (live && changed) live.textContent = p.slides[next].getAttribute("aria-label") || "";
  };

  Gallery.prototype.img = function() {
    var slide = this.p && this.p.slides[this.index];
    return slide && slide.querySelector("[data-pk-gallery-img]");
  };

  // The photo's size at scale 1 and its unzoomed centre on screen.
  Gallery.prototype.base = function() {
    var img = this.img();
    if (!img) return null;
    var r = img.getBoundingClientRect();
    var s = this.z.scale;
    return {
      w: r.width / s, h: r.height / s,
      cx: r.left + r.width / 2 - this.z.x, cy: r.top + r.height / 2 - this.z.y
    };
  };

  Gallery.prototype.applyZoom = function(z, animate) {
    var img = this.img();
    var b = this.base();
    if (b) z = galleryClampPan(z, b.w, b.h, this.width(), this.height());
    this.z = z;
    if (!img) return;
    this.transition(img, animate);
    img.style.transform = z.scale === 1 ? "" : "translate3d(" + z.x + "px," + z.y + "px,0) scale(" + z.scale + ")";
    img.style.cursor = z.scale > 1 ? "grab" : "";
  };

  Gallery.prototype.zoomTo = function(scale, clientX, clientY, animate) {
    var b = this.base();
    if (!b) return;
    var px = clientX == null ? 0 : clientX - b.cx;
    var py = clientY == null ? 0 : clientY - b.cy;
    this.applyZoom(galleryZoomAt(this.z, scale, px, py, this.maxZoom()), animate);
  };

  Gallery.prototype.resetZoom = function(animate) {
    var img = this.img();
    this.z = { scale: 1, x: 0, y: 0 };
    if (img) { this.transition(img, animate); img.style.transform = ""; img.style.cursor = ""; }
  };

  Gallery.prototype.dragY = function(dy, animate) {
    var p = this.p;
    if (!p) return;
    var slide = p.slides[this.index];
    var box = slide && slide.querySelector("[data-pk-gallery-zoom]");
    if (box) {
      this.transition(box, animate);
      box.style.transform = dy ? "translate3d(0," + dy + "px,0) scale(" + (1 - Math.min(0.25, Math.abs(dy) / (this.height() * 3))) + ")" : "";
    }
    if (p.backdrop) {
      this.transition(p.backdrop, animate, "opacity");
      p.backdrop.style.opacity = dy ? String(galleryDismissOpacity(dy, this.height())) : "";
    }
  };

  // ── Pointers ────────────────────────────────────────────────────────────

  function dist(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }
  function mid(a, b) { return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }; }
  function pts(map) { return Object.keys(map).map(function(k) { return map[k]; }); }

  Gallery.prototype.down = function(e) {
    if (e.button && e.button !== 0) return;
    if (e.target && e.target.closest && e.target.closest("a,button,input,textarea,select,label")) return;
    this.pointers[e.pointerId] = { x: e.clientX, y: e.clientY };
    try { this.p.viewport.setPointerCapture(e.pointerId); } catch (_) { /* not capturable */ }
    var list = pts(this.pointers);
    var now = e.timeStamp || Date.now();
    if (list.length >= 2) {
      var c = mid(list[0], list[1]);
      this.layout(false);
      this.dragY(0, false);
      this.gesture = { kind: "pinch", d0: dist(list[0], list[1]) || 1, c0: c, z0: this.z, base: this.base() };
    } else {
      this.gesture = {
        kind: "drag", axis: null, x0: e.clientX, y0: e.clientY, t0: now,
        lx: e.clientX, ly: e.clientY, lt: now, vx: 0, vy: 0, z0: this.z,
        onImg: !!(e.target && e.target.closest && e.target.closest("[data-pk-gallery-img]")),
        moved: false
      };
    }
  };

  Gallery.prototype.move = function(e) {
    if (!this.pointers[e.pointerId]) return;
    this.pointers[e.pointerId] = { x: e.clientX, y: e.clientY };
    var g = this.gesture;
    if (!g) return;
    e.preventDefault();
    if (g.kind === "pinch") {
      var list = pts(this.pointers);
      if (list.length < 2 || !g.base) return;
      var c = mid(list[0], list[1]);
      var scale = g.z0.scale * dist(list[0], list[1]) / g.d0;
      var z = galleryZoomAt(g.z0, scale, g.c0.x - g.base.cx, g.c0.y - g.base.cy, this.maxZoom());
      z.x += c.x - g.c0.x;
      z.y += c.y - g.c0.y;
      if (z.scale === 1) { z.x = 0; z.y = 0; }
      this.applyZoom(z, false);
      return;
    }
    var now = e.timeStamp || Date.now();
    var dt = Math.max(1, now - g.lt);
    g.vx = (e.clientX - g.lx) / dt;
    g.vy = (e.clientY - g.ly) / dt;
    g.lx = e.clientX; g.ly = e.clientY; g.lt = now;
    var dx = e.clientX - g.x0, dy = e.clientY - g.y0;
    if (Math.abs(dx) > TAP_SLOP || Math.abs(dy) > TAP_SLOP) g.moved = true;
    if (g.z0.scale > 1) {
      this.applyZoom({ scale: g.z0.scale, x: g.z0.x + dx, y: g.z0.y + dy }, false);
      return;
    }
    if (!g.axis) g.axis = galleryAxis(dx, dy);
    if (g.axis === "x") this.layout(false, galleryRubber(dx, this.index, this.p.count));
    else if (g.axis === "y") this.dragY(dy > 0 ? dy : dy * 0.2, false);
  };

  Gallery.prototype.up = function(e, cancelled) {
    if (!this.pointers[e.pointerId]) return;
    delete this.pointers[e.pointerId];
    var g = this.gesture;
    if (!g) return;
    if (g.kind === "pinch") {
      // One finger stays down: nothing more until both are lifted.
      if (pts(this.pointers).length) { this.gesture = null; return; }
      this.gesture = null;
      if (this.z.scale < 1.02) this.resetZoom(true);
      return;
    }
    this.gesture = null;
    var dx = e.clientX - g.x0, dy = e.clientY - g.y0;
    if (cancelled) { this.layout(true); this.dragY(0, true); return; }
    if (g.axis === "x" && g.z0.scale === 1) {
      this.go(gallerySwipeTarget(this.index, this.p.count, dx, g.vx, this.width()), true);
      this.suppressClick = true;
      return;
    }
    if (g.axis === "y" && g.z0.scale === 1) {
      this.suppressClick = true;
      if (galleryDismiss(dy, g.vy, this.height())) this.close();
      else this.dragY(0, true);
      return;
    }
    if (g.moved) { this.suppressClick = true; return; }
    // A tap: twice on the photo zooms there, once beside it closes.
    var now = e.timeStamp || Date.now();
    var last = this.lastTap;
    if (g.onImg) {
      if (last && now - last.t < DOUBLE_TAP_MS && Math.hypot(e.clientX - last.x, e.clientY - last.y) < TAP_SLOP * 3) {
        this.lastTap = null;
        this.zoomTo(galleryDoubleTapScale(this.z.scale, this.maxZoom()), e.clientX, e.clientY, true);
      } else {
        this.lastTap = { t: now, x: e.clientX, y: e.clientY };
      }
    } else if (this.z.scale === 1) {
      this.close();
    }
  };

  Gallery.prototype.wheel = function(e) {
    e.preventDefault();
    this.zoomTo(galleryWheelScale(this.z.scale, e.deltaY, e.deltaMode), e.clientX, e.clientY, false);
  };

  Gallery.prototype.click = function(e) {
    var t = e.target;
    if (this.suppressClick) { this.suppressClick = false; if (t && t.closest && t.closest("[data-pk-gallery-viewport]")) return; }
    if (!t || !t.closest) return;
    if (t.closest("[data-pk-gallery-close]")) { e.preventDefault(); this.close(); }
    else if (t.closest("[data-pk-gallery-prev]")) { e.preventDefault(); this.go(this.index - 1, true); }
    else if (t.closest("[data-pk-gallery-next]")) { e.preventDefault(); this.go(this.index + 1, true); }
  };

  Gallery.prototype.key = function(e) {
    var t = e.target;
    if (t && t.closest && t.closest("input,textarea,select,[contenteditable]")) return;
    if (e.altKey || e.ctrlKey || e.metaKey) return;
    var a = galleryKeyAction(e.key, this.rtl);
    if (!a) return;
    e.preventDefault();
    if (a === "prev") this.go(this.index - 1, true);
    else if (a === "next") this.go(this.index + 1, true);
    else if (a === "first") this.go(0, true);
    else if (a === "last") this.go(this.p.count - 1, true);
    else if (a === "zoomIn") this.zoomTo(this.z.scale * 1.5, null, null, true);
    else if (a === "zoomOut") this.zoomTo(this.z.scale / 1.5, null, null, true);
    else if (a === "reset") this.resetZoom(true);
  };

  function galleryFor(root) {
    if (!root) return null;
    if (!root._pkGallery) root._pkGallery = new Gallery(root);
    return root._pkGallery;
  }

  function rootOf(el) {
    if (!el || !el.closest) return null;
    var named = el.getAttribute && el.getAttribute("data-pk-gallery");
    if (named) {
      var r = document.getElementById(named);
      if (r && r.hasAttribute("data-pk-gallery-root")) return r;
    }
    return el.closest("[data-pk-gallery-root]");
  }

  document.addEventListener("click", function(e) {
    var btn = e.target && e.target.closest && e.target.closest("[data-pk-gallery-open]");
    if (!btn) return;
    var g = galleryFor(rootOf(btn));
    if (!g) return;
    e.preventDefault();
    g.open(parseInt(btn.getAttribute("data-pk-gallery-open"), 10) || 0, btn);
  });

  document.addEventListener("pk:photo-gallery-open", function(e) {
    var g = galleryFor(e.target && e.target.closest && e.target.closest("[data-pk-gallery-root]"));
    if (g) g.open((e.detail && parseInt(e.detail.index, 10)) || 0, document.activeElement);
  });

  window.addEventListener("phx:pk:photo-gallery-open", function(e) {
    var id = e.detail && e.detail.id;
    var root = typeof id === "string" && id ? document.getElementById(id) : null;
    if (root && root.hasAttribute("data-pk-gallery-root")) {
      galleryFor(root).open(parseInt(e.detail.index, 10) || 0, document.activeElement);
    }
  });
})();

// ---------------------------------------------------------------------------
// PkUploadEdit — `<.file_upload edit_images>`: crop, turn and flip a photo
// in the browser before it is uploaded.
//
// The hook wraps the live file input (and its drop zone). A selection or a
// drop is taken in the capture phase, before LiveView's window listeners see
// it; each JPEG/PNG/WebP is shown in the dialog the component rendered; the
// results go to LiveView through the hook's `upload(name, files)`, as if the
// person had chosen them. Anything else goes up untouched.
//
// The crop geometry (`imageEditorRect`) is the stored-image editor's
// (ImageEditor in phoenix_kit_admin.js reads it from PhoenixKitInternals).
// ---------------------------------------------------------------------------
(function () {
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  if (typeof window === "undefined") return;
  window.PhoenixKitHooks = window.PhoenixKitHooks || {};

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

  window.PhoenixKitInternals = window.PhoenixKitInternals || {};
  window.PhoenixKitInternals.imageEditorRect = imageEditorRect;

  // ── Pure helpers (exported for test/js/upload_edit.test.cjs) ───────────

  var EDITABLE = ["image/jpeg", "image/png", "image/webp"];
  // Every dialog button but Remove: off while a photo decodes.
  var EDIT_CONTROLS = "[data-pk-edit-rotate],[data-pk-edit-flip],[data-pk-edit-aspect]," +
    "[data-pk-edit-reset],[data-pk-edit-original],[data-pk-edit-apply]";

  function uploadEditable(file) {
    return !!file && EDITABLE.indexOf(String(file.type).toLowerCase()) !== -1;
  }

  // A quarter turn more (dir 90) or less (-90), kept in 0…270.
  function uploadEditRotate(rotation, dir) {
    return (((rotation + dir) % 360) + 360) % 360;
  }

  // The stored turn after the person turns the picture on screen by `dir`
  // (90 = clockwise). The transform mirrors after it turns, and a mirror
  // reverses a turn, so with the mirror on the stored turn goes the other
  // way: what is shown always turns the way the button says.
  function uploadEditTurn(rotation, flip, dir) {
    return uploadEditRotate(rotation, flip ? -dir : dir);
  }

  // The picture's size once turned.
  function uploadEditDims(w, h, rotation) {
    return rotation === 90 || rotation === 270 ? [h, w] : [w, h];
  }

  // The canvas transform drawing a `w` × `h` source turned `rotation`
  // degrees clockwise, mirrored when `flip`, at `scale`, with the frame's
  // point (ox, oy) — in turned, unscaled pixels — at the canvas origin.
  function uploadEditMatrix(w, h, rotation, flip, scale, ox, oy) {
    var m;
    if (rotation === 90) m = [0, 1, -1, 0, h, 0];
    else if (rotation === 180) m = [-1, 0, 0, -1, w, h];
    else if (rotation === 270) m = [0, -1, 1, 0, 0, w];
    else m = [1, 0, 0, 1, 0, 0];
    if (flip) {
      var W = uploadEditDims(w, h, rotation)[0];
      m = [-m[0], m[1], -m[2], m[3], W - m[4], m[5]];
    }
    var s = scale || 1;
    return [m[0] * s, m[1] * s, m[2] * s, m[3] * s, (m[4] - (ox || 0)) * s, (m[5] - (oy || 0)) * s];
  }

  // A crop in percent of the turned frame as whole pixels inside it; the
  // whole frame when there is none (or it is too small to mean anything).
  function uploadEditCropPixels(rect, W, H) {
    if (!rect || rect.w < 0.5 || rect.h < 0.5) return { x: 0, y: 0, w: W, h: H };
    var x = clamp(Math.round(rect.x / 100 * W), 0, W - 1);
    var y = clamp(Math.round(rect.y / 100 * H), 0, H - 1);
    var w = clamp(Math.round(rect.w / 100 * W), 1, W - x);
    var h = clamp(Math.round(rect.h / 100 * H), 1, H - y);
    return { x: x, y: y, w: w, h: h };
  }

  // The largest crop of `aspect` ([w, h]) centred in a `W` × `H` frame, in percent.
  function uploadEditCenteredCrop(aspect, W, H) {
    if (!aspect) return null;
    var ratio = aspect[0] / aspect[1];
    var w = W, h = W / ratio;
    if (h > H) { h = H; w = H * ratio; }
    var pw = w / W * 100, ph = h / H * 100;
    return { x: (100 - pw) / 2, y: (100 - ph) / 2, w: pw, h: ph };
  }

  function uploadEditAspect(value) {
    if (!value) return null;
    var parts = String(value).split("/").map(Number);
    return parts.length === 2 && parts[0] > 0 && parts[1] > 0 ? parts : null;
  }

  // Whether an `accept` attribute ("" when none) lets a PNG through.
  function uploadEditAcceptsPng(accept) {
    var list = String(accept || "").split(",").map(function (x) { return x.trim().toLowerCase(); }).filter(Boolean);
    if (!list.length) return true;
    return list.some(function (x) { return x === ".png" || x === "image/png" || x === "image/*" || x === "*/*"; });
  }

  // What the encoded edit goes up as — {type, name} — or null when it cannot
  // go up: no blob (a canvas too large to encode), or a type other than the
  // one asked for. A browser without a WebP encoder answers PNG; that PNG is
  // the edit, so it goes up named .png when the input accepts PNG.
  function uploadEditEncoded(blob, type, name, accept) {
    if (!blob) return null;
    if (!blob.type || blob.type === type) return { type: type, name: name };
    if (type === "image/webp" && blob.type === "image/png" && uploadEditAcceptsPng(accept)) {
      var base = String(name || "photo").replace(/\.[^./\\]*$/, "");
      return { type: "image/png", name: (base || "photo") + ".png" };
    }
    return null;
  }

  // Whether anything was changed at all: an unchanged photo goes up as it was.
  function uploadEditChanged(state) {
    return !!state && (state.rotation !== 0 || !!state.flip || !!(state.crop && state.crop.w >= 0.5 && state.crop.h >= 0.5));
  }

  if (typeof module === "object" && module.exports) {
    module.exports.imageEditorRect = imageEditorRect;
    module.exports.uploadEdit = {
      editable: uploadEditable, rotate: uploadEditRotate, turn: uploadEditTurn, dims: uploadEditDims,
      matrix: uploadEditMatrix, cropPixels: uploadEditCropPixels,
      centeredCrop: uploadEditCenteredCrop, aspect: uploadEditAspect,
      changed: uploadEditChanged, encoded: uploadEditEncoded, acceptsPng: uploadEditAcceptsPng
    };
  }

  // ── The hook ────────────────────────────────────────────────────────────

  window.PhoenixKitHooks.PkUploadEdit = {
    mounted() {
      var self = this;
      this._queue = [];
      this._done = [];
      this._passing = false;

      // A selection from the file chooser.
      this._onInput = function (e) {
        if (self._passing) return;
        var input = e.target;
        if (!input || input.type !== "file" || !self.el.contains(input)) return;
        e.stopPropagation();
        var files = Array.prototype.slice.call(input.files || []);
        // The same selection fires `input` and then `change`; take it once.
        try { input.value = ""; } catch (_) { /* read-only in old browsers */ }
        if (files.length) self._take(files);
      };
      // A drop on the drop zone, before LiveView tracks it.
      this._onDrop = function (e) {
        var zone = e.target && e.target.closest && e.target.closest("[phx-drop-target],[data-phx-drop-target]");
        var files = e.dataTransfer && e.dataTransfer.files;
        if (!zone || !files || !files.length) return;
        e.preventDefault();
        e.stopPropagation();
        zone.classList.remove("phx-drop-target-active");
        self._take(Array.prototype.slice.call(files));
      };

      this.el.addEventListener("input", this._onInput, true);
      this.el.addEventListener("change", this._onInput, true);
      this.el.addEventListener("drop", this._onDrop, true);
      this._bindDialog();
    },

    destroyed() {
      this.el.removeEventListener("input", this._onInput, true);
      this.el.removeEventListener("change", this._onInput, true);
      this.el.removeEventListener("drop", this._onDrop, true);
      this._release();
    },

    _input() {
      return this.el.querySelector('input[type="file"]');
    },

    _take(files) {
      var input = this._input();
      // Several files on a single-entry input (a drop: the chooser cannot
      // pick more than one): hand LiveView the whole drop, unedited, so its
      // max_entries rule rejects it with :too_many_files as it would
      // without the editor, instead of quietly keeping only the first.
      if (input && !input.hasAttribute("multiple") && files.length > 1) {
        this._handOver(files);
        return;
      }
      this._queue = this._queue.concat(files);
      if (!this._current) this._next();
    },

    _next() {
      while (this._queue.length && !uploadEditable(this._queue[0])) this._done.push(this._queue.shift());
      if (!this._queue.length) {
        this._closeDialog();
        this._send();
        return;
      }
      this._edit(this._queue.shift());
    },

    _send() {
      var files = this._done;
      this._done = [];
      this._handOver(files);
    },

    _handOver(files) {
      if (!files.length) return;
      this._passing = true;
      try {
        this.upload(this.el.dataset.uploadName, files);
      } finally {
        this._passing = false;
      }
    },

    _dialog() {
      return this.el.querySelector("[data-pk-edit-dialog]");
    },

    _bindDialog() {
      var self = this;
      var d = this._dialog();
      if (!d || d._pkUploadEdit) return;
      d._pkUploadEdit = true;
      d.addEventListener("click", function (e) {
        var t = e.target && e.target.closest ? e.target.closest("button") : null;
        if (!t || !self._current) return;
        e.preventDefault();
        // Until the photo shown is the current one, only Remove works: the
        // dialog may still show the previous photo.
        if (!self._img && !t.hasAttribute("data-pk-edit-skip")) return;
        var s = self._state;
        if (!t.hasAttribute("data-pk-edit-apply") && !t.hasAttribute("data-pk-edit-original") &&
          !t.hasAttribute("data-pk-edit-skip")) self._failed(false);
        if (t.hasAttribute("data-pk-edit-rotate")) {
          s.rotation = uploadEditTurn(s.rotation, s.flip, parseInt(t.getAttribute("data-pk-edit-rotate"), 10) || 0);
          s.crop = null;
          self._draw();
          if (s.aspect) self._setCrop(uploadEditCenteredCrop(s.aspect, self._frame[0], self._frame[1]));
        } else if (t.hasAttribute("data-pk-edit-flip")) {
          s.flip = !s.flip;
          t.setAttribute("aria-pressed", String(s.flip));
          if (s.crop) s.crop = { x: 100 - s.crop.x - s.crop.w, y: s.crop.y, w: s.crop.w, h: s.crop.h };
          self._draw();
        } else if (t.hasAttribute("data-pk-edit-aspect")) {
          s.aspect = uploadEditAspect(t.getAttribute("data-pk-edit-aspect"));
          d.querySelectorAll("[data-pk-edit-aspect]").forEach(function (b) {
            b.setAttribute("aria-pressed", String(b === t));
          });
          self._setCrop(uploadEditCenteredCrop(s.aspect, self._frame[0], self._frame[1]));
        } else if (t.hasAttribute("data-pk-edit-reset")) {
          self._resetState();
          self._draw();
        } else if (t.hasAttribute("data-pk-edit-skip")) {
          self._finish(null);
        } else if (t.hasAttribute("data-pk-edit-original")) {
          self._finish(self._current);
        } else if (t.hasAttribute("data-pk-edit-apply")) {
          self._apply();
        }
      });
      // Esc closes the dialog: the photo is not uploaded (nothing goes up
      // that the person did not confirm).
      d.addEventListener("cancel", function (e) {
        e.preventDefault();
        if (self._current) self._finish(null);
      });

      var frame = d.querySelector("[data-pk-edit-frame]");
      if (!frame) return;
      frame.addEventListener("pointerdown", function (e) {
        if (!self._current || !self._img || (e.button && e.button !== 0)) return;
        e.preventDefault();
        self._box = frame.getBoundingClientRect();
        self._start = self._point(e);
        try { frame.setPointerCapture(e.pointerId); } catch (_) { /* not capturable */ }
      });
      frame.addEventListener("pointermove", function (e) {
        if (!self._start) return;
        self._showCrop(self._rectTo(self._point(e)));
      });
      var end = function (e) {
        if (!self._start) return;
        var rect = self._rectTo(self._point(e));
        self._start = null;
        // A click, not a drag: keep what was there.
        if (rect.w < 0.5 || rect.h < 0.5) { self._showCrop(self._state.crop); return; }
        self._setCrop(rect);
      };
      frame.addEventListener("pointerup", end);
      frame.addEventListener("pointercancel", function () {
        self._start = null;
        self._showCrop(self._state && self._state.crop);
      });
    },

    _point(e) {
      var b = this._box;
      return { x: (e.clientX - b.left) / b.width * 100, y: (e.clientY - b.top) / b.height * 100 };
    },

    _rectTo(end) {
      return imageEditorRect(this._start, end, this._state.aspect, this._frame);
    },

    _setCrop(rect) {
      this._state.crop = rect;
      this._showCrop(rect);
    },

    _showCrop(rect) {
      var d = this._dialog();
      var box = d && d.querySelector("[data-pk-edit-crop]");
      if (!box) return;
      if (!rect || rect.w < 0.5 || rect.h < 0.5) { box.hidden = true; return; }
      box.hidden = false;
      box.style.left = rect.x + "%";
      box.style.top = rect.y + "%";
      box.style.width = rect.w + "%";
      box.style.height = rect.h + "%";
    },

    _resetState() {
      this._state = { rotation: 0, flip: false, crop: null, aspect: null };
      var d = this._dialog();
      if (!d) return;
      d.querySelectorAll("[data-pk-edit-aspect]").forEach(function (b) {
        b.setAttribute("aria-pressed", String(b.getAttribute("data-pk-edit-aspect") === ""));
      });
      var flip = d.querySelector("[data-pk-edit-flip]");
      if (flip) flip.setAttribute("aria-pressed", "false");
    },

    _edit(file) {
      var self = this;
      var d = this._dialog();
      if (!d || typeof URL === "undefined" || !URL.createObjectURL) {
        this._done.push(file);
        this._next();
        return;
      }
      this._current = file;
      this._img = null;
      this._failed(false);
      this._resetState();
      this._loading(true);
      var name = d.querySelector("[data-pk-edit-name]");
      if (name) name.textContent = file.name || "";
      var progress = d.querySelector("[data-pk-edit-progress]");
      if (progress) {
        var total = this._done.length + this._queue.length + 1;
        progress.textContent = total > 1 ? (this._done.length + 1) + " / " + total : "";
      }
      this._release();
      this._url = URL.createObjectURL(file);
      var img = new Image();
      img.onload = function () {
        if (self._current !== file) return;
        self._img = img;
        self._loading(false);
        self._draw();
        if (!d.open && typeof d.showModal === "function") d.showModal();
      };
      // A picture the browser cannot draw goes up as it is.
      img.onerror = function () {
        if (self._current === file) self._finish(file);
      };
      img.src = this._url;
    },

    // While the next photo decodes: the previous preview is cleared and
    // everything but Remove is disabled, so nothing is confirmed unseen.
    _loading(on) {
      var d = this._dialog();
      if (!d) return;
      d.querySelectorAll(EDIT_CONTROLS).forEach(function (b) { b.disabled = on; });
      var frame = d.querySelector("[data-pk-edit-frame]");
      if (frame && frame.setAttribute) frame.setAttribute("aria-busy", String(on));
      if (!on) return;
      this._showCrop(null);
      var canvas = d.querySelector("[data-pk-edit-canvas]");
      var ctx = canvas && canvas.getContext && canvas.getContext("2d");
      if (ctx) {
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.clearRect(0, 0, canvas.width, canvas.height);
      }
    },

    // The preview: the whole turned frame, fitted to at most 1600px across.
    _draw() {
      var d = this._dialog();
      var canvas = d && d.querySelector("[data-pk-edit-canvas]");
      var img = this._img;
      if (!canvas || !img) return;
      var s = this._state;
      var dims = uploadEditDims(img.naturalWidth, img.naturalHeight, s.rotation);
      this._frame = dims;
      var scale = Math.min(1, 1600 / Math.max(dims[0], dims[1]));
      canvas.width = Math.max(1, Math.round(dims[0] * scale));
      canvas.height = Math.max(1, Math.round(dims[1] * scale));
      var ctx = canvas.getContext("2d");
      var m = uploadEditMatrix(img.naturalWidth, img.naturalHeight, s.rotation, s.flip, scale, 0, 0);
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.setTransform(m[0], m[1], m[2], m[3], m[4], m[5]);
      ctx.drawImage(img, 0, 0);
      this._showCrop(s.crop);
    },

    _apply() {
      var self = this;
      var file = this._current, img = this._img, s = this._state;
      if (!img) return;
      if (!uploadEditChanged(s)) { this._finish(file); return; }
      var dims = uploadEditDims(img.naturalWidth, img.naturalHeight, s.rotation);
      var c = uploadEditCropPixels(s.crop, dims[0], dims[1]);
      var out = document.createElement("canvas");
      out.width = c.w;
      out.height = c.h;
      var ctx = out.getContext("2d");
      var m = uploadEditMatrix(img.naturalWidth, img.naturalHeight, s.rotation, s.flip, 1, c.x, c.y);
      ctx.setTransform(m[0], m[1], m[2], m[3], m[4], m[5]);
      ctx.drawImage(img, 0, 0);
      var type = file.type === "image/png" || file.type === "image/webp" ? file.type : "image/jpeg";
      var input = this._input();
      var accept = input && input.getAttribute ? input.getAttribute("accept") : "";
      out.toBlob(function (blob) {
        if (self._current !== file) return;
        var as = uploadEditEncoded(blob, type, file.name, accept);
        // Not saved: say so, and let the person choose Upload original or
        // Remove rather than dropping the edit without a word.
        if (!as) { self._failed(true); return; }
        var edited;
        try {
          edited = new File([blob], as.name, { type: as.type, lastModified: Date.now() });
        } catch (_) {
          edited = blob;
          edited.name = as.name;
        }
        self._finish(edited);
      }, type, 0.92);
    },

    // The "could not save the edit" message, with Upload off while it shows
    // (another change — a smaller crop — may encode, and turns it back on).
    _failed(on) {
      var d = this._dialog();
      if (!d) return;
      var msg = d.querySelector("[data-pk-edit-error]");
      if (msg) msg.hidden = !on;
      var apply = d.querySelector("[data-pk-edit-apply]");
      if (apply) apply.disabled = on;
    },

    _finish(result) {
      this._failed(false);
      if (result) this._done.push(result);
      this._current = null;
      this._img = null;
      this._release();
      this._next();
    },

    _closeDialog() {
      var d = this._dialog();
      if (d && d.open && typeof d.close === "function") d.close();
    },

    _release() {
      if (this._url && typeof URL !== "undefined" && URL.revokeObjectURL) URL.revokeObjectURL(this._url);
      this._url = null;
    }
  };
})();

// ---------------------------------------------------------------------------
// FormDraft — opt-in drafts of a form's fields in the browser
// (PhoenixKitWeb.Components.Core.FormDraft, `<.simple_form draft>`).
//
//   data-draft-key        what it is stored under (default: path + form id)
//   data-draft-storage    "local" (default) | "session"
//   data-draft-exclude    "name,other" — never stored
//   data-draft-ttl        seconds a draft is offered for
//   data-draft-event      ask the server first: {restore: true|false} or {}
//
// Saved (debounced) on input/change, offered back on mount through the bar
// `<.form_draft_bar>` renders, cleared when a submitted form leaves the page
// or the server pushes "pk:form-draft" {id, action: "clear"}.
// ---------------------------------------------------------------------------
(function () {
  if (typeof window !== "undefined" && window.__pkBundleLoads > 1) return;
  if (typeof window === "undefined") return;
  window.PhoenixKitHooks = window.PhoenixKitHooks || {};

  var PREFIX = "pk:draft:";
  var SAVE_MS = 400;
  var SKIP_TYPES = ["password", "hidden", "file", "submit", "button", "reset", "image"];

  // ── Pure helpers (exported for test/js/form_draft.test.cjs) ────────────

  function draftExcludeList(value) {
    return String(value || "").split(",").map(function (s) { return s.trim(); }).filter(Boolean);
  }

  // "email" matches "email" and "user[email]"; "user[email]" only itself.
  function draftNameExcluded(name, exclude) {
    for (var i = 0; i < exclude.length; i++) {
      var x = exclude[i];
      if (name === x) return true;
      if (x.indexOf("[") === -1 && new RegExp("\\[" + x.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\](\\[\\])?$").test(name)) return true;
    }
    return false;
  }

  function draftEligible(el, exclude) {
    if (!el || !el.name || el.disabled) return false;
    var tag = String(el.tagName || "").toUpperCase();
    if (tag !== "INPUT" && tag !== "TEXTAREA" && tag !== "SELECT") return false;
    var type = String(el.type || "").toLowerCase();
    if (SKIP_TYPES.indexOf(type) !== -1) return false;
    if (el.name.charAt(0) === "_" || /csrf/i.test(el.name)) return false;
    if (el.hasAttribute && el.hasAttribute("data-draft-skip")) return false;
    return !draftNameExcluded(el.name, exclude || []);
  }

  // {name: value}: a string, or a list for checkboxes and multiple selects.
  function draftSerialize(elements, exclude) {
    var out = {};
    for (var i = 0; i < elements.length; i++) {
      var el = elements[i];
      if (!draftEligible(el, exclude)) continue;
      var type = String(el.type || "").toLowerCase();
      if (type === "checkbox") {
        if (!Array.isArray(out[el.name])) out[el.name] = [];
        if (el.checked) out[el.name].push(el.value == null ? "on" : String(el.value));
      } else if (type === "radio") {
        if (!(el.name in out)) out[el.name] = null;
        if (el.checked) out[el.name] = String(el.value);
      } else if (type === "select-multiple" || (String(el.tagName).toUpperCase() === "SELECT" && el.multiple)) {
        var vals = [];
        for (var j = 0; j < el.options.length; j++) if (el.options[j].selected) vals.push(String(el.options[j].value));
        out[el.name] = vals;
      } else {
        out[el.name] = el.value == null ? "" : String(el.value);
      }
    }
    return out;
  }

  function draftEqual(a, b) {
    return JSON.stringify(sortKeys(a || {})) === JSON.stringify(sortKeys(b || {}));
  }

  function sortKeys(o) {
    var out = {};
    Object.keys(o).sort().forEach(function (k) { out[k] = o[k]; });
    return out;
  }

  // Puts `fields` back; returns the elements whose value changed.
  function draftApply(elements, fields, exclude) {
    var changed = [];
    for (var i = 0; i < elements.length; i++) {
      var el = elements[i];
      if (!draftEligible(el, exclude) || !Object.prototype.hasOwnProperty.call(fields, el.name)) continue;
      var v = fields[el.name];
      var type = String(el.type || "").toLowerCase();
      if (type === "checkbox") {
        var on = Array.isArray(v) && v.indexOf(el.value == null ? "on" : String(el.value)) !== -1;
        if (el.checked !== on) { el.checked = on; changed.push(el); }
      } else if (type === "radio") {
        var pick = v === String(el.value);
        if (el.checked !== pick) { el.checked = pick; changed.push(el); }
      } else if (type === "select-multiple" || (String(el.tagName).toUpperCase() === "SELECT" && el.multiple)) {
        var any = false;
        for (var j = 0; j < el.options.length; j++) {
          var sel = Array.isArray(v) && v.indexOf(String(el.options[j].value)) !== -1;
          if (el.options[j].selected !== sel) { el.options[j].selected = sel; any = true; }
        }
        if (any) changed.push(el);
      } else if (typeof v === "string" && el.value !== v) {
        el.value = v;
        changed.push(el);
      }
    }
    return changed;
  }

  function draftKey(pathname, formId, key) {
    return PREFIX + (key ? String(key) : String(pathname || "") + "#" + String(formId || ""));
  }

  // A stored draft, or null when it is missing, unreadable or too old.
  function draftParse(raw, now, ttlSeconds) {
    if (!raw) return null;
    var d;
    try { d = JSON.parse(raw); } catch (_) { return null; }
    if (!d || d.v !== 1 || typeof d.t !== "number" || !d.fields || typeof d.fields !== "object") return null;
    var ttl = ttlSeconds > 0 ? ttlSeconds * 1000 : 7 * 24 * 3600 * 1000;
    if (now - d.t > ttl || d.t > now + 60000) return null;
    return d;
  }

  if (typeof module === "object" && module.exports) {
    module.exports.formDraft = {
      excludeList: draftExcludeList, nameExcluded: draftNameExcluded,
      eligible: draftEligible, serialize: draftSerialize, equal: draftEqual,
      apply: draftApply, key: draftKey, parse: draftParse
    };
  }

  // ── The hook ────────────────────────────────────────────────────────────

  function store(kind) {
    try {
      var s = kind === "session" ? window.sessionStorage : window.localStorage;
      return s || null;
    } catch (_) {
      return null;
    }
  }

  window.PhoenixKitHooks.FormDraft = {
    mounted() {
      var self = this;
      this._exclude = draftExcludeList(this.el.dataset.draftExclude);
      this._key = draftKey(window.location && window.location.pathname, this.el.id, this.el.dataset.draftKey);
      this._store = store(this.el.dataset.draftStorage);
      this._initial = this._snapshot();
      this._pending = null;
      this._submitted = false;

      this._onEdit = function (e) {
        if (!e.target || !draftEligible(e.target, self._exclude)) return;
        // Typing after a submit means that submit did not end the editing.
        self._submitted = false;
        clearTimeout(self._timer);
        self._timer = setTimeout(function () { self._save(); }, SAVE_MS);
      };
      this._onSubmit = function () {
        self._save();
        self._submitted = true;
      };
      this.el.addEventListener("input", this._onEdit);
      this.el.addEventListener("change", this._onEdit);
      this.el.addEventListener("submit", this._onSubmit);

      this._onBar = function (e) {
        var t = e.target && e.target.closest && e.target.closest("[data-pk-draft-restore],[data-pk-draft-discard]");
        if (!t) return;
        e.preventDefault();
        if (t.hasAttribute("data-pk-draft-restore")) self._restore();
        else self._discard();
      };
      this._bar = this._findBar();
      if (this._bar) this._bar.addEventListener("click", this._onBar);

      this.handleEvent("pk:form-draft", function (p) {
        if (!p || p.id !== self.el.id) return;
        if (p.action === "clear" || p.action === "discard") self._discard();
        else if (p.action === "restore") self._restore();
      });

      this._offer();
    },

    destroyed() {
      clearTimeout(this._timer);
      this.el.removeEventListener("input", this._onEdit);
      this.el.removeEventListener("change", this._onEdit);
      this.el.removeEventListener("submit", this._onSubmit);
      if (this._bar) this._bar.removeEventListener("click", this._onBar);
      // Submitted and gone: the save went through (a failed one re-renders
      // the form in place). A form that leaves unsubmitted keeps its draft.
      if (this._submitted) this._remove();
    },

    _findBar() {
      var id = this.el.id;
      return this.el.querySelector('[data-pk-draft-bar="' + id + '"]') ||
        (id ? document.getElementById(id + "-draft-bar") : null);
    },

    _snapshot() {
      return draftSerialize(this.el.elements || [], this._exclude);
    },

    _read() {
      if (!this._store) return null;
      var raw = null;
      try { raw = this._store.getItem(this._key); } catch (_) { return null; }
      var d = draftParse(raw, Date.now(), parseInt(this.el.dataset.draftTtl, 10));
      if (!d && raw) this._remove();
      return d;
    },

    _save() {
      if (!this._store || this._pending) return;
      var fields = this._snapshot();
      if (draftEqual(fields, this._initial)) { this._remove(); return; }
      try {
        this._store.setItem(this._key, JSON.stringify({ v: 1, t: Date.now(), fields: fields }));
      } catch (_) { /* full or blocked: no draft */ }
    },

    _remove() {
      if (!this._store) return;
      try { this._store.removeItem(this._key); } catch (_) { /* blocked */ }
    },

    _offer() {
      var self = this;
      var d = this._read();
      if (!d) return;
      if (draftEqual(d.fields, this._initial)) { this._remove(); return; }
      this._pending = d;
      var event = this.el.dataset.draftEvent;
      if (event) {
        this.pushEvent(event, { id: this.el.id, saved_at: d.t, fields: Object.keys(d.fields) }, function (reply) {
          if (!self._pending) return;
          if (reply && reply.restore === true) self._restore();
          else if (reply && reply.restore === false) self._discard();
          else self._prompt(true);
        });
      } else {
        this._prompt(true);
      }
    },

    _prompt(show) {
      var p = this._bar && this._bar.querySelector("[data-pk-draft-prompt]");
      if (p) p.hidden = !show;
    },

    _restore() {
      var d = this._pending || this._read();
      this._pending = null;
      this._prompt(false);
      if (!d) return;
      var changed = draftApply(this.el.elements || [], d.fields, this._exclude);
      // One input event: LiveView sends the whole form to phx-change.
      if (changed.length && typeof Event === "function") {
        changed[0].dispatchEvent(new Event("input", { bubbles: true }));
      }
      this._save();
    },

    _discard() {
      this._pending = null;
      this._prompt(false);
      this._remove();
    }
  };
})();
