defmodule PhoenixKit.Notifications.Channels.Email do
  @moduledoc """
  Email notification channel — delivers a user's notifications to their account
  email address via `PhoenixKit.Mailer`.

  Unlike Telegram, email needs **no setup**: every user has an account email, so
  `configured?/2` is always true and the Email column is available from the
  start. There's no per-user connection or config beyond the routing/cadence the
  matrix + aggregation popup write.

  The message is core's `notification` email (`PhoenixKit.Email.Content`), so
  it is sent in the shared layout with the site's branding, can be rewritten
  with override files like any other email, and shows in the admin preview.
  Its variables are `{{subject}}` (the notification's title, or the start of
  its text), `{{text}}` and `{{url}}` (empty when the notification has no
  link) — all already rendered in the reader's language.
  """

  @behaviour PhoenixKit.Notifications.Channel

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Swoosh.Email

  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.Email.Provider
  alias PhoenixKit.Mailer
  alias PhoenixKit.Users.Auth

  @impl true
  def key, do: "email"

  @impl true
  def label, do: gettext("Email")

  @impl true
  def icon, do: "hero-envelope"

  # Always available — nothing to connect. (A user with no address can't be
  # reached, but that's a delivery-time miss, not a configuration state.)
  @impl true
  def configured?(_user_uuid, _config), do: true

  @impl true
  def deliver(envelope, _config) do
    case Auth.get_user(envelope.recipient_uuid) do
      %{email: address} = user when is_binary(address) and address != "" ->
        send_email(user, address, envelope)

      _ ->
        {:error, {:permanent, :no_recipient_email}}
    end
  end

  @impl true
  def validate_config(config) when is_map(config), do: {:ok, config}

  # --- Internals ------------------------------------------------------------

  defp send_email(user, address, envelope) do
    content =
      Content.resolve(
        "notification",
        user,
        %{
          "subject" => subject_for(envelope),
          "text" => envelope.text,
          "url" => envelope.url || ""
        },
        &CoreTemplates.notification_defaults/0
      )

    if content.db_template, do: Provider.current().track_usage(content.db_template)

    email =
      new()
      |> to(address)
      |> from({Mailer.get_from_name(), Mailer.get_from_email()})
      |> subject(content.subject)
      |> text_body(trim(content.text))
      |> html_body(content.html)

    case Mailer.deliver_email(email, category: "notifications") do
      {:ok, _} -> :ok
      # A blocklisted recipient (hard bounce / complaint) won't recover on retry.
      {:error, {:blocked, reason}} -> {:error, {:permanent, reason}}
      {:error, reason} -> {:error, {:transient, reason}}
    end
  end

  defp subject_for(%{title: title}) when is_binary(title) and title != "", do: title
  defp subject_for(%{text: text}), do: String.slice(text, 0, 120)

  # A notification without a link leaves the default's `{{url}}` line empty.
  defp trim(text) when is_binary(text), do: String.trim_trailing(text)
  defp trim(text), do: text
end
