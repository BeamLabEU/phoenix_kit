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

  test "an empty table is nothing to do" do
    assert :ok = PruneWorker.perform(%Oban.Job{})
    assert Repo.all(Token) == []
  end

  test "is an Oban worker of the default queue" do
    assert PruneWorker.__opts__()[:queue] == :default
    assert function_exported?(PruneWorker, :perform, 1)
  end
end
