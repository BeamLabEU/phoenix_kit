defmodule Mix.Tasks.PhoenixKit.UpdateObanSchemaTest do
  @moduledoc """
  Where the Oban schema step sits in `mix phoenix_kit.update`: before the
  migrate step, whatever core's own state — the host already on the latest
  core is exactly the one an Oban upgrade leaves behind. What the step itself
  decides and writes is `PhoenixKit.Integration.ObanSchemaUpgradeTest`.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Update

  @staged [%{repo: SomeRepo, prefix: "public", from: 13, to: 14}]

  defp recording_steps(test_pid, overrides \\ %{}) do
    Map.merge(
      %{
        stage_oban: fn prefix ->
          send(test_pid, {:step, :stage_oban, prefix})
          @staged
        end,
        migrate: fn opts -> send(test_pid, {:step, :migrate, opts[:oban_staged]}) end,
        verify_oban: fn staged -> send(test_pid, {:step, :verify_oban, staged}) end,
        modules: fn _opts -> send(test_pid, {:step, :modules, nil}) end
      },
      overrides
    )
  end

  defp steps_run do
    receive_all([])
  end

  defp receive_all(acc) do
    receive do
      {:step, name, arg} -> receive_all([{name, arg} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "the Oban step runs first, and its result reaches the migrate step" do
    Update.run_schema_steps([prefix: "public"], recording_steps(self()))

    assert steps_run() == [
             {:stage_oban, "public"},
             {:migrate, @staged},
             {:verify_oban, @staged},
             {:modules, nil}
           ]
  end

  test "it runs with nothing from core in the options — no core status gates it" do
    # The only input is the task's own options; nothing here says whether
    # core had a migration to run, and the Oban step must not need to know.
    Update.run_schema_steps([prefix: "auth"], recording_steps(self()))
    assert [{:stage_oban, "auth"} | _] = steps_run()
  end

  test "a declined migration still leaves the Oban file written, and stops there" do
    declined = %{migrate: fn _opts -> Mix.raise("Migration skipped at your request.") end}

    assert_raise Mix.Error, fn ->
      Update.run_schema_steps([prefix: "public"], recording_steps(self(), declined))
    end

    assert steps_run() == [{:stage_oban, "public"}]
  end

  describe "staged_oban_note/1 — the not-migrated message names the Oban step" do
    test "says nothing when no Oban migration is waiting" do
      assert Update.staged_oban_note([]) == ""
    end

    test "names each step and what it costs until it runs" do
      note = Update.staged_oban_note(@staged)
      assert note =~ "public v13 → v14"
      assert note =~ "unique Oban inserts fail"
    end
  end
end
