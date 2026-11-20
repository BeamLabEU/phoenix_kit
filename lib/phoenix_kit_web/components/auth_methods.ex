defmodule PhoenixKitWeb.Components.AuthMethods do
  @moduledoc """
  The other ways in, at the top of the sign-in and sign-up pages: passkey,
  magic link, QR code and the OAuth providers, two short buttons to a row, then
  an "or" divider before the email form.

  At the top, because a site with several providers grows a long list, and at
  the bottom of the page that list ended up off the screen. Each button is named
  by the method alone ("Magic link", "Google"): the page's heading already says
  whether it signs in or creates an account.

      <.auth_methods :if={@any_method?}>
        <.link navigate={...} class="btn btn-outline w-full">Magic link</.link>
        <OAuthButtons.provider_links providers={@oauth_providers} />
      </.auth_methods>

  The children are the grid's cells: give each one `w-full`. An odd last cell
  spans both columns. Render the component only when at least one method is
  on, or the divider stands alone.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  attr :id, :string, default: "auth-methods"
  slot :inner_block, required: true

  def auth_methods(assigns) do
    ~H"""
    <div id={@id}>
      <div class="grid grid-cols-2 gap-2 [&>*:last-child:nth-child(odd)]:col-span-2">
        {render_slot(@inner_block)}
      </div>
      <%!-- mb-1: the form below adds its fieldset's and the first label's own
           padding, so this evens the space on both sides of the line. --%>
      <div class="divider mt-3 mb-1 text-sm text-base-content/60">{gettext("or")}</div>
    </div>
    """
  end
end
