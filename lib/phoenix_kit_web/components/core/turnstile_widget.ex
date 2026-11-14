defmodule PhoenixKitWeb.Components.Core.TurnstileWidget do
  @moduledoc """
  The Cloudflare Turnstile widget of a public form.

      <.turnstile_widget id="registration-turnstile" />

  Renders nothing while Turnstile is off (`PhoenixKit.Users.Turnstile`). Put it
  INSIDE the form: the widget adds the hidden `cf-turnstile-response` field
  next to itself, and that is what the submit carries. The LiveView checks it
  with `PhoenixKitWeb.Users.BotCheck.run/3`.

  The element is `phx-update="ignore"`: Cloudflare's script owns what is in it.
  """
  use Phoenix.Component

  alias PhoenixKit.Users.Turnstile

  attr :id, :string, required: true
  attr :class, :string, default: "mt-4"

  def turnstile_widget(assigns) do
    assigns = assign(assigns, :site_key, Turnstile.widget_site_key())

    ~H"""
    <div
      :if={@site_key}
      id={@id}
      phx-hook="Turnstile"
      phx-update="ignore"
      data-sitekey={@site_key}
      class={["min-h-[65px]", @class]}
    >
    </div>
    """
  end
end
