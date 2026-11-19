defmodule PhoenixKit.Modules.Sitemap.SchedulerWorkerBootTest do
  # Boot-time scheduling must wait for Oban instead of raising: the host starts
  # PhoenixKit.Supervisor (and so this check) before Oban.
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Sitemap.SchedulerWorker

  describe "await_oban/3" do
    test "is false once the timeout passes without the instance" do
      name = {:sitemap_boot_test, make_ref()}
      started = System.monotonic_time(:millisecond)

      refute SchedulerWorker.await_oban(name, 60, 10)
      assert System.monotonic_time(:millisecond) - started >= 60
    end

    test "is true as soon as an instance registers under the name, even after the call started" do
      name = {:sitemap_boot_test, make_ref()}
      parent = self()

      registrar =
        spawn_link(fn ->
          Process.sleep(50)
          {:ok, _} = Registry.register(Oban.Registry, name, nil)
          send(parent, :registered)
          Process.sleep(:infinity)
        end)

      assert SchedulerWorker.await_oban(name, 2_000, 10)
      assert_receive :registered
      Process.unlink(registrar)
      Process.exit(registrar, :kill)
    end
  end

  describe "ensure_scheduled_on_boot/1" do
    test "returns :oban_unavailable instead of raising when Oban never comes up" do
      name = {:sitemap_boot_test, make_ref()}

      assert SchedulerWorker.ensure_scheduled_on_boot(
               oban: name,
               enabled?: true,
               timeout: 30,
               interval: 10
             ) == :oban_unavailable
    end

    test "returns :disabled at once, without waiting for Oban, when scheduling is off" do
      name = {:sitemap_boot_test, make_ref()}
      started = System.monotonic_time(:millisecond)

      assert SchedulerWorker.ensure_scheduled_on_boot(
               oban: name,
               enabled?: false,
               timeout: 5_000,
               interval: 10
             ) == :disabled

      assert System.monotonic_time(:millisecond) - started < 2_000
    end
  end
end
