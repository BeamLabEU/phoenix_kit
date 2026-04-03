defmodule PhoenixKit.Install.JsIntegration do
  @moduledoc """
  Handles automatic JavaScript hooks integration for PhoenixKit installation.

  This module:
  - Copies `phoenix_kit.js` to the parent app's `priv/static/assets/vendor/`
  - Adds a `<script>` tag to the root layout so hooks are loaded before LiveSocket

  The JS file defines `window.PhoenixKitHooks` which is spread into LiveSocket's
  hooks object in app.js: `hooks: { ...window.PhoenixKitHooks, ...colocatedHooks }`
  """

  require Logger

  @source_filename "phoenix_kit.js"
  @script_marker "<!-- PhoenixKit JS Hooks -->"

  @doc """
  Copies phoenix_kit.js to the parent app's static vendor directory and
  adds a script tag to the root layout.

  Safe to run multiple times (idempotent).
  """
  def add_js_integration(igniter) do
    igniter
    |> copy_js_file()
    |> add_script_tag_to_layout()
  end

  @doc """
  Updates the JS file in the parent app's static vendor directory.
  Called during `mix phoenix_kit.update` to keep hooks in sync.
  """
  def update_js_file do
    case resolve_source_path() do
      {:ok, source} ->
        dest = dest_path()
        File.mkdir_p(Path.dirname(dest))

        case File.cp(source, dest) do
          :ok ->
            Logger.info("Updated #{@source_filename} in priv/static/assets/vendor/")
            :ok

          {:error, reason} ->
            Logger.warning("Failed to update #{@source_filename}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("Could not find #{@source_filename} in PhoenixKit priv/static/assets/")
        {:error, :not_found}
    end
  rescue
    error ->
      Logger.warning("Unexpected error updating #{@source_filename}: #{inspect(error)}")
      {:error, :unexpected}
  end

  # ── Private ──────────────────────────────────────────────────────

  defp copy_js_file(igniter) do
    case resolve_source_path() do
      {:ok, source} ->
        dest = dest_path()
        File.mkdir_p(Path.dirname(dest))

        case File.cp(source, dest) do
          :ok ->
            Igniter.add_notice(
              igniter,
              "✅ Copied #{@source_filename} to priv/static/assets/vendor/"
            )

          {:error, reason} ->
            Igniter.add_warning(
              igniter,
              "⚠️  Failed to copy #{@source_filename}: #{inspect(reason)}. " <>
                "Please copy it manually from deps/phoenix_kit/priv/static/assets/#{@source_filename}"
            )
        end

      {:error, :not_found} ->
        Igniter.add_warning(
          igniter,
          "⚠️  Could not find #{@source_filename}. " <>
            "Please copy it manually from the phoenix_kit package."
        )
    end
  end

  defp add_script_tag_to_layout(igniter) do
    layout_paths = [
      "lib/#{Mix.Phoenix.otp_app()}_web/components/layouts/root.html.heex",
      "lib/#{Mix.Phoenix.otp_app()}_web/templates/layout/root.html.heex"
    ]

    case find_existing_file(layout_paths) do
      {:ok, layout_path} ->
        content = File.read!(layout_path)

        cond do
          String.contains?(content, @script_marker) ->
            # Already integrated
            igniter

          String.contains?(content, "phoenix_kit.js") ->
            # Already has a script tag (manually added)
            igniter

          true ->
            inject_script_tag(igniter, layout_path, content)
        end

      {:error, :not_found} ->
        Igniter.add_notice(
          igniter,
          """
          ⚠️  Could not find root layout. Please add this before your app.js script tag:

              #{@script_marker}
              <script src="/assets/vendor/#{@source_filename}"></script>
          """
        )
    end
  end

  defp inject_script_tag(igniter, layout_path, content) do
    script_tag = """
        #{@script_marker}
        <script src={~p"/assets/vendor/#{@source_filename}"}></script>\
    """

    # Insert before the app.js script tag
    updated =
      String.replace(
        content,
        ~r{(\s*<script[^>]*src=[^>]*app\.js[^>]*>)},
        "\n#{script_tag}\n\\1",
        global: false
      )

    if updated != content do
      File.write!(layout_path, updated)

      Igniter.add_notice(
        igniter,
        "✅ Added PhoenixKit JS hooks script tag to #{layout_path}"
      )
    else
      Igniter.add_warning(
        igniter,
        """
        ⚠️  Could not automatically add script tag to #{layout_path}.
        Please add this before your app.js script tag:

            #{@script_marker}
            <script src={~p"/assets/vendor/#{@source_filename}"}></script>
        """
      )
    end
  end

  defp resolve_source_path do
    # Try multiple possible locations
    candidates = [
      # Path dependency (development)
      Path.join([File.cwd!(), "..", "phoenix_kit", "priv", "static", "assets", @source_filename]),
      # Hex dependency
      Path.join([:code.priv_dir(:phoenix_kit), "static", "assets", @source_filename])
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp dest_path do
    Path.join([File.cwd!(), "priv", "static", "assets", "vendor", @source_filename])
  end

  defp find_existing_file(paths) do
    case Enum.find(paths, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end
end
