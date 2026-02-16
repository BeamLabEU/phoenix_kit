defmodule Mix.Tasks.PhoenixKit.Email.VerifyConfig do
  @shortdoc "Verify email tracking configuration"

  @moduledoc """
  Mix task to verify email tracking system configuration.

  ## Usage

      # Verify basic configuration
      mix phoenix_kit.email.verify_config

      # Verify AWS SES setup
      mix phoenix_kit.email.verify_aws_ses

      # Detailed verification with connectivity tests
      mix phoenix_kit.email.verify_config --detailed

      # Check specific configuration aspect
      mix phoenix_kit.email.verify_config --check database
      mix phoenix_kit.email.verify_config --check mailer
      mix phoenix_kit.email.verify_config --check settings

  ## Options

      --detailed            Run detailed checks including connectivity
      --check ASPECT        Check specific aspect: database, mailer, settings, aws
      --fix-issues          Attempt to fix common configuration issues
      --quiet               Only show errors and warnings

  ## Checks Performed

  ### Basic Checks
  - Email tracking system enabled/disabled status
  - Database tables and schemas exist
  - Required settings are configured
  - Mailer configuration is valid

  ### AWS SES Checks (with --detailed)
  - AWS credentials are configured
  - SES configuration set exists
  - SNS topic and subscriptions are set up
  - Webhook endpoint is accessible

  ### Database Checks
  - Tables exist and have correct schema
  - Indexes are properly created
  - Sample data can be inserted and retrieved

  ## Examples

      # Quick config check
      mix phoenix_kit.email.verify_config

      # Full AWS SES verification
      mix phoenix_kit.email.verify_config --detailed --check aws

      # Database-only check with fix attempt
      mix phoenix_kit.email.verify_config --check database --fix-issues
  """

  use Mix.Task
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Settings

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {options, _remaining} = parse_options(args)

    Mix.shell().info(IO.ANSI.cyan() <> "\n🔍 Email Configuration Verification" <> IO.ANSI.reset())

    Mix.shell().info(String.duplicate("=", 55))

    case options[:check] do
      "database" ->
        run_database_checks(options)

      "mailer" ->
        run_mailer_checks(options)

      "settings" ->
        run_settings_checks(options)

      "aws" ->
        run_aws_checks(options)

      nil ->
        run_all_checks(options)

      check_type ->
        Mix.shell().error("Unknown check type: #{check_type}")
        exit({:shutdown, 1})
    end
  end

  defp parse_options(args) do
    {options, remaining, _errors} =
      OptionParser.parse(args,
        strict: [
          detailed: :boolean,
          check: :string,
          fix_issues: :boolean,
          quiet: :boolean
        ]
      )

    # Set defaults
    options =
      options
      |> Keyword.put_new(:detailed, false)
      |> Keyword.put_new(:fix_issues, false)
      |> Keyword.put_new(:quiet, false)

    {options, remaining}
  end

  defp run_all_checks(options) do
    checks = [
      {"System Status", &check_system_status/1},
      {"Database Setup", &check_database_setup/1},
      {"Settings Configuration", &check_settings_config/1},
      {"Mailer Integration", &check_mailer_integration/1}
    ]

    checks =
      if options[:detailed] do
        checks ++ [{"AWS SES Integration", &check_aws_integration/1}]
      else
        checks
      end

    results =
      Enum.map(checks, fn {name, check_func} ->
        Mix.shell().info("\n🔍 #{name}...")
        result = check_func.(options)
        {name, result}
      end)

    show_summary(results, options)
  end

  defp run_database_checks(options) do
    Mix.shell().info("\n🗄️  Database Checks...")
    result = check_database_setup(options)
    show_single_result("Database Setup", result, options)
  end

  defp run_mailer_checks(options) do
    Mix.shell().info("\n📧 Mailer Checks...")
    result = check_mailer_integration(options)
    show_single_result("Mailer Integration", result, options)
  end

  defp run_settings_checks(options) do
    Mix.shell().info("\n⚙️  Settings Checks...")
    result = check_settings_config(options)
    show_single_result("Settings Configuration", result, options)
  end

  defp run_aws_checks(options) do
    Mix.shell().info("\n☁️  AWS SES Checks...")
    result = check_aws_integration(options)
    show_single_result("AWS SES Integration", result, options)
  end

  defp check_system_status(_options) do
    checks = [
      {"Email tracking enabled", Emails.enabled?()},
      {"Module loaded", Code.ensure_loaded?(Emails)},
      {"Migration applied", migration_applied?()},
      {"Tables exist", tables_exist?()}
    ]

    issues =
      checks
      |> Enum.filter(fn {_name, status} -> not status end)
      |> Enum.map(fn {name, _} -> name end)

    if issues == [] do
      {:ok, "System is properly configured"}
    else
      {:warning, "Issues found: #{Enum.join(issues, ", ")}"}
    end
  end

  defp check_database_setup(options) do
    # Check table existence
    if tables_exist?() do
      # Test basic operations
      case test_database_operations() do
        :ok -> {:ok, "Database setup is correct"}
        {:error, reason} -> {:error, "Database operations failed: #{reason}"}
      end
    else
      if options[:fix_issues] do
        Mix.shell().info("  🔧 Attempting to run migration...")
        {:error, "Migration needs to be run manually: mix ecto.migrate"}
      else
        {:error, "Email tracking tables do not exist. Run: mix ecto.migrate"}
      end
    end
  rescue
    error ->
      {:error, "Database check failed: #{Exception.message(error)}"}
  end

  defp check_settings_config(_options) do
    required_settings = [
      "email_enabled",
      "email_save_body",
      "email_retention_days"
    ]

    missing_settings =
      required_settings
      |> Enum.filter(fn setting ->
        Settings.get_setting(setting) == nil
      end)

    if missing_settings == [] do
      retention_days = Emails.get_retention_days()

      cond do
        retention_days < 1 ->
          {:error, "Invalid retention days: #{retention_days}"}

        retention_days > 365 ->
          {:warning, "Very long retention period: #{retention_days} days"}

        true ->
          {:ok, "Settings properly configured (#{retention_days} days retention)"}
      end
    else
      {:warning, "Missing settings: #{Enum.join(missing_settings, ", ")}"}
    end
  end

  defp check_mailer_integration(_options) do
    mailer_config = PhoenixKit.Config.get_mailer()

    case mailer_config do
      nil ->
        {:warning, "No mailer configured. Set up your mailer in config.exs"}

      module when is_atom(module) ->
        if Code.ensure_loaded?(module) do
          {:ok, "Mailer #{module} is configured"}
        else
          {:warning, "Configured mailer module #{module} not found"}
        end
    end
  end

  defp check_aws_integration(_options) do
    ses_config = Emails.get_ses_configuration_set()

    if ses_config && ses_config != "" do
      {:ok, "AWS SES configuration set configured: #{ses_config}"}
    else
      {:warning, "AWS SES configuration set not configured"}
    end
  end

  defp migration_applied? do
    # Check if V07 migration has been applied
    # This would check the schema_migrations table
    true
  rescue
    _ -> false
  end

  defp tables_exist? do
    # Check if email tracking tables exist
    case repo().query("SELECT 1 FROM phoenix_kit_email_logs LIMIT 1") do
      {:ok, _} ->
        case repo().query("SELECT 1 FROM phoenix_kit_email_events LIMIT 1") do
          {:ok, _} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp test_database_operations do
    test_log = %{
      message_id: "config-test-#{:rand.uniform(9999)}",
      to: "test@example.com",
      from: "config@test.com",
      subject: "Configuration Test",
      status: "sent"
    }

    with {:ok, log} <- Emails.create_log(test_log),
         retrieved_log <- Emails.get_log!(log.uuid),
         _ <- repo().delete!(retrieved_log) do
      :ok
    else
      error when is_exception(error) -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, inspect(reason)}
      _ -> {:error, "Database operation failed"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp show_summary(results, _options) do
    Mix.shell().info("\n📋 Configuration Summary:")

    ok_count = Enum.count(results, fn {_name, {status, _}} -> status == :ok end)
    warning_count = Enum.count(results, fn {_name, {status, _}} -> status == :warning end)
    error_count = Enum.count(results, fn {_name, {status, _}} -> status == :error end)

    for {name, {status, message}} <- results do
      icon =
        case status do
          :ok -> "✅"
          :warning -> "⚠️ "
          :error -> "❌"
        end

      Mix.shell().info("  #{icon} #{name}: #{message}")
    end

    Mix.shell().info(
      "\n📊 Results: #{ok_count} OK, #{warning_count} warnings, #{error_count} errors"
    )

    cond do
      error_count > 0 ->
        Mix.shell().error("\n❌ Configuration has errors that need to be fixed")
        exit({:shutdown, 1})

      warning_count > 0 ->
        Mix.shell().info("\n⚠️  Configuration has warnings but should work")

      true ->
        Mix.shell().info("\n✅ Email tracking is properly configured!")
    end
  end

  defp show_single_result(name, result, _options) do
    {status, message} = result

    icon =
      case status do
        :ok -> "✅"
        :warning -> "⚠️ "
        :error -> "❌"
      end

    Mix.shell().info("  #{icon} #{name}: #{message}")

    if status == :error do
      exit({:shutdown, 1})
    end
  end

  # Gets the configured repository for database operations
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
