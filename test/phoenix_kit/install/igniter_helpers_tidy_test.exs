defmodule PhoenixKit.Install.IgniterHelpersTidyTest do
  @moduledoc """
  Igniter prints every notice as `"* " <> notice`; the kit's notices are
  heredocs that start with a blank line, so NordAPI's update showed bare
  `* ` bullets with the text below them. `tidy_messages/1` runs last in the
  install and update pipelines.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.IgniterHelpers

  test "notices, warnings and issues lose their surrounding blank lines" do
    igniter =
      Igniter.new()
      |> Igniter.add_notice("""

      ✅ PhoenixKit is already up to date (V236).

      Use --force to regenerate the migration anyway.
      """)
      |> Igniter.add_warning("\n❌ Cannot reach the database.\n")
      |> Igniter.add_issue("\n  ❌ below the floor\n")
      |> IgniterHelpers.tidy_messages()

    assert igniter.notices == [
             "✅ PhoenixKit is already up to date (V236).\n\nUse --force to regenerate the migration anyway."
           ]

    assert igniter.warnings == ["❌ Cannot reach the database."]
    assert igniter.issues == ["❌ below the floor"]
  end

  test "an empty message is dropped, duplicates are kept once, non-strings are kept" do
    error = %RuntimeError{message: "boom"}

    igniter =
      %{Igniter.new() | notices: ["\nsame\n", "same", "  \n"], warnings: [error]}
      |> IgniterHelpers.tidy_messages()

    assert igniter.notices == ["same"]
    assert igniter.warnings == [error]
  end

  test "both task pipelines end with it" do
    for task <- ["lib/mix/tasks/phoenix_kit.update.ex", "lib/mix/tasks/phoenix_kit.install.ex"] do
      assert File.read!(task) =~ "|> IgniterHelpers.tidy_messages()", task
    end
  end
end
