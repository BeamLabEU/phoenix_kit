defmodule PhoenixKit.Install.OAuthConfig do
  @moduledoc """
  Handles OAuth configuration for PhoenixKit installation.

  PhoenixKit uses **fully dynamic OAuth** - providers are configured at runtime from database.
  However, a minimal compile-time configuration is still required for Ueberauth to initialize.

  ## How It Works

  Instead of using `plug Ueberauth` (which requires compile-time providers configuration),
  PhoenixKit calls Ueberauth functions directly in the OAuth controller:

  ```elixir
  # In PhoenixKitWeb.Users.OAuth controller:
  # - request/2 calls Ueberauth.run_request/4
  # - callback/2 calls Ueberauth.run_callback/4
  ```

  This approach allows:
  - **Minimal compile-time configuration** - Only `config :ueberauth, Ueberauth, providers: []`
  - **Database-driven credentials** - Credentials loaded from Settings table at runtime
  - **Dynamic provider management** - Add/remove/modify providers without app restart

  ## Runtime OAuth Flow

  1. User clicks "Sign in with Google"
  2. `PhoenixKitWeb.Plugs.EnsureOAuthConfig` loads credentials from database
  3. `PhoenixKitWeb.Users.OAuth.request/2` calls `Ueberauth.run_request/4` dynamically
  4. User authenticates with provider
  5. `PhoenixKitWeb.Users.OAuth.callback/2` calls `Ueberauth.run_callback/4` dynamically
  6. User is logged in

  ## Related Modules

  - `PhoenixKit.Users.OAuthConfig` - Configures credentials in Application env at runtime
  - `PhoenixKit.Workers.OAuthConfigLoader` - Loads OAuth config on app startup
  - `PhoenixKitWeb.Plugs.EnsureOAuthConfig` - Ensures credentials loaded before OAuth
  - `PhoenixKitWeb.Users.OAuth` - OAuth controller with dynamic Ueberauth calls
  """
  use PhoenixKit.Install.IgniterCompat

  @doc """
  Adds OAuth configuration for PhoenixKit installation.

  This adds the minimal Ueberauth configuration required for compilation.
  OAuth providers are configured dynamically at runtime from the database.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with Ueberauth configuration and informational notice.

  ## Example
  ```elixir
  igniter
  |> OAuthConfig.add_oauth_configuration()
  ```
  """
  def add_oauth_configuration(igniter) do
    igniter
    |> add_ueberauth_config()
    |> add_oauth_configuration_notice()
  end

  # Add minimal Ueberauth config required for compilation
  # Providers are configured dynamically at runtime from database
  defp add_ueberauth_config(igniter) do
    ueberauth_config = """

    # Configure Ueberauth (minimal configuration for compilation)
    # OAuth providers are configured dynamically at runtime from database
    config :ueberauth, Ueberauth, providers: []
    """

    try do
      Igniter.update_file(igniter, "config/config.exs", fn source ->
        content = Rewrite.Source.get(source, :content)

        # Check if Ueberauth config already exists
        if String.contains?(content, "config :ueberauth") do
          source
        else
          # Find insertion point before import_config statements
          insertion_point = find_import_config_location(content)

          updated_content =
            case insertion_point do
              {:before_import, before_content, after_content} ->
                # Insert before import_config
                before_content <> ueberauth_config <> "\n" <> after_content

              :append_to_end ->
                # No import_config found, append to end
                content <> ueberauth_config
            end

          Rewrite.Source.update(source, :content, updated_content)
        end
      end)
    rescue
      e ->
        IO.warn("Failed to add Ueberauth configuration: #{inspect(e)}")
        add_manual_config_notice(igniter)
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

  # Add informational notice about OAuth configuration
  defp add_oauth_configuration_notice(igniter) do
    Igniter.add_notice(
      igniter,
      "🔐 OAuth ready (providers configured dynamically from database at runtime)"
    )
  end

  # Add notice when manual configuration is required
  defp add_manual_config_notice(igniter) do
    notice = """
    ⚠️  Manual Configuration Required: Ueberauth

    PhoenixKit couldn't automatically configure Ueberauth.

    Please add the following to config/config.exs:

      config :ueberauth, Ueberauth, providers: []

    This minimal configuration is required for compilation.
    OAuth providers are configured dynamically at runtime from the database.
    """

    Igniter.add_notice(igniter, notice)
  end
end
