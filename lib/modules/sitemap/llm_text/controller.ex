defmodule PhoenixKit.Modules.Sitemap.LLMText.Controller do
  @moduledoc """
  Controller for serving LLM-friendly content generated on-the-fly.

  ## Endpoints

  - GET /llms.txt — index file (default language)
  - GET /llms/{lang}/llms.txt — index file for specific language
  - GET /llms/{lang}/*path — individual page (.md only)
  - GET /llms/*path — individual page, no language prefix (uses default language)
  """

  use PhoenixKitWeb, :controller

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Sitemap.LLMText.Generator
  alias PhoenixKit.Modules.Sitemap.LLMText.Sources.Source

  def index(conn, _params) do
    language = get_default_language()
    content = Generator.build_index(language)

    conn
    |> put_resp_content_type("text/plain; charset=utf-8")
    |> send_resp(200, content)
  end

  def show(conn, %{"path" => path_parts}) when is_list(path_parts) do
    if String.contains?(Path.join(path_parts), "..") do
      conn
      |> put_resp_content_type("text/plain; charset=utf-8")
      |> send_resp(400, "Bad request")
    else
      {language, content_path} = extract_language(path_parts)
      dispatch(conn, language, content_path)
    end
  end

  # Private

  defp dispatch(conn, language, ["llms.txt"]) do
    content = Generator.build_index(language)

    conn
    |> put_resp_content_type("text/plain; charset=utf-8")
    |> send_resp(200, content)
  end

  defp dispatch(conn, language, content_path) do
    last = List.last(content_path, "")

    if String.ends_with?(last, ".md") do
      sources = Generator.get_sources()

      result =
        Enum.find_value(sources, fn source_mod ->
          case Source.safe_serve_page(source_mod, content_path, language) do
            {:ok, content} -> {:ok, content}
            :not_found -> nil
          end
        end)

      case result do
        {:ok, content} ->
          conn
          |> put_resp_content_type("text/markdown; charset=utf-8")
          |> send_resp(200, content)

        nil ->
          conn
          |> put_resp_content_type("text/plain; charset=utf-8")
          |> send_resp(404, "Not found")
      end
    else
      conn
      |> put_resp_content_type("text/plain; charset=utf-8")
      |> send_resp(404, "Not found")
    end
  end

  defp extract_language([first | rest] = all_parts) do
    if first in get_known_language_codes() do
      {first, rest}
    else
      {get_default_language(), all_parts}
    end
  end

  defp get_known_language_codes do
    if languages_module_enabled?() and
         function_exported?(Languages, :get_enabled_language_codes, 0) do
      Languages.get_enabled_language_codes()
    else
      ["en"]
    end
  rescue
    _ -> ["en"]
  end

  defp get_default_language do
    if languages_module_enabled?() and
         function_exported?(Languages, :get_default_language, 0) do
      case Languages.get_default_language() do
        %{code: code} when is_binary(code) -> code
        _ -> "en"
      end
    else
      "en"
    end
  rescue
    _ -> "en"
  end

  defp languages_module_enabled? do
    Code.ensure_loaded?(Languages) and
      function_exported?(Languages, :enabled?, 0) and
      Languages.enabled?()
  rescue
    _ -> false
  end
end
