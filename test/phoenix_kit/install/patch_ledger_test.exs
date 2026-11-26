defmodule PhoenixKit.Install.PatchLedgerTest do
  # Process-dictionary run state, the current directory and temp files.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.PhoenixKit.Update
  alias PhoenixKit.Install.JsIntegration
  alias PhoenixKit.Install.ObanConfig
  alias PhoenixKit.Install.PatchLedger

  setup do
    root = Path.join(System.tmp_dir!(), "pk_ledger_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      PatchLedger.abandon()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp ledger_file(root), do: Path.join(root, PatchLedger.file_name())

  describe "decision/4 (no ledger = as before)" do
    test "absent and never recorded → applied, exactly as an update always did" do
      assert PatchLedger.decision("module_js_seed", false, "", nil) == :apply
    end

    test "present → recorded as applied" do
      assert PatchLedger.decision("module_js_seed", true, "", nil) == :present
    end

    test "recorded as applied and now absent → declined as removed, not re-added", %{root: root} do
      PatchLedger.save(%{patches: %{"module_js_seed" => :applied}}, root)
      PatchLedger.begin([], root)

      assert PatchLedger.decide("module_js_seed", false, "") == {:declined, :removed}
    end

    test "recorded as declined stays out", %{root: root} do
      PatchLedger.save(%{patches: %{"daisyui_themes" => :declined}}, root)
      PatchLedger.begin([], root)

      assert PatchLedger.decide("daisyui_themes", false, "") == {:declined, :ledger}
    end

    test "--repair-patch applies a removed one again", %{root: root} do
      PatchLedger.save(%{patches: %{"module_js_seed" => :applied}}, root)
      PatchLedger.begin([repair_patch: "module_js_seed"], root)

      assert PatchLedger.decide("module_js_seed", false, "") == :apply
    end

    test "--skip-patch declines, also when present (nothing is removed)", %{root: root} do
      PatchLedger.begin([skip_patch: "css_sources_import"], root)

      assert PatchLedger.decide("css_sources_import", true, "") == {:declined, :flag}
      assert PatchLedger.decide("css_sources_import", false, "") == {:declined, :flag}
    end

    test "a group flag or ledger entry covers its members", %{root: root} do
      PatchLedger.save(%{patches: %{"oban_queues" => :declined}}, root)
      PatchLedger.begin([], root)
      assert PatchLedger.decide("oban_queues:posts", false, "") == {:declined, :ledger}

      PatchLedger.begin([skip_patch: "oban_queues"], root)
      assert PatchLedger.decide("oban_queues:sitemap", false, "") == {:declined, :flag}
    end

    test "inline markers in Elixir, HEEx and CSS comments" do
      assert PatchLedger.marker?("# phoenix_kit:skip oban_queues:posts\n", "oban_queues:posts")
      assert PatchLedger.marker?("<%!-- phoenix_kit:skip module_js_seed --%>", "module_js_seed")
      assert PatchLedger.marker?("/* phoenix_kit:skip daisyui_themes */", "daisyui_themes")
      # the group marker covers a member; a member marker is not another member
      assert PatchLedger.marker?("# phoenix_kit:skip oban_queues", "oban_queues:posts")
      refute PatchLedger.marker?("# phoenix_kit:skip oban_queues:posts", "oban_queues:post")
      refute PatchLedger.marker?("# phoenix_kit:skip oban_queues:posts", "oban_queues:sitemap")
      refute PatchLedger.marker?(nil, "module_js_seed")
    end
  end

  describe "flags" do
    test "an unknown ID is refused, naming the known ones" do
      assert_raise Mix.Error, ~r/Unknown patch ID "nope".*module_js_seed/s, fn ->
        PatchLedger.validate_ids!(["nope"])
      end
    end

    test "security-relevant and required edits are not declinable" do
      for id <- ["body_guard", "oban_config", "ueberauth"] do
        assert_raise Mix.Error, ~r/cannot be\s+declined/, fn ->
          PatchLedger.validate_ids!([id])
        end
      end
    end

    test "both option parsers declare the switches as repeatable" do
      %Igniter.Mix.Task.Info{schema: schema} = Update.info([], nil)
      assert schema[:skip_patch] == :keep
      assert schema[:repair_patch] == :keep

      [_, switches] =
        Regex.run(
          ~r/OptionParser\.parse\(argv,\s*switches:\s*\[(.*?)\]\s*,\s*aliases/s,
          File.read!("lib/mix/tasks/phoenix_kit.update.ex")
        )

      assert switches =~ "skip_patch: :keep"
      assert switches =~ "repair_patch: :keep"
    end

    test "--help documents them and the ledger" do
      help = capture_io(fn -> Update.run(["--help"]) end)
      assert help =~ "--skip-patch"
      assert help =~ "--repair-patch"
      assert help =~ ".phoenix_kit.exs"
    end
  end

  describe "the file" do
    test "round-trips and is a commented literal map", %{root: root} do
      ledger = %{patches: %{"a" => :applied}, daisyui_notice: %{kit: "3.0.0", daisyui: "5.5.20"}}
      PatchLedger.save(ledger, root)

      assert File.read!(ledger_file(root)) =~ "# PhoenixKit's record"
      assert PatchLedger.load(root) == ledger
    end

    test "a file that is not a literal map is refused, not guessed", %{root: root} do
      File.write!(ledger_file(root), "System.halt()")
      assert_raise Mix.Error, ~r/not a literal Elixir map/, fn -> PatchLedger.load(root) end
    end

    test "the first run records what is present; a run with nothing new writes nothing",
         %{root: root} do
      PatchLedger.begin([], root)
      assert PatchLedger.decide("module_js_seed", true, "") == :present
      PatchLedger.flush()
      assert PatchLedger.load(root).patches == %{"module_js_seed" => :applied}

      File.write!(ledger_file(root), File.read!(ledger_file(root)) <> "\n# hand edit\n")
      PatchLedger.begin([], root)
      assert PatchLedger.decide("module_js_seed", true, "") == :present
      PatchLedger.flush()
      assert File.read!(ledger_file(root)) =~ "# hand edit"
    end

    test "nothing is recorded or written without a run (the installer, unit callers)",
         %{root: root} do
      refute PatchLedger.active?()
      assert PatchLedger.decide("module_js_seed", false, "") == :apply
      PatchLedger.flush()
      refute File.exists?(ledger_file(root))
    end

    test "the summary names each removed patch with its repair flag", %{root: root} do
      PatchLedger.save(%{patches: %{"css_sources_import" => :applied}}, root)
      PatchLedger.begin([], root)
      PatchLedger.decide("css_sources_import", false, "")

      assert PatchLedger.summary() =~ "--repair-patch css_sources_import"
    end
  end

  describe "Oban queues" do
    @host """
    config :my_app, Oban,
      repo: MyApp.Repo,
      queues: [default: 10]
    """

    @declared [
      %{name: :default, limit: 10, kind: nil, owner: :core},
      %{name: :sitemap, limit: 5, kind: :batch, owner: :core}
    ]

    test "without a ledger a missing queue is added, as before" do
      out =
        capture_io(fn ->
          send(self(), {:result, ObanConfig.ensure_declared_queues(@host, "my_app", @declared)})
        end)

      assert_received {:result, updated}
      assert updated =~ "sitemap: 5"
      assert out =~ "Adding sitemap queue"
    end

    test "a queue removed after an earlier update is not added back", %{root: root} do
      PatchLedger.save(%{patches: %{"oban_queues:sitemap" => :applied}}, root)
      PatchLedger.begin([], root)

      out =
        capture_io(fn ->
          send(self(), {:result, ObanConfig.ensure_declared_queues(@host, "my_app", @declared)})
        end)

      assert_received {:result, unchanged}
      assert unchanged == @host
      assert out =~ "Left out the sitemap queue"
      assert out =~ "--repair-patch oban_queues:sitemap"
    end

    test "an inline marker in config.exs declines one queue" do
      content = "# phoenix_kit:skip oban_queues:sitemap\n" <> @host

      capture_io(fn ->
        send(self(), {:result, ObanConfig.ensure_declared_queues(content, "my_app", @declared)})
      end)

      assert_received {:result, ^content}
    end

    test "an added queue is recorded once config.exs on disk has it", %{root: root} do
      File.mkdir_p!(Path.join(root, "config"))
      PatchLedger.begin([], root)

      capture_io(fn ->
        send(self(), {:updated, ObanConfig.ensure_declared_queues(@host, "my_app", @declared)})
      end)

      assert_received {:updated, updated}
      File.write!(Path.join(root, "config/config.exs"), updated)
      File.cd!(root, &PatchLedger.flush/0)

      assert PatchLedger.load(root).patches == %{
               "oban_queues:default" => :applied,
               "oban_queues:sitemap" => :applied
             }
    end

    # Igniter keeps the edit in its buffer until the run's changes are
    # accepted. Declined there, the queue never reached the file, and
    # recording it as applied would make the next run treat it as removed.
    test "an added queue whose edit never reached the disk is not recorded", %{root: root} do
      File.mkdir_p!(Path.join(root, "config"))
      File.write!(Path.join(root, "config/config.exs"), @host)
      PatchLedger.begin([], root)
      capture_io(fn -> ObanConfig.ensure_declared_queues(@host, "my_app", @declared) end)
      File.cd!(root, &PatchLedger.flush/0)

      assert PatchLedger.load(root).patches == %{"oban_queues:default" => :applied}
    end

    test "only installed packages' fallback queues are generated or added" do
      lines = ObanConfig.generated_queue_lines()
      # core's own queues are always there
      assert lines =~ "file_processing:"

      for {queue, app} <- [
            posts: :phoenix_kit_posts,
            newsletters_delivery: :phoenix_kit_newsletters,
            catalogue_pdf: :phoenix_kit_catalogue,
            shop_imports: :phoenix_kit_ecommerce
          ] do
        installed? = match?(:ok, Application.load(app)) or Application.spec(app) != nil
        assert lines =~ "#{queue}:" == installed?, "#{queue} vs #{app} installed=#{installed?}"
      end
    end
  end

  describe "module_js_seed" do
    @layout "lib/phoenix_kit_web/components/layouts/root.html.heex"

    @layout_content """
    <html>
      <head>
        <script src="/assets/vendor/phoenix_kit.js"></script>
        <script defer src={~p"/assets/js/app.js"}></script>
      </head>
    </html>
    """

    defp project(root, layout \\ @layout_content) do
      File.mkdir_p!(Path.join(root, Path.dirname(@layout)))
      File.write!(Path.join(root, @layout), layout)
    end

    defp run_splice(root) do
      File.cd!(root, fn ->
        JsIntegration.ensure_module_js_integration(%{
          Igniter.new()
          | args: %Igniter.Mix.Task.Args{argv: []}
        })
      end)
    end

    test "first run: added as before and recorded", %{root: root} do
      project(root)
      PatchLedger.begin([], root)
      run_splice(root)
      PatchLedger.flush()

      assert File.read!(Path.join(root, @layout)) =~ "phoenix_kit_modules.js"
      assert PatchLedger.load(root).patches["module_js_seed"] == :applied
    end

    test "removed after that: left out, with a notice", %{root: root} do
      project(root)
      PatchLedger.save(%{patches: %{"module_js_seed" => :applied}}, root)
      PatchLedger.begin([], root)
      igniter = run_splice(root)

      assert File.read!(Path.join(root, @layout)) == @layout_content
      refute File.exists?(Path.join(root, "priv/static/assets/vendor/phoenix_kit_modules.js"))
      assert Enum.any?(igniter.notices, &(&1 =~ "--repair-patch module_js_seed"))
    end

    test "the HEEx marker declines it", %{root: root} do
      layout =
        String.replace(
          @layout_content,
          "<head>",
          "<head>\n<%!-- phoenix_kit:skip module_js_seed --%>"
        )

      project(root, layout)
      run_splice(root)

      assert File.read!(Path.join(root, @layout)) == layout
    end
  end

  describe "app.css patches" do
    @css """
    @source "../../deps/phoenix_kit";
    @plugin "../vendor/daisyui" {
      themes: false;
    }
    """

    test "no ledger: themes switched on and the import added, as before" do
      out =
        capture_io(fn ->
          css =
            @css
            |> Update.enable_daisyui_themes("app.css")
            |> Update.add_css_sources_import("app.css")

          send(self(), {:css, css})
        end)

      assert_received {:css, css}
      assert css =~ "themes: all"
      assert css =~ ~s|@import "./_phoenix_kit_sources.css";|
      assert out =~ "enable all themes"
    end

    test "themes turned off again after an update stay off", %{root: root} do
      PatchLedger.save(%{patches: %{"daisyui_themes" => :applied}}, root)
      PatchLedger.begin([], root)

      capture_io(fn -> send(self(), {:css, Update.enable_daisyui_themes(@css, "app.css")}) end)
      assert_received {:css, @css}
    end

    test "the CSS marker declines the import" do
      css = "/* phoenix_kit:skip css_sources_import */\n" <> @css
      capture_io(fn -> send(self(), {:css, Update.add_css_sources_import(css, "app.css")}) end)
      assert_received {:css, ^css}
    end
  end
end
