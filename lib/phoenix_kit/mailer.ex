defmodule PhoenixKit.Mailer do
  @moduledoc """
  Mailer module for PhoenixKit emails.

  This module handles sending emails such as
  confirmation emails, password reset emails, magic link emails, etc.

  It can work in two modes:
  1. **Built-in mode**: Uses PhoenixKit's own Swoosh mailer (default)
  2. **Delegation mode**: Uses the parent application's mailer when configured

  ## Configuration

  To use your application's mailer instead of PhoenixKit's built-in one:

      config :phoenix_kit,
        mailer: MyApp.Mailer

  When delegation is configured, all emails will be sent through your application's 
  mailer, allowing you to use a single mailer configuration across your entire application.
  """

  use Swoosh.Mailer, otp_app: :phoenix_kit

  import Swoosh.Email

  alias PhoenixKit.EmailSystem.EmailInterceptor

  alias PhoenixKit.Users.Auth.User

  @doc """
  Gets the mailer module to use for sending emails.

  Returns the configured parent application mailer if set,
  otherwise returns the built-in PhoenixKit.Mailer.

  ## Examples

      iex> PhoenixKit.Mailer.get_mailer()
      MyApp.Mailer  # if configured
      
      iex> PhoenixKit.Mailer.get_mailer()
      PhoenixKit.Mailer  # default
  """
  def get_mailer do
    PhoenixKit.Config.get(:mailer, __MODULE__)
  end

  @doc """
  Delivers an email using the appropriate mailer.

  If a parent application mailer is configured, delegates to it.
  Otherwise uses the built-in PhoenixKit mailer.

  This function also integrates with the email tracking system to log
  outgoing emails when tracking is enabled.
  """
  def deliver_email(email, opts \\ []) do
    # Intercept email for tracking before sending
    tracked_email = EmailInterceptor.intercept_before_send(email, opts)

    mailer = get_mailer()

    result =
      if mailer == __MODULE__ do
        # Use built-in mailer
        __MODULE__.deliver(tracked_email)
      else
        # Delegate to parent application mailer
        mailer.deliver(tracked_email)
      end

    # Handle post-send tracking updates
    handle_delivery_result(tracked_email, result, opts)

    result
  end

  @doc """
  Sends a magic link email to the user.

  ## Examples

      iex> PhoenixKit.Mailer.send_magic_link_email(user, "https://app.com/magic/token123")
      {:ok, %Swoosh.Email{}}
  """
  def send_magic_link_email(%User{} = user, magic_link_url) when is_binary(magic_link_url) do
    email =
      new()
      |> to({user.email, user.email})
      |> from({"PhoenixKit", get_from_email()})
      |> subject("Your secure login link")
      |> html_body(magic_link_html_body(user, magic_link_url))
      |> text_body(magic_link_text_body(user, magic_link_url))

    deliver_email(email,
      user_id: user.id,
      template_name: "magic_link",
      campaign_id: "authentication",
      provider: detect_provider()
    )
  end

  # HTML version of the magic link email
  defp magic_link_html_body(%User{} = user, magic_link_url) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Your Secure Login Link</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #2563eb; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
        .warning { background-color: #fef3c7; border: 1px solid #f59e0b; border-radius: 6px; padding: 16px; margin: 20px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Secure Login Link</h1>
        </div>

        <p>Hi #{user.email},</p>

        <p>Click the button below to securely log in to your account:</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="#{magic_link_url}" class="button">Log In Securely</a>
        </p>

        <div class="warning">
          <strong>⚠️ Important:</strong> This link will expire in 15 minutes and can only be used once.
        </div>

        <p>If you didn't request this login link, you can safely ignore this email.</p>

        <p>For your security, never share this link with anyone.</p>

        <div class="footer">
          <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
          <p><a href="#{magic_link_url}">#{magic_link_url}</a></p>
        </div>
      </div>

    </body>
    </html>
    """
  end

  # Text version of the magic link email
  defp magic_link_text_body(%User{} = user, magic_link_url) do
    """
    Secure Login Link

    Hi #{user.email},

    Click the link below to securely log in to your account:

    #{magic_link_url}

    ⚠️ Important: This link will expire in 15 minutes and can only be used once.

    If you didn't request this login link, you can safely ignore this email.

    For your security, never share this link with anyone.
    """
  end

  # Handle delivery result for email tracking updates
  defp handle_delivery_result(email, result, opts) do
    # Only process if email tracking is enabled
    if PhoenixKit.EmailSystem.enabled?() do
      case extract_log_id_from_email(email) do
        nil ->
          # No log ID found, skip tracking
          :ok

        log_id ->
          case PhoenixKit.EmailSystem.get_log!(log_id) do
            nil -> :ok
            log -> update_log_after_delivery(log, result, opts)
          end
      end
    end
  rescue
    # Don't fail email delivery if tracking update fails
    error ->
      require Logger
      Logger.error("Failed to update email tracking after delivery: #{inspect(error)}")
      :ok
  end

  # Extract log ID from email headers
  defp extract_log_id_from_email(email) do
    case get_in(email.headers, ["X-PhoenixKit-Log-Id"]) do
      nil ->
        nil

      log_id_str ->
        case Integer.parse(log_id_str) do
          {log_id, _} -> log_id
          _ -> nil
        end
    end
  end

  # Update email log based on delivery result
  defp update_log_after_delivery(log, {:ok, response}, _opts) do
    EmailInterceptor.update_after_send(log, response)
  end

  defp update_log_after_delivery(log, {:error, error}, _opts) do
    EmailInterceptor.update_after_failure(log, error)
  end

  defp update_log_after_delivery(_log, _result, _opts) do
    # Unknown result format, skip update
    :ok
  end

  # Detect current email provider from configuration
  defp detect_provider do
    mailer = get_mailer()

    if mailer == __MODULE__ do
      detect_builtin_provider()
    else
      detect_parent_app_provider(mailer)
    end
  end

  # Detect provider for built-in PhoenixKit mailer
  defp detect_builtin_provider do
    config = Application.get_env(:phoenix_kit, __MODULE__, [])
    adapter = Keyword.get(config, :adapter)
    adapter_to_provider_name(adapter, "phoenix_kit_builtin")
  end

  # Detect provider for parent application mailer
  defp detect_parent_app_provider(mailer) when is_atom(mailer) do
    app = PhoenixKit.Config.get_parent_app()
    config = Application.get_env(app, mailer, [])
    adapter = Keyword.get(config, :adapter)
    adapter_to_provider_name(adapter, "parent_app_mailer")
  end

  defp detect_parent_app_provider(_mailer), do: "unknown"

  # Convert adapter module to provider name
  defp adapter_to_provider_name(adapter, default_name) do
    case adapter do
      Swoosh.Adapters.AmazonSES -> "aws_ses"
      Swoosh.Adapters.SMTP -> "smtp"
      Swoosh.Adapters.Sendgrid -> "sendgrid"
      Swoosh.Adapters.Mailgun -> "mailgun"
      Swoosh.Adapters.Local -> "local"
      _ -> default_name
    end
  end

  @doc """
  Send a test tracking email to verify email delivery and tracking functionality.

  This function sends a test email with test links
  to verify that the email tracking system is working correctly.

  ## Parameters

  - `recipient_email` - The email address to send the test email to
  - `user_id` - Optional user ID to associate with the test email (default: nil)

  ## Returns

  - `{:ok, %Swoosh.Email{}}` - Email sent successfully
  - `{:error, reason}` - Email failed to send

  ## Examples

      iex> PhoenixKit.Mailer.send_test_tracking_email("admin@example.com")
      {:ok, %Swoosh.Email{}}

      iex> PhoenixKit.Mailer.send_test_tracking_email("admin@example.com", 123)
      {:ok, %Swoosh.Email{}}

  """
  def send_test_tracking_email(recipient_email, user_id \\ nil) when is_binary(recipient_email) do
    timestamp = DateTime.utc_now() |> DateTime.to_string()

    email =
      new()
      |> to(recipient_email)
      |> from({"PhoenixKit Test", get_from_email()})
      |> subject("Test Tracking Email - #{timestamp}")
      |> html_body(test_email_html_body(recipient_email, timestamp))
      |> text_body(test_email_text_body(recipient_email, timestamp))

    deliver_email(email,
      user_id: user_id,
      template_name: "test_email",
      campaign_id: "test",
      provider: detect_provider()
    )
  end

  # HTML version of the test tracking email
  defp test_email_html_body(recipient_email, timestamp) do
    base_url = PhoenixKit.Config.get_dynamic_base_url()
    test_link_url = "#{base_url}/phoenix_kit/admin/emails"

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Test Tracking Email</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background-color: #f8f9fa; }
        .container { max-width: 600px; margin: 20px auto; background: white; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 30px; text-align: center; border-radius: 8px 8px 0 0; }
        .content { padding: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; margin: 10px 5px; }
        .button:hover { background-color: #2563eb; }
        .info-box { background-color: #f0f9ff; border: 1px solid #0ea5e9; border-radius: 6px; padding: 16px; margin: 20px 0; }
        .success-box { background-color: #f0fdf4; border: 1px solid #22c55e; border-radius: 6px; padding: 16px; margin: 20px 0; }
        .footer { background-color: #f8f9fa; padding: 20px; border-radius: 0 0 8px 8px; font-size: 14px; color: #6b7280; }
        .test-links { margin: 20px 0; }
        .test-links a { margin-right: 15px; }
        .tracking-info { font-family: monospace; background: #f3f4f6; padding: 10px; border-radius: 4px; margin: 10px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>📧 Test Tracking Email</h1>
          <p>Email Tracking System Verification</p>
        </div>

        <div class="content">
          <div class="success-box">
            <strong>✅ Success!</strong> This test email was sent successfully through the PhoenixKit email tracking system.
          </div>

          <p>Hello,</p>

          <p>This is a test email to verify that your email tracking system is working correctly. If you received this email, it means:</p>

          <ul>
            <li>✅ Email delivery is working</li>
            <li>✅ AWS SES configuration is correct (if using SES)</li>
            <li>✅ Email tracking is enabled and logging</li>
            <li>✅ Configuration set is properly configured</li>
          </ul>

          <div class="info-box">
            <strong>📊 Tracking Information:</strong>
            <div class="tracking-info">
              Recipient: #{recipient_email}<br>
              Sent at: #{timestamp}<br>
              Campaign: test<br>
              Template: test_email
            </div>
          </div>

          <div class="test-links">
            <p><strong>Test these tracking features:</strong></p>
            <a href="#{test_link_url}?test=link1" class="button">Test Link 1</a>
            <a href="#{test_link_url}?test=link2" class="button">Test Link 2</a>
            <a href="#{test_link_url}?test=link3" class="button">Test Link 3</a>
          </div>

          <p>Click any of the buttons above to test link tracking. Then check your emails in the admin panel to see the tracking data.</p>

        </div>

        <div class="footer">
          <p>This is an automated test email from PhoenixKit Email Tracking System.</p>
          <p>Check your admin panel at: <a href="#{test_link_url}">#{test_link_url}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  # Text version of the test tracking email
  defp test_email_text_body(recipient_email, timestamp) do
    base_url = PhoenixKit.Config.get_dynamic_base_url()
    test_link_url = "#{base_url}/phoenix_kit/admin/emails"

    """
    TEST TRACKING EMAIL - EMAIL SYSTEM VERIFICATION

    Success! This test email was sent successfully through the PhoenixKit email tracking system.

    Hello,

    This is a test email to verify that your email tracking system is working correctly. If you received this email, it means:

    ✅ Email delivery is working
    ✅ AWS SES configuration is correct (if using SES)
    ✅ Email tracking is enabled and logging
    ✅ Configuration set is properly configured

    TRACKING INFORMATION:
    ---------------------
    Recipient: #{recipient_email}
    Sent at: #{timestamp}
    Campaign: test
    Template: test_email

    TEST LINKS:
    -----------
    Test these tracking features by visiting:

    Test Link 1: #{test_link_url}?test=link1
    Test Link 2: #{test_link_url}?test=link2
    Test Link 3: #{test_link_url}?test=link3

    Click any of the links above to test link tracking. Then check your emails in the admin panel to see the tracking data.

    ---
    This is an automated test email from PhoenixKit Email Tracking System.
    Check your admin panel at: #{test_link_url}
    """
  end

  # Get the from email address from configuration or use a default
  defp get_from_email do
    case PhoenixKit.Config.get(:from_email) do
      {:ok, email} -> email
      :not_found -> "noreply@localhost"
    end
  end
end
