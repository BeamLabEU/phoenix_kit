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
    # A switch with no credentials is not a way in: the same list the sign-in
    # and sign-up pages use. Only a local path travels; anything else is
    # dropped rather than handed to the callback's session stash.
    assigns =
      assigns
      |> assign(:providers, OAuthAvailability.configured_providers())
      |> assign(:return_query, oauth_return_query(assigns[:return_to]))

    ~H"""
    <div :if={@providers != []} class={@class}>
      <div :if={@show_divider} class="divider text-base-content/60">
        {gettext("Or continue with")}
      </div>

      <div class="space-y-2">
        <%!-- OAuth routes are non-localized, so we use locale: :none --%>
        <.link
          :for={provider <- @providers}
          href={Routes.path("/users/auth/#{provider}", locale: :none) <> @return_query}
          class="btn btn-outline w-full flex items-center justify-center gap-2 hover:bg-base-200 transition-all hover:scale-[1.02] active:scale-[0.98]"
        >
          <.provider_icon provider={provider} />
          <span>{continue_label(provider)}</span>
        </.link>
      </div>
    </div>
    """
  end

  # Brand names stay inside the sentence so each one remains its own msgid.
  defp continue_label(:google), do: gettext("Continue with Google")
  defp continue_label(:github), do: gettext("Continue with GitHub")
  defp continue_label(:facebook), do: gettext("Continue with Facebook")

  @doc """
  One compact button per provider that has credentials, named by the provider alone
  ("Google"), for the grid of sign-in methods at the top of the sign-in and
  sign-up pages (`PhoenixKitWeb.Components.AuthMethods`). Renders the links
  only, with no wrapper, so each one is a cell of the caller's grid.
  """
  attr :providers, :list, required: true, doc: "from `OAuthAvailability.configured_providers/0`"
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
