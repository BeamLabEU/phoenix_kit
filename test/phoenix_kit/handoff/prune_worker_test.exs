defmodule PhoenixKit.Handoff.PruneWorkerTest do
  @moduledoc "The Oban worker that keeps the handoff table small, run as Oban runs it."
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Handoff
  alias PhoenixKit.Handoff.PruneWorker
  alias PhoenixKit.Handoff.Token

  defp mint!(nonce) do
    {:ok, token} =
      Handoff.mint(%{
        target_host: "shop-de.test",
        redirect_path: "/shop",
        browser_nonce_hash: :crypto.hash(:sha256, nonce),
        payload: %{"handoff_stub" => %{"cart" => "abc"}}
      })

    token
  end

  defp row(token), do: Repo.get_by(Token, token_hash: :crypto.hash(:sha256, token))

  defp expire(token, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    Repo.update_all(from(t in Token, where: t.token_hash == ^:crypto.hash(:sha256, token)),
      set: [expires_at: at]
    )
  end

  test "deletes the rows that expired more than a day ago and keeps the live ones" do
    nonce = Handoff.new_secret()
    live = mint!(nonce)
    recent = mint!(nonce)
    stale = mint!(nonce)
    stale_used = mint!(nonce)
    assert {:ok, _} = Handoff.redeem(stale_used, "shop-de.test", nonce)

    expire(recent, 3_600)
    expire(stale, 86_400 + 60)
    expire(stale_used, 2 * 86_400)

    assert :ok = PruneWorker.perform(%Oban.Job{})

    assert row(live)
    assert row(recent)
    refute row(stale)
    refute row(stale_used)
  end

  # `n` rows that expired `seconds_ago` ago, in one statement.
  defp insert_expired(n, seconds_ago) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for _ <- 1..n do
        %{
          uuid: UUIDv7.generate(),
          token_hash: :crypto.strong_rand_bytes(32),
          target_host: "shop-de.test",
          redirect_path: "/",
          payload: %{},
          browser_nonce_hash: :crypto.strong_rand_bytes(32),
          expires_at: DateTime.add(now, -seconds_ago, :second),
          inserted_at: now
        }
      end

    {^n, _} = Repo.insert_all(Token, rows)
  end

  test "deletes in bounded batches until nothing is left" do
    insert_expired(25, 2 * 86_400)

    assert 25 == PruneWorker.prune(batch: 10, max_batches: 100)
    assert Repo.aggregate(Token, :count) == 0
  end

  test "stops after the cap of a run and leaves the rest for the next one" do
    insert_expired(25, 2 * 86_400)

    assert 20 == PruneWorker.prune(batch: 10, max_batches: 2)
    assert Repo.aggregate(Token, :count) == 5

    assert :ok = PruneWorker.perform(%Oban.Job{})
    assert Repo.aggregate(Token, :count) == 0
  end

  test "a run never issues a statement bigger than the batch" do
    insert_expired(30, 2 * 86_400)

    # The statements a run issues: each one is a DELETE with a LIMIT of the batch.
    handler = "prune-worker-batches-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:phoenix_kit, :test, :repo, :query],
      fn _event, _measurements, %{result: result, query: query}, _config ->
        with true <- query =~ "phoenix_kit_handoff_tokens",
             true <- query =~ "DELETE",
             {:ok, %{num_rows: rows}} <- result,
             do: send(test, {:deleted, rows})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert 30 == PruneWorker.prune(batch: 7, max_batches: 100)

    sizes = collect_deleted()
    assert Enum.sum(sizes) == 30
    assert Enum.all?(sizes, &(&1 <= 7)), inspect(sizes)
    assert length(sizes) >= 5
  end

  defp collect_deleted do
    receive do
      {:deleted, n} -> [n | collect_deleted()]
    after
      0 -> []
    end
  end

  test "an empty table is nothing to do" do
    assert :ok = PruneWorker.perform(%Oban.Job{})
    assert Repo.all(Token) == []
  end

  test "is an Oban worker of the default queue" do
    assert PruneWorker.__opts__()[:queue] == :default
    assert function_exported?(PruneWorker, :perform, 1)
  end
end
