defmodule PhoenixKit.Modules.Sitemap.HtmlRedirectTest do
  @moduledoc """
  `GET /sitemap.html` is deprecated and redirects to `sitemap.xml`.

  The target is built from the configured `:url_prefix`. A site mounted at the
  root has the prefix `"/"`; gluing the prefix and `/sitemap.xml` together
  produced `//sitemap.xml`, which Phoenix refuses to redirect to (an
  open-redirect guard), so the page answered 500 instead of 302.

  Pure conn test: `redirect/2` with `:to` needs no endpoint, and the prefix is
  swapped through the application env (it is cached in `:persistent_term`).
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Sitemap.Web.Controller

  setup do
    previous = Application.fetch_env(:phoenix_kit, :url_prefix)
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

  defp redirect_location(prefix) do
    Application.put_env(:phoenix_kit, :url_prefix, prefix)
    Config.clear_url_prefix_cache()

    conn =
      :get
      |> Plug.Test.conn("/sitemap.html")
      |> Controller.html(%{})

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    location
  end

  test "a root prefix redirects to /sitemap.xml, not //sitemap.xml" do
    assert redirect_location("/") == "/sitemap.xml"
  end

  test "an empty prefix is the root prefix too" do
    assert redirect_location("") == "/sitemap.xml"
  end

  test "a non-empty prefix is kept in front of sitemap.xml" do
    assert redirect_location("/phoenix_kit") == "/phoenix_kit/sitemap.xml"
  end

  test "a nested prefix is kept whole" do
    assert redirect_location("/app/kit") == "/app/kit/sitemap.xml"
  end
end
