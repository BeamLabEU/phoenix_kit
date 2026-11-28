defmodule PhoenixKitWeb.RootRoutesOptionTest do
  @moduledoc """
  `phoenix_kit_routes(root: ...)`: which files the kit declares at the site root. The
  default (`:all`, the test router) is today's table; a group left out is not declared, so
  the path is free for the host. And `config :phoenix_kit, hide_disabled_routes: true`,
  the runtime 404 of the sitemap's stylesheets and redirect while Sitemap is off.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKitWeb.Integration

  @root_files %{
    llms: ["/llms.txt"],
    sitemap: ["/sitemap.xml", "/sitemap.html", "/sitemaps/:filename", "/sitemap.xsl"],
    sitemap_assets: ["/assets/sitemap/:style", "/assets/sitemap-index/:style"],
    mcp: ["/mcp"],
    well_known: [
      "/.well-known/api-catalog",
      "/.well-known/oauth-authorization-server"
    ]
  }

  defp paths(router), do: router.__routes__() |> Enum.map(& &1.path) |> MapSet.new()

  defp compile_router(opts) do
    module = Module.concat(__MODULE__, "Router#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use PhoenixKitWeb, :router

          import PhoenixKitWeb.Integration
          import PhoenixKitWeb.Users.Auth

          pipeline :browser do
            plug :accepts, ["html"]
          end

          phoenix_kit_routes(unquote(opts))
        end
      end
    )

    module
  end

  describe "root_groups!/1" do
    test "the default and :all are every group" do
      all = [:mcp, :llms, :sitemap, :well_known, :sitemap_assets]
      assert Integration.root_groups!([]) == all
      assert Integration.root_groups!(root: :all) == all
    end

    test "false is none, a list is those groups" do
      assert Integration.root_groups!(root: false) == []
      assert Integration.root_groups!(root: [:sitemap, :llms]) == [:llms, :sitemap]
    end

    test "anything else is a compile error" do
      for opts <- [[root: [:nope]], [root: true], [root: "llms"], :all] do
        assert_raise ArgumentError, ~r/phoenix_kit_routes/, fn ->
          Integration.root_groups!(opts)
        end
      end
    end
  end

  describe "a kit mounted under a prefix" do
    test "the test router (no option) still declares every root file" do
      prefix = Config.get_url_prefix()
      assert prefix != "/"
      paths = paths(PhoenixKitWeb.Router)

      for {_group, files} <- @root_files, file <- files do
        assert file in paths, "#{file} is missing at the root"

        assert (prefix <> file) in paths or String.starts_with?(file, "/.well-known"),
               "#{prefix <> file} is missing under the prefix"
      end

      assert Enum.any?(paths, &String.starts_with?(&1, "/.well-known/oauth-protected-resource"))
    end

    test "root: false declares no root file and keeps the prefixed copies" do
      prefix = Config.get_url_prefix()
      paths = paths(compile_router(root: false))

      for {_group, files} <- @root_files, file <- files do
        refute file in paths, "#{file} is still declared at the root"
      end

      refute Enum.any?(paths, &String.starts_with?(&1, "/.well-known/"))

      for file <- @root_files.llms ++ @root_files.sitemap ++ @root_files.mcp do
        assert (prefix <> file) in paths
      end

      # The MCP servers and the REST API are not root files.
      assert Enum.any?(paths, &String.starts_with?(&1, prefix <> "/mcp/"))
    end

    test "root: [:llms, :sitemap] declares those groups only" do
      paths = paths(compile_router(root: [:llms, :sitemap]))

      for file <- @root_files.llms ++ @root_files.sitemap, do: assert(file in paths)

      for file <- @root_files.sitemap_assets ++ @root_files.mcp ++ @root_files.well_known,
          do: refute(file in paths)
    end
  end

  describe "a kit mounted at the root" do
    setup do
      previous = Application.fetch_env(:phoenix_kit, :url_prefix)
      Application.put_env(:phoenix_kit, :url_prefix, "/")
      Config.clear_url_prefix_cache()

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit, :url_prefix, value)
          :error -> Application.delete_env(:phoenix_kit, :url_prefix)
        end

        Config.clear_url_prefix_cache()
      end)

      :ok
    end

    test "root: [:mcp] leaves only the guide of the root files, each declared once" do
      routes = compile_router(root: [:mcp]).__routes__()
      paths = Enum.map(routes, & &1.path)

      assert Enum.count(paths, &(&1 == "/mcp")) == 2
      assert "/mcp/admin" in paths or Enum.any?(paths, &String.starts_with?(&1, "/mcp/"))

      for file <- @root_files.llms ++ @root_files.sitemap ++ @root_files.well_known,
          do: refute(file in paths)
    end
  end

  # The switch itself, as the Modules page stores it (`disable_system/0` also cancels the
  # module's Oban jobs, which the test endpoint does not run).
  defp sitemap(on?) do
    {:ok, _} = PhoenixKit.Settings.update_boolean_setting("sitemap_enabled", on?)
    assert Sitemap.enabled?() == on?
  end

  describe "hide_disabled_routes" do
    setup do
      start_supervised!({PhoenixKit.Cache.Registry, []})

      start_supervised!(
        Supervisor.child_spec({PhoenixKit.Cache, name: :settings}, id: :settings_cache)
      )

      sitemap(false)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :hide_disabled_routes) end)
      :ok
    end

    test "unset: the stylesheets and the redirect answer as before while Sitemap is off",
         %{conn: conn} do
      refute Config.hide_disabled_routes?()

      assert get(conn, "/assets/sitemap/table").status == 200
      assert get(conn, "/assets/sitemap-index/minimal").status == 200
      assert get(conn, "/sitemap.html").status == 302
    end

    test "true: they answer 404 while Sitemap is off", %{conn: conn} do
      Application.put_env(:phoenix_kit, :hide_disabled_routes, true)

      assert get(conn, "/assets/sitemap/table").status == 404
      assert get(conn, "/assets/sitemap-index/minimal").status == 404
      assert get(conn, "/sitemap.html").status == 404
    end

    test "true: they answer as usual while Sitemap is on", %{conn: conn} do
      Application.put_env(:phoenix_kit, :hide_disabled_routes, true)
      sitemap(true)

      assert get(conn, "/assets/sitemap/table").status == 200
      assert get(conn, "/sitemap.html").status == 302
    end
  end
end
