defmodule PhoenixKitWeb.Components.Core.OAuthUtils do
  @moduledoc """
  Utility components for OAuth functionality.
  """

  use Phoenix.Component
  import PhoenixKitWeb.Components.Core.Icon

  @doc """
  Displays a callback URL with a copy-to-clipboard button.
  """
  attr :url, :string, required: true
  attr :provider_name, :string, required: true
  attr :class, :string, default: nil

  def callback_url_copy(assigns) do
    assigns = assign_new(assigns, :class, fn -> nil end)

    ~H"""
    <div class={@class}>
      <div class="text-sm font-medium mb-2">Callback URL</div>
      <div class="flex items-center gap-2">
        <code class="flex-1 px-3 py-2 bg-base-200 text-base-content border border-base-300 rounded font-mono text-xs break-all">
          {@url}
        </code>
        <button
          type="button"
          class="btn btn-sm btn-square btn-outline"
          onclick={"navigator.clipboard.writeText('#{@url}')"}
          title="Copy to clipboard"
        >
          <.icon name="hero-clipboard" class="h-4 w-4" />
        </button>
      </div>
      <div class="text-xs text-base-content/60 mt-2">
        Copy this URL to {@provider_name} OAuth configuration
      </div>
    </div>
    """
  end

  @doc """
  Displays reverse proxy notice for OAuth providers.
  """
  attr :class, :string, default: "text-xs text-base-content/60 mt-2"

  def reverse_proxy_notice(assigns) do
    ~H"""
    <div class={@class}>
      <strong>Note:</strong> If using reverse proxy, ensure the callback URL
      reflects the external domain, not the internal one.
    </div>
    """
  end
end
