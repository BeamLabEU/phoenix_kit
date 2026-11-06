defmodule PhoenixKit.Install.ObanConfigNotifierTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.ObanConfig

  # The line is spliced between `repo:` and `queues:` of a fresh block, so
  # what matters is that the block still parses and says what it should.
  defp block(repo_config) do
    "config :my_app, Oban,\n  repo: MyApp.Repo," <>
      ObanConfig.notifier_line(repo_config) <> "\n  queues: [default: 10]\n"
  end

  defp oban_opts(source) do
    {:config, _, [:my_app, _oban, opts]} = Code.string_to_quoted!(source)
    opts
  end

  test "a repo that looks pooled gets the PG notifier" do
    source = block(port: 6432, hostname: "db.internal")

    assert {:__aliases__, _, [:Oban, :Notifiers, :PG]} = oban_opts(source)[:notifier]
    assert source =~ "connection pooler"
  end

  test "a pooler named by its host counts too" do
    assert oban_opts(block(hostname: "pgbouncer", port: 5432))[:notifier]
  end

  test "a direct repo keeps Oban's default notifier and gets the hint as a comment" do
    source = block(port: 5432, hostname: "localhost")

    refute Keyword.has_key?(oban_opts(source), :notifier)
    assert source =~ "# If you run one, add: notifier: Oban.Notifiers.PG"
  end

  test "a repo Mix has no config for (runtime.exs only) gets the comment" do
    source = block(nil)

    refute Keyword.has_key?(oban_opts(source), :notifier)
    assert source =~ "Oban.Notifiers.PG"
  end
end
