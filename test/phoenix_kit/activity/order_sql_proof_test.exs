defmodule PhoenixKit.Activity.OrderSqlProofTest do
  @moduledoc """
  Guards `Activity.list/1` and `Activity.recent/1` against losing their
  secondary sort key.

  Sorting by `inserted_at` alone is not a total order: the column carries no
  uniqueness constraint, so two entries can tie on it — rows written before
  V185 (`timestamp` went from second to microsecond precision) are all
  whole-second, which is the common case on any existing install, and even
  microsecond-precision writes can land on the identical instant. When they
  do, Postgres is free to break the tie however its query plan happens to
  land — a real, user-visible "recent activity" feed can then show events
  out of the order they actually happened in, and that order can differ
  between two runs of the exact same query. Appending `uuid` (the entry's
  primary key, unique and NOT NULL by schema) as a second sort key closes
  that gap completely: `(inserted_at, uuid)` cannot collide across two
  distinct rows, so the sort has nothing left to arbitrate — no migration,
  no precision upgrade needed.

  This test does not touch a database. It swaps `PhoenixKit.RepoHelper`'s
  configured repo for a stand-in that hands the query straight to
  `PhoenixKit.Test.Repo.to_sql/2` (a pure SQL compile step — no connection is
  opened) and inspects the resulting `ORDER BY` clause. Runs even where
  Postgres is unreachable.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Activity
  alias PhoenixKit.Test.Repo, as: TestRepo

  defmodule CapturingRepo do
    @moduledoc false
    def aggregate(_query, _kind), do: 0

    def all(query) do
      {sql, _params} = TestRepo.to_sql(:all, query)
      Process.put(:activity_order_sql_capture, sql)
      []
    end

    def preload(entries, _assocs), do: entries
  end

  setup do
    original_repo = Application.get_env(:phoenix_kit, :repo)
    Application.put_env(:phoenix_kit, :repo, CapturingRepo)
    Process.delete(:activity_order_sql_capture)

    on_exit(fn -> Application.put_env(:phoenix_kit, :repo, original_repo) end)
    :ok
  end

  defp captured_order_by! do
    sql = Process.get(:activity_order_sql_capture) || flunk("no query was captured")

    case Regex.run(~r/ORDER BY (.+?)(?:LIMIT|OFFSET|$)/is, sql) do
      [_, clause] -> clause
      nil -> flunk("query had no ORDER BY clause:\n#{sql}")
    end
  end

  # `inserted_at` must come BEFORE `uuid` — `uuid` only exists to arbitrate
  # ties within an `inserted_at` value, so `desc: uuid, desc: inserted_at`
  # would pass a key-presence check while actually breaking the feed.
  @order_by_pattern ~r/inserted_at"\s*DESC,\s*\S*"uuid"\s*DESC/i

  # Needs the repo process, which only runs when the test database is reachable.
  @tag :integration
  test "recent/1 breaks inserted_at ties on the unique uuid primary key" do
    Activity.recent(5)
    order_by = captured_order_by!()

    assert order_by =~ @order_by_pattern
  end

  @tag :integration
  test "list/1 breaks inserted_at ties on the unique uuid primary key" do
    Activity.list()
    order_by = captured_order_by!()

    assert order_by =~ @order_by_pattern
  end
end
