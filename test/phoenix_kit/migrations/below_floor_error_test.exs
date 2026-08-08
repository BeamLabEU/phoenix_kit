defmodule PhoenixKit.Migrations.BelowFloorErrorTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.BelowFloorError

  describe "message/1" do
    test "names the bridge and the floor for context: :up" do
      message =
        Exception.message(%BelowFloorError{db_version: 5, floor: 121, context: :up})

      assert message =~ ~r/bridge/i
      assert message =~ "version 5"
      assert message =~ "V121"
      refute message =~ "test.reset"
    end

    test "names the rollback-specific reason for context: :down" do
      message =
        Exception.message(%BelowFloorError{db_version: 90, floor: 121, context: :down})

      assert message =~ ~r/bridge/i
      assert message =~ "cannot be rolled back"
      refute message =~ "test.reset"
    end

    test "appends the test/CI-database hint only for context: :ensure_current" do
      message =
        Exception.message(%BelowFloorError{db_version: 5, floor: 121, context: :ensure_current})

      assert message =~ ~r/bridge/i
      assert message =~ "mix test.reset"
    end

    test "falls back to generic bridge wording when bridge_version is nil" do
      message =
        Exception.message(%BelowFloorError{db_version: 5, floor: 121, context: :up})

      assert message =~ "1.7.x"
    end

    test "names the concrete bridge version when known" do
      message =
        Exception.message(%BelowFloorError{
          db_version: 5,
          floor: 121,
          context: :up,
          bridge_version: "1.7.227"
        })

      assert message =~ "PhoenixKit 1.7.227"
      assert message =~ ~r/bridge/i
    end

    test "is raiseable via `raise Module, fields`" do
      error =
        assert_raise BelowFloorError, ~r/bridge/i, fn ->
          raise BelowFloorError, db_version: 5, floor: 121, context: :up
        end

      assert error.db_version == 5
      assert error.floor == 121
      assert error.context == :up
      assert error.bridge_version == nil
    end
  end
end
