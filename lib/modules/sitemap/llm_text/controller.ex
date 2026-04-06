defmodule PhoenixKit.Modules.Sitemap.LLMText.Controller do
  @moduledoc """
  Controller for serving LLM-friendly markdown files.

  ## Endpoints

  - GET /{prefix}/llms.txt — serves the index file listing all LLM-readable pages
  - GET /{prefix}/*path — serves individual LLM markdown files (`.md` extension only)

  Files are served directly from `priv/static/llms/` with `text/markdown` content type.
  Returns 404 for files that do not exist or do not have a `.md` extension.
  """

  use PhoenixKitWeb, :controller

  require Logger

  alias PhoenixKit.Modules.Sitemap.LLMText.FileStorage

  @doc """
  Serves the llms.txt index file.
  """
  def index(conn, _params) do
    path = FileStorage.index_path()

    case File.read(path) do
      {:ok, content} ->
        conn
        |> put_resp_content_type("text/plain; charset=utf-8")
        |> send_resp(200, content)

      {:error, :enoent} ->
        conn
        |> put_resp_content_type("text/plain; charset=utf-8")
        |> send_resp(404, "Not found")

      {:error, reason} ->
        Logger.warning("Sitemap.LLMText controller: failed to read llms.txt: #{inspect(reason)}")

        conn
        |> put_resp_content_type("text/plain; charset=utf-8")
        |> send_resp(500, "Internal error")
    end
  end

  @doc """
  Serves an individual LLM markdown file at `/*path`.

  Only serves files with a `.md` extension — returns 404 for all other paths.
  """
  def show(conn, %{"path" => path_parts}) when is_list(path_parts) do
    relative_path = Path.join(path_parts)

    cond do
      String.contains?(relative_path, "..") ->
        conn
        |> put_resp_content_type("text/plain; charset=utf-8")
        |> send_resp(400, "Bad request")

      not String.ends_with?(relative_path, ".md") ->
        conn
        |> put_resp_content_type("text/plain; charset=utf-8")
        |> send_resp(404, "Not found")

      true ->
        full_path = FileStorage.file_path(relative_path)

        case File.read(full_path) do
          {:ok, content} ->
            conn
            |> put_resp_content_type("text/markdown; charset=utf-8")
            |> send_resp(200, content)

          {:error, :enoent} ->
            conn
            |> put_resp_content_type("text/plain; charset=utf-8")
            |> send_resp(404, "Not found")

          {:error, reason} ->
            Logger.warning(
              "Sitemap.LLMText controller: failed to read #{relative_path}: #{inspect(reason)}"
            )

            conn
            |> put_resp_content_type("text/plain; charset=utf-8")
            |> send_resp(500, "Internal error")
        end
    end
  end
end
