defmodule PhoenixKit.Users.Sessions.RevocationObserverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Users.Sessions.Revocation.Observer

  test "a permanently unavailable repo stops retaining its observer" do
    check = fn ->
      send(self(), :checked)
      :unavailable
    end

    log =
      capture_log(fn ->
        assert :unavailable = Observer.run(check, 4, max_failures: 3, initial_delay: 0)
      end)

    for _ <- 1..3, do: assert_received(:checked)
    refute_received :checked
    assert log =~ "3 consecutive repo failures (4 sessions)"
    assert log =~ "token absence was not verified"
  end

  test "a reachable transaction resets the failure budget and may stay open" do
    key = make_ref()

    outcomes =
      [:unavailable, :unavailable] ++
        List.duplicate(:retry, 50) ++ [:unavailable, :unavailable, :done]

    Process.put(key, outcomes)

    check = fn ->
      [outcome | rest] = Process.get(key)
      Process.put(key, rest)
      outcome
    end

    capture_log(fn ->
      assert :ok = Observer.run(check, 1, max_failures: 3, initial_delay: 0)
    end)

    assert Process.get(key) == []
  end

  test "rollback or completed disconnect ends observation immediately" do
    assert :ok = Observer.run(fn -> :done end, 1, initial_delay: 0)
  end
end
