defmodule PhoenixKitWeb.Components.Core.OAuthProvider do
  @moduledoc """
  Reusable component for OAuth provider credential forms.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc """
  Renders an OAuth provider credential form with fields, test button, and setup instructions.

  ## Attributes
  - `provider` - The provider name (:google, :github, :facebook)
  - `enabled` - Boolean indicating if this provider is enabled
  - `settings` - Map of current settings values
  - `callback_url` - The OAuth callback URL for this provider
  """

  attr :provider, :atom, required: true
  attr :enabled, :boolean, required: true
  attr :settings, :map, required: true
  attr :callback_url, :string, required: true

  def oauth_provider_credentials(assigns) do
    assigns = assign(assigns, :provider_config, get_provider_config(assigns.provider))

    ~H"""
    <div class={[
      if(@provider == :google, do: "hidden", else: "card bg-base-200 p-4 mt-3"),
      if(!@enabled, do: "hidden", else: "")
    ]}>
      <%!-- Special handling for the Google provider --%>
      <%= if @provider == :google do %>
        <div class="card bg-base-200 p-4 mt-3">
          <h3 class="font-semibold mb-3 flex items-center gap-2">
            {@provider_config.icon}
            {@provider_config.title}
          </h3>

          <%= for field <- @provider_config.fields do %>
            <div class="fieldset">
              <label class="label">
                <span class="fieldset-legend">{field.label}</span>
              </label>
              <%= if field.type == :textarea do %>
                <textarea
                  name={field.name}
                  rows={field.rows || 3}
                  placeholder={field.placeholder}
                  class="textarea font-mono text-xs"
                >{@settings[field.setting_key] || ""}</textarea>
              <% else %>
                <input
                  type={field.type}
                  name={field.name}
                  value={@settings[field.setting_key] || ""}
                  placeholder={field.placeholder}
                  class={field.class}
                />
              <% end %>
            </div>
          <% end %>

          <button
            type="button"
            phx-click="test_oauth"
            phx-value-provider={@provider}
            class="btn btn-sm btn-outline mt-3 w-fit"
          >
            {gettext("Test Credentials")}
          </button>
        </div>
      <% else %>
        <h3 class="font-semibold mb-3 flex items-center gap-2">
          {@provider_config.icon}
          {@provider_config.title}
        </h3>

        <%= for field <- @provider_config.fields do %>
          <div class="fieldset">
            <label class="label">
              <span class="fieldset-legend">{field.label}</span>
            </label>
            <input
              type={field.type}
              name={field.name}
              value={@settings[field.setting_key] || ""}
              placeholder={field.placeholder}
              class="input"
            />
          </div>
        <% end %>

        <button
          type="button"
          phx-click="test_oauth"
          phx-value-provider={@provider}
          class="btn btn-sm btn-outline mt-3 w-fit"
        >
          {gettext("Test Credentials")}
        </button>
      <% end %>
    </div>
    """
  end

  # Private helper to get provider configuration
  defp get_provider_config(:google) do
    %{
      title: gettext("Google OAuth Credentials"),
      icon: "<icon_google class=\"h-5 w-5\" />",
      fields: [
        %{
          label: gettext("Client ID"),
          type: "text",
          name: "settings[oauth_google_client_id]",
          setting_key: "oauth_google_client_id",
          placeholder: gettext("Your Google OAuth Client ID"),
          class: "input"
        },
        %{
          label: gettext("Client Secret"),
          type: "password",
          name: "settings[oauth_google_client_secret]",
          setting_key: "oauth_google_client_secret",
          placeholder: gettext("Your Google OAuth Client Secret"),
          class: "input"
        }
      ]
    }
  end

  defp get_provider_config(:github) do
    %{
      title: gettext("GitHub OAuth Credentials"),
      icon: "<icon_github class=\"h-5 w-5\" />",
      fields: [
        %{
          label: gettext("Client ID"),
          type: "text",
          name: "settings[oauth_github_client_id]",
          setting_key: "oauth_github_client_id",
          placeholder: gettext("Your GitHub OAuth Client ID"),
          class: "input"
        },
        %{
          label: gettext("Client Secret"),
          type: "password",
          name: "settings[oauth_github_client_secret]",
          setting_key: "oauth_github_client_secret",
          placeholder: gettext("Your GitHub OAuth Client Secret"),
          class: "input"
        }
      ]
    }
  end

  defp get_provider_config(:facebook) do
    %{
      title: gettext("Facebook OAuth Credentials"),
      icon: "<icon_facebook class=\"h-5 w-5\" />",
      fields: [
        %{
          label: gettext("App ID"),
          type: "text",
          name: "settings[oauth_facebook_app_id]",
          setting_key: "oauth_facebook_app_id",
          placeholder: gettext("Your Facebook App ID"),
          class: "input"
        },
        %{
          label: gettext("App Secret"),
          type: "password",
          name: "settings[oauth_facebook_app_secret]",
          setting_key: "oauth_facebook_app_secret",
          placeholder: gettext("Your Facebook App Secret"),
          class: "input"
        }
      ]
    }
  end
end
