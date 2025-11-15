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

  import PhoenixKitWeb.Components.Core.Icon

  attr :upload, :any, required: true
  attr :label, :string, default: "Upload Files"
  attr :icon, :string, default: "hero-cloud-arrow-up"
  attr :accept_description, :string, default: nil
  attr :max_size_description, :string, default: nil

  attr :uploaded_file_ids, :list,
    default: nil,
    doc: "List of file IDs from last upload (for external use)"

  attr :variant, :string,
    default: "full",
    doc: "Display variant - 'full' for drag-drop zone, 'button' for simple button only"

  def file_upload(assigns) do
    case assigns.variant do
      "button" -> button_upload(assigns)
      _ -> full_upload(assigns)
    end
  end

  defp full_upload(assigns) do
    ~H"""
    <div class="space-y-4">
      <form phx-change="validate" id={"upload-form-" <> @upload.ref}>
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
                <p class="font-semibold text-base-content">Drag files here or click to browse</p>
                <p class="text-sm text-base-content/70 mt-1">
                  <%= if @accept_description do %>
                    {@accept_description}
                  <% else %>
                    Drop your files to upload
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
              Maximum file size: {@max_size_description}
            <% end %>
          </p>
        <% end %>
      </form>

      <%!-- Active Uploads --%>
      <%= if length(@upload.entries) > 0 do %>
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
              </div>

              <%!-- Cancel Button --%>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="btn btn-xs btn-ghost text-error"
                title="Cancel upload"
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

  defp button_upload(assigns) do
    ~H"""
    <div class="space-y-3">
      <form phx-change="validate" id={"button-upload-form-" <> @upload.ref}>
        <label
          for={@upload.ref}
          class="btn btn-primary btn-block"
        >
          <.icon name={@icon} class="w-5 h-5" /> {@label}
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
              </div>

              <%!-- Cancel Button --%>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="btn btn-xs btn-ghost text-error"
                title="Cancel upload"
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
