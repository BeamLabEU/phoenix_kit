defmodule PhoenixKitWeb.Components.Core.TurnstileWidget do
  @moduledoc """
  The Cloudflare Turnstile widget of a public form.

      <.turnstile_widget id="registration-turnstile" />

  Put the widget inside the form so the submit includes `cf-turnstile-response`.
  Auth forms use the Authorization settings and `PhoenixKitWeb.Users.BotCheck.run/3`.
  Other forms pass their selected connection’s public `site_key` and check the token
  with `PhoenixKit.Integrations.Turnstile.verify/3`. A nil key hides the widget.

  The element is `phx-update="ignore"`: Cloudflare's script owns what is in it.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Users.Turnstile

  attr :id, :string, required: true

  attr :site_key, :string,
    doc: "Public key for a selected connection. Defaults to the auth form configuration."

  attr :class, :string, default: "mt-4"

  def turnstile_widget(assigns) do
    assigns = assign_new(assigns, :site_key, &Turnstile.widget_site_key/0)

    ~H"""
    <div
      :if={@site_key}
      id={@id}
      phx-hook="Turnstile"
      phx-update="ignore"
      data-sitekey={@site_key}
      data-failed-text={
        gettext(
          "The verification could not load, so this form cannot be sent. Your browser or network is blocking challenges.cloudflare.com: allow it (a content blocker is the usual cause), then reload the page."
        )
      }
      class={[
        "min-h-[65px] data-[turnstile-failed]:text-sm data-[turnstile-failed]:text-error",
        @class
      ]}
    >
    </div>
    """
  end
end
