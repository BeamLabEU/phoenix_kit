defmodule PhoenixKitWeb.Plugs.HostLocaleTest do
  @moduledoc """
  The host `/:locale` plug and `on_mount` hook, against a small router with a
  prefixless scope, a `/:locale` scope and a nested `/shop/:locale/...` route.
  Languages are modelled with a primed settings cache (no database).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Phoenix.LiveView.{Lifecycle, Socket}
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKitWeb.Plugs.HostLocale

  defmodule Page do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      body = "#{conn.assigns[:current_locale]}|#{conn.assigns[:current_locale_base]}"
      send_resp(conn, 200, body)
    end
  end

  defmodule Router do
    @moduledoc false
    use Phoenix.Router

    pipeline :host_locale do
      plug PhoenixKitWeb.Plugs.HostLocale
    end

    pipeline :host_locale_primary do
      plug PhoenixKitWeb.Plugs.HostLocale, on_unknown: :primary, on_primary_segment: :serve
    end

    scope "/" do
      pipe_through :host_locale
      get "/products", Page, :index
      get "/shop/:locale/items/:id", Page, :index
      get "/:locale/products", Page, :index
      post "/:locale/contact", Page, :index
    end

    scope "/lenient" do
      pipe_through :host_locale_primary
      get "/:locale/page", Page, :index
    end
  end

  defp request(method \\ :get, path) do
    conn = Plug.Test.conn(method, path)
    Router.call(conn, Router.init([]))
  end

  defp request_error(path) do
    request(path)
    flunk("expected #{path} to raise")
  rescue
    error in Plug.Conn.WrapperError -> error.reason
  end

  describe "primary served with its segment" do
    setup do
      LanguageSettings.multilingual!(languages: ~w(en-US et ru))
    end

    test "a served language sets assigns, Gettext and the request locale" do
      conn = request("/et/products")

      assert conn.status == 200
      assert conn.resp_body == "et|et"
      assert %{code: "et"} = conn.assigns.current_language
      assert Languages.request_locale() == "et"
      assert Gettext.get_locale() == "et"
    end

    test "the primary's segment is served as is" do
      assert request("/en/products").resp_body == "en-US|en"
    end

    test "a path without a segment is the primary language" do
      assert request("/products").resp_body == "en-US|en"
    end

    test "an unknown segment is a 404" do
      assert %HostLocale.NotFoundError{segment: "de", plug_status: 404} =
               request_error("/de/products")

      assert Plug.Exception.status(%HostLocale.NotFoundError{segment: "x"}) == 404
    end

    test "another spelling of a served segment redirects to the canonical one" do
      conn = request("/ET/products?x=1")
      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "location") == ["/et/products?x=1"]

      conn = request("/en-US/products")
      assert Plug.Conn.get_resp_header(conn, "location") == ["/en/products"]
    end

    test "a nested locale segment is found through the route pattern" do
      assert request("/shop/ru/items/7").resp_body == "ru|ru"

      conn = request("/shop/RU/items/7")
      assert Plug.Conn.get_resp_header(conn, "location") == ["/shop/ru/items/7"]
    end

    test "a non-GET redirect keeps its method (307)" do
      conn = request(:post, "/ET/contact")
      assert conn.status == 307
      assert Plug.Conn.get_resp_header(conn, "location") == ["/et/contact"]
    end

    test "on_unknown: :primary renders the primary language" do
      assert request("/lenient/zz/page").resp_body == "en-US|en"
    end

    test "a fixed kit segment captured as a locale logs the scope-ordering warning" do
      key = {HostLocale, :fixed_segment_warned, "assets"}
      :persistent_term.erase(key)

      log =
        capture_log(fn ->
          assert %HostLocale.NotFoundError{} = request_error("/assets/products")
        end)

      assert log =~ "Declare the wide /:locale scope after phoenix_kit_routes()"
      :persistent_term.erase(key)
    end
  end

  describe "primary served without a segment" do
    setup do
      LanguageSettings.multilingual!(languages: ~w(en-US et), no_prefix: true)
    end

    test "the prefixless page is the primary language" do
      assert request("/products").resp_body == "en-US|en"
    end

    test "the primary's segment redirects to the prefixless URL" do
      conn = request("/en/products?q=1")
      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "location") == ["/products?q=1"]
    end

    test "a canonicalised spelling of the primary goes straight to the prefixless URL" do
      conn = request("/EN/products")
      assert Plug.Conn.get_resp_header(conn, "location") == ["/products"]
    end

    test "on_primary_segment: :serve renders it" do
      assert request("/lenient/en/page").resp_body == "en-US|en"
    end

    test "other languages keep their segment" do
      assert request("/et/products").resp_body == "et|et"
    end
  end

  describe "single-language site" do
    setup do
      LanguageSettings.single_language!(languages: ~w(et))
    end

    test "the primary is served without a segment; any other code is a 404" do
      assert request("/products").resp_body == "et|et"
      assert Plug.Conn.get_resp_header(request("/et/products"), "location") == ["/products"]
      assert %HostLocale.NotFoundError{} = request_error("/en/products")
    end
  end

  describe "on_mount" do
    setup do
      LanguageSettings.multilingual!(languages: ~w(en-US et ru))
    end

    defp socket do
      %Socket{
        view: MyAppWeb.PageLive,
        assigns: %{__changed__: %{}, flash: %{}},
        private: %{connect_params: %{}, lifecycle: %Lifecycle{}, live_temp: %{}},
        router: Router
      }
    end

    test "a served language sets assigns and attaches the handle_params hook" do
      {:cont, socket} = HostLocale.on_mount(:default, %{"locale" => "ru"}, %{}, socket())

      assert socket.assigns.current_locale == "ru"
      assert socket.assigns.current_locale_base == "ru"
      assert %{code: "ru"} = socket.assigns.current_language
      assert Languages.request_locale() == "ru"

      assert Enum.map(socket.private.lifecycle.handle_params, & &1.id) == [
               :phoenix_kit_host_locale
             ]
    end

    test "no locale parameter is the primary language" do
      {:cont, socket} = HostLocale.on_mount(:default, %{}, %{}, socket())
      assert socket.assigns.current_locale == "en-US"
    end

    test "an unknown segment raises the 404 error in handle_params, before the first render" do
      # At mount the params merge path and query, so an unknown value is the primary there.
      {:cont, socket} = HostLocale.on_mount(:default, %{"locale" => "zz"}, %{}, socket())
      assert socket.assigns.current_locale == "en-US"
      [hook] = socket.private.lifecycle.handle_params

      assert_raise HostLocale.NotFoundError, fn ->
        hook.function.(%{"locale" => "zz"}, "http://localhost/zz/products", socket)
      end
    end

    test "a percent-encoded segment is read as the router decodes it" do
      {:cont, socket} = HostLocale.on_mount(:default, %{"locale" => "et"}, %{}, socket())
      [hook] = socket.private.lifecycle.handle_params

      {:cont, socket} =
        hook.function.(%{"locale" => "et"}, "http://localhost/%65t/products", socket)

      assert socket.assigns.current_locale == "et"
    end

    test "a ?locale= query parameter is not a locale segment, as for the plug" do
      for value <- ["zz", "et"] do
        {:cont, socket} = HostLocale.on_mount(:default, %{"locale" => value}, %{}, socket())
        [hook] = socket.private.lifecycle.handle_params

        {:cont, socket} =
          hook.function.(
            %{"locale" => value},
            "http://localhost/products?locale=#{value}",
            socket
          )

        assert socket.assigns.current_locale == "en-US"
        assert request("/products?locale=#{value}").resp_body == "en-US|en"
      end
    end

    test "mount reads the path parameters, not the query, so mount and render agree" do
      :ok = HostLocale.attach_mount_uri()

      mount_at = fn uri, params ->
        :telemetry.execute([:phoenix, :live_view, :mount, :start], %{}, %{uri: uri})
        {:cont, socket} = HostLocale.on_mount(:default, params, %{}, socket())
        socket.assigns.current_locale
      end

      # The connected mount: the URL comes from LiveView's mount telemetry.
      assert mount_at.("http://localhost/products?locale=et", %{"locale" => "et"}) == "en-US"
      assert mount_at.("http://localhost/et/products", %{"locale" => "et"}) == "et"
      assert mount_at.("http://localhost/ru/products?locale=et", %{"locale" => "ru"}) == "ru"

      # A URL serves the one mount it was recorded for: a later mount without its own
      # event does not reuse it.
      :telemetry.execute([:phoenix, :live_view, :mount, :start], %{}, %{
        uri: "http://localhost/ru/products"
      })

      {:cont, _} = HostLocale.on_mount(:default, %{"locale" => "ru"}, %{}, socket())
      {:cont, socket} = HostLocale.on_mount(:default, %{"locale" => "zz"}, %{}, socket())
      assert socket.assigns.current_locale == "en-US"

      :telemetry.execute([:phoenix, :live_view, :mount, :start], %{}, %{
        uri: "http://localhost/zz/products"
      })

      assert_raise HostLocale.NotFoundError, fn ->
        HostLocale.on_mount(:default, %{"locale" => "zz"}, %{}, socket())
      end

      # The dead render: the request itself.
      dead = fn path_params, params ->
        conn = %Plug.Conn{path_params: path_params}
        socket = put_in(socket().private[:connect_info], conn)
        {:cont, socket} = HostLocale.on_mount(:default, params, %{}, socket)
        socket.assigns.current_locale
      end

      assert dead.(%{}, %{"locale" => "et"}) == "en-US"
      assert dead.(%{"locale" => "ru"}, %{"locale" => "ru"}) == "ru"
    end

    test "a nested live_render view keeps the strict decision at mount" do
      assert_raise HostLocale.NotFoundError, fn ->
        HostLocale.on_mount(:default, %{"locale" => "zz"}, %{}, %{socket() | router: nil})
      end
    end

    test "the segment's own spelling is recorded for the strategy builders" do
      {:cont, socket} = HostLocale.on_mount(:default, %{}, %{}, socket())
      [hook] = socket.private.lifecycle.handle_params

      {:cont, socket} =
        hook.function.(%{"locale" => "ET"}, "http://localhost/ET/products", socket)

      assert socket.assigns.current_locale == "et"
      assert socket.assigns.phoenix_kit_locale_segment == "ET"

      assert PhoenixKit.I18n.localized_url(socket, "en", strategy: :path) == "/en/products"
      assert PhoenixKit.I18n.localized_url(socket, "ru", strategy: :path) == "/ru/products"
    end

    test "options are accepted as the hook argument" do
      {:cont, socket} =
        HostLocale.on_mount([on_unknown: :primary], %{"locale" => "zz"}, %{}, socket())

      assert socket.assigns.current_locale == "en-US"
    end

    test "the handle_params hook follows a live patch and records the current path" do
      {:cont, socket} = HostLocale.on_mount(:default, %{"locale" => "et"}, %{}, socket())
      [hook] = socket.private.lifecycle.handle_params

      {:cont, socket} =
        hook.function.(%{"locale" => "ru"}, "http://localhost/ru/products?page=2", socket)

      assert socket.assigns.current_locale == "ru"
      assert socket.assigns.phoenix_kit_current_path == "/ru/products?page=2"
    end
  end

  test "a view not mounted at the router (live_render) gets the language without the hook" do
    LanguageSettings.multilingual!(languages: ~w(en-US et))
    socket = %{socket() | router: nil}

    {:cont, socket} = HostLocale.on_mount(:default, %{"locale" => "et"}, %{}, socket)

    assert socket.assigns.current_locale == "et"
    assert socket.private.lifecycle.handle_params == []
  end

  test "invalid options are refused at init" do
    assert_raise ArgumentError, fn -> HostLocale.init(on_unknown: :redirect) end
    assert_raise ArgumentError, fn -> HostLocale.init(on_primary_segment: :maybe) end
  end
end
