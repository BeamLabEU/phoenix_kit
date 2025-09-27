defmodule PhoenixKit.EmailSystem.ApplicationIntegration do
  @moduledoc """
  Helpers for integrating PhoenixKit Email Tracking into parent applications.

  This module provides convenient functions for adding email system
  to your Phoenix application's supervision tree.

  ## Quick Integration

  The simplest way to add email system:

      # In lib/your_app/application.ex
      def start(_type, _args) do
        children = [
          # ... your processes
        ] ++ PhoenixKit.EmailSystem.ApplicationIntegration.children()

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  ## Conditional Integration

  If you want to control when email system starts:

      # In lib/your_app/application.ex
      def start(_type, _args) do
        base_children = [
          # ... your main processes
        ]

        children = base_children ++ email_children()

        Supervisor.start_link(children, strategy: :one_for_one)
      end

      defp email_children do
        if email_enabled?() do
          PhoenixKit.EmailSystem.ApplicationIntegration.children()
        else
          []
        end
      end

      defp email_enabled? do
        # Your logic for determining if email system is enabled
        System.get_env("EMAIL_TRACKING_ENABLED") == "true"
      end

  ## Advanced Integration

  For full control use separate functions:

      children = [
        # ... your processes
      ] ++ PhoenixKit.EmailSystem.ApplicationIntegration.supervisor_children()
  """

  alias PhoenixKit.EmailSystem

  @doc """
  Returns list of child specs for adding to supervision tree.

  This is the main function for email system integration.

  ## Options

  - `:supervisor_name` - supervisor process name
  - `:start_sqs_worker` - force enable/disable SQS Worker

  ## Examples

      # Basic usage
      children = PhoenixKit.EmailSystem.ApplicationIntegration.children()

      # With custom options
      children = PhoenixKit.EmailSystem.ApplicationIntegration.children(
        supervisor_name: MyApp.EmailSystemSupervisor,
        start_sqs_worker: true
      )
  """
  def children(opts \\ []) do
    if should_start_email_system?(opts) do
      [supervisor_child_spec(opts)]
    else
      []
    end
  end

  @doc """
  Returns child spec for email system supervisor.

  ## Examples

      supervisor_spec = PhoenixKit.EmailSystem.ApplicationIntegration.supervisor_child_spec()
  """
  def supervisor_child_spec(opts \\ []) do
    supervisor_name = Keyword.get(opts, :supervisor_name, EmailSystem.Supervisor)

    %{
      id: supervisor_name,
      start: {EmailSystem.Supervisor, :start_link, [[name: supervisor_name]]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @doc """
  Returns only children for supervisor (without supervisor itself).

  Use if you want to add email system processes
  to existing supervisor.

  ## Examples

      # In your supervisor module
      def init(_opts) do
        children = [
          # ... your processes
        ] ++ PhoenixKit.EmailSystem.ApplicationIntegration.supervisor_children()

        Supervisor.init(children, strategy: :one_for_one)
      end
  """
  def supervisor_children(opts \\ []) do
    if should_start_email_system?(opts) do
      build_worker_children(opts)
    else
      []
    end
  end

  @doc """
  Checks if system is ready to start email system.

  ## Examples

      iex> PhoenixKit.EmailSystem.ApplicationIntegration.ready_for_email_system?()
      true

      iex> PhoenixKit.EmailSystem.ApplicationIntegration.ready_for_email_system?()
      {:error, :email_disabled}
  """
  def ready_for_email_system? do
    cond do
      not EmailSystem.enabled?() ->
        {:error, :email_disabled}

      not EmailSystem.sqs_polling_enabled?() ->
        {:error, :sqs_polling_disabled}

      not has_valid_sqs_configuration?() ->
        {:error, :invalid_sqs_configuration}

      not has_aws_credentials?() ->
        {:error, :missing_aws_credentials}

      true ->
        true
    end
  end

  @doc """
  Performs pre-flight checks for email system system.

  Returns detailed report on system readiness.

  ## Examples

      iex> PhoenixKit.EmailSystem.ApplicationIntegration.preflight_check()
      %{
        status: :ready,
        checks: %{
          email_enabled: true,
          sqs_polling_enabled: true,
          sqs_configuration: true,
          aws_credentials: true
        }
      }
  """
  def preflight_check do
    checks = %{
      email_enabled: EmailSystem.enabled?(),
      sqs_polling_enabled: EmailSystem.sqs_polling_enabled?(),
      sqs_configuration: has_valid_sqs_configuration?(),
      aws_credentials: has_aws_credentials?(),
      dependencies_loaded: dependencies_loaded?()
    }

    status =
      if Enum.all?(checks, fn {_key, value} -> value end) do
        :ready
      else
        :not_ready
      end

    %{
      status: status,
      checks: checks,
      issues: get_issues(checks)
    }
  end

  @doc """
  Creates initial configuration for email system.

  Useful for initializing system with basic settings.

  ## Examples

      PhoenixKit.EmailSystem.ApplicationIntegration.initialize_configuration()
  """
  def initialize_configuration do
    # Create basic settings if they do not exist
    default_settings = [
      {"email_enabled", "true"},
      {"email_save_body", "false"},
      {"email_ses_events", "true"},
      {"email_retention_days", "90"},
      {"email_sampling_rate", "100"},
      {"sqs_polling_enabled", "false"},
      {"sqs_polling_interval_ms", "5000"},
      {"sqs_max_messages_per_poll", "10"},
      {"sqs_visibility_timeout", "300"},
      {"aws_region", System.get_env("AWS_REGION", "eu-north-1")}
    ]

    Enum.each(default_settings, fn {key, default_value} ->
      case PhoenixKit.Settings.get_setting(key) do
        nil ->
          PhoenixKit.Settings.update_setting_with_module(
            key,
            default_value,
            "email_system"
          )

        _ ->
          :already_exists
      end
    end)
  end

  ## --- Private Functions ---

  # Determines whether email system should start
  defp should_start_email_system?(opts) do
    force_start = Keyword.get(opts, :start_sqs_worker, nil)

    case force_start do
      true -> true
      false -> false
      nil -> EmailSystem.enabled?() and EmailSystem.sqs_polling_enabled?()
    end
  end

  # Builds list of worker children
  defp build_worker_children(opts) do
    children = []

    # Add SQS Worker
    children =
      if should_start_sqs_worker?(opts) do
        [build_sqs_worker_child_spec() | children]
      else
        children
      end

    # In the future, other workers can be added:
    # - Metrics collector
    # - Archiver worker
    # - Cleanup scheduler

    children
  end

  # Determines whether SQS Worker should start
  defp should_start_sqs_worker?(opts) do
    force_start = Keyword.get(opts, :start_sqs_worker, nil)

    case force_start do
      true ->
        true

      false ->
        false

      nil ->
        EmailSystem.sqs_polling_enabled?() and has_valid_sqs_configuration?()
    end
  end

  # Creates child spec for SQS Worker
  defp build_sqs_worker_child_spec do
    %{
      id: EmailSystem.SQSWorker,
      start: {EmailSystem.SQSWorker, :start_link, [[]]},
      type: :worker,
      restart: :permanent,
      shutdown: 10_000
    }
  end

  # Checks SQS configuration validity
  defp has_valid_sqs_configuration? do
    sqs_config = EmailSystem.get_sqs_config()

    not is_nil(sqs_config.queue_url) and
      sqs_config.queue_url != "" and
      not is_nil(sqs_config.aws_region) and
      sqs_config.aws_region != ""
  end

  # Checks for AWS credentials
  defp has_aws_credentials? do
    # Check environment variables
    access_key = System.get_env("AWS_ACCESS_KEY_ID")
    secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")

    not is_nil(access_key) and access_key != "" and
      (not is_nil(secret_key) and secret_key != "")
  end

  # Checks if required dependencies are loaded
  defp dependencies_loaded? do
    # Check that ExAws modules are available
    Code.ensure_loaded?(ExAws) and
      Code.ensure_loaded?(ExAws.SQS) and
      Code.ensure_loaded?(Jason)
  rescue
    _ -> false
  end

  # Returns list of issues based on checks
  defp get_issues(checks) do
    checks
    |> Enum.filter(fn {_key, value} -> not value end)
    |> Enum.map(fn {key, _value} -> key end)
  end
end
