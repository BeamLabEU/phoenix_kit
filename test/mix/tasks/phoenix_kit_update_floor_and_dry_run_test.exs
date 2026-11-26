defmodule Mix.Tasks.PhoenixKit.Update.FloorAndDryRunTest do
  @moduledoc """
  The second pass of `mix phoenix_kit.update` (`full_update/2`) in the order
  that keeps a refused or previewed run from touching the host:

    * a database below this release's floor is refused BEFORE the Igniter
      pass (config.exs, application.ex, the root layout) and before the
      post-Igniter steps (CSS, vendored JS, migration files). The designer
      box's run at V220 edited config.exs and wrote 13 module migrations
      first, then stopped — and wrote a second set after the bridge.
    * `--dry-run` runs Igniter's preview and skips every step that writes
      outside Igniter.

  The JS splices that write the root layout and `app.js` straight to disk
  are checked against a real temp directory: under `--dry-run` they leave
  every file as it was.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.PhoenixKit.Update
  alias PhoenixKit.Install.IgniterHelpers
  alias PhoenixKit.Install.JsIntegration
  alias PhoenixKit.Migrations.Postgres, as: MigrationsPostgres

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "pk_update_floor_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  # Each step reports itself; the Igniter and finish steps also write a file,
  # standing in for the writes the real ones make.
  defp steps(test_pid, tmp_dir, status) do
    %{
      start_app: fn -> send(test_pid, {:step, :start_app}) end,
      installation_status: fn prefix ->
        send(test_pid, {:step, {:status, prefix}})
        status
      end,
      igniter: fn ->
        send(test_pid, {:step, :igniter})
        File.write!(Path.join(tmp_dir, "config.exs"), "edited")
        :changes_made
      end,
      finish: fn _opts ->
        send(test_pid, {:step, :finish})
        File.write!(Path.join(tmp_dir, "module_migration.exs"), "written")
      end
    }
  end

  defp steps_run(acc \\ []) do
    receive do
      {:step, name} -> steps_run([name | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "below the floor" do
    test "raises after the database check and before anything is written", %{tmp_dir: tmp_dir} do
      floor = MigrationsPostgres.minimum_version()

      error =
        assert_raise Mix.Error, fn ->
          Update.full_update(
            [prefix: "public"],
            steps(self(), tmp_dir, {:current_version, floor - 1})
          )
        end

      assert error.message =~ "below this release's floor"
      assert error.message =~ MigrationsPostgres.bridge_version()
      assert error.message =~ "Nothing was changed."

      assert steps_run() == [:start_app, {:status, "public"}]
      assert File.ls!(tmp_dir) == []
    end

    test "a dry run below the floor is refused the same way", %{tmp_dir: tmp_dir} do
      floor = MigrationsPostgres.minimum_version()

      assert_raise Mix.Error, ~r/below this release's floor/, fn ->
        Update.full_update(
          [prefix: "public", dry_run: true],
          steps(self(), tmp_dir, {:current_version, floor - 1})
        )
      end

      assert File.ls!(tmp_dir) == []
    end

    test "at the floor the update goes ahead", %{tmp_dir: tmp_dir} do
      floor = MigrationsPostgres.minimum_version()

      assert :changes_made ==
               Update.full_update(
                 [prefix: "public"],
                 steps(self(), tmp_dir, {:current_version, floor})
               )

      assert steps_run() == [:start_app, {:status, "public"}, :igniter, :finish]
    end

    test "a status other than a readable version is left to the Igniter pass",
         %{tmp_dir: tmp_dir} do
      for status <- [{:not_installed}, {:unknown_version}, {:unreachable, :econnrefused}] do
        Update.full_update([prefix: "public"], steps(self(), tmp_dir, status))
        assert [:start_app, _, :igniter, :finish] = steps_run()
      end
    end
  end

  describe "--dry-run" do
    test "runs Igniter's preview and none of the post-Igniter steps", %{tmp_dir: tmp_dir} do
      floor = MigrationsPostgres.minimum_version()
      steps = steps(self(), tmp_dir, {:current_version, floor})
      # The preview itself writes nothing; Igniter is responsible for that.
      test_pid = self()

      steps = %{
        steps
        | igniter: fn ->
            send(test_pid, {:step, :igniter})
            :dry_run_with_changes
          end
      }

      output =
        capture_io(fn ->
          assert :dry_run_with_changes ==
                   Update.full_update([prefix: "public", dry_run: true], steps)
        end)

      assert steps_run() == [:start_app, {:status, "public"}, :igniter]
      assert File.ls!(tmp_dir) == []
      assert output =~ "Dry run (--dry-run): nothing was written"
      assert output =~ "asset rebuild"
    end

    test "--skip-assets drops the asset line from the dry-run report" do
      steps = %{
        start_app: fn -> :ok end,
        installation_status: fn _ -> {:not_installed} end,
        igniter: fn -> :dry_run_with_no_changes end,
        finish: fn _ -> flunk("finish ran in a dry run") end
      }

      output =
        capture_io(fn ->
          Update.full_update([prefix: "public", dry_run: true, skip_assets: true], steps)
        end)

      refute output =~ "asset rebuild"
    end

    test "both option parsers declare the switch" do
      %Igniter.Mix.Task.Info{schema: schema} = Update.info(["--dry-run"], nil)
      assert schema[:dry_run] == :boolean

      source = File.read!("lib/mix/tasks/phoenix_kit.update.ex")

      [_, switches_block] =
        Regex.run(~r/OptionParser\.parse\(argv,\s*switches:\s*\[(.*?)\]\s*,\s*aliases/s, source)

      assert switches_block =~ "dry_run: :boolean"
    end

    test "--help documents it" do
      assert capture_io(fn -> Update.run(["--help"]) end) =~ "--dry-run"
    end
  end

  describe "JS splices that write to disk directly" do
    @layout "lib/phoenix_kit_web/components/layouts/root.html.heex"

    @layout_content """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <title>Probe</title>
        <script defer phx-track-static type="text/javascript" src={~p"/assets/js/app.js"}></script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """

    @app_js """
    const liveSocket = new LiveSocket("/live", Socket, {
      hooks: {...colocatedHooks},
    })
    """

    defp probe_project(tmp_dir) do
      File.mkdir_p!(Path.join(tmp_dir, Path.dirname(@layout)))
      File.write!(Path.join(tmp_dir, @layout), @layout_content)
      File.mkdir_p!(Path.join(tmp_dir, "assets/js"))
      File.write!(Path.join(tmp_dir, "assets/js/app.js"), @app_js)
    end

    defp run_splices(argv) do
      igniter = %{Igniter.new() | args: %Igniter.Mix.Task.Args{argv: argv}}

      igniter
      |> JsIntegration.ensure_module_js_integration()
      |> JsIntegration.ensure_theme_bootstrap()
    end

    test "--dry-run leaves the layout and app.js untouched and seeds nothing",
         %{tmp_dir: tmp_dir} do
      probe_project(tmp_dir)

      igniter = File.cd!(tmp_dir, fn -> run_splices(["--dry-run"]) end)

      assert File.read!(Path.join(tmp_dir, @layout)) == @layout_content
      assert File.read!(Path.join(tmp_dir, "assets/js/app.js")) == @app_js
      refute File.exists?(Path.join(tmp_dir, "priv/static/assets/vendor/phoenix_kit_modules.js"))

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "Dry run: would add the PhoenixKit theme bootstrap")
             )

      assert Enum.any?(igniter.notices, &(&1 =~ "Dry run: would add the module-hooks script tag"))
    end

    test "without --dry-run the same splices do write (the test reaches the write path)",
         %{tmp_dir: tmp_dir} do
      probe_project(tmp_dir)

      igniter = File.cd!(tmp_dir, fn -> run_splices([]) end)

      layout = File.read!(Path.join(tmp_dir, @layout))
      assert layout =~ "ThemeBootstrap.theme_bootstrap"
      assert layout =~ "phoenix_kit_modules.js"
      assert File.exists?(Path.join(tmp_dir, "priv/static/assets/vendor/phoenix_kit_modules.js"))

      # The notice names the marker that keeps the bootstrap out for good.
      added = Enum.find(igniter.notices, &(&1 =~ "Added the PhoenixKit theme bootstrap"))
      assert added =~ JsIntegration.host_managed_marker()

      # ...and the marker does what the notice says.
      with_marker =
        String.replace(
          @layout_content,
          "<title>",
          JsIntegration.host_managed_marker() <> "\n<title>"
        )

      assert JsIntegration.theme_bootstrap_plan(with_marker) == :host_managed
    end

    test "dry_run?/1 reads the flag from argv or options" do
      assert IgniterHelpers.dry_run?(%{
               Igniter.new()
               | args: %Igniter.Mix.Task.Args{argv: ["--dry-run"]}
             })

      assert IgniterHelpers.dry_run?(%{
               Igniter.new()
               | args: %Igniter.Mix.Task.Args{options: [dry_run: true]}
             })

      refute IgniterHelpers.dry_run?(Igniter.new())
    end
  end
end
