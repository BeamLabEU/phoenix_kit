defmodule PhoenixKitWeb.Components.Core.Markdown do
  @moduledoc """
  Renders markdown content safely with consistent styling.

  This component parses markdown to HTML using Earmark, sanitizes the output
  for XSS prevention, and renders with appropriate styling.

  ## Usage

      # Full markdown rendering with styling
      <.markdown content={@description} />

      # Compact mode for previews/inline
      <.markdown content={@description} compact />

      # With custom class
      <.markdown content={@description} class="text-sm" />

      # Without sanitization (trusted admin content)
      <.markdown content={@description} sanitize={false} />

  ## Features

  - GFM (GitHub Flavored Markdown) support
  - Smart typography (smartypants)
  - Code block syntax highlighting classes
  - XSS sanitization (enabled by default)
  - Compact mode for previews
  - Graceful error handling
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]
  import PhoenixKitWeb.Components.Core.MarkdownContent, only: [markdown_content: 1]

  alias PhoenixKit.Modules.Entities.HtmlSanitizer

  @doc """
  Renders markdown content with styling and optional XSS protection.

  ## Attributes

  * `content` - The markdown string to render (required)
  * `class` - Additional CSS classes (optional)
  * `compact` - Use compact styling for previews (default: false)
  * `sanitize` - Enable HTML sanitization (default: true)
  """
  attr :content, :string, required: true, doc: "The markdown content to render"
  attr :class, :string, default: "", doc: "Additional CSS classes"
  attr :compact, :boolean, default: false, doc: "Use compact styling for previews"
  attr :sanitize, :boolean, default: true, doc: "Enable HTML sanitization"

  def markdown(assigns) do
    html_content = render_markdown(assigns.content, assigns.sanitize)
    assigns = assign(assigns, :html_content, html_content)

    if assigns.compact do
      ~H"""
      <div class={["prose prose-sm max-w-none", @class]}>
        {raw(@html_content)}
      </div>
      """
    else
      ~H"""
      <.markdown_content content={@html_content} class={@class} />
      """
    end
  end

  defp render_markdown(nil, _sanitize), do: ""
  defp render_markdown("", _sanitize), do: ""

  defp render_markdown(content, sanitize) when is_binary(content) do
    case Earmark.as_html(content, earmark_options()) do
      {:ok, html, _warnings} ->
        if sanitize, do: HtmlSanitizer.sanitize(html), else: html

      {:error, _html, _errors} ->
        # Fallback: escape and return as paragraph
        Phoenix.HTML.html_escape(content) |> Phoenix.HTML.safe_to_string()
    end
  end

  defp render_markdown(_other, _sanitize), do: ""

  defp earmark_options do
    %Earmark.Options{
      code_class_prefix: "language-",
      smartypants: true,
      gfm: true,
      escape: false
    }
  end
end
