defmodule PhoenixKitWeb.Components.Core.MarkdownEditor do
  @moduledoc """
  Reusable markdown editor LiveComponent with cursor tracking,
  markdown formatting toolbar, component insertion, and optional unsaved
  changes protection.

  ## Features

  - Monospace textarea optimized for markdown/code editing
  - **Markdown formatting toolbar** with selection-aware text manipulation
  - Cursor position tracking for inserting components at cursor
  - Optional toolbar for inserting images, videos, etc.
  - Save status indicator (saving/unsaved/saved)
  - Browser navigation protection for unsaved changes — **opt-in** via
    `protect_navigation={true}`; off by default so closing the tab never
    prompts
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

  ## Events Sent to Parent — required host wiring (silent failure otherwise)

  This is a `LiveComponent`, so it has no `handle_info` of its own: it
  reports edits by sending **process messages to the host LiveView** via
  `send/2`. The host MUST handle these, or the edits are silently lost
  (the editor looks live but the parent never sees the typed content —
  no crash, no warning):

  - `{:editor_content_changed, %{content: content, editor_id: id}}` —
    **required.** Content updated; the host folds `content` into its own
    changeset/assign. Forget this and the form never sees what's typed.
  - `{:editor_insert_component, %{type: :image | :video, editor_id: id}}` —
    toolbar insert button clicked (handle if you support media inserts).
  - `{:editor_save_requested, %{editor_id: id}}` — save button clicked.

  Each host folds the content into its own form differently, so there is
  intentionally no `use ...Embed` macro — the handling is yours to write.

  ## Commands from Parent

  Use `send_update/2` to send commands to the component:

      # Insert text at cursor position
      send_update(PhoenixKitWeb.Components.Core.MarkdownEditor,
        id: "content-editor",
        action: :insert_at_cursor,
        text: "<Image file_id=\\"abc123\\" />"
      )

      # Prompt the user (window.prompt) on the client, then insert the value by
      # substituting `%{value}` in `template` (e.g. a video URL):
      send_update(PhoenixKitWeb.Components.Core.MarkdownEditor,
        id: "content-editor",
        action: :prompt_insert,
        prompt: "Enter YouTube URL:",
        template: "\\n![Video](%{value})\\n"
      )

  ## JavaScript / CSP

  All behavior is driven by the `MarkdownEditor` LiveView hook (shipped in
  `priv/static/assets/phoenix_kit.js` as `window.PhoenixKitHooks.MarkdownEditor`),
  not by inline `<script>` or `onclick=` handlers. That means it works under a
  strict Content-Security-Policy with no nonce and survives LiveView navigation.
  The host only needs the vendored `phoenix_kit.js` loaded (the standard install;
  `mix phoenix_kit.update` refreshes it) and `window.PhoenixKitHooks` spread into
  its LiveSocket — exactly like every other PhoenixKit hook.
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
     # Off by default: closing the tab must never prompt "leave with unsaved
     # changes". (The old `true` default never actually armed the guard — a
     # boolean renders as an empty data attribute, which fails the hook's
     # `=== "true"` check — so this makes the shipped behavior deliberate.)
     # Hosts that genuinely want the guard opt in with
     # `protect_navigation={true}`, which now arms it for real via the
     # `to_string/1` in the data attribute below.
     |> assign_new(:protect_navigation, fn -> false end)
     |> assign_new(:show_save_button, fn -> false end)
     |> assign_new(:readonly, fn -> false end)}
  end

  @impl true
  def update(%{action: :insert_at_cursor, text: text}, socket) do
    # Trigger JS to insert text at cursor via push_event
    global_id = String.replace(socket.assigns.id, "-", "_")
    {:ok, push_event(socket, "markdown-editor-insert", %{global_id: global_id, text: text})}
  end

  # Ask the user for a value (window.prompt) on the client, then insert it at the
  # cursor by substituting `%{value}` in `template`. Lets a host trigger a
  # client-side prompt (e.g. a video URL) without any inline script of its own.
  def update(%{action: :prompt_insert} = assigns, socket) do
    global_id = String.replace(socket.assigns.id, "-", "_")

    {:ok,
     push_event(socket, "markdown-editor-prompt-insert", %{
       global_id: global_id,
       prompt: Map.get(assigns, :prompt, ""),
       template: Map.get(assigns, :template, "%{value}")
     })}
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
      phx-hook="MarkdownEditor"
      data-markdown-editor="true"
      data-global-id={@global_id}
      data-protect-navigation={to_string(@protect_navigation)}
      data-save-status={@save_status}
    >
      <%!-- The toolbars below are hidden by default and revealed by the
           MarkdownEditor hook on mount, so JS-dependent buttons never show as
           dead controls. When JS is disabled the hook never runs and this
           noscript hint explains why the toolbar is absent. --%>
      <noscript>
        <div class="alert alert-warning mb-2 flex items-start gap-3" role="alert">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
          <div>
            <p class="font-semibold text-base-content">
              {gettext("Interactive editor features need JavaScript")}
            </p>
            <p class="text-sm text-base-content/80">
              {gettext("Enable JavaScript to use the toolbar and media insertion.")}
            </p>
          </div>
        </div>
      </noscript>

      <%!-- Formatting Toolbar (hidden until the hook reveals it) --%>
      <%= if @show_formatting_toolbar do %>
        <div
          class="flex flex-wrap items-center gap-1 mb-2 p-2 bg-base-200 rounded-lg hidden"
          data-md-toolbar
        >
          <%!-- Headings --%>
          <div class="flex items-center gap-0.5 mr-2">
            <%= for level <- 1..6 do %>
              <button
                type="button"
                data-md-action="line-prefix"
                data-md-prefix={String.duplicate("#", level) <> " "}
                class="btn btn-xs btn-ghost font-bold px-1.5"
                title={gettext("Heading %{level}", level: level)}
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
              data-md-action="wrap"
              data-md-prefix="**"
              data-md-suffix="**"
              class="btn btn-xs btn-ghost font-bold px-2"
              title={gettext("Bold")}
            >
              B
            </button>
            <button
              type="button"
              data-md-action="wrap"
              data-md-prefix="*"
              data-md-suffix="*"
              class="btn btn-xs btn-ghost italic px-2"
              title={gettext("Italic")}
            >
              I
            </button>
            <button
              type="button"
              data-md-action="wrap"
              data-md-prefix="~~"
              data-md-suffix="~~"
              class="btn btn-xs btn-ghost line-through px-2"
              title={gettext("Strikethrough")}
            >
              S
            </button>
            <button
              type="button"
              data-md-action="wrap"
              data-md-prefix="`"
              data-md-suffix="`"
              class="btn btn-xs btn-ghost font-mono px-2"
              title={gettext("Inline Code")}
            >
              <.icon name="hero-code-bracket" class="w-3.5 h-3.5" />
            </button>
            <button
              type="button"
              data-md-action="insert"
              data-md-text="<br>"
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
              data-md-action="link"
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
              data-md-action="line-prefix"
              data-md-prefix="- "
              class="btn btn-xs btn-ghost px-2"
              title={gettext("Bullet List")}
            >
              <.icon name="hero-list-bullet" class="w-3.5 h-3.5" />
            </button>
            <button
              type="button"
              data-md-action="line-prefix"
              data-md-prefix="1. "
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

      <%!-- Component Insert Toolbar (legacy - only when formatting toolbar is disabled and not readonly) --%>
      <%= if not @show_formatting_toolbar and not @readonly and (length(@toolbar) > 0 or @show_save_button) do %>
        <div class="flex flex-wrap items-center justify-between gap-3 mb-3">
          <%!-- Component Toolbar --%>
          <%= if length(@toolbar) > 0 do %>
            <div
              class="card bg-base-200 border border-base-300 hidden"
              data-md-toolbar
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
        class={"textarea textarea-bordered w-full font-mono text-sm leading-6 #{if @readonly, do: "bg-base-200 cursor-not-allowed opacity-70"}"}
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
