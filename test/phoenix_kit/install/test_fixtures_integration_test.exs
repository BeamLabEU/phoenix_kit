defmodule PhoenixKit.Install.TestFixturesIntegrationTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias PhoenixKit.Install.TestFixturesIntegration, as: TFI
  alias PhoenixKit.Test.Fixtures

  @conn_case_path "test/support/conn_case.ex"

  # The ConnCase phx.new 1.8 generates, trimmed to the part that matters.
  @phx_new_conn_case """
  defmodule MyAppWeb.ConnCase do
    use ExUnit.CaseTemplate

    using do
      quote do
        # The default endpoint for testing
        @endpoint MyAppWeb.Endpoint

        use MyAppWeb, :verified_routes

        # Import conveniences for testing with connections
        import Plug.Conn
        import Phoenix.ConnTest
        import MyAppWeb.ConnCase
      end
    end
  end
  """

  describe "conn_case_plan/2" do
    test "injects into a stock phx.new ConnCase" do
      assert TFI.conn_case_plan(@phx_new_conn_case, []) == :inject
    end

    test "leaves a ConnCase that already imports the fixtures alone" do
      content = TFI.inject_import(@phx_new_conn_case)
      assert TFI.conn_case_plan(content, []) == :already_present
    end

    test "refuses when the ConnCase defines a fixture name itself (phx.gen.auth)" do
      content =
        String.replace(@phx_new_conn_case, "end\nend\n", """
        end

          def register_and_log_in_user(%{conn: conn}), do: %{conn: conn}
        end
        """)

      assert TFI.conn_case_plan(content, []) == {:conflict, "register_and_log_in_user"}
    end

    test "refuses when any other test source defines one, private or not" do
      other = """
      defmodule MyAppWeb.PageTest do
        defp log_in_user(conn, _user), do: conn
      end
      """

      assert TFI.conn_case_plan(@phx_new_conn_case, [other]) == {:conflict, "log_in_user"}
    end

    test "a name that merely starts with a fixture name is not a conflict" do
      other = "defmodule X do\n  def user_fixture_with_posts(_), do: :ok\nend\n"
      assert TFI.conn_case_plan(@phx_new_conn_case, [other]) == :inject
    end

    test "a ConnCase not shaped like phx.new's is reported, not edited" do
      assert TFI.conn_case_plan("defmodule MyAppWeb.ConnCase do\nend\n", []) == :no_anchor
    end

    # The names are a list of their own in the installer, and a fixture added
    # without it would go past the check and break the host's test build.
    test "every function of PhoenixKit.Test.Fixtures counts as a clash" do
      for {name, _arity} <- Fixtures.__info__(:functions) do
        other = "defmodule X do\n  def #{name}(_), do: :ok\nend\n"
        assert TFI.conn_case_plan(@phx_new_conn_case, [other]) == {:conflict, "#{name}"}
      end
    end

    test "a macro or a delegate with a fixture name clashes as a function does" do
      for definition <- [
            "defmacro log_in_user(conn, user), do: {conn, user}",
            "defmacrop log_in_user(conn, user), do: {conn, user}",
            "defdelegate log_in_user(conn, user), to: MyApp.TestSupport"
          ] do
        other = "defmodule X do\n  #{definition}\nend\n"
        assert TFI.conn_case_plan(@phx_new_conn_case, [other]) == {:conflict, "log_in_user"}
      end
    end
  end

  # `test_project/1` never touches the disk, so these see the import only when
  # it goes through Igniter's buffer. That is also what keeps the host's file
  # as it was on `--dry-run`, or when the person answers no to the diff.
  describe "ensure_conn_case_import/2" do
    defp project, do: test_project(files: %{@conn_case_path => @phx_new_conn_case})

    defp conn_case(igniter) do
      igniter.rewrite |> Rewrite.source!(@conn_case_path) |> Rewrite.Source.get(:content)
    end

    test "stages the import instead of writing the file" do
      igniter = TFI.ensure_conn_case_import(project(), fn -> [] end)

      assert conn_case(igniter) =~ "import PhoenixKit.Test.Fixtures"
      assert Enum.any?(igniter.notices, &(&1 =~ "register_and_log_in_user/1"))
    end

    test "a second run changes nothing" do
      igniter =
        project()
        |> TFI.ensure_conn_case_import(fn -> [] end)
        |> apply_igniter!()
        |> TFI.ensure_conn_case_import(fn -> [] end)

      assert_unchanged(igniter, @conn_case_path)
      assert igniter.notices == []
    end

    test "reads what an earlier step of the same run staged" do
      igniter =
        project()
        |> Igniter.update_file(@conn_case_path, fn source ->
          content = Rewrite.Source.get(source, :content)
          Rewrite.Source.update(source, :content, "# staged earlier\n" <> content)
        end)
        |> TFI.ensure_conn_case_import(fn -> [] end)

      assert conn_case(igniter) =~ "# staged earlier"
      assert conn_case(igniter) =~ "import PhoenixKit.Test.Fixtures"
    end

    test "a clash leaves the file alone and says why" do
      igniter =
        TFI.ensure_conn_case_import(project(), fn -> ["defp log_in_user(conn, _), do: conn\n"] end)

      assert_unchanged(igniter, @conn_case_path)
      assert Enum.any?(igniter.notices, &(&1 =~ "log_in_user"))
    end

    test "a project with no ConnCase is left alone" do
      igniter = TFI.ensure_conn_case_import(test_project(), fn -> [] end)

      assert igniter.notices == []
      refute Igniter.exists?(igniter, @conn_case_path)
    end
  end

  describe "inject_import/1" do
    test "adds the import right after Phoenix.ConnTest, at the same indent" do
      assert TFI.inject_import(@phx_new_conn_case) =~
               "      import Phoenix.ConnTest\n      import PhoenixKit.Test.Fixtures\n      import MyAppWeb.ConnCase\n"
    end

    test "adds it once" do
      once = TFI.inject_import(@phx_new_conn_case)
      assert length(String.split(once, "import PhoenixKit.Test.Fixtures")) == 2
    end
  end
end
