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

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Interceptor
  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.Utils, as: EmailUtils
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Routes

  require Logger

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
  Sends an email using a template from the database.

  This is the main function for sending emails using PhoenixKit's template system.
  It automatically:
  - Loads the template by name
  - Renders it with provided variables
  - Tracks template usage
  - Sends the email with tracking
  - Logs to EmailSystem

  ## Parameters

  - `template_name` - Name of the template in the database (e.g., "welcome_email")
  - `recipient` - Email address (string) or {name, email} tuple
  - `variables` - Map of variables to substitute in the template
  - `opts` - Additional options:
    - `:user_id` - Associate email with a user (for tracking)
    - `:campaign_id` - Campaign identifier (for analytics)
    - `:from` - Override from address (default: configured from_email)
    - `:reply_to` - Reply-to address
    - `:metadata` - Additional metadata map for tracking

  ## Returns

  - `{:ok, email}` - Email sent successfully
  - `{:error, :template_not_found}` - Template doesn't exist
  - `{:error, :template_inactive}` - Template is not active
  - `{:error, reason}` - Other error

  ## Examples

      # Simple welcome email
      PhoenixKit.Mailer.send_from_template(
        "welcome_email",
        "user@example.com",
        %{"user_name" => "John", "url" => "https://app.com"}
      )

      # With user tracking
      PhoenixKit.Mailer.send_from_template(
        "password_reset",
        {"Jane Doe", "jane@example.com"},
        %{"reset_url" => "https://app.com/reset/token123"},
        user_uuid: user.uuid,
        campaign_id: "password_recovery"
      )

      # With metadata
      PhoenixKit.Mailer.send_from_template(
        "order_confirmation",
        customer.email,
        %{"order_id" => "12345", "total" => "$99.99"},
        user_id: customer.id,
        campaign_id: "orders",
        metadata: %{order_id: order.id, amount: order.total}
      )
  """
  def send_from_template(template_name, recipient, variables \\ %{}, opts \\ [])
      when is_binary(template_name) do
    # Get the template from database
    case Templates.get_active_template_by_name(template_name) do
      nil ->
        {:error, :template_not_found}

      template ->
        # Ensure template is active
        if template.status == "active" do
          # Render template with variables
          rendered = Templates.render_template(template, variables)

          # Build email
          email =
            new()
            |> to(recipient)
            |> from(Keyword.get(opts, :from, {get_from_name(), get_from_email()}))
            |> subject(rendered.subject)
            |> html_body(rendered.html_body)
            |> text_body(rendered.text_body)

          # Add reply-to if provided
          email =
            if reply_to = Keyword.get(opts, :reply_to) do
              reply_to(email, reply_to)
            else
              email
            end

          # Track template usage
          Templates.track_usage(template)

          # Extract source_module from template metadata
          source_module = Template.get_source_module(template)

          # Prepare delivery options with category and source_module from template
          delivery_opts =
            opts
            |> Keyword.put(:template_name, template_name)
            |> Keyword.put(:template_id, template.id)
            |> Keyword.put_new(:campaign_id, template.category)
            |> Keyword.put(:category, template.category)
            |> Keyword.put_new(:source_module, source_module)
            |> Keyword.put(:provider, detect_provider())

          # Send email with tracking
          deliver_email(email, delivery_opts)
        else
          {:error, :template_inactive}
        end
    end
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
    tracked_email = Interceptor.intercept_before_send(email, opts)

    mailer = get_mailer()

    result =
      if mailer == __MODULE__ do
        # Use built-in mailer with runtime config for AWS
        deliver_with_runtime_config(tracked_email, mailer)
      else
        # Check if parent mailer also uses AWS SES
        app = PhoenixKit.Config.get_parent_app()
        config = Application.get_env(app, mailer, [])

        if config[:adapter] == Swoosh.Adapters.AmazonSES do
          # Parent mailer uses AWS SES, provide runtime config
          deliver_with_runtime_config(tracked_email, mailer, app)
        else
          # Non-AWS mailer, use standard delivery
          mailer.deliver(tracked_email)
        end
      end

    # Handle post-send tracking updates
    handle_delivery_result(tracked_email, result, opts)

    result
  end

  # Deliver email with runtime configuration for AWS SES
  defp deliver_with_runtime_config(email, mailer, app \\ :phoenix_kit) do
    config =
      if app == :phoenix_kit do
        # Use PhoenixKit config for built-in mailer
        PhoenixKit.Config.get(mailer, [])
      else
        # Use parent app config for parent mailer
        PhoenixKit.Config.get_parent_app_config(mailer, [])
      end

    # If using AWS SES, override with runtime settings from DB
    runtime_config =
      if config[:adapter] == Swoosh.Adapters.AmazonSES do
        config
        |> Keyword.put(:region, Emails.get_aws_region())
        |> Keyword.put(:access_key, Emails.get_aws_access_key())
        |> Keyword.put(:secret, Emails.get_aws_secret_key())
      else
        config
      end

    # Use Swoosh.Mailer.deliver with runtime config
    Swoosh.Mailer.deliver(email, runtime_config)
  end

  @doc """
  Sends a magic link email to the user.

  Uses the 'magic_link' template from the database if available,
  falls back to hardcoded template if not found.

  ## Examples

      iex> PhoenixKit.Mailer.send_magic_link_email(user, "https://app.com/magic/token123")
      {:ok, %Swoosh.Email{}}
  """
  def send_magic_link_email(%User{} = user, magic_link_url) when is_binary(magic_link_url) do
    # Variables for template substitution
    template_variables = %{
      "user_email" => user.email,
      "magic_link_url" => magic_link_url
    }

    # Try to get template from database, fallback to hardcoded
    {subject, html_body, text_body} =
      case Templates.get_active_template_by_name("magic_link") do
        nil ->
          # Fallback to hardcoded templates
          {
            "Your secure login link",
            magic_link_html_body(user, magic_link_url),
            magic_link_text_body(user, magic_link_url)
          }

        template ->
          # Use database template with variable substitution
          rendered = Templates.render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body}
      end

    email =
      new()
      |> to({user.email, user.email})
      |> from({get_from_name(), get_from_email()})
      |> subject(subject)
      |> html_body(html_body)
      |> text_body(text_body)

    # Track template usage if using database template
    case Templates.get_active_template_by_name("magic_link") do
      # No template to track
      nil -> :ok
      template -> Templates.track_usage(template)
    end

    deliver_email(email,
      user_uuid: user.uuid,
      template_name: "magic_link",
      campaign_id: "authentication",
      category: "system",
      source_module: "users",
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
    if Emails.enabled?() do
      case extract_log_id_from_email(email) do
        nil ->
          # No log ID found, skip tracking
          :ok

        log_id ->
          case Emails.get_log!(log_id) do
            nil -> :ok
            log -> update_log_after_delivery(log, result, opts)
          end
      end
    end
  rescue
    # Don't fail email delivery if tracking update fails
    error ->
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
    Interceptor.update_after_send(log, response)
  end

  defp update_log_after_delivery(log, {:error, error}, _opts) do
    Interceptor.update_after_failure(log, error)
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
    config = PhoenixKit.Config.get(PhoenixKit.Mailer, [])
    adapter = Keyword.get(config, :adapter)
    EmailUtils.adapter_to_provider_name(adapter, "phoenix_kit_builtin")
  end

  # Detect provider for parent application mailer
  defp detect_parent_app_provider(mailer) when is_atom(mailer) do
    config = PhoenixKit.Config.get_parent_app_config(mailer, [])
    adapter = Keyword.get(config, :adapter)
    EmailUtils.adapter_to_provider_name(adapter, "parent_app_mailer")
  end

  defp detect_parent_app_provider(_mailer), do: "unknown"

  @doc """
  Send a test tracking email to verify email delivery and tracking functionality.

  Uses the 'test_email' template from the database if available,
  falls back to hardcoded template if not found.

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
    test_link_url = Routes.url("/admin/emails")

    # Variables for template substitution
    template_variables = %{
      "recipient_email" => recipient_email,
      "timestamp" => timestamp,
      "test_link_url" => test_link_url
    }

    # Try to get template from database, fallback to hardcoded
    {subject, html_body, text_body} =
      case Templates.get_active_template_by_name("test_email") do
        nil ->
          # Fallback to hardcoded templates
          {
            "Test Tracking Email - #{timestamp}",
            test_email_html_body(recipient_email, timestamp),
            test_email_text_body(recipient_email, timestamp)
          }

        template ->
          # Use database template with variable substitution
          rendered = Templates.render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body}
      end

    email =
      new()
      |> to(recipient_email)
      |> from({get_from_name(), get_from_email()})
      |> subject(subject)
      |> html_body(html_body)
      |> text_body(text_body)

    # Track template usage if using database template
    case Templates.get_active_template_by_name("test_email") do
      # No template to track
      nil -> :ok
      template -> Templates.track_usage(template)
    end

    deliver_email(email,
      user_id: user_id,
      template_name: "test_email",
      campaign_id: "test",
      category: "system",
      source_module: "admin",
      provider: detect_provider()
    )
  end

  # HTML version of the test tracking email
  defp test_email_html_body(recipient_email, timestamp) do
    test_link_url = Routes.url("/admin/emails")

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Test Tracking Email</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background-color: #f8f9fa; }
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
    test_link_url = Routes.url("/admin/emails")

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
end
