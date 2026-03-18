defmodule PhoenixKitWeb.Components.Core.MarkdownContent do
  @moduledoc """
  Renders markdown content with consistent styling across the application.

  Uses Tailwind Typography's `prose` classes for markdown rendering,
  with theme-aware color integration via daisyUI's CSS custom properties.

  ## Usage

      <.markdown_content content={@rendered_html} />

      # With custom class
      <.markdown_content content={@rendered_html} class="my-custom-class" />

  ## Features

  - Styled headings (h1-h6)
  - Paragraph spacing and line height
  - Bullet and numbered lists
  - Inline and block code styling
  - Blockquotes
  - Tables
  - Horizontal rules
  - Theme-aware colors (works with all daisyUI themes)
  - Responsive variants (`prose-sm`, `prose-lg`)

  ## CSS Integration

  This component relies on prose overrides defined in `app.css` that extend
  Tailwind Typography to use daisyUI's theme CSS custom properties.
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  @doc """
  Renders HTML content with markdown-appropriate styling.

  ## Attributes

  * `content` - The raw HTML string to render (required)
  * `class` - Additional CSS classes to apply (optional)

  ## Modifiers

  Add these classes to change the prose size:

  * `prose-sm` - Smaller text, compact spacing
  * `prose-lg` - Larger text, comfortable spacing (default)
  """
  attr :content, :string, required: true, doc: "The raw HTML content to render"
  attr :class, :string, default: "", doc: "Additional CSS classes"

  def markdown_content(assigns) do
    ~H"""
    <div class={["prose prose-lg max-w-none", @class]}>
      {raw(@content)}
    </div>
    """
  end
end
