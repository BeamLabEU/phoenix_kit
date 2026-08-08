defmodule PhoenixKit.Migrations.Repair.CommentPolicy do
  @moduledoc """
  Pure decision logic for the version-comment policy, spec §6.4 R1-R6. Every
  function here is DB-free — the caller (`PhoenixKit.Migrations.Repair`) does
  the actual reading/writing and passes in already-fetched values.

  ## Why "floor" here is `PhoenixKit.Migrations.Postgres.initial_version/0`, not a fixed number

  §6.4's R3 ("`0 < comment < floor` → hard `BelowFloorError`") is written for
  the **post-squash** world, where `floor` is a real number greater than 1
  (P3, now done). The chain is squashed at floor 135, so `initial_version/0`
  is `135` and the below-floor branches below are LIVE, not hypothetical:
  `classify/3`'s `:below_floor` branch is unreachable today (no integer
  satisfies `0 < comment < 1`) — but the branch has to exist and be correct
  now so P3 only has to change what `floor` *is*, never how this module
  *decides*. Tests exercise it with synthetic floors (e.g. `121`) precisely
  to prove that forward-readiness.

  ## R1 ("never lower the comment")

  Not a branch here — it is a postcondition every function in this module
  upholds by construction: `classify/3` never proposes writing a comment at
  all (that is `PhoenixKit.Migrations.Repair`'s job, driven by
  `should_heal_comment?/2` and `adopt_outcome/2`), and both of those only ever
  return a version `>=` what triggered them (`{:stale_low, target}` has
  `target > comment` by `marker_cross_check/2`'s own guard; `adopt_outcome/2`
  only fires from the NULL-comment branch, where any stamp is a raise).

  ## R2/R5 as one computation

  R2's "stale-LOW comment" (schema ahead of what the comment claims) and R5's
  "lying-HIGH ... comment ahead of schema" warning are opposite readings of
  the same number: the highest version whose objects are *all* structurally
  present (`highest_fully_present_version/1`, the generalized form of
  `PhoenixKit.Migrations.Postgres.heal_version_comment/2`'s single hardcoded
  `{83, ...}` marker probe — spec's own word for it is "generalized").
  `marker_cross_check/2` compares that number against the comment and reports
  whichever side is warranted (or `:consistent` when they agree).
  """

  @typedoc "Raw comment as read by `PhoenixKit.Migrations.Repair.Probe.raw_comment/2`."
  @type raw_comment :: :absent | nil | non_neg_integer()

  @typedoc "Which R-branch a given raw comment falls into."
  @type branch ::
          :not_installed
          | {:below_floor, pos_integer()}
          | :adopt_required
          | {:in_range, pos_integer()}
          | {:above_current, pos_integer()}

  @doc """
  Classifies a raw comment against `floor`/`current` into one of R3-R6's
  branches (R1/R2 are cross-cutting, not classification outcomes — see
  moduledoc). `:absent` (table doesn't exist) and a phantom `0` comment (never
  written by any real migration, but treated defensively the same as `nil`)
  both fall outside R1-R6's own enumeration; `:not_installed`/`:adopt_required`
  make that explicit rather than leaving them undefined.

      iex> CommentPolicy.classify(:absent, 121, 151)
      :not_installed
      iex> CommentPolicy.classify(nil, 121, 151)
      :adopt_required
      iex> CommentPolicy.classify(0, 121, 151)
      :adopt_required
      iex> CommentPolicy.classify(90, 121, 151)
      {:below_floor, 90}
      iex> CommentPolicy.classify(135, 121, 151)
      {:in_range, 135}
      iex> CommentPolicy.classify(200, 121, 151)
      {:above_current, 200}
  """
  @spec classify(raw_comment(), floor :: pos_integer(), current :: pos_integer()) :: branch()
  def classify(:absent, _floor, _current), do: :not_installed
  def classify(nil, _floor, _current), do: :adopt_required
  def classify(0, _floor, _current), do: :adopt_required

  def classify(comment, floor, _current)
      when is_integer(comment) and comment > 0 and comment < floor do
    {:below_floor, comment}
  end

  def classify(comment, _floor, current) when is_integer(comment) and comment > current do
    {:above_current, comment}
  end

  def classify(comment, _floor, _current) when is_integer(comment) and comment > 0 do
    {:in_range, comment}
  end

  @typedoc "Outcome of comparing the comment against the highest fully-present version."
  @type cross_check ::
          :consistent | {:stale_low, pos_integer()} | {:ahead_of_schema, pos_integer()}

  @doc """
  The R2/R5 cross-check (see moduledoc). `highest` is
  `highest_fully_present_version/1`'s result.

      iex> CommentPolicy.marker_cross_check(135, 140)
      {:stale_low, 140}
      iex> CommentPolicy.marker_cross_check(135, 130)
      {:ahead_of_schema, 130}
      iex> CommentPolicy.marker_cross_check(135, 135)
      :consistent
  """
  @spec marker_cross_check(comment :: pos_integer(), highest :: non_neg_integer()) ::
          cross_check()
  def marker_cross_check(comment, highest) when highest > comment, do: {:stale_low, highest}
  def marker_cross_check(comment, highest) when highest < comment, do: {:ahead_of_schema, highest}
  def marker_cross_check(_comment, _highest), do: :consistent

  @doc """
  Generalizes `PhoenixKit.Migrations.Postgres.heal_version_comment/2`'s single
  `{83, marker_query}` entry to the whole manifest: the highest version for
  which *every* manifest object with that `since` is structurally present,
  given a per-`since`-bucket presence result. `0` if nothing is present at
  all (or the input is empty).

  `presence_by_since` need not be sorted or exhaustive — every distinct
  `since` bucket the caller actually probed, in any order. Correctness
  depends on the caller having probed **every** `since` value from the
  smallest up to (at least) the answer; a caller that skips a low `since`
  bucket entirely gets a result as if that bucket were fully present, which
  is why `PhoenixKit.Migrations.Repair.Probe`'s caller probes the whole
  manifest, not just "since above the comment".

      iex> CommentPolicy.highest_fully_present_version([{53, true}, {114, true}, {137, false}, {142, true}])
      114
      iex> CommentPolicy.highest_fully_present_version([{53, true}])
      53
      iex> CommentPolicy.highest_fully_present_version([{53, false}])
      0
      iex> CommentPolicy.highest_fully_present_version([])
      0
  """
  @spec highest_fully_present_version([{pos_integer(), boolean()}]) :: non_neg_integer()
  def highest_fully_present_version(presence_by_since) do
    presence_by_since
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take_while(fn {_since, all_present?} -> all_present? end)
    |> case do
      [] -> 0
      buckets -> buckets |> List.last() |> elem(0)
    end
  end

  @doc """
  Whether `--heal-comment` should stamp the comment forward, given the R2/R5
  cross-check and whether the flag was passed. Only `{:stale_low, _}` is ever
  healed — `:consistent` and `{:ahead_of_schema, _}` never propose writing
  anything (R1: healing "ahead of schema" would mean *lowering* the comment
  toward `highest`, which R1 forbids outright; R2's normal missing-object
  healing is what addresses that case instead).

      iex> CommentPolicy.should_heal_comment?({:stale_low, 140}, true)
      {:heal, 140}
      iex> CommentPolicy.should_heal_comment?({:stale_low, 140}, false)
      :no_heal
      iex> CommentPolicy.should_heal_comment?(:consistent, true)
      :no_heal
      iex> CommentPolicy.should_heal_comment?({:ahead_of_schema, 130}, true)
      :no_heal
  """
  @spec should_heal_comment?(cross_check(), heal_comment_requested? :: boolean()) ::
          {:heal, pos_integer()} | :no_heal
  def should_heal_comment?({:stale_low, target}, true), do: {:heal, target}
  def should_heal_comment?(_cross_check, _requested?), do: :no_heal

  @doc """
  R4's `--adopt` gate: stamp `floor` iff the post-apply verify pass came back
  fully clean (zero `:missing`, zero error-severity divergences, every
  floor-level data invariant held) — `verify_clean?` is that single boolean,
  computed by the caller from a `PhoenixKit.Migrations.Repair.Report.t()`.
  Never partially adopts.

      iex> CommentPolicy.adopt_outcome(true, 121)
      {:stamp, 121}
      iex> CommentPolicy.adopt_outcome(false, 121)
      :no_stamp
  """
  @spec adopt_outcome(verify_clean? :: boolean(), floor :: pos_integer()) ::
          {:stamp, pos_integer()} | :no_stamp
  def adopt_outcome(true, floor), do: {:stamp, floor}
  def adopt_outcome(false, _floor), do: :no_stamp

  @doc """
  Whether a report-only verify pass counts as "clean" for `adopt_outcome/2`'s
  `verify_clean?` argument: zero `:missing` findings and zero error-severity
  findings. (`data_invariants_hold?` is threaded separately by the caller —
  invariant failures already surface as error-severity findings in a
  well-formed report, but `PhoenixKit.Migrations.Repair` computes this from
  the finding list directly so the gate does not depend on that always being
  true.)

      iex> CommentPolicy.floor_verify_clean?([%{kind: :pending, severity: :info}])
      true
      iex> CommentPolicy.floor_verify_clean?([%{kind: :missing, severity: :repairable}])
      false
      iex> CommentPolicy.floor_verify_clean?([%{kind: :wrong_shape, severity: :error}])
      false
  """
  @spec floor_verify_clean?([PhoenixKit.Migrations.Repair.Report.finding()]) :: boolean()
  def floor_verify_clean?(findings) do
    Enum.all?(findings, fn finding -> finding.severity != :error and finding.kind != :missing end)
  end

  @doc """
  Detects the "chain `up/1` advanced the comment mid-repair" race (spec's
  concurrency rule, S18): compares the raw comment read right after the
  advisory lock was acquired against a second raw read taken right before the
  final verify pass. Any difference — not just an increase — aborts, since a
  decrease would mean a `down/1` ran concurrently, an equally unsafe race.

      iex> CommentPolicy.concurrent_migration?(135, 135)
      false
      iex> CommentPolicy.concurrent_migration?(135, 142)
      true
      iex> CommentPolicy.concurrent_migration?(nil, nil)
      false
      iex> CommentPolicy.concurrent_migration?(nil, 121)
      true
  """
  @spec concurrent_migration?(raw_comment(), raw_comment()) :: boolean()
  def concurrent_migration?(same, same), do: false
  def concurrent_migration?(_before, _after), do: true
end
