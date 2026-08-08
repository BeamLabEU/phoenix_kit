defmodule Mix.Tasks.PhoenixKit.RepairTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Repair, as: RepairTask
  alias PhoenixKit.Migrations.Repair.Report

  # `run/1` itself isn't a good unit-test seam (starts the app, needs a real
  # DB) — see `Mix.Tasks.PhoenixKit.Gen.Migration.migration_content/5` for
  # the established pattern this follows: exercise the pure decision the
  # task makes from a `PhoenixKit.Migrations.Repair` result directly.

  describe "exit_code/1" do
    test "delegates to Report.exit_code/1 for a completed run" do
      report =
        Report.new("public", true, %{
          comment: 135,
          floor: 121,
          current: 151
        })

      assert RepairTask.exit_code({:ok, report}) == 0
    end

    test ":not_generated → 1 (nothing attempted, but expected today, not a failure)" do
      assert RepairTask.exit_code({:error, :not_generated}) == 1
    end

    test "every other hard error → 2" do
      assert RepairTask.exit_code({:error, {:below_floor, 90, 121}}) == 2
      assert RepairTask.exit_code({:error, {:above_current, 200, 151}}) == 2
      assert RepairTask.exit_code({:error, {:not_installed, "public"}}) == 2
      assert RepairTask.exit_code({:error, {:pooled_connection, "msg"}}) == 2
      assert RepairTask.exit_code({:error, {:concurrent_migration, 135, 142}}) == 2
    end
  end

  describe "error_tag/1 — the {:json} error object's discriminator" do
    test ":not_generated" do
      assert RepairTask.error_tag(:not_generated) == "not_generated"
    end

    test "2-tuples" do
      assert RepairTask.error_tag({:pooled_connection, "msg"}) == "pooled_connection"
      assert RepairTask.error_tag({:not_installed, "public"}) == "not_installed"
    end

    test "3-tuples" do
      assert RepairTask.error_tag({:below_floor, 90, 121}) == "below_floor"
      assert RepairTask.error_tag({:above_current, 200, 151}) == "above_current"
      assert RepairTask.error_tag({:concurrent_migration, 135, 142}) == "concurrent_migration"
    end
  end
end
