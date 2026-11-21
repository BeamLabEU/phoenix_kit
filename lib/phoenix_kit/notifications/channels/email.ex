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
  its text, on one line), `{{text}}`, `{{quote}}` (the message it carries,
  with its writer's name — a comment, a reason — empty when none), `{{url}}`
  and `{{action_label}}` (the button: the module's label or "Open"; both
  empty when the notification has no link), `{{reason}}` (the setting line
  that sent it, "You get this because “…” is on."), `{{settings_url}}` and
  `{{settings_label}}` ("Change") — all already rendered in the reader's
  language; the last three empty when no line owns the notification. The
  default is Markdown: a button, and the same words in the text version.
  """

  @behaviour PhoenixKit.Notifications.Channel

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Swoosh.Email

  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.Mailer
  alias PhoenixKit.Notifications.Messages
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
          "action_label" => action_label(envelope),
          "reason" => Map.get(envelope, :reason) || "",
          "settings_url" => Map.get(envelope, :reason_url) || "",
          "settings_label" => settings_label(envelope)
        },
        fn ->
          CoreTemplates.notification_defaults(
            link: action_label(envelope) != "",
            reason: settings_label(envelope) != ""
          )
        end,
        # What an operator saved in Settings → Notifications → Messages,
        # for this type and the reader's language, over everything else.
        overrides:
          Messages.for_message(
            Map.get(envelope, :type_key),
            "email",
            Map.get(envelope, :locale)
          )
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

  # One line, never more: a line break in a subject is a header injection
  # waiting to happen, and mail clients show only the first line anyway.
  defp subject_for(%{title: title}) when is_binary(title) and title != "", do: one_line(title)
  defp subject_for(%{text: text}), do: text |> one_line() |> String.slice(0, 120)

  defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  # The button's label: the module's ("Open task"), else "Open"; empty with
  # no link, so the button's paragraph is left out.
  defp action_label(%{url: url} = envelope) when is_binary(url) and url != "" do
    case Map.get(envelope, :action_label) do
      label when is_binary(label) and label != "" -> label
      _ -> gettext("Open")
    end
  end

  defp action_label(_envelope), do: ""

  defp settings_label(envelope) do
    if is_binary(Map.get(envelope, :reason_url)) and envelope.reason_url != "",
      do: gettext("Change"),
      else: ""
  end

  # A notification without a link leaves the default's `{{url}}` line empty.
  # An empty variable (no quote, no reason) leaves its blank lines behind.
  defp trim(text) when is_binary(text),
    do: text |> String.replace(~r/\n{3,}/, "\n\n") |> String.trim_trailing()

  defp trim(text), do: text
end
