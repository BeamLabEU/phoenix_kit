defmodule PhoenixKitWeb.Components.Core.FileUpload do
  @moduledoc """
  Reusable file upload component for PhoenixKit.

  Provides a simple file upload button with auto-upload functionality.
  Files are uploaded immediately upon selection without requiring a submit button.

  ## Usage

      <.file_upload
        upload={@uploads.media_files}
        label="Upload Media"
      />

  ## Attributes

  - `upload` (required) - LiveView upload config from allow_upload/3
  - `label` (optional) - Button label (default: "Upload Files")
  - `icon` (optional) - Icon name (default: "hero-cloud-arrow-up")
  - `accept_description` (optional) - Text describing accepted file types
  - `max_size_description` (optional) - Text describing max file size
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Utils.Format

  attr :upload, :any, required: true

  attr :label, :string,
    default: nil,
    doc: "Button label; defaults to a translated \"Upload Files\""

  attr :icon, :string, default: "hero-cloud-arrow-up"
  attr :accept_description, :string, default: nil
  attr :max_size_description, :string, default: nil

  attr :uploaded_file_ids, :list,
    default: nil,
    doc: "List of file IDs from last upload (for external use)"

  attr :show_entries, :boolean,
    default: true,
    doc:
      "list the entries in flight under the drop zone. FALSE when an " <>
        "`upload_manager` on the page already lists them"

  attr :standalone, :boolean,
    default: true,
    doc:
      "wrap the drop zone in its own `<form>`. Set FALSE when embedding inside another form — " <>
        "HTML forbids nested forms and the browser closes the outer one at the inner tag, " <>
        "silently pushing every later field out of the host form"

  attr :variant, :string,
    default: "full",
    doc: "Display variant - 'full' for drag-drop zone, 'button' for simple button only"

  def file_upload(assigns) do
    case assigns.variant do
      "button" -> button_upload(assigns)
      _ -> full_upload(assigns)
    end
  end

  @doc """
  Live transfer stats for one upload entry, rendered under its progress bar.

  The server only patches `data-progress`; the `UploadStats` JS hook computes
  transferred bytes, speed, and ETA in the browser ("3.2 MB / 12.4 MB ·
  2.8 MB/s · 4s left") and flips to a ticking "Processing on server…" once
  the transfer reaches 100% — the phase where the bar used to sit frozen with
  no hint whether the network, the file size, or the server was to blame.
  The hook owns the element's text; the server-rendered size is only the
  pre-mount fallback.
  """
  attr :entry, :any, required: true, doc: "a Phoenix.LiveView.UploadEntry"
  attr :class, :string, default: "block text-xs text-base-content/60 tabular-nums mt-1"

  def upload_entry_stats(assigns) do
    ~H"""
    <span
      id={"pk-upload-stats-#{@entry.upload_ref}-#{@entry.ref}"}
      phx-hook="UploadStats"
      data-progress={@entry.progress}
      data-size={@entry.client_size}
      data-label-processing={gettext("Processing on server…")}
      data-label-left={gettext("left")}
      class={@class}
    >
      {Format.bytes(@entry.client_size, base: 1000, decimals: 2)}
    </span>
    """
  end

  defp full_upload(assigns) do
    ~H"""
    <%!-- UploadGuard: while any entry is in flight (data-active), the
         browser's own beforeunload dialog blocks an accidental refresh /
         close that would kill the transfer — interrupted LiveView
         uploads are not resumed. Protection instead of disclaimer prose. --%>
    <div
      id={"pk-upload-guard-" <> @upload.ref}
      phx-hook="UploadGuard"
      data-active={to_string(@upload.entries != [])}
      class="space-y-4"
    >
      <%!-- STANDALONE wraps the drop zone in its own form so `phx-change`
           has something to hang on. Embedded, it must not: nested `<form>`
           elements are invalid HTML, and the browser resolves that by
           closing the OUTER form at the inner tag — which silently moves
           every field after this point, including the host's submit
           button and any hidden anti-spam field, outside the form that was
           supposed to carry them. Nothing looks wrong; the host form just
           stops containing half of itself. --%>
      <form :if={@standalone} phx-change="validate" id={"upload-form-" <> @upload.ref}>
        <.drop_zone {assigns} />
      </form>

      <.drop_zone :if={not @standalone} {assigns} />

      <%!-- Active Uploads --%>
      <%= if @show_entries and length(@upload.entries) > 0 do %>
        <div class="space-y-2">
          <%= for entry <- @upload.entries do %>
            <div class="flex items-center gap-3 p-3 border border-base-300 rounded-lg bg-base-50">
              <div class="flex-1">
                <p class="font-medium text-sm truncate">{entry.client_name}</p>
                <div class="flex gap-2 items-center mt-1">
                  <progress
                    value={entry.progress}
                    max="100"
                    class="progress progress-primary progress-sm flex-1"
                  >
                    {entry.progress}%
                  </progress>
                  <span class="text-xs text-base-content/60 min-w-max">
                    {entry.progress}%
                  </span>
                </div>
                <.upload_entry_stats entry={entry} />
              </div>

              <%!-- Cancel Button --%>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="btn btn-xs btn-ghost text-error"
                title={gettext("Cancel upload")}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # The drop zone itself, shared by both wrappings so they cannot drift.
  defp drop_zone(assigns) do
    ~H"""
    <%!-- Drag and Drop Zone --%>
    <div
      class="border-2 border-dashed border-base-300 rounded-lg p-8 text-center transition-colors cursor-pointer hover:border-primary hover:bg-primary/5"
      phx-drop-target={@upload.ref}
      id={"drop-zone-" <> @upload.ref}
    >
      <label for={@upload.ref} class="cursor-pointer block">
        <div class="flex flex-col items-center gap-2">
          <.icon name={@icon} class="w-8 h-8 text-primary" />
          <div>
            <p class="font-semibold text-base-content">
              {gettext("Drag files here or click to browse")}
            </p>
            <p class="text-sm text-base-content/70 mt-1">
              <%= if @accept_description do %>
                {@accept_description}
              <% else %>
                {gettext("Drop your files to upload")}
              <% end %>
            </p>
          </div>
        </div>
      </label>
      <.live_file_input upload={@upload} class="hidden" />
    </div>

    <%!-- File Type and Size Info --%>
    <%= if @accept_description != nil or @max_size_description != nil do %>
      <p class="text-sm text-base-content/70 text-center">
        <%= if @max_size_description do %>
          {gettext("Maximum file size: %{size}", size: @max_size_description)}
        <% end %>
      </p>
    <% end %>
    """
  end

  defp button_upload(assigns) do
    ~H"""
    <div
      id={"pk-upload-guard-btn-" <> @upload.ref}
      phx-hook="UploadGuard"
      data-active={to_string(@upload.entries != [])}
      class="space-y-3"
    >
      <form phx-change="validate" id={"button-upload-form-" <> @upload.ref}>
        <label
          for={@upload.ref}
          class="btn btn-primary btn-block"
        >
          <.icon name={@icon} class="w-5 h-5" /> {@label || gettext("Upload Files")}
        </label>
        <.live_file_input upload={@upload} class="hidden" />
      </form>

      <%!-- Active Uploads --%>
      <%= if length(@upload.entries) > 0 do %>
        <div class="space-y-2">
          <%= for entry <- @upload.entries do %>
            <div class="flex items-center gap-3 p-3 border border-base-300 rounded-lg bg-base-50">
              <div class="flex-1">
                <p class="font-medium text-sm truncate">{entry.client_name}</p>
                <progress
                  value={entry.progress}
                  max="100"
                  class="progress progress-primary progress-sm w-full mt-1"
                >
                  {entry.progress}%
                </progress>
                <.upload_entry_stats entry={entry} />
              </div>

              <%!-- Cancel Button --%>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="btn btn-xs btn-ghost text-error"
                title={gettext("Cancel upload")}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
