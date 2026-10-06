# Igniter-only helper: every caller is a `mix phoenix_kit.*` igniter task,
# which is itself guarded the same way. Igniter is an OPTIONAL dependency
# (see mix.exs), so a host that scopes it to `only: [:dev, :test]` compiles
# :prod without it — unguarded, this module emitted
# "Igniter.X is undefined" warnings on every production build.
if Code.ensure_loaded?(Igniter) do
  defmodule PhoenixKit.Install.BootHook do
    @moduledoc """
    Wires `PhoenixKit.boot/1` into the parent app's `Application.start/2`.

    `PhoenixKit.boot/1` rescans for late-loading `:phoenix_kit_<x>` deps and
    runs registered modules' `migrate_legacy/0` (except with `update_mode`
    on, as under `mix phoenix_kit.update` / `doctor`). It must be called
    after `Supervisor.start_link/2` succeeds.

    Idempotent — if `PhoenixKit.boot` is already present in the file, this
    helper is a no-op. Called from both `mix phoenix_kit.install` and
    `mix phoenix_kit.update`.

    ## Standard form

    Matches the canonical Phoenix generator output:

        Supervisor.start_link(children, opts)

    and rewrites it to:

        Supervisor.start_link(children, opts) |> PhoenixKit.boot()

    Non-standard shapes (custom variable names, piped form, calls wrapped
    in `case`/`with`) are left untouched and surface as an Igniter warning
    with manual-edit instructions.
    """
    use PhoenixKit.Install.IgniterCompat

    alias PhoenixKit.Install.ConfigVerify
    alias PhoenixKit.Install.IgniterHelpers

    @standard_call ~r/Supervisor\.start_link\(children,\s*opts\)/

    @doc """
    Add the `PhoenixKit.boot/1` call to the parent app's `Application.start/2`.

    Returns the igniter unchanged when:
      * The parent app has no `lib/<app>/application.ex` (unusual setup)
      * `PhoenixKit.boot` is already in the file (idempotent re-run)
    """
    def add_boot_hook(igniter) do
      app_name = IgniterHelpers.get_parent_app_name(igniter)
      app_file = "lib/#{app_name}/application.ex"

      # `Igniter.exists?/2`, not bare `File.exists?/1`: the latter only ever
      # sees the real filesystem, missing a file that exists only in
      # Igniter's own buffer (an earlier step in this run created it, or —
      # the case that matters for testing this function at all — a test
      # project built with `Igniter.Test.test_project/1`, which never
      # touches real disk).
      if Igniter.exists?(igniter, app_file) do
        wire_in(igniter, app_file)
      else
        igniter
      end
    end

    # I103: the verify+rollback decision happens INSIDE the
    # `Igniter.update_file/3` callback, against the BUFFERED content
    # (`Rewrite.Source.get(source, :content)`) rather than a fresh
    # `File.read!/1` — Igniter never flushes a step's writes to disk before
    # the next step runs, so reading the file mid-pipeline sees whatever was
    # on disk BEFORE this run started. The regression this fixes: this used
    # to read `content` from disk and then unconditionally overwrite the
    # buffer with a candidate built from it, discarding whatever an EARLIER
    # step in the same run had already staged for the same file — most
    # concretely `ApplicationSupervisor.add_supervisor/2` adding
    # `PhoenixKit.Supervisor` to `children` on a fresh install, silently
    # producing a boot pipe with no supervisor in it. Same reasoning as
    # `PhoenixKit.Install.ObanConfig.update_existing_oban_config/3` and
    # `PhoenixKit.Install.MailerConfig.repair_runtime_import_order/1`, both
    # of which already decide from the buffer.
    defp wire_in(igniter, app_file) do
      Igniter.update_file(igniter, app_file, fn source ->
        content = Rewrite.Source.get(source, :content)

        cond do
          String.contains?(content, "PhoenixKit.boot") ->
            source

          not Regex.match?(@standard_call, content) ->
            {:warning, manual_instructions(app_file)}

          true ->
            candidate =
              Regex.replace(
                @standard_call,
                content,
                "Supervisor.start_link(children, opts) |> PhoenixKit.boot()",
                global: false
              )

            case ConfigVerify.verify_or_rollback(content, candidate, &boot_hook_wired?/1) do
              {:ok, updated_content} -> Rewrite.Source.update(source, :content, updated_content)
              {:rolled_back, _original, _reason} -> {:warning, manual_instructions(app_file)}
            end
        end
      end)
    end

    # True if `ast` contains `... |> PhoenixKit.boot()` anywhere — confirms
    # the rewrite actually landed as a real pipe into `PhoenixKit.boot/1`,
    # not inside a comment or a string that happened to match the same text.
    defp boot_hook_wired?(ast) do
      ConfigVerify.ast_contains?(ast, fn
        {:|>, _, [_lhs, {{:., _, [{:__aliases__, _, [:PhoenixKit]}, :boot]}, _, []}]} -> true
        _ -> false
      end)
    end

    defp manual_instructions(app_file) do
      """
      PhoenixKit could not automatically wire `PhoenixKit.boot/1` into
      #{app_file} — your `Supervisor.start_link/2` call uses a non-standard form.

      Please add `|> PhoenixKit.boot()` at the end of `start/2` manually:

          def start(_type, _args) do
            children = [...]
            opts = [strategy: :one_for_one, name: MyApp.Supervisor]
            Supervisor.start_link(children, opts) |> PhoenixKit.boot()
          end

      Without this call, late-loading `:phoenix_kit_<x>` modules may not appear
      in the admin Modules page until you restart the server (and even then,
      only intermittently).
      """
    end
  end
end
