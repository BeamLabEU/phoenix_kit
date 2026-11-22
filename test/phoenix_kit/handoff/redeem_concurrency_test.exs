defmodule PhoenixKit.Handoff.RedeemConcurrencyTest do
  @moduledoc """
  Simultaneous redeems of one token: separate database sessions, real commits, no sandbox, so the
  statement's locking is what decides, not a single connection's order. Exactly one wins.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Handoff
  alias PhoenixKit.Handoff.Token
  alias PhoenixKit.Test.Repo

  @moduletag :integration
  @host "shop-de.test"
  @callers 8

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(t in Token, where: t.target_host == ^@host))
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  defp mint! do
    nonce = Handoff.new_secret()

    {:ok, token} =
      Handoff.mint(%{
        target_host: @host,
        redirect_path: "/shop",
        browser_nonce_hash: :crypto.hash(:sha256, nonce),
        payload: %{"handoff_stub" => %{"cart" => "abc"}}
      })

    {token, nonce}
  end

  test "of several simultaneous redeems on separate connections exactly one wins" do
    {token, nonce} = mint!()

    results =
      1..@callers
      |> Task.async_stream(fn _ -> Handoff.redeem(token, @host, nonce) end,
        max_concurrency: @callers,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %Token{}}, &1)) == 1
    assert Enum.count(results, &(&1 == :error)) == @callers - 1

    assert [%Token{used_at: %DateTime{}}] =
             Repo.all(from(t in Token, where: t.target_host == ^@host))
  end

  test "simultaneous redeems of different tokens each win their own" do
    minted = for _ <- 1..@callers, do: mint!()

    results =
      minted
      |> Task.async_stream(fn {token, nonce} -> Handoff.redeem(token, @host, nonce) end,
        max_concurrency: @callers,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Token{}}, &1))
  end
end
