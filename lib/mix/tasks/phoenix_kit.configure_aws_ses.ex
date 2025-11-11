defmodule Mix.Tasks.PhoenixKit.ConfigureAwsSes do
  @moduledoc """
  Mix task to configure AWS SES integration for PhoenixKit email system.

  This task helps set up AWS SES configuration set, SNS topics, and SQS queues
  for tracking email delivery events and processing email status updates.

  ## Usage

      # Check current configuration status
      mix phoenix_kit.configure_aws_ses --status

      # Configure basic SES settings
      mix phoenix_kit.configure_aws_ses --config-set my-app-tracking

      # Set up SNS topic for events
      mix phoenix_kit.configure_aws_ses --sns-topic arn:aws:sns:eu-north-1:123456789012:email-events

      # Configure SQS queue for processing
      mix phoenix_kit.configure_aws_ses --sqs-queue https://sqs.eu-north-1.amazonaws.com/123456789012/email-events

      # Set DLQ URL for failed messages
      mix phoenix_kit.configure_aws_ses --dlq-url https://sqs.eu-north-1.amazonaws.com/123456789012/email-events-dlq

      # Specify AWS region
      mix phoenix_kit.configure_aws_ses --region eu-north-1

      # Reset configuration
      mix phoenix_kit.configure_aws_ses --reset

      # Show help
      mix phoenix_kit.configure_aws_ses --help
  """
  @shortdoc "Configure AWS SES integration for email system"

  use Mix.Task

  alias PhoenixKit.Emails

  @default_region "eu-north-1"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          config_set: :string,
          sns_topic: :string,
          sqs_queue: :string,
          dlq_url: :string,
          region: :string,
          status: :boolean,
          enable_polling: :boolean,
          help: :boolean
        ],
        aliases: [h: :help, s: :status]
      )

    if opts[:help] do
      print_help()
    else
      # Start the application
      Mix.Task.run("app.start")

      cond do
        opts[:status] ->
          show_current_status()

        opts[:config_set] || opts[:sns_topic] || opts[:sqs_queue] ->
          configure_from_options(opts)

        true ->
          interactive_configuration()
      end
    end
  end

  defp show_current_status do
    IO.puts("\n📊 Current AWS SES Integration Status")
    IO.puts("═══════════════════════════════════")

    config = Emails.get_config()

    IO.puts("📧 Email:")
    IO.puts("   Enabled: #{format_boolean(config.enabled)}")
    IO.puts("   SES Events: #{format_boolean(config.ses_events)}")

    IO.puts("\n🔧 AWS Configuration:")
    IO.puts("   Configuration Set: #{config.ses_configuration_set || "❌ Not set"}")
    IO.puts("   AWS Region: #{config.aws_region || "❌ Not set"}")

    aws_access_key = System.get_env("AWS_ACCESS_KEY_ID")
    aws_secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")

    IO.puts("\n🔑 AWS Credentials:")
    IO.puts("   Access Key ID: #{if aws_access_key, do: "✅ Configured", else: "❌ Missing"}")
    IO.puts("   Secret Access Key: #{if aws_secret_key, do: "✅ Configured", else: "❌ Missing"}")

    complete = config.enabled && config.ses_configuration_set && aws_access_key && aws_secret_key

    IO.puts(
      "\n#{if complete, do: "✅", else: "⚠️"} Configuration Status: #{if complete, do: "Complete", else: "Incomplete"}"
    )
  end

  defp configure_from_options(opts) do
    IO.puts("🔧 Configuring AWS SES integration from options...")

    updates = []

    updates =
      if config_set = opts[:config_set] do
        case Emails.set_ses_configuration_set(config_set) do
          {:ok, _} ->
            IO.puts("✅ Set configuration set: #{config_set}")
            ["configuration_set" | updates]

          {:error, reason} ->
            IO.puts("❌ Failed to set configuration set: #{inspect(reason)}")
            updates
        end
      else
        updates
      end

    region = opts[:region] || @default_region

    updates =
      case Emails.set_aws_region(region) do
        {:ok, _} ->
          IO.puts("✅ Set AWS region: #{region}")
          ["region" | updates]

        {:error, reason} ->
          IO.puts("❌ Failed to set region: #{inspect(reason)}")
          updates
      end

    if length(updates) > 0 do
      IO.puts("\n✅ Configuration updated: #{Enum.join(updates, ", ")}")
      IO.puts("💡 Run 'mix phoenix_kit.configure_aws_ses --status' to verify")
    else
      IO.puts("\n❌ No configuration changes made")
    end
  end

  defp interactive_configuration do
    IO.puts("🚀 PhoenixKit AWS SES Integration Setup")
    IO.puts("=====================================")

    IO.puts("\nThis wizard will help you configure AWS SES integration.")
    IO.puts("You can press Enter to skip optional settings.\n")

    config_set = prompt("AWS SES Configuration Set name", "phoenixkit-system")

    if config_set != "" do
      Emails.set_ses_configuration_set(config_set)
    end

    region = prompt("AWS Region", @default_region)
    Emails.set_aws_region(region)

    enable_ses = prompt_boolean("Enable SES event management?", true)
    Emails.set_ses_events(enable_ses)

    IO.puts("\n✅ Configuration completed!")
    IO.puts("💡 Run 'mix phoenix_kit.configure_aws_ses --status' to verify")
  end

  # Helper functions
  defp format_boolean(value) do
    case value do
      true -> "✅ Yes"
      false -> "❌ No"
    end
  end

  defp prompt(message, default) do
    default_text = format_default(default)
    input = IO.gets("#{message}#{default_text}: ") |> String.trim()

    if input == "", do: default, else: input
  end

  defp format_default(""), do: ""
  defp format_default(default), do: " [#{default}]"

  @spec prompt_boolean(String.t(), boolean()) :: boolean()
  defp prompt_boolean(message, default) when is_boolean(default) do
    default_text =
      case default do
        true -> " [Y/n]"
        false -> " [y/N]"
      end

    input = IO.gets("#{message}#{default_text}: ") |> String.trim() |> String.downcase()

    case input do
      "" -> default
      "y" -> true
      "yes" -> true
      "n" -> false
      "no" -> false
      _ -> default
    end
  end

  defp print_help do
    IO.puts("""
    🔧 PhoenixKit AWS SES Configuration

    USAGE:
        mix phoenix_kit.configure_aws_ses [options]

    OPTIONS:
        --config-set NAME    Set AWS SES configuration set name
        --region REGION      Set AWS region (default: eu-north-1)
        --enable-polling     Enable SQS polling
        --status, -s         Show current configuration status
        --help, -h           Show this help

    EXAMPLES:
        mix phoenix_kit.configure_aws_ses --status
        mix phoenix_kit.configure_aws_ses --config-set "phoenixkit-system"

    DESCRIPTION:
        This task helps configure AWS SES integration for comprehensive email
        management including delivery status, bounces, complaints, and engagement
        events. Supports interactive setup or automated configuration.
    """)
  end
end
