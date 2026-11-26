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
  - `edit_images` (optional, default `false`) - let the user crop, rotate and
    flip a photo in the browser before it is uploaded (see below)

  ## Editing photos before upload

      <.file_upload upload={@uploads.photos} edit_images />

  With `edit_images`, a chosen or dropped JPEG, PNG or WebP opens an editor
  first: crop (drawn on the picture, free or at 1:1, 4:3, 3:2, 16:9, 3:4,
  9:16), quarter turns and a mirror flip. "Upload" sends the edited picture
  (re-encoded by the browser in the same format; a JPEG at quality 0.92),
  "Upload original" the file untouched, "Remove" drops it. Several files are
  edited one after the other, then uploaded together. Other files (a PDF, a
  GIF, a HEIC the browser cannot draw) go up untouched. Nothing changes on
  the server side: the LiveView receives an ordinary upload entry (with the
  edited file's size, so `max_file_size` applies to what is sent).

  The editor is the `PkUploadEdit` hook in `phoenix_kit.js`; its crop
  geometry is the one `PhoenixKitWeb.Components.ImageEditor` (editing a
  stored image afterwards) uses. Without JavaScript the files upload as
  they are. The browser re-encodes the picture, so its EXIF data (camera,
  location) is not carried over — the orientation is applied to the pixels.
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

  attr :edit_images, :boolean,
    default: false,
    doc: "open a crop/rotate editor in the browser for each chosen photo before it is uploaded"

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
    <.edit_wrapper upload={@upload} enabled={@edit_images}>
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
    </.edit_wrapper>

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
        <.edit_wrapper upload={@upload} enabled={@edit_images}>
          <label
            for={@upload.ref}
            class="btn btn-primary btn-block"
          >
            <.icon name={@icon} class="w-5 h-5" /> {@label || gettext("Upload Files")}
          </label>
          <.live_file_input upload={@upload} class="hidden" />
        </.edit_wrapper>
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

  # The `edit_images` editor: the PkUploadEdit hook around the file input
  # (and the drop zone), which takes the chosen files before LiveView sees
  # them, and the dialog it edits them in. Off, the content renders bare.
  attr :upload, :any, required: true
  attr :enabled, :boolean, default: false
  slot :inner_block, required: true

  defp edit_wrapper(%{enabled: false} = assigns) do
    ~H"""
    {render_slot(@inner_block)}
    """
  end

  defp edit_wrapper(assigns) do
    assigns = assign(assigns, :id, "pk-upload-edit-" <> assigns.upload.ref)

    ~H"""
    <div id={@id} phx-hook="PkUploadEdit" data-upload-name={to_string(@upload.name)}>
      {render_slot(@inner_block)}
      <%!-- Buttons only, no fields: this sits inside the upload's form,
           and a field here would be sent with its phx-change. --%>
      <dialog
        id={@id <> "-dialog"}
        data-pk-edit-dialog
        aria-labelledby={@id <> "-title"}
        phx-update="ignore"
        class="modal"
      >
        <div class="modal-box max-w-3xl space-y-3">
          <div class="flex items-baseline justify-between gap-3">
            <h3 id={@id <> "-title"} class="font-semibold text-lg">
              {gettext("Edit photo before upload")}
            </h3>
            <span data-pk-edit-progress class="text-sm text-base-content/60 tabular-nums"></span>
          </div>
          <p data-pk-edit-name class="text-sm text-base-content/70 truncate"></p>

          <div class="flex justify-center bg-base-200 rounded-box p-2">
            <div data-pk-edit-frame class="relative touch-none select-none cursor-crosshair">
              <canvas data-pk-edit-canvas class="block max-w-full max-h-[60vh]"></canvas>
              <div
                data-pk-edit-crop
                hidden
                class="absolute pointer-events-none border-2 border-white outline outline-1 outline-black/40 shadow-[0_0_0_9999px_rgba(0,0,0,0.45)]"
              >
              </div>
            </div>
          </div>
          <p class="text-xs text-base-content/60">
            {gettext("Drag on the photo to crop it.")}
          </p>

          <div class="flex flex-wrap items-center gap-1" role="toolbar" aria-label={gettext("Edit")}>
            <button type="button" class="btn btn-sm" data-pk-edit-rotate="-90">
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Rotate left")}
            </button>
            <button type="button" class="btn btn-sm" data-pk-edit-rotate="90">
              <.icon name="hero-arrow-uturn-right" class="w-4 h-4" /> {gettext("Rotate right")}
            </button>
            <button type="button" class="btn btn-sm" data-pk-edit-flip aria-pressed="false">
              <.icon name="hero-arrows-right-left" class="w-4 h-4" /> {gettext("Flip")}
            </button>
            <span class="mx-1 h-5 border-l border-base-300" aria-hidden="true"></span>
            <button
              :for={{label, value} <- crop_aspects()}
              type="button"
              class="btn btn-sm btn-ghost"
              data-pk-edit-aspect={value}
              aria-pressed={to_string(value == "")}
            >
              {label}
            </button>
            <button type="button" class="btn btn-sm btn-ghost" data-pk-edit-reset>
              {gettext("Reset")}
            </button>
          </div>

          <div class="modal-action mt-2 flex-wrap">
            <button type="button" class="btn btn-ghost text-error" data-pk-edit-skip>
              {gettext("Remove")}
            </button>
            <button type="button" class="btn btn-ghost" data-pk-edit-original>
              {gettext("Upload original")}
            </button>
            <button type="button" class="btn btn-primary" data-pk-edit-apply>
              {gettext("Upload")}
            </button>
          </div>
        </div>
      </dialog>
    </div>
    """
  end

  defp crop_aspects do
    [
      {gettext("Free"), ""},
      {"1:1", "1/1"},
      {"4:3", "4/3"},
      {"3:2", "3/2"},
      {"16:9", "16/9"},
      {"3:4", "3/4"},
      {"9:16", "9/16"}
    ]
  end
end
