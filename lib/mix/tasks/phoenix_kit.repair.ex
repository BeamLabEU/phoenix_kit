defmodule Mix.Tasks.PhoenixKit.Repair do
  @moduledoc """
  Verifies and additively repairs a PhoenixKit installation against the
  generated `PhoenixKit.Migrations.ExpectedSchema` manifest (spec §6).

  ## Usage

      $ mix phoenix_kit.repair
      $ mix phoenix_kit.repair --dry-run
      $ mix phoenix_kit.repair --prefix=auth
      $ mix phoenix_kit.repair --json
      $ mix phoenix_kit.repair --adopt
      $ mix phoenix_kit.repair --heal-comment
      $ mix phoenix_kit.repair --unsafe-pooled

  ## Options

    * `--dry-run` — plan only; never writes (creates, backfills, comment
      changes). Every finding that would otherwise be `:repaired` reports
      as `:missing` instead. Equivalent in effect to `mix phoenix_kit.repair`
      always running the read-only half — the flag exists so the command
      name stays `repair` for the write path and `--dry-run` opts into the
      identical `verify/1` behavior without a separate subcommand.
    * `--prefix` — schema prefix. Resolved the same way
      `mix phoenix_kit.update`/`--status` resolve it: `--prefix` flag →
      `config :phoenix_kit, :prefix` → `"public"`
      (`PhoenixKit.Install.PrefixConfig.resolve_prefix/1`).
    * `--json` — machine-readable output (`PhoenixKit.Migrations.Repair.Report.to_json_map/1`)
      instead of the human-readable report.
    * `--adopt` — spec §6.4 R4. Only meaningful when the version comment is
      missing (half-installed/adopted/PgBouncer-stripped) — converges the
      floor-level slice and stamps the floor version iff it comes back
      clean.
    * `--heal-comment` — spec §6.4 R2. Only meaningful when the schema is
      structurally ahead of what the comment claims — stamps the highest
      version whose objects are all present.
    * `--unsafe-pooled` — required to proceed when a pooled connection
      (PgBouncer transaction-mode or similar) is detected; skips the
      advisory lock and FK `VALIDATE CONSTRAINT` (§6.3).

  ## Exit codes

      0  clean — nothing to report
      1  the manifest is not generated yet, OR repairs were applied/are pending
      2  a hard error (below-floor, above-current, concurrent migration,
         pooled connection without --unsafe-pooled, adopt-required without
         --adopt) OR report-only divergences are present in the findings

  ## Manifest not generated yet

  `PhoenixKit.Migrations.ExpectedSchema` — the tool-generated manifest — does
  not exist until the squash PR (P3) generates it from a real migrated
  scratch database. Until then, every invocation of this task prints
  `PhoenixKit.Migrations.ExpectedSchema.Resolver.not_generated_message/0`
  and exits `1`; this is expected, not a bug report.
  """

  use Mix.Task

  alias PhoenixKit.Install.PrefixConfig
  alias PhoenixKit.Migrations.Repair
  alias PhoenixKit.Migrations.Repair.Report

  @shortdoc "Verifies and additively repairs a PhoenixKit installation against the manifest"

  @switches [
    dry_run: :boolean,
    prefix: :string,
    json: :boolean,
    adopt: :boolean,
    unsafe_pooled: :boolean,
    heal_comment: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.config")
    prefix = PrefixConfig.resolve_prefix(opts)
    Mix.Task.run("app.start")

    result =
      Repair.repair(
        prefix: prefix,
        dry_run: Keyword.get(opts, :dry_run, false),
        adopt: Keyword.get(opts, :adopt, false),
        heal_comment: Keyword.get(opts, :heal_comment, false),
        unsafe_pooled: Keyword.get(opts, :unsafe_pooled, false)
      )

    render(result, Keyword.get(opts, :json, false))
    halt_with(exit_code(result))
  end

  # ── Rendering ───────────────────────────────────────────────────────

  defp render({:ok, report}, true) do
    IO.puts(Jason.encode!(Report.to_json_map(report), pretty: true))
  end

  defp render({:error, reason}, true) do
    IO.puts(
      Jason.encode!(%{error: error_tag(reason), message: Repair.error_message(reason)},
        pretty: true
      )
    )
  end

  defp render({:ok, report}, false) do
    header(report)
    Enum.each(Report.findings(report), &print_finding/1)
    footer(report)
  end

  defp render({:error, reason}, false) do
    IO.puts("\n#{IO.ANSI.red()}#{Repair.error_message(reason)}#{IO.ANSI.reset()}")
  end

  defp header(report) do
    mode = if report.dry_run, do: "dry-run", else: "repair"
    comment = format_comment(report.versions.comment)

    IO.puts(
      "\n#{IO.ANSI.bright()}PhoenixKit Repair#{IO.ANSI.reset()} (#{mode}, prefix #{inspect(report.prefix)})"
    )

    IO.puts(String.duplicate("─", 60))

    IO.puts(
      "comment: #{comment} · floor: #{report.versions.floor} · current: #{report.versions.current}"
    )

    case report.comment_action do
      :none -> :ok
      {tag, version} -> IO.puts("comment action: #{tag} → V#{version}")
    end
  end

  defp format_comment(:absent), do: "absent (not installed)"
  defp format_comment(nil), do: "NULL"
  defp format_comment(version), do: "V#{version}"

  defp print_finding(finding) do
    color =
      case finding.severity do
        :error -> IO.ANSI.red()
        :repairable -> IO.ANSI.yellow()
        :info -> IO.ANSI.faint()
      end

    tag = finding.object_id || (finding.since && "V#{finding.since}") || "-"

    IO.puts(
      "  #{color}[#{finding.severity}] #{finding.kind} (#{tag})#{IO.ANSI.reset()} #{finding.message}"
    )
  end

  defp footer(report) do
    summary = Report.summary(report)
    IO.puts("")

    IO.puts(
      "#{IO.ANSI.bright()}#{summary.total} finding(s)#{IO.ANSI.reset()} — #{inspect(summary.by_severity)}"
    )
  end

  # ── Exit codes ──────────────────────────────────────────────────────

  # 0/1/2 mirror `PhoenixKit.Migrations.Repair.Report.exit_code/1` for a
  # completed run. The three error conditions without a numeric analogue in
  # that struct are placed deliberately: `:not_generated` (nothing could be
  # attempted at all, but this is an expected P2-era state, not a crash) at
  # `1` — the same bucket as "repairs pending" — and every other hard error
  # (below-floor, above-current, concurrent migration, a pooled connection
  # without `--unsafe-pooled`) at `2`, alongside report-only divergences,
  # since all of them mean "an operator needs to look at this before
  # anything else runs."
  # Public (but undocumented) for the same reason
  # `Mix.Tasks.PhoenixKit.Gen.Migration.migration_content/5` is: a mix
  # task's `run/1` isn't itself a good unit-test seam (it starts the app,
  # touches a real DB), but the pure decision this task makes from a
  # `Repair.repair/1` result is — `test/mix/tasks/phoenix_kit_repair_test.exs`
  # asserts against these directly.
  @doc false
  def exit_code({:ok, report}), do: Report.exit_code(report)
  def exit_code({:error, :not_generated}), do: 1
  def exit_code({:error, _reason}), do: 2

  @doc false
  def error_tag(:not_generated), do: "not_generated"
  def error_tag({tag, _}), do: to_string(tag)
  def error_tag({tag, _, _}), do: to_string(tag)

  defp halt_with(0), do: :ok
  defp halt_with(code), do: exit({:shutdown, code})
end
