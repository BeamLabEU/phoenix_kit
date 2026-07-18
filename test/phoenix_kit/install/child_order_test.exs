defmodule PhoenixKit.Install.ChildOrderTest do
  @moduledoc """
  Unit coverage for `ChildOrder` — the doctor safety net that catches a
  host `application.ex` whose supervision `children` list starts
  `PhoenixKit.Supervisor` or `Oban` before the Ecto Repo. That order crashes
  the app at boot (PhoenixKit reads Settings from the DB; Oban needs the pool),
  and it can slip in via a hand edit or an Igniter anchor miss that prepends.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.ChildOrder

  defp app(children_lines) do
    """
    defmodule MyApp.Application do
      use Application

      def start(_type, _args) do
        children = [
    #{children_lines}
        ]

        opts = [strategy: :one_for_one, name: MyApp.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    """
  end

  describe "check/2 — correct order" do
    test "passes when the Repo precedes PhoenixKit.Supervisor and Oban" do
      source =
        app("""
              MyApp.Repo,
              {Phoenix.PubSub, name: MyApp.PubSub},
              PhoenixKit.Supervisor,
              {Oban, Application.fetch_env!(:my_app, Oban)},
              MyAppWeb.Endpoint
        """)

      assert {:ok, detail} = ChildOrder.check(source, MyApp.Repo)
      assert detail =~ "MyApp.Repo"
      assert detail =~ "PhoenixKit.Supervisor"
      assert detail =~ "Oban"
    end

    test "passes when no Repo-dependent children are present" do
      source =
        app("""
              MyApp.Repo,
              MyAppWeb.Endpoint
        """)

      assert {:ok, _detail} = ChildOrder.check(source, MyApp.Repo)
    end

    test "passes when the Repo is written as a 2-tuple child spec" do
      source =
        app("""
              {MyApp.Repo, []},
              PhoenixKit.Supervisor,
              MyAppWeb.Endpoint
        """)

      assert {:ok, _detail} = ChildOrder.check(source, MyApp.Repo)
    end
  end

  describe "check/2 — misordered (the boot-crash cases)" do
    test "flags PhoenixKit.Supervisor listed before the Repo" do
      source =
        app("""
              PhoenixKit.Supervisor,
              MyApp.Repo,
              MyAppWeb.Endpoint
        """)

      assert {:misordered, [PhoenixKit.Supervisor]} = ChildOrder.check(source, MyApp.Repo)
    end

    test "flags Oban (as a {Oban, opts} tuple) listed before the Repo" do
      source =
        app("""
              {Oban, queues: [default: 10]},
              MyApp.Repo,
              MyAppWeb.Endpoint
        """)

      assert {:misordered, [Oban]} = ChildOrder.check(source, MyApp.Repo)
    end

    test "flags both PhoenixKit.Supervisor and Oban when both precede the Repo" do
      source =
        app("""
              PhoenixKit.Supervisor,
              {Oban, []},
              MyApp.Repo,
              MyAppWeb.Endpoint
        """)

      assert {:misordered, offenders} = ChildOrder.check(source, MyApp.Repo)
      assert Enum.sort(offenders) == Enum.sort([PhoenixKit.Supervisor, Oban])
    end
  end

  describe "check/2 — indeterminate inputs" do
    test "returns :no_repo_in_children when the Repo isn't in the list" do
      source =
        app("""
              {Phoenix.PubSub, name: MyApp.PubSub},
              PhoenixKit.Supervisor,
              MyAppWeb.Endpoint
        """)

      assert :no_repo_in_children = ChildOrder.check(source, MyApp.Repo)
    end

    test "returns :no_children when no children list can be located" do
      source = """
      defmodule MyApp.Application do
        use Application
        def start(_type, _args), do: :ignore
      end
      """

      assert :no_children = ChildOrder.check(source, MyApp.Repo)
    end
  end

  describe "ordered_children/1" do
    test "reads head modules in list order, including tuple specs" do
      source =
        app("""
              MyApp.Repo,
              {Phoenix.PubSub, name: MyApp.PubSub},
              {Oban, []},
              MyAppWeb.Endpoint
        """)

      assert {:ok, [MyApp.Repo, Phoenix.PubSub, Oban, MyAppWeb.Endpoint]} =
               ChildOrder.ordered_children(source)
    end

    test "reads the inline Supervisor.start_link([...]) shape" do
      source = """
      defmodule MyApp.Application do
        use Application
        def start(_type, _args) do
          Supervisor.start_link(
            [MyApp.Repo, PhoenixKit.Supervisor, MyAppWeb.Endpoint],
            strategy: :one_for_one
          )
        end
      end
      """

      assert {:ok, [MyApp.Repo, PhoenixKit.Supervisor, MyAppWeb.Endpoint]} =
               ChildOrder.ordered_children(source)
    end

    test "yields nil for a map child spec but keeps positions" do
      source =
        app("""
              MyApp.Repo,
              %{id: MyWorker, start: {MyWorker, :start_link, []}},
              PhoenixKit.Supervisor
        """)

      assert {:ok, [MyApp.Repo, nil, PhoenixKit.Supervisor]} =
               ChildOrder.ordered_children(source)
    end
  end
end
