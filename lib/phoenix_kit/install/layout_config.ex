defmodule PhoenixKit.Install.LayoutConfig do
  @moduledoc """
  Handles layout integration configuration for PhoenixKit installation.

  This module provides functionality to:
  - Detect app layouts using Phoenix conventions
  - Add layout configuration to config files
  - Handle recompilation requirements
  - Generate appropriate notices for layout setup
  """
  use PhoenixKit.Install.IgniterCompat

  alias Igniter.Project.Config

  alias PhoenixKit.Install.IgniterHelpers
  alias PhoenixKit.Utils.PhoenixVersion

  @doc """
  Adds layout integration configuration to the Phoenix application.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with layout configuration and notices.
  """
  def add_layout_integration_configuration(igniter) do
    case detect_app_layouts(igniter) do
      {igniter, nil} ->
        # No layouts detected, use PhoenixKit defaults
        add_layout_integration_notice(igniter, :no_layouts_detected)

      {igniter, {layouts_module, _}} ->
        # Add layout configuration to config.exs
        igniter
        |> add_layout_config(layouts_module)
        |> add_layout_integration_notice(:layouts_detected)
    end
  end

  # Detect app layouts using IgniterPhoenix
  defp detect_app_layouts(igniter) do
    layouts_module = IgniterHelpers.get_parent_app_module_web_layouts(igniter)

    if layouts_module != nil do
      {igniter, {layouts_module, :app}}
    else
      {igniter, nil}
    end
  end

  # Add layout configuration to config.exs with Phoenix version support
  defp add_layout_config(igniter, layouts_module) do
    # Add modern layout configuration based on Phoenix version
    igniter
    |> add_modern_layout_config_with_comments(layouts_module)
    |> recompile_phoenix_kit_dependency()
  end

  # Add modern layout configuration with Phoenix version detection and comments
  defp add_modern_layout_config_with_comments(igniter, layouts_module) do
    case PhoenixVersion.get_strategy() do
      :modern ->
        # Phoenix v1.8+ - Use function component configuration
        add_modern_layout_config(igniter, layouts_module)

      :legacy ->
        # Phoenix v1.7- - Use legacy layout configuration
        add_legacy_layout_config(igniter, layouts_module)
    end
    |> add_version_aware_comments(layouts_module)
  end

  # Skip redundant layout notice since already covered
  defp add_layout_integration_notice(igniter, :layouts_detected) do
    igniter
  end

  defp add_layout_integration_notice(igniter, :no_layouts_detected) do
    notice = "💡 To integrate with your app's design, see layout configuration in README.md"
    Igniter.add_notice(igniter, notice)
  end

  # Recompile PhoenixKit dependency to pick up layout configuration changes
  defp recompile_phoenix_kit_dependency(igniter) do
    # Since this is running during installation, we need to recompile the dependency
    # to ensure the layout configuration changes are picked up immediately
    recompile_notice = """

    🔄 Recompiling PhoenixKit to apply layout configuration...
    """

    igniter = Igniter.add_notice(igniter, recompile_notice)

    # Run the recompilation in the background using System.cmd instead of Mix task
    # to avoid potential issues with Mix state during Igniter execution
    try do
      {output, exit_code} =
        System.cmd("mix", ["deps.compile", "phoenix_kit", "--force"], stderr_to_stdout: true)

      if exit_code == 0 do
        success_notice = "✅ PhoenixKit dependency recompiled successfully!"
        Igniter.add_notice(igniter, success_notice)
      else
        warning_notice =
          "⚠️ Could not automatically recompile PhoenixKit dependency. Output: #{String.slice(output, 0, 200)}"

        Igniter.add_warning(igniter, warning_notice)
      end
    rescue
      _ ->
        warning_notice =
          "⚠️ Could not automatically recompile PhoenixKit dependency. Please run: mix deps.compile phoenix_kit --force"

        Igniter.add_warning(igniter, warning_notice)
    end
  end

  # Phoenix v1.8+ layout configuration - uses function components, no router-level config needed
  defp add_modern_layout_config(igniter, layouts_module) do
    igniter
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:layouts_module],
      layouts_module
    )
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:phoenix_version_strategy],
      :modern
    )
  rescue
    _ ->
      add_layout_config_simple(igniter, layouts_module, :modern)
  end

  # Phoenix v1.7- legacy layout configuration
  defp add_legacy_layout_config(igniter, layouts_module) do
    igniter
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:layout],
      {layouts_module, :app}
    )
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:root_layout],
      {layouts_module, :root}
    )
    |> Config.configure_new(
      "config.exs",
      :phoenix_kit,
      [:phoenix_version_strategy],
      :legacy
    )
  rescue
    _ ->
      add_layout_config_simple(igniter, layouts_module, :legacy)
  end

  # Simple file append for layout configuration when Igniter fails
  defp add_layout_config_simple(igniter, layouts_module, strategy) do
    layout_config =
      case strategy do
        :modern ->
          """

          # PhoenixKit layout configuration (Phoenix v1.8+)
          config :phoenix_kit,
            layouts_module: #{inspect(layouts_module)},
            phoenix_version_strategy: :modern
          """

        :legacy ->
          """

          # PhoenixKit layout configuration (Phoenix v1.7-)
          config :phoenix_kit,
            layout: {#{inspect(layouts_module)}, :app},
            root_layout: {#{inspect(layouts_module)}, :root},
            phoenix_version_strategy: :legacy
          """
      end

    try do
      igniter =
        Igniter.update_file(igniter, "config/config.exs", fn source ->
          content = Rewrite.Source.get(source, :content)

          # Check if already configured
          if String.contains?(content, "config :phoenix_kit") &&
               String.contains?(content, "layouts_module") do
            source
          else
            # Find insertion point before import_config
            updated_content =
              case find_import_config_location_simple(content) do
                {:before_import, before_content, after_content} ->
                  before_content <> layout_config <> "\n" <> after_content

                :append_to_end ->
                  content <> layout_config
              end

            Rewrite.Source.update(source, :content, updated_content)
          end
        end)

      igniter
    rescue
      e ->
        IO.warn("Failed to configure layout automatically: #{inspect(e)}")
        add_layout_config_manual_notice(igniter, layouts_module, strategy)
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

  # Manual configuration notice for layout
  defp add_layout_config_manual_notice(igniter, layouts_module, strategy) do
    config_example =
      case strategy do
        :modern ->
          """
            config :phoenix_kit,
              layouts_module: #{inspect(layouts_module)},
              phoenix_version_strategy: :modern
          """

        :legacy ->
          """
            config :phoenix_kit,
              layout: {#{inspect(layouts_module)}, :app},
              root_layout: {#{inspect(layouts_module)}, :root},
              phoenix_version_strategy: :legacy
          """
      end

    notice = """
    ⚠️  Manual Layout Configuration Required

    PhoenixKit couldn't automatically configure layouts.

    Please add this to config/config.exs:

    #{config_example}
    """

    Igniter.add_notice(igniter, notice)
  end

  # Add version-aware comments to configuration
  defp add_version_aware_comments(igniter, _layouts_module) do
    # Simple notice that layout integration is configured
    notice = "✅ Layout integration configured automatically"

    igniter
    |> Igniter.add_notice(notice)
  end
end
