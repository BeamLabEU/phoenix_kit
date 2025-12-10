defmodule PhoenixKitWeb.Components.Core.MarkdownEditor do
  @moduledoc """
  Reusable markdown editor LiveComponent with cursor tracking,
  markdown formatting toolbar, component insertion, and unsaved changes protection.

  ## Features

  - Monospace textarea optimized for markdown/code editing
  - **Markdown formatting toolbar** with selection-aware text manipulation
  - Cursor position tracking for inserting components at cursor
  - Optional toolbar for inserting images, videos, etc.
  - Save status indicator (saving/unsaved/saved)
  - Browser navigation protection for unsaved changes
  - Debounced content updates

  ## Usage

      <.live_component
        module={PhoenixKitWeb.Components.Core.MarkdownEditor}
        id="content-editor"
        content={@content}
        save_status={@save_status}
        show_formatting_toolbar={true}
        toolbar={[:image, :video]}
        on_change="content_changed"
        on_save="save_content"
        on_insert_component="insert_component"
      />

  ## Formatting Toolbar

  The formatting toolbar includes:
  - **Headings**: H1-H6 (adds `#` prefix to current line)
  - **Inline styles**: Bold, Italic, Strikethrough, Inline Code (wraps selection)
  - **Links**: Prompts for URL and wraps selection as link text
  - **Lists**: Bullet and numbered lists (adds prefix to current line)

  When text is selected, formatting wraps the selection. When no text is
  selected, a placeholder is inserted and auto-selected for easy replacement.

  ## Events Sent to Parent

  The component sends messages to the parent LiveView via `send/2`:

  - `{:editor_content_changed, %{content: content, editor_id: id}}` - Content updated
  - `{:editor_insert_component, %{type: :image | :video, editor_id: id}}` - Toolbar button clicked
  - `{:editor_save_requested, %{editor_id: id}}` - Save button clicked

  ## Commands from Parent

  Use `send_update/2` to send commands to the component:

      # Insert text at cursor position
      send_update(PhoenixKitWeb.Components.Core.MarkdownEditor,
        id: "content-editor",
        action: :insert_at_cursor,
        text: "<Image file_id=\\"abc123\\" />"
      )

  ## CSP Nonce

  If your app uses Content Security Policy, pass the nonce:

      <.live_component
        module={PhoenixKitWeb.Components.Core.MarkdownEditor}
        id="editor"
        content={@content}
        script_nonce={assigns[:csp_nonce] || ""}
      />
  """
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign_new(:content, fn -> "" end)
     |> assign_new(:save_status, fn -> :saved end)
     |> assign_new(:toolbar, fn -> [] end)
     |> assign_new(:show_formatting_toolbar, fn -> true end)
     |> assign_new(:placeholder, fn -> "Write your content here..." end)
     |> assign_new(:height, fn -> "480px" end)
     |> assign_new(:debounce, fn -> 400 end)
     |> assign_new(:protect_navigation, fn -> true end)
     |> assign_new(:script_nonce, fn -> "" end)
     |> assign_new(:show_save_button, fn -> false end)
     |> assign_new(:readonly, fn -> false end)}
  end

  @impl true
  def update(%{action: :insert_at_cursor, text: text}, socket) do
    # Trigger JS to insert text at cursor via push_event
    global_id = String.replace(socket.assigns.id, "-", "_")
    {:ok, push_event(socket, "markdown-editor-insert", %{global_id: global_id, text: text})}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    global_id = String.replace(assigns.id, "-", "_")
    assigns = assign(assigns, :global_id, global_id)

    ~H"""
    <div
      class="markdown-editor"
      id={@id}
      data-markdown-editor="true"
      data-global-id={@global_id}
      data-protect-navigation={@protect_navigation}
    >
      <%!--
        Global initialization script - uses MutationObserver to detect when
        markdown editors are added to the DOM (including on LiveView navigation)
      --%>
      <script nonce={@script_nonce} data-editor-id={@id}>
        (function() {
          window.markdownEditors = window.markdownEditors || {};

          // Define init function globally so MutationObserver can always find it
          window.phoenixKitInitEditor = window.phoenixKitInitEditor || function(editorEl, attempt) {
            attempt = attempt || 0;
            const maxAttempts = 20;
            const editorId = editorEl.id;
            const globalId = editorEl.dataset.globalId;
            const textareaId = editorId + '-textarea';
            const protectNavigation = editorEl.dataset.protectNavigation === 'true';

            const textarea = document.getElementById(textareaId);
            const warningEl = document.getElementById(editorId + '-js-warning');

            if (!textarea) {
              if (attempt >= maxAttempts) {
                console.error('[MarkdownEditor] Failed to initialize:', editorId, '- textarea not found after', maxAttempts, 'attempts');
                // Show warning on failure
                if (warningEl) warningEl.classList.remove('hidden');
                return;
              }
              // Textarea not ready yet, retry shortly
              setTimeout(function() { window.phoenixKitInitEditor(editorEl, attempt + 1); }, 50);
              return;
            }

            // Check if already initialized with current textarea
            const existing = window.markdownEditors[editorId];
            if (existing && existing.textarea === textarea && existing.initialized) {
              return;
            }

            // Store state in namespaced object
            const state = {
              textarea: textarea,
              lastCursorPosition: 0,
              hasUnsavedChanges: false,
              initialized: true
            };
            window.markdownEditors[editorId] = state;

            // Setup cursor tracking
            const events = ['blur', 'select', 'click', 'keyup'];
            events.forEach(function(event) {
              textarea.addEventListener(event, function() {
                const s = window.markdownEditors[editorId];
                if (s) s.lastCursorPosition = textarea.selectionStart;
              });
            });

            // Auto-continue lists on Enter
            textarea.addEventListener('keydown', function(e) {
              if (e.key !== 'Enter') return;

              const pos = textarea.selectionStart;
              const value = textarea.value;

              // Find current line
              const lineStart = value.lastIndexOf('\n', pos - 1) + 1;
              const lineEnd = value.indexOf('\n', pos);
              const currentLine = value.substring(lineStart, lineEnd === -1 ? value.length : lineEnd);

              // Check if cursor is at end of line
              const cursorInLine = pos - lineStart;
              if (cursorInLine < currentLine.length) return; // Cursor not at end, let default happen

              // Match bullet list: "  - text" or "  * text" or "  + text"
              const bulletMatch = currentLine.match(/^(\s*)(-|\*|\+)\s(.*)$/);
              if (bulletMatch) {
                e.preventDefault();
                const [, indent, marker, content] = bulletMatch;

                if (content.trim() === '') {
                  // Empty list item - remove marker
                  const newValue = value.substring(0, lineStart) + value.substring(pos);
                  textarea.value = newValue;
                  textarea.selectionStart = textarea.selectionEnd = lineStart;
                } else {
                  // Continue list
                  const insertion = '\n' + indent + marker + ' ';
                  const newValue = value.substring(0, pos) + insertion + value.substring(pos);
                  textarea.value = newValue;
                  textarea.selectionStart = textarea.selectionEnd = pos + insertion.length;
                }
                const s = window.markdownEditors[editorId];
                if (s) s.lastCursorPosition = textarea.selectionStart;
                textarea.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
                return;
              }

              // Match numbered list: "  1. text"
              const numberMatch = currentLine.match(/^(\s*)(\d+)\.\s(.*)$/);
              if (numberMatch) {
                e.preventDefault();
                const [, indent, num, content] = numberMatch;

                if (content.trim() === '') {
                  // Empty list item - remove marker
                  const newValue = value.substring(0, lineStart) + value.substring(pos);
                  textarea.value = newValue;
                  textarea.selectionStart = textarea.selectionEnd = lineStart;
                } else {
                  // Continue with next number
                  const nextNum = parseInt(num, 10) + 1;
                  const insertion = '\n' + indent + nextNum + '. ';
                  const newValue = value.substring(0, pos) + insertion + value.substring(pos);
                  textarea.value = newValue;
                  textarea.selectionStart = textarea.selectionEnd = pos + insertion.length;
                }
                const s = window.markdownEditors[editorId];
                if (s) s.lastCursorPosition = textarea.selectionStart;
                textarea.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
                return;
              }
            });

            // Register global functions
            window['markdownEditorInsert_' + globalId] = function(text) {
              const s = window.markdownEditors[editorId];
              if (!s || !s.textarea) return;

              const start = s.lastCursorPosition || 0;
              const currentValue = s.textarea.value;
              const newValue = currentValue.substring(0, start) + text + currentValue.substring(start);

              s.textarea.value = newValue;
              const newCursorPos = start + text.length;
              s.textarea.selectionStart = s.textarea.selectionEnd = newCursorPos;
              s.lastCursorPosition = newCursorPos;

              s.textarea.focus();
              s.textarea.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
            };

            window['markdownFormat_' + globalId] = function(prefix, suffix) {
              const s = window.markdownEditors[editorId];
              if (!s || !s.textarea) return;

              const start = s.textarea.selectionStart;
              const end = s.textarea.selectionEnd;
              const selected = s.textarea.value.substring(start, end);
              const before = s.textarea.value.substring(0, start);
              const after = s.textarea.value.substring(end);

              if (selected.length > 0) {
                s.textarea.value = before + prefix + selected + suffix + after;
                s.textarea.selectionStart = start + prefix.length;
                s.textarea.selectionEnd = end + prefix.length;
              } else {
                const placeholder = "text";
                s.textarea.value = before + prefix + placeholder + suffix + after;
                s.textarea.selectionStart = start + prefix.length;
                s.textarea.selectionEnd = start + prefix.length + placeholder.length;
              }

              s.textarea.focus();
              s.textarea.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
              s.lastCursorPosition = s.textarea.selectionEnd;
            };

            window['markdownLinePrefix_' + globalId] = function(prefix) {
              const s = window.markdownEditors[editorId];
              if (!s || !s.textarea) return;

              const start = s.textarea.selectionStart;
              const value = s.textarea.value;

              let lineStart = value.lastIndexOf('\n', start - 1) + 1;
              const before = value.substring(0, lineStart);
              const after = value.substring(lineStart);

              s.textarea.value = before + prefix + after;
              const newPos = start + prefix.length;
              s.textarea.selectionStart = s.textarea.selectionEnd = newPos;

              s.textarea.focus();
              s.textarea.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
              s.lastCursorPosition = newPos;
            };

            window['markdownLink_' + globalId] = function() {
              const s = window.markdownEditors[editorId];
              if (!s || !s.textarea) return;

              const url = prompt('Enter URL:');
              if (!url || !url.trim()) return;

              const start = s.textarea.selectionStart;
              const end = s.textarea.selectionEnd;
              const selected = s.textarea.value.substring(start, end);
              const linkText = selected.length > 0 ? selected : 'link text';

              const before = s.textarea.value.substring(0, start);
              const after = s.textarea.value.substring(end);

              s.textarea.value = before + '[' + linkText + '](' + url.trim() + ')' + after;

              const newPos = start + linkText.length + url.trim().length + 4;
              s.textarea.selectionStart = s.textarea.selectionEnd = newPos;

              s.textarea.focus();
              s.textarea.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
              s.lastCursorPosition = newPos;
            };

            // Browser exit protection
            if (protectNavigation && !window['markdownEditorBeforeUnload_' + globalId]) {
              window['markdownEditorBeforeUnload_' + globalId] = true;
              window.addEventListener('beforeunload', function(e) {
                const s = window.markdownEditors && window.markdownEditors[editorId];
                if (s && s.hasUnsavedChanges) {
                  e.preventDefault();
                  e.returnValue = '';
                  return '';
                }
              });
            }

          };

          function initAllEditors() {
            document.querySelectorAll('[data-markdown-editor="true"]').forEach(window.phoenixKitInitEditor);
          }

          // CRITICAL: Always init THIS specific editor immediately when script runs
          // This ensures the editor works even on LiveView navigation
          var scriptEl = document.currentScript;
          if (scriptEl && scriptEl.dataset.editorId) {
            var thisEditor = document.getElementById(scriptEl.dataset.editorId);
            if (thisEditor) {
              window.phoenixKitInitEditor(thisEditor);
            }
          }

          // Only set up global listeners once
          if (!window.phoenixKitEditorSystemInit) {
            window.phoenixKitEditorSystemInit = true;

            // Watch for new editors added to DOM (LiveView navigation)
            const observer = new MutationObserver(function(mutations) {
              mutations.forEach(function(mutation) {
                mutation.addedNodes.forEach(function(node) {
                  if (node.nodeType === Node.ELEMENT_NODE) {
                    // Check if the added node is an editor
                    if (node.dataset && node.dataset.markdownEditor === 'true') {
                      window.phoenixKitInitEditor(node);
                    }
                    // Check children for editors
                    if (node.querySelectorAll) {
                      node.querySelectorAll('[data-markdown-editor="true"]').forEach(window.phoenixKitInitEditor);
                    }
                  }
                });
              });
            });

            observer.observe(document.body, { childList: true, subtree: true });

            // Also re-init on LiveView page load events as a fallback
            window.addEventListener('phx:page-loading-stop', function() {
              setTimeout(initAllEditors, 100);
            });

            // Listen for insert events from LiveView
            window.addEventListener('phx:markdown-editor-insert', function(e) {
              const globalId = e.detail.global_id;
              const text = e.detail.text;
              const insertFn = window['markdownEditorInsert_' + globalId];
              if (insertFn) {
                insertFn(text);
              }
            });

            // Listen for set-content events from LiveView (for collaborative editing sync)
            window.addEventListener('phx:set-content', function(e) {
              const content = e.detail.content;
              // Update all markdown editor textareas on the page
              document.querySelectorAll('[data-markdown-editor="true"] textarea').forEach(function(textarea) {
                textarea.value = content;
              });
            });
          }
        })();
      </script>

      <%!-- JS Warning Banner - hidden by default, shown only if JS fails to initialize --%>
      <div
        id={"#{@id}-js-warning"}
        class="alert alert-warning mb-2 flex items-start gap-3 hidden"
        role="alert"
      >
        <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
        <div>
          <p class="font-semibold text-base-content">
            {gettext("Interactive editor features need JavaScript")}
          </p>
          <p class="text-sm text-base-content/80">
            {gettext("Enable JavaScript or allow inline scripts for this page.")}
          </p>
        </div>
      </div>

      <%!-- Formatting Toolbar --%>
      <%= if @show_formatting_toolbar do %>
        <div
          class="flex flex-wrap items-center gap-1 mb-2 p-2 bg-base-200 rounded-lg"
          onmousedown="event.preventDefault()"
        >
          <%!-- Headings --%>
          <div class="flex items-center gap-0.5 mr-2">
            <%= for level <- 1..6 do %>
              <button
                type="button"
                onclick={"window.markdownLinePrefix_#{@global_id}('#{"#" |> String.duplicate(level)} ')"}
                class="btn btn-xs btn-ghost font-bold px-1.5"
                title={"Heading #{level}"}
              >
                H{level}
              </button>
            <% end %>
          </div>

          <div class="divider divider-horizontal mx-0.5 h-6"></div>

          <%!-- Inline Formatting --%>
          <div class="flex items-center gap-0.5 mr-2">
            <button
              type="button"
              onclick={"window.markdownFormat_#{@global_id}('**', '**')"}
              class="btn btn-xs btn-ghost font-bold px-2"
              title={gettext("Bold")}
            >
              B
            </button>
            <button
              type="button"
              onclick={"window.markdownFormat_#{@global_id}('*', '*')"}
              class="btn btn-xs btn-ghost italic px-2"
              title={gettext("Italic")}
            >
              I
            </button>
            <button
              type="button"
              onclick={"window.markdownFormat_#{@global_id}('~~', '~~')"}
              class="btn btn-xs btn-ghost line-through px-2"
              title={gettext("Strikethrough")}
            >
              S
            </button>
            <button
              type="button"
              onclick={"window.markdownFormat_#{@global_id}('`', '`')"}
              class="btn btn-xs btn-ghost font-mono px-2"
              title={gettext("Inline Code")}
            >
              <.icon name="hero-code-bracket" class="w-3.5 h-3.5" />
            </button>
            <button
              type="button"
              onclick={"window.markdownEditorInsert_#{@global_id}('<br>')"}
              class="btn btn-xs btn-ghost px-2"
              title={gettext("Line Break")}
            >
              ↵
            </button>
          </div>

          <div class="divider divider-horizontal mx-0.5 h-6"></div>

          <%!-- Links & Media --%>
          <div class="flex items-center gap-0.5 mr-2">
            <button
              type="button"
              onclick={"window.markdownLink_#{@global_id}()"}
              class="btn btn-xs btn-ghost px-2"
              title={gettext("Insert Link")}
            >
              <.icon name="hero-link" class="w-3.5 h-3.5" />
            </button>
            <%= if :image in @toolbar do %>
              <button
                type="button"
                phx-click="editor_toolbar_click"
                phx-value-action="image"
                phx-value-editor-id={@id}
                phx-target={@myself}
                class="btn btn-xs btn-ghost px-2"
                title={gettext("Insert Image")}
              >
                <.icon name="hero-photo" class="w-3.5 h-3.5" />
              </button>
            <% end %>
            <%= if :video in @toolbar do %>
              <button
                type="button"
                phx-click="editor_toolbar_click"
                phx-value-action="video"
                phx-value-editor-id={@id}
                phx-target={@myself}
                class="btn btn-xs btn-ghost px-2"
                title={gettext("Insert Video")}
              >
                <.icon name="hero-video-camera" class="w-3.5 h-3.5" />
              </button>
            <% end %>
          </div>

          <div class="divider divider-horizontal mx-0.5 h-6"></div>

          <%!-- Lists --%>
          <div class="flex items-center gap-0.5">
            <button
              type="button"
              onclick={"window.markdownLinePrefix_#{@global_id}('- ')"}
              class="btn btn-xs btn-ghost px-2"
              title={gettext("Bullet List")}
            >
              <.icon name="hero-list-bullet" class="w-3.5 h-3.5" />
            </button>
            <button
              type="button"
              onclick={"window.markdownLinePrefix_#{@global_id}('1. ')"}
              class="btn btn-xs btn-ghost px-2"
              title={gettext("Numbered List")}
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-3.5 h-3.5"
              >
                <path d="M3 4.5a.5.5 0 01.5-.5h1a.5.5 0 01.5.5v2a.5.5 0 01-.5.5h-1a.5.5 0 01-.5-.5v-2zM7 5h10a1 1 0 110 2H7a1 1 0 110-2zM3 9.5a.5.5 0 01.5-.5h1a.5.5 0 01.5.5v2a.5.5 0 01-.5.5h-1a.5.5 0 01-.5-.5v-2zM7 10h10a1 1 0 110 2H7a1 1 0 110-2zM3 14.5a.5.5 0 01.5-.5h1a.5.5 0 01.5.5v2a.5.5 0 01-.5.5h-1a.5.5 0 01-.5-.5v-2zM7 15h10a1 1 0 110 2H7a1 1 0 110-2z" />
              </svg>
            </button>
          </div>

          <%!-- Save Status & Button (when enabled) --%>
          <%= if @show_save_button do %>
            <div class="flex-1"></div>
            <div class="flex items-center gap-2">
              <%= case @save_status do %>
                <% :saving -> %>
                  <span class="badge badge-info badge-sm gap-1">
                    <span class="loading loading-spinner loading-xs"></span>
                    {gettext("Saving...")}
                  </span>
                <% :unsaved -> %>
                  <span class="badge badge-warning badge-sm">{gettext("Unsaved changes")}</span>
                <% _ -> %>
                  <span class="badge badge-success badge-sm gap-1">
                    <.icon name="hero-check" class="w-3 h-3" />
                    {gettext("Saved")}
                  </span>
              <% end %>
              <button
                type="button"
                phx-click="editor_save_click"
                phx-value-editor-id={@id}
                phx-target={@myself}
                class={[
                  "btn btn-primary btn-xs shadow-none gap-1",
                  (@save_status == :saving || @save_status == :saved) &&
                    "btn-disabled pointer-events-none opacity-60"
                ]}
                disabled={@save_status == :saving || @save_status == :saved}
              >
                <.icon name="hero-arrow-down-tray" class="w-3 h-3" />
                {gettext("Save")}
              </button>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Component Insert Toolbar (legacy - only when formatting toolbar is disabled) --%>
      <%= if not @show_formatting_toolbar and (length(@toolbar) > 0 or @show_save_button) do %>
        <div class="flex flex-wrap items-center justify-between gap-3 mb-3">
          <%!-- Component Toolbar --%>
          <%= if length(@toolbar) > 0 do %>
            <div
              class="card bg-base-200 border border-base-300"
              onmousedown="event.preventDefault()"
            >
              <div class="card-body p-3">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-xs font-semibold text-base-content/70 mr-2">
                    {gettext("Insert:")}
                  </span>
                  <%= if :image in @toolbar do %>
                    <button
                      type="button"
                      phx-click="editor_toolbar_click"
                      phx-value-action="image"
                      phx-value-editor-id={@id}
                      phx-target={@myself}
                      class="btn btn-xs btn-outline gap-1"
                      title={gettext("Insert Image")}
                      onmousedown="event.preventDefault()"
                    >
                      <.icon name="hero-photo" class="w-3 h-3" />
                      {gettext("Image")}
                    </button>
                  <% end %>
                  <%= if :video in @toolbar do %>
                    <button
                      type="button"
                      phx-click="editor_toolbar_click"
                      phx-value-action="video"
                      phx-value-editor-id={@id}
                      phx-target={@myself}
                      class="btn btn-xs btn-outline gap-1"
                      title={gettext("Insert Video")}
                      onmousedown="event.preventDefault()"
                    >
                      <.icon name="hero-video-camera" class="w-3 h-3" />
                      {gettext("Video")}
                    </button>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Save Status & Button --%>
          <%= if @show_save_button do %>
            <div class="flex items-center gap-2">
              <%= case @save_status do %>
                <% :saving -> %>
                  <span class="badge badge-info badge-sm gap-1">
                    <span class="loading loading-spinner loading-xs"></span>
                    {gettext("Saving...")}
                  </span>
                <% :unsaved -> %>
                  <span class="badge badge-warning badge-sm">{gettext("Unsaved changes")}</span>
                <% _ -> %>
                  <span class="badge badge-success badge-sm gap-1">
                    <.icon name="hero-check" class="w-3 h-3" />
                    {gettext("Saved")}
                  </span>
              <% end %>
              <button
                type="button"
                phx-click="editor_save_click"
                phx-value-editor-id={@id}
                phx-target={@myself}
                class={[
                  "btn btn-primary btn-xs shadow-none gap-1",
                  (@save_status == :saving || @save_status == :saved) &&
                    "btn-disabled pointer-events-none opacity-60"
                ]}
                disabled={@save_status == :saving || @save_status == :saved}
              >
                <.icon name="hero-arrow-down-tray" class="w-3 h-3" />
                {gettext("Save")}
              </button>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Textarea with keyup event for content tracking --%>
      <textarea
        id={"#{@id}-textarea"}
        name="editor_content"
        phx-keyup="editor_content_change"
        phx-target={@myself}
        phx-debounce={@debounce}
        placeholder={@placeholder}
        class="textarea textarea-bordered w-full font-mono text-sm leading-6"
        style={"height: #{@height}"}
        readonly={@readonly}
      ><%= @content %></textarea>
    </div>
    """
  end

  @impl true
  def handle_event("editor_content_change", %{"value" => content}, socket) do
    # Send content change to parent (phx-blur sends "value")
    send(self(), {:editor_content_changed, %{content: content, editor_id: socket.assigns.id}})
    {:noreply, assign(socket, :content, content)}
  end

  def handle_event(
        "editor_toolbar_click",
        %{"action" => action, "editor-id" => editor_id},
        socket
      ) do
    type = String.to_existing_atom(action)
    send(self(), {:editor_insert_component, %{type: type, editor_id: editor_id}})
    {:noreply, socket}
  end

  def handle_event("editor_save_click", %{"editor-id" => editor_id}, socket) do
    send(self(), {:editor_save_requested, %{editor_id: editor_id}})
    {:noreply, socket}
  end

  # Prevent form submission
  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end
end
