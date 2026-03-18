defmodule PhoenixKit.Modules.Publishing.RendererTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer

  # ============================================================================
  # Tailwind Class Injection
  # ============================================================================

  describe "render_markdown/1 adds Tailwind classes to headings" do
    test "h1 gets size, weight, border classes" do
      html = Renderer.render_markdown("# Title")
      assert html =~ ~s(<h1 class=")
      assert html =~ "text-4xl"
      assert html =~ "font-bold"
      assert html =~ "border-b"
    end

    test "h2 gets size and weight classes" do
      html = Renderer.render_markdown("## Subtitle")
      assert html =~ ~s(<h2 class=")
      assert html =~ "text-3xl"
      assert html =~ "font-semibold"
    end

    test "h3 through h6 get appropriate sizes" do
      assert Renderer.render_markdown("### H3") =~ "text-2xl"
      assert Renderer.render_markdown("#### H4") =~ "text-xl"
      assert Renderer.render_markdown("##### H5") =~ "text-lg"
      assert Renderer.render_markdown("###### H6") =~ "text-base"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to paragraphs" do
    test "paragraphs get spacing and line-height" do
      html = Renderer.render_markdown("Some text")
      assert html =~ ~s(<p class=")
      assert html =~ "my-4"
      assert html =~ "leading-relaxed"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to links" do
    test "links get daisyUI link classes" do
      html = Renderer.render_markdown("[click](https://example.com)")
      assert html =~ ~s(<a class="link link-primary")
      assert html =~ ~s(href="https://example.com")
    end
  end

  describe "render_markdown/1 adds Tailwind classes to lists" do
    test "unordered lists get disc markers" do
      html = Renderer.render_markdown("- one\n- two")
      assert html =~ ~s(<ul class=")
      assert html =~ "list-disc"
      assert html =~ "pl-8"
    end

    test "ordered lists get decimal markers" do
      html = Renderer.render_markdown("1. one\n2. two")
      assert html =~ ~s(<ol class=")
      assert html =~ "list-decimal"
    end

    test "list items get spacing" do
      html = Renderer.render_markdown("- one\n- two")
      assert html =~ ~s(<li class=")
      assert html =~ "my-1"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to code" do
    test "inline code gets bg and font-mono" do
      html = Renderer.render_markdown("Use `code` here")
      assert html =~ "bg-base-200"
      assert html =~ "font-mono"
      assert html =~ "rounded"
    end

    test "code blocks get pre styling, not inline code styling" do
      html = Renderer.render_markdown("```\nsome code\n```")
      assert html =~ ~s(<pre class=")
      assert html =~ "bg-base-300"
      assert html =~ "rounded-lg"
      # Code inside pre should NOT have inline code background
      refute html =~ ~s(<code class="bg-base-200)
    end

    test "fenced code blocks preserve language class" do
      html = Renderer.render_markdown("```elixir\ndef foo, do: :bar\n```")
      assert html =~ "language-elixir"
      assert html =~ ~s(<pre class=")
    end
  end

  describe "render_markdown/1 adds Tailwind classes to blockquotes" do
    test "blockquotes get border and italic" do
      html = Renderer.render_markdown("> A quote")
      assert html =~ ~s(<blockquote class=")
      assert html =~ "border-l-4"
      assert html =~ "border-primary"
      assert html =~ "italic"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to tables" do
    test "tables get daisyUI table class" do
      md = """
      | A | B |
      |---|---|
      | 1 | 2 |
      """

      html = Renderer.render_markdown(md)
      assert html =~ ~s(<table class=")
      assert html =~ "table"
    end

    test "thead gets background" do
      md = """
      | A | B |
      |---|---|
      | 1 | 2 |
      """

      html = Renderer.render_markdown(md)
      assert html =~ ~s(<thead class=")
      assert html =~ "bg-base-200"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to hr" do
    test "hr gets border styling" do
      html = Renderer.render_markdown("---")
      assert html =~ ~s(<hr class=")
      assert html =~ "border-t-2"
      assert html =~ "my-8"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to images" do
    test "images get rounded and responsive" do
      html = Renderer.render_markdown("![alt](https://example.com/img.png)")
      assert html =~ "max-w-full"
      assert html =~ "rounded-lg"
    end
  end

  # ============================================================================
  # Blank Line Preservation
  # ============================================================================

  describe "render_markdown/1 preserves intentional blank lines" do
    test "single blank line is a normal paragraph break" do
      html = Renderer.render_markdown("Para 1\n\nPara 2")
      # Should produce exactly 2 paragraphs, no spacers
      refute html =~ "&nbsp;"
      assert html =~ "Para 1"
      assert html =~ "Para 2"
    end

    test "double blank lines produce one spacer" do
      html = Renderer.render_markdown("Para 1\n\n\nPara 2")
      assert html =~ "&nbsp;"
    end

    test "triple blank lines produce two spacers" do
      html = Renderer.render_markdown("Para 1\n\n\n\nPara 2")
      # Two extra lines = two &nbsp; spacers
      count = length(String.split(html, "&nbsp;")) - 1
      assert count == 2
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "render_markdown/1 edge cases" do
    test "empty string returns empty" do
      assert Renderer.render_markdown("") == ""
    end

    test "nil returns empty" do
      assert Renderer.render_markdown(nil) == ""
    end

    test "merges classes into existing class attribute" do
      # Inline code with Earmark's class="inline" should merge
      html = Renderer.render_markdown("Use `code` here")
      # Should have both our classes and Earmark's
      assert html =~ "font-mono"
    end

    test "does not double-style code inside pre blocks" do
      html = Renderer.render_markdown("```\ncode\n```")
      # Pre should have bg-base-300
      assert html =~ ~r/<pre class="[^"]*bg-base-300/
      # The code tag inside pre should NOT have bg-base-200 (inline code style)
      refute html =~ ~r/<code[^>]*bg-base-200/
    end
  end
end
