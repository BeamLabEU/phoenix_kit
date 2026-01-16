defmodule PhoenixKit.Install.JsIntegration do
  @moduledoc """
  Handles automatic JavaScript integration for PhoenixKit installation.

  This module provides functionality to:
  - Add PhoenixKit JS import for hooks and interactive features
  - Update liveSocket hooks configuration automatically
  - Ensure idempotent operations (safe to run multiple times)
  - Provide fallback instructions if automatic integration fails

  ## Import Strategy

  PhoenixKit JavaScript is imported directly from the deps directory, similar to CSS.
  This means updates to PhoenixKit automatically include updated JavaScript without
  needing to run `phoenix_kit.update`.

  The import path is relative to your app.js location:
  - `assets/js/app.js` → `import "../../deps/phoenix_kit/priv/static/assets/phoenix_kit.js"`
  - `priv/static/assets/app.js` → `import "../../../deps/phoenix_kit/priv/static/assets/phoenix_kit.js"`
  """
  use PhoenixKit.Install.IgniterCompat

  @phoenix_kit_js_marker "// PhoenixKit JS - DO NOT REMOVE"

  # Import paths based on app.js location
  @import_path_from_assets_js "../../deps/phoenix_kit/priv/static/assets/phoenix_kit.js"
  @import_path_from_priv_assets "../../../deps/phoenix_kit/priv/static/assets/phoenix_kit.js"

  @doc """
  Automatically integrates PhoenixKit JavaScript with the parent app's app.js.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with JS integration applied automatically.
  """
  def add_automatic_js_integration(igniter) do
    js_paths = [
      "assets/js/app.js",
      "priv/static/assets/app.js"
    ]

    IO.puts("\n🔍 Looking for app.js in: #{inspect(js_paths)}")

    case find_app_js(js_paths) do
      {:ok, js_path} ->
        IO.puts("✅ Found app.js at: #{js_path}")
        integrate_js_automatically(igniter, js_path)

      {:error, :not_found} ->
        IO.puts("❌ app.js not found in any expected location")
        add_manual_integration_instructions(igniter)
    end
  end

  @doc """
  Checks what PhoenixKit JS integration already exists in content.
  Returns a map with detected integrations.
  """
  def check_existing_integration(content) do
    %{
      phoenix_kit_marker: String.contains?(content, @phoenix_kit_js_marker),
      phoenix_kit_import: has_phoenix_kit_import?(content),
      phoenix_kit_hooks: String.contains?(content, "PhoenixKitHooks")
    }
  end

  # Find the main app.js file in common locations
  defp find_app_js(paths) do
    case Enum.find(paths, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  # Determine the correct import path based on app.js location
  defp get_import_path(js_path) do
    if String.starts_with?(js_path, "priv/") do
      @import_path_from_priv_assets
    else
      @import_path_from_assets_js
    end
  end

  # Build the full import statement
  defp build_import_statement(js_path) do
    import_path = get_import_path(js_path)
    ~s|import "#{import_path}"|
  end

  # Automatically integrate JS with PhoenixKit requirements
  defp integrate_js_automatically(igniter, js_path) do
    import_statement = build_import_statement(js_path)

    igniter
    |> Igniter.update_file(js_path, &add_smart_js_integration(&1, import_statement))
    |> add_integration_success_notice(js_path)
  rescue
    e ->
      IO.warn("Failed to automatically integrate JS: #{inspect(e)}")
      add_manual_integration_instructions(igniter)
  end

  # Smart integration that handles all cases within Igniter context
  def add_smart_js_integration(source, import_statement \\ nil) do
    content = source.content

    # First, fix any old vendor-based import paths to use deps
    content = fix_old_import_paths(content)
    existing = check_existing_integration(content)

    if existing.phoenix_kit_marker or existing.phoenix_kit_import do
      # Already integrated (with correct path), no changes needed
      Rewrite.Source.update(source, :content, content)
    else
      # Add PhoenixKit JS integration
      # Use provided import statement or default to assets/js path
      import_stmt = import_statement || ~s|import "#{@import_path_from_assets_js}"|
      updated = add_phoenix_kit_js(content, import_stmt)
      Rewrite.Source.update(source, :content, updated)
    end
  end

  # Fix old vendor-based import paths to use deps directory
  defp fix_old_import_paths(content) do
    # Pattern matches old vendor-based imports like:
    # import "./vendor/phoenix_kit"
    # import "./vendor/phoenix_kit.js"
    old_vendor_pattern = ~r/import\s+["'][^"']*vendor\/phoenix_kit[^"']*["']/

    # Pattern matches old deps-based imports with wrong paths
    old_deps_pattern =
      ~r/import\s+["'][^"']*deps\/phoenix_kit\/priv\/static\/assets\/phoenix_kit[^"']*["']/

    content
    |> maybe_replace_pattern(old_vendor_pattern, ~s|import "#{@import_path_from_assets_js}"|)
    |> maybe_replace_pattern(old_deps_pattern, ~s|import "#{@import_path_from_assets_js}"|)
  end

  defp maybe_replace_pattern(content, pattern, replacement) do
    if String.match?(content, pattern) do
      String.replace(content, pattern, replacement)
    else
      content
    end
  end

  # Add PhoenixKit JS import and update hooks
  defp add_phoenix_kit_js(content, import_statement) do
    lines = String.split(content, "\n")

    # Find last import line to insert after
    last_import_idx = find_last_import_index(lines)

    {before, after_lines} = Enum.split(lines, last_import_idx + 1)

    import_lines = [
      "",
      @phoenix_kit_js_marker,
      import_statement
    ]

    new_lines = before ++ import_lines ++ after_lines
    content_with_import = Enum.join(new_lines, "\n")

    # Update hooks in liveSocket if possible
    update_livesocket_hooks(content_with_import)
  end

  # Find the index of the last import statement
  defp find_last_import_index(lines) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _} -> String.match?(line, ~r/^import\s/) end)
    |> List.last()
    |> case do
      {_, idx} -> idx
      nil -> 0
    end
  end

  # Try to add PhoenixKitHooks spread to existing hooks configuration
  defp update_livesocket_hooks(content) do
    cond do
      # Already has PhoenixKitHooks - no changes needed
      String.contains?(content, "PhoenixKitHooks") ->
        content

      # Pattern: hooks: Hooks (simple variable reference)
      String.match?(content, ~r/hooks:\s*Hooks[,\s\n}]/) ->
        String.replace(
          content,
          ~r/hooks:\s*Hooks([,\s\n}])/,
          "hooks: { ...window.PhoenixKitHooks, ...Hooks }\\1"
        )

      # Pattern: hooks: {} or hooks: { ... } (object literal)
      String.match?(content, ~r/hooks:\s*\{/) ->
        String.replace(
          content,
          ~r/hooks:\s*\{/,
          "hooks: { ...window.PhoenixKitHooks, "
        )

      # No hooks configuration found - add notice for manual update
      true ->
        content
    end
  end

  # Check if PhoenixKit import already exists
  defp has_phoenix_kit_import?(content) do
    phoenix_kit_patterns = [
      ~r/import\s+["'][^"']*phoenix_kit[^"']*["']/,
      ~r/import\s+["'][^"']*vendor\/phoenix_kit["']/,
      ~r/import\s+["'][^"']*deps\/phoenix_kit[^"']*phoenix_kit\.js["']/
    ]

    Enum.any?(phoenix_kit_patterns, &String.match?(content, &1))
  end

  # Success notice
  defp add_integration_success_notice(igniter, js_path) do
    import_path = get_import_path(js_path)

    notice = """

    ✅ PhoenixKit JS Integration Complete!

    • Updated #{js_path} with PhoenixKit import
    • Import path: #{import_path}
    • Drag-and-drop and other interactive features are now enabled!

    📦 JavaScript updates automatically with package updates (no phoenix_kit.update needed)
    """

    Igniter.add_notice(igniter, notice)
  end

  # Fallback instructions if automatic integration fails
  defp add_manual_integration_instructions(igniter) do
    notice = """

    ⚠️ Could not automatically locate app.js file.

    Please manually add the following to your app.js (after other imports):

    #{@phoenix_kit_js_marker}
    import "#{@import_path_from_assets_js}"

    Then update your liveSocket hooks:
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { ...window.PhoenixKitHooks, ...Hooks },
      // ... other options
    })

    Common locations: assets/js/app.js, priv/static/assets/app.js

    Note: If your app.js is at priv/static/assets/app.js, use:
    import "#{@import_path_from_priv_assets}"
    """

    Igniter.add_warning(igniter, notice)
  end
end
