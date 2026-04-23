defmodule PhoenixKit.Settings.SettingTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Setting

  describe "@optional_settings ⊇ empty-string defaults invariant" do
    test "every key with an empty-string default is in @optional_settings" do
      empty_string_keys =
        Settings.get_defaults()
        |> Enum.filter(fn {_k, v} -> v == "" end)
        |> Enum.map(fn {k, _} -> k end)
        |> Enum.sort()

      optional = Setting.optional_settings()

      missing = empty_string_keys -- optional

      assert missing == [],
             """
             The following setting keys have empty-string defaults in \
             `PhoenixKit.Settings.get_defaults/0` but are missing from \
             `@optional_settings` in `PhoenixKit.Settings.Setting`:

               #{inspect(missing)}

             Batch-saving these from an empty form field will trip \
             `validate_value_exclusivity/1` and roll back the whole save. \
             Add them to `@optional_settings`. See PR #502.
             """
    end
  end
end
