defmodule PhoenixKit.Install.JsIntegration do
  @moduledoc """
  Handles automatic JavaScript integration for PhoenixKit installation.

  This module provides functionality to:
  - Copy PhoenixKit JS files to the parent app's assets/vendor directory
  - Add PhoenixKit JS import for hooks and interactive features
  - Update liveSocket hooks configuration automatically
  - Ensure idempotent operations (safe to run multiple times)
  - Provide fallback instructions if automatic integration fails
  """
  use PhoenixKit.Install.IgniterCompat

  # Mix functions only available at compile-time during installation
  @dialyzer {:nowarn_function, fallback_phoenix_kit_assets_dir: 0}

  @phoenix_kit_js_marker "// PhoenixKit JS - DO NOT REMOVE"
  @phoenix_kit_import ~s|import "./vendor/phoenix_kit"|

  # Source files in PhoenixKit package
  @source_files [
    "phoenix_kit.js",
    "phoenix_kit_sortable.js"
  ]

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

        igniter
        |> copy_vendor_files(js_path)
        |> integrate_js_automatically(js_path)

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

  # Copy PhoenixKit JS files to parent app's vendor directory
  # Uses direct File.write! instead of Igniter to ensure files exist before asset rebuild
  defp copy_vendor_files(igniter, js_path) do
    # Determine vendor directory based on app.js location
    vendor_dir =
      js_path
      |> Path.dirname()
      |> Path.join("vendor")

    IO.puts("  📂 Creating vendor directory: #{vendor_dir}")

    # Create vendor directory if it doesn't exist
    File.mkdir_p!(vendor_dir)

    # Get source directory from PhoenixKit package
    source_dir = get_phoenix_kit_assets_dir()
    IO.puts("  📂 Source directory: #{source_dir}")

    # Copy each source file directly (not through Igniter, so they exist immediately)
    Enum.each(@source_files, fn file ->
      source_path = Path.join(source_dir, file)
      dest_path = Path.join(vendor_dir, file)

      IO.puts("  📄 Checking source: #{source_path}")

      if File.exists?(source_path) do
        content = File.read!(source_path)

        # Only write if different or doesn't exist
        should_write = !File.exists?(dest_path) or File.read!(dest_path) != content

        if should_write do
          File.write!(dest_path, content)
          IO.puts("  ✅ Copied #{file} to #{vendor_dir}/")
        else
          IO.puts("  ⏭️  #{file} already up to date")
        end
      else
        IO.puts("  ❌ Source file not found: #{source_path}")
      end
    end)

    igniter
  end

  # Get the path to PhoenixKit's static assets directory
  defp get_phoenix_kit_assets_dir do
    # Use :code.priv_dir to get the actual priv directory of the phoenix_kit application
    # This works for both Hex packages and local path dependencies
    case :code.priv_dir(:phoenix_kit) do
      {:error, reason} ->
        # Fallback: try common locations
        IO.puts("  ℹ️  :code.priv_dir(:phoenix_kit) returned error: #{inspect(reason)}")
        fallback_phoenix_kit_assets_dir()

      priv_dir ->
        assets_path = Path.join([to_string(priv_dir), "static", "assets"])
        IO.puts("  ℹ️  Checking priv_dir assets at: #{assets_path}")

        if File.dir?(assets_path) do
          IO.puts("  ✅ Found assets directory via :code.priv_dir")
          assets_path
        else
          IO.puts("  ⚠️  Assets directory not found at priv_dir, trying fallback")
          fallback_phoenix_kit_assets_dir()
        end
    end
  end

  defp fallback_phoenix_kit_assets_dir do
    IO.puts("  ℹ️  Trying fallback paths for assets directory...")

    possible_paths = [
      # Standard deps location
      "deps/phoenix_kit/priv/static/assets",
      Path.join([Mix.Project.deps_path(), "phoenix_kit", "priv", "static", "assets"])
    ]

    IO.puts("  ℹ️  Fallback paths to check:")
    Enum.each(possible_paths, fn path ->
      exists = File.dir?(path)
      IO.puts("      #{if exists, do: "✅", else: "❌"} #{path}")
    end)

    found = Enum.find(possible_paths, &File.dir?/1)

    if found do
      IO.puts("  ✅ Found assets directory at: #{found}")
      found
    else
      IO.puts("  ❌ Could not find PhoenixKit assets directory in any location!")
      List.first(possible_paths)
    end
  end

  # Automatically integrate JS with PhoenixKit requirements
  defp integrate_js_automatically(igniter, js_path) do
    igniter
    |> Igniter.update_file(js_path, &add_smart_js_integration/1)
    |> add_integration_success_notice(js_path)
  rescue
    e ->
      IO.warn("Failed to automatically integrate JS: #{inspect(e)}")
      add_manual_integration_instructions(igniter)
  end

  # Smart integration that handles all cases within Igniter context
  def add_smart_js_integration(source) do
    content = source.content

    # First, fix any old deps-based import paths
    content = fix_old_import_paths(content)
    existing = check_existing_integration(content)

    if existing.phoenix_kit_marker or existing.phoenix_kit_import do
      # Already integrated (with correct path), no changes needed
      Rewrite.Source.update(source, :content, content)
    else
      # Add PhoenixKit JS integration
      updated = add_phoenix_kit_js(content)
      Rewrite.Source.update(source, :content, updated)
    end
  end

  # Fix old deps-based import paths to use vendor directory
  defp fix_old_import_paths(content) do
    # Pattern matches old deps-based imports like:
    # import "../../../deps/phoenix_kit/priv/static/assets/phoenix_kit.js"
    # import "../../deps/phoenix_kit/priv/static/assets/phoenix_kit.js"
    old_import_pattern =
      ~r/import\s+["'][^"']*deps\/phoenix_kit\/priv\/static\/assets\/phoenix_kit[^"']*["']/

    if String.match?(content, old_import_pattern) do
      String.replace(content, old_import_pattern, @phoenix_kit_import)
    else
      content
    end
  end

  # Add PhoenixKit JS import and update hooks
  defp add_phoenix_kit_js(content) do
    lines = String.split(content, "\n")

    # Find last import line to insert after
    last_import_idx = find_last_import_index(lines)

    {before, after_lines} = Enum.split(lines, last_import_idx + 1)

    import_lines = [
      "",
      @phoenix_kit_js_marker,
      @phoenix_kit_import
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
      ~r/import\s+["'][^"']*vendor\/phoenix_kit["']/
    ]

    Enum.any?(phoenix_kit_patterns, &String.match?(content, &1))
  end

  # Success notice
  defp add_integration_success_notice(igniter, js_path) do
    vendor_dir = js_path |> Path.dirname() |> Path.join("vendor")

    notice = """

    ✅ PhoenixKit JS Integration Complete!

    • Copied JS files to #{vendor_dir}/
    • Updated #{js_path} with PhoenixKit hooks
    • Drag-and-drop and other interactive features are now enabled!
    """

    Igniter.add_notice(igniter, notice)
  end

  # Fallback instructions if automatic integration fails
  defp add_manual_integration_instructions(igniter) do
    notice = """

    ⚠️ Could not automatically locate app.js file.

    Please manually:

    1. Copy PhoenixKit JS files to your assets/js/vendor/ directory:
       - phoenix_kit.js
       - phoenix_kit_sortable.js

    2. Add import to your app.js (after other imports):
       #{@phoenix_kit_js_marker}
       #{@phoenix_kit_import}

    3. Update liveSocket hooks:
       let liveSocket = new LiveSocket("/live", Socket, {
         hooks: { ...window.PhoenixKitHooks, ...Hooks },
         // ... other options
       })

    Common locations: assets/js/app.js, priv/static/assets/app.js
    """

    Igniter.add_warning(igniter, notice)
  end
end
