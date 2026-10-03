defmodule PhoenixKit.Users.Auth.UserNotifier do
  @moduledoc """
  User notification system for PhoenixKit authentication workflows.

  This module handles email delivery for user authentication and account management workflows,
  including account confirmation, password reset, and email change notifications.

  ## Email Types

  - **Confirmation instructions**: Sent during user registration
  - **Password reset instructions**: Sent when user requests password reset
  - **Email update instructions**: Sent when user changes their email address

  ## Configuration

  Configure your mailer in your application config:

      config :phoenix_kit, PhoenixKit.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        # ... other adapter configuration

  ## Customization

  Override this module in your application to customize email templates
  and delivery behavior while maintaining the same function signatures.
  """
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Swoosh.Email

  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.Email.Provider
  alias PhoenixKit.Mailer
  alias PhoenixKit.Users.LoginAttempts
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.TimeZone

  # Every templated auth email resolves identically and differs only in its
  # name, its variables and its default copy — so the resolution, the usage
  # tracking and the send live here once instead of five times.
  #
  # `recipient` is what the locale is resolved from (a user struct, or a bare
  # address where no account exists yet); `address` is who it is sent to. They
  # differ only on the magic-link registration path.
  defp deliver_templated(recipient, address, name, variables, defaults) do
    content = Content.resolve(name, recipient, variables, defaults)

    if content.db_template, do: Provider.current().track_usage(content.db_template)

    deliver(address, content.subject, content.text, content.html)
  end

  # Delivers the email using the appropriate mailer.
  # Uses the configured parent application mailer if available,
  # otherwise falls back to PhoenixKit's built-in mailer.
  defp deliver(recipient, subject, text_body, html_body) do
    from_email = get_from_email()
    from_name = get_from_name()

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(text_body)
      |> html_body(html_body)

    with {:ok, _metadata} <-
           Mailer.deliver_email(email,
             user_uuid: nil,
             template_name: "user_notification",
             campaign_id: "authentication"
           ) do
      {:ok, email}
    end
  end

  # Get the from email address from configuration or use a default
  # Priority: Settings Database > Config file > Default
  defp get_from_email do
    # Priority 1: Settings Database (runtime)
    case PhoenixKit.Settings.get_setting("from_email") do
      nil ->
        # Priority 2: Config file (compile-time, fallback)
        case PhoenixKit.Config.get(:from_email) do
          {:ok, email} -> email
          # Priority 3: Default
          _ -> "noreply@localhost"
        end

      email ->
        email
    end
  end

  # Get the from name from configuration or use a default
  # Priority: Settings Database > Config file > Default
  defp get_from_name do
    # Priority 1: Settings Database (runtime)
    case PhoenixKit.Settings.get_setting("from_name") do
      nil ->
        # Priority 2: Config file (compile-time, fallback)
        case PhoenixKit.Config.get(:from_name) do
          {:ok, name} -> name
          # Priority 3: Default
          _ -> "PhoenixKit"
        end

      name ->
        name
    end
  end

  @doc """
  Deliver instructions to confirm account.
  """
  def deliver_confirmation_instructions(user, url) do
    deliver_templated(
      user,
      user.email,
      "register",
      %{"user_email" => user.email, "confirmation_url" => url},
      &CoreTemplates.register_defaults/0
    )
  end

  @doc """
  Deliver instructions to reset a user password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver_templated(
      user,
      user.email,
      "reset_password",
      %{"user_email" => user.email, "reset_url" => url},
      &CoreTemplates.reset_password_defaults/0
    )
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver_templated(
      user,
      user.email,
      "update_email",
      %{"user_email" => user.email, "update_url" => url},
      &CoreTemplates.update_email_defaults/0
    )
  end

  @doc """
  Deliver the welcome email to a user who has just confirmed their address.

  Called only by `PhoenixKit.Users.WelcomeEmailWorker`, after the
  confirmation commits — see `PhoenixKit.Users.WelcomeEmail` for when and
  how often.
  """
  def deliver_welcome(user) do
    deliver_templated(
      user,
      user.email,
      "welcome",
      CoreTemplates.welcome_variables(user.email),
      &CoreTemplates.welcome_defaults/0
    )
  end

  @doc """
  Deliver organization invitation email to a new (unregistered) user.

  Sends a registration link containing the invitation token so the invitee
  can register and automatically join the organization on email confirmation.
  """
  def deliver_organization_invitation(email, organization_name, registration_url) do
    deliver_templated(
      email,
      email,
      "organization_invitation",
      %{
        "user_email" => email,
        "organization_name" => organization_name,
        "registration_url" => registration_url
      },
      &CoreTemplates.organization_invitation_defaults/0
    )
  end

  @doc """
  Deliver magic link registration instructions.

  Accepts a user struct or a bare address: on this path the account does not
  exist yet, so there may be no stored locale preference to resolve.
  """
  def deliver_magic_link_registration(user_or_email, url) do
    email =
      case user_or_email do
        %{email: email} -> email
        email when is_binary(email) -> email
      end

    deliver_templated(
      user_or_email,
      email,
      "magic_link_registration",
      %{"user_email" => email, "registration_url" => url},
      &CoreTemplates.magic_link_registration_defaults/0
    )
  end

  @doc """
  Deliver a "new login detected" security alert.

  Sent by `PhoenixKit.Users.LoginAlerts` when a login is seen from a
  device (IP + user-agent pair) not previously associated with the
  account. `attrs` carries `:ip_address`, `:browser`, `:os` (either may be
  `nil`), `:location` (a "City, Country" string, or `nil` if geolocation
  didn't resolve), and `:first_seen_at` (a `DateTime`).
  """
  def deliver_new_login_alert(user, attrs) do
    browser_os = [attrs[:browser], attrs[:os]] |> Enum.filter(& &1) |> Enum.join(" on ")

    # The winning content layer is rendered in the recipient's locale, so the
    # strings built here have to be too — otherwise a German reader gets
    # "Unknown" in whichever locale the signing-in request happened to be
    # served in.
    variables =
      RecipientLocale.in_locale(RecipientLocale.for_rendering(user), fn ->
        %{
          "user_email" => user.email,
          "login_time" => login_time(user, attrs.first_seen_at),
          "ip_address" => attrs.ip_address,
          "location" => CoreTemplates.location_line(attrs[:location]),
          "browser_os" => (browser_os == "" && gettext("Unknown")) || browser_os,
          # The line that separates "my new laptop" from "someone finally
          # guessed it". Empty (not "0") when there is nothing to report, and
          # it carries its own trailing blank line so the paragraph collapses
          # cleanly instead of leaving a gap.
          "failed_attempts" => failed_attempts_note(user),
          # The one email that reaches a genuinely compromised account was, until
          # now, the one with no way to act on it: it said "change your password
          # immediately" and gave the reader nothing to click.
          "security_url" => Routes.base_url() <> Routes.user_settings_path()
        }
      end)

    deliver_templated(
      user,
      user.email,
      "new_login_alert",
      variables,
      &CoreTemplates.new_login_alert_defaults/0
    )
  end

  @doc """
  Warns `user` that their account is being hammered.

  Sent when failures cross `failed_login_alert_threshold` inside an hour, at
  most once a day per account — `PhoenixKit.Users.LoginAttempts` owns both
  gates. Unlike the new-device alert, nothing here means a sign-in SUCCEEDED;
  the point is to reach the reader while it is still only attempts.
  """
  def deliver_failed_login_alert(user, attrs) do
    variables =
      RecipientLocale.in_locale(RecipientLocale.for_rendering(user), fn ->
        %{
          "user_email" => user.email,
          "attempt_count" => Integer.to_string(attrs.count),
          "window_hours" => Integer.to_string(attrs.window_hours),
          "security_url" => Routes.base_url() <> Routes.user_settings_path()
        }
      end)

    deliver_templated(
      user,
      user.email,
      "failed_login_alert",
      variables,
      &CoreTemplates.failed_login_alert_defaults/0
    )
  end

  # 24 hours, not "since your last successful sign-in": the latter needs a
  # timestamp core does not keep, and the fixed window answers the question the
  # reader actually has — does this sign-in look like the end of an attack?
  defp failed_attempts_note(user) do
    since = DateTime.add(DateTime.utc_now(), -86_400, :second)

    user |> LoginAttempts.count_for_user_since(since) |> CoreTemplates.failed_attempts_note()
  end

  # The line exists so the reader can answer "was that me?", which nobody can
  # do against UTC. Rendered in their own timezone (their preference, else the
  # site's) and named, so the number is not ambiguous.
  #
  # Date and time are formatted separately because
  # `Utils.Date.format_datetime_with_user_timezone/2` returns the date ALONE --
  # it ends in `format_datetime/2`, which drops to `NaiveDateTime.to_date/1`.
  # This is the same pairing the admin lists use.
  defp login_time(user, at) do
    date = UtilsDate.format_date_with_user_timezone(at, user)
    time = UtilsDate.format_time_with_user_timezone(at, user)

    "#{date} #{time} #{zone_suffix(at, UtilsDate.get_user_timezone(user))}"
  end

  # An IANA zone knows its own abbreviation for the instant being shown ("CEST"
  # in summer, "CET" in winter); a legacy numeric offset does not, so it falls
  # back to the "UTC+05:00" label. Never the raw `zone_abbr` for the numeric
  # case: `TimeZone.shift/2` adds seconds there and leaves the struct saying
  # "UTC", which would label a shifted clock as UTC.
  defp zone_suffix(%DateTime{} = at, zone) do
    if TimeZone.identifier?(zone) do
      %DateTime{zone_abbr: abbr} = TimeZone.shift(at, zone)
      abbr
    else
      TimeZone.label(zone)
    end
  end

  defp zone_suffix(_at, zone), do: TimeZone.label(zone)
end
