defmodule PhoenixKit.Migrations.Repair.EnvironmentTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Repair.Environment

  describe "classify_config/1 — the config-only heuristic (hint, never authoritative alone)" do
    test "standard port + ordinary host → :direct" do
      assert Environment.classify_config(port: 5432, hostname: "db.internal") == :direct
    end

    test "non-standard port → :maybe_pooled, regardless of hostname" do
      assert Environment.classify_config(port: 6432, hostname: "db.internal") == :maybe_pooled
    end

    test "hostname containing \"pgbouncer\" → :maybe_pooled, even on the standard port" do
      assert Environment.classify_config(port: 5432, hostname: "pgbouncer.internal") ==
               :maybe_pooled
    end

    test "derives port/host from a connection URL when given instead of discrete keys" do
      assert Environment.classify_config(url: "ecto://user:pass@pgbouncer:6432/db") ==
               :maybe_pooled

      assert Environment.classify_config(url: "ecto://user:pass@db.internal:5432/db") == :direct
    end

    test "no port/host/url at all defaults to 5432 + localhost → :direct" do
      assert Environment.classify_config([]) == :direct
    end
  end

  describe "lock_key/0" do
    test "a fixed, non-negative integer — stable across calls" do
      key = Environment.lock_key()
      assert is_integer(key)
      assert key >= 0
      assert Environment.lock_key() == key
    end
  end

  doctest Environment
end
