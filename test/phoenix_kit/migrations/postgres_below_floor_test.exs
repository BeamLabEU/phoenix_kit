defmodule PhoenixKit.Migrations.PostgresBelowFloorTest do
  use ExUnit.Case, async: true

  @moduledoc """
  DB-free tests for `PhoenixKit.Migrations.Postgres.plan_up/3` and
  `plan_down/3` — spec §5.2's registry-change cond order.

  Post-squash, `@initial_version` is 135 (`Postgres.initial_version/0`): every
  branch these functions implement (below-floor raise, fresh-DB clamp,
  teardown split at the floor) is now reachable through the real
  `up/1`/`down/1`, not just a synthetic future floor as before the squash.

  `plan_up/3`/`plan_down/3` still take `initial_version` as a plain argument
  rather than reading the module attribute, so this suite exercises BOTH the
  real compiled floor (via `Postgres.initial_version/0` and
  `Postgres.current_version/0`, so a future floor raise needs no edits here)
  AND a couple of synthetic floors (1, 200) to keep proving the guard logic
  generically for any floor, not just today's.
  """

  alias PhoenixKit.Migrations.Postgres

  @floor Postgres.initial_version()
  @current Postgres.current_version()

  describe "plan_up/3 at the real compiled floor" do
    test "a DB below the floor raises" do
      assert Postgres.plan_up(90, @current, @floor) == {:raise, 90, @floor}
      assert Postgres.plan_up(1, @current, @floor) == {:raise, 1, @floor}
      assert Postgres.plan_up(@floor - 1, @current, @floor) == {:raise, @floor - 1, @floor}
    end

    test "fresh install (initial 0) clamps the target up to the floor" do
      assert Postgres.plan_up(0, @current, @floor) == {:run, @floor..@current}
      # pinned below-floor wrapper (e.g. `up(version: 27)`) still clamps up
      assert Postgres.plan_up(0, 27, @floor) == {:run, @floor..@floor}
      # pathological version: 0 / negative pins clamp too
      assert Postgres.plan_up(0, 0, @floor) == {:run, @floor..@floor}
      assert Postgres.plan_up(0, -5, @floor) == {:run, @floor..@floor}
    end

    test "the floor boundary itself is NOT below-floor — a valid installed shape" do
      assert Postgres.plan_up(@floor, @floor, @floor) == :noop
      assert Postgres.plan_up(@floor, @current, @floor) == {:run_delta, (@floor + 1)..@current}
    end

    test "ordinary delta upgrade from at-or-above the floor is unaffected" do
      mid = @floor + 1
      assert Postgres.plan_up(mid, @current, @floor) == {:run_delta, (mid + 1)..@current}
    end

    test "already at or past target is a no-op" do
      assert Postgres.plan_up(@current, @current, @floor) == :noop
      assert Postgres.plan_up(@current, @floor + 1, @floor) == :noop
    end
  end

  describe "plan_down/3 at the real compiled floor" do
    test "a current version below the floor raises regardless of target" do
      assert Postgres.plan_down(90, 0, @floor) == {:raise, 90, @floor}
      assert Postgres.plan_down(90, 50, @floor) == {:raise, 90, @floor}
    end

    test "full teardown splits the range at the floor boundary" do
      assert Postgres.plan_down(@current, 0, @floor) ==
               {:teardown, @current..(@floor + 1)//-1, @floor}
    end

    test "the teardown range never includes the floor (it's applied directly by down/1)" do
      {:teardown, range, floor} = Postgres.plan_down(@current, 0, @floor)
      refute floor in Enum.to_list(range)
    end

    test "a target below the floor clamps instead of tearing down" do
      assert Postgres.plan_down(@current, 50, @floor) ==
               {:clamped, @current..(@floor + 1)//-1, @floor}
    end

    test "a target at or above the floor is an ordinary partial rollback" do
      mid = @floor + 1
      assert Postgres.plan_down(@current, mid, @floor) == {:run, @current..(mid + 1)//-1}
      assert Postgres.plan_down(@current, @floor, @floor) == {:run, @current..(@floor + 1)//-1}
    end

    test "already at or below target is a no-op" do
      assert Postgres.plan_down(0, 0, @floor) == :noop
      assert Postgres.plan_down(@floor + 1, @current, @floor) == :noop
    end
  end

  describe "plan_up/3 — generic pure-function coverage at synthetic floors" do
    test "floor 1 degenerates to the pre-squash unclamped chain (below-floor guard unreachable)" do
      refute Enum.any?(0..200, fn v -> v > 0 and v < 1 end)

      assert Postgres.plan_up(0, 161, 1) == {:run, 1..161}
      assert Postgres.plan_up(0, 0, 1) == {:run, 1..1}
      assert Postgres.plan_up(0, -5, 1) == {:run, 1..1}
      assert Postgres.plan_up(56, 161, 1) == {:run_delta, 57..161}
      assert Postgres.plan_up(161, 161, 1) == :noop
      assert Postgres.plan_up(161, 100, 1) == :noop
    end

    test "an arbitrary future floor (200) behaves identically in shape to today's" do
      assert Postgres.plan_up(190, 210, 200) == {:raise, 190, 200}
      assert Postgres.plan_up(0, 27, 200) == {:run, 200..200}
      assert Postgres.plan_up(0, 210, 200) == {:run, 200..210}
      assert Postgres.plan_up(200, 200, 200) == :noop
      assert Postgres.plan_up(200, 210, 200) == {:run_delta, 201..210}
      assert Postgres.plan_up(205, 210, 200) == {:run_delta, 206..210}
    end
  end

  describe "plan_down/3 — generic pure-function coverage at synthetic floors" do
    test "teardown degenerates to today's single-range semantics at floor 1" do
      {:teardown, range, floor} = Postgres.plan_down(161, 0, 1)
      assert Enum.to_list(range) ++ [floor] == Enum.to_list(161..1//-1)
      assert floor == 1

      {:teardown, range2, floor2} = Postgres.plan_down(1, 0, 1)
      assert Enum.to_list(range2) ++ [floor2] == [1]
    end

    test "ordinary partial rollback above floor 1 is unaffected" do
      assert Postgres.plan_down(161, 50, 1) == {:run, 161..51//-1}
    end

    test "an arbitrary future floor (200) behaves identically in shape to today's" do
      assert Postgres.plan_down(190, 0, 200) == {:raise, 190, 200}
      assert Postgres.plan_down(190, 50, 200) == {:raise, 190, 200}
      assert Postgres.plan_down(210, 0, 200) == {:teardown, 210..201//-1, 200}
      assert Postgres.plan_down(210, 150, 200) == {:clamped, 210..201//-1, 200}
      assert Postgres.plan_down(210, 205, 200) == {:run, 210..206//-1}
      assert Postgres.plan_down(210, 200, 200) == {:run, 210..201//-1}
      assert Postgres.plan_down(0, 0, 200) == :noop
      assert Postgres.plan_down(205, 210, 200) == :noop
    end
  end
end
