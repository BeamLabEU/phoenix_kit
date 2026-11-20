defmodule PhoenixKitWeb.Components.OAuthButtons do
  @moduledoc """
  OAuth authentication buttons component for Google, GitHub, and Facebook Sign-In.

  This component automatically checks if OAuth is available and configured.
  If OAuth is not available (dependencies not installed or not enabled in settings),
  the buttons will not be rendered.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext
  alias PhoenixKit.Users.OAuthAvailability
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.Icons

  @doc """
  Renders OAuth provider buttons for authentication.

  This component only renders buttons if:
  - OAuth is enabled in settings (oauth_enabled = true)
  - Ueberauth library is loaded
  - At least one provider is configured

  ## Examples

      <.oauth_buttons />
      <.oauth_buttons show_divider={false} />
      <.oauth_buttons class="mt-6" />
  """
  attr :class, :string, default: ""
  attr :show_divider, :boolean, default: true

  attr :return_to, :string,
    default: nil,
    doc:
      "Local post-login destination to carry through the OAuth round-trip. The callback stashes it as :oauth_return_to; without it a user sent to sign in from a protected page lands on the default instead."

  def oauth_buttons(assigns) do
    # Check each provider individually
    assigns =
      assigns
      |> assign(:google_enabled, OAuthAvailability.provider_enabled?(:google))
      |> assign(:github_enabled, OAuthAvailability.provider_enabled?(:github))
      |> assign(:facebook_enabled, OAuthAvailability.provider_enabled?(:facebook))

    # Check if at least one provider is enabled
    any_provider_enabled =
      assigns.google_enabled or assigns.github_enabled or assigns.facebook_enabled

    assigns = assign(assigns, :any_provider_enabled, any_provider_enabled)

    # Only a local path travels; anything else is dropped rather than handed
    # to the callback's session stash.
    assigns =
      assign(assigns, :return_query, oauth_return_query(assigns[:return_to]))

    ~H"""
    <%= if @any_provider_enabled do %>
      <div class={@class}>
        <%= if @show_divider do %>
          <div class="divider text-base-content/60">{gettext("Or continue with")}</div>
        <% end %>

        <div class="space-y-2">
          <%!-- Google Sign-In Button --%>
          <%!-- OAuth routes are non-localized, so we use locale: :none --%>
          <%= if @google_enabled do %>
            <.link
              href={Routes.path("/users/auth/google", locale: :none) <> @return_query}
              class="btn btn-outline w-full flex items-center justify-center gap-2 hover:bg-base-200 transition-all hover:scale-[1.02] active:scale-[0.98]"
            >
              <Icons.icon_google class="w-5 h-5" />
              <span>{gettext("Continue with Google")}</span>
            </.link>
          <% end %>
          <%!-- GitHub Sign-In Button --%>
          <%= if @github_enabled do %>
            <.link
              href={Routes.path("/users/auth/github", locale: :none) <> @return_query}
              class="btn btn-outline w-full flex items-center justify-center gap-2 hover:bg-base-200 transition-all hover:scale-[1.02] active:scale-[0.98]"
            >
              <Icons.icon_github class="w-5 h-5" />
              <span>{gettext("Continue with GitHub")}</span>
            </.link>
          <% end %>
          <%!-- Facebook Sign-In Button --%>
          <%= if @facebook_enabled do %>
            <.link
              href={Routes.path("/users/auth/facebook", locale: :none) <> @return_query}
              class="btn btn-outline w-full flex items-center justify-center gap-2 hover:bg-base-200 transition-all hover:scale-[1.02] active:scale-[0.98]"
            >
              <Icons.icon_facebook class="w-5 h-5" />
              <span>{gettext("Continue with Facebook")}</span>
            </.link>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  The enabled OAuth providers, in the order the sign-in pages show them.
  """
  @spec enabled_providers() :: [:google | :github | :facebook]
  def enabled_providers do
    Enum.filter([:google, :github, :facebook], &OAuthAvailability.provider_enabled?/1)
  end

  @doc """
  One compact button per enabled provider, named by the provider alone
  ("Google"), for the grid of sign-in methods at the top of the sign-in and
  sign-up pages (`PhoenixKitWeb.Components.AuthMethods`). Renders the links
  only, with no wrapper, so each one is a cell of the caller's grid.
  """
  attr :providers, :list, required: true, doc: "from `enabled_providers/0`"
  attr :return_to, :string, default: nil

  def provider_links(assigns) do
    assigns = assign(assigns, :return_query, oauth_return_query(assigns[:return_to]))

    ~H"""
    <.link
      :for={provider <- @providers}
      href={Routes.path("/users/auth/#{provider}", locale: :none) <> @return_query}
      class="btn btn-outline w-full gap-2"
    >
      <.provider_icon provider={provider} />
      <span>{provider_name(provider)}</span>
    </.link>
    """
  end

  attr :provider, :atom, required: true

  defp provider_icon(%{provider: :google} = assigns),
    do: ~H(<Icons.icon_google class="w-5 h-5" />)

  defp provider_icon(%{provider: :github} = assigns),
    do: ~H(<Icons.icon_github class="w-5 h-5" />)

  defp provider_icon(%{provider: :facebook} = assigns),
    do: ~H(<Icons.icon_facebook class="w-5 h-5" />)

  # Brand names, not translated.
  defp provider_name(:google), do: "Google"
  defp provider_name(:github), do: "GitHub"
  defp provider_name(:facebook), do: "Facebook"

  defp oauth_return_query(return_to) do
    if is_binary(return_to) and Routes.local_path?(return_to) do
      "?" <> URI.encode_query(%{"return_to" => return_to})
    else
      ""
    end
  end
end
