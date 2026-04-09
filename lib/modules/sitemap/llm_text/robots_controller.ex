defmodule PhoenixKit.Modules.Sitemap.LLMText.RobotsController do
  @moduledoc """
  Serves a dynamic robots.txt that includes a LLM-File directive pointing to llms.txt.

  Reads the parent app's existing priv/static/robots.txt (if present) and appends
  the `LLM-File:` directive when the LLM text feature is enabled.

  Falls back to a minimal default (`User-agent: *\nAllow: /`) when no static file exists.

  ## Route (injected by phoenix_kit_routes/0)

      GET /robots.txt

  ## Setup note

  For this route to be reachable, `robots.txt` must NOT be served by `Plug.Static`.
  Remove it from your endpoint's `only:` list (or `static_paths/0`) and delete
  `priv/static/robots.txt` — PhoenixKit will handle the file from this point.
  `mix phoenix_kit.update` performs this change automatically.

  ## Always-on route

  The `/robots.txt` route is registered unconditionally by `phoenix_kit_routes/0`.
  When LLM text is disabled (or `site_url` is empty), the controller still serves
  robots.txt — it simply omits the `LLM-File:` directive. This ensures PhoenixKit
  never breaks an existing robots.txt by returning 404 when the feature is off.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.LLMText.Cache

  @default_robots "User-agent: *\nAllow: /\n"

  def index(conn, _params) do
    content =
      Cache.fetch(:robots_txt, fn ->
        base = read_parent_robots() || @default_robots
        append_llm_file(base)
      end)

    conn
    |> put_resp_content_type("text/plain; charset=utf-8")
    |> send_resp(200, content)
  end

  # Private

  # Read robots.txt from the parent app's priv/static directory.
  # Returns nil if the parent app is unknown, the file doesn't exist, or reading fails.
  defp read_parent_robots do
    parent_app = PhoenixKit.Config.get_parent_app()

    if parent_app do
      path =
        parent_app
        |> :code.priv_dir()
        |> Path.join("static/robots.txt")

      case File.read(path) do
        {:ok, content} -> content
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  # Appends `LLM-File: <site_url>/llms.txt` when the feature is enabled.
  # Skips if the directive is already present (idempotent).
  defp append_llm_file(base) do
    site_url = get_site_url()

    if Sitemap.llm_text_enabled?() and site_url != "" and not String.contains?(base, "LLM-File:") do
      llm_line = "LLM-File: #{String.trim_trailing(site_url, "/")}/llms.txt"
      String.trim_trailing(base) <> "\n" <> llm_line <> "\n"
    else
      base
    end
  end

  defp get_site_url do
    PhoenixKit.Settings.get_setting("site_url", "")
  rescue
    _ -> ""
  end
end
