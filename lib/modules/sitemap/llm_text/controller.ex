defmodule PhoenixKit.Modules.Sitemap.LLMText.Controller do
  @moduledoc """
  Controller for serving LLM-friendly text files.

  ## Endpoints

  - GET /{prefix}/llms.txt — serves the index file listing all LLM-readable pages
  - GET /{prefix}/llms/*path — serves individual LLM text files

  Files are served directly from `priv/static/llms/` with `text/plain` content type.
  Returns 404 for files that do not exist.
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
  Serves an individual LLM text file at `/llms/*path`.
  """
  def show(conn, %{"path" => path_parts}) when is_list(path_parts) do
    relative_path = Path.join(path_parts)

    # Prevent path traversal
    if String.contains?(relative_path, "..") do
      conn
      |> put_resp_content_type("text/plain; charset=utf-8")
      |> send_resp(400, "Bad request")
    else
      full_path = FileStorage.file_path(relative_path)

      case File.read(full_path) do
        {:ok, content} ->
          conn
          |> put_resp_content_type("text/plain; charset=utf-8")
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
