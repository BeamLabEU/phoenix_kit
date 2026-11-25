defmodule PhoenixKit.Install.EncryptionKeyConfigTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias PhoenixKit.Install.EncryptionKeyConfig

  @runtime """
  import Config

  if config_env() == :prod do
    config :my_app, MyAppWeb.Endpoint, secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
  end
  """

  @files %{
    "config/dev.exs" => "import Config\n",
    "config/test.exs" => "import Config\n",
    "config/runtime.exs" => @runtime
  }

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  defp run(files) do
    test_project(app_name: :my_app, files: files)
    |> EncryptionKeyConfig.add_encryption_key()
    |> apply_igniter!()
  end

  defp literal_key(content) do
    case Regex.run(~r/integrations_encryption_key: "([^"]+)"/, content) do
      [_, key] -> key
      nil -> nil
    end
  end

  describe "a new installation" do
    test "dev and test each get a generated key of their own" do
      igniter = run(@files)

      dev = literal_key(content(igniter, "config/dev.exs"))
      test = literal_key(content(igniter, "config/test.exs"))

      assert byte_size(dev) == 64
      assert byte_size(test) == 64
      assert dev != test
    end

    test "production reads the variable inside the :prod block and refuses to boot without it" do
      runtime = content(run(@files), "config/runtime.exs")

      assert runtime =~ ~s|System.get_env("PHOENIX_KIT_INTEGRATIONS_ENCRYPTION_KEY")|
      assert runtime =~ "raise"
      # No generated secret in a file that ships to production.
      assert literal_key(runtime) == nil

      # The file still parses, and the key sits inside the :prod block.
      assert {:ok, _} = Code.string_to_quoted(runtime)
      [_before, prod_block] = String.split(runtime, "if config_env() == :prod do", parts: 2)
      assert prod_block =~ "integrations_encryption_key"
    end

    test "the production value evaluates to the variable, and raises when it is missing" do
      runtime = content(run(@files), "config/runtime.exs")
      [_, expr] = Regex.run(~r/integrations_encryption_key:\s*(.+?)\nend\s*\z/s, runtime)

      var = EncryptionKeyConfig.env_var()
      previous = System.get_env(var)

      on_exit(fn ->
        if previous, do: System.put_env(var, previous), else: System.delete_env(var)
      end)

      System.put_env(var, "from-the-environment")
      assert {"from-the-environment", _} = Code.eval_string(expr)

      System.delete_env(var)
      assert_raise RuntimeError, ~r/#{var} is missing/, fn -> Code.eval_string(expr) end
    end

    test "says what production needs" do
      igniter =
        test_project(app_name: :my_app, files: @files)
        |> EncryptionKeyConfig.add_encryption_key()

      assert Enum.any?(igniter.notices, &(&1 =~ EncryptionKeyConfig.env_var()))
    end
  end

  describe "an existing installation is left alone" do
    test "one that already has a PhoenixKit migration" do
      files =
        Map.put(
          @files,
          "priv/repo/migrations/20260101000000_add_phoenix_kit_tables.exs",
          "defmodule MyApp.Repo.Migrations.AddPhoenixKitTables do\nend\n"
        )

      igniter = run(files)

      assert content(igniter, "config/dev.exs") == "import Config\n"
      assert content(igniter, "config/runtime.exs") == @runtime
    end

    test "one whose config already names a key" do
      files =
        Map.put(@files, "config/config.exs", """
        import Config

        config :phoenix_kit, integrations_encryption_key: "the-host-already-chose-this-one"
        """)

      igniter = run(files)

      assert content(igniter, "config/dev.exs") == "import Config\n"
      assert content(igniter, "config/runtime.exs") == @runtime
    end

    test "one whose config names a key store" do
      files =
        Map.put(@files, "config/config.exs", """
        import Config

        config :phoenix_kit, integrations_key_store: PhoenixKit.Integrations.KeyStore.File
        """)

      assert content(run(files), "config/dev.exs") == "import Config\n"
    end
  end

  test "a second run changes nothing" do
    first = run(@files)

    files =
      Map.new(["config/dev.exs", "config/test.exs", "config/runtime.exs"], fn path ->
        {path, content(first, path)}
      end)

    second = run(files)

    for path <- Map.keys(files) do
      assert content(second, path) == files[path]
    end
  end
end
