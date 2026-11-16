defmodule PhoenixKitWeb.OAuth.MetadataTest do
  @moduledoc """
  The two discovery documents through the real endpoint, where they are routed (the site root,
  for a kit under a prefix and for one at the root), what they hold and what they leave out, the
  `404` while OAuth is off, and that the challenge URL of the `401` answer resolves to a served
  document.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [enable_oauth!: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.OAuth.Metadata
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.Config
  alias PhoenixKit.Utils.Routes

  @as_path "/.well-known/oauth-authorization-server"

  setup do
    setup_api()
    enable_oauth!()
    :ok
  end

  defp fetch(path, ip \\ unique_ip()) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-forwarded-for", ip)
    |> Phoenix.ConnTest.dispatch(@endpoint, :get, path, nil)
  end

  describe "the protected resource document (RFC 9728)" do
    test "is served at the path variant of the well-known URL" do
      conn = fetch(Resource.metadata_path())
      assert conn.status == 200
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

      assert body(conn) == %{
               "resource" => Resource.resource(),
               "authorization_servers" => [Resource.issuer()],
               "bearer_methods_supported" => ["header"],
               "resource_name" => "MCP server"
             }
    end

    test "carries the kit's URL prefix in the resource and in the path" do
      prefix = Config.get_url_prefix()
      assert prefix != "/"

      assert Resource.metadata_path() ==
               "/.well-known/oauth-protected-resource" <> prefix <> "/mcp/admin"

      assert String.ends_with?(
               body(fetch(Resource.metadata_path()))["resource"],
               prefix <> "/mcp/admin"
             )
    end

    test "the bare root path and a foreign resource path are not served" do
      assert fetch("/.well-known/oauth-protected-resource").status == 404
      assert fetch("/.well-known/oauth-protected-resource/mcp/admin").status == 404
      assert fetch("/.well-known/oauth-protected-resource/elsewhere").status == 404
    end

    test "names no scope, tool, permission or module" do
      text = fetch(Resource.metadata_path()).resp_body
      refute text =~ "scopes_supported"
      refute text =~ "testkit"
    end

    test "the URL a 401 challenge names resolves to it" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-forwarded-for", unique_ip())
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Phoenix.ConnTest.dispatch(@endpoint, :post, Routes.path("/mcp/admin"), "{}")

      assert conn.status == 401
      [challenge] = get_resp_header(conn, "www-authenticate")
      assert [_, url] = Regex.run(~r/resource_metadata="([^"]+)"/, challenge)
      assert url == Resource.metadata_url()

      served = fetch(URI.parse(url).path)
      assert served.status == 200
      assert body(served)["resource"] == Resource.resource()
    end
  end

  describe "the authorization server document (RFC 8414)" do
    test "holds the endpoints and what the server supports" do
      conn = fetch(@as_path)
      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      doc = body(conn)
      issuer = Resource.issuer()

      assert doc["issuer"] == issuer
      assert doc["authorization_endpoint"] == issuer <> Routes.path("/oauth/authorize")
      assert doc["token_endpoint"] == issuer <> Routes.path("/oauth/token")
      assert doc["revocation_endpoint"] == issuer <> Routes.path("/oauth/revoke")
      assert doc["response_types_supported"] == ["code"]
      assert doc["grant_types_supported"] == ["authorization_code", "refresh_token"]
      assert doc["code_challenge_methods_supported"] == ["S256"]
      assert doc["token_endpoint_auth_methods_supported"] == ["none"]
      assert doc["authorization_response_iss_parameter_supported"] == true
    end

    test "has no scopes_supported, no registration endpoint yet and is not an OpenID provider" do
      doc = body(fetch(@as_path))
      refute Map.has_key?(doc, "scopes_supported")
      refute Map.has_key?(doc, "registration_endpoint")
      refute Map.has_key?(doc, "jwks_uri")
      refute Map.has_key?(doc, "userinfo_endpoint")
      assert fetch("/.well-known/openid-configuration").status == 404
    end

    test "the endpoints it names are routed, with no locale segment" do
      doc = body(fetch(@as_path))
      refute doc["authorization_endpoint"] =~ ~r{/(en|et|ru)/}

      for {verb, key} <- [
            {"GET", "authorization_endpoint"},
            {"POST", "token_endpoint"},
            {"POST", "revocation_endpoint"}
          ] do
        path = URI.parse(doc[key]).path
        assert %{} = Phoenix.Router.route_info(PhoenixKitWeb.Router, verb, path, "localhost"), key
      end
    end

    test "is a pure function of the install: the same as the module builds" do
      assert body(fetch(@as_path)) == Metadata.authorization_server()
    end
  end

  describe "while OAuth is off" do
    test "both documents are the same 404 problem" do
      put_setting("api_oauth_enabled", "false")

      prm = fetch(Resource.metadata_path())
      as = fetch(@as_path)

      assert prm.status == 404
      assert as.status == 404
      assert body(prm)["code"] == "not_found"
      assert get_resp_header(prm, "access-control-allow-origin") == []
    end

    test "the admin API off switches them off too" do
      put_setting("api_admin_enabled", "false")
      assert fetch(@as_path).status == 404
    end
  end

  describe "where they are routed" do
    test "once each, at the root, for a kit under a prefix" do
      paths = metadata_routes(PhoenixKitWeb.Router)

      assert Enum.sort(paths) ==
               Enum.sort([
                 {"/.well-known/oauth-protected-resource" <>
                    Config.get_url_prefix() <> "/mcp/admin", :protected_resource},
                 {@as_path, :authorization_server}
               ])
    end

    test "once each, at the root, for a kit mounted at the root" do
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

      module = Module.concat(__MODULE__, "RootProbeRouter#{System.unique_integer([:positive])}")

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            use PhoenixKitWeb, :router

            import PhoenixKitWeb.Integration
            import PhoenixKitWeb.Users.Auth

            pipeline :browser do
              plug :accepts, ["html"]
            end

            phoenix_kit_routes()
          end
        end
      )

      assert Enum.sort(metadata_routes(module)) ==
               Enum.sort([
                 {"/.well-known/oauth-protected-resource/mcp/admin", :protected_resource},
                 {@as_path, :authorization_server}
               ])
    end

    defp metadata_routes(router) do
      for %{verb: :get, path: path, plug_opts: action} <- router.__routes__(),
          action in [:protected_resource, :authorization_server],
          do: {path, action}
    end
  end
end
