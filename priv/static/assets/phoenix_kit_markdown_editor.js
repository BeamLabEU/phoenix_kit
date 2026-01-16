/**
 * PhoenixKit Markdown Editor JavaScript
 *
 * This file provides the JavaScript functionality for the MarkdownEditor
 * LiveComponent. It must be loaded once in your application for the editor
 * to work correctly with LiveView navigation.
 *
 * Include in your app.js:
 *   import "../../../deps/phoenix_kit/priv/static/assets/phoenix_kit_markdown_editor.js"
 *
 * Or via script tag in your layout:
 *   <script src={~p"/assets/phoenix_kit_markdown_editor.js"}></script>
 */
(function () {
  // Prevent multiple initializations
  if (window.PhoenixKitMarkdownEditor) return;
  window.PhoenixKitMarkdownEditor = true;

  // Global state for all markdown editors
  window.markdownEditors = window.markdownEditors || {};

  /**
   * Initialize a single markdown editor element
   * @param {HTMLElement} editorEl - The editor container element
   * @param {number} attempt - Retry attempt number
   */
  window.initMarkdownEditor = function (editorEl, attempt) {
    attempt = attempt || 0;
    var maxAttempts = 20;
    var editorId = editorEl.id;
    var globalId = editorEl.dataset.globalId;
    var textareaId = editorId + "-textarea";
    var protectNavigation = editorEl.dataset.protectNavigation === "true";

    var textarea = document.getElementById(textareaId);
    var warningEl = document.getElementById(editorId + "-js-warning");

    if (!textarea) {
      if (attempt >= maxAttempts) {
        console.error(
          "[MarkdownEditor] Failed to initialize:",
          editorId,
          "- textarea not found after",
          maxAttempts,
          "attempts"
        );
        // Show warning on failure
        if (warningEl) warningEl.classList.remove("hidden");
        return;
      }
      // Textarea not ready yet, retry shortly
      setTimeout(function () {
        window.initMarkdownEditor(editorEl, attempt + 1);
      }, 50);
      return;
    }

    // Check if already initialized with THIS EXACT textarea element
    var existing = window.markdownEditors[editorId];
    if (existing && existing.textarea === textarea && existing.initialized) {
      return;
    }

    // Clear any stale state
    if (existing) {
      // Editor was re-mounted, re-initialize
    }

    // Store state in namespaced object
    var state = {
      textarea: textarea,
      lastCursorPosition: 0,
      hasUnsavedChanges: false,
      initialized: true,
    };
    window.markdownEditors[editorId] = state;

    // Setup cursor tracking
    var events = ["blur", "select", "click", "keyup"];
    events.forEach(function (event) {
      textarea.addEventListener(event, function () {
        var s = window.markdownEditors[editorId];
        if (s) s.lastCursorPosition = textarea.selectionStart;
      });
    });

    // Auto-continue lists on Enter
    textarea.addEventListener("keydown", function (e) {
      if (e.key !== "Enter") return;

      var pos = textarea.selectionStart;
      var value = textarea.value;

      // Find current line
      var lineStart = value.lastIndexOf("\n", pos - 1) + 1;
      var lineEnd = value.indexOf("\n", pos);
      var currentLine = value.substring(
        lineStart,
        lineEnd === -1 ? value.length : lineEnd
      );

      // Check if cursor is at end of line
      var cursorInLine = pos - lineStart;
      if (cursorInLine < currentLine.length) return; // Cursor not at end, let default happen

      // Match bullet list: "  - text" or "  * text" or "  + text"
      var bulletMatch = currentLine.match(/^(\s*)(-|\*|\+)\s(.*)$/);
      if (bulletMatch) {
        e.preventDefault();
        var indent = bulletMatch[1];
        var marker = bulletMatch[2];
        var content = bulletMatch[3];

        if (content.trim() === "") {
          // Empty list item - remove marker
          var newValue = value.substring(0, lineStart) + value.substring(pos);
          textarea.value = newValue;
          textarea.selectionStart = textarea.selectionEnd = lineStart;
        } else {
          // Continue list
          var insertion = "\n" + indent + marker + " ";
          var newValue =
            value.substring(0, pos) + insertion + value.substring(pos);
          textarea.value = newValue;
          textarea.selectionStart = textarea.selectionEnd =
            pos + insertion.length;
        }
        var s = window.markdownEditors[editorId];
        if (s) s.lastCursorPosition = textarea.selectionStart;
        textarea.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true }));
        return;
      }

      // Match numbered list: "  1. text"
      var numberMatch = currentLine.match(/^(\s*)(\d+)\.\s(.*)$/);
      if (numberMatch) {
        e.preventDefault();
        var indent = numberMatch[1];
        var num = numberMatch[2];
        var content = numberMatch[3];

        if (content.trim() === "") {
          // Empty list item - remove marker
          var newValue = value.substring(0, lineStart) + value.substring(pos);
          textarea.value = newValue;
          textarea.selectionStart = textarea.selectionEnd = lineStart;
        } else {
          // Continue with next number
          var nextNum = parseInt(num, 10) + 1;
          var insertion = "\n" + indent + nextNum + ". ";
          var newValue =
            value.substring(0, pos) + insertion + value.substring(pos);
          textarea.value = newValue;
          textarea.selectionStart = textarea.selectionEnd =
            pos + insertion.length;
        }
        var s = window.markdownEditors[editorId];
        if (s) s.lastCursorPosition = textarea.selectionStart;
        textarea.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true }));
        return;
      }
    });

    // Register global insert function
    window["markdownEditorInsert_" + globalId] = function (text) {
      var s = window.markdownEditors[editorId];
      if (!s || !s.textarea) return;

      var start = s.lastCursorPosition || 0;
      var currentValue = s.textarea.value;
      var newValue =
        currentValue.substring(0, start) +
        text +
        currentValue.substring(start);

      s.textarea.value = newValue;
      var newCursorPos = start + text.length;
      s.textarea.selectionStart = s.textarea.selectionEnd = newCursorPos;
      s.lastCursorPosition = newCursorPos;

      s.textarea.focus();
      s.textarea.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true }));
    };

    // Register global format function (wraps selection)
    window["markdownFormat_" + globalId] = function (prefix, suffix) {
      var s = window.markdownEditors[editorId];
      if (!s || !s.textarea) return;

      var start = s.textarea.selectionStart;
      var end = s.textarea.selectionEnd;
      var selected = s.textarea.value.substring(start, end);
      var before = s.textarea.value.substring(0, start);
      var after = s.textarea.value.substring(end);

      if (selected.length > 0) {
        s.textarea.value = before + prefix + selected + suffix + after;
        s.textarea.selectionStart = start + prefix.length;
        s.textarea.selectionEnd = end + prefix.length;
      } else {
        var placeholder = "text";
        s.textarea.value = before + prefix + placeholder + suffix + after;
        s.textarea.selectionStart = start + prefix.length;
        s.textarea.selectionEnd = start + prefix.length + placeholder.length;
      }

      s.textarea.focus();
      s.textarea.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true }));
      s.lastCursorPosition = s.textarea.selectionEnd;
    };

    // Register global line prefix function (adds prefix to line)
    window["markdownLinePrefix_" + globalId] = function (prefix) {
      var s = window.markdownEditors[editorId];
      if (!s || !s.textarea) return;

      var start = s.textarea.selectionStart;
      var value = s.textarea.value;

      var lineStart = value.lastIndexOf("\n", start - 1) + 1;
      var before = value.substring(0, lineStart);
      var after = value.substring(lineStart);

      s.textarea.value = before + prefix + after;
      var newPos = start + prefix.length;
      s.textarea.selectionStart = s.textarea.selectionEnd = newPos;

      s.textarea.focus();
      s.textarea.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true }));
      s.lastCursorPosition = newPos;
    };

    // Register global link function
    window["markdownLink_" + globalId] = function () {
      var s = window.markdownEditors[editorId];
      if (!s || !s.textarea) return;

      var url = prompt("Enter URL:");
      if (!url || !url.trim()) return;

      var start = s.textarea.selectionStart;
      var end = s.textarea.selectionEnd;
      var selected = s.textarea.value.substring(start, end);
      var linkText = selected.length > 0 ? selected : "link text";

      var before = s.textarea.value.substring(0, start);
      var after = s.textarea.value.substring(end);

      s.textarea.value =
        before + "[" + linkText + "](" + url.trim() + ")" + after;

      var newPos = start + linkText.length + url.trim().length + 4;
      s.textarea.selectionStart = s.textarea.selectionEnd = newPos;

      s.textarea.focus();
      s.textarea.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true }));
      s.lastCursorPosition = newPos;
    };

    // Browser exit protection
    if (
      protectNavigation &&
      !window["markdownEditorBeforeUnload_" + globalId]
    ) {
      window["markdownEditorBeforeUnload_" + globalId] = true;
      window.addEventListener("beforeunload", function (e) {
        var s = window.markdownEditors && window.markdownEditors[editorId];
        if (s && s.hasUnsavedChanges) {
          e.preventDefault();
          e.returnValue = "";
          return "";
        }
      });
    }
  };

  /**
   * Initialize all markdown editors on the page
   */
  function initAllEditors() {
    var editors = document.querySelectorAll('[data-markdown-editor="true"]');
    editors.forEach(window.initMarkdownEditor);
  }

  // Initialize on DOM ready
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initAllEditors);
  } else {
    initAllEditors();
  }

  // Re-initialize on LiveView navigation
  window.addEventListener("phx:page-loading-stop", function () {
    // Staggered initialization to handle DOM morphing timing
    setTimeout(initAllEditors, 50);
    setTimeout(initAllEditors, 150);
  });

  // Watch for new editors added to DOM (LiveView navigation)
  var observer = new MutationObserver(function (mutations) {
    mutations.forEach(function (mutation) {
      mutation.addedNodes.forEach(function (node) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          // Check if the added node is an editor
          if (node.dataset && node.dataset.markdownEditor === "true") {
            window.initMarkdownEditor(node);
          }
          // Check children for editors
          if (node.querySelectorAll) {
            node
              .querySelectorAll('[data-markdown-editor="true"]')
              .forEach(window.initMarkdownEditor);
          }
        }
      });
    });
  });

  observer.observe(document.body, { childList: true, subtree: true });

  // Listen for insert events from LiveView
  window.addEventListener("phx:markdown-editor-insert", function (e) {
    var globalId = e.detail.global_id;
    var text = e.detail.text;
    var insertFn = window["markdownEditorInsert_" + globalId];
    if (insertFn) {
      insertFn(text);
    }
  });
})();
