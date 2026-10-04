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

  describe "a crontab held in a variable" do
    @worker_lines [
      ~S|{"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}|,
      ~S|{"30 4 * * *", PhoenixKit.Users.Referrals.PruneWorker}|,
      ~S|{"45 4 * * *", PhoenixKit.Users.LoginAttemptsPruneWorker}|,
      ~S|{"*/5 * * * *", PhoenixKit.Jobs.SweepWorker}|,
      ~S|{"15 4 * * *", PhoenixKit.Jobs.PruneWorker}|,
      ~S|{"20 4 * * *", PhoenixKit.Modules.Storage.Workers.BucketLogPruneWorker}|
    ]

    @digest_lines [
      ~S|{"0 * * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "hourly"}}|,
      ~S|{"0 */12 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "12h"}}|,
      ~S|{"0 6 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "daily"}}|,
      ~S|{"0 6 * * 1", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "weekly"}}|
    ]

    defp var_config(lines) do
      "some_var = [\n" <>
        Enum.map_join(lines, ",\n", &("  " <> &1)) <>
        "\n]\n\nconfig :myapp, Oban,\n  plugins: [\n    {Oban.Plugins.Cron, crontab: some_var}\n  ]\n"
    end

    defp run_all(content) do
      ObanConfig.take_manual_steps()

      out =
        capture_io(fn ->
          capture_io(:stderr, fn ->
            result =
              content
              |> ObanConfig.ensure_cron_plugin("myapp")
              |> ObanConfig.ensure_digest_cron_entries("myapp")
              |> ObanConfig.ensure_worker_cron_entries("myapp")

            send(self(), {:result, result})
          end)
        end)

      assert_received {:result, result}
      {result, out, ObanConfig.take_manual_steps()}
    end

    test "with every entry in the variable's list: already configured, nothing to do by hand" do
      content = var_config(@worker_lines ++ @digest_lines)
      assert {:ok, _} = Code.string_to_quoted(content)

      {result, out, steps} = run_all(content)

      assert result == content
      assert steps == []
      assert out =~ "not a literal list; not verified"
      refute out =~ "Adding"
    end

    test "each function says so on its own" do
      content = var_config(@worker_lines ++ @digest_lines)

      for fun <- [
            &ObanConfig.ensure_cron_plugin/2,
            &ObanConfig.ensure_digest_cron_entries/2,
            &ObanConfig.ensure_worker_cron_entries/2
          ] do
        ObanConfig.take_manual_steps()

        out =
          capture_io(fn ->
            capture_io(:stderr, fn -> send(self(), {:r, fun.(content, "myapp")}) end)
          end)

        assert_received {:r, ^content}
        assert ObanConfig.take_manual_steps() == []
        assert out =~ "not verified"
      end
    end

    test "with none of them: a manual step for exactly what is missing" do
      content = var_config([~S|{"0 3 * * *", MyApp.Nightly}|])

      {result, _out, steps} = run_all(content)

      assert result == content
      headlines = Enum.map(steps, &elem(&1, 0))
      assert Enum.any?(headlines, &(&1 =~ "ProcessScheduledJobsWorker"))
      assert Enum.any?(headlines, &(&1 =~ "digest cron entries"))
      assert Enum.any?(headlines, &(&1 =~ "worker cron entries"))
    end

    test "with some of them: only the absent ones are listed" do
      content =
        var_config(Enum.take(@worker_lines, 3) ++ Enum.take(@digest_lines, 2))

      {result, _out, steps} = run_all(content)

      assert result == content
      text = steps |> Enum.flat_map(fn {h, lines} -> [h | lines] end) |> Enum.join("\n")

      # Present: not offered again.
      refute text =~ "ProcessScheduledJobsWorker"
      refute text =~ "Referrals.PruneWorker"
      refute text =~ "LoginAttemptsPruneWorker"
      refute text =~ ~s(cadence: "hourly")
      refute text =~ ~s(cadence: "12h")

      # Absent: offered.
      assert text =~ "PhoenixKit.Jobs.SweepWorker"
      assert text =~ "PhoenixKit.Jobs.PruneWorker"
      assert text =~ "BucketLogPruneWorker"
      assert text =~ ~s(cadence: "daily")
      assert text =~ ~s(cadence: "weekly")
    end

    test "an entry only in a comment above the block does not count as present" do
      content =
        "# {\"*/5 * * * *\", PhoenixKit.Jobs.SweepWorker}\n" <>
          var_config([~S|{"0 3 * * *", MyApp.Nightly}|])

      {_result, _out, steps} = run_all(content)
      text = steps |> Enum.flat_map(fn {h, lines} -> [h | lines] end) |> Enum.join("\n")

      assert text =~ "PhoenixKit.Jobs.SweepWorker"
    end

    test "a module attribute behaves the same" do
      content =
        "@crontab [\n  " <>
          Enum.join(@worker_lines ++ @digest_lines, ",\n  ") <>
          "\n]\n\nconfig :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: @crontab}]\n"

      assert {:ok, _} = Code.string_to_quoted(content)
      {result, out, steps} = run_all(content)

      assert result == content
      assert steps == []
      assert out =~ "not verified"
    end
  end

  # --- round 4: the final review's findings --------------------------------

  # The whole backfill, with what it printed and the steps it left.
  defp backfill(content) do
    ObanConfig.take_manual_steps()
    ObanConfig.take_declined()

    err =
      capture_io(:stderr, fn ->
        out =
          capture_io(fn -> send(self(), {:r, ObanConfig.update_content(content, "myapp")}) end)

        send(self(), {:out, out})
      end)

    assert_received {:r, result}
    assert_received {:out, out}
    {result, out, err, ObanConfig.take_manual_steps()}
  end

  # The crontab steps only (no queues, Pruner or Lifeline).
  defp cron_backfill(content) do
    ObanConfig.take_manual_steps()

    err =
      capture_io(:stderr, fn ->
        out =
          capture_io(fn ->
            result =
              content
              |> ObanConfig.ensure_cron_plugin("myapp")
              |> ObanConfig.ensure_digest_cron_entries("myapp")
              |> ObanConfig.ensure_worker_cron_entries("myapp")

            send(self(), {:r, result})
          end)

        send(self(), {:out, out})
      end)

    assert_received {:r, result}
    assert_received {:out, out}
    {result, out, err, ObanConfig.take_manual_steps()}
  end

  defp info_lines(out), do: out |> String.split("\n", trim: true)

  @all_pk_worker_lines [
    ~S|{"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}|,
    ~S|{"30 4 * * *", PhoenixKit.Users.Referrals.PruneWorker}|,
    ~S|{"45 4 * * *", PhoenixKit.Users.LoginAttemptsPruneWorker}|,
    ~S|{"*/5 * * * *", PhoenixKit.Jobs.SweepWorker}|,
    ~S|{"15 4 * * *", PhoenixKit.Jobs.PruneWorker}|,
    ~S|{"20 4 * * *", PhoenixKit.Modules.Storage.Workers.BucketLogPruneWorker}|,
    ~S|{"0 * * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "hourly"}}|,
    ~S|{"0 */12 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "12h"}}|,
    ~S|{"0 6 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "daily"}}|,
    ~S|{"0 6 * * 1", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "weekly"}}|
  ]

  describe "a mention elsewhere is not presence (the file-wide fallback is narrow)" do
    test "A: another app's Oban block has Cron with every entry; this app has no Cron" do
      other =
        "config :other_app, Oban,\n  plugins: [\n    {Oban.Plugins.Cron,\n     crontab: [\n" <>
          Enum.map_join(@all_pk_worker_lines, ",\n", &("       " <> &1)) <> "\n     ]}\n  ]\n\n"

      content = other <> "config :myapp, Oban,\n  plugins: [Oban.Plugins.Pruner]\n"

      {result, _out, _err, steps} = cron_backfill(content)

      assert steps == []
      assert String.starts_with?(result, other)
      assert in_crontab?(result, @posts_worker)
      assert in_crontab?(result, PhoenixKit.Jobs.SweepWorker)
    end

    test "B: a bare Oban.Plugins.Cron with no crontab: option gets a manual step, not 'configured'" do
      other =
        "config :other_app, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: [#{Enum.join(@all_pk_worker_lines, ", ")}]}]\n\n"

      content = other <> "config :myapp, Oban,\n  plugins: [Oban.Plugins.Cron]\n"

      {result, _out, _err, steps} = cron_backfill(content)

      assert result == content
      assert Enum.any?(steps, fn {h, _} -> h =~ "worker cron entries" end)
    end

    test "C: crontab: my_cron with no entries anywhere in it, entries only in another app" do
      other =
        "config :other_app, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: [#{Enum.join(@all_pk_worker_lines, ", ")}]}]\n\n"

      content =
        other <>
          "my_cron = [{\"0 3 * * *\", MyApp.Nightly}]\n\nconfig :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: my_cron}]\n"

      {result, out, _err, steps} = cron_backfill(content)

      assert result == content
      assert Enum.any?(steps, fn {h, _} -> h =~ "worker cron entries" end)
      refute out =~ "not verified"
    end

    test "D: a module name inside a string is not an entry" do
      content =
        "note = \"PhoenixKit.Jobs.SweepWorker PhoenixKit.Jobs.PruneWorker\"\n\n" <>
          "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: my_cron}]\n"

      {_result, out, _err, steps} = cron_backfill(content)

      assert Enum.any?(steps, fn {h, _} -> h =~ "worker cron entries" end)
      refute out =~ "SweepWorker"
    end

    test "E: entries in a variable the Cron plugin does not use still count as unverified, never as added" do
      # The text cannot tell a used variable from an unused one; it says so.
      content =
        "unused = [#{Enum.join(@all_pk_worker_lines, ", ")}]\n\n" <>
          "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: other_var}]\n"

      {result, out, _err, steps} = cron_backfill(content)

      assert result == content
      assert steps == []
      assert out =~ "not verified"
    end
  end

  describe "every crontab: of the block counts as presence; entries go only to Oban.Plugins.Cron" do
    defp dynamic_config(dynamic_lines, cron_lines \\ nil) do
      list = fn lines -> Enum.map_join(lines, ",\n         ", & &1) end

      cron =
        if cron_lines,
          do: ",\n    {Oban.Plugins.Cron,\n     crontab: [\n       #{list.(cron_lines)}\n     ]}",
          else: ""

      "config :myapp, Oban,\n  plugins: [\n    {Oban.Pro.Plugins.DynamicCron,\n     crontab: [\n         #{list.(dynamic_lines)}\n     ]}#{cron}\n  ]\n"
    end

    test "DynamicCron only, holding the worker: nothing is added to it, and a run changes nothing more" do
      content = dynamic_config([hd(@all_pk_worker_lines)])

      {first, _out, _err, steps} = cron_backfill(content)

      # The worker is scheduled (by DynamicCron): not added again. The rest
      # cannot go into DynamicCron, and there is no Cron plugin to take them.
      assert first == content
      assert Enum.any?(steps, fn {h, _} -> h =~ "worker cron entries" end)
      refute Enum.any?(steps, fn {h, _} -> h =~ "ProcessScheduledJobsWorker" end)

      {second, _, _, _} = cron_backfill(first)
      {third, _, _, _} = cron_backfill(second)
      assert second == first and third == first
      assert length(String.split(third, "ProcessScheduledJobsWorker")) == 2
    end

    test "DynamicCron first, then Cron with every entry: nothing is duplicated" do
      content = dynamic_config([~S|{"0 3 * * *", MyApp.Nightly}|], @all_pk_worker_lines)

      {first, _out, _err, steps} = cron_backfill(content)
      assert first == content
      assert steps == []

      {second, _, _, _} = cron_backfill(first)
      {third, _, _, _} = cron_backfill(second)
      assert second == content and third == content
    end

    test "DynamicCron first, then a Cron missing some: they land in Cron, once" do
      content =
        dynamic_config([~S|{"0 3 * * *", MyApp.Nightly}|], [hd(@all_pk_worker_lines)])

      {first, _out, _err, steps} = cron_backfill(content)

      assert steps == []
      assert in_crontab?(first, PhoenixKit.Jobs.SweepWorker)

      # Inside the Cron plugin's tuple, not the DynamicCron one.
      [dynamic_part, cron_part] = String.split(first, "{Oban.Plugins.Cron,")
      assert dynamic_part =~ "MyApp.Nightly"
      refute dynamic_part =~ "SweepWorker"
      assert cron_part =~ "SweepWorker"

      {second, _, _, _} = cron_backfill(first)
      assert second == first
    end
  end

  describe "g4: a prod-only block after the app's block is not part of the fallback" do
    test "an entry that is only in a nested prod block is still a manual step" do
      content = """
      some_var = [{"0 3 * * *", MyApp.Nightly}]

      config :myapp, Oban,
        plugins: [{Oban.Plugins.Cron, crontab: some_var}]

      if config_env() == :prod do
        config :myapp, Oban,
          plugins: [
            {Oban.Plugins.Cron,
             crontab: [
               {"*/5 * * * *", PhoenixKit.Jobs.SweepWorker}
               # comment
             ]}
          ]
      end
      """

      {result, out, _err, steps} = cron_backfill(content)

      assert result == content
      text = steps |> Enum.flat_map(fn {h, l} -> [h | l] end) |> Enum.join("\n")

      assert text =~ "PhoenixKit.Jobs.SweepWorker"

      refute out =~
               "Already configured (crontab is not a literal list; not verified): PhoenixKit.Jobs.SweepWorker"
    end

    test "an entry in the variable's own definition still counts, next to such a block" do
      content = """
      some_var = [{"*/5 * * * *", PhoenixKit.Jobs.SweepWorker}]

      config :myapp, Oban,
        plugins: [{Oban.Plugins.Cron, crontab: some_var}]

      if config_env() == :prod do
        config :myapp, Oban,
          plugins: [{Oban.Plugins.Cron, crontab: [{"0 5 * * *", MyApp.ProdOnly}]}]
      end
      """

      {_result, out, _err, steps} = cron_backfill(content)

      refute Enum.any?(steps, fn {h, l} ->
               Enum.any?([h | l], &(&1 =~ "SweepWorker"))
             end)

      assert out =~ "not verified): PhoenixKit.Jobs.SweepWorker"
    end
  end

  describe "refusal texts and the quiet cases" do
    test "F: config :app, Oban, false — one info line for the whole phase, no steps, no 'Adding'" do
      {result, out, err, steps} = backfill("config :myapp, Oban, false\n")

      assert result == "config :myapp, Oban, false\n"
      assert steps == []
      assert err == ""
      assert [_header, line] = info_lines(out) |> Enum.take(2) |> then(&[hd(&1), List.last(&1)])
      assert line =~ "Oban is disabled"
      assert length(info_lines(out)) == 1
      refute out =~ "Adding"
      refute out =~ "up-to-date"
    end

    test "G: plugins: false — queues are still checked, plugins are one info line, no steps" do
      content =
        "config :myapp, Oban,\n  repo: MyApp.Repo,\n  queues: [default: 10],\n  plugins: false\n"

      {result, out, err, steps} = backfill(content)

      assert steps == []
      assert err == ""
      assert out =~ "Oban plugins are switched off"
      refute out =~ "Adding PhoenixKit worker"
      refute out =~ "Adding notification digest"
      refute out =~ "Pruner configuration not found"
      assert {:ok, _} = Code.string_to_quoted(result)
    end

    test "K: a block nested in an if says so; not 'not verified'" do
      content =
        "if config_env() == :prod do\n  config :myapp, Oban,\n    plugins: [{Oban.Plugins.Cron, crontab: []}]\nend\n"

      {result, out, err, steps} = backfill(content)

      assert result == content
      assert err =~ "nested in an expression"
      refute out =~ "not verified"
      assert steps != []
    end

    test "17: a nested prod block that follows the app's block is not edited" do
      content = """
      config :myapp, Oban,
        repo: MyApp.Repo,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"0 3 * * *", MyApp.Nightly}
           ]}
        ]

      if config_env() == :prod do
        config :myapp, Oban,
          plugins: [
            {Oban.Plugins.Cron,
             crontab: [
               {"0 5 * * *", MyApp.ProdOnly}
             ]}
          ]
      end
      """

      {result, _out, _err, steps} = cron_backfill(content)

      assert steps == []
      [outer, nested] = String.split(result, "if config_env()")
      assert outer =~ "SweepWorker"
      refute nested =~ "SweepWorker"
      refute nested =~ "PruneWorker"
    end

    test "17b: the app's own block has no plugins; the nested prod block is still not edited" do
      content = """
      config :myapp, Oban,
        repo: MyApp.Repo,
        queues: [default: 10]

      if config_env() == :prod do
        config :myapp, Oban,
          plugins: [{Oban.Plugins.Cron, crontab: [{"0 3 * * *", MyApp.Nightly}]}]
      end
      """

      {result, _out, _err, steps} = cron_backfill(content)

      refute result =~ "SweepWorker"
      refute result =~ "DigestWorker"
      refute result =~ "ProcessScheduledJobsWorker"
      assert Enum.any?(steps, fn {h, _} -> h =~ "worker cron entries" end)
    end

    test "a plugins: variable gives a text that blames the plugins, not a missing crontab:" do
      content = "config :myapp, Oban,\n  plugins: my_plugins\n"
      {_result, _out, err, steps} = backfill(content)

      assert err =~ "`plugins:` are not a literal list"
      refute err =~ "no `crontab:` option"
      assert steps != []
    end
  end

  describe "queues from a variable" do
    test "every queue present in the file's code: already configured, no step" do
      content =
        "my_queues = [default: 10, media: 3, mailers: 5]\n\nconfig :myapp, Oban,\n  queues: my_queues\n"

      out =
        capture_io(fn ->
          capture_io(:stderr, fn ->
            send(self(), {:r, ObanConfig.ensure_queue(content, "myapp", "media", 3)})
          end)
        end)

      assert_received {:r, ^content}
      assert out =~ "not a literal list; not verified"
    end

    test "a queue named only in a comment, a string or another app is still a manual step" do
      content =
        "# media: 3\nnote = \"media: 3\"\nconfig :other, Oban, queues: [media: 3]\n\nconfig :myapp, Oban,\n  queues: my_queues\n"

      ObanConfig.take_manual_steps()

      capture_io(:stderr, fn ->
        send(self(), {:r, ObanConfig.ensure_queue(content, "myapp", "media", 3)})
      end)

      assert_received {:r, ^content}
      assert [{headline, _}] = ObanConfig.take_manual_steps()
      assert headline =~ "media queue"
    end
  end

  describe "declined entries" do
    test "a digest entry commented out over two lines is declined" do
      content =
        crontab_config(~S|,
      # {"0 6 * * 1", PhoenixKit.Notifications.DigestWorker,
      #  args: %{cadence: "weekly"}}|)

      ObanConfig.take_declined()
      updated = quiet(fn -> ObanConfig.ensure_digest_cron_entries(content, "myapp") end)

      refute updated =~ ~r/^\s+\{"0 6 \* \* 1"/m
      assert ObanConfig.take_declined() == ["PhoenixKit.Notifications.DigestWorker (weekly)"]
    end

    test "names are the full module names, with the cadence for a digest" do
      content =
        crontab_config(~S|,
      # {"30 4 * * *", PhoenixKit.Users.Referrals.PruneWorker}
      # {"0 6 * * 1", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "weekly"}}
      # {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}|)

      {_result, _out, _err, _steps} = backfill(content)
      # backfill/1 already drained the list; run again to read it.
      ObanConfig.take_declined()
      quiet(fn -> ObanConfig.update_content(content, "myapp") end)

      assert ObanConfig.take_declined() |> Enum.sort() == [
               "PhoenixKit.Notifications.DigestWorker (weekly)",
               "PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker",
               "PhoenixKit.Users.Referrals.PruneWorker"
             ]
    end
  end

  describe "ensure_cron_plugin/2 with the old worker in a combined list" do
    test "[old_worker] ++ extra holding the core worker: the double-run warning, not 'configured'" do
      content =
        "config :myapp, Oban,\n  plugins: [\n    {Oban.Plugins.Cron,\n     crontab: [{\"* * * * *\", PhoenixKitPosts.Workers.PublishScheduledPostsJob}] ++ extra()}\n  ]\n\nextra = [{\"* * * * *\", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}]\n"

      ObanConfig.take_manual_steps()

      err =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            send(self(), {:r, ObanConfig.ensure_cron_plugin(content, "myapp")})
          end)
        end)

      assert_received {:r, ^content}
      assert err =~ "Both PublishScheduledPostsJob and ProcessScheduledJobsWorker"
      assert [{headline, _}] = ObanConfig.take_manual_steps()
      assert headline =~ "Both PublishScheduledPostsJob"
    end

    test "the old-worker rename stays inside this app's block" do
      other =
        "config :other, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: [{\"* * * * *\", Other.PublishScheduledPostsJob}]}]\n\n"

      mine =
        "config :myapp, Oban,\n  plugins: [\n    {Oban.Plugins.Cron,\n     crontab: [\n       {\"* * * * *\", PhoenixKitPosts.Workers.PublishScheduledPostsJob}\n     ]}\n  ]\n"

      updated = quiet(fn -> ObanConfig.ensure_cron_plugin(other <> mine, "myapp") end)

      assert String.starts_with?(updated, other)
      assert updated =~ "ProcessScheduledJobsWorker"
      refute updated =~ "PhoenixKitPosts.Workers.PublishScheduledPostsJob"
    end
  end

  describe "the masker follows the lexical forms inside interpolation" do
    @interp_forms [
      {~S|#{?"}|, "a character literal"},
      {~S|#{'"'}|, "a charlist"},
      {~S|#{~s(")}|, "a sigil"},
      {~S|#{?{}|, "a brace character literal"},
      {~S|#{"x" # "
        }|, "a comment holding a quote"},
      {~S|#{~HTML(x])}|, "a multi-letter sigil with a bracket"}
    ]

    for {interp, name} <- @interp_forms do
      test "an interpolation holding #{name}" do
        content =
          crontab_around([
            ~s({"0 2 * * *", MyApp.I, args: %{n: "a #{unquote(interp)} ] b"}}),
            ~S|{"0 3 * * *", MyApp.J, args: %{note: "x # y"}} # tail|
          ])

        case Code.string_to_quoted(content, emit_warnings: false) do
          {:ok, _} ->
            updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)
            assert updated != content
            assert host_preserved?(content, updated)

          {:error, _} ->
            # Not valid Elixir after all: nothing to assert about it.
            :ok
        end
      end
    end

    test "a file the masker cannot balance is called unreadable, not diagnosed" do
      content =
        "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: [\"unterminated]}]\n"

      ObanConfig.take_manual_steps()
      err = capture_io(:stderr, fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      assert err =~ "could not read the Oban block safely"
      refute err =~ "no `crontab:`"
    end
  end

  describe "line endings follow the list's own neighbourhood" do
    test "a CRLF list in an otherwise LF file is written with CRLF" do
      lf_head = String.duplicate("# note\n", 12)
      list = String.replace(crontab_config(" # tail"), "\n", "\r\n")

      updated = quiet(fn -> ObanConfig.ensure_worker_cron_entries(lf_head <> list, "myapp") end)

      assert String.starts_with?(updated, lf_head)
      added = updated |> String.split("SweepWorker") |> hd() |> String.split("\n") |> List.last()
      assert added != nil
      refute String.replace(String.replace_prefix(updated, lf_head, ""), "\r\n", "") =~ "\n"
    end

    test "an LF list in an otherwise CRLF file is written with LF" do
      crlf_head = String.duplicate("# note\r\n", 12)

      updated =
        quiet(fn ->
          ObanConfig.ensure_worker_cron_entries(crlf_head <> crontab_config(" # tail"), "myapp")
        end)

      body = String.replace_prefix(updated, crlf_head, "")
      refute body =~ "\r"
    end
  end

  describe "rollback and refusal branches" do
    test "a rescue_after raise that cannot be verified becomes a recorded manual step" do
      # The first match is inside a comment, so the replacement changes the
      # comment only and the real entry keeps its low value.
      content = """
      config :myapp, Oban,
        plugins: [
          # {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(5)}
          {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(10)}
        ]
      """

      ObanConfig.take_manual_steps()

      err =
        capture_io(:stderr, fn ->
          send(self(), {:r, ObanConfig.ensure_lifeline_plugin(content, "myapp")})
        end)

      assert_received {:r, ^content}
      assert err =~ "Could not safely raise Lifeline rescue_after"
      assert [{headline, lines}] = ObanConfig.take_manual_steps()
      assert headline =~ "Lifeline rescue_after"
      assert Enum.any?(lines, &(&1 =~ "minutes(60)"))
    end

    test "append_entries/6 refuses through preserves_original? when only that check fails" do
      content = "config :myapp, Oban,\n  queues: [default: 10]\n"

      # The verify check is satisfied and the candidate parses, but the entry
      # text closes the list early and reopens another option: the entries do
      # not parse as list elements, so the original cannot be shown preserved.
      assert {:error, why} =
               ObanConfig.append_entries(
                 content,
                 "myapp",
                 :queues,
                 ["a: 1], other: [2"],
                 fn _ast -> true end
               )

      assert why =~ "changed something else"
    end
  end

  describe "the closing line of the phase and of the update" do
    test "'up-to-date' is not printed while a step is waiting" do
      content = "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: my_cron}]\n"
      {_result, out, _err, steps} = backfill(content)

      assert steps != []
      refute out =~ "already up-to-date"
      assert out =~ "step(s) need you"
    end

    test "the summary header does not promise that every item switches a feature off" do
      ObanConfig.take_manual_steps()

      steps = [
        {"Both PublishScheduledPostsJob and ProcessScheduledJobsWorker are in the crontab.",
         ["x"]}
      ]

      summary = ObanConfig.manual_steps_summary(steps)

      refute summary =~ "stay off"
      assert summary =~ "Manual steps needed"
    end

    test "the manual-steps block is printed after a run that raises, and the error still propagates" do
      alias Mix.Tasks.PhoenixKit.Update, as: Update

      ObanConfig.take_manual_steps()
      content = "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: my_cron}]\n"
      capture_io(:stderr, fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      err =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/migration declined/, fn ->
            Update.with_manual_steps_summary(fn -> Mix.raise("migration declined") end)
          end
        end)

      assert err =~ "Manual steps needed"
      assert err =~ "worker cron entries"
      assert ObanConfig.take_manual_steps() == []
    end

    test "and after a run that completes" do
      alias Mix.Tasks.PhoenixKit.Update, as: Update

      ObanConfig.take_manual_steps()
      content = "config :myapp, Oban,\n  plugins: [{Oban.Plugins.Cron, crontab: my_cron}]\n"
      capture_io(:stderr, fn -> ObanConfig.ensure_worker_cron_entries(content, "myapp") end)

      err =
        capture_io(:stderr, fn ->
          assert Update.with_manual_steps_summary(fn -> :done end) == :done
        end)

      assert err =~ "Manual steps needed"
    end
  end

  # The comment text a tail carries, to check it survived the splice.
  defp tail_comments(tail) do
    for line <- String.split(tail, "\n"),
        [_, comment] <- [Regex.run(~r/(#.*)$/, line)],
        do: comment
  end
end
