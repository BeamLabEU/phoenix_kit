defmodule PhoenixKit.Install.ObanCronInsertionTest do
  # Every list-append the updater does into a host's Oban config
  # (`crontab:`, `plugins:`, `queues:`), against the shapes a host's list
  # actually ends in. The old splices read the tail of the source text for a
  # comma and put it inside a trailing comment.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PhoenixKit.Install.ConfigSplice
  alias PhoenixKit.Install.ConfigVerify
  alias PhoenixKit.Install.ObanConfig

  @posts_worker PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker

  # The last crontab element's tail, as the host wrote it.
  @tails [
    {"nothing", ""},
    {"a trailing comma", ","},
    {"a trailing comma and a comment line", ",\n      # old nightly job, kept for reference"},
    {"an end-of-line comment", " # every minute"},
    {"a comment line after an entry with no comma", "\n      # nothing else runs here"},
    {"a trailing comma and an end-of-line comment", ", # nightly"},
    {"a commented-out entry after an entry with no comma",
     "\n      # {\"0 5 * * *\", MyApp.Workers.Old}"},
    {"a five-line comment after an entry with no comma",
     "\n      # These jobs run on the primary only.\n      # The secondary node has queues: false.\n" <>
       "      # Do not move them without telling ops.\n      # (Reason: the reports hit a read replica.)\n" <>
       "      # Last reviewed in spring."}
  ]

  defp crontab_config(tail, indent \\ "  ") do
    ~s"""
    config :myapp, Oban,
    #{indent}repo: MyApp.Repo,
    #{indent}queues: [default: 10],
    #{indent}plugins: [
    #{indent}  {Oban.Plugins.Pruner, max_age: 60},
    #{indent}  {Oban.Plugins.Cron,
    #{indent}   crontab: [
    #{indent}     {"0 3 * * *", MyApp.Workers.Nightly}#{tail}
    #{indent}   ]}
    #{indent}]
    """
  end

  # `module` is a direct member of `:myapp`'s `crontab:` list.
  defp in_crontab?(content, module) do
    {:ok, ast} = Code.string_to_quoted(content)

    ConfigVerify.app_config_satisfies?(ast, "myapp", Oban, :crontab, fn list ->
      Enum.any?(list, &ConfigVerify.tuple_names_module?(&1, module))
    end)
  end

  defp quiet(fun),
    do:
      capture_io(:stderr, fn -> send(self(), {:result, fun.()}) end)
      |> then(fn _ ->
        receive do
          {:result, r} -> r
        end
      end)

  describe "worker entries (ensure_worker_cron_entries/2)" do
    for {name, tail} <- @tails do
      test "are added after the last element when the crontab ends in #{name}" do
        content = crontab_config(unquote(tail))
        updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

        refute updated == content, "the entries were rolled back instead of added"
        assert {:ok, _} = Code.string_to_quoted(updated)
        refute updated =~ ",,"

        assert in_crontab?(updated, PhoenixKit.Jobs.SweepWorker)
        assert in_crontab?(updated, PhoenixKit.Jobs.PruneWorker)
        assert in_crontab?(updated, PhoenixKit.Users.LoginAttemptsPruneWorker)
        assert in_crontab?(updated, PhoenixKit.Modules.Storage.Workers.BucketLogPruneWorker)
        assert in_crontab?(updated, MyApp.Workers.Nightly)

        # What the host wrote after its last element is still there, in order.
        assert updated =~ "MyApp.Workers.Nightly}"
        assert tail_comments(unquote(tail)) |> Enum.all?(&String.contains?(updated, &1))
      end
    end
  end

  describe "digest entries (ensure_digest_cron_entries/2)" do
    for {name, tail} <- @tails do
      test "are added when the crontab ends in #{name}" do
        content = crontab_config(unquote(tail))
        updated = quiet(fn -> ObanConfig.ensure_digest_cron_entries(content, "myapp") end)

        refute updated == content, "the entries were rolled back instead of added"
        assert {:ok, _} = Code.string_to_quoted(updated)

        for cadence <- ~w(hourly 12h daily weekly) do
          assert updated =~ ~s(cadence: "#{cadence}")
        end

        assert tail_comments(unquote(tail)) |> Enum.all?(&String.contains?(updated, &1))
      end
    end
  end

  describe "scheduled posts (ensure_cron_plugin/2, existing Cron plugin)" do
    for {name, tail} <- @tails do
      test "the worker is added when the crontab ends in #{name}" do
        content = crontab_config(unquote(tail))
        updated = quiet(fn -> ObanConfig.ensure_cron_plugin(content, "myapp") end)

        refute updated == content, "the entry was rolled back instead of added"
        assert {:ok, _} = Code.string_to_quoted(updated)
        assert in_crontab?(updated, @posts_worker)
        assert tail_comments(unquote(tail)) |> Enum.all?(&String.contains?(updated, &1))
      end
    end
  end

  describe "the plugins list (ensure_lifeline_plugin/2, ensure_cron_plugin/2 with no Cron plugin)" do
    @plugin_tails [
      {"nothing", ""},
      {"an end-of-line comment", " # prune after 60s"},
      {"a trailing comma and a comment line", ",\n    # more plugins below"},
      {"a comment line after an entry with no comma", "\n    # Cron goes here later"}
    ]

    defp plugins_config(tail) do
      """
      config :myapp, Oban,
        repo: MyApp.Repo,
        plugins: [
          {Oban.Plugins.Pruner, max_age: 60}#{tail}
        ]
      """
    end

    for {name, tail} <- @plugin_tails do
      test "Lifeline is added when the list ends in #{name}" do
        content = plugins_config(unquote(tail))
        updated = quiet(fn -> ObanConfig.ensure_lifeline_plugin(content, "myapp") end)

        refute updated == content
        assert {:ok, _} = Code.string_to_quoted(updated)
        assert updated =~ "Oban.Plugins.Lifeline"
      end

      test "the Cron plugin is added when the list ends in #{name}" do
        content = plugins_config(unquote(tail))
        updated = quiet(fn -> ObanConfig.ensure_cron_plugin(content, "myapp") end)

        refute updated == content
        assert {:ok, _} = Code.string_to_quoted(updated)
        assert in_crontab?(updated, @posts_worker)
      end
    end
  end

  describe "the queues list (ensure_queue/4)" do
    @queue_tails [
      {"nothing", ""},
      {"an end-of-line comment", " # the main queue"},
      {"a comment line after an entry with no comma", "\n    # keep small"},
      {"a trailing comma", ","},
      {"a five-line comment", "\n    # a\n    # b\n    # c\n    # d\n    # e"}
    ]

    for {name, tail} <- @queue_tails do
      test "a queue is added when the list ends in #{name}" do
        content = """
        config :myapp, Oban,
          repo: MyApp.Repo,
          queues: [
            # the busy one
            default: 10, # between entries
            mailers: 20#{unquote(tail)}
          ]
        """

        updated = quiet(fn -> ObanConfig.ensure_queue(content, "myapp", "media", 3) end)

        refute updated == content
        assert {:ok, ast} = Code.string_to_quoted(updated)

        assert ConfigVerify.keyword_list_satisfies?(ast, :queues, fn list ->
                 {:media, 3} in list
               end)

        assert updated =~ "# the busy one"
        assert updated =~ "# between entries"
      end
    end

    test "an empty queues list is left as it is (Oban reads [] as: run none)" do
      content = "config :myapp, Oban,\n  queues: [\n  ]\n"

      err =
        capture_io(:stderr, fn ->
          send(self(), {:r, ObanConfig.ensure_queue(content, "myapp", "media", 3)})
        end)

      assert_received {:r, ^content}
      assert err =~ "run none"
    end
  end

  describe "the shape found on a real host" do
    # Literal config.exs block; queues with comments between lines; plugins
    # Pruner + Lifeline + Cron; seven crontab tuples (some with args:), a
    # comment between them, no comma after the last one, then a five-line
    # comment and the `]` at the indent of `crontab:`.
    @real_host """
    import Config

    config :myapp, Oban,
      repo: MyApp.Repo,
      queues: [
        # default work
        default: 10,
        # outbound mail
        mailers: 5
        # NOTE: do not raise
        # without asking ops
      ],
      plugins: [
        {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30},
        {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)},
        {Oban.Plugins.Cron,
         crontab: [
           # reports
           {"0 1 * * *", MyApp.Reports.Daily},
           {"0 2 * * *", MyApp.Reports.Weekly, args: %{kind: "weekly"}},
           {"0 3 * * *", MyApp.Cleanup},
           # mail
           {"*/10 * * * *", MyApp.Mail.Flush, args: %{batch: 50}},
           {"0 4 * * *", MyApp.Sync, queue: :default},
           {"15 4 * * *", MyApp.Sync.Prices, args: %{tags: ["a", "b"]}},
           {"0 5 * * *", MyApp.Archive}
           # These jobs run on the primary node only.
           # The secondary node runs with queues: false.
           # Do not move them without telling ops.
           # (Reason: the reports read from a replica.)
           # Last reviewed in spring.
         ]}
      ]
    """

    test "worker entries land" do
      updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(@real_host, "myapp") end)

      refute updated == @real_host
      assert {:ok, _} = Code.string_to_quoted(updated)
      assert in_crontab?(updated, PhoenixKit.Jobs.SweepWorker)
      assert in_crontab?(updated, PhoenixKit.Users.LoginAttemptsPruneWorker)
      # Entries sit between the last tuple and the host's closing comment.
      assert updated =~ ~r/MyApp\.Archive\},\n\s+\{"[^"]+", PhoenixKit/
      assert updated =~ "# Last reviewed in spring."
    end

    test "digest entries land" do
      updated = quiet(fn -> ObanConfig.ensure_digest_cron_entries(@real_host, "myapp") end)

      refute updated == @real_host
      assert {:ok, _} = Code.string_to_quoted(updated)
      assert updated =~ ~s(cadence: "weekly")
    end

    test "the scheduled-posts worker lands" do
      updated = quiet(fn -> ObanConfig.ensure_cron_plugin(@real_host, "myapp") end)

      refute updated == @real_host
      assert {:ok, _} = Code.string_to_quoted(updated)
      assert in_crontab?(updated, @posts_worker)
    end

    test "a queue lands, after the last queue and before the host's closing comment" do
      updated = quiet(fn -> ObanConfig.ensure_queue(@real_host, "myapp", "media", 3) end)

      refute updated == @real_host
      assert {:ok, ast} = Code.string_to_quoted(updated)

      assert ConfigVerify.keyword_list_satisfies?(ast, :queues, fn list ->
               {:media, 3} in list
             end)

      assert updated =~ ~r/mailers: 5,\n\s+media: 3\n\s+# NOTE: do not raise/
    end

    test "running every step in sequence converges, and a second run changes nothing" do
      run = fn content ->
        quiet(fn ->
          content
          |> ObanConfig.ensure_queue("myapp", "media", 3)
          |> ObanConfig.ensure_cron_plugin("myapp")
          |> ObanConfig.ensure_digest_cron_entries("myapp")
          |> ObanConfig.ensure_worker_cron_entries("myapp")
        end)
      end

      once = run.(@real_host)
      assert {:ok, _} = Code.string_to_quoted(once)
      assert run.(once) == once
    end
  end

  describe "other crontab forms" do
    test "an empty crontab: []" do
      content = "config :myapp, Oban,\n  plugins: [\n    {Oban.Plugins.Cron, crontab: []}\n  ]\n"
      updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      assert {:ok, _} = Code.string_to_quoted(updated)
      assert in_crontab?(updated, PhoenixKit.Jobs.SweepWorker)
    end

    test "an empty crontab holding only a comment" do
      content = """
      config :myapp, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             # nothing scheduled yet
           ]}
        ]
      """

      updated = quiet(fn -> ObanConfig.ensure_cron_plugin(content, "myapp") end)

      assert {:ok, _} = Code.string_to_quoted(updated)
      assert in_crontab?(updated, @posts_worker)
      assert updated =~ "# nothing scheduled yet"
    end

    test "an empty crontab spread over two lines" do
      content =
        "config :myapp, Oban,\n  plugins: [\n    {Oban.Plugins.Cron,\n     crontab: [\n     ]}\n  ]\n"

      updated = quiet(fn -> ObanConfig.ensure_digest_cron_entries(content, "myapp") end)

      assert {:ok, _} = Code.string_to_quoted(updated)
      assert updated =~ ~s(cadence: "daily")
    end

    test "a crontab on one line" do
      content =
        "config :myapp, Oban,\n  plugins: [\n    {Oban.Plugins.Cron, crontab: [{\"0 3 * * *\", MyApp.Nightly}]}\n  ]\n"

      updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      assert {:ok, _} = Code.string_to_quoted(updated)
      assert in_crontab?(updated, MyApp.Nightly)
      assert in_crontab?(updated, PhoenixKit.Jobs.SweepWorker)
    end

    test "a multi-line existing entry" do
      content = """
      config :myapp, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"0 3 * * *", MyApp.Nightly,
              args: %{
                kind: "full",
                tags: ["a", "b"]
              },
              queue: :default}
           ]}
        ]
      """

      for fun <- [
            &ObanConfig.ensure_worker_cron_entries/2,
            &ObanConfig.ensure_digest_cron_entries/2,
            &ObanConfig.ensure_cron_plugin/2
          ] do
        updated = quiet(fn -> fun.(content, "myapp") end)
        refute updated == content
        assert {:ok, _} = Code.string_to_quoted(updated)
        assert in_crontab?(updated, MyApp.Nightly)
      end
    end

    test "tab-indented config" do
      content = crontab_config(" # tab form", "\t")

      for fun <- [
            &ObanConfig.ensure_worker_cron_entries/2,
            &ObanConfig.ensure_digest_cron_entries/2,
            &ObanConfig.ensure_cron_plugin/2
          ] do
        updated = quiet(fn -> fun.(content, "myapp") end)
        refute updated == content
        assert {:ok, _} = Code.string_to_quoted(updated)
        # New lines use the host's tab, not spaces.
        refute updated =~ ~r/\n {2,}\{"/
      end
    end

    test "four-space indented config" do
      content = crontab_config("", "    ")
      updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      assert {:ok, _} = Code.string_to_quoted(updated)
      assert in_crontab?(updated, PhoenixKit.Jobs.SweepWorker)
    end

    test "a `]` and a `#` inside a string or a comment of the list do not move the splice" do
      content = """
      config :myapp, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             # historically took a priority list, e.g. [1, 2] - removed
             {"0 3 * * *", MyApp.Nightly, args: %{note: "see [x] # not a comment"}}
           ]}
        ]
      """

      for fun <- [
            &ObanConfig.ensure_worker_cron_entries/2,
            &ObanConfig.ensure_digest_cron_entries/2,
            &ObanConfig.ensure_cron_plugin/2
          ] do
        updated = quiet(fn -> fun.(content, "myapp") end)
        refute updated == content
        assert {:ok, _} = Code.string_to_quoted(updated)
      end
    end

    test "a crontab outside this app's Oban block is not touched" do
      neighbour = """
      config :some_lib,
        crontab: [
          {"* * * * *", SomeLib.Worker} # theirs
        ]

      """

      content = neighbour <> "config :myapp, Oban,\n  repo: MyApp.Repo\n"

      for fun <- [
            &ObanConfig.ensure_worker_cron_entries/2,
            &ObanConfig.ensure_digest_cron_entries/2,
            &ObanConfig.ensure_cron_plugin/2
          ] do
        capture_io(:stderr, fn -> send(self(), {:r, fun.(content, "myapp")}) end)
        assert_received {:r, result}
        assert String.starts_with?(result, neighbour)
        # There is nothing literal to extend in :myapp's block: left as it was.
        assert result =~ "repo: MyApp.Repo"
      end
    end

    test "a neighbour's crontab BEFORE this app's block does not receive the entries" do
      content =
        """
        config :some_lib,
          crontab: [
            {"* * * * *", SomeLib.Worker} # theirs
          ]

        """ <> crontab_config(" # ours")

      updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      [theirs | _] = String.split(updated, "config :myapp")
      refute theirs =~ "SweepWorker"
      assert updated =~ "SweepWorker"
      assert {:ok, _} = Code.string_to_quoted(updated)
    end
  end

  describe "forms the updater cannot take — content untouched, the reason said" do
    @refused [
      {"a module attribute", "@crontab", "not a literal list"},
      {"a variable", "crontab", "not a literal list"},
      {"a function call", "crontab()", "not a literal list"},
      {"a list combined with ++", "[{\"0 3 * * *\", MyApp.Nightly}] ++ extra_jobs()",
       "combined with another expression"}
    ]

    for {name, value, reason} <- @refused do
      test "crontab from #{name}" do
        content =
          "config :myapp, Oban,\n  plugins: [\n    {Oban.Plugins.Cron, crontab: #{unquote(value)}}\n  ]\n"

        for fun <- [
              &ObanConfig.ensure_worker_cron_entries/2,
              &ObanConfig.ensure_digest_cron_entries/2,
              &ObanConfig.ensure_cron_plugin/2
            ] do
          err =
            capture_io(:stderr, fn ->
              send(self(), {:r, fun.(content, "myapp")})
            end)

          assert_received {:r, result}
          assert result == content
          assert err =~ unquote(reason)
          assert err =~ "Please manually add"
        end
      end
    end

    test "no Oban block in config.exs (it lives in runtime.exs)" do
      content = "import Config\n\nconfig :myapp, MyApp.Repo, pool_size: 10\n"

      err =
        capture_io(:stderr, fn ->
          send(self(), {:r, ObanConfig.ensure_worker_cron_entries(content, "myapp")})
        end)

      assert_received {:r, ^content}
      assert err =~ "runtime.exs"
    end
  end

  describe "declining an entry" do
    test "a commented-out worker entry is not offered again, and the run says so" do
      content =
        crontab_config(",\n      # {\"30 4 * * *\", PhoenixKit.Users.Referrals.PruneWorker}")

      out =
        capture_io(fn ->
          send(self(), {:r, ObanConfig.ensure_worker_cron_entries(content, "myapp")})
        end)

      assert_received {:r, updated}
      assert {:ok, _} = Code.string_to_quoted(updated)
      refute in_crontab?(updated, PhoenixKit.Users.Referrals.PruneWorker)
      assert out =~ "Referrals.PruneWorker"
      assert out =~ "commented out"
      # The others were still added.
      assert in_crontab?(updated, PhoenixKit.Jobs.SweepWorker)
    end

    test "a failed insertion names the way to decline" do
      content = "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: @crontab}]\n"

      err =
        capture_io(:stderr, fn ->
          send(self(), {:r, ObanConfig.ensure_worker_cron_entries(content, "myapp")})
        end)

      assert err =~ "decline"
      assert err =~ "comment"
    end

    test "a commented-out digest cadence is declined" do
      content =
        crontab_config(~S(,
      # {"0 6 * * 1", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "weekly"}}))

      updated = quiet(fn -> ObanConfig.ensure_digest_cron_entries(content, "myapp") end)

      refute updated =~ ~r/^\s+\{"0 6 \* \* 1"/m
      assert updated =~ ~s(cadence: "daily")
    end
  end

  describe "manual steps are remembered for the closing summary" do
    test "every refusal is recorded once, and take_manual_steps/0 hands them over and forgets them" do
      ObanConfig.take_manual_steps()
      content = "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: @crontab}]\n"

      quiet(fn ->
        content
        |> ObanConfig.ensure_worker_cron_entries("myapp")
        |> ObanConfig.ensure_digest_cron_entries("myapp")
      end)

      steps = ObanConfig.take_manual_steps()
      assert [{worker_headline, worker_lines}, {digest_headline, _}] = steps
      assert worker_headline =~ "worker cron entries"
      assert digest_headline =~ "digest cron entries"
      assert Enum.any?(worker_lines, &(&1 =~ "PhoenixKit.Jobs.SweepWorker"))
      assert ObanConfig.take_manual_steps() == []
    end

    test "the same refusal on a second pass is listed once" do
      ObanConfig.take_manual_steps()
      content = "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: @crontab}]\n"

      quiet(fn ->
        ObanConfig.ensure_worker_cron_entries(content, "myapp")
        ObanConfig.ensure_worker_cron_entries(content, "myapp")
      end)

      assert [_one] = ObanConfig.take_manual_steps()
    end

    test "the closing summary lists every step and says how to decline" do
      ObanConfig.take_manual_steps()
      content = "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: @crontab}]\n"
      quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      summary = ObanConfig.manual_steps_summary(ObanConfig.take_manual_steps())

      assert summary =~ "Manual steps needed"
      assert summary =~ "1. Could not add worker cron entries for :myapp"
      assert summary =~ ~s({"*/5 * * * *", PhoenixKit.Jobs.SweepWorker})
      assert summary =~ "decline"
      assert ObanConfig.manual_steps_summary([]) == ""
    end

    test "a clean run records nothing" do
      ObanConfig.take_manual_steps()
      quiet(fn -> ObanConfig.ensure_worker_cron_entries(crontab_config(""), "myapp") end)
      assert ObanConfig.take_manual_steps() == []
    end
  end

  describe "ConfigSplice.mask/2" do
    test "keeps byte length and newlines, blanks comments" do
      src = "a = 1 # note ü\nb = 2\n"
      masked = ConfigSplice.mask(src)

      assert byte_size(masked) == byte_size(src)
      assert masked =~ "a = 1"
      refute masked =~ "note"
      assert length(String.split(masked, "\n")) == length(String.split(src, "\n"))
    end

    test "a # inside a string is not a comment; with strings: true its body is blanked" do
      src = ~s(x = "see [x] # y" # real comment\n)

      assert ConfigSplice.mask(src) =~ ~s("see [x] # y")
      refute ConfigSplice.mask(src) =~ "real comment"

      strict = ConfigSplice.mask(src, strings: true)
      refute strict =~ "[x]"
      assert byte_size(strict) == byte_size(src)
    end

    test "sigils, heredocs and character literals" do
      src =
        Enum.join(
          ["a = ~w(x # y)", "b = ?#", ~S(c = """), "in # here [", ~S("""), "d = 1 # gone", ""],
          "\n"
        )

      masked = ConfigSplice.mask(src, strings: true)

      assert byte_size(masked) == byte_size(src)
      refute masked =~ "gone"
      refute masked =~ "in # here"
      assert masked =~ "d = 1"
    end

    test "declined?/2 tells a commented-out module from an active one" do
      assert ConfigSplice.declined?("# {\"x\", Foo.Worker}\n", "Foo.Worker")
      refute ConfigSplice.declined?("{\"x\", Foo.Worker} # still on\n", "Foo.Worker")
      refute ConfigSplice.declined?("nothing\n", "Foo.Worker")
    end
  end

  # --- second round: masker forms, scoping, reasons, CRLF ---------------------

  # Everything the host wrote is still there: with the PhoenixKit-added tuples
  # removed from every list, the AST equals the original's.
  defp host_preserved?(original, updated) do
    strip = fn content ->
      {:ok, ast} = Code.string_to_quoted(content)

      ast
      |> Macro.prewalk(fn
        {form, _meta, args} -> {form, [], args}
        other -> other
      end)
      |> Macro.prewalk(fn
        list when is_list(list) -> Enum.reject(list, &phoenix_kit_tuple?/1)
        other -> other
      end)
    end

    strip.(original) == strip.(updated)
  end

  # A crontab tuple `{"cron", PhoenixKit.Some.Worker}` or `{"cron", PhoenixKit.W, opts}`.
  defp phoenix_kit_tuple?({cron, {:__aliases__, _, [:PhoenixKit | _]}}) when is_binary(cron),
    do: true

  defp phoenix_kit_tuple?({:{}, _, [cron, {:__aliases__, _, [:PhoenixKit | _]} | _]})
       when is_binary(cron),
       do: true

  defp phoenix_kit_tuple?(_), do: false

  defp crontab_around(lines, before \\ "") do
    before <>
      "config :myapp, Oban,\n  plugins: [\n    {Oban.Plugins.Cron,\n     crontab: [\n" <>
      Enum.map_join(lines, "\n", &("       " <> &1)) <> "\n     ]}\n  ]\n"
  end

  describe "the masker on forms that used to corrupt the host's strings" do
    @tricky_last_entries [
      {"?} and ?\\\" together",
       [
         ~S|{"0 2 * * *", MyApp.A4, args: %{c: ?}}},|,
         ~S|{"0 2 * * *", MyApp.A1, args: %{c: ?\"}}, # "x"|,
         ~S|{"0 2 * * *", MyApp.W20, args: %{s: "ü ]"}}, # "x"|,
         ~S|{"0 2 * * *", MyApp.W6, args: %{note: "#{inspect([1, 2])} # x ]"}},|
       ]},
      {"?\\\" then a comment holding a quote",
       [
         ~S|{"0 2 * * *", MyApp.A1, args: %{c: ?\"}}, # "x"|,
         ~S|{"0 2 * * *", MyApp.W, args: %{note: "abc"}},|
       ]},
      {"?] and ?[", [~S|{"0 2 * * *", MyApp.D, args: %{open: ?[, close: ?]}},|]},
      {"?# (not a comment)", [~S|{"0 2 * * *", MyApp.E, args: %{sep: ?#, note: "x"}} # tail|]},
      {"?\\\\", [~S|{"0 2 * * *", MyApp.F, args: %{sep: ?\\, other: "y"}}|]},
      {"a nested interpolation with a # in its inner string",
       [~S|{"0 2 * * *", MyApp.B, args: %{n: "a #{"b # c"} d"}}|]},
      {"an interpolation that holds braces",
       [~S|{"0 2 * * *", MyApp.G, args: %{n: "#{inspect(%{a: 1})} ]"}}|]},
      {"a ~s sigil with quotes and a #",
       [~S|{"0 2 * * *", MyApp.S, args: %{t: ~s(a "b" # c)}},|]},
      {"a heredoc sigil whose body holds a mid-line triple quote",
       [~S|{"0 2 * * *", MyApp.A6, args: %{s: ~s"""|, ~S|  x """ y ]|, ~S|  """}}|]},
      {"a ~S sigil with brackets", [~S|{"0 2 * * *", MyApp.S, args: %{t: ~S{a ] # "b" [}}}|]}
    ]

    for {name, lines} <- @tricky_last_entries do
      test "#{name}" do
        content = crontab_around(unquote(lines))
        assert {:ok, _} = Code.string_to_quoted(content)

        for fun <- [
              &ObanConfig.ensure_worker_cron_entries/2,
              &ObanConfig.ensure_digest_cron_entries/2,
              &ObanConfig.ensure_cron_plugin/2
            ] do
          updated = quiet(fn -> fun.(content, "myapp") end)

          refute updated == content, "rolled back instead of added"
          assert {:ok, _} = Code.string_to_quoted(updated)
          assert host_preserved?(content, updated)
        end
      end
    end

    test "a ~S heredoc holding a quote, in ANOTHER config before the Oban block" do
      before = ~S'''
      import Config

      config :myapp, MyAppWeb.Endpoint,
        csp: ~S"""
        default-src 'self'; script-src 'self' "nonce"
        """

      '''

      content = crontab_around([~S|{"0 2 * * *", MyApp.B, args: %{note: "x"}},|], before)
      updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      refute updated == content
      assert String.starts_with?(updated, before)
      assert host_preserved?(content, updated)
    end

    test "a charlist heredoc before the Oban block" do
      before =
        "import Config\n\nconfig :myapp, Other, text: " <>
          "'''\n  it's a \"quote\" # not a comment\n  '''\n\n"

      content = crontab_around([~S|{"0 2 * * *", MyApp.B}|], before)
      updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      refute updated == content
      assert host_preserved?(content, updated)
    end

    test "a splice whose result fails the checks is refused, never half-applied" do
      content = crontab_config(" # tail")
      entries = [~s({"30 4 * * *", PhoenixKit.Users.Referrals.PruneWorker})]

      # The semantic check says the entry did not land where it should.
      assert {:error, why} =
               ObanConfig.append_entries(content, "myapp", :crontab, entries, fn _ast -> false end)

      assert why =~ "wrong place"

      # An entry that does not parse makes the candidate not parse.
      assert {:error, _} =
               ObanConfig.append_entries(content, "myapp", :crontab, ["{"], fn _ast -> true end)

      # And the same call with a passing check lands the entry.
      assert {:ok, updated} =
               ObanConfig.append_entries(content, "myapp", :crontab, entries, fn _ast -> true end)

      assert updated =~ "Referrals.PruneWorker"
    end

    test "preserves_original?/3 accepts the entries only, and rejects a change to the host's own text" do
      original = ~s(config :a, Oban,\n  queues: [x: 1, note: "a # b"]\n)
      entries = ["media: 3"]

      good = ~s(config :a, Oban,\n  queues: [x: 1, note: "a # b",\n    media: 3]\n)
      assert ConfigSplice.preserves_original?(original, good, entries)

      # The comma landed inside the host's string — still parses, still has the entry.
      bad = ~s(config :a, Oban,\n  queues: [x: 1, note: "a ,# b",\n    media: 3]\n)
      refute ConfigSplice.preserves_original?(original, bad, entries)

      refute ConfigSplice.preserves_original?(original, "config :a, Oban, queues: [", entries)
    end
  end

  describe "presence and declining are read from this app's own crontab" do
    test "a comment naming the module elsewhere in the file is not a refusal" do
      content =
        ~s|# TODO add: {"*/5 * * * *", PhoenixKit.Jobs.SweepWorker}\n| <> crontab_config("")

      updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      assert in_crontab?(updated, PhoenixKit.Jobs.SweepWorker)
    end

    test "an entry in ANOTHER app's Oban block is not this app's" do
      other = """
      config :other, Oban,
        plugins: [
          {Oban.Plugins.Cron, crontab: [{"*/5 * * * *", PhoenixKit.Jobs.SweepWorker}]}
        ]

      """

      content = other <> crontab_config("")
      updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      assert in_crontab?(updated, PhoenixKit.Jobs.SweepWorker)
      assert String.starts_with?(updated, other)
    end

    test "a digest entry reformatted over several lines is found, so a second run changes nothing" do
      content = """
      config :myapp, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"0 * * * *", PhoenixKit.Notifications.DigestWorker,
              args: %{cadence: "hourly"}},
             {"0 */12 * * *", PhoenixKit.Notifications.DigestWorker,
              args: %{
                cadence: "12h"
              }},
             {"0 6 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "daily"}},
             {"0 6 * * 1", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "weekly"}}
           ]}
        ]
      """

      assert quiet(fn -> ObanConfig.ensure_digest_cron_entries(content, "myapp") end) == content
    end

    test "one cadence is not credited to another tuple's DigestWorker" do
      content =
        crontab_config(
          ~s|,\n      {"0 * * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "hourly"}}|
        )

      updated = quiet(fn -> ObanConfig.ensure_digest_cron_entries(content, "myapp") end)

      for cadence <- ~w(12h daily weekly) do
        assert updated =~ ~s(cadence: "#{cadence}")
      end

      assert length(String.split(updated, ~s(cadence: "hourly"))) == 2
    end

    test "declined entries are remembered for the closing summary" do
      ObanConfig.take_declined()

      content =
        crontab_config(~S|,
      # {"30 4 * * *", PhoenixKit.Users.Referrals.PruneWorker}|)

      quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)
      declined = ObanConfig.take_declined()

      assert declined == ["PhoenixKit.Users.Referrals.PruneWorker"]
      assert ObanConfig.take_declined() == []

      summary = ObanConfig.manual_steps_summary([], declined)

      assert summary =~
               "Declined (commented out in your crontab), not added: PhoenixKit.Users.Referrals.PruneWorker"

      refute summary =~ "Manual steps needed"
    end
  end

  describe "ensure_cron_plugin/2 reads its cases from this app's own block" do
    test "a ProcessScheduledJobsWorker in another app's block does not count" do
      other = """
      config :other, Oban,
        plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}]}]

      """

      content = other <> crontab_config("")
      updated = quiet(fn -> ObanConfig.ensure_cron_plugin(content, "myapp") end)

      assert in_crontab?(updated, @posts_worker)
    end

    test "both the old and the core worker scheduled is a manual step, not a lost line" do
      ObanConfig.take_manual_steps()

      content =
        crontab_config(~S|,
      {"* * * * *", PhoenixKitPosts.Workers.PublishScheduledPostsJob},
      {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}|)

      err =
        capture_io(:stderr, fn ->
          send(self(), {:r, ObanConfig.ensure_cron_plugin(content, "myapp")})
        end)

      assert_received {:r, ^content}
      assert err =~ "Both PublishScheduledPostsJob and ProcessScheduledJobsWorker"
      assert [{headline, _}] = ObanConfig.take_manual_steps()
      assert headline =~ "Both PublishScheduledPostsJob"
    end
  end

  describe "ensure_pruner_max_age/2 shapes" do
    test "a one-line plugins list" do
      content = "config :myapp, Oban,\n  plugins: [Oban.Plugins.Pruner, Oban.Plugins.Lifeline]\n"
      updated = quiet(fn -> ObanConfig.ensure_pruner_max_age(content, "myapp") end)

      assert {:ok, _} = Code.string_to_quoted(updated)
      assert updated =~ "{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30}, Oban.Plugins.Lifeline"
    end

    test "the tuple form followed by a comma" do
      content =
        "config :myapp, Oban,\n  plugins: [\n    {Oban.Plugins.Pruner},\n    Oban.Plugins.Lifeline\n  ]\n"

      updated = quiet(fn -> ObanConfig.ensure_pruner_max_age(content, "myapp") end)

      refute updated == content
      assert {:ok, _} = Code.string_to_quoted(updated)
    end

    test "a Pruner with other options is left alone" do
      content =
        "config :myapp, Oban,\n  plugins: [\n    {Oban.Plugins.Pruner, interval: 1000}\n  ]\n"

      assert quiet(fn -> ObanConfig.ensure_pruner_max_age(content, "myapp") end) == content
    end

    test "a Pruner in another app's block, or in a comment, is not this app's" do
      other = "config :other, Oban,\n  plugins: [Oban.Plugins.Pruner]\n\n"

      mine =
        "config :myapp, Oban,\n  plugins: [\n    # Oban.Plugins.Pruner,\n    Oban.Plugins.Lifeline\n  ]\n"

      content = other <> mine

      assert quiet(fn -> ObanConfig.ensure_pruner_max_age(content, "myapp") end) == content
    end

    test "only this app's Pruner is rewritten" do
      other = "config :other, Oban,\n  plugins: [Oban.Plugins.Pruner]\n\n"
      mine = "config :myapp, Oban,\n  plugins: [\n    Oban.Plugins.Pruner\n  ]\n"
      updated = quiet(fn -> ObanConfig.ensure_pruner_max_age(other <> mine, "myapp") end)

      assert String.starts_with?(updated, other)
      assert updated =~ "{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30}"
    end
  end

  describe "refusal texts" do
    defp refusal(content, fun \\ &ObanConfig.ensure_worker_cron_entries/2) do
      ObanConfig.take_manual_steps()

      err =
        capture_io(:stderr, fn ->
          out = capture_io(fn -> send(self(), {:r, fun.(content, "myapp")}) end)
          send(self(), {:out, out})
        end)

      assert_received {:r, result}
      assert_received {:out, out}
      {result, err, out, ObanConfig.take_manual_steps()}
    end

    test "a block nested in an expression says so" do
      content =
        "if config_env() == :prod do\n  config :myapp, Oban,\n    plugins: [{Oban.Plugins.Cron, crontab: []}]\nend\n"

      {result, err, _out, [_step]} = refusal(content)

      assert result == content
      assert err =~ "nested in an expression"
      refute err =~ "runtime.exs"
    end

    test "plugins: false is switched off, not a variable" do
      content = "config :myapp, Oban,\n  repo: MyApp.Repo,\n  plugins: false\n"
      {result, err, out, steps} = refusal(content, &ObanConfig.ensure_lifeline_plugin/2)

      assert result == content
      assert steps == []
      refute err =~ "variable"
      assert out =~ "switched off"
    end

    test "config :app, Oban, false is one info line and no manual step" do
      content = "config :myapp, Oban, false\n"

      for fun <- [
            &ObanConfig.ensure_worker_cron_entries/2,
            &ObanConfig.ensure_digest_cron_entries/2,
            &ObanConfig.ensure_cron_plugin/2,
            &ObanConfig.ensure_lifeline_plugin/2
          ] do
        {result, err, out, steps} = refusal(content, fun)

        assert result == content
        assert steps == []
        assert err == ""
        assert out =~ "Oban is disabled"
      end
    end

    test "the combined-list text mentions --" do
      content =
        "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: [{\"* * * * *\", MyApp.W}] -- [x]}]\n"

      {_result, err, _out, _steps} = refusal(content)
      assert err =~ "`--`"
    end
  end

  describe "queues" do
    test "ensure_queue/4 takes the queue as an atom" do
      content = "config :myapp, Oban,\n  queues: [\n    default: 10\n  ]\n"
      updated = quiet(fn -> ObanConfig.ensure_queue(content, "myapp", :media, 3) end)

      assert updated =~ "media: 3"
      assert {:ok, _} = Code.string_to_quoted(updated)
    end

    test "a queue named only in an end-of-line comment is still added" do
      content = "config :myapp, Oban,\n  queues: [\n    default: 10 # was media: 3\n  ]\n"
      updated = quiet(fn -> ObanConfig.ensure_queue(content, "myapp", "media", 3) end)

      refute updated == content
      assert {:ok, ast} = Code.string_to_quoted(updated)
      assert ConfigVerify.keyword_list_satisfies?(ast, :queues, fn l -> {:media, 3} in l end)
    end
  end

  describe "line endings" do
    test "a CRLF file stays CRLF" do
      content =
        String.replace(crontab_config(" # every minute") <> "\n# end\n", "\n", "\r\n")

      for fun <- [
            &ObanConfig.ensure_worker_cron_entries/2,
            &ObanConfig.ensure_digest_cron_entries/2,
            &ObanConfig.ensure_cron_plugin/2
          ] do
        updated = quiet(fn -> fun.(content, "myapp") end)

        refute updated == content
        assert {:ok, _} = Code.string_to_quoted(updated)
        refute updated =~ ~r/(?<!\r)\n/, "a bare LF was written into a CRLF file"
        refute updated =~ "\r\r"
      end
    end

    test "a CRLF queues list stays CRLF" do
      content = "config :myapp, Oban,\r\n  queues: [\r\n    default: 10 # main\r\n  ]\r\n"
      updated = quiet(fn -> ObanConfig.ensure_queue(content, "myapp", "media", 3) end)

      refute updated =~ ~r/(?<!\r)\n/
      assert {:ok, _} = Code.string_to_quoted(updated)
    end
  end

  # The comment text a tail carries, to check it survived the splice.
  defp tail_comments(tail) do
    for line <- String.split(tail, "\n"),
        [_, comment] <- [Regex.run(~r/(#.*)$/, line)],
        do: comment
  end
end
