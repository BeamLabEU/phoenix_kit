defmodule PhoenixKitWeb.Components.Core.OAuthProvider do
  @moduledoc """
  Reusable component for OAuth provider credential forms.
  """

  use Phoenix.Component

  @doc """
  Renders an OAuth provider credential form with fields, test button, and setup instructions.

  ## Attributes
  - `provider` - The provider name (:google, :apple, :github, :facebook)
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
      if(@provider in [:google, :apple], do: "hidden", else: "card bg-base-200 p-4 mt-3"),
      if(!@enabled, do: "hidden", else: "")
    ]}>
      <%!-- Special handling for Google and Apple providers --%>
      <%= if @provider in [:google, :apple] do %>
        <div class="card bg-base-200 p-4 mt-3">
          <h3 class="font-semibold mb-3 flex items-center gap-2">
            {@provider_config.icon}
            {@provider_config.title}
          </h3>

          <%= for field <- @provider_config.fields do %>
            <div class="form-control">
              <label class="label">
                <span class="label-text">{field.label}</span>
              </label>
              <%= if field.type == :textarea do %>
                <textarea
                  name={field.name}
                  rows={field.rows || 3}
                  placeholder={field.placeholder}
                  class="textarea textarea-bordered font-mono text-xs"
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
            Test Credentials
          </button>
        </div>
      <% else %>
        <h3 class="font-semibold mb-3 flex items-center gap-2">
          {@provider_config.icon}
          {@provider_config.title}
        </h3>

        <%= for field <- @provider_config.fields do %>
          <div class="form-control">
            <label class="label">
              <span class="label-text">{field.label}</span>
            </label>
            <input
              type={field.type}
              name={field.name}
              value={@settings[field.setting_key] || ""}
              placeholder={field.placeholder}
              class="input input-bordered"
            />
          </div>
        <% end %>

        <button
          type="button"
          phx-click="test_oauth"
          phx-value-provider={@provider}
          class="btn btn-sm btn-outline mt-3 w-fit"
        >
          Test Credentials
        </button>
      <% end %>
    </div>
    """
  end

  # Private helper to get provider configuration
  defp get_provider_config(:google) do
    %{
      title: "Google OAuth Credentials",
      icon: "<icon_google class=\"h-5 w-5\" />",
      fields: [
        %{
          label: "Client ID",
          type: "text",
          name: "settings[oauth_google_client_id]",
          setting_key: "oauth_google_client_id",
          placeholder: "Your Google OAuth Client ID",
          class: "input input-bordered"
        },
        %{
          label: "Client Secret",
          type: "password",
          name: "settings[oauth_google_client_secret]",
          setting_key: "oauth_google_client_secret",
          placeholder: "Your Google OAuth Client Secret",
          class: "input input-bordered"
        }
      ]
    }
  end

  defp get_provider_config(:apple) do
    %{
      title: "Apple OAuth Credentials",
      icon: "<icon_apple class=\"h-5 w-5\" />",
      fields: [
        %{
          label: "Client ID",
          type: "text",
          name: "settings[oauth_apple_client_id]",
          setting_key: "oauth_apple_client_id",
          placeholder: "com.yourapp.service",
          class: "input input-bordered"
        },
        %{
          label: "Team ID",
          type: "text",
          name: "settings[oauth_apple_team_id]",
          setting_key: "oauth_apple_team_id",
          placeholder: "Your Apple Team ID",
          class: "input input-bordered"
        },
        %{
          label: "Key ID",
          type: "text",
          name: "settings[oauth_apple_key_id]",
          setting_key: "oauth_apple_key_id",
          placeholder: "Your Apple Key ID",
          class: "input input-bordered"
        },
        %{
          label: "Private Key",
          type: :textarea,
          name: "settings[oauth_apple_private_key]",
          setting_key: "oauth_apple_private_key",
          placeholder:
            "-----BEGIN PRIVATE KEY-----\nYour Apple private key content\n-----END PRIVATE KEY-----",
          rows: 5,
          class: "textarea textarea-bordered font-mono text-xs"
        }
      ]
    }
  end

  defp get_provider_config(:github) do
    %{
      title: "GitHub OAuth Credentials",
      icon: "<icon_github class=\"h-5 w-5\" />",
      fields: [
        %{
          label: "Client ID",
          type: "text",
          name: "settings[oauth_github_client_id]",
          setting_key: "oauth_github_client_id",
          placeholder: "Your GitHub OAuth Client ID",
          class: "input input-bordered"
        },
        %{
          label: "Client Secret",
          type: "password",
          name: "settings[oauth_github_client_secret]",
          setting_key: "oauth_github_client_secret",
          placeholder: "Your GitHub OAuth Client Secret",
          class: "input input-bordered"
        }
      ]
    }
  end

  defp get_provider_config(:facebook) do
    %{
      title: "Facebook OAuth Credentials",
      icon: "<icon_facebook class=\"h-5 w-5\" />",
      fields: [
        %{
          label: "App ID",
          type: "text",
          name: "settings[oauth_facebook_app_id]",
          setting_key: "oauth_facebook_app_id",
          placeholder: "Your Facebook App ID",
          class: "input input-bordered"
        },
        %{
          label: "App Secret",
          type: "password",
          name: "settings[oauth_facebook_app_secret]",
          setting_key: "oauth_facebook_app_secret",
          placeholder: "Your Facebook App Secret",
          class: "input input-bordered"
        }
      ]
    }
  end
end
