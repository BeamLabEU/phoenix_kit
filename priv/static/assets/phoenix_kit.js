/**
 * PhoenixKit JavaScript Bundle
 * ============================================================================
 *
 * A single self-contained file with all PhoenixKit JavaScript functionality.
 * Import directly from deps - updates automatically with package updates.
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
 * TABLE OF CONTENTS:
 * ============================================================================
 *   1. SORTABLE MODULE ................ Drag-and-drop grid reordering
 *   2. COOKIE CONSENT MODULE .......... GDPR/CCPA compliant consent management
 *   3. UTILITY HOOKS .................. ResetSelect, TimeAgo
 *
 * HOOKS PROVIDED:
 *   - SortableGrid .... Drag-and-drop reorderable grid/list
 *   - CookieConsent ... Cookie consent banner and preferences modal
 *   - ResetSelect ..... Reset select element to first option on event
 *   - TimeAgo ......... Client-side relative time updates
 *   - LanguageSwitcherSearch ... Client-side language filtering for dropdown
 *
 * @version 2.0.0
 * @license MIT
 */

(function() {
  "use strict";

  // Prevent double initialization
  if (window.PhoenixKitInitialized) return;
  window.PhoenixKitInitialized = true;

  // Initialize hooks collection
  window.PhoenixKitHooks = window.PhoenixKitHooks || {};


  // ============================================================================
  // 1. SORTABLE MODULE
  // ============================================================================
  //
  // Provides drag-and-drop reordering for grids and lists.
  // Auto-loads SortableJS from CDN when first used.
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

    var SORTABLE_CDN = "https://cdn.jsdelivr.net/npm/sortablejs@1.15.0/Sortable.min.js";
    var sortableLoading = false;
    var sortableCallbacks = [];
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
        ".sortable-drag { box-shadow: 0 10px 15px -3px rgba(0,0,0,0.1), 0 4px 6px -2px rgba(0,0,0,0.05); }"
      ].join("\n");
      document.head.appendChild(style);
    }

    // ---------------------------------------------------------------------------
    // CDN Loading
    // ---------------------------------------------------------------------------

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
        console.error("[PhoenixKit:SortableGrid] Failed to load SortableJS from CDN");
      };
      document.head.appendChild(script);
    }

    // ---------------------------------------------------------------------------
    // SortableGrid Hook
    // ---------------------------------------------------------------------------

    window.PhoenixKitHooks.SortableGrid = {
      mounted: function() {
        var self = this;
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

        injectStyles();

        this._itemCount = container.querySelectorAll(".sortable-item[data-id]").length;

        this.sortable = window.Sortable.create(container, {
          animation: 150,
          draggable: ".sortable-item",
          filter: ".sortable-ignore",
          forceFallback: true,
          fallbackOnBody: true,
          ghostClass: "sortable-ghost",
          chosenClass: "sortable-chosen",
          dragClass: "sortable-drag",
          onEnd: function(evt) {
            var items = container.querySelectorAll(".sortable-item[data-id]");
            var orderedIds = Array.from(items).map(function(el) {
              return el.dataset.id;
            });
            self.pushEvent(eventName, { ordered_ids: orderedIds });
          }
        });
      }
    };
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
      var meta = document.querySelector('meta[name="phoenix-kit-prefix"]');
      var prefix = meta ? meta.getAttribute("content") : "/phoenix_kit";
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
          if (attr.name !== "type" && attr.name !== "data-blocked") {
            newScript.setAttribute(attr.name, attr.value);
          }
        });
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

      // CSS Styles
      var styles = '<style>' +
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
        '.pk-toggle-thumb{background:var(--pk-bg);box-shadow:0 1px 3px oklch(var(--bc)/0.2)}' +
      '</style>';

      // Floating Icon (only shown in opt-in mode)
      var iconHTML = showIcon
        ? '<button id="pk-consent-icon" type="button" onclick="window.PhoenixKitConsent.openPreferences()" ' +
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
              '<button type="button" onclick="window.PhoenixKitConsent.openPreferences()" class="btn btn-ghost btn-sm" style="font-size:0.75rem">Customize</button>' +
              '<button type="button" onclick="window.PhoenixKitConsent.rejectAll()" class="btn btn-outline btn-sm" style="font-size:0.75rem">Reject</button>' +
              '<button type="button" onclick="window.PhoenixKitConsent.acceptAll()" class="btn btn-primary btn-sm" style="font-size:0.75rem">Accept All</button>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>';

      // Modal HTML
      var modalHTML = '<div id="pk-consent-modal" ' +
        'style="position:fixed;inset:0;z-index:100;display:none" ' +
        'role="dialog" aria-modal="true" aria-label="Cookie preferences">' +
        '<div class="pk-modal-backdrop" onclick="window.PhoenixKitConsent.closePreferences()" ' +
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
              '<button type="button" onclick="window.PhoenixKitConsent.closePreferences()" class="btn btn-ghost btn-sm btn-circle" aria-label="Close">' +
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
                  '<button type="button" onclick="window.PhoenixKitConsent.rejectAll()" class="btn btn-ghost btn-sm" style="font-size:0.75rem">Reject All</button>' +
                  '<button type="button" onclick="window.PhoenixKitConsent.savePreferences()" class="btn btn-primary btn-sm" style="font-size:0.75rem">Save Preferences</button>' +
                '</div>' +
              '</div>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>';

      return '<div id="pk-consent-root" class="pk-consent-widget">' +
        styles + iconHTML + bannerHTML + modalHTML +
      '</div>';
    }

    // ---------------------------------------------------------------------------
    // UI Show/Hide Functions
    // ---------------------------------------------------------------------------

    function injectWidget(config) {
      var existing = document.getElementById("pk-consent-root");
      if (existing) existing.remove();

      var container = document.createElement("div");
      container.innerHTML = createWidgetHTML(config);
      document.body.appendChild(container.firstChild);

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
      fetch(getConfigEndpoint(), { credentials: "same-origin" })
        .then(function(response) {
          if (!response.ok) {
            throw new Error("Config endpoint returned " + response.status);
          }
          return response.json();
        })
        .then(function(config) {
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
