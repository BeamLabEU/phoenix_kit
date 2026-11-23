defmodule PhoenixKit.Test.RateLimitIsolation do
  @moduledoc """
  What a test that counts a rate-limit budget needs, so that neither the wall clock nor another
  test can change the count.

  The limiter's windows are fixed and aligned to the clock (`div(now, window)`), and its buckets
  live in one table for the whole run. A test that takes N slots and then expects the next one to
  be refused therefore fails

    * when the window rolls over between its hits (a 60-second window rolls somewhere inside a
      test that takes a second, one run in sixty), and
    * when any other test took a slot of the same key in the same window. Keys carry an address,
      and an address picked at random out of a small range is picked twice sooner or later.

  `freeze_windows/1` takes the first away and `unique_ip/0` the second.

  The counter `unique_ip/0` reads is created by `test/test_helper.exs` (`start/0`).
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias PhoenixKit.Users.RateLimiter

  # A window that has not ended when the VM does: `div(now, window)` is 0 for the next 31,000
  # years, so the bucket never rolls and (expiring then) is never cleaned up either.
  @frozen_window_ms 1_000_000_000_000_000

  @handoff_windows [
    :handoff_start_window_ms,
    :handoff_mint_window_ms,
    :handoff_mint_ip_window_ms,
    :handoff_redeem_failure_window_ms
  ]

  # Addresses from 10.100.0.0 up: unique for the first ten million calls, and clear of the other
  # ranges tests of the suite use (10.8/16, 172.17/16, 198.51.100/24, 203.0.113/24).
  @first_octet 100
  @addresses 156 * 65_536

  @doc "Creates the counter `unique_ip/0` reads. Called once, by `test/test_helper.exs`."
  def start, do: :persistent_term.put(__MODULE__, :atomics.new(1, signed: false))

  @doc """
  An address no other call has been given in this run, as a string.
  """
  @spec unique_ip() :: String.t()
  def unique_ip, do: unique_peer() |> Tuple.to_list() |> Enum.join(".")

  @doc "The same address as `unique_ip/0`, as the tuple a connection's peer is."
  @spec unique_peer() :: :inet.ip4_address()
  def unique_peer do
    n = rem(:atomics.add_get(:persistent_term.get(__MODULE__), 1, 1), @addresses)

    {10, @first_octet + div(n, 65_536), div(rem(n, 65_536), 256), rem(n, 256)}
  end

  @doc """
  Windows of `keys` (the handoff ones by default) that never roll, for the rest of the test.
  The limits are not touched: the test still counts to them, at its own pace.
  """
  @spec freeze_windows([atom()]) :: :ok
  def freeze_windows(keys \\ @handoff_windows),
    do: put(Enum.map(keys, &{&1, @frozen_window_ms}))

  @doc """
  Sets keys of the limiter's configuration for the rest of the test, and puts the application
  env back exactly as it was when the test ends: the same list when there was one, no key at all
  when there was none.
  """
  @spec put(keyword()) :: :ok
  def put(entries) when is_list(entries) do
    {current, restore} =
      case Application.fetch_env(:phoenix_kit, RateLimiter) do
        {:ok, config} ->
          {config, fn -> Application.put_env(:phoenix_kit, RateLimiter, config) end}

        :error ->
          {[], fn -> Application.delete_env(:phoenix_kit, RateLimiter) end}
      end

    Application.put_env(:phoenix_kit, RateLimiter, Keyword.merge(current, entries))
    on_exit(restore)
  end

  @spec put(atom(), term()) :: :ok
  def put(key, value), do: put([{key, value}])
end
