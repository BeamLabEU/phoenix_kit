defmodule PhoenixKit.Install.JsIntegration do
  @moduledoc """
  Handles automatic JavaScript hooks integration for PhoenixKit installation.

  This module:
  - Copies `phoenix_kit.js` to the parent app's `priv/static/assets/vendor/`
  - Adds a `<script>` tag to the root layout so hooks are loaded before LiveSocket

  The JS file defines `window.PhoenixKitHooks` which is spread into LiveSocket's
  hooks object in app.js: `hooks: { ...window.PhoenixKitHooks, ...colocatedHooks }`

  ## External module hooks

  External modules declare prebuilt hook bundles via `js_sources/0`. The
  `:phoenix_kit_js_sources` compiler concatenates those into
  `priv/static/assets/vendor/phoenix_kit_modules.js` on every compile and folds
  their hooks into `window.PhoenixKitHooks`. This module:

  - registers that compiler in the parent app's `mix.exs`,
  - adds a single (stable) `<script>` tag for the aggregate file after
    `phoenix_kit.js` and before `app.js`,
  - seeds an empty aggregate file so the tag doesn't 404 before the first compile.

  The tag never changes as modules come and go — only the file's content does — so
  module JS stays zero-config, exactly like `css_sources/0`.
  """

  require Logger

  alias Mix.Tasks.Compile.PhoenixKitJsSources

  # Igniter is optional (see mix.exs) and this module cannot be guarded away
  # like the `PhoenixKit.Install.*` helpers — `mix phoenix_kit.assets.rebuild`
  # calls `update_js_file/0`, which needs no igniter. The shim silences the
  # undefined-module warnings for the igniter-only functions on a build
  # without igniter.
  use PhoenixKit.Install.IgniterCompat

  @source_filename "phoenix_kit.js"
  @script_marker "<!-- PhoenixKit JS Hooks -->"

  @modules_filename "phoenix_kit_modules.js"
  @modules_script_marker "<!-- PhoenixKit Module Hooks -->"

  @bootstrap_marker "<%!-- PhoenixKit theme bootstrap: pre-paint theme stamp --%>"

  # A host that stamps the theme itself writes this in its root layout to tell
  # `mix phoenix_kit.update` so, and the notice below stops repeating.
  @host_managed_marker "<%!-- phoenix_kit: theme managed by host --%>"

  @doc """
  Copies phoenix_kit.js to the parent app's static vendor directory and
  adds a script tag to the root layout.

  Safe to run multiple times (idempotent).
  """
  def add_js_integration(igniter) do
    igniter
    |> copy_js_file()
    |> add_script_tag_to_layout()
    |> add_hooks_to_app_js()
    |> ensure_module_js_integration()
    |> ensure_theme_bootstrap()
  end

  @doc """
  Ensures the host root layout stamps the saved theme before first paint.

  Renders `PhoenixKitWeb.Components.ThemeBootstrap` at the top of `<head>`.
  Without it, admin pages served under the host's root layout paint in the
  default theme and swap after load — the one page class the kit's own
  layouts (which all render the bootstrap themselves) cannot cover.

  Skipped when the layout already renders the component. A stock
  `phx:theme` script (phx.new 1.8) is NOT a substitute: it treats
  `"system"` as "remove `data-theme`", which is how branded hosts flashed
  daisyUI's default over the configured pair. Those layouts still get
  the bootstrap, injected just before `</head>` so it runs *after* the
  stock script and the configured pair wins.

  Safe to run multiple times (idempotent). Called from both install and
  `mix phoenix_kit.update`, so existing hosts pick it up on upgrade.
  """
  def ensure_theme_bootstrap(igniter) do
    layout_paths = [
      "lib/#{Mix.Phoenix.otp_app()}_web/components/layouts/root.html.heex",
      "lib/#{Mix.Phoenix.otp_app()}_web/templates/layout/root.html.heex"
    ]

    case find_existing_file(layout_paths) do
      {:ok, layout_path} ->
        content = File.read!(layout_path)

        case theme_bootstrap_plan(content) do
          :already_present -> igniter
          :host_managed -> host_managed_notice(igniter, layout_path, content)
          _ -> inject_theme_bootstrap(igniter, layout_path, content)
        end

      {:error, :not_found} ->
        Igniter.add_notice(
          igniter,
          """
          ⚠️  Could not find root layout. To avoid a theme flash on first paint,
          render this at the top of <head>:

              #{@bootstrap_marker}
              <PhoenixKitWeb.Components.ThemeBootstrap.theme_bootstrap />
          """
        )
    end
  end

  # Where the bootstrap should land. Public so the placement rules can be
  # asserted without writing a host layout to disk.
  #
  #   * `:already_present` — the kit's marker or the component is there. The
  #     bare word "ThemeBootstrap" anywhere (a comment included) also counts:
  #     hosts have used exactly that as a way to opt out, and breaking it would
  #     re-inject into layouts that deliberately declined.
  #   * `:host_managed` — the host sets or clears `data-theme` with its own
  #     script, or has said so with `@host_managed_marker`. Injecting there puts the kit's script after
  #     the host's, the kit's stamp wins, and the host's own `[data-theme=…]`
  #     rules stop applying. So nothing is written; the caller explains why.
  #   * `:before_head_close` — the stock phx.new 1.8 script, which CLEARS
  #     `data-theme` for "system". The bootstrap must run after it, or the
  #     configured pair is stamped and then removed.
  #   * `:top_of_head` — nothing touches the theme.
  #
  # Telling the stock script from a host's own: the stock one removes the
  # attribute (its "system" branch) and reads `phx:theme`; anything else that
  # touches the attribute is the host's.
  @doc false
  def theme_bootstrap_plan(content) when is_binary(content) do
    cond do
      String.contains?(content, @bootstrap_marker) -> :already_present
      String.contains?(content, "ThemeBootstrap") -> :already_present
      String.contains?(content, @host_managed_marker) -> :host_managed
      stock_theme_script?(content) -> :before_head_close
      clears_theme?(content) or stamps_theme?(content) -> :host_managed
      # Reads the key but neither stamps nor clears: placement after it is
      # the safe choice, as before.
      String.contains?(content, "phx:theme") -> :before_head_close
      true -> :top_of_head
    end
  end

  # The stock script is recognised by doing both things it does: clearing the
  # attribute AND reading the `phx:theme` key. A host's own switcher that also
  # clears the attribute (for "light", say) but uses its own key is the
  # host's, and injecting after it would silently take its theme over.
  defp stock_theme_script?(content) do
    clears_theme?(content) and String.contains?(content, "phx:theme")
  end

  defp clears_theme?(content) do
    Regex.match?(~r/removeAttribute\(\s*["']data-theme["']\s*\)/, content)
  end

  defp stamps_theme?(content) do
    Regex.match?(~r/setAttribute\(\s*["']data-theme["']/, content) or
      Regex.match?(~r/dataset\.theme\s*=[^=]/, content) or
      Regex.match?(~r/<html\b[^>]*\sdata-theme\s*=/i, content)
  end

  # Pure half of the write — returns the updated HTML, or the original
  # when there is nowhere to land. The `<head>` matcher must not also
  # match `<header>`.
  @doc false
  def inject_theme_bootstrap_into(content) when is_binary(content) do
    block = """
        #{@bootstrap_marker}
        <PhoenixKitWeb.Components.ThemeBootstrap.theme_bootstrap />\
    """

    case theme_bootstrap_plan(content) do
      :before_head_close ->
        String.replace(content, "</head>", "    #{block}\n  </head>", global: false)

      :top_of_head ->
        String.replace(content, ~r{(<head(?:\s[^>]*)?>)}, "\\1\n#{block}", global: false)

      plan when plan in [:already_present, :host_managed] ->
        content
    end
  end

  # The host said so explicitly: nothing to report. Otherwise explain once per
  # run why the layout was left alone, and what to do about either outcome.
  defp host_managed_notice(igniter, layout_path, content) do
    if String.contains?(content, @host_managed_marker) do
      igniter
    else
      Igniter.add_notice(
        igniter,
        """
        ℹ️  #{layout_path} already sets data-theme itself, so PhoenixKit did NOT
        add its theme bootstrap — injecting it would override your script and
        your own [data-theme=…] styles would stop applying.

        PhoenixKit's admin pages will follow the theme your script sets. So
        they use the same palettes, point the kit at your theme names:

            config :phoenix_kit, dashboard_themes: ["light", "dark"]

        To let PhoenixKit manage the theme instead, remove your script and add
        at the end of <head>:

            #{@bootstrap_marker}
            <PhoenixKitWeb.Components.ThemeBootstrap.theme_bootstrap />

        To keep your script and silence this notice, add to <head>:

            #{@host_managed_marker}
        """
      )
    end
  end

  defp inject_theme_bootstrap(igniter, layout_path, content) do
    updated = inject_theme_bootstrap_into(content)

    if updated != content do
      File.write!(layout_path, updated)

      Igniter.add_notice(
        igniter,
        "✅ Added the PhoenixKit theme bootstrap (pre-paint theme stamp) to #{layout_path}"
      )
    else
      Igniter.add_warning(
        igniter,
        """
        ⚠️  Could not automatically add the theme bootstrap to #{layout_path}.
        To avoid a theme flash on first paint, render this at the top of <head>:

            #{@bootstrap_marker}
            <PhoenixKitWeb.Components.ThemeBootstrap.theme_bootstrap />
        """
      )
    end
  end

  @doc """
  Ensures the external-module JS integration is wired: an aggregate file is
  seeded, and the root layout has the (stable) module-hooks `<script>` tag.

  Registering the `:phoenix_kit_js_sources` compiler itself is NOT done here
  — see `PhoenixKit.Install.Common.ensure_compilers_registered/2`, called
  once by the install/update tasks alongside `:phoenix_kit_css_sources`
  (touching `mix.exs`'s `:compilers` list from two separate calls corrupts
  the second one; see that function's doc).

  Idempotent. Called at install and at `mix phoenix_kit.update`, so hosts that
  installed before this feature pick it up on their next update.
  """
  def ensure_module_js_integration(igniter) do
    igniter
    |> seed_modules_js_file()
    |> add_modules_script_tag_to_layout()
  end

  @doc """
  Updates the JS file in the parent app's static vendor directory.
  Called during `mix phoenix_kit.update` to keep hooks in sync.

  Belt-and-suspenders only — the `:phoenix_kit_js_sources` compiler now
  re-vendors this same file on every `mix compile`, so it self-heals even if
  this never runs again. This copy exists for the immediate feedback of
  running `update` itself, and raises loudly (`Mix.raise/1`) instead of
  logging a warning that the caller's return value goes unchecked, since a
  silently-stale hooks file breaks every PhoenixKit JS interaction with no
  error anywhere in sight.
  """
  def update_js_file do
    case resolve_source_path() do
      {:ok, source} ->
        dest = dest_path()
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(source, dest)
        verify_vendored!(dest)
        # The bundle names no library URL of its own: it needs the viewer
        # libraries and the install facts beside it, in the same step. The
        # compiler's function, so both paths produce identical output.
        PhoenixKitJsSources.vendor_all(File.cwd!())

        Logger.info(
          "Updated #{@source_filename}, its libraries and install facts in priv/static/assets/vendor/"
        )

        :ok

      {:error, :not_found} ->
        Mix.raise("""
        Could not find #{@source_filename} in the :phoenix_kit dependency's
        priv/static/assets/ — the dependency looks corrupted or incompletely
        fetched. Try `mix deps.get`.
        """)
    end
  end

  # A post-condition, not just a check on File.cp!/2's return value: verifies
  # the copy actually landed and isn't empty, so a filesystem quirk that lets
  # File.cp!/2 "succeed" without real content doesn't go unnoticed.
  defp verify_vendored!(dest) do
    case File.stat(dest) do
      {:ok, %File.Stat{size: size}} when size > 0 ->
        :ok

      {:ok, %File.Stat{size: 0}} ->
        Mix.raise("Vendored #{dest}, but the file is empty.")

      {:error, reason} ->
        Mix.raise(
          "Vendored #{@source_filename} to #{dest}, but it's not readable back: #{inspect(reason)}"
        )
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp copy_js_file(igniter) do
    case resolve_source_path() do
      {:ok, source} ->
        dest = dest_path()
        File.mkdir_p(Path.dirname(dest))

        case File.cp(source, dest) do
          :ok ->
            # The libraries and install facts the bundle loads them by.
            PhoenixKitJsSources.vendor_all(File.cwd!())

            Igniter.add_notice(
              igniter,
              "✅ Copied #{@source_filename}, its libraries and install facts to priv/static/assets/vendor/"
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

  # I103: regex-only, on purpose — `app.js` is JavaScript, and
  # `PhoenixKit.Install.ConfigVerify` (the parse-then-verify safety net the
  # Oban/config.exs splices use) only understands Elixir via
  # `Code.string_to_quoted/1`. There is no equivalent check available here;
  # correctness rests entirely on the regex and the `if updated != content`
  # guard below. See `ConfigVerify`'s moduledoc, "What this deliberately does
  # NOT cover".
  defp add_hooks_to_app_js(igniter) do
    app_js_path = Path.join([File.cwd!(), "assets", "js", "app.js"])

    if File.exists?(app_js_path) do
      content = File.read!(app_js_path)

      cond do
        # Match the actual spread, not any mention — a comment that merely names
        # PhoenixKitHooks must not skip the real injection. \s* handles the
        # multiline `hooks: {\n  ...window.PhoenixKitHooks,` shape.
        Regex.match?(~r/\.\.\.\s*window\.PhoenixKitHooks\b/, content) ->
          # Already has the PhoenixKitHooks spread
          igniter

        Regex.match?(~r/hooks:\s*\{/, content) ->
          # Has a hooks object — inject PhoenixKitHooks spread at the start
          updated =
            Regex.replace(
              ~r/hooks:\s*\{/,
              content,
              "hooks: {...window.PhoenixKitHooks, ",
              global: false
            )

          if updated != content do
            File.write!(app_js_path, updated)

            Igniter.add_notice(
              igniter,
              "✅ Added PhoenixKitHooks spread to LiveSocket hooks in assets/js/app.js"
            )
          else
            add_hooks_manual_notice(igniter)
          end

        Regex.match?(~r/new LiveSocket\(/, content) ->
          # Has LiveSocket but no hooks — add hooks option
          updated =
            Regex.replace(
              ~r/(new LiveSocket\([^,]+,\s*Socket,\s*\{)/,
              content,
              "\\1\n  hooks: {...window.PhoenixKitHooks},",
              global: false
            )

          if updated != content do
            File.write!(app_js_path, updated)

            Igniter.add_notice(
              igniter,
              "✅ Added PhoenixKitHooks to LiveSocket configuration in assets/js/app.js"
            )
          else
            add_hooks_manual_notice(igniter)
          end

        true ->
          add_hooks_manual_notice(igniter)
      end
    else
      add_hooks_manual_notice(igniter)
    end
  end

  defp add_hooks_manual_notice(igniter) do
    Igniter.add_warning(
      igniter,
      """
      ⚠️  Could not automatically add PhoenixKitHooks to app.js.
      Please add ...window.PhoenixKitHooks to your LiveSocket hooks:

          const liveSocket = new LiveSocket("/live", Socket, {
            hooks: {...window.PhoenixKitHooks, ...yourOtherHooks},
          })
      """
    )
  end

  # Seed an empty aggregate file so the <script> tag doesn't 404 before the
  # compiler first runs. The compiler overwrites it with real content. A seed
  # failure is surfaced as a warning (not swallowed) — the first `mix compile`
  # recreates the file, so it's recoverable, but the installer should say so.
  defp seed_modules_js_file(igniter) do
    dest = Path.join([File.cwd!(), "priv", "static", "assets", "vendor", @modules_filename])

    if File.exists?(dest) do
      igniter
    else
      with :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <-
             File.write(
               dest,
               "/* Auto-generated by PhoenixKit — populated on first compile. */\n"
             ) do
        igniter
      else
        {:error, reason} ->
          Igniter.add_warning(
            igniter,
            "⚠️  Could not seed #{@modules_filename} (#{inspect(reason)}). " <>
              "It will be created on the next `mix compile`."
          )
      end
    end
  end

  # Add the (stable) aggregate-module-hooks <script> tag to the root layout,
  # after phoenix_kit.js (so it augments window.PhoenixKitHooks) and before app.js.
  defp add_modules_script_tag_to_layout(igniter) do
    layout_paths = [
      "lib/#{Mix.Phoenix.otp_app()}_web/components/layouts/root.html.heex",
      "lib/#{Mix.Phoenix.otp_app()}_web/templates/layout/root.html.heex"
    ]

    case find_existing_file(layout_paths) do
      {:ok, layout_path} ->
        content = File.read!(layout_path)

        if String.contains?(content, @modules_filename) do
          igniter
        else
          inject_modules_script_tag(igniter, layout_path, content)
        end

      {:error, :not_found} ->
        Igniter.add_notice(
          igniter,
          """
          ⚠️  Could not find root layout. Please add this after the phoenix_kit.js
          script tag and before your app.js script tag:

              #{@modules_script_marker}
              <script src={~p"/assets/vendor/#{@modules_filename}"}></script>
          """
        )
    end
  end

  # I103: regex-only, on purpose — this splices into HEEX, and
  # `PhoenixKit.Install.ConfigVerify`'s parse-then-verify only understands
  # Elixir. See `ConfigVerify`'s moduledoc, "What this deliberately does NOT
  # cover", and `add_hooks_to_app_js/1` above for the same boundary on the JS
  # side.
  defp inject_modules_script_tag(igniter, layout_path, content) do
    tag = """
        #{@modules_script_marker}
        <script src={~p"/assets/vendor/#{@modules_filename}"}></script>\
    """

    # Prefer to anchor right after the phoenix_kit.js tag so ordering is explicit.
    # Escape the filename — its "." is a regex metachar, and a future vendor file
    # could otherwise false-match.
    pk = Regex.escape(@source_filename)

    updated =
      cond do
        Regex.match?(~r{<script[^>]*#{pk}[^>]*>\s*</script>}, content) ->
          Regex.replace(
            ~r{(<script[^>]*#{pk}[^>]*>\s*</script>)},
            content,
            "\\1\n#{tag}",
            global: false
          )

        Regex.match?(~r{(\s*<script[^>]*src=[^>]*app\.js[^>]*>)}, content) ->
          Regex.replace(
            ~r{(\s*<script[^>]*src=[^>]*app\.js[^>]*>)},
            content,
            "\n#{tag}\n\\1",
            global: false
          )

        true ->
          content
      end

    if updated != content do
      File.write!(layout_path, updated)
      Igniter.add_notice(igniter, "✅ Added module-hooks script tag to #{layout_path}")
    else
      Igniter.add_warning(
        igniter,
        """
        ⚠️  Could not automatically add the module-hooks script tag to #{layout_path}.
        Please add this after phoenix_kit.js and before app.js:

            #{@modules_script_marker}
            <script src={~p"/assets/vendor/#{@modules_filename}"}></script>
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
