defmodule PhoenixKit.Migrations.Repair.Report do
  @moduledoc """
  The result shape `PhoenixKit.Migrations.Repair.verify/1` and `.repair/1` return —
  versions observed, one finding per object/invariant that was not silently
  clean, and the derived exit code for `mix phoenix_kit.repair` (spec §6.1's
  final pipeline step, §6.2's severity mapping, and the `0`/`1`/`2` contract on
  the mix task's moduledoc).

  ## Fields

    * `:prefix` — the schema this report is about.
    * `:dry_run` — whether the run that produced this report was read-only
      (`PhoenixKit.Migrations.Repair.verify/1`, or `.repair/1` with
      `dry_run: true`). Purely descriptive — every `finding.kind` already
      disambiguates `:would_repair` (dry-run) from `:repaired` (applied).
    * `:versions` — `%{comment: comment(), floor: pos_integer(), current: pos_integer()}`.
      `comment` is the **raw** value (see
      `PhoenixKit.Migrations.Repair.Probe.raw_comment/2`) — `:absent` (the
      `phoenix_kit` table does not exist), `nil` (table exists, no comment —
      the half-installed/adopt case), or the numeric value.
    * `:comment_action` — what, if anything, happened to the version comment
      this run: `:none`, `{:healed, version}` (stale-low, R2/`--heal-comment`),
      `{:adopted, version}` (R4/`--adopt`), or `{:would_heal, version}` /
      `{:would_adopt, version}` for a dry run that found the condition but
      did not write.
    * `:findings` — see `t:finding/0`.

  ## Severity → exit code

  `mix phoenix_kit.repair`'s contract is exit `0`/`1`/`2` (moduledoc); this
  module computes that from the **highest severity present**, never from
  counting kinds one by one, so a run that both fixed something repairable
  AND surfaced an error-severity divergence reports the divergence's exit
  code (`2`) — the operator still needs to see it even though other things
  got fixed:

    * any `severity: :error` finding present → `2` ("report-only divergences
      present" — spec §6.2's error-severity bucket: wrong type/length/
      default, unexpected NOT NULL, divergent index/constraint definition,
      `:create_failed`, a failing data invariant)
    * else any `severity: :repairable` finding present → `1` ("repairs
      applied-or-pending" — covers both an actual `:repaired` in `repair/1`
      and a `:would_repair` in `verify/1`/dry-run, deliberately collapsed to
      the same code per the mix task moduledoc's own wording)
    * else → `0` (clean; only `:info`-severity findings, if any)
  """

  @typedoc "Raw comment as read by `Probe.raw_comment/2` — never the legacy no-comment→1 mapping."
  @type comment :: :absent | nil | non_neg_integer()

  @typedoc "See the moduledoc's severity → exit code table."
  @type severity :: :info | :repairable | :error

  @typedoc """
  One reportable event. `since`/`object_id` are `nil` for findings that are not
  about a single manifest object (comment-policy findings, data invariants use
  `object_id: nil` + a `since` from the invariant).
  """
  @type finding :: %{
          kind: atom(),
          severity: severity(),
          object_id: String.t() | nil,
          since: pos_integer() | nil,
          message: String.t()
        }

  @type comment_action ::
          :none
          | {:healed, pos_integer()}
          | {:adopted, pos_integer()}
          | {:would_heal, pos_integer()}
          | {:would_adopt, pos_integer()}

  @type t :: %__MODULE__{
          prefix: String.t(),
          dry_run: boolean(),
          versions: %{comment: comment(), floor: pos_integer(), current: pos_integer()},
          comment_action: comment_action(),
          findings: [finding()]
        }

  defstruct prefix: "public",
            dry_run: false,
            versions: %{comment: :absent, floor: 1, current: 1},
            comment_action: :none,
            findings: []

  @doc "Builds an empty report for the given prefix/dry_run/versions triple."
  @spec new(String.t(), boolean(), %{
          comment: comment(),
          floor: pos_integer(),
          current: pos_integer()
        }) ::
          t()
  def new(prefix, dry_run, versions) do
    %__MODULE__{prefix: prefix, dry_run: dry_run, versions: versions, findings: []}
  end

  @doc "Appends one finding (prepended internally; `findings/1` returns them in append order)."
  @spec add_finding(t(), finding()) :: t()
  def add_finding(%__MODULE__{findings: findings} = report, finding) when is_map(finding) do
    %{report | findings: [finding | findings]}
  end

  @doc "Findings in the order they were added."
  @spec findings(t()) :: [finding()]
  def findings(%__MODULE__{findings: findings}), do: Enum.reverse(findings)

  @doc "Sets `comment_action`."
  @spec put_comment_action(t(), comment_action()) :: t()
  def put_comment_action(%__MODULE__{} = report, action), do: %{report | comment_action: action}

  @severity_rank %{error: 2, repairable: 1, info: 0}

  @doc """
  Counts findings by `severity` and by `kind`, plus the total — the numbers
  `mix phoenix_kit.repair`'s human-readable summary line and `--json` output
  both render from.
  """
  @spec summary(t()) :: %{total: non_neg_integer(), by_severity: map(), by_kind: map()}
  def summary(%__MODULE__{findings: findings}) do
    %{
      total: length(findings),
      by_severity: Enum.frequencies_by(findings, & &1.severity),
      by_kind: Enum.frequencies_by(findings, & &1.kind)
    }
  end

  @doc """
  The highest-severity-wins exit code — see the moduledoc's "Severity → exit
  code" section. `0`/`1`/`2` only; never raises.
  """
  @spec exit_code(t()) :: 0 | 1 | 2
  def exit_code(%__MODULE__{findings: []}), do: 0

  def exit_code(%__MODULE__{findings: findings}) do
    findings
    |> Enum.map(&Map.fetch!(@severity_rank, &1.severity))
    |> Enum.max()
    |> case do
      2 -> 2
      1 -> 1
      0 -> 0
    end
  end

  @doc """
  Plain-data rendering for `--json` — every value is already a JSON scalar,
  list, or map except `:versions.comment` (`:absent` needs a string form) and
  `:comment_action` (a tagged tuple). Both are flattened here; everything else
  (`finding.kind`/`finding.severity` atoms included) is left for the caller's
  JSON encoder to stringify, matching how `mix phoenix_kit.doctor`/
  `release_check` already emit atoms as plain output.
  """
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = report) do
    %{
      prefix: report.prefix,
      dry_run: report.dry_run,
      versions: %{
        comment: json_comment(report.versions.comment),
        floor: report.versions.floor,
        current: report.versions.current
      },
      comment_action: json_comment_action(report.comment_action),
      summary: summary(report),
      exit_code: exit_code(report),
      findings: findings(report)
    }
  end

  defp json_comment(:absent), do: "absent"
  defp json_comment(nil), do: nil
  defp json_comment(version) when is_integer(version), do: version

  defp json_comment_action(:none), do: %{action: "none"}

  defp json_comment_action({tag, version}) when is_integer(version) do
    %{action: to_string(tag), version: version}
  end
end
