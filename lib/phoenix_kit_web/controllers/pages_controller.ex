defmodule PhoenixKitWeb.PagesController do
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Pages
  alias PhoenixKit.Pages.Renderer

  @doc """
  Renders a public page from the pages directory.

  Only renders pages with status "published". Draft and archived pages fall back
  to the configured not-found behaviour. When the "Handle 404s in Pages" setting
  is disabled, requests are handed back to the parent router so the host
  application can keep its existing 404 pipeline.

  Path examples:
    /pages/test2 -> renders test2.md (if published)
    /pages/blog/hello -> renders blog/hello.md (if published)
    /test -> handled by the catch-all route and mapped to /test.md
  """
  def show(conn, %{"path" => path}) do
    if Pages.enabled?() do
      file_path = build_file_path(path)

      with {:ok, html_content, metadata} <- Renderer.render_file_with_metadata(file_path),
           true <- metadata.status == "published" do
        render_markdown(conn, file_path, html_content, metadata)
      else
        _ -> handle_not_found(conn)
      end
    else
      passthrough_to_parent(conn)
    end
  end

  # Private helpers

  defp build_file_path(path) when is_list(path) do
    # Handle catch-all route: ["blog", "post-1"] -> "/blog/post-1.md"
    "/" <> Path.join(path) <> ".md"
  end

  defp build_file_path(path) when is_binary(path) do
    # Handle single path segment: "test2" -> "/test2.md"
    "/" <> path <> ".md"
  end

  defp render_markdown(conn, file_path, html_content, metadata) do
    page_title = metadata.title || Path.basename(file_path, ".md")

    conn
    |> assign(:page_title, page_title)
    |> assign(:html_content, html_content)
    |> assign(:metadata, metadata)
    |> render(:show)
  end

  defp handle_not_found(conn) do
    if Pages.handle_not_found?() do
      render_pages_not_found(conn)
    else
      passthrough_to_parent(conn)
    end
  end

  defp render_pages_not_found(conn) do
    Pages.ensure_not_found_page_exists()

    case Renderer.render_file_with_metadata(Pages.not_found_file_path()) do
      {:ok, html_content, metadata} ->
        conn
        |> put_status(:not_found)
        |> assign(:page_title, metadata.title || "Page Not Found")
        |> assign(:html_content, html_content)
        |> assign(:metadata, metadata)
        |> render(:show)

      {:error, _reason} ->
        default_not_found(conn)
    end
  end

  defp default_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: PhoenixKitWeb.ErrorHTML)
    |> render(:"404")
  end

  defp passthrough_to_parent(conn) do
    router = conn.private[:phoenix_router] || PhoenixKitWeb.Router
    raise Phoenix.Router.NoRouteError, conn: conn, router: router
  end
end
