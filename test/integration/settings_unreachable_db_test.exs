defmodule PhoenixKit.Settings.UnreachableDbTest do
  @moduledoc """
  Settings reads must degrade to their default when the database is
  unreachable, rather than taking the caller down with them.

  An unreachable database surfaces two ways: a checkout with no owner
  **raises** `DBConnection.OwnershipError`, while a dead pool or an owner that
  died mid-flight **exits**. `rescue` alone only ever covered the first, so a
  transient DB problem crashed callers — including the login redirect
  resolver.

  This presented as suite flakiness rather than a hard failure, because
  settings reads are ETS-cached and only touch the pool on a cache MISS:
  DB-less unit tests (`routes_test`, `language_refactor_test`, `tab_item_test`)
  passed on a warm cache and died when another test's settings write had
  evicted the key first.

  ## Two rules this file follows, both learned the hard way

  1. **Denying the DB takes `async: true` AND `Process.delete(:"$callers")`.**
     Shared sandbox mode (any `async: false` test) hands a connection to every
     process, and Ecto deliberately lets a `Task` borrow its caller's
     connection through `$callers`. Miss either and every assertion here
     passes vacuously against a healthy database — hence the leading guard
     test.
  2. **Never evict a real settings key.** This file is `async: true`, so it
     runs alongside other tests that share the ETS cache; evicting a key they
     read (`languages_enabled`, `remember_me_enabled`, …) forces THEM to hit
     the database and fail. Every read below uses a unique probe key that
     exists in neither the cache nor the database, so the miss is inherent —
     no eviction required, no cross-test interference.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Queries
  alias PhoenixKit.Test.Repo, as: TestRepo

  # A key no other test touches and no row exists for: guaranteed cache miss,
  # zero blast radius.
  defp probe_key(suffix), do: "__unreachable_db_probe_#{suffix}__"

  # A process with no route to a connection: not an owner itself, and no
  # caller chain for the sandbox to borrow one through.
  defp read_without_db_ownership(fun) do
    Task.async(fn ->
      Process.delete(:"$callers")
      fun.()
    end)
    |> Task.await(5000)
  end

  test "the harness really does deny the DB to a spawned task" do
    # Guards the guard: if this starts succeeding, the sandbox has gone shared
    # and every assertion below is silently vacuous.
    result =
      read_without_db_ownership(fn ->
        try do
          Queries.get_setting_by_key(probe_key("guard"))
          :unexpectedly_reachable
        rescue
          _ -> :denied
        catch
          :exit, _ -> :denied
        end
      end)

    assert result == :denied
  end

  test "get_boolean_setting/2 falls back to its default" do
    assert read_without_db_ownership(fn ->
             Settings.get_boolean_setting(probe_key("bool_true"), true)
           end) == true

    # The default is honored in both directions — not coerced to a constant.
    assert read_without_db_ownership(fn ->
             Settings.get_boolean_setting(probe_key("bool_false"), false)
           end) == false
  end

  test "get_setting_cached/2 falls back to its default" do
    assert read_without_db_ownership(fn ->
             Settings.get_setting_cached(probe_key("cached"), "/fallback")
           end) == "/fallback"
  end

  test "get_setting/1 returns nil rather than exiting" do
    assert read_without_db_ownership(fn -> Settings.get_setting(probe_key("plain")) end) == nil
  end

  test "get_setting/2 returns its default rather than exiting" do
    assert read_without_db_ownership(fn ->
             Settings.get_setting(probe_key("plain_default"), "/fallback")
           end) == "/fallback"
  end

  # The mode a `rescue` cannot catch, and the one the real flake hit:
  # `** (EXIT) shutdown: "owner #PID<...> exited"`. The reader owns a sandbox
  # connection, then that owner dies mid-flight, so the checkout EXITS rather
  # than raising. Without the `catch :exit` clauses this crashes the caller.
  test "a settings read whose sandbox owner has died still returns its default" do
    parent = self()
    key = probe_key("dead_owner")

    reader =
      spawn(fn ->
        owner = Sandbox.start_owner!(TestRepo, shared: false)
        # Prove the connection works, then destroy it out from under ourselves.
        _ = Settings.get_setting_cached(probe_key("dead_owner_warmup"), "x")
        Sandbox.stop_owner(owner)

        send(parent, {:result, Settings.get_boolean_setting(key, true)})
      end)

    ref = Process.monitor(reader)

    assert_receive {:result, true}, 5000
    refute_receive {:DOWN, ^ref, :process, _, {%DBConnection.OwnershipError{}, _}}, 100
  end
end
