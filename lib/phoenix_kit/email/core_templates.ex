defmodule PhoenixKit.Email.CoreTemplates do
  @moduledoc """
  The emails core itself sends, as `PhoenixKit.Email.Catalog` entries.

  Each email's default copy is a named function here, not a closure at the
  send site, because two callers need the same copy: the send
  (`PhoenixKit.Users.Auth.UserNotifier`, `PhoenixKit.Mailer.send_magic_link_email/2`)
  and the admin preview. One function means the preview can never show copy
  the send no longer uses.

  Every `*_defaults/0` is a zero-arity function so `PhoenixKit.Email.Content`
  can evaluate it inside the recipient's locale — see "Why the default is a
  function" there.

  The defaults are Markdown (`PhoenixKit.Email.Markdown`): the main action is
  a button — a paragraph that is exactly one `[label]({{url}})` link — with
  the address written out under it for a reader whose client does not show
  the button, and the plain-text body is derived from the same Markdown. A
  host that overrides `text.txt` alone still gets its own words in both
  bodies (see "Which part makes which body" in `PhoenixKit.Email.Content`).

  `notification` is the exception: its body is the notification's own text,
  already rendered in the reader's language, so its default is a plain `text`
  part with nothing to translate.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @sample_email "jane.doe@example.com"
  @sample_token "preview-token"

  @doc """
  The catalog entries for core's emails, in the order the admin lists them.

  Labels and descriptions are evaluated on the call, so call this in the
  locale they should read in. Defaults and sample variables are closures,
  evaluated later by the preview in the locale being previewed.
  """
  @spec entries() :: [PhoenixKit.Email.Catalog.entry()]
  def entries do
    [
      %{
        name: "register",
        label: gettext("Account confirmation"),
        description: gettext("Sent after registration, with the link that confirms the address."),
        defaults: &register_defaults/0,
        variables: fn ->
          %{"user_email" => @sample_email, "confirmation_url" => sample_url("/users/confirm")}
        end
      },
      %{
        name: "reset_password",
        label: gettext("Password reset"),
        description: gettext("Sent when someone asks to reset a forgotten password."),
        defaults: &reset_password_defaults/0,
        variables: fn ->
          %{"user_email" => @sample_email, "reset_url" => sample_url("/users/reset-password")}
        end
      },
      %{
        name: "update_email",
        label: gettext("Email change confirmation"),
        description: gettext("Sent to the new address when a user changes their email."),
        defaults: &update_email_defaults/0,
        variables: fn ->
          %{
            "user_email" => @sample_email,
            "update_url" => sample_url("/users/settings/confirm-email")
          }
        end
      },
      %{
        name: "magic_link",
        label: gettext("Magic link sign-in"),
        description:
          gettext("Sent when a user signs in with a one-time link instead of a password."),
        defaults: &magic_link_defaults/0,
        variables: fn ->
          %{"user_email" => @sample_email, "magic_link_url" => sample_url("/users/magic-link")}
        end
      },
      %{
        name: "magic_link_registration",
        label: gettext("Magic link registration"),
        description: gettext("Sent when someone registers with a one-time link."),
        defaults: &magic_link_registration_defaults/0,
        variables: fn ->
          %{
            "user_email" => @sample_email,
            "registration_url" => sample_url("/users/register/magic-link")
          }
        end
      },
      %{
        name: "organization_invitation",
        label: gettext("Organization invitation"),
        description: gettext("Sent to an address that is invited to join an organization."),
        defaults: &organization_invitation_defaults/0,
        variables: fn ->
          %{
            "user_email" => @sample_email,
            "organization_name" => "Acme Ltd",
            "registration_url" => sample_url("/users/register/invitation")
          }
        end
      },
      %{
        name: "new_login_alert",
        label: gettext("New login alert"),
        description:
          gettext("Sent when an account signs in from a device it has not used before."),
        defaults: &new_login_alert_defaults/0,
        variables: fn ->
          %{
            "user_email" => @sample_email,
            "login_time" => Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC"),
            "ip_address" => "203.0.113.24",
            "location" => location_line("Tallinn, Estonia"),
            "browser_os" => "Firefox on Linux",
            "failed_attempts" => failed_attempts_note(2),
            "security_url" => Routes.base_url() <> Routes.user_settings_path()
          }
        end
      },
      %{
        name: "failed_login_alert",
        label: gettext("Failed sign-in alert"),
        description: gettext("Sent when an account sees repeated failed sign-in attempts."),
        defaults: &failed_login_alert_defaults/0,
        variables: fn ->
          %{
            "user_email" => @sample_email,
            "attempt_count" => "12",
            "window_hours" => "1",
            "security_url" => Routes.base_url() <> Routes.user_settings_path()
          }
        end
      },
      %{
        name: "welcome",
        label: gettext("Welcome"),
        description:
          gettext(
            "Sent once, after an address is confirmed — only while the welcome email is switched on."
          ),
        defaults: &welcome_defaults/0,
        variables: fn -> welcome_variables(@sample_email) end
      },
      %{
        name: "notification",
        label: gettext("Notification"),
        description:
          gettext(
            "A notification delivered by email, one at a time or as a digest, when the reader routes it to email."
          ),
        defaults: &notification_defaults/0,
        variables: fn ->
          %{
            "subject" => gettext("Acme Ltd commented on your order"),
            "text" => gettext("Acme Ltd commented on your order"),
            "url" => Routes.url("/admin/notifications")
          }
        end
      }
    ]
  end

  defp sample_url(path), do: Routes.url("#{path}/#{@sample_token}")

  @doc """
  The variables of the welcome email for `email`: the address, and the site
  name and address the layout's footer shows (`{{site_name}}`,
  `{{site_url}}`), so the button leads where the footer does.
  """
  @spec welcome_variables(String.t()) :: %{String.t() => String.t()}
  def welcome_variables(email) when is_binary(email) do
    %{
      "user_email" => email,
      "site_name" => Settings.get_project_title(),
      "site_url" => Routes.base_url()
    }
  end

  @doc """
  Default of the notification email (`notification`): the subject is the
  notification's title (or the start of its text), the body its text and
  link. Nothing to translate — both arrive rendered in the reader's
  language.
  """
  @spec notification_defaults() :: PhoenixKit.Templates.defaults()
  def notification_defaults do
    %{subject: "{{subject}}", text: "{{text}}\n\n{{url}}"}
  end

  @doc "Default copy of the account confirmation email (`register`)."
  @spec register_defaults() :: PhoenixKit.Templates.defaults()
  def register_defaults do
    %{
      subject: gettext("Confirm your account"),
      markdown:
        gettext("""
        Hi {{user_email}},

        Please confirm your account with the button below.

        [Confirm account]({{confirmation_url}})

        If the button doesn't work, open this link: [{{confirmation_url}}]({{confirmation_url}})

        If you didn't create an account with us, please ignore this email.
        """)
    }
  end

  @doc "Default copy of the password reset email (`reset_password`)."
  @spec reset_password_defaults() :: PhoenixKit.Templates.defaults()
  def reset_password_defaults do
    %{
      subject: gettext("Reset your password"),
      markdown:
        gettext("""
        Hi {{user_email}},

        You can reset your password with the button below.

        [Reset password]({{reset_url}})

        If the button doesn't work, open this link: [{{reset_url}}]({{reset_url}})

        If you didn't request this change, please ignore this email.
        """)
    }
  end

  @doc "Default copy of the email change confirmation (`update_email`)."
  @spec update_email_defaults() :: PhoenixKit.Templates.defaults()
  def update_email_defaults do
    %{
      subject: gettext("Confirm your email change"),
      markdown:
        gettext("""
        Hi {{user_email}},

        You can change your email with the button below.

        [Confirm email change]({{update_url}})

        If the button doesn't work, open this link: [{{update_url}}]({{update_url}})

        If you didn't request this change, please ignore this email.
        """)
    }
  end

  @doc "Default copy of the magic link sign-in email (`magic_link`)."
  @spec magic_link_defaults() :: PhoenixKit.Templates.defaults()
  def magic_link_defaults do
    %{
      subject: gettext("Your secure login link"),
      markdown:
        gettext("""
        Hi {{user_email}},

        Use the button below to sign in. This link expires in 15 minutes.

        [Sign in]({{magic_link_url}})

        If the button doesn't work, open this link: [{{magic_link_url}}]({{magic_link_url}})

        If you didn't ask for this link, you can ignore this email.
        """)
    }
  end

  @doc "Default copy of the magic link registration email (`magic_link_registration`)."
  @spec magic_link_registration_defaults() :: PhoenixKit.Templates.defaults()
  def magic_link_registration_defaults do
    %{
      subject: gettext("Complete your registration"),
      markdown:
        gettext("""
        Hi {{user_email}},

        Welcome! To complete your registration, use the button below.

        [Complete registration]({{registration_url}})

        If the button doesn't work, open this link: [{{registration_url}}]({{registration_url}})

        This link will expire in 30 minutes for your security.

        If you didn't request this registration, please ignore this email.
        """)
    }
  end

  @doc "Default copy of the organization invitation (`organization_invitation`)."
  @spec organization_invitation_defaults() :: PhoenixKit.Templates.defaults()
  def organization_invitation_defaults do
    %{
      subject: gettext("You've been invited to join {{organization_name}}"),
      markdown:
        gettext("""
        Hi {{user_email}},

        {{organization_name}} has invited you to join their organization.

        To accept the invitation, register an account with the button below.

        [Accept invitation]({{registration_url}})

        If the button doesn't work, open this link: [{{registration_url}}]({{registration_url}})

        This invitation link will expire in 7 days.

        If you did not expect this invitation, you can safely ignore this email.
        """)
    }
  end

  @doc "Default copy of the new login alert (`new_login_alert`)."
  @spec new_login_alert_defaults() :: PhoenixKit.Templates.defaults()
  def new_login_alert_defaults do
    %{
      subject: gettext("New login to your account"),
      markdown:
        gettext("""
        Hi {{user_email}},

        We noticed a new login to your account from an unrecognized device:

        - Time: {{login_time}}
        - IP address: {{ip_address}}
        - Location: {{location}}
        - Device: {{browser_os}}

        {{failed_attempts}}

        If this was you, no action is needed.

        If you don't recognize this activity, secure your account:

        [Review account security]({{security_url}})

        If the button doesn't work, open this link: [{{security_url}}]({{security_url}})
        """)
    }
  end

  @doc "Default copy of the failed sign-in alert (`failed_login_alert`)."
  @spec failed_login_alert_defaults() :: PhoenixKit.Templates.defaults()
  def failed_login_alert_defaults do
    %{
      subject: gettext("Failed sign-in attempts on your account"),
      markdown:
        gettext("""
        Hi {{user_email}},

        Someone has been trying to sign in to your account and failing.

        - Failed attempts: {{attempt_count}}
        - In the last: {{window_hours}} hour(s)

        Nobody has signed in. You do not need to do anything if you recognize this as your own mistyped password.

        If you do not, your password may be being guessed. Change it to something you do not use anywhere else:

        [Change password]({{security_url}})

        If the button doesn't work, open this link: [{{security_url}}]({{security_url}})
        """)
    }
  end

  @doc "Default copy of the welcome email (`welcome`), sent once an address is confirmed."
  @spec welcome_defaults() :: PhoenixKit.Templates.defaults()
  def welcome_defaults do
    %{
      subject: gettext("Welcome to {{site_name}}"),
      markdown:
        gettext("""
        Hi {{user_email}},

        Welcome to {{site_name}}! Your email address is confirmed and your account is ready.

        [Go to {{site_name}}]({{site_url}})

        If the button doesn't work, open this link: [{{site_url}}]({{site_url}})
        """)
    }
  end

  @doc """
  The `{{location}}` line of the new login alert: the geolocated place,
  marked approximate, or "Unknown".

  IP geolocation is city-accurate at best and routinely a hundred kilometres
  out. Saying so is the difference between a reader dismissing a genuine
  alert because the city looks wrong and a reader checking the device.
  """
  @spec location_line(term()) :: String.t()
  def location_line(location) when is_binary(location) and location != "",
    do: gettext("%{location} (approximate)", location: location)

  def location_line(_location), do: gettext("Unknown")

  @doc """
  The `{{failed_attempts}}` paragraph of the new login alert for `count`
  failures in the last 24 hours: empty (not "0") when there were none, else a
  sentence carrying its own trailing blank line, so the paragraph collapses
  cleanly instead of leaving a gap.
  """
  @spec failed_attempts_note(non_neg_integer()) :: String.t()
  def failed_attempts_note(0), do: ""

  def failed_attempts_note(count) when is_integer(count) and count > 0 do
    ngettext(
      "There was also %{count} failed sign-in attempt on your account in the last 24 hours.",
      "There were also %{count} failed sign-in attempts on your account in the last 24 hours.",
      count
    ) <> "\n\n"
  end
end
