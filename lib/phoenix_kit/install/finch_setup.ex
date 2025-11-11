defmodule PhoenixKit.Install.FinchSetup do
  use PhoenixKit.Install.IgniterCompat

  @moduledoc """
  Handles automatic Finch and HTTP client setup for PhoenixKit installation.

  This module provides functionality to:
  - Detect if HTTP client adapters (like AmazonSES, SendGrid, etc.) are being used
  - Automatically add Finch to the application supervisor when needed
  - Add required dependencies like gen_smtp for AWS SES
  - Configure Swoosh API client appropriately
  """

  alias Igniter.Project.{Application, Config, Deps}

  @doc """
  Automatically configures Finch and dependencies based on mailer adapter configuration.

  This function checks if any HTTP-based email adapters are configured and:
  - Adds Finch to the application supervisor
  - Adds gen_smtp dependency for AWS SES
  - Configures Swoosh API client

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with Finch configuration if needed.
  """
  def add_finch_configuration(igniter) do
    igniter
    |> maybe_add_finch_dependency()
    |> maybe_add_finch_supervisor()
    |> maybe_add_gen_smtp_dependency()
    |> add_swoosh_api_client_config()
  end

  # Always add Finch to supervisor - it's lightweight and allows future HTTP adapter use
  defp maybe_add_finch_supervisor(igniter) do
    Application.add_new_child(
      igniter,
      {Finch, name: Swoosh.Finch},
      opts: [after: [:telemetry_supervisor, :pubsub]]
    )
  end

  # Always add Finch dependency for HTTP email adapters
  defp maybe_add_finch_dependency(igniter) do
    Deps.add_dep(igniter, {:finch, "~> 0.18"})
  end

  # Check if AWS SES is being used and add gen_smtp dependency
  defp maybe_add_gen_smtp_dependency(igniter) do
    if needs_gen_smtp?(igniter) do
      Deps.add_dep(igniter, {:gen_smtp, "~> 1.2"})
    else
      igniter
    end
  end

  # Configure Swoosh API client to use Finch
  defp add_swoosh_api_client_config(igniter) do
    # Always configure Finch as the API client in config.exs
    # This allows users to switch to HTTP-based adapters later without conflicts
    Config.configure_new(
      igniter,
      "config.exs",
      :swoosh,
      [:api_client],
      Swoosh.ApiClient.Finch
    )
  rescue
    _ ->
      add_swoosh_config_simple(igniter)
  end

  # Simple file append for Swoosh config when Igniter fails
  defp add_swoosh_config_simple(igniter) do
    swoosh_config = """

    # Swoosh API client configuration
    config :swoosh, api_client: Swoosh.ApiClient.Finch
    """

    try do
      igniter =
        Igniter.update_file(igniter, "config/config.exs", fn source ->
          content = Rewrite.Source.get(source, :content)

          # Check if already configured
          if String.contains?(content, "config :swoosh, api_client:") do
            source
          else
            # Find insertion point before import_config
            updated_content =
              case find_import_config_location_simple(content) do
                {:before_import, before_content, after_content} ->
                  before_content <> swoosh_config <> "\n" <> after_content

                :append_to_end ->
                  content <> swoosh_config
              end

            Rewrite.Source.update(source, :content, updated_content)
          end
        end)

      igniter
    rescue
      e ->
        IO.warn("Failed to configure Swoosh API client automatically: #{inspect(e)}")
        add_swoosh_config_manual_notice(igniter)
    end
  end

  # Helper to find import_config location (simplified version)
  defp find_import_config_location_simple(content) do
    if String.contains?(content, "import_config") do
      lines = String.split(content, "\n")

      import_index =
        Enum.find_index(lines, fn line ->
          String.contains?(line, "import_config")
        end)

      case import_index do
        nil ->
          :append_to_end

        index ->
          # Find start of import block
          start_index = max(0, index - 3)
          before_lines = Enum.take(lines, start_index)
          after_lines = Enum.drop(lines, start_index)

          before_content = Enum.join(before_lines, "\n")
          after_content = Enum.join(after_lines, "\n")

          {:before_import, before_content, after_content}
      end
    else
      :append_to_end
    end
  end

  # Manual configuration notice for Swoosh
  defp add_swoosh_config_manual_notice(igniter) do
    notice = """
    ⚠️  Manual Swoosh Configuration Required

    PhoenixKit couldn't automatically configure Swoosh API client.

    Please add this to config/config.exs:

      config :swoosh, api_client: Swoosh.ApiClient.Finch
    """

    Igniter.add_notice(igniter, notice)
  end

  # Check if AWS SES is being used (needs gen_smtp)
  defp needs_gen_smtp?(igniter) do
    check_config_for_adapters(igniter, ["Swoosh.Adapters.AmazonSES"])
  end

  # Helper to check if any of the specified adapters are configured
  defp check_config_for_adapters(igniter, adapters) do
    config_files = ["config.exs", "dev.exs", "prod.exs"]

    Enum.any?(config_files, fn file ->
      case igniter.rewrite.sources[file] do
        nil ->
          false

        source ->
          content = Rewrite.Source.get(source, :content)
          Enum.any?(adapters, &String.contains?(content, &1))
      end
    end)
  end
end
