defmodule PhoenixKit.Install.TestFixturesIntegrationTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.TestFixturesIntegration, as: TFI

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
