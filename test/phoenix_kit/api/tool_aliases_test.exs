defmodule PhoenixKit.API.ToolAliasesTest do
  @moduledoc """
  Undotted tool names and aliases (`PhoenixKit.API.Tool`, "Undotted names and aliases"):
  what `Tool.new/1` accepts, how a call by an alias reaches its tool under the tool's own
  name, and the one collision check (`ModuleRegistry.check_api_tool_names!/1`) that refuses
  a clash at registration. A set of dotted names alone keeps the older rule.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiHarness

  alias PhoenixKit.API.MCP.Names
  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.REST
  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.ToolLint
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.ApiTools

  @scope "testkit.items:read"

  defp tool(name, opts \\ []) do
    audience = Keyword.get(opts, :audience, :admin)

    rights =
      if audience == :admin, do: [scope: @scope, permission: "dashboard"], else: []

    Tool.new!(
      [
        name: name,
        audience: audience,
        description: "A host tool.",
        handler: {__MODULE__.HostTools, :run}
      ] ++ rights ++ Keyword.take(opts, [:aliases])
    )
  end

  defmodule HostTools do
    @moduledoc false
    alias PhoenixKit.API.Tool

    def module_key, do: "host_tools_alias_test"
    def module_name, do: "Host tools"
    def enabled?, do: true

    def api_tools do
      [
        Tool.new!(
          name: "call_endpoint",
          aliases: ["callEndpoint", "legacyhost.call"],
          audience: :admin,
          scope: "testkit.items:read",
          permission: "dashboard",
          description: "An undotted host tool.",
          handler: {__MODULE__, :run},
          annotations: %{read_only: true}
        )
      ]
    end

    def run(input, _ctx) do
      send(self(), {:host_tool_ran, input})
      {:ok, %{"ran" => true}}
    end
  end

  # A module whose tools are given at run time, for the collision cases.
  defmodule Scripted do
    @moduledoc false
    def module_key, do: "scripted_alias_test"
    def module_name, do: "Scripted"
    def enabled?, do: true
    def api_tools, do: :persistent_term.get({__MODULE__, :tools}, [])
    def put(tools), do: :persistent_term.put({__MODULE__, :tools}, tools)
  end

  setup do
    setup_api()
    on_exit(fn -> :persistent_term.erase({Scripted, :tools}) end)
    :ok
  end

  defp register_host! do
    :ok = ModuleRegistry.register(HostTools)
    on_exit(fn -> ModuleRegistry.unregister(HostTools) end)
  end

  describe "Tool.new/1" do
    test "takes an undotted name of letters, digits, _ and -" do
      for name <- ["call_endpoint", "CallEndpoint", "call-endpoint-2"] do
        assert {:ok, %Tool{name: ^name, aliases: []}} =
                 Tool.new(
                   name: name,
                   audience: :public,
                   handler: {Kernel, :inspect}
                 )
      end
    end

    test "still refuses anything else" do
      for name <- ["call endpoint", "a.b.c", "", "ünïcode", "a/b", String.duplicate("a", 101)] do
        assert {:error, _} = Tool.new(name: name, audience: :public, handler: {Kernel, :inspect})
      end
    end

    test "aliases are names, unique, and not the tool's own name" do
      base = [name: "call_endpoint", audience: :public, handler: {Kernel, :inspect}]

      assert {:ok, %Tool{aliases: ["a", "x.y"]}} = Tool.new(base ++ [aliases: ["a", "x.y"]])
      assert {:error, [message]} = Tool.new(base ++ [aliases: ["has space"]])
      assert message =~ "aliases must be"
      assert {:error, [message]} = Tool.new(base ++ [aliases: ["a", "a"]])
      assert message =~ "repeat a name"
      assert {:error, [message]} = Tool.new(base ++ [aliases: ["call_endpoint"]])
      assert message =~ "own name"
      assert {:error, _} = Tool.new(base ++ [aliases: "a"])
    end

    test "a dotted tool without aliases is built exactly as before" do
      assert %Tool{name: "testkit.read_items", aliases: []} = tool("testkit.read_items")
    end
  end

  describe "a call by name or alias" do
    setup do
      register_host!()
      {owner, _role} = user_with(["dashboard"])
      {_key, token} = issue_key(owner, [@scope])
      %{token: token}
    end

    test "the registry finds the tool by its undotted name and by each alias, under its own name" do
      for name <- ["call_endpoint", "callEndpoint", "legacyhost.call"] do
        assert {:ok, %Tool{name: "call_endpoint"}} = Registry.find(name, :admin)
      end

      assert Registry.find("callEndpoint", :public) == {:error, :not_found}
    end

    test "MCP keeps an undotted name and an alias as they are" do
      assert Names.resolve("call_endpoint", :admin) == "call_endpoint"
      assert Names.resolve("callEndpoint", :admin) == "callEndpoint"
      # The older underscore mapping still works next to them.
      assert Names.resolve("testkit_read_items", :admin) == "testkit.read_items"
    end

    test "REST runs the tool by an alias", %{token: token} do
      conn =
        :post
        |> api_conn("/callEndpoint", token: token, body: %{})
        |> REST.call(REST.init(audience: :admin))

      assert conn.status == 200
      assert json(conn) == %{"ran" => true}
      assert_received {:host_tool_ran, %{}}
    end

    test "a key without the tool's scope is refused by an alias too" do
      {owner, _role} = user_with(["dashboard", "settings"])
      {_key, token} = issue_key(owner, ["testkit.items:write"])

      conn =
        :post
        |> api_conn("/callEndpoint", token: token, body: %{})
        |> REST.call(REST.init(audience: :admin))

      assert conn.status == 403
      refute_received {:host_tool_ran, _}
    end

    test "listings show the name, never an alias", %{token: token} do
      conn = :get |> api_conn("/", token: token) |> REST.call(REST.init(audience: :admin))
      names = Enum.map(json(conn)["tools"], & &1["name"])

      assert "call_endpoint" in names
      refute "callEndpoint" in names
      refute "legacyhost.call" in names
    end

    test "the alias of a hidden tool is as unknown as its name" do
      put_setting("api_disabled_tools", "call_endpoint")
      assert Registry.find("callEndpoint", :admin) == {:error, :not_found}
    end

    test "a tool listed in api_disabled_tools by one of its aliases is hidden too" do
      put_setting("api_disabled_tools", "legacyhost.call")

      for name <- ["call_endpoint", "callEndpoint", "legacyhost.call"] do
        assert Registry.find(name, :admin) == {:error, :not_found}
      end
    end

    test "MCP reaches a dotted alias by its underscore form too" do
      assert Names.resolve("legacyhost_call", :admin) == "legacyhost.call"
      assert {:ok, %Tool{name: "call_endpoint"}} = Registry.find("legacyhost.call", :admin)
    end
  end

  describe "the collision check" do
    test "the modules of the suite pass, and so does a set of dotted names alone" do
      assert ModuleRegistry.check_api_tool_names!([ApiTools]) == :ok

      Scripted.put([tool("dotonly.a_b"), tool("dotonly_a.b")])
      assert ModuleRegistry.check_api_tool_names!([ApiTools, Scripted]) == :ok
    end

    test "an alias that is another tool's name, MCP name or alias is refused" do
      for clash <- ["testkit.read_items", "testkit_read_items"] do
        Scripted.put([tool("scripted.x", aliases: [clash])])

        error =
          assert_raise ArgumentError, fn ->
            ModuleRegistry.check_api_tool_names!([ApiTools, Scripted])
          end

        assert error.message =~ "is a name, MCP name or alias of testkit.read_items"
        assert error.message =~ "scripted.x"
      end

      Scripted.put([tool("scripted.x", aliases: ["callEndpoint"])])

      assert_raise ArgumentError, ~r/callEndpoint/, fn ->
        ModuleRegistry.check_api_tool_names!([HostTools, Scripted])
      end
    end

    test "an undotted name that is another tool's MCP name is refused" do
      Scripted.put([tool("call_endpoint")])

      assert_raise ArgumentError, ~r/call_endpoint/, fn ->
        ModuleRegistry.check_api_tool_names!([HostTools, Scripted])
      end
    end

    test "the same name on the other audience is no clash" do
      Scripted.put([tool("callEndpoint", audience: :public)])
      assert ModuleRegistry.check_api_tool_names!([HostTools, Scripted]) == :ok
    end

    test "kit namespaces are reserved for undotted names and aliases" do
      cases = [
        tool("system_info"),
        tool("scripted.x", aliases: ["system.whoami"]),
        tool("testkit_more"),
        tool("scripted.y", aliases: ["TestKit-thing"]),
        tool("scripted.z", aliases: ["testkit.other"])
      ]

      for reserved <- cases do
        Scripted.put([reserved])

        assert_raise ArgumentError, ~r/reserved namespace/, fn ->
          ModuleRegistry.check_api_tool_names!([ApiTools, Scripted])
        end
      end
    end

    test "a module's own namespace is not reserved against itself" do
      Scripted.put([tool("scripted.list"), tool("scripted_legacy", aliases: ["scripted-old"])])
      assert ModuleRegistry.check_api_tool_names!([ApiTools, Scripted]) == :ok
    end

    test "register/1 refuses the module with the message, and leaves it out" do
      Scripted.put([tool("scripted.x", aliases: ["testkit_read_items"])])

      assert_raise ArgumentError, ~r/collide/, fn -> ModuleRegistry.register(Scripted) end
      refute Scripted in ModuleRegistry.all_modules()
    end

    test "ToolLint reports an alias collision inside one module's set" do
      assert {:error, messages} =
               ToolLint.check_tools([tool("a.list"), tool("a.other", aliases: ["a_list"])])

      assert Enum.any?(messages, &(&1 =~ "a_list"))
    end
  end
end
