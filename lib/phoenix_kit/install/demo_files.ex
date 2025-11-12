defmodule PhoenixKit.Install.DemoFiles do
  @moduledoc """
  Handles copying demo test files for PhoenixKit installation.

  This module provides functionality to:
  - Copy test demo files to parent project
  - Transform module names to match parent app
  - Generate appropriate demo file notices
  """
  use PhoenixKit.Install.IgniterCompat

  alias Igniter.Project.Application
  alias Mix.Tasks.PhoenixKitTemplates

  alias PhoenixKit.Install.IgniterHelpers

  @doc """
  Copies test demo files to the parent project.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with demo files copied and notices added.
  """
  def copy_test_demo_files(igniter) do
    case Application.app_name(igniter) do
      nil ->
        Igniter.add_warning(igniter, "Could not determine app name for copying test demo files")

      :phoenix_kit ->
        # This is the PhoenixKit library itself, skip copying test files
        igniter

      app_name ->
        app_web_module = IgniterHelpers.get_parent_app_module_web(igniter)

        # Create demo directory path - directly in app_web as phoenix_kit_live
        app_web_dir = Macro.underscore(to_string(app_name)) <> "_web"
        demo_dir = Path.join([app_web_dir, "phoenix_kit_live"])

        igniter
        |> copy_test_file("test_ensure_auth_live.ex", demo_dir, app_web_module)
        |> copy_test_file("test_redirect_if_auth_live.ex", demo_dir, app_web_module)
        |> copy_test_file("test_require_auth_live.ex", demo_dir, app_web_module)
        |> add_test_demo_notice()
    end
  end

  # Copy a single test file to demo directory using embedded content
  defp copy_test_file(igniter, filename, demo_dir, app_web_module) do
    # Create files in live/ directory with proper notifications
    content = get_embedded_test_file_content(filename)

    if content do
      # First update use statement to avoid conflicts
      app_web_module_string = inspect(app_web_module)

      updated_content =
        String.replace(
          content,
          "use PhoenixKitWeb, :live_view",
          "use #{app_web_module_string}, :live_view"
        )

      # Then replace module names (but not the use statement)
      updated_content =
        String.replace(
          updated_content,
          "defmodule PhoenixKitWeb",
          "defmodule #{app_web_module_string}.PhoenixKitLive"
        )

      # Create file only if it doesn't exist (skip if already exists)
      dest_path = Path.join(["lib", demo_dir, filename])

      if File.exists?(dest_path) do
        # File exists, add notice and skip creation
        Igniter.add_notice(igniter, "Demo file already exists, skipping: #{dest_path}")
      else
        # File doesn't exist, create it
        Igniter.create_new_file(igniter, dest_path, updated_content)
      end
    else
      Igniter.add_warning(igniter, "Unknown test file: #{filename}")
    end
  end

  # Get embedded content for test files
  defp get_embedded_test_file_content("test_ensure_auth_live.ex") do
    PhoenixKitTemplates.get_test_ensure_auth_live()
  end

  defp get_embedded_test_file_content("test_redirect_if_auth_live.ex") do
    PhoenixKitTemplates.get_test_redirect_if_auth_live()
  end

  defp get_embedded_test_file_content("test_require_auth_live.ex") do
    PhoenixKitTemplates.get_test_require_auth_live()
  end

  defp get_embedded_test_file_content(_), do: nil

  # Add notice about demo files
  defp add_test_demo_notice(igniter) do
    notice = "📝 Demo pages: /test-current-user, /test-redirect-if-auth, /test-ensure-auth"

    Igniter.add_notice(igniter, notice)
  end
end
