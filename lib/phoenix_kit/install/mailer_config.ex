defmodule PhoenixKit.Install.MailerConfig do
  @moduledoc """
  Handles mailer configuration for PhoenixKit installation.

  This module provides functionality to:
  - Configure development mailer with Swoosh.Adapters.Local
  - Add production mailer templates for various providers
  - Generate appropriate notices for mailer setup
  """
  use PhoenixKit.Install.IgniterCompat

  alias Igniter.Project.Config
  alias PhoenixKit.Install.FinchSetup
  alias PhoenixKit.Install.IgniterHelpers
  alias PhoenixKit.Install.RuntimeDetector

  @doc """
  Adds PhoenixKit mailer configuration for development and production.

  Now supports both delegation mode and built-in mode:
  - **Delegation mode**: Configure PhoenixKit to use parent app's mailer
  - **Built-in mode**: Configure PhoenixKit's own mailer (legacy)

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with mailer configuration and notices.
  """
  def add_mailer_configuration(igniter) do
    igniter
    |> add_mailer_delegation_config()
    |> add_prod_mailer_config()
    |> FinchSetup.add_finch_configuration()
    |> add_mailer_production_notice()
  end

  # Add mailer delegation configuration - detects and uses parent app's mailer
  defp add_mailer_delegation_config(igniter) do
    parent_app_name = IgniterHelpers.get_parent_app_name(igniter)

    case detect_parent_mailer(parent_app_name) do
      {:ok, parent_mailer} ->
        # Configure PhoenixKit to use parent app's mailer
        Config.configure_new(
          igniter,
          "config.exs",
          :phoenix_kit,
          [:mailer],
          parent_mailer
        )

      :not_found ->
        # Fall back to built-in PhoenixKit mailer
        add_dev_mailer_config(igniter)
    end
  end

  # Add Local mailer adapter for development - supports both dev.exs and runtime.exs
  defp add_dev_mailer_config(igniter) do
    case RuntimeDetector.detect_config_pattern() do
      :runtime ->
        add_runtime_mailer_config(igniter)

      :dev_exs ->
        add_simple_dev_mailer_config(igniter)

      :config_exs ->
        add_config_exs_mailer_config(igniter)
    end
  end

  # Add mailer config to runtime.exs file
  defp add_runtime_mailer_config(igniter) do
    # Check if dev.exs is altered/complex - if so, use simple append to runtime.exs
    if RuntimeDetector.dev_exs_exists?() && !RuntimeDetector.simple_dev_config?() do
      # Dev.exs is complex, use simple append strategy for runtime.exs
      append_to_runtime_file_simple(igniter)
    else
      # Use standard insertion strategy based on detection
      case RuntimeDetector.find_insertion_point() do
        {:runtime, line_number} ->
          insert_into_runtime_file(igniter, line_number)

        {:dev_exs, line_number} ->
          add_simple_dev_mailer_config_at_line(igniter, line_number)

        {:config_exs, line_number} ->
          add_config_exs_mailer_config_at_line(igniter, line_number)
      end
    end
  end

  # Simple dev.exs configuration (legacy behavior)
  defp add_simple_dev_mailer_config(igniter) do
    Config.configure_new(
      igniter,
      "dev.exs",
      :phoenix_kit,
      [PhoenixKit.Mailer],
      adapter: Swoosh.Adapters.Local
    )
  end

  # Add mailer config to config.exs with environment check
  defp add_config_exs_mailer_config(igniter) do
    config_content = """
    # PhoenixKit mailer configuration
    if config_env() == :dev do
      config :phoenix_kit, PhoenixKit.Mailer,
        adapter: Swoosh.Adapters.Local
    end
    """

    # Try to append to config.exs, fall back to notice if it fails
    try do
      Igniter.update_file(igniter, "config/config.exs", fn source ->
        current_content = Rewrite.Source.get(source, :content)
        updated_content = current_content <> "\n" <> config_content
        Rewrite.Source.update(source, :content, updated_content)
      end)
    rescue
      _ ->
        add_runtime_config_notice(igniter)
    end
  end

  # Insert mailer config into runtime.exs file
  defp insert_into_runtime_file(igniter, line_number) do
    mailer_config = """
      # PhoenixKit mailer configuration
      config :phoenix_kit, PhoenixKit.Mailer,
        adapter: Swoosh.Adapters.Local
    """

    try do
      Igniter.update_file(igniter, "config/runtime.exs", fn source ->
        current_content = Rewrite.Source.get(source, :content)
        lines = String.split(current_content, "\n")

        # Insert at the specified line
        {before_lines, after_lines} = Enum.split(lines, line_number - 1)

        updated_content =
          (before_lines ++
             [mailer_config] ++
             after_lines)
          |> Enum.join("\n")

        Rewrite.Source.update(source, :content, updated_content)
      end)
    rescue
      _ ->
        # Fallback to simple append if AST parsing fails
        append_to_runtime_file_simple(igniter)
    end
  end

  # Simple append to runtime.exs using Igniter (no AST parsing)
  defp append_to_runtime_file_simple(igniter) do
    mailer_config = """

    # PhoenixKit mailer configuration
    config :phoenix_kit, PhoenixKit.Mailer,
      adapter: Swoosh.Adapters.Local
    """

    try do
      igniter =
        Igniter.update_file(igniter, "config/runtime.exs", fn source ->
          content = Rewrite.Source.get(source, :content)

          # Check if already configured
          if String.contains?(content, "config :phoenix_kit, PhoenixKit.Mailer") do
            source
          else
            # Find insertion point before import_config statements
            insertion_point = find_import_config_location(content)

            updated_content =
              case insertion_point do
                {:before_import, before_content, after_content} ->
                  # Insert before import_config
                  before_content <> mailer_config <> "\n" <> after_content

                :append_to_end ->
                  # No import_config found, append to end
                  content <> mailer_config
              end

            Rewrite.Source.update(source, :content, updated_content)
          end
        end)

      igniter
    rescue
      e ->
        # Last resort: show manual instructions
        IO.warn("Failed to automatically configure runtime.exs: #{inspect(e)}")
        add_runtime_config_notice(igniter)
    end
  end

  # Find the location to insert config before import_config statements
  defp find_import_config_location(content) do
    lines = String.split(content, "\n")

    # Look for import_config pattern (can have variations)
    import_index =
      Enum.find_index(lines, fn line ->
        trimmed = String.trim(line)

        String.starts_with?(trimmed, "import_config") or
          String.contains?(line, "import_config")
      end)

    case import_index do
      nil ->
        # No import_config found, append to end
        :append_to_end

      index ->
        # Find the start of the import_config block (look backwards for comments/blank lines)
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
    # Look backwards from import_config line to find where the block starts
    lines
    |> Enum.take(import_index)
    |> Enum.reverse()
    |> Enum.reduce_while(import_index, fn line, current_index ->
      trimmed = String.trim(line)

      cond do
        # Comment line that mentions "import" or "bottom" or "environment"
        String.starts_with?(trimmed, "#") and
            (String.contains?(line, "import") or
               String.contains?(line, "bottom") or
               String.contains?(line, "environment") or
               String.contains?(line, "Import") or
               String.contains?(line, "BOTTOM")) ->
          {:cont, current_index - 1}

        # Blank line
        trimmed == "" ->
          {:cont, current_index - 1}

        # env_config assignment or similar
        String.contains?(line, "config_env()") or
            String.contains?(line, "env_config") ->
          {:cont, current_index - 1}

        # Stop at any other code
        true ->
          {:halt, current_index}
      end
    end)
  end

  # Add dev mailer config at specific line number
  defp add_simple_dev_mailer_config_at_line(igniter, _line_number) do
    mailer_config = """

    # PhoenixKit mailer configuration
    config :phoenix_kit, PhoenixKit.Mailer,
      adapter: Swoosh.Adapters.Local
    """

    try do
      # Try using Igniter first for better integration
      Config.configure_new(
        igniter,
        "dev.exs",
        :phoenix_kit,
        [PhoenixKit.Mailer],
        adapter: Swoosh.Adapters.Local
      )
    rescue
      _ ->
        # Fallback to simple file append using Igniter
        try do
          igniter =
            Igniter.update_file(igniter, "config/dev.exs", fn source ->
              content = Rewrite.Source.get(source, :content)

              # Check if already configured
              if String.contains?(content, "config :phoenix_kit, PhoenixKit.Mailer") do
                source
              else
                updated_content = content <> mailer_config
                Rewrite.Source.update(source, :content, updated_content)
              end
            end)

          igniter
        rescue
          e ->
            IO.warn("Failed to configure dev.exs: #{inspect(e)}")
            add_runtime_config_notice(igniter)
        end
    end
  end

  # Add config_exs mailer config at specific line number
  defp add_config_exs_mailer_config_at_line(igniter, _line_number) do
    mailer_config = """

    # PhoenixKit mailer configuration
    if config_env() == :dev do
      config :phoenix_kit, PhoenixKit.Mailer,
        adapter: Swoosh.Adapters.Local
    end
    """

    try do
      igniter =
        Igniter.update_file(igniter, "config/config.exs", fn source ->
          content = Rewrite.Source.get(source, :content)

          # Check if already configured
          if String.contains?(content, "config :phoenix_kit, PhoenixKit.Mailer") do
            source
          else
            # Find insertion point before import_config statements
            insertion_point = find_import_config_location(content)

            updated_content =
              case insertion_point do
                {:before_import, before_content, after_content} ->
                  # Insert before import_config
                  before_content <> mailer_config <> "\n" <> after_content

                :append_to_end ->
                  # No import_config found, append to end
                  content <> mailer_config
              end

            Rewrite.Source.update(source, :content, updated_content)
          end
        end)

      igniter
    rescue
      e ->
        IO.warn("Failed to configure config.exs: #{inspect(e)}")
        add_runtime_config_notice(igniter)
    end
  end

  # Detect parent application's mailer module
  defp detect_parent_mailer(app_name) do
    app_module = app_name |> to_string() |> Macro.camelize()

    # Common mailer module patterns
    mailer_candidates = [
      Module.concat([app_module, "Mailer"]),
      Module.concat([app_module <> "Web", "Mailer"])
    ]

    # Find the first existing mailer module
    mailer_candidates
    |> Enum.find(&mailer_module_exists?/1)
    |> case do
      nil -> :not_found
      mailer -> {:ok, mailer}
    end
  end

  # Check if a mailer module exists in the project
  defp mailer_module_exists?(module) do
    case Code.ensure_compiled(module) do
      {:module, _} -> function_exported?(module, :deliver, 1)
      _ -> false
    end
  rescue
    _ -> false
  end

  # Add production mailer configuration template as comments
  defp add_prod_mailer_config(igniter) do
    prod_config_template = get_prod_mailer_template()

    try do
      if File.exists?("config/prod.exs") do
        # Try Igniter first for better integration
        Igniter.update_file(igniter, "config/prod.exs", fn source ->
          try do
            current_content = Rewrite.Source.get(source, :content)

            # Only add template if PhoenixKit mailer config doesn't already exist
            if String.contains?(current_content, "# Configure PhoenixKit mailer for production") do
              # Config already exists, no changes needed
              source
            else
              # Add the template
              updated_content = current_content <> "\n" <> prod_config_template
              Rewrite.Source.update(source, :content, updated_content)
            end
          rescue
            _ ->
              # Fallback: just return original source if there's an error
              source
          end
        end)
      else
        # Create prod.exs with import Config and template
        try do
          initial_content = "import Config\n" <> prod_config_template
          Igniter.create_new_file(igniter, "config/prod.exs", initial_content)
        rescue
          _ ->
            # Last resort: create file manually
            File.write!("config/prod.exs", "import Config\n" <> prod_config_template)
            igniter
        end
      end
    rescue
      e ->
        IO.warn("Failed to add production mailer config: #{inspect(e)}")
        igniter
    end
  end

  # Get production mailer configuration template
  defp get_prod_mailer_template do
    """
    # Configure PhoenixKit mailer for production
    #
    # IMPORTANT: Configure sender email address
    # config :phoenix_kit,
    #   from_email: "noreply@yourcompany.com",
    #   from_name: "Your Company Name"

    # OPTION 1 (RECOMMENDED): Use your app's existing mailer
    # PhoenixKit will automatically use your app's mailer if configured with:
    # config :phoenix_kit, mailer: MyApp.Mailer
    #
    # Then configure your app's mailer as usual:
    # config :my_app, MyApp.Mailer,
    #   adapter: Swoosh.Adapters.SMTP,
    #   relay: "smtp.sendgrid.net",
    #   username: System.get_env("SENDGRID_USERNAME"),
    #   password: System.get_env("SENDGRID_PASSWORD"),
    #   port: 587,
    #   auth: :always,
    #   tls: :always

    # OPTION 2 (LEGACY): Configure PhoenixKit's built-in mailer
    # Uncomment and configure the adapter you want to use:

    # SMTP configuration (recommended for most providers)
    # config :phoenix_kit, PhoenixKit.Mailer,
    #   adapter: Swoosh.Adapters.SMTP,
    #   relay: "smtp.sendgrid.net",
    #   username: System.get_env("SENDGRID_USERNAME"),
    #   password: System.get_env("SENDGRID_PASSWORD"),
    #   port: 587,
    #   auth: :always,
    #   tls: :always

    # SendGrid API configuration
    # config :phoenix_kit, PhoenixKit.Mailer,
    #   adapter: Swoosh.Adapters.Sendgrid,
    #   api_key: System.get_env("SENDGRID_API_KEY")

    # Mailgun configuration
    # config :phoenix_kit, PhoenixKit.Mailer,
    #   adapter: Swoosh.Adapters.Mailgun,
    #   api_key: System.get_env("MAILGUN_API_KEY"),
    #   domain: System.get_env("MAILGUN_DOMAIN")

    # ==========================================
    # Amazon SES configuration (COMPLETE SETUP GUIDE)
    # ==========================================

    # STEP 1: Add required dependencies to mix.exs
    # {:gen_smtp, "~> 1.2"}  # Required for AWS SES
    # {:finch, "~> 0.18"}    # Required for HTTP client
    #
    # Also add :finch to extra_applications in mix.exs:
    # extra_applications: [:logger, :runtime_tools, :finch]

    # STEP 2: Add Finch to your application supervisor (lib/your_app/application.ex)
    # Add this to your children list:
    # {Finch, name: Swoosh.Finch}

    # STEP 3: Configure Swoosh API client (config/config.exs)
    # config :swoosh, :api_client, Swoosh.ApiClient.Finch
    #
    # ⚠️ IMPORTANT: Check that config/dev.exs does NOT have:
    # config :swoosh, :api_client, false
    # This setting will override Finch configuration and break AWS SES!

    # STEP 4: Configure AWS SES
    # For your app's mailer (recommended approach):
    # config :your_app, YourApp.Mailer,
    #   adapter: Swoosh.Adapters.AmazonSES,
    #   region: "eu-north-1",  # or "us-east-1", "us-west-2", etc.
    #   access_key: System.get_env("AWS_ACCESS_KEY_ID"),
    #   secret: System.get_env("AWS_SECRET_ACCESS_KEY")
    #
    # Then configure PhoenixKit to use your mailer:
    # config :phoenix_kit,
    #   mailer: YourApp.Mailer,
    #   from_email: "noreply@yourcompany.com",
    #   from_name: "Your Company"
    #
    # Legacy approach (using PhoenixKit's built-in mailer):
    # config :phoenix_kit, PhoenixKit.Mailer,
    #   adapter: Swoosh.Adapters.AmazonSES,
    #   region: "eu-north-1",
    #   access_key: System.get_env("AWS_ACCESS_KEY_ID"),
    #   secret: System.get_env("AWS_SECRET_ACCESS_KEY")

    # STEP 5: AWS SES Setup Checklist
    # □ Create AWS IAM user with SES permissions (ses:*)
    # □ Verify sender email address in AWS SES Console
    # □ Verify recipient email addresses (if in sandbox mode)
    # □ Ensure correct AWS region matches your verification
    # □ Request production access to send to any email
    # □ Set environment variables:
    #   - AWS_ACCESS_KEY_ID
    #   - AWS_SECRET_ACCESS_KEY
    #   - AWS_REGION (optional, defaults to eu-north-1)

    # Common AWS SES regions:
    # - eu-west-1 (Ireland)
    # - us-east-1 (N. Virginia)
    # - us-west-2 (Oregon)
    # - eu-north-1 (Stockholm)


    # TROUBLESHOOTING:
    # If you see "function false.post/4 is undefined":
    # 1. Check that Finch is in your mix.exs deps: {:finch, "~> 0.18"}
    # 2. Check that :finch is in extra_applications
    # 3. Check that Swoosh.Finch is in application.ex children
    # 4. Make sure there's no "api_client: false" in dev.exs
    # 5. Restart your Phoenix server after changes
    #
    # See full setup guide: docs/AWS_SES_SETUP.md

    """
  end

  # Add brief notice about mailer configuration
  defp add_mailer_production_notice(igniter) do
    parent_app_name = IgniterHelpers.get_parent_app_name(igniter)

    notice =
      case detect_parent_mailer(parent_app_name) do
        {:ok, parent_mailer} ->
          "📧 Email configured to use #{inspect(parent_mailer)} (see config/prod.exs for production setup)"

        :not_found ->
          "📧 Email configured (built-in PhoenixKit.Mailer, see config/prod.exs)"
      end

    Igniter.add_notice(igniter, notice)
  end

  # Add notice when runtime configuration cannot be automatically applied
  defp add_runtime_config_notice(igniter) do
    notice = """
    ⚠️  Manual Configuration Required

    PhoenixKit couldn't automatically configure the mailer due to complex config patterns.

    Please add the following configuration manually:

    Option 1: Add to config/runtime.exs (in the dev block, before any import_config):

      if config_env() == :dev do
        config :phoenix_kit, PhoenixKit.Mailer,
          adapter: Swoosh.Adapters.Local
      end

    Option 2: Add to config/dev.exs:

      config :phoenix_kit, PhoenixKit.Mailer,
        adapter: Swoosh.Adapters.Local

    After adding the configuration, run: mix deps.get
    """

    Igniter.add_notice(igniter, notice)
  end
end
