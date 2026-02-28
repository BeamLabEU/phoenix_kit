defmodule Mix.Tasks.PhoenixKit.Email.SendTest do
  @shortdoc "Send test email to specific address"

  @moduledoc """
  Mix task to send a test email to verify email system functionality.

  This task sends a test email to a specific address without requiring
  email system system configuration. Useful for basic email delivery testing.

  ## Usage

      # Send to specific email address
      mix phoenix_kit.email.send_test --to admin@example.com

      # Send to multiple addresses
      mix phoenix_kit.email.send_test --to admin@example.com,user@example.com

      # Send with custom subject
      mix phoenix_kit.email.send_test --to admin@example.com --subject "Custom Test Subject"

      # Include system (requires configured repo)
      mix phoenix_kit.email.send_test --to admin@example.com --track

  ## Options

      --to EMAIL           Email address to send to (required)
      --subject SUBJECT    Custom email subject (optional)
      --track              Enable email system (requires repo configuration)
      --from EMAIL         From email address (optional)

  ## Examples

      # Basic test email
      mix phoenix_kit.email.send_test --to admin@example.com

      # Multiple recipients with custom subject
      mix phoenix_kit.email.send_test --to "admin@example.com,user@example.com" --subject "PhoenixKit Test Email"

      # Test with system enabled
      mix phoenix_kit.email.send_test --to test@example.com --track
  """

  use Mix.Task
  import Swoosh.Email
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {options, _remaining} = parse_options(args)

    recipient = options[:to]

    unless recipient do
      Mix.shell().error("--to option is required. Please specify recipient email address.")
      exit({:shutdown, 1})
    end

    Mix.shell().info(IO.ANSI.cyan() <> "\n📧 Sending Test Email" <> IO.ANSI.reset())
    Mix.shell().info(String.duplicate("=", 30))

    send_test_email(options)
  end

  defp parse_options(args) do
    {options, remaining, _errors} =
      OptionParser.parse(args,
        strict: [
          to: :string,
          subject: :string,
          track: :boolean,
          from: :string
        ]
      )

    # Set defaults
    options =
      options
      |> Keyword.put_new(:subject, "PhoenixKit Test Email")
      |> Keyword.put_new(:track, false)
      |> Keyword.put_new(:from, "noreply@phoenixkit.dev")

    {options, remaining}
  end

  defp send_test_email(options) do
    recipients = parse_recipients(options[:to])
    subject = options[:subject]
    from_email = options[:from]
    track_email = options[:track]

    Mix.shell().info("Recipients: #{Enum.join(recipients, ", ")}")
    Mix.shell().info("Subject: #{subject}")
    Mix.shell().info("From: #{from_email}")
    Mix.shell().info("Tracking: #{if track_email, do: "enabled", else: "disabled"}")
    Mix.shell().info("")

    timestamp = UtilsDate.utc_now() |> DateTime.to_string()

    Enum.each(recipients, fn recipient ->
      Mix.shell().info("📤 Sending email to #{recipient}...")

      email =
        new()
        |> to(recipient)
        |> from({from_email, "PhoenixKit Test"})
        |> subject(subject)
        |> html_body(html_email_body(recipient, timestamp, track_email))
        |> text_body(text_email_body(recipient, timestamp, track_email))

      result =
        if track_email do
          # Use PhoenixKit.Mailer with system
          PhoenixKit.Mailer.deliver_email(email,
            template_name: "test_email",
            campaign_id: "manual_test"
          )
        else
          # Use basic Swoosh delivery without system
          send_via_configured_mailer(email)
        end

      case result do
        {:ok, _} ->
          Mix.shell().info("✅ Email sent successfully to #{recipient}")

        {:error, reason} ->
          Mix.shell().error("❌ Failed to send email to #{recipient}: #{inspect(reason)}")
      end

      # Small delay between emails
      Process.sleep(500)
    end)

    Mix.shell().info("\n🎉 Test email sending completed!")
  end

  defp parse_recipients(recipient_string) do
    recipient_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp send_via_configured_mailer(email) do
    # Try to use PhoenixKit.Mailer directly, falling back to simple delivery
    mailer = PhoenixKit.Mailer.get_mailer()

    if mailer == PhoenixKit.Mailer do
      PhoenixKit.Mailer.deliver(email)
    else
      mailer.deliver(email)
    end
  rescue
    error ->
      Mix.shell().error("Mailer delivery failed: #{inspect(error)}")
      Mix.shell().info("Attempting basic Swoosh delivery...")

      # Fallback to basic SMTP if available
      deliver_with_basic_config(email)
  end

  defp deliver_with_basic_config(email) do
    # Simple SMTP configuration for testing
    # This is just for development/testing purposes
    adapter_config = [
      adapter: Swoosh.Adapters.SMTP,
      relay: "smtp.gmail.com",
      port: 587,
      username: System.get_env("SMTP_USERNAME"),
      password: System.get_env("SMTP_PASSWORD"),
      tls: :if_available,
      retries: 1,
      no_mx_lookups: false
    ]

    if adapter_config[:username] && adapter_config[:password] do
      Swoosh.Mailer.deliver(email, adapter_config)
    else
      {:error,
       "No mailer configuration found. Please configure PhoenixKit.Mailer or set SMTP_USERNAME and SMTP_PASSWORD environment variables."}
    end
  end

  defp html_email_body(recipient, timestamp, track_enabled) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>PhoenixKit Test Email</title>
      <style>
      body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background-color: #f8f9fa; }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 30px; text-align: center; border-radius: 8px 8px 0 0; }
        .content { padding: 30px; }
        .info-box { background-color: #f0f9ff; border: 1px solid #0ea5e9; border-radius: 6px; padding: 16px; margin: 20px 0; }
        .system-box { background-color: #{if track_enabled, do: "#f0fdf4", else: "#fef3c7"}; border: 1px solid #{if track_enabled, do: "#22c55e", else: "#f59e0b"}; border-radius: 6px; padding: 16px; margin: 20px 0; }
        .footer { background-color: #f8f9fa; padding: 20px; border-radius: 0 0 8px 8px; font-size: 14px; color: #6b7280; }
        .system-info { font-family: monospace; background: #f3f4f6; padding: 10px; border-radius: 4px; margin: 10px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>📧 PhoenixKit Test Email</h1>
          <p>Email System Verification</p>
        </div>

        <div class="content">
          <div class="info-box">
            <strong>✅ Success!</strong> This email was sent successfully through the PhoenixKit email system.
          </div>

          <p>Hello,</p>

          <p>This is a test email to verify your email system configuration. If you received this email, it indicates:</p>

          <ul>
            <li>✅ Email delivery is working correctly</li>
            <li>✅ SMTP/Email provider configuration is valid</li>
            <li>✅ PhoenixKit mailer is functioning properly</li>
            #{if track_enabled, do: "<li>✅ Email system system is operational</li>", else: "<li>ℹ️ Email system was not enabled for this test</li>"}
          </ul>

          <div class="system-box">
            <strong>📊 Email Details:</strong>
            <div class="system-info">
              Recipient: #{recipient}<br>
              Sent at: #{timestamp}<br>
              Tracking: #{if track_enabled, do: "Enabled", else: "Disabled"}<br>
              Type: Manual Test Email
            </div>
          </div>

          <p>You can safely ignore this email - it's just for testing purposes.</p>

        </div>

        <div class="footer">
          <p>This is an automated test email from PhoenixKit Email System.</p>
          <p>Generated at: #{timestamp}</p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  defp text_email_body(recipient, timestamp, track_enabled) do
    """
    PHOENIXKIT TEST EMAIL - EMAIL SYSTEM VERIFICATION
    ================================================

    Success! This email was sent successfully through the PhoenixKit email system.

    Hello,

    This is a test email to verify your email system configuration. If you received this email, it indicates:

    ✅ Email delivery is working correctly
    ✅ SMTP/Email provider configuration is valid
    ✅ PhoenixKit mailer is functioning properly
    #{if track_enabled, do: "✅ Email system system is operational", else: "ℹ️ Email system was not enabled for this test"}

    EMAIL DETAILS:
    --------------
    Recipient: #{recipient}
    Sent at: #{timestamp}
    Tracking: #{if track_enabled, do: "Enabled", else: "Disabled"}
    Type: Manual Test Email

    You can safely ignore this email - it's just for testing purposes.

    ---
    This is an automated test email from PhoenixKit Email System.
    Generated at: #{timestamp}
    """
  end
end
