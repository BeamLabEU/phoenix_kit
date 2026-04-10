defmodule PhoenixKit.Install.CssIntegration do
  @moduledoc """
  Handles automatic Tailwind CSS + DaisyUI integration for PhoenixKit installation.

  This module provides functionality to:
  - Automatically detect app.css file in Phoenix applications
  - Add PhoenixKit-specific @source and @plugin directives
  - Ensure idempotent operations (safe to run multiple times)
  - Provide fallback instructions if automatic integration fails
  """

  require Logger
  use PhoenixKit.Install.IgniterCompat

  @phoenix_kit_css_marker "/* PhoenixKit Integration - DO NOT REMOVE */"

  @phoenix_kit_integration """
  #{@phoenix_kit_css_marker}
  @source "../../deps/phoenix_kit";
  @source "../../../phoenix_kit";
  @import "./_phoenix_kit_sources.css";
  """

  @doc """
  Automatically integrates PhoenixKit with the parent app's CSS configuration.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with CSS integration applied automatically.
  """
  def add_automatic_css_integration(igniter) do
    css_paths = [
      "assets/css/app.css",
      "priv/static/assets/app.css",
      "assets/app.css"
    ]

    case find_app_css(css_paths) do
      {:ok, css_path} ->
        integrate_css_automatically(igniter, css_path)

      {:error, :not_found} ->
        add_manual_integration_instructions(igniter)
    end
  end

  @doc """
  Checks what PhoenixKit integration already exists in CSS content.
  Returns a map with detected integrations.
  """
  def check_existing_integration(content) do
    %{
      phoenix_kit_marker: String.contains?(content, @phoenix_kit_css_marker),
      phoenix_kit_source: has_phoenix_kit_source?(content),
      daisyui_plugin: has_daisyui_plugin?(content),
      daisyui_themes_disabled: has_daisyui_themes_disabled?(content),
      tailwindcss_import: String.match?(content, ~r/@import\s+["']tailwindcss["']/)
    }
  end

  # Find the main app.css file in common locations
  defp find_app_css(paths) do
    case Enum.find(paths, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  # Automatically integrate CSS with PhoenixKit requirements
  defp integrate_css_automatically(igniter, css_path) do
    igniter
    |> Igniter.update_file(css_path, &add_smart_integration/1)
    |> add_css_sources_compiler()
    |> ensure_css_sources_file(css_path)
    |> add_integration_success_notice(css_path)
  rescue
    e ->
      IO.warn("Failed to automatically integrate CSS: #{inspect(e)}")
      add_manual_integration_instructions(igniter)
  end

  # Smart integration that handles all cases within Igniter context
  def add_smart_integration(source) do
    content = source.content
    existing = check_existing_integration(content)

    source =
      if existing.phoenix_kit_source do
        # PhoenixKit source exists, but check for missing plugin module sources
        add_missing_integration_parts(source, existing)
      else
        # No PhoenixKit integration exists, add it
        add_complete_integration(source, existing)
      end

    # Always check and update daisyUI themes configuration
    update_daisyui_themes_config(source)
  end

  # Update daisyUI plugin configuration to enable all themes
  defp update_daisyui_themes_config(source) do
    content = source.content

    # Pattern to match daisyUI plugin with themes: false
    pattern = ~r/@plugin\s+(["'][^"']*daisyui["'])\s*\{([^}]*themes:\s*)false([^}]*)\}/

    if String.match?(content, pattern) do
      updated_content =
        String.replace(content, pattern, fn match ->
          String.replace(match, ~r/(themes:\s*)false/, "\\1all")
        end)

      Rewrite.Source.update(source, :content, updated_content)
    else
      source
    end
  end

  # Add :phoenix_kit_css_sources compiler to the parent app's mix.exs.
  # This compiler auto-generates _phoenix_kit_sources.css on each compilation
  # with @source directives for external PhoenixKit modules.
  defp add_css_sources_compiler(igniter) do
    Igniter.Project.MixProject.update(igniter, :project, [:compilers], fn
      nil ->
        {:ok, {:code, [:phoenix_kit_css_sources]}}

      zipper ->
        case Igniter.Code.List.prepend_new_to_list(zipper, :phoenix_kit_css_sources) do
          {:ok, zipper} -> {:ok, zipper}
          :error -> {:warning, "Could not add :phoenix_kit_css_sources to compilers in mix.exs"}
        end
    end)
  rescue
    _ ->
      Igniter.add_warning(
        igniter,
        """
        ⚠️  Could not add :phoenix_kit_css_sources compiler to mix.exs.
        Please add it manually:

            def project do
              [
                ...,
                compilers: [:phoenix_kit_css_sources] ++ Mix.compilers()
              ]
            end
        """
      )
  end

  # Create an initial _phoenix_kit_sources.css so the @import doesn't fail
  # before the compiler has a chance to run.
  defp ensure_css_sources_file(igniter, css_path) do
    generated_path = Path.join(Path.dirname(css_path), "_phoenix_kit_sources.css")

    unless File.exists?(generated_path) do
      File.mkdir_p!(Path.dirname(generated_path))

      File.write!(generated_path, """
      /* Auto-generated by PhoenixKit — do not edit manually.
         Regenerated on each compilation from css_sources/0 callbacks. */
      """)
    end

    igniter
  end

  # Generic success notice - we'll determine what was actually done
  defp add_integration_success_notice(igniter, css_path) do
    notice = """

    ✅ PhoenixKit CSS Integration Complete!

    Updated #{css_path} with PhoenixKit integration.
    Your app will now automatically generate all PhoenixKit styles!
    """

    Igniter.add_notice(igniter, notice)
  end

  # Add missing parts to partial integration (source version)
  def add_missing_integration_parts(source, existing) do
    content = source.content
    missing_parts = []

    missing_parts =
      if existing.phoenix_kit_source do
        missing_parts
      else
        [
          @phoenix_kit_css_marker,
          "@source \"../../deps/phoenix_kit\";",
          "@source \"../../../phoenix_kit\";"
        ] ++
          missing_parts
      end

    # Add the auto-generated CSS import if missing
    missing_parts =
      if String.contains?(content, "_phoenix_kit_sources.css") do
        missing_parts
      else
        missing_parts ++ ["@import \"./_phoenix_kit_sources.css\";"]
      end

    missing_parts =
      if existing.daisyui_plugin do
        missing_parts
      else
        ["@plugin \"daisyui\";"] ++ missing_parts
      end

    if missing_parts != [] do
      updated_content = insert_missing_parts(content, missing_parts, existing)
      Rewrite.Source.update(source, :content, updated_content)
    else
      source
    end
  end

  # Add complete PhoenixKit integration (source version)
  defp add_complete_integration(source, _existing) do
    content = source.content

    updated_content =
      case String.split(content, "\n") do
        [_ | _] = lines ->
          insert_phoenix_kit_integration(lines)

        _ ->
          # Empty file, add basic integration
          """
          @import "tailwindcss";
          #{@phoenix_kit_integration}
          """ <> content
      end

    Rewrite.Source.update(source, :content, updated_content)
  end

  # Insert PhoenixKit integration at the appropriate location
  defp insert_phoenix_kit_integration(lines) do
    # Detect if this is Tailwind CSS 4 format (@import "tailwindcss" source())
    has_tailwind_v4 =
      Enum.any?(lines, &String.match?(&1, ~r/@import\s+["']tailwindcss["'].*source\(/))

    result_lines =
      if has_tailwind_v4 do
        # For Tailwind CSS 4, add PhoenixKit @source after existing @source lines
        insert_after_existing_sources(lines)
      else
        # For older Tailwind, add at the end
        lines ++ ["", @phoenix_kit_integration]
      end

    Enum.join(result_lines, "\n")
  end

  # Insert PhoenixKit @source after existing @source lines for Tailwind CSS 4
  defp insert_after_existing_sources(lines) do
    {pre_sources, post_sources} = find_source_insertion_point(lines)

    phoenix_kit_lines =
      [
        "@source \"../../deps/phoenix_kit\";",
        "@source \"../../../phoenix_kit\";",
        "@import \"./_phoenix_kit_sources.css\";"
      ]

    pre_sources ++ phoenix_kit_lines ++ post_sources
  end

  # Find the right place to insert PhoenixKit @source directive
  defp find_source_insertion_point(lines) do
    # Find the last @source line (not reversed - we want the actual last one)
    last_source_index =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn {line, _index} ->
        String.match?(line, ~r/^@source\s+/) &&
          !String.contains?(line, "phoenix_kit")
      end)

    case last_source_index do
      {_line, index} ->
        # Split after the last @source line
        pre_lines = Enum.take(lines, index + 1)
        post_lines = Enum.drop(lines, index + 1)
        {pre_lines, post_lines}

      nil ->
        # No @source lines found, look for @import line and add after it
        import_index =
          lines
          |> Enum.with_index()
          |> Enum.find(fn {line, _index} -> String.match?(line, ~r/^@import\s+/) end)

        case import_index do
          {_line, index} ->
            {Enum.take(lines, index + 1), Enum.drop(lines, index + 1)}

          nil ->
            # No @import either, add at the beginning
            {[], lines}
        end
    end
  end

  # Helper functions for detecting existing integrations
  defp has_phoenix_kit_source?(content) do
    phoenix_kit_patterns = [
      # Exact PhoenixKit deps patterns (quoted)
      ~r/@source\s+["']\.\.\/\.\.\/deps\/phoenix_kit["']/,
      ~r/@source\s+["']\.\/deps\/phoenix_kit["']/,
      ~r/@source\s+["']deps\/phoenix_kit["']/,
      # Exact PhoenixKit deps patterns (unquoted)
      ~r/@source\s+\.\.\/\.\.\/deps\/phoenix_kit[;\s]/,
      ~r/@source\s+\.\/deps\/phoenix_kit[;\s]/,
      ~r/@source\s+deps\/phoenix_kit[;\s]/
    ]

    Enum.any?(phoenix_kit_patterns, &String.match?(content, &1))
  end

  defp has_daisyui_plugin?(content) do
    daisyui_patterns = [
      # Quoted patterns
      ~r/@plugin\s+["']daisyui["']/,
      ~r/@plugin\s+["'][^"']*daisyui[^"']*["']/,
      # Unquoted patterns (with or without options)
      ~r/@plugin\s+[^{;]+daisyui[^{;]*[{;]/,
      ~r/@plugin\s+\.\.\/[^{;]*daisyui[^{;]*[{;]/
    ]

    Enum.any?(daisyui_patterns, &String.match?(content, &1))
  end

  defp has_daisyui_themes_disabled?(content) do
    String.match?(content, ~r/@plugin\s+["'][^"']*daisyui["']\s*\{[^}]*themes:\s*false/)
  end

  # Insert missing parts into existing CSS content
  defp insert_missing_parts(content, missing_parts, existing) do
    lines = String.split(content, "\n")
    insertion_point = find_insertion_point(lines, existing)
    {before_lines, after_lines} = Enum.split(lines, insertion_point)

    formatted_parts = format_missing_parts(missing_parts, insertion_point)
    new_lines = before_lines ++ formatted_parts ++ after_lines
    Enum.join(new_lines, "\n")
  end

  # Find appropriate location to insert missing parts (at the end)
  defp find_insertion_point(lines, existing) do
    if existing.phoenix_kit_source do
      # Find existing PhoenixKit source line to insert nearby
      find_line_after_pattern(lines, ~r/@source\s+["'][^"']*phoenix_kit[^"']*["']/)
    else
      # Insert at the end of the file
      length(lines)
    end
  end

  # Find line after a regex pattern
  defp find_line_after_pattern(lines, pattern) do
    case Enum.find_index(lines, &String.match?(&1, pattern)) do
      nil -> 0
      index -> index + 1
    end
  end

  # Add missing parts with proper spacing
  defp format_missing_parts(missing_parts, insertion_point) do
    if insertion_point > 0 and not Enum.empty?(missing_parts) do
      [""] ++ missing_parts
    else
      missing_parts
    end
  end

  # Fallback instructions if automatic integration fails
  defp add_manual_integration_instructions(igniter) do
    notice = """

    ⚠️ Could not automatically locate app.css file.

    Please manually add these lines to your CSS file:

    ```css
    @import "tailwindcss";
    @source "../../deps/phoenix_kit";
    @source "../../../phoenix_kit";
    @plugin "daisyui";
    ```

    If you use phoenix_kit_* plugin modules, also add @source lines for each.

    Common locations: assets/css/app.css, priv/static/assets/app.css
    """

    Igniter.add_warning(igniter, notice)
  end
end
