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
  its text), `{{text}}`, `{{quote}}` (the message it carries, with its
  writer's name — a comment, a reason — empty when none), `{{url}}` (empty when the notification has no
  link), `{{reason}}` (the setting line that sent it, "You get this because
  “…” is on.") and `{{settings_url}}` (where the reader changes it) — all
  already rendered in the reader's language; the last two empty when no
  line owns the notification.
  """

  @behaviour PhoenixKit.Notifications.Channel

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Swoosh.Email

  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.Mailer
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

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
    user = Auth.get_user(envelope.recipient_uuid)

    case User.delivery_email(user) do
      # An address nobody has proven gets no notification mail
      # (`Auth.unsolicited_mail_allowed?/1`). `:ok`, not an error: a permanent
      # error switches the channel off, and it must work once they confirm.
      address when is_binary(address) and address != "" ->
        if Auth.unsolicited_mail_allowed?(user),
          do: send_email(user, address, envelope),
          else: :ok

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
          "quote" => Map.get(envelope, :quote) || "",
          "url" => envelope.url || "",
          "reason" => Map.get(envelope, :reason) || "",
          "settings_url" => Map.get(envelope, :reason_url) || ""
        },
        &CoreTemplates.notification_defaults/0
      )

    email =
      new()
      |> to(address)
      |> from({Mailer.get_from_name(), Mailer.get_from_email()})
      |> subject(content.subject)
      |> text_body(trim(content.text))
      |> html_body(content.html)

    result = Mailer.deliver_email(email, category: "notifications")

    case result do
      {:ok, _} -> :ok
      # A blocklisted recipient (hard bounce / complaint) won't recover on retry.
      {:error, {:blocked, reason}} -> {:error, {:permanent, reason}}
      {:error, reason} -> {:error, {:transient, reason}}
    end
  end

  defp subject_for(%{title: title}) when is_binary(title) and title != "", do: title
  defp subject_for(%{text: text}), do: String.slice(text, 0, 120)

  # A notification without a link leaves the default's `{{url}}` line empty.
  # An empty variable (no quote, no reason) leaves its blank lines behind.
  defp trim(text) when is_binary(text),
    do: text |> String.replace(~r/\n{3,}/, "\n\n") |> String.trim_trailing()

  defp trim(text), do: text
end
