defmodule PhoenixKitWeb.Components.Core.MarkdownContent do
  @moduledoc """
  Renders markdown content with consistent styling across the application.

  This component provides a styled container for rendered markdown/HTML content,
  with support for headings, lists, code blocks, blockquotes, tables, and more.
  Includes dark mode support.

  ## Usage

      <.markdown_content content={@rendered_html} />

      # With custom class
      <.markdown_content content={@rendered_html} class="my-custom-class" />

  ## Features

  - Styled headings (h1-h4)
  - Paragraph spacing and line height
  - Bullet and numbered lists
  - Inline and block code styling
  - Blockquotes
  - Tables
  - Horizontal rules
  - Dark mode support via `[data-theme="dark"]`
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  @doc """
  Renders HTML content with markdown-appropriate styling.

  ## Attributes

  * `content` - The raw HTML string to render (required)
  * `class` - Additional CSS classes to apply (optional)
  """
  attr :content, :string, required: true, doc: "The raw HTML content to render"
  attr :class, :string, default: "", doc: "Additional CSS classes"

  def markdown_content(assigns) do
    ~H"""
    <style>
      .phoenix-kit-markdown h1 {
        font-size: 2.25rem;
        line-height: 2.5rem;
        font-weight: 700;
        margin-top: 2.5rem;
        margin-bottom: 1.5rem;
      }
      .phoenix-kit-markdown h2 {
        font-size: 1.875rem;
        line-height: 2.25rem;
        font-weight: 700;
        margin-top: 2rem;
        margin-bottom: 1rem;
      }
      .phoenix-kit-markdown h3 {
        font-size: 1.5rem;
        line-height: 2rem;
        font-weight: 600;
        margin-top: 1.75rem;
        margin-bottom: 0.75rem;
      }
      .phoenix-kit-markdown h4 {
        font-size: 1.25rem;
        line-height: 1.75rem;
        font-weight: 600;
        margin-top: 1.5rem;
        margin-bottom: 0.5rem;
      }
      .phoenix-kit-markdown h5 {
        font-size: 1.125rem;
        line-height: 1.5rem;
        font-weight: 600;
        margin-top: 1.25rem;
        margin-bottom: 0.5rem;
      }
      .phoenix-kit-markdown h6 {
        font-size: 1rem;
        line-height: 1.5rem;
        font-weight: 600;
        margin-top: 1rem;
        margin-bottom: 0.5rem;
      }
      .phoenix-kit-markdown p {
        margin-top: 1rem;
        margin-bottom: 1rem;
        line-height: 1.8;
      }
      .phoenix-kit-markdown ul,
      .phoenix-kit-markdown ol {
        margin-top: 1rem;
        margin-bottom: 1rem;
        padding-left: 1.5rem;
        list-style-position: outside;
      }
      .phoenix-kit-markdown ul {
        list-style-type: disc;
      }
      .phoenix-kit-markdown ol {
        list-style-type: decimal;
      }
      .phoenix-kit-markdown li {
        margin-top: 0.5rem;
        margin-bottom: 0.5rem;
      }
      .phoenix-kit-markdown code {
        background-color: rgba(15, 23, 42, 0.08);
        color: inherit;
        padding: 0.2rem 0.4rem;
        border-radius: 0.375rem;
        font-size: 0.95em;
      }
      .phoenix-kit-markdown pre {
        background-color: rgba(15, 23, 42, 0.08);
        padding: 1rem;
        border-radius: 0.75rem;
        overflow-x: auto;
        margin-top: 1.5rem;
        margin-bottom: 1.5rem;
      }
      .phoenix-kit-markdown pre code {
        background-color: transparent;
        padding: 0;
        border-radius: 0;
        font-size: 0.9em;
      }
      .phoenix-kit-markdown blockquote {
        border-left: 4px solid rgba(15, 23, 42, 0.15);
        padding-left: 1rem;
        margin-top: 1.5rem;
        margin-bottom: 1.5rem;
        font-style: italic;
        color: rgba(15, 23, 42, 0.8);
      }
      .phoenix-kit-markdown table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 1.5rem;
        margin-bottom: 1.5rem;
      }
      .phoenix-kit-markdown th,
      .phoenix-kit-markdown td {
        border: 1px solid rgba(15, 23, 42, 0.15);
        padding: 0.75rem;
        text-align: left;
      }
      .phoenix-kit-markdown th {
        background-color: rgba(15, 23, 42, 0.08);
        font-weight: 600;
      }
      .phoenix-kit-markdown hr {
        border: none;
        border-top: 1px solid rgba(15, 23, 42, 0.15);
        margin-top: 2rem;
        margin-bottom: 2rem;
      }
      .phoenix-kit-markdown a {
        color: oklch(var(--p));
        text-decoration: underline;
      }
      .phoenix-kit-markdown a:hover {
        opacity: 0.8;
      }
      .phoenix-kit-markdown img {
        max-width: 100%;
        height: auto;
        border-radius: 0.5rem;
        margin-top: 1rem;
        margin-bottom: 1rem;
      }

      /* Dark mode support */
      [data-theme="dark"] .phoenix-kit-markdown code {
        background-color: rgba(255, 255, 255, 0.12);
      }
      [data-theme="dark"] .phoenix-kit-markdown pre {
        background-color: rgba(255, 255, 255, 0.1);
      }
      [data-theme="dark"] .phoenix-kit-markdown blockquote {
        border-left-color: rgba(255, 255, 255, 0.25);
        color: rgba(255, 255, 255, 0.8);
      }
      [data-theme="dark"] .phoenix-kit-markdown th,
      [data-theme="dark"] .phoenix-kit-markdown td {
        border-color: rgba(255, 255, 255, 0.2);
      }
      [data-theme="dark"] .phoenix-kit-markdown th {
        background-color: rgba(255, 255, 255, 0.12);
      }
      [data-theme="dark"] .phoenix-kit-markdown hr {
        border-top-color: rgba(255, 255, 255, 0.2);
      }
    </style>
    <div class={["phoenix-kit-markdown prose prose-lg max-w-none", @class]}>
      {raw(@content)}
    </div>
    """
  end
end
