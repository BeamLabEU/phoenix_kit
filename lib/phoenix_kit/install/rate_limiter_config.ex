defmodule PhoenixKit.Install.RateLimiterConfig do
  @moduledoc """
  Handles Hammer rate limiter configuration for PhoenixKit installation.

  This module provides functionality to:
  - Configure Hammer backend (ETS by default)
  - Add rate limiting configuration for PhoenixKit endpoints
  - Ensure configuration exists during updates
  """
  use PhoenixKit.Install.IgniterCompat

  @doc """
  Adds or verifies Hammer rate limiter configuration.

  This function ensures that both:
  1. Hammer backend configuration exists (required for Hammer to start)
  2. PhoenixKit rate limiter settings are configured

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with rate limiter configuration and notices.
  """
  def add_rate_limiter_configuration(igniter) do
    igniter
    |> add_hammer_backend_config()
    |> add_phoenix_kit_rate_limiter_config()
    |> add_rate_limiter_notice()
  end

  @doc """
  Checks if Hammer configuration exists in config.exs.

  ## Parameters
  - `_igniter` - The igniter context (unused but required for API consistency)

  ## Returns
  Boolean indicating if configuration exists.
  """
  def hammer_config_exists?(_igniter) do
    config_path = "config/config.exs"

    if File.exists?(config_path) do
      content = File.read!(config_path)
      String.contains?(content, "config :hammer") and String.contains?(content, "expiry_ms")
    else
      false
    end
  rescue
    _ -> false
  end

  # Add Hammer backend configuration to config.exs
  defp add_hammer_backend_config(igniter) do
    hammer_config = """

    # Configure rate limiting with Hammer
    config :hammer,
      backend:
        {Hammer.Backend.ETS,
         [
           # Cleanup expired rate limit buckets every 60 seconds
           expiry_ms: 60_000,
           # Cleanup interval (1 minute)
           cleanup_interval_ms: 60_000
         ]}
    """

    try do
      Igniter.update_file(igniter, "config/config.exs", fn source ->
        content = Rewrite.Source.get(source, :content)

        # Check if Hammer config already exists
        if String.contains?(content, "config :hammer") do
          source
        else
          # Find insertion point before import_config statements
          insertion_point = find_import_config_location(content)

          updated_content =
            case insertion_point do
              {:before_import, before_content, after_content} ->
                # Insert before import_config
                before_content <> hammer_config <> "\n" <> after_content

              :append_to_end ->
                # No import_config found, append to end
                content <> hammer_config
            end

          Rewrite.Source.update(source, :content, updated_content)
        end
      end)
    rescue
      e ->
        IO.warn("Failed to add Hammer configuration: #{inspect(e)}")
        add_manual_config_notice(igniter, :hammer)
    end
  end

  # Add PhoenixKit rate limiter configuration to config.exs
  defp add_phoenix_kit_rate_limiter_config(igniter) do
    rate_limiter_config = """

    # Configure rate limits for authentication endpoints
    config :phoenix_kit, PhoenixKit.Users.RateLimiter,
      # Login: 5 attempts per minute per email
      login_limit: 5,
      login_window_ms: 60_000,
      # Magic link: 3 requests per 5 minutes per email
      magic_link_limit: 3,
      magic_link_window_ms: 300_000,
      # Password reset: 3 requests per 5 minutes per email
      password_reset_limit: 3,
      password_reset_window_ms: 300_000,
      # Registration: 3 attempts per hour per email
      registration_limit: 3,
      registration_window_ms: 3_600_000,
      # Registration IP: 10 attempts per hour per IP
      registration_ip_limit: 10,
      registration_ip_window_ms: 3_600_000
    """

    try do
      Igniter.update_file(igniter, "config/config.exs", fn source ->
        content = Rewrite.Source.get(source, :content)

        # Check if PhoenixKit rate limiter config already exists
        if String.contains?(content, "config :phoenix_kit, PhoenixKit.Users.RateLimiter") do
          source
        else
          # Find insertion point before import_config statements
          insertion_point = find_import_config_location(content)

          updated_content =
            case insertion_point do
              {:before_import, before_content, after_content} ->
                # Insert before import_config
                before_content <> rate_limiter_config <> "\n" <> after_content

              :append_to_end ->
                # No import_config found, append to end
                content <> rate_limiter_config
            end

          Rewrite.Source.update(source, :content, updated_content)
        end
      end)
    rescue
      e ->
        IO.warn("Failed to add PhoenixKit rate limiter configuration: #{inspect(e)}")
        add_manual_config_notice(igniter, :rate_limiter)
    end
  end

  # Find the location to insert config before import_config statements
  defp find_import_config_location(content) do
    lines = String.split(content, "\n")

    # Look for import_config pattern
    import_index =
      Enum.find_index(lines, fn line ->
        trimmed = String.trim(line)
        String.starts_with?(trimmed, "import_config") or String.contains?(line, "import_config")
      end)

    case import_index do
      nil ->
        # No import_config found, append to end
        :append_to_end

      index ->
        # Find the start of the import_config block
        start_index = find_import_block_start(lines, index)

        # Split content at the start of import block
        before_lines = Enum.take(lines, start_index)
        after_lines = Enum.drop(lines, start_index)

        before_content = Enum.join(before_lines, "\n")
        after_content = Enum.join(after_lines, "\n")

        {:before_import, before_content, after_content}
    end
  end

  # Find the start of the import_config block (including preceding comments)
  defp find_import_block_start(lines, import_index) do
    lines
    |> Enum.take(import_index)
    |> Enum.reverse()
    |> Enum.reduce_while(import_index, fn line, current_index ->
      trimmed = String.trim(line)

      cond do
        # Comment line related to import
        String.starts_with?(trimmed, "#") and
            (String.contains?(line, "import") or String.contains?(line, "Import") or
               String.contains?(line, "bottom") or String.contains?(line, "BOTTOM") or
               String.contains?(line, "environment")) ->
          {:cont, current_index - 1}

        # Blank line
        trimmed == "" ->
          {:cont, current_index - 1}

        # config_env or similar
        String.contains?(line, "config_env()") or String.contains?(line, "env_config") ->
          {:cont, current_index - 1}

        # Stop at any other code
        true ->
          {:halt, current_index}
      end
    end)
  end

  # Add notice about rate limiter configuration
  defp add_rate_limiter_notice(igniter) do
    if hammer_config_exists?(igniter) do
      Igniter.add_notice(
        igniter,
        "🛡️  Rate limiting configured (Hammer + PhoenixKit.Users.RateLimiter)"
      )
    else
      Igniter.add_notice(
        igniter,
        "⚠️  Rate limiting configuration added - restart your server if running"
      )
    end
  end

  # Add notice when manual configuration is required
  defp add_manual_config_notice(igniter, :hammer) do
    notice = """
    ⚠️  Manual Configuration Required: Hammer

    PhoenixKit couldn't automatically configure Hammer rate limiting.

    Please add the following to config/config.exs:

      config :hammer,
        backend:
          {Hammer.Backend.ETS,
           [
             expiry_ms: 60_000,
             cleanup_interval_ms: 60_000
           ]}

    Without this configuration, your application will fail to start.
    """

    Igniter.add_notice(igniter, notice)
  end

  defp add_manual_config_notice(igniter, :rate_limiter) do
    notice = """
    ⚠️  Manual Configuration Required: PhoenixKit Rate Limiter

    PhoenixKit couldn't automatically configure rate limits.

    Please add the following to config/config.exs:

      config :phoenix_kit, PhoenixKit.Users.RateLimiter,
        login_limit: 5,
        login_window_ms: 60_000,
        magic_link_limit: 3,
        magic_link_window_ms: 300_000,
        password_reset_limit: 3,
        password_reset_window_ms: 300_000,
        registration_limit: 3,
        registration_window_ms: 3_600_000,
        registration_ip_limit: 10,
        registration_ip_window_ms: 3_600_000
    """

    Igniter.add_notice(igniter, notice)
  end
end
