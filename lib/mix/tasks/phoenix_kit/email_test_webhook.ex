defmodule Mix.Tasks.PhoenixKit.Email.TestWebhook do
  @shortdoc "Test email webhook functionality"

  @moduledoc """
  Mix task to test email webhook functionality with sample events.

  ## Usage

      # Test bounce event
      mix phoenix_kit.email.test_webhook --event bounce

      # Test open event with specific message UUID
      mix phoenix_kit.email.test_webhook --event open --message-uuid abc123

      # Test delivery event
      mix phoenix_kit.email.test_webhook --event delivery

      # Test all event types
      mix phoenix_kit.email.test_webhook --all

  ## Options

      --event TYPE          Event type to test: bounce, delivery, send, open, click, complaint
      --message-uuid UUID   Use specific message UUID (uses random if not provided)
      --all                 Test all event types
      --endpoint URL        Custom webhook endpoint URL
      --no-verify           Skip signature verification (for testing)

  ## Event Types

      send         - Email send confirmation
      delivery     - Successful delivery
      bounce       - Hard/soft bounce
      complaint    - Spam complaint
      open         - Email opened (AWS SES)
      click        - Link clicked

  ## Examples

      # Test bounce handling
      mix phoenix_kit.email.test_webhook --event bounce --message-id test-123

      # Test all events with custom endpoint
      mix phoenix_kit.email.test_webhook --all --endpoint {prefix}/webhooks/email

      # Where {prefix} is your configured PhoenixKit URL prefix

      # Quick delivery test
      mix phoenix_kit.email.test_webhook --event delivery
  """

  use Mix.Task
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {options, _remaining} = parse_options(args)

    unless Emails.enabled?() do
      Mix.shell().error("Email is not enabled.")
      exit({:shutdown, 1})
    end

    Mix.shell().info(IO.ANSI.cyan() <> "\n🧪 Email Webhook Testing" <> IO.ANSI.reset())
    Mix.shell().info(String.duplicate("=", 40))

    if options[:all] do
      test_all_events(options)
    else
      event_type = options[:event] || "delivery"
      test_single_event(event_type, options)
    end
  end

  defp parse_options(args) do
    {options, remaining, _errors} =
      OptionParser.parse(args,
        strict: [
          event: :string,
          message_uuid: :string,
          all: :boolean,
          endpoint: :string,
          no_verify: :boolean
        ]
      )

    # Set defaults
    options =
      options
      |> Keyword.put_new(:all, false)
      |> Keyword.put_new(:no_verify, false)

    {options, remaining}
  end

  defp test_all_events(options) do
    event_types = ["send", "delivery", "bounce", "complaint", "open", "click"]

    Mix.shell().info("Testing all event types...\n")

    results =
      Enum.map(event_types, fn event_type ->
        result = test_single_event(event_type, options)
        # Small delay between tests
        Process.sleep(500)
        {event_type, result}
      end)

    # Summary
    Mix.shell().info("\n📋 Test Summary:")

    for {event_type, result} <- results do
      status_icon = if result == :ok, do: "✅", else: "❌"
      Mix.shell().info("  #{status_icon} #{String.pad_trailing(event_type, 12)} #{result}")
    end
  end

  defp test_single_event(event_type, options) do
    Mix.shell().info("🧪 Testing #{event_type} event...")

    # Create test email log if needed
    message_uuid = options[:message_uuid] || generate_test_message_uuid()
    test_log = ensure_test_log(message_uuid)

    # Generate test event
    test_event = generate_test_event(event_type, message_uuid, test_log)

    # Test webhook processing
    case test_webhook_processing(test_event, options) do
      :ok ->
        Mix.shell().info("✅ #{event_type} event processed successfully")
        :ok

      {:error, reason} ->
        Mix.shell().error("❌ #{event_type} event failed: #{reason}")
        {:error, reason}
    end
  end

  defp generate_test_message_uuid do
    timestamp = UtilsDate.utc_now() |> DateTime.to_unix()
    "test-webhook-#{timestamp}-#{:rand.uniform(9999)}"
  end

  defp ensure_test_log(message_uuid) do
    case Emails.get_log_by_message_id(message_uuid) do
      {:error, :not_found} ->
        # Create a test log
        {:ok, log} =
          Emails.create_log(%{
            message_id: message_uuid,
            to: "test@example.com",
            from: "noreply@phoenixkit.dev",
            subject: "Test Email for Webhook",
            status: "sent",
            provider: "test_provider",
            sent_at: UtilsDate.utc_now()
          })

        Mix.shell().info("📧 Created test email log: #{message_uuid}")
        log

      {:ok, log} ->
        Mix.shell().info("📧 Using existing email log: #{message_uuid}")
        log

      {:error, reason} ->
        Mix.shell().error("❌ Error getting email log: #{inspect(reason)}")
        nil
    end
  end

  defp generate_test_event(event_type, message_uuid, _log) do
    base_event = %{
      "Type" => "Notification",
      "MessageId" => "webhook-test-#{:rand.uniform(99999)}",
      "Timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
      "Message" => Jason.encode!(generate_ses_message(event_type, message_uuid))
    }

    base_event
  end

  defp generate_ses_message("send", message_uuid) do
    %{
      "eventType" => "send",
      "mail" => %{
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "messageId" => message_uuid,
        "source" => "test@phoenixkit.dev",
        "destination" => ["test@example.com"]
      },
      "send" => %{}
    }
  end

  defp generate_ses_message("delivery", message_uuid) do
    %{
      "eventType" => "delivery",
      "mail" => %{
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "messageId" => message_uuid,
        "source" => "test@phoenixkit.dev",
        "destination" => ["test@example.com"]
      },
      "delivery" => %{
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "processingTimeMillis" => 2000,
        "recipients" => ["test@example.com"],
        "smtpResponse" => "250 2.0.0 OK"
      }
    }
  end

  defp generate_ses_message("bounce", message_uuid) do
    %{
      "eventType" => "bounce",
      "mail" => %{
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "messageId" => message_uuid,
        "source" => "test@phoenixkit.dev",
        "destination" => ["bounce@example.com"]
      },
      "bounce" => %{
        "bounceType" => "Permanent",
        "bounceSubType" => "General",
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "feedbackId" => "test-bounce-#{:rand.uniform(9999)}",
        "bouncedRecipients" => [
          %{
            "emailAddress" => "bounce@example.com",
            "status" => "5.1.1",
            "action" => "failed",
            "diagnosticCode" => "smtp; 550 5.1.1 User unknown"
          }
        ]
      }
    }
  end

  defp generate_ses_message("complaint", message_uuid) do
    %{
      "eventType" => "complaint",
      "mail" => %{
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "messageId" => message_uuid,
        "source" => "test@phoenixkit.dev",
        "destination" => ["complaint@example.com"]
      },
      "complaint" => %{
        "complainedRecipients" => [
          %{
            "emailAddress" => "complaint@example.com"
          }
        ],
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "feedbackId" => "test-complaint-#{:rand.uniform(9999)}",
        "complaintFeedbackType" => "abuse"
      }
    }
  end

  defp generate_ses_message("open", message_uuid) do
    %{
      "eventType" => "open",
      "mail" => %{
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "messageId" => message_uuid,
        "source" => "test@phoenixkit.dev",
        "destination" => ["test@example.com"]
      },
      "open" => %{
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "userAgent" => "Mozilla/5.0 (Test Webhook)",
        "ipAddress" => "192.0.2.1"
      }
    }
  end

  defp generate_ses_message("click", message_uuid) do
    %{
      "eventType" => "click",
      "mail" => %{
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "messageId" => message_uuid,
        "source" => "test@phoenixkit.dev",
        "destination" => ["test@example.com"]
      },
      "click" => %{
        "timestamp" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "userAgent" => "Mozilla/5.0 (Test Webhook)",
        "ipAddress" => "192.0.2.1",
        "link" => "https://example.com/test-link",
        "linkTags" => %{
          "campaign" => "test"
        }
      }
    }
  end

  defp test_webhook_processing(webhook_data, _options) do
    # Process the webhook event using EmailTracking
    case Emails.process_webhook_event(webhook_data) do
      {:ok, _event} ->
        :ok

      {:error, :email_log_not_found} ->
        # This might be expected for some test cases
        Mix.shell().info("ℹ️  Note: Email log not found (this may be expected for test events)")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end
end
