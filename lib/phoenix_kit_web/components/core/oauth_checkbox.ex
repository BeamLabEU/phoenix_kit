defmodule PhoenixKitWeb.Components.Core.OAuthCheckbox do
  @moduledoc """
  Reusable component for OAuth provider checkboxes with conditional styling.
  """

  use Phoenix.Component

  @doc """
  Renders an OAuth provider checkbox with conditional disable styling.

  ## Attributes
  - `provider` - The provider name (:google, :apple, :github, :facebook)
  - `provider_label` - Display label for the provider (e.g., "Google Sign-In")
  - `master_enabled` - Boolean indicating if OAuth master switch is enabled
  - `provider_enabled` - Boolean indicating if this specific provider is enabled
  """

  attr :provider, :atom, required: true
  attr :provider_label, :string, required: true
  attr :master_enabled, :boolean, required: true
  attr :provider_enabled, :boolean, required: true

  def oauth_provider_checkbox(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <input name={"settings[oauth_#{@provider}_enabled]"} type="hidden" value="false" />
      <input
        name={"settings[oauth_#{@provider}_enabled]"}
        type="checkbox"
        value="true"
        checked={@provider_enabled}
        class={[
          "checkbox checkbox-primary",
          if(!@master_enabled, do: "pointer-events-none", else: "")
        ]}
      />
      <span class="label-text">{@provider_label}</span>
    </div>
    """
  end
end
