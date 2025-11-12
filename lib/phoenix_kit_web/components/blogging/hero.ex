defmodule PhoenixKitWeb.Components.Blogging.Hero do
  @moduledoc """
  Hero section component with multiple variants.

  Variants:
  - `split-image`: Hero with content on left, image on right
  - `centered`: Centered content with optional background
  - `minimal`: Simple centered text-only hero

  Example usage in .phk file:
  ```xml
  <Hero variant="split-image">
    <Headline>Build Your SaaS Faster</Headline>
    <Subheadline>Start shipping in days, not months</Subheadline>
    <CTA primary="true" action="/signup">Get Started</CTA>
    <CTA action="#features">Learn More</CTA>
    <Image src="/assets/dashboard.png" alt="Dashboard" />
  </Hero>
  ```
  """
  use Phoenix.Component

  attr :variant, :string, default: "centered"
  attr :children, :list, default: []
  attr :attributes, :map, default: %{}
  attr :content, :string, default: nil

  def render(assigns) do
    case assigns.variant do
      "split-image" -> render_split_image(assigns)
      "centered" -> render_centered(assigns)
      "minimal" -> render_minimal(assigns)
      _ -> render_centered(assigns)
    end
  end

  # Split Image Variant: Content on left, image on right
  defp render_split_image(assigns) do
    ~H"""
    <section class="phk-hero phk-hero--split-image py-20 bg-gradient-to-br from-primary/10 to-secondary/10">
      <div class="container mx-auto px-4">
        <div class="grid lg:grid-cols-2 gap-12 items-center">
          <div class="space-y-6">
            <%= for child <- @children do %>
              <%= if child.type in [:headline, :subheadline, :cta] do %>
                {render_child(child, assigns)}
              <% end %>
            <% end %>
          </div>
          <div class="relative">
            <%= for child <- @children do %>
              <%= if child.type == :image do %>
                {render_child(child, assigns)}
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # Centered Variant: All content centered
  defp render_centered(assigns) do
    ~H"""
    <section class="phk-hero phk-hero--centered py-24 bg-base-200">
      <div class="container mx-auto px-4">
        <div class="max-w-4xl mx-auto text-center space-y-8">
          <%= for child <- @children do %>
            {render_child(child, assigns)}
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  # Minimal Variant: Simple text-only hero
  defp render_minimal(assigns) do
    ~H"""
    <section class="phk-hero phk-hero--minimal py-16">
      <div class="container mx-auto px-4">
        <div class="max-w-3xl mx-auto text-center space-y-4">
          <%= for child <- @children do %>
            {render_child(child, assigns)}
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  defp render_child(child, assigns) do
    case PhoenixKitWeb.Live.Modules.Blogging.PageBuilder.Renderer.render(child, assigns) do
      {:ok, html} -> html
      {:error, _} -> ""
    end
  end
end
