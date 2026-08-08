defmodule PhoenixKit.Migrations.ExpectedSchema.DataInvariant do
  @moduledoc """
  The `t:t/0` map shape emitted by
  `PhoenixKit.Migrations.ExpectedSchema.data_invariants/1` — an assertion
  about *data*, not schema, for an upgrade-only transform the squash baseline
  cannot replay (spec §5.1/§8.3's minimum set: post-V114 no composite
  `"integration:*"` settings keys, V137 `aws_message_id` uniqueness, V77/V109
  renamed-key absence, and similar).

  Schema objects (`PhoenixKit.Migrations.ExpectedSchema.Object`) answer "does
  this table/column/index/... exist with the right shape". Data invariants
  answer a question no catalog lookup can: "did the data that already lived
  in this table get correctly transformed", for transforms a fresh baseline
  never runs (a fresh install has no legacy rows to rename/dedupe/rewrite in
  the first place — the invariant is vacuously true there) but an
  incrementally-upgraded install must have already satisfied via the real
  chain's delta modules.

  ## Usage

  Report-only, always — verify surfaces a failing invariant as an
  error-severity divergence (spec §6.2's severity mapping) but repair never
  attempts to *fix* one (there is no additive SQL that undoes a settings-key
  rename or a dedup-delete safely outside the chain). The one place a data
  invariant gates a decision rather than merely reporting is `--adopt` (spec
  §6.4 R4): stamping the floor version on a half-installed/adopted database is
  refused unless every floor-level invariant (`since <= floor`) holds, exactly
  like the verify pass's own `:missing`/error-severity gate.

  ## Fields

    * `:since` — the version whose delta module the invariant characterizes
      (used the same way `Object.t()`'s `:since` gates object creation: an
      invariant with `since > comment` has not "happened" yet for that DB and
      is not evaluated).
    * `:desc` — human-readable, one line, printed verbatim in reports.
    * `:assert` — SQL text that returns exactly one row with one boolean
      column; `true` means the invariant holds. Carries the same
      `"__SCHEMA__"` token (`PhoenixKit.Migrations.ExpectedSchema.Object.schema_token/0`)
      as `Object.t()`'s `:check`/`:create` strings — substitute it via
      `materialize/2`, never by hand.

  ## Example

      iex> invariant = %{
      ...>   since: 114,
      ...>   desc: "V114: settings integration rows are uuid-keyed",
      ...>   assert: "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_settings " <>
      ...>             "WHERE key LIKE 'integration:%')"
      ...> }
      iex> DataInvariant.materialize(invariant, "auth").assert
      "SELECT NOT EXISTS (SELECT 1 FROM auth.phoenix_kit_settings WHERE key LIKE 'integration:%')"
  """

  alias PhoenixKit.Migrations.ExpectedSchema.Object

  @typedoc "One data invariant. See the moduledoc's field reference."
  @type t :: %{
          since: pos_integer(),
          desc: String.t(),
          assert: String.t()
        }

  @doc """
  Substitutes `PhoenixKit.Migrations.ExpectedSchema.Object.schema_token/0` for
  `prefix` in `:assert`. `prefix` must already be normalized
  (`Object.normalize_prefix/1`); this function does not validate it again.
  """
  @spec materialize(t(), String.t()) :: t()
  def materialize(invariant, prefix) do
    %{invariant | assert: String.replace(invariant.assert, Object.schema_token(), prefix)}
  end

  @doc """
  Structural runtime conformance check for one invariant — the `DataInvariant`
  counterpart to `Object.valid?/1`. Never raises.
  """
  @spec valid?(term()) :: boolean()
  def valid?(%{since: since, desc: desc, assert: assert} = invariant) do
    Map.keys(invariant) |> Enum.sort() == [:assert, :desc, :since] and
      is_integer(since) and since > 0 and
      is_binary(desc) and desc != "" and
      is_binary(assert) and assert != ""
  end

  def valid?(_invariant), do: false
end
