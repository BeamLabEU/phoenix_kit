defmodule PhoenixKit.Install.ObanConfigPatchResultTest do
  @moduledoc """
  The Oban patch returns `{:ok, :added | :changed | :unchanged} | {:error, reason}`
  and the run reports it in exactly one line. A run used to print
  "Failed to add Oban configuration: SyntaxError" and "✅ Updated Oban
  configuration" for the same edit.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Igniter.Test

  alias PhoenixKit.Install.ObanConfig

  setup do
    ObanConfig.take_manual_steps()
    on_exit(fn -> ObanConfig.take_manual_steps() end)
    :ok
  end

  defp oban_lines(igniter) do
    Enum.filter(igniter.notices ++ igniter.warnings, &(&1 =~ ~r/Oban configuration/))
  end

  defp run(files) do
    capture_io(fn ->
      igniter =
        test_project(app_name: :my_app, files: files)
        |> ObanConfig.add_oban_configuration("public")

      send(self(), {:igniter, igniter})
    end)

    assert_received {:igniter, igniter}
    igniter
  end

  test "a new block: {:ok, :added}, one line" do
    igniter = run(%{"config/config.exs" => "import Config\n"})

    assert igniter.assigns[:phoenix_kit_oban_patch] == {:ok, :added}
    assert [line] = oban_lines(igniter)
    assert line =~ "added"
  end

  test "an existing block missing a queue: {:ok, :changed}, one line" do
    config = """
    import Config

    config :my_app, Oban,
      repo: MyApp.Repo,
      queues: [default: 10],
      plugins: false
    """

    igniter = run(%{"config/config.exs" => config})

    assert igniter.assigns[:phoenix_kit_oban_patch] == {:ok, :changed}
    assert [line] = oban_lines(igniter)
    assert line =~ "updated"

    new =
      igniter.rewrite |> Rewrite.source!("config/config.exs") |> Rewrite.Source.get(:content)

    assert new =~ "file_processing:"
  end

  test "nothing to do: {:ok, :unchanged}" do
    config = """
    import Config

    config :my_app, Oban, false
    """

    igniter = run(%{"config/config.exs" => config})
    assert igniter.assigns[:phoenix_kit_oban_patch] == {:ok, :unchanged}
    assert [_] = oban_lines(igniter)
  end

  describe "an edit that would not parse" do
    test "parse_check/3 names the file, the line and shows the lines around it" do
      original = "import Config\nconfig :my_app, Oban, queues: [default: 10]\n"
      candidate = "import Config\nconfig :my_app, Oban, queues: [default: 10,, x: 1]\n"

      assert {:error, reason} = ObanConfig.parse_check(candidate, original, "config/config.exs")
      assert reason.file == "config/config.exs"
      assert reason.line == 2
      assert reason.snippet =~ ">    2 | config :my_app"
      refute reason.message =~ "did not parse before"
    end

    test "a file that was already broken is said to be so" do
      broken = "import Config\nconfig :my_app, Oban, queues: [\n"
      assert {:error, reason} = ObanConfig.parse_check(broken, broken, "config/config.exs")
      assert reason.message =~ "did not parse before PhoenixKit's edit either"
    end

    test "is reported once, as a warning, and listed in the closing summary" do
      reason = %{file: "config/config.exs", line: 7, message: "syntax error", snippet: ">  7 | x"}

      igniter =
        test_project(app_name: :my_app, files: %{"config/config.exs" => "import Config\n"})
        |> ObanConfig.report_patch({:error, reason})

      assert [warning] = oban_lines(igniter)
      assert warning =~ "NOT updated (config/config.exs:7)"
      refute Enum.any?(igniter.notices, &(&1 =~ "Oban configuration"))

      summary = ObanConfig.manual_steps_summary(ObanConfig.take_manual_steps())
      assert summary =~ "config/config.exs:7"
    end
  end
end
