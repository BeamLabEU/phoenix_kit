defmodule PhoenixKit.Pages.Renderer do
  @moduledoc """
  Simple markdown rendering for Pages module.

  Converts markdown files to HTML with metadata extraction.
  """

  alias PhoenixKit.Pages.FileOperations
  alias PhoenixKit.Pages.Metadata

  @doc """
  Renders a markdown file to HTML.

  ## Examples

      iex> Renderer.render_file("/test.md")
      {:ok, "<h1>Hello World</h1>"}

      iex> Renderer.render_file("/missing.md")
      {:error, :enoent}
  """
  def render_file(relative_path) do
    case FileOperations.read_file(relative_path) do
      {:ok, content} ->
        html = render_markdown(content)
        {:ok, html}

      error ->
        error
    end
  end

  @doc """
  Renders a markdown file to HTML with metadata extraction.

  Returns both the rendered HTML and the parsed metadata.

  ## Examples

      iex> Renderer.render_file_with_metadata("/test.md")
      {:ok, "<h1>Hello World</h1>", %{status: "published", ...}}

      iex> Renderer.render_file_with_metadata("/missing.md")
      {:error, :enoent}
  """
  def render_file_with_metadata(relative_path) do
    case FileOperations.read_file(relative_path) do
      {:ok, content} ->
        # Extract metadata
        {metadata, content_without_metadata} =
          case Metadata.parse(content) do
            {:ok, metadata, stripped_content} ->
              {metadata, stripped_content}

            {:error, :no_metadata} ->
              # No metadata found, use defaults
              {Metadata.default_metadata(), content}
          end

        # Render markdown (without metadata block)
        html = render_markdown(content_without_metadata)

        {:ok, html, metadata}

      error ->
        error
    end
  end

  @doc """
  Converts markdown content to HTML.

  ## Examples

      iex> Renderer.render_markdown("# Hello")
      "<h1>Hello</h1>"
  """
  def render_markdown(content) do
    case Earmark.as_html(content) do
      {:ok, html, _warnings} -> html
      {:error, _html, errors} -> raise "Markdown parsing failed: #{inspect(errors)}"
    end
  end
end
