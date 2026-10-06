defmodule PhoenixKit.Activity.LogNeverUnwindsTest do
  @moduledoc """
  `Activity.log/1` never unwinds into its caller: a raise, an exit or a
  throw from the repo comes back as `{:error, _}` with a log line, and a
  failure in the fan-out after a committed insert leaves the result
  `{:ok, entry}`. Swaps
  the configured repo, so it runs synchronously — after every async test,
  with nothing else in flight.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Activity

  defmodule FailingRepo do
    @moduledoc false
    # The insert lands; the notification fan-out's settings read then throws.
    def insert(%Ecto.Changeset{changes: %{metadata: %{"fail" => "fan_out"}}} = changeset),
      do: {:ok, Ecto.Changeset.apply_changes(changeset)}

    def insert(%Ecto.Changeset{changes: %{metadata: %{"fail" => kind}}}), do: fail(kind)

    # Whichever read the fan-out makes (a setting by key, by id) throws.
    def get_by(_queryable, _clauses, _opts \\ []), do: throw(:fan_out_thrown)
    def get(_queryable, _id, _opts \\ []), do: throw(:fan_out_thrown)

    defp fail("raise"), do: raise("boom")
    defp fail("exit"), do: exit(:pool_down)
    defp fail("throw"), do: throw(:thrown)
  end

  setup do
    previous = Application.get_env(:phoenix_kit, :repo)
    Application.put_env(:phoenix_kit, :repo, FailingRepo)
    on_exit(fn -> Application.put_env(:phoenix_kit, :repo, previous) end)
  end

  test "a committed entry stays {:ok, entry} when the fan-out after it throws" do
    log =
      capture_log(fn ->
        assert {:ok, %PhoenixKit.Activity.Entry{action: "probe.fan_out"}} =
                 Activity.log(%{
                   action: "probe.fan_out",
                   target_uuid: "019a0000-0000-7000-8000-000000000009",
                   metadata: %{"fail" => "fan_out"}
                 })
      end)

    assert log =~ "fan-out failed"
  end

  for kind <- ~w(raise exit throw) do
    test "a #{kind} from the repo is returned, not propagated" do
      log =
        capture_log(fn ->
          assert {:error, _} =
                   Activity.log(%{
                     action: "probe.#{unquote(kind)}",
                     metadata: %{"fail" => unquote(kind)}
                   })
        end)

      assert log =~ "Activity logging error"
    end
  end
end
