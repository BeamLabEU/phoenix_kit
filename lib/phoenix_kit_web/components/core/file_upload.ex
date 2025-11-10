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

  def file_upload(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- Upload Form with phx-change on form not file input --%>
      <form phx-change="validate" id={"upload-form-" <> @upload.ref}>
        <label for={@upload.ref} class="btn btn-primary cursor-pointer">
          <.icon name={@icon} class="w-4 h-4 mr-2" />
          {@label}
        </label>
        <.live_file_input upload={@upload} class="hidden" />
      </form>

      <%!-- File Type and Size Info --%>
      <%= if @accept_description != nil or @max_size_description != nil do %>
        <p class="text-sm text-base-content/70">
          <%= if @accept_description do %>
            Supported formats: {@accept_description}
            <%= if @max_size_description do %>
              <br />
            <% end %>
          <% end %>
          <%= if @max_size_description do %>
            Maximum file size: {@max_size_description}
          <% end %>
        </p>
      <% end %>

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
end
