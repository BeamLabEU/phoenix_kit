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
  import Swoosh.Email

  alias PhoenixKit.Mailer
  alias PhoenixKit.Modules.Emails.Templates

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
             user_id: nil,
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

  Uses the 'register' template from the database if available,
  falls back to hardcoded template if not found.
  """
  def deliver_confirmation_instructions(user, url) do
    # Variables for template substitution
    template_variables = %{
      "user_email" => user.email,
      "confirmation_url" => url
    }

    # Try to get template from database, fallback to hardcoded
    {subject, html_body, text_body} =
      case Templates.get_active_template_by_name("register") do
        nil ->
          # Fallback to hardcoded templates
          fallback_text = """

          ==============================

          Hi #{user.email},

          You can confirm your account by visiting the URL below:

          #{url}

          If you didn't create an account with us, please ignore this.

          ==============================
          """

          {
            "Confirm your account",
            confirmation_html_body(user.email, url),
            fallback_text
          }

        template ->
          # Use database template with variable substitution
          rendered = Templates.render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body}
      end

    # Track template usage if using database template
    case Templates.get_active_template_by_name("register") do
      # No template to track
      nil -> :ok
      template -> Templates.track_usage(template)
    end

    deliver(user.email, subject, text_body, html_body)
  end

  @doc """
  Deliver instructions to reset a user password.

  Uses the 'reset_password' template from the database if available,
  falls back to hardcoded template if not found.
  """
  def deliver_reset_password_instructions(user, url) do
    # Variables for template substitution
    template_variables = %{
      "user_email" => user.email,
      "reset_url" => url
    }

    # Try to get template from database, fallback to hardcoded
    {subject, html_body, text_body} =
      case Templates.get_active_template_by_name("reset_password") do
        nil ->
          # Fallback to hardcoded templates
          fallback_text = """

          ==============================

          Hi #{user.email},

          You can reset your password by visiting the URL below:

          #{url}

          If you didn't request this change, please ignore this.

          ==============================
          """

          {
            "Reset your password",
            reset_password_html_body(user.email, url),
            fallback_text
          }

        template ->
          # Use database template with variable substitution
          rendered = Templates.render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body}
      end

    # Track template usage if using database template
    case Templates.get_active_template_by_name("reset_password") do
      # No template to track
      nil -> :ok
      template -> Templates.track_usage(template)
    end

    deliver(user.email, subject, text_body, html_body)
  end

  @doc """
  Deliver instructions to update a user email.

  Uses the 'update_email' template from the database if available,
  falls back to hardcoded template if not found.
  """
  def deliver_update_email_instructions(user, url) do
    # Variables for template substitution
    template_variables = %{
      "user_email" => user.email,
      "update_url" => url
    }

    # Try to get template from database, fallback to hardcoded
    {subject, html_body, text_body} =
      case Templates.get_active_template_by_name("update_email") do
        nil ->
          # Fallback to hardcoded templates
          fallback_text = """

          ==============================

          Hi #{user.email},

          You can change your email by visiting the URL below:

          #{url}

          If you didn't request this change, please ignore this.

          ==============================
          """

          {
            "Confirm your email change",
            update_email_html_body(user.email, url),
            fallback_text
          }

        template ->
          # Use database template with variable substitution
          rendered = Templates.render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body}
      end

    # Track template usage if using database template
    case Templates.get_active_template_by_name("update_email") do
      # No template to track
      nil -> :ok
      template -> Templates.track_usage(template)
    end

    deliver(user.email, subject, text_body, html_body)
  end

  # HTML template for account confirmation email
  defp confirmation_html_body(email, url) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Confirm Your Account</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #2563eb; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
        .info-box { background-color: #f0f9ff; border: 1px solid #0ea5e9; border-radius: 6px; padding: 16px; margin: 20px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Welcome! Please confirm your account</h1>
        </div>

        <p>Hi #{email},</p>

        <p>Thank you for creating an account! To complete your registration, please confirm your email address by clicking the button below:</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="#{url}" class="button">Confirm My Account</a>
        </p>

        <div class="info-box">
          <strong>ℹ️ Note:</strong> This confirmation link is secure and will verify your email address.
        </div>

        <p>If you didn't create an account with us, you can safely ignore this email.</p>

        <div class="footer">
          <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
          <p><a href="#{url}">#{url}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  # HTML template for password reset email
  defp reset_password_html_body(email, url) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Reset Your Password</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #dc2626; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #b91c1c; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
        .warning { background-color: #fef3c7; border: 1px solid #f59e0b; border-radius: 6px; padding: 16px; margin: 20px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Password Reset Request</h1>
        </div>

        <p>Hi #{email},</p>

        <p>We received a request to reset your password. Click the button below to create a new password:</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="#{url}" class="button">Reset My Password</a>
        </p>

        <div class="warning">
          <strong>⚠️ Security Notice:</strong> This password reset link will expire soon for your security.
        </div>

        <p>If you didn't request this password reset, you can safely ignore this email. Your password will remain unchanged.</p>

        <div class="footer">
          <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
          <p><a href="#{url}">#{url}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  # HTML template for email update confirmation
  defp update_email_html_body(email, url) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Confirm Email Change</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #059669; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #047857; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
        .info-box { background-color: #f0fdf4; border: 1px solid #22c55e; border-radius: 6px; padding: 16px; margin: 20px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Confirm Your Email Change</h1>
        </div>

        <p>Hi #{email},</p>

        <p>We received a request to change your email address. To complete this change, please confirm your new email address by clicking the button below:</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="#{url}" class="button">Confirm Email Change</a>
        </p>

        <div class="info-box">
          <strong>✓ Verification Required:</strong> This step ensures your new email address is valid and accessible.
        </div>

        <p>If you didn't request this email change, you can safely ignore this message. Your current email address will remain unchanged.</p>

        <div class="footer">
          <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
          <p><a href="#{url}">#{url}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Deliver magic link registration instructions.

  Uses the 'magic_link_registration' template from the database if available,
  falls back to hardcoded template if not found.
  """
  def deliver_magic_link_registration(user_or_email, url) do
    # Handle both user struct and plain email string
    email =
      case user_or_email do
        %{email: email} -> email
        email when is_binary(email) -> email
      end

    # Variables for template substitution
    template_variables = %{
      "user_email" => email,
      "registration_url" => url
    }

    # Try to get template from database, fallback to hardcoded
    {subject, html_body, text_body} =
      case Templates.get_active_template_by_name("magic_link_registration") do
        nil ->
          # Fallback to hardcoded templates
          fallback_text = """

          ==============================

          Hi #{email},

          Welcome! To complete your registration, please click the link below:

          #{url}

          This link will expire in 30 minutes for your security.

          If you didn't request this registration, please ignore this email.

          ==============================
          """

          {
            "Complete Your Registration",
            magic_link_registration_html_body(email, url),
            fallback_text
          }

        template ->
          # Use database template with variable substitution
          rendered = Templates.render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body}
      end

    # Track template usage if using database template
    case Templates.get_active_template_by_name("magic_link_registration") do
      # No template to track
      nil -> :ok
      template -> Templates.track_usage(template)
    end

    deliver(email, subject, text_body, html_body)
  end

  # HTML template for magic link registration email
  defp magic_link_registration_html_body(email, url) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Complete Your Registration</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #2563eb; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
        .info-box { background-color: #f0f9ff; border: 1px solid #0ea5e9; border-radius: 6px; padding: 16px; margin: 20px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Welcome! Complete Your Registration</h1>
        </div>

        <p>Hi #{email},</p>

        <p>Thank you for starting your registration! Click the button below to complete your account setup:</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="#{url}" class="button">Complete Registration</a>
        </p>

        <div class="info-box">
          <strong>ℹ️ Security Note:</strong> This registration link will expire in 30 minutes and can only be used once.
        </div>

        <p>If you didn't request this registration, you can safely ignore this email.</p>

        <div class="footer">
          <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
          <p><a href="#{url}">#{url}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end
end
