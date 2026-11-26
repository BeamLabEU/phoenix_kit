defmodule PhoenixKit.Modules.Crawlers.Web.Controller do
  @moduledoc """
  Serves `/llms.txt` for the Crawlers module.

  Mounted at the site root and under the kit prefix, mirroring
  `/sitemap.xml`'s reasoning: tools look for these files at the root, and the
  prefixed copy exists so prefix-only installs still have the endpoint.

  Sections from the host application (`config :phoenix_kit, llms_txt_sections:`)
  are described in `PhoenixKit.Modules.Crawlers.LlmsTxt`.

  404s when the Crawlers module is disabled — a policy document served from a
  switched-off policy module would be a lie about who is deciding.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.API.PublicDiscovery
  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Crawlers.LlmsTxt
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.WebsiteAccess.Gate

  @cache_max_age 3600

  def llms_txt(conn, _params) do
    if Crawlers.module_enabled?() do
      conn
      |> put_resp_content_type("text/markdown")
      |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
      |> put_api_section()
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  # While the public API is published (`PhoenixKit.API.PublicDiscovery.check/1`)
  # the file ends with its section and points to the API catalog. With the
  # website gate on that depends on the client address, so a shared cache must
  # not keep the answer.
  defp put_api_section(conn) do
    host_sections = host_sections(conn)

    case PublicDiscovery.check(conn) do
      {:ok, _tools} ->
        origin = PublicDiscovery.origin(conn)

        body =
          LlmsTxt.build(
            host_sections: host_sections,
            api_section: PublicDiscovery.llms_section(origin)
          )

        conn
        |> PublicDiscovery.put_link(PublicDiscovery.catalog_link(origin))
        |> put_gate_cache_control()
        |> send_resp(200, body)

      :hidden ->
        send_resp(conn, 200, LlmsTxt.build(host_sections: host_sections))
    end
  end

  # The host's own sections (`config :phoenix_kit, llms_txt_sections:`), nothing when unset.
  # The origin is the one discovery documents use, which never trusts an unknown `Host`.
  defp host_sections(conn) do
    if Application.get_env(:phoenix_kit, :llms_txt_sections) do
      origin = PublicDiscovery.origin(conn)

      LlmsTxt.host_sections(%{
        base_url: origin,
        host: URI.parse(origin).host,
        locale: locale(conn)
      })
    end
  end

  # `?lang=` when it names an enabled language, else the site's primary language.
  defp locale(conn) do
    conn = fetch_query_params(conn)
    enabled = Languages.enabled_locale_codes()

    case conn.query_params["lang"] do
      code when is_binary(code) -> if code in enabled, do: code, else: primary()
      _other -> primary()
    end
  end

  defp primary, do: Languages.primary_language_code()

  defp put_gate_cache_control(conn) do
    if Gate.enabled?(),
      do: put_resp_header(conn, "cache-control", "private, no-store"),
      else: conn
  end
end
