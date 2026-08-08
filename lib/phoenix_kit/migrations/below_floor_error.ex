defmodule PhoenixKit.Migrations.BelowFloorError do
  @moduledoc """
  Raised when a database's PhoenixKit version is below this release's floor
  (`PhoenixKit.Migrations.Postgres.initial_version/0`) — a shape this
  release's compiled chain no longer carries migration modules for. Spec:
  `dev_docs/plans/2026-07-14-squash-migrations-spec.md` §5.2 / §6.4 R3.

  Repair is a completeness tool, not a migration bridge (§6.4 R3):
  non-additive intermediate transforms below the floor (type changes, PK
  promotions, key rewrites) cannot be replayed additively. The only
  supported path back to a floor-or-above shape is the **migration
  bridge** — the last pre-squash 1.7.x release of PhoenixKit, which still
  carries every version from V01. An operator on a below-floor install
  must:

    1. Pin the bridge release (`{:phoenix_kit, "~> 1.7"}`) and run its
       `mix phoenix_kit.update` (or `PhoenixKit.Migrations.up/1`) until
       the reported version is at least the floor this release requires.
    2. Only then move the pin to this release and upgrade normally.

  ## Fields

    * `:db_version` — the version this database is actually at (read from
      the `phoenix_kit` table comment)
    * `:floor` — this release's `initial_version/0`
    * `:bridge_version` — the bridge release's version string, when known;
      `nil` until that release is tagged (the message falls back to
      generic "1.7.x bridge release" wording in that case — see
      `dev_docs/plans/2026-07-14-squash-migrations-spec.md` §7.2's
      "last 1.7.x = frozen bridge")
    * `:context` — which entry point raised: `:up`, `:down`, or
      `:ensure_current`. The latter is reached only through
      `PhoenixKit.Migration.ensure_current/2` (test/CI boot helper) and
      appends a hint that installing the bridge is very likely NOT the
      right advice there — a persistent below-floor CI database is the
      common case, and `mix test.reset` is the actual fix.
  """

  defexception [:db_version, :floor, :bridge_version, :context]

  @type context :: :up | :down | :ensure_current

  @type t :: %__MODULE__{
          db_version: pos_integer(),
          floor: pos_integer(),
          bridge_version: String.t() | nil,
          context: context()
        }

  @impl true
  def message(%__MODULE__{} = error) do
    error
    |> stopover_message()
    |> maybe_append_test_db_hint(error.context)
  end

  defp stopover_message(%__MODULE__{db_version: db_version, floor: floor} = error) do
    "PhoenixKit database is at version #{db_version}, below this release's floor " <>
      "(V#{floor}) — #{action_clause(error.context)}. Install " <>
      "#{bridge_name(error.bridge_version)}, run its migrations until the reported " <>
      "version is at least V#{floor}, THEN upgrade to this release."
  end

  defp action_clause(:down),
    do: "a below-floor install cannot be rolled back through this release"

  defp action_clause(_up_or_ensure_current),
    do: "this release's chain no longer carries the migration modules below the floor"

  defp bridge_name(nil), do: "the last PhoenixKit 1.7.x release (the migration bridge)"
  defp bridge_name(version), do: "PhoenixKit #{version} (the migration bridge)"

  defp maybe_append_test_db_hint(message, :ensure_current) do
    message <> " If this is a test/CI database, run `mix test.reset`."
  end

  defp maybe_append_test_db_hint(message, _context), do: message
end
