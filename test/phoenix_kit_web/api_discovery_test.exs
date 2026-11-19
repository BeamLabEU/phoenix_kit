defmodule PhoenixKitWeb.APIDiscoveryTest do
  @moduledoc """
  The public pages about the public API through the real endpoint and router:
  the guide `GET /mcp`, the API catalog, the `Link` headers and the API section
  of `/llms.txt`. What each one answers when the API is hidden, which host and
  language it uses, how it is cached, and that it never names the admin API.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.Test.ApiHarness

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.MCP
  alias PhoenixKit.API.MCP.Names
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.API.PublicDiscovery
  alias PhoenixKit.API.RateLimit
  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.Validator
  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Crawlers.LlmsTxt
  alias PhoenixKit.Modules.Crawlers.Web.Controller, as: CrawlersController
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.DiscoveryTools
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.WebsiteAccess.AllowedAddresses
  alias PhoenixKit.WebsiteAccess.Gate
  alias PhoenixKitWeb.Controllers.ApiDiscovery

  @router PhoenixKitWeb.Router

  defmodule Hook do
    @moduledoc false
    def two_domains(conn) do
      case conn.host do
        "b.test" -> %{hosts: ["a.test", "b.test"], language: "fr"}
        _other -> %{hosts: ["a.test", "b.test"], language: "de"}
      end
    end

    def language_only(_conn), do: %{language: "de"}
    def junk_hosts(_conn), do: %{hosts: ["a.test", 1], language: "de"}
    def raises(_conn), do: raise("hook failure")
    def odd_host(_conn), do: %{hosts: ["x.com;id", "Bad_Host.test", "a.test"]}
    def unknown_language(_conn), do: %{language: "zz-ZZ"}
    def dialect(_conn), do: %{language: "es-ES"}
  end

  setup do
    KeyTestSupport.start_cache_registry!()

    start_supervised!(
      Supervisor.child_spec({PhoenixKit.Cache, name: :settings}, id: :settings_cache)
    )

    DiscoveryTools.register!()
    {:ok, _} = Crawlers.enable_module()
    switch(:public, true)
    put_setting("site_url", "https://shop.test")
    put_setting("project_title", "Acme Print")

    on_exit(fn -> Application.delete_env(:phoenix_kit, :api_request_context) end)
    :ok
  end

  defp hook(fun), do: Application.put_env(:phoenix_kit, :api_request_context, {Hook, fun})

  defp route_info(verb, path, host \\ "localhost"),
    do: Phoenix.Router.route_info(@router, verb, path, host)

  defp fetch(conn, path, opts \\ []) do
    conn =
      conn
      |> with_client_ip(Keyword.get_lazy(opts, :ip, &unique_ip/0))
      |> then(fn conn ->
        Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {name, value}, acc ->
          put_req_header(acc, name, value)
        end)
      end)

    conn = if host = opts[:host], do: %{conn | host: host}, else: conn
    conn = if port = opts[:port], do: %{conn | port: port}, else: conn
    conn = if peer = opts[:peer], do: %{conn | remote_ip: peer}, else: conn

    dispatch(conn, @endpoint, Keyword.get(opts, :method, :get), path, nil)
  end

  defp guide(conn, opts \\ []), do: fetch(conn, Routes.path("/mcp"), opts)

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  defp turn_gate_on(allowed_ip) do
    {:ok, _} = Gate.set_password("Secret42")
    {:ok, _} = Gate.set_enabled(true)
    {:ok, _} = Settings.update_setting(AllowedAddresses.key(), allowed_ip)
  end

  describe "the routes" do
    test "GET /mcp is routed at the kit prefix and at the root, to the guide" do
      for path <- [Routes.path("/mcp"), "/mcp"] do
        assert %{plug: ApiDiscovery, plug_opts: :guide} =
                 route_info("GET", path)
      end
    end

    test "every other method on /mcp reaches the 405 action" do
      for verb <- ["POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
          path <- [Routes.path("/mcp"), "/mcp"] do
        assert %{plug: ApiDiscovery, plug_opts: :not_allowed} =
                 route_info(verb, path)
      end
    end

    test "the API catalog is at the site root, not under the kit prefix" do
      assert %{plug_opts: :api_catalog} = route_info("GET", "/.well-known/api-catalog")

      if Routes.prefix_base() != "" do
        assert route_info("GET", Routes.prefix_base() <> "/.well-known/api-catalog") == :error
      end
    end

    test "/mcp/public and /mcp/admin are still the MCP forwards" do
      assert %{plug: MCP, plug_opts: [audience: :public]} =
               route_info("POST", Routes.path("/mcp/public"))

      assert %{plug: MCP, plug_opts: [audience: :admin]} =
               route_info("POST", Routes.path("/mcp/admin"))
    end

    test "the guide route has no browser pipeline: no session, no CSRF, no CrawlerBlocker" do
      assert %{pipe_through: []} = route_info("GET", Routes.path("/mcp"))
    end
  end

  describe "the visibility gate" do
    test "everything is published when the switch is on, the site is open and a tool is visible",
         %{conn: conn} do
      assert guide(conn).status == 200
      assert fetch(conn, "/.well-known/api-catalog").status == 200
    end

    test "public API off: /mcp, ?format=md and the catalog are the API's own 404", %{conn: conn} do
      switch(:public, false)

      for path <- [
            Routes.path("/mcp"),
            Routes.path("/mcp") <> "?format=md",
            "/.well-known/api-catalog"
          ] do
        conn = fetch(conn, path)
        assert conn.status == 404, path
        assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
        assert header(conn, "cache-control") == "no-store"
        assert %{"code" => "not_found", "status" => 404} = json(conn)
      end
    end

    test "the 404 is the body of the public API's own 404", %{conn: conn} do
      switch(:public, false)
      api = fetch(conn, Routes.path("/api/public/v1"))
      hidden = guide(conn)

      assert Map.delete(json(api), "request_id") == Map.delete(json(hidden), "request_id")
    end

    test "website gate on: a non-allowed address gets the 404, an allowed one the page", %{
      conn: conn
    } do
      allowed = unique_ip()
      turn_gate_on(allowed)

      assert guide(conn).status == 404
      assert fetch(conn, "/.well-known/api-catalog").status == 404
      assert guide(conn, ip: allowed).status == 200
      assert fetch(conn, "/.well-known/api-catalog", ip: allowed).status == 200
    end

    test "zero visible public tools: the same 404", %{conn: conn} do
      DiscoveryTools.set_enabled(false)
      assert Registry.visible_tools(:public, :all) == []

      assert guide(conn).status == 404
      assert fetch(conn, "/.well-known/api-catalog").status == 404
    end

    test "the order is visibility, method, representation: a hidden guide is a 404 for POST and event-stream too",
         %{conn: conn} do
      switch(:public, false)

      assert guide(conn, method: :post).status == 404
      assert guide(conn, headers: [{"accept", "text/event-stream"}]).status == 404

      switch(:public, true)
      assert guide(conn, method: :post).status == 405
      assert guide(conn, headers: [{"accept", "text/event-stream"}]).status == 406
    end

    test "a hidden tool (api_disabled_tools) disappears from the guide; a new tool appears", %{
      conn: conn
    } do
      assert guide(conn).resp_body =~ "zzdisc.search_things"

      put_setting("api_disabled_tools", "zzdisc.search_things")
      body = guide(conn).resp_body
      refute body =~ "zzdisc.search_things"
      assert body =~ "zzdisc.add_thing"

      DiscoveryTools.put_extra([
        DiscoveryTools.public_tool("zzdisc.brand_new", title: "Brand new")
      ])

      assert guide(conn).resp_body =~ "zzdisc.brand_new"
    end
  end

  describe "the guide: representation" do
    test "HTML by default, with the alternate link, Vary and content-language", %{conn: conn} do
      conn = guide(conn)

      assert conn.status == 200
      assert header(conn, "content-type") == "text/html; charset=utf-8"
      assert header(conn, "vary") == "accept"
      assert header(conn, "content-language") == "en"
      assert conn.resp_body =~ ~s(<html lang="en">)
      assert conn.resp_body =~ ~s(<link rel="alternate" type="text/markdown" href="?format=md">)
      refute conn.resp_body =~ "<script"
    end

    test "the Accept matrix", %{conn: conn} do
      html = "text/html; charset=utf-8"
      markdown = "text/markdown; charset=utf-8"

      matrix = [
        {"*/*", 200, html},
        {"text/html", 200, html},
        {"text/markdown", 200, markdown},
        {"text/markdown;q=0.5, text/html", 200, html},
        {"text/markdown, text/html;q=0.5", 200, markdown},
        {"text/markdown, text/html", 200, html},
        {"text/markdown, */*", 200, html},
        {"text/markdown, */*;q=0.1", 200, markdown},
        {"text/event-stream", 406, "application/problem+json; charset=utf-8"},
        {"application/json, text/event-stream", 406, "application/problem+json; charset=utf-8"},
        {"text/event-stream, */*", 200, html},
        {"text/event-stream, text/html", 200, html},
        {"application/xml", 200, html},
        {"not a header at all", 200, html}
      ]

      for {accept, status, type} <- matrix do
        conn = guide(conn, headers: [{"accept", accept}])
        assert {accept, conn.status, header(conn, "content-type")} == {accept, status, type}
        assert header(conn, "vary") == "accept", accept
      end

      assert header(guide(conn), "content-type") == html
    end

    test "?format=md wins over Accept", %{conn: conn} do
      conn =
        fetch(conn, Routes.path("/mcp") <> "?format=md", headers: [{"accept", "text/html"}])

      assert header(conn, "content-type") == "text/markdown; charset=utf-8"
      assert conn.resp_body =~ "# Acme Print"
    end

    test "the 406 points to the MCP server", %{conn: conn} do
      conn = guide(conn, headers: [{"accept", "text/event-stream"}])

      assert %{"code" => "not_acceptable", "status" => 406, "detail" => detail} = json(conn)
      assert detail =~ "https://shop.test" <> Routes.path("/mcp/public")
    end

    test "HEAD answers like GET, without a body", %{conn: conn} do
      ip = unique_ip()
      get_conn = guide(conn, ip: ip)
      head_conn = guide(conn, ip: ip, method: :head)

      assert head_conn.status == 200
      assert head_conn.resp_body == ""

      for name <- ["content-type", "cache-control", "vary", "content-language", "link"] do
        assert header(head_conn, name) == header(get_conn, name), name
      end
    end

    test "POST (a client given the guide URL as its server URL) is a 405 with Allow", %{
      conn: conn
    } do
      for method <- [:post, :put, :delete, :patch, :options] do
        conn = guide(conn, method: method)

        assert conn.status == 405, "#{method} gave #{conn.status}"
        assert header(conn, "allow") == "GET, HEAD"
        assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
        assert %{"code" => "method_not_allowed", "detail" => detail} = json(conn)
        assert detail =~ "https://shop.test" <> Routes.path("/mcp/public")
      end
    end

    test "the guide is served at the site root as well", %{conn: conn} do
      conn = fetch(conn, "/mcp")
      assert conn.status == 200
      assert conn.resp_body =~ "https://shop.test" <> Routes.path("/mcp/public")
    end
  end

  describe "the guide: content" do
    test "names the servers and lists the tools sorted, with both names", %{conn: conn} do
      body = fetch(conn, Routes.path("/mcp") <> "?format=md").resp_body

      assert body =~ "# Acme Print — public API and MCP server"
      assert body =~ "https://shop.test" <> Routes.path("/mcp/public")
      assert body =~ "https://shop.test" <> Routes.path("/api/public/v1")
      assert body =~ "https://shop.test" <> Routes.path("/api/public/v1/openapi.json")

      names = Regex.scan(~r/REST name: `(zzdisc\.[a-z_]+)`/, body, capture: :all_but_first)
      names = Enum.map(names, &hd/1)
      assert names == Enum.sort(names)
      assert "zzdisc.search_things" in names
      assert body =~ "MCP name: `zzdisc_search_things`"
      assert body =~ "Second line of the description."
    end

    test "only the tool with a danger says it may ask for confirmation", %{conn: conn} do
      body = fetch(conn, Routes.path("/mcp") <> "?format=md").resp_body
      [_, add_thing] = String.split(body, "### Add a thing")
      [add_thing | _] = String.split(add_thing, "### ")

      assert add_thing =~ "May ask for confirmation first."
      assert length(String.split(body, "May ask for confirmation first.")) == 2
    end

    test "the curl example is the first read-only tool, by name, without required input", %{
      conn: conn
    } do
      body = fetch(conn, Routes.path("/mcp") <> "?format=md").resp_body

      assert body =~
               "curl -X POST 'https://shop.test#{Routes.path("/api/public/v1")}/zzdisc.markup_tool' -H 'content-type: application/json' -d '{}'"
    end

    test "no read-only tool without required input: no example", %{conn: conn} do
      put_setting("api_disabled_tools", "zzdisc.search_things\nzzdisc.markup_tool")
      body = fetch(conn, Routes.path("/mcp") <> "?format=md").resp_body

      refute body =~ "curl -X"
      assert body =~ "zzdisc.browse_required"
    end

    test "the JSON snippets decode and the shell snippet single-quotes the URL", %{conn: conn} do
      body = fetch(conn, Routes.path("/mcp") <> "?format=md").resp_body
      mcp_url = "https://shop.test" <> Routes.path("/mcp/public")

      [cursor] = Regex.run(~r/```json\n(\{"mcpServers".*)\n```/, body, capture: :all_but_first)
      assert JSON.decode!(cursor) == %{"mcpServers" => %{"acme-print" => %{"url" => mcp_url}}}

      [vscode] = Regex.run(~r/```json\n(\{"servers".*)\n```/, body, capture: :all_but_first)

      assert JSON.decode!(vscode) ==
               %{"servers" => %{"acme-print" => %{"type" => "http", "url" => mcp_url}}}

      assert body =~ "claude mcp add --transport http acme-print '#{mcp_url}'"
    end

    test "the curl example passes the validator of its tool", %{conn: conn} do
      body = fetch(conn, Routes.path("/mcp") <> "?format=md").resp_body
      [_, name, payload] = Regex.run(~r{/api/public/v1/([a-z_.]+)' -H '[^']+' -d '([^']*)'}, body)

      {:ok, tool} = Registry.find(name, :public)

      assert {:ok, _} =
               Validator.validate(
                 Executor.input_schema(tool),
                 JSON.decode!(payload)
               )
    end

    test "a description with markup is shown as text in the HTML", %{conn: conn} do
      body = guide(conn).resp_body

      refute body =~ "<script>alert(1)"
      refute body =~ "<img src=x"
      assert body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert body =~ "&lt;img src=x onerror=alert(2)&gt;"
      assert body =~ "&amp; &quot;quoted&quot;"
    end

    test "the page links the OpenAPI document, the Markdown page, llms.txt and the catalog", %{
      conn: conn
    } do
      body = fetch(conn, Routes.path("/mcp") <> "?format=md").resp_body

      assert body =~ "(https://shop.test#{Routes.path("/api/public/v1/openapi.json")})"
      assert body =~ "(https://shop.test#{Routes.path("/mcp")}?format=md)"
      assert body =~ "(https://shop.test/llms.txt)"
      assert body =~ "(https://shop.test/.well-known/api-catalog)"
    end

    test "llms.txt is not linked while the Crawlers module is off", %{conn: conn} do
      Crawlers.disable_module()
      body = fetch(conn, Routes.path("/mcp") <> "?format=md").resp_body

      refute body =~ "llms.txt"
      assert body =~ "api-catalog"
    end
  end

  describe "the base URL and the host" do
    test "a default install trusts only the canonical host: Host: www.example.com is not used", %{
      conn: conn
    } do
      body = guide(conn, host: "www.example.com").resp_body
      assert body =~ "https://shop.test" <> Routes.path("/mcp/public")
      refute body =~ "www.example.com"
    end

    test "a hook that lists two hosts: each gets its own host, the scheme and port are the canonical ones",
         %{conn: conn} do
      hook(:two_domains)

      a = fetch(conn, Routes.path("/mcp") <> "?format=md", host: "a.test").resp_body
      b = fetch(conn, Routes.path("/mcp") <> "?format=md", host: "b.test", port: 4000).resp_body

      assert a =~ "https://a.test" <> Routes.path("/mcp/public")
      assert b =~ "https://b.test" <> Routes.path("/mcp/public")
      refute b =~ "b.test:4000"
    end

    test "the request's port and scheme never reach a URL, whatever the host", %{conn: conn} do
      hook(:two_domains)

      for host <- ["shop.test", "a.test"] do
        response =
          fetch(conn, Routes.path("/mcp") <> "?format=md", host: host, port: 1337)

        assert response.resp_body =~ "https://#{host}" <> Routes.path("/mcp/public"), host
        refute response.resp_body =~ "1337", host
        refute response.resp_body =~ "http://#{host}", host

        catalog = fetch(conn, "/.well-known/api-catalog", host: host, port: 1337)
        refute catalog.resp_body =~ "1337", host
        refute header(catalog, "link") =~ "1337", host
      end
    end

    test "a canonical origin with a scheme and a port is given to its own host and to the hook hosts",
         %{conn: conn} do
      put_setting("site_url", "http://shop.test:8443")
      hook(:two_domains)

      for host <- ["shop.test", "a.test"] do
        body = fetch(conn, Routes.path("/mcp") <> "?format=md", host: host, port: 1337).resp_body

        assert body =~ "http://#{host}:8443" <> Routes.path("/mcp/public"), host
        refute body =~ "1337", host
      end
    end

    test "a hook with no :hosts, with a bad list, or that raises: only the canonical host", %{
      conn: conn
    } do
      for fun <- [:language_only, :junk_hosts, :raises] do
        hook(fun)

        capture_log(fn ->
          body = fetch(conn, Routes.path("/mcp") <> "?format=md", host: "a.test").resp_body
          assert body =~ "https://shop.test" <> Routes.path("/mcp/public"), "#{fun}"
          refute body =~ "a.test", "#{fun}"
        end)
      end
    end

    test "hostile and unknown hosts fall back to the canonical origin", %{conn: conn} do
      hook(:two_domains)

      for host <- [
            "x.com;id",
            "x.com$(id)",
            "x.com'; id #",
            "a.test\n",
            "a.test.",
            "-a.test",
            "evil.example",
            "a.test.evil.example",
            "[::1]"
          ] do
        body = fetch(conn, Routes.path("/mcp") <> "?format=md", host: host).resp_body
        assert body =~ "https://shop.test" <> Routes.path("/mcp/public"), inspect(host)
        refute body =~ "evil", inspect(host)
        refute body =~ "id #", inspect(host)
      end
    end

    test "a listed host that is not a plain hostname is never used (a misconfigured hook)", %{
      conn: conn
    } do
      hook(:odd_host)

      for host <- ["x.com;id", "Bad_Host.test"] do
        body = fetch(conn, Routes.path("/mcp") <> "?format=md", host: host).resp_body
        assert body =~ "https://shop.test" <> Routes.path("/mcp/public"), host
        refute body =~ ";id", host
        refute body =~ "bad_host", host
      end

      body = fetch(conn, Routes.path("/mcp") <> "?format=md", host: "a.test").resp_body
      assert body =~ "https://a.test" <> Routes.path("/mcp/public")
    end

    test "X-Forwarded-Proto is believed from nobody: the scheme is the canonical one", %{
      conn: conn
    } do
      hook(:two_domains)
      forwarded = [{"x-forwarded-proto", "http"}]
      path = Routes.path("/mcp") <> "?format=md"

      local = fetch(conn, path, host: "a.test", headers: forwarded).resp_body

      stranger =
        fetch(conn, path, host: "a.test", headers: forwarded, peer: {203, 0, 113, 9}).resp_body

      assert local =~ "https://a.test" <> Routes.path("/mcp/public")
      assert stranger =~ "https://a.test" <> Routes.path("/mcp/public")
    end

    test "the fallback reads no database row once the settings are cached" do
      conn = %{Plug.Test.conn(:get, Routes.path("/mcp")) | host: "evil.example"}
      _warm = PublicDiscovery.origin(conn)

      {origin, queries} = count_queries(fn -> PublicDiscovery.origin(conn) end)

      assert origin == "https://shop.test"
      assert queries == 0
    end

    test "under a URL prefix the guide URLs carry it; /llms.txt and the catalog stay at the root",
         %{conn: conn} do
      body = fetch(conn, Routes.path("/mcp") <> "?format=md").resp_body
      prefix = Routes.prefix_base()

      assert body =~ "https://shop.test#{prefix}/mcp/public"
      assert body =~ "https://shop.test#{prefix}/api/public/v1"
      assert body =~ "(https://shop.test/llms.txt)"
      assert body =~ "(https://shop.test/.well-known/api-catalog)"
    end
  end

  describe "the page language" do
    test "follows the language of the domain; the text is translated", %{conn: conn} do
      hook(:two_domains)

      a = fetch(conn, Routes.path("/mcp"), host: "a.test")
      b = fetch(conn, Routes.path("/mcp"), host: "b.test")

      assert header(a, "content-language") == "de"
      assert a.resp_body =~ ~s(<html lang="de">)
      assert a.resp_body =~ "Acme Print — öffentliche API und MCP-Server"
      assert a.resp_body =~ "Per MCP verbinden"

      assert header(b, "content-language") == "fr"
      assert b.resp_body =~ ~s(<html lang="fr">)
      assert b.resp_body =~ "Acme Print — API publique et serveur MCP"
    end

    test "a dialect is reduced to the base catalogue; an unknown language is English", %{
      conn: conn
    } do
      hook(:dialect)
      es = guide(conn)
      assert header(es, "content-language") == "es"
      assert es.resp_body =~ "Conectar con MCP"

      hook(:unknown_language)
      unknown = guide(conn)
      assert header(unknown, "content-language") == "en"
      assert unknown.resp_body =~ "Connect with MCP"
    end

    test "the tool texts stay as declared", %{conn: conn} do
      hook(:two_domains)
      body = fetch(conn, Routes.path("/mcp"), host: "a.test").resp_body

      assert body =~ "Finds things."
      assert body =~ "Search things"
    end

    test "the page does not change the process locale", %{conn: conn} do
      hook(:two_domains)
      before = Gettext.get_locale(PhoenixKitWeb.Gettext)
      fetch(conn, Routes.path("/mcp"), host: "a.test")
      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == before
    end
  end

  describe "caching" do
    test "website gate off: public, max-age=300 on the guide, the Markdown and the catalog", %{
      conn: conn
    } do
      for path <- [
            Routes.path("/mcp"),
            Routes.path("/mcp") <> "?format=md",
            "/.well-known/api-catalog"
          ] do
        assert header(fetch(conn, path), "cache-control") == "public, max-age=300", path
      end
    end

    test "website gate on: private, no-store, because the answer depends on the address", %{
      conn: conn
    } do
      allowed = unique_ip()
      turn_gate_on(allowed)

      for path <- [
            Routes.path("/mcp"),
            Routes.path("/mcp") <> "?format=md",
            "/.well-known/api-catalog"
          ] do
        assert header(fetch(conn, path, ip: allowed), "cache-control") == "private, no-store",
               path
      end
    end

    test "a 404 is no-store", %{conn: conn} do
      switch(:public, false)
      assert header(guide(conn), "cache-control") == "no-store"
    end

    test "no rate-limit counter moves for the discovery pages", %{conn: conn} do
      ip = unique_ip()
      KeyTestSupport.set_limit("api_public_ip_rate_per_min", 5)

      for _ <- 1..8 do
        guide(conn, ip: ip)
        fetch(conn, Routes.path("/mcp") <> "?format=md", ip: ip)
        fetch(conn, "/.well-known/api-catalog", ip: ip)
        fetch(conn, "/llms.txt", ip: ip)
      end

      assert {:ok, headers} = RateLimit.check_public(ip, nil, 1)
      assert KeyTestSupport.header_value(headers, "ratelimit-remaining") == 4
    end
  end

  describe "the API catalog" do
    test "RFC 9727 content type, linkset, CORS, Link and cache", %{conn: conn} do
      conn = fetch(conn, "/.well-known/api-catalog")
      api = "https://shop.test" <> Routes.path("/api/public/v1")

      assert conn.status == 200

      assert header(conn, "content-type") ==
               ~s(application/linkset+json; profile="https://www.rfc-editor.org/info/rfc9727")

      assert header(conn, "access-control-allow-origin") == "*"

      assert header(conn, "link") ==
               ~s(<https://shop.test/.well-known/api-catalog>; rel="api-catalog")

      assert json(conn) == %{
               "linkset" => [
                 %{
                   "anchor" => "https://shop.test/.well-known/api-catalog",
                   "item" => [%{"href" => api}]
                 },
                 %{
                   "anchor" => api,
                   "service-desc" => [
                     %{"href" => api <> "/openapi.json", "type" => "application/json"}
                   ],
                   "service-doc" => [
                     %{
                       "href" => "https://shop.test" <> Routes.path("/mcp"),
                       "type" => "text/html"
                     }
                   ]
                 }
               ]
             }
    end

    test "HEAD carries the same Link and no body; Accept is ignored", %{conn: conn} do
      head = fetch(conn, "/.well-known/api-catalog", method: :head)
      assert head.status == 200
      assert head.resp_body == ""
      assert header(head, "link") =~ ~s(rel="api-catalog")

      json_only =
        fetch(conn, "/.well-known/api-catalog", headers: [{"accept", "application/json"}])

      assert json_only.status == 200
    end
  end

  describe "Link headers" do
    @catalog ~s(<https://shop.test/.well-known/api-catalog>; rel="api-catalog")

    test "the guide and llms.txt point to the catalog", %{conn: conn} do
      assert header(guide(conn), "link") == @catalog
      assert header(fetch(conn, "/llms.txt"), "link") == @catalog
    end

    test "GET /api/public/v1 points to the OpenAPI document and the guide", %{conn: conn} do
      conn = fetch(conn, Routes.path("/api/public/v1"))
      assert conn.status == 200

      assert header(conn, "link") ==
               ~s(<https://shop.test#{Routes.path("/api/public/v1/openapi.json")}>; rel="service-desc", ) <>
                 ~s(<https://shop.test#{Routes.path("/mcp")}>; rel="service-doc")
    end

    test "the REST list answers 200 with no Link when no public tool is visible", %{conn: conn} do
      DiscoveryTools.set_enabled(false)
      conn = fetch(conn, Routes.path("/api/public/v1"))

      assert conn.status == 200
      assert header(conn, "link") == nil
    end

    test "the REST list has no Link on an error answer", %{conn: conn} do
      KeyTestSupport.set_limit("api_public_ip_rate_per_min", 1)
      ip = unique_ip()
      assert fetch(conn, Routes.path("/api/public/v1"), ip: ip).status == 200
      limited = fetch(conn, Routes.path("/api/public/v1"), ip: ip)

      assert limited.status == 429
      assert header(limited, "link") == nil
    end

    test "the 405 of GET /mcp/public points to the guide; the admin one does not", %{conn: conn} do
      conn = fetch(conn, Routes.path("/mcp/public"))
      assert conn.status == 405

      assert header(conn, "link") ==
               ~s(<https://shop.test#{Routes.path("/mcp")}>; rel="service-doc")
    end

    test "a Link header an earlier plug set is kept: ours is appended to it" do
      earlier = ~s(<https://host.test/preload>; rel="preload")
      base = Plug.Test.conn(:get, Routes.path("/mcp/public"))
      base = %{base | host: "shop.test"} |> put_resp_header("link", earlier)

      assert base |> PublicDiscovery.put_service_doc_link() |> header("link") ==
               earlier <> ", " <> ~s(<https://shop.test#{Routes.path("/mcp")}>; rel="service-doc")

      listed =
        base
        |> PublicDiscovery.put_list_links()
        |> send_resp(200, "")

      assert header(listed, "link") =~ earlier <> ", <https://shop.test"
      assert header(listed, "link") =~ ~s(rel="service-desc")
      assert header(listed, "link") =~ ~s(rel="service-doc")

      for action <- [:guide, :api_catalog] do
        answered = apply(ApiDiscovery, action, [base, %{}])

        assert header(answered, "link") == earlier <> ", " <> @catalog, "#{action}"
      end

      llms = CrawlersController.llms_txt(base, %{})
      assert header(llms, "link") == earlier <> ", " <> @catalog
    end

    test "the 405 of GET /mcp/public has no Link when no tool is visible", %{conn: conn} do
      DiscoveryTools.set_enabled(false)
      conn = fetch(conn, Routes.path("/mcp/public"))

      assert conn.status == 405
      assert header(conn, "link") == nil
    end

    test "no Link while the website gate hides the site from the client", %{conn: conn} do
      allowed = unique_ip()
      turn_gate_on(allowed)

      assert header(fetch(conn, "/llms.txt"), "link") == nil
      assert header(fetch(conn, "/llms.txt", ip: allowed), "link") == @catalog
    end
  end

  describe "/llms.txt" do
    test "ends with the API section, URLs at the origin root where the files are", %{conn: conn} do
      conn = fetch(conn, "/llms.txt")
      assert conn.status == 200

      assert conn.resp_body =~
               """

               ## Public API and MCP

               - [How to connect](https://shop.test#{Routes.path("/mcp")}): MCP server and REST API, no key needed
               - [MCP server](https://shop.test#{Routes.path("/mcp/public")}): Streamable HTTP
               - [OpenAPI](https://shop.test#{Routes.path("/api/public/v1/openapi.json")})
               """

      assert String.ends_with?(conn.resp_body, ")\n")
      assert header(conn, "cache-control") == "public, max-age=3600"
    end

    test "the section comes after the operator's text", %{conn: conn} do
      Crawlers.update_llms_txt_extra("> About us.")
      body = fetch(conn, "/llms.txt").resp_body

      assert body =~ "# Acme Print\n\n> About us.\n\n## Public API and MCP\n"
    end

    test "no section while the API is hidden", %{conn: conn} do
      switch(:public, false)
      conn = fetch(conn, "/llms.txt")

      assert conn.resp_body == "# Acme Print\n"
      assert header(conn, "cache-control") == "public, max-age=3600"
    end

    test "website gate on: the file with the section is private, no-store; without it, unchanged",
         %{conn: conn} do
      allowed = unique_ip()
      turn_gate_on(allowed)

      with_section = fetch(conn, "/llms.txt", ip: allowed)
      assert with_section.resp_body =~ "## Public API and MCP"
      assert header(with_section, "cache-control") == "private, no-store"

      without = fetch(conn, "/llms.txt")
      refute without.resp_body =~ "## Public API and MCP"
      assert header(without, "cache-control") == "public, max-age=3600"
    end

    test "the Crawlers settings preview shows the section the site serves for the canonical host",
         %{conn: conn} do
      served = fetch(conn, "/llms.txt").resp_body
      preview = LlmsTxt.build(api_section: preview_section())

      assert preview == served
    end
  end

  describe "nothing names the admin API" do
    setup do
      switch(:admin, true)
      put_setting("api_oauth_enabled", "true")
      :ok
    end

    # Every public document of the module, with its status line and headers.
    defp public_responses(conn) do
      ip = unique_ip()

      [
        {"html", guide(conn, ip: ip)},
        {"markdown", fetch(conn, Routes.path("/mcp") <> "?format=md", ip: ip)},
        {"llms.txt", fetch(conn, "/llms.txt", ip: ip)},
        {"catalog", fetch(conn, "/.well-known/api-catalog", ip: ip)},
        {"405", guide(conn, ip: ip, method: :post)},
        {"406", guide(conn, ip: ip, headers: [{"accept", "text/event-stream"}])},
        {"rest list", fetch(conn, Routes.path("/api/public/v1"), ip: ip)},
        {"openapi", fetch(conn, Routes.path("/api/public/v1/openapi.json"), ip: ip)},
        {"mcp 405", fetch(conn, Routes.path("/mcp/public"), ip: ip)},
        {"mcp tools/list", mcp_list(conn, ip)},
        {"mcp initialize", mcp_initialize(conn, ip)},
        {"oauth prm", fetch(conn, Resource.metadata_path(), ip: ip)},
        {"oauth as", fetch(conn, "/.well-known/oauth-authorization-server", ip: ip)}
      ]
    end

    # The one place a public document may name the admin MCP path: the `resource` member of the
    # protected resource metadata (RFC 9728 wants the identifier of the resource there). It is
    # taken out of the text that is scanned, and nothing else is: the literal `/mcp/admin` at the
    # end of that member goes, the origin and the URL prefix before it are still scanned.
    defp scanned_text("oauth prm", response) do
      resource = Resource.resource()
      assert %{"resource" => ^resource} = JSON.decode!(response.resp_body)
      assert String.ends_with?(resource, "/mcp/admin")
      masked = String.replace_suffix(resource, "/mcp/admin", "")
      String.replace(text_of(response), ~s("resource":"#{resource}"), ~s("resource":"#{masked}"))
    end

    defp scanned_text(_label, response), do: text_of(response)

    defp mcp_list(conn, ip), do: mcp_call(conn, ip, "tools/list", nil)

    defp mcp_initialize(conn, ip) do
      params = %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "leak-test", "version" => "1"}
      }

      mcp_call(conn, ip, "initialize", params)
    end

    defp mcp_call(conn, ip, method, params) do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => method}
      request = if params, do: Map.put(request, "params", params), else: request

      conn
      |> with_client_ip(ip)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> post(Routes.path("/mcp/public"), JSON.encode!(request))
    end

    # The admin side as the registry has it right now.
    defp banned do
      admin = Registry.visible_tools(:admin, :all)

      terms =
        Enum.flat_map(admin, fn tool ->
          [tool.name, Names.to_mcp(tool.name), tool.scope, tool.permission]
        end)

      terms
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(["/api/admin", "/mcp/admin", "Bearer", "approval"])
      |> Enum.uniq()
      |> Enum.map(fn term ->
        Regex.compile!("(?<![A-Za-z0-9_])" <> Regex.escape(term) <> "(?![A-Za-z0-9_])", "i")
      end)
      |> Kernel.++([~r/\bpk_[0-9a-f]{8}_/])
    end

    defp text_of(conn) do
      headers =
        Enum.map_join(conn.resp_headers, "\n", fn {name, value} -> "#{name}: #{value}" end)

      conn.resp_body <> "\n" <> headers
    end

    test "the banned list is built from the registry and holds the fake admin module" do
      terms = Enum.map(banned(), &Regex.source/1)

      assert Enum.any?(terms, &(&1 =~ "zzleak\\.reset_things"))
      assert Enum.any?(terms, &(&1 =~ "zzleak_reset_things"))
      assert Enum.any?(terms, &(&1 =~ "zzleak\\.things:write"))
      assert Enum.any?(terms, &(&1 =~ "zzleak_perm"))
      assert Enum.any?(terms, &(&1 =~ "system_get_identity"))
    end

    test "no public body or header holds a banned term", %{conn: conn} do
      responses = public_responses(conn)
      banned = banned()

      for {label, response} <- responses, regex <- banned do
        refute Regex.match?(regex, scanned_text(label, response)),
               "#{label} names #{inspect(Regex.source(regex))}"
      end

      # Every one of them answered (a scan of an empty 404 would prove nothing).
      statuses = Map.new(responses, fn {label, response} -> {label, response.status} end)

      assert statuses == %{
               "html" => 200,
               "markdown" => 200,
               "llms.txt" => 200,
               "catalog" => 200,
               "405" => 405,
               "406" => 406,
               "rest list" => 200,
               "openapi" => 200,
               "mcp 405" => 405,
               "mcp tools/list" => 200,
               "mcp initialize" => 200,
               "oauth prm" => 200,
               "oauth as" => 200
             }
    end

    test "the authorization server document names no banned term with registration switched on",
         %{conn: conn} do
      put_setting("api_oauth_dcr_enabled", "true")

      response = fetch(conn, "/.well-known/oauth-authorization-server", ip: unique_ip())

      assert response.status == 200
      assert %{"registration_endpoint" => _} = JSON.decode!(response.resp_body)

      for regex <- banned() do
        refute Regex.match?(regex, text_of(response)),
               "the document names #{inspect(Regex.source(regex))}"
      end
    end

    test "no generated public document says \"approval\" in any form (compound identifiers too)",
         %{conn: conn} do
      for {label, response} <- public_responses(conn) do
        refute response |> text_of() |> String.downcase() |> String.contains?("approval"),
               "#{label} mentions approvals"
      end
    end

    test "the OAuth documents are 404 while OAuth is off, and still hold no banned term", %{
      conn: conn
    } do
      put_setting("api_oauth_enabled", "false")

      ip = unique_ip()

      responses = [
        {"oauth prm", fetch(conn, Resource.metadata_path(), ip: ip)},
        {"oauth as", fetch(conn, "/.well-known/oauth-authorization-server", ip: ip)}
      ]

      for {label, response} <- responses do
        assert response.status == 404, label

        for regex <- banned() do
          refute Regex.match?(regex, text_of(response)),
                 "#{label} names #{inspect(Regex.source(regex))}"
        end
      end
    end

    test "the hidden 404 holds no banned term either", %{conn: conn} do
      switch(:public, false)

      for {label, response} <- public_responses(conn), response.status == 404 do
        for regex <- banned() do
          refute Regex.match?(regex, text_of(response)),
                 "#{label} names #{inspect(Regex.source(regex))}"
        end
      end
    end
  end

  # The same section the controller builds, for the origin the preview uses.
  defp preview_section do
    if Config.public_enabled?(),
      do: PublicDiscovery.llms_section(Routes.base_url())
  end

  defp count_queries(fun) do
    counter = :counters.new(1, [])
    test_pid = self()
    handler = "discovery-test-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:phoenix_kit, :test, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      result = fun.()
      {result, :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end

  describe "nothing advertises a deprecated alias" do
    @alias_path ~r{/api/shop|/mcp/shop}

    defp everything_said(conn) do
      headers =
        Enum.map_join(conn.resp_headers, "\n", fn {name, value} -> name <> ": " <> value end)

      headers <> "\n" <> conn.resp_body
    end

    test "no document, error or header of the public API names an alias", %{conn: conn} do
      for {name, answer} <- public_responses(conn) do
        refute everything_said(answer) =~ @alias_path, name
      end
    end

    test "the documents served through the alias name the canonical paths too", %{conn: conn} do
      ip = unique_ip()

      for {name, answer} <- [
            {"rest list", fetch(conn, Routes.path("/api/shop/v1"), ip: ip)},
            {"openapi", fetch(conn, Routes.path("/api/shop/v1/openapi.json"), ip: ip)},
            {"mcp 405", fetch(conn, Routes.path("/mcp/shop"), ip: ip)}
          ] do
        refute everything_said(answer) =~ @alias_path, name
      end
    end

    test "the URL builders return the canonical path only" do
      origin = "https://shop.test"

      assert PublicDiscovery.mcp_url(origin) == origin <> Routes.path("/mcp/public")
      assert PublicDiscovery.api_url(origin) == origin <> Routes.path("/api/public/v1")

      assert PublicDiscovery.openapi_url(origin) ==
               origin <> Routes.path("/api/public/v1/openapi.json")
    end
  end
end
