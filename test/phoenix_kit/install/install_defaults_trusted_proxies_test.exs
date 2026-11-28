defmodule PhoenixKit.Install.InstallDefaultsTrustedProxiesTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  alias Mix.Tasks.PhoenixKit.Install
  alias Mix.Tasks.PhoenixKit.Update
  alias PhoenixKit.Install.InstallDefaults

  setup do
    InstallDefaults.forget_answers()
    on_exit(&InstallDefaults.forget_answers/0)
    :ok
  end

  defp config(igniter) do
    igniter.rewrite |> Rewrite.source!("config/config.exs") |> Rewrite.Source.get(:content)
  end

  defp answers(list) do
    {:ok, agent} = Agent.start_link(fn -> list end)

    fn _question -> Agent.get_and_update(agent, fn [answer | rest] -> {answer, rest} end) end
  end

  describe "trusted_proxies_choice/3" do
    test "--trusted-proxy values are validated and written as given" do
      assert {:write, ["10.0.0.0/8", "127.0.0.1/8"]} =
               InstallDefaults.trusted_proxies_choice(["10.0.0.0/8", "127.0.0.1/8"], false)
    end

    test "a malformed --trusted-proxy stops the install with the value named" do
      assert_raise Mix.Error, ~r/not-a-cidr/, fn ->
        InstallDefaults.trusted_proxies_choice(["not-a-cidr"], true)
      end
    end

    test "the flag wins over the question" do
      ask = fn _ -> flunk("asked although --trusted-proxy was given") end
      assert {:write, _} = InstallDefaults.trusted_proxies_choice(["10.0.0.1"], true, ask)
    end

    test "no proxy (the default answer) writes []" do
      assert {:write, []} = InstallDefaults.trusted_proxies_choice([], true, answers([false]))
    end

    test "behind a proxy trusts loopback; private ranges only when also chosen" do
      assert {:write, loopback} =
               InstallDefaults.trusted_proxies_choice([], true, answers([true, false]))

      assert loopback == InstallDefaults.loopback_blocks()

      assert {:write, both} =
               InstallDefaults.trusted_proxies_choice([], true, answers([true, true]))

      assert both == InstallDefaults.loopback_blocks() ++ InstallDefaults.private_blocks()
    end

    test "no terminal and no flag writes nothing" do
      assert :skip = InstallDefaults.trusted_proxies_choice([], false, answers([]))
    end
  end

  describe "add_trusted_proxies/3 on a project" do
    test "writes the chosen blocks into config.exs" do
      igniter =
        test_project(app_name: :my_app, files: %{"config/config.exs" => "import Config\n"})
        |> InstallDefaults.add_trusted_proxies(["127.0.0.1/8"], false)

      assert config(igniter) =~ ~s|trusted_proxies: ["127.0.0.1/8"]|
    end

    test "[] is written for the explicit no-proxy answer" do
      igniter =
        test_project(app_name: :my_app, files: %{"config/config.exs" => "import Config\n"})
        |> InstallDefaults.write_trusted_proxies({:write, []})

      assert config(igniter) =~ "trusted_proxies: []"
    end

    test "an entry the host already has is left alone" do
      existing = """
      import Config
      config :phoenix_kit, trusted_proxies: ["172.18.0.7/32"]
      """

      igniter =
        test_project(app_name: :my_app, files: %{"config/config.exs" => existing})
        |> InstallDefaults.write_trusted_proxies({:write, []})

      assert config(igniter) =~ ~s|"172.18.0.7/32"|
      refute config(igniter) =~ "trusted_proxies: []"
    end

    test "no terminal: nothing written, a notice says how" do
      igniter =
        test_project(app_name: :my_app, files: %{"config/config.exs" => "import Config\n"})
        |> InstallDefaults.add_trusted_proxies([], false)

      refute config(igniter) =~ "trusted_proxies"
      assert Enum.any?(igniter.notices, &(&1 =~ "trusted_proxies"))
    end
  end

  describe "the flag" do
    test "the installer declares --trusted-proxy as repeatable" do
      %Igniter.Mix.Task.Info{schema: schema} = Install.info([], nil)
      assert schema[:trusted_proxy] == :keep
    end

    test "--help documents it" do
      assert ExUnit.CaptureIO.capture_io(fn -> Install.run(["--help"]) end) =~
               "--trusted-proxy"
    end

    # An upgraded host keeps what it had: the updater has no such option and
    # never writes the key.
    test "the updater neither takes the flag nor writes the key" do
      %Igniter.Mix.Task.Info{schema: schema} = Update.info([], nil)
      refute Keyword.has_key?(schema, :trusted_proxy)
      refute File.read!("lib/mix/tasks/phoenix_kit.update.ex") =~ "InstallDefaults"
    end
  end
end
