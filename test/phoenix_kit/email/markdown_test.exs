defmodule PhoenixKit.Email.MarkdownTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Email.Markdown

  @accent "#1d4ed8"

  defp html(markdown, variables \\ %{}),
    do: Markdown.to_html(markdown, Map.put_new(variables, "accent_color", @accent))

  describe "to_html/2 placeholders" do
    test "a placeholder in a link target arrives as its value, not percent-encoded" do
      out =
        html("Go [here]({{url}}) now.", %{"url" => "https://a.test/confirm/abc?x=1&y=2"})

      assert out =~ ~s(<a href="https://a.test/confirm/abc?x=1&amp;y=2")
      refute out =~ "%7B"
      refute out =~ "{{"
    end

    test "a placeholder inside a target is filled in place" do
      out = html("[Open](https://a.test/u/{{id}}/edit)", %{"id" => "42"})
      assert out =~ ~s(href="https://a.test/u/42/edit")
    end

    test "double braces escape the value, triple braces insert it raw" do
      out = html("Hi {{name}} and {{{raw}}}", %{"name" => "<b>Ada</b>", "raw" => "<i>x</i>"})

      assert out =~ "Hi &lt;b&gt;Ada&lt;/b&gt; and <i>x</i>"
    end

    test "a value is rendered as data, never as Markdown" do
      out = html("Hi {{name}}", %{"name" => "**bold** [x](https://evil.test)"})

      refute out =~ "<strong>"
      refute out =~ "evil.test\""
      assert out =~ "**bold** [x](https://evil.test)"
    end

    test "a value is substituted once — a placeholder inside a value stays text" do
      out =
        html("Hi {{name}} [go]({{url}})", %{
          "name" => "{{secret}}",
          "url" => "https://a.test/{{secret}}",
          "secret" => "S3CRET"
        })

      refute out =~ "S3CRET"
      assert out =~ "Hi {{secret}}"
      assert out =~ ~s(href="https://a.test/{{secret}}")
    end

    test "a placeholder is an ordinary word to the renderer: an address around it is linked" do
      out = html("Write to {{user}}@example.test", %{"user" => "ada"})

      assert out =~
               ~s(<a href="mailto:ada@example.test" style="color:#{@accent};">ada@example.test</a>)
    end

    test "a placeholder in angle brackets is not mistaken for an HTML tag" do
      assert html("See <{{url}}>", %{"url" => "x"}) =~ "See &lt;x&gt;"
    end

    test "an unbound placeholder stays visible in text" do
      assert html("Hi {{nobody}}") =~ "Hi {{nobody}}"
    end

    test "placeholders inside inline code are filled and escaped" do
      assert html("`{{name}}`", %{"name" => "<x>"}) =~ "<code>&lt;x&gt;</code>"
    end

    test "placeholder-shaped text written by the author survives emphasis around it" do
      assert html("**{{name}}**", %{"name" => "Ada"}) =~ "<strong>Ada</strong>"
    end
  end

  describe "to_html/2 links" do
    test "a link inside a sentence is a link in the accent colour" do
      out = html("Read [the terms](https://a.test/terms) first.")

      assert out =~
               ~s(Read <a href="https://a.test/terms" style="color:#{@accent};">the terms</a> first.)
    end

    test "javascript: from a variable never becomes a link" do
      out = html("[Pay]({{url}}) or [this]({{url}}) one", %{"url" => "javascript:alert(1)"})

      refute out =~ "href"
      refute out =~ "javascript"
      assert out =~ "Pay"
    end

    test "javascript: as a lone link drops the button and keeps the label" do
      out = html("[Pay]({{url}})", %{"url" => " JavaScript:alert(1)"})

      refute out =~ "href"
      refute out =~ "<table"
      assert out =~ ~s(<p style="margin:0 0 16px;">Pay</p>)
    end

    test "the scheme is checked at the start of the address, not anywhere in it" do
      out =
        html("[a]({{u}}) [b]({{u}}) ![c]({{u}})", %{"u" => "javascript:alert('https://a.test/')"})

      refute out =~ "href"
      refute out =~ "<img"
      refute out =~ "javascript"

      assert Markdown.to_text("[a]({{u}})", %{"u" => "javascript:x//mailto:a@b.test"}) == "a"
    end

    test "only http(s) and mailto targets are kept" do
      out = html("[a](mailto:x@y.test) [b](/relative) [c](data:text/html,x) [d](ftp://a.test)")

      assert out =~ ~s(<a href="mailto:x@y.test")
      refute out =~ ~s(href="/relative")
      refute out =~ "data:"
      refute out =~ "ftp:"
    end

    test "a target nothing bound is no link" do
      out = html("[Confirm]({{confirmation_url}})")

      refute out =~ "href"
      assert out =~ "Confirm"
    end

    test "a value cannot break out of the attribute" do
      out = html("[x]({{url}}) y", %{"url" => ~s{https://a.test/"onmouseover="alert(1)}})

      assert out =~ ~s{href="https://a.test/&quot;onmouseover=&quot;alert(1)"}
    end
  end

  describe "to_html/2 buttons" do
    test "a paragraph that is exactly one link becomes a button in the accent colour" do
      out =
        html("Hi.\n\n[Confirm]({{confirmation_url}})\n\nThanks.", %{
          "confirmation_url" => "https://a.test/c/tok"
        })

      assert out =~ ~s(<table role="presentation")
      assert out =~ ~s(bgcolor="#{@accent}")
      assert out =~ ~s(background-color:#{@accent};)
      assert out =~ ~s(<a href="https://a.test/c/tok" style="display:inline-block;)
      assert out =~ ">Confirm</a>"
      # The button replaces the paragraph rather than sitting inside one.
      refute out =~ "<p><table"
      refute out =~ ~s(<p style="margin:0 0 16px;"><table)
    end

    test "only a top-level paragraph is a button: a link alone in a list item or a quote is not" do
      out =
        html(
          "- [In a list](https://a.test/l)\n\n> [In a quote](https://a.test/q)\n\n[Top](https://a.test/t)"
        )

      assert out =~ ~s(<a href="https://a.test/l" style="color:#{@accent};">In a list</a>)
      assert out =~ ~s(<a href="https://a.test/q" style="color:#{@accent};">In a quote</a>)
      assert out =~ ~s(<a href="https://a.test/t" style="display:inline-block;)
      assert length(String.split(out, "<table")) == 2
    end

    test "a link with text around it is not a button" do
      refute html("Please [confirm](https://a.test) now") =~ "<table"
    end

    test "a bare address on its own line stays a link" do
      out = html("https://a.test/x")

      refute out =~ "<table"
      assert out =~ ~s(<a href="https://a.test/x" style="color:#{@accent};">https://a.test/x</a>)

      www = html("www.a.test")
      refute www =~ "<table"
      assert www =~ ~s(<a href="http://www.a.test" style="color:#{@accent};">www.a.test</a>)
    end

    test "the label keeps its own formatting and its placeholders" do
      out = html("[**Pay** {{amount}}](https://a.test/pay)", %{"amount" => "<10 €>"})

      assert out =~ "<strong>Pay</strong> &lt;10 €&gt;</a>"
    end

    test "white text on a dark accent, dark text on a light one" do
      dark = Markdown.to_html("[Go](https://a.test)", %{"accent_color" => "#1d4ed8"})
      light = Markdown.to_html("[Go](https://a.test)", %{"accent_color" => "#fde047"})

      assert dark =~ "color:#ffffff;text-decoration:none"
      assert light =~ "color:#18181b;text-decoration:none"
    end

    test "an invalid accent colour falls back to the neutral one" do
      out = Markdown.to_html("[Go](https://a.test)", %{"accent_color" => "red;x:url(y)"})

      assert out =~ ~s(bgcolor="#18181b")
      refute out =~ "red;"
    end

    test "the accent colour may be passed under an atom key" do
      assert Markdown.to_html("[Go](https://a.test)", %{accent_color: "#00aa00"}) =~
               ~s(bgcolor="#00aa00")
    end
  end

  describe "to_html/2 markup" do
    test "headings, emphasis, lists and tables render" do
      out = html("# Title\n\n*a* **b** ~~c~~\n\n- one\n- two\n\n| h |\n|---|\n| v |")

      assert out =~ "<h1>Title</h1>"
      assert out =~ "<em>a</em> <strong>b</strong> <del>c</del>"
      assert out =~ "<li>one</li>"
      assert out =~ "<td>v</td>"
    end

    test "raw HTML in the Markdown is not rendered" do
      out =
        html(~s|<a href="{{url}}">x</a> <script>alert(1)</script>|, %{"url" => "javascript:x"})

      refute out =~ "<script"
      refute out =~ "<a "
      refute out =~ "javascript"
    end

    test "an image's alt text is escaped as an attribute, triple braces too" do
      out =
        html(~s|![{{{n}}} {{n}}](https://a.test/a.png)|, %{"n" => ~s|" onerror="alert(1)|})

      assert out =~
               ~s|alt="&quot; onerror=&quot;alert(1) &quot; onerror=&quot;alert(1)"|

      refute out =~ ~s|" onerror="|
    end

    test "the alt text of an image that is not shown is escaped too" do
      out = html("![{{{n}}}](javascript:x)", %{"n" => "<b>x</b>"})

      assert out =~ "&lt;b&gt;x&lt;/b&gt;"
      refute out =~ "<b>"
    end

    test "an image needs an http(s) address" do
      ok = html("![Logo]({{logo_url}})", %{"logo_url" => "https://a.test/l.png"})
      bad = html("![Logo]({{logo_url}})", %{"logo_url" => "javascript:x"})

      assert ok =~ ~s(<img src="https://a.test/l.png" alt="Logo")
      refute bad =~ "<img"
      assert bad =~ "Logo"
    end
  end

  describe "to_text/2" do
    test "headings, paragraphs and lists as lines; a link as label: url" do
      text =
        Markdown.to_text(
          """
          # Welcome {{name}}

          Please *confirm* your account:

          [Confirm]({{confirmation_url}})

          - first
          - second

          1. one
          2. two
          """,
          %{"name" => "Ada", "confirmation_url" => "https://a.test/c"}
        )

      assert text ==
               """
               Welcome Ada

               Please confirm your account:

               Confirm: https://a.test/c

               - first
               - second

               1. one
               2. two\
               """
    end

    test "values are not escaped in text" do
      assert Markdown.to_text("Hi {{name}}", %{"name" => "<Ada & co>"}) == "Hi <Ada & co>"
    end

    test "an unsafe target leaves only the label" do
      assert Markdown.to_text("[Pay]({{url}})", %{"url" => "javascript:alert(1)"}) == "Pay"
    end

    test "a bare address is written once" do
      assert Markdown.to_text("See https://a.test/x", %{}) == "See https://a.test/x"
      assert Markdown.to_text("www.a.test", %{}) == "www.a.test"
    end

    test "Markdown that is not UTF-8 comes back as text instead of raising" do
      assert Markdown.to_text(<<"a ", 0xFF, " {{n}}">>, %{"n" => "b"}) == <<"a ", 0xFF, " b">>
      assert Markdown.to_html(<<"a ", 0xFF, " {{n}}">>, %{"n" => "<b>"}) =~ "&lt;b&gt;"
    end

    test "a value is substituted once in text too" do
      assert Markdown.to_text("[go]({{url}}) {{a}}", %{
               "url" => "https://a.test/{{a}}",
               "a" => "{{b}}",
               "b" => "B"
             }) == "go: https://a.test/{{a}} {{b}}"
    end
  end

  describe "a paragraph that is only placeholders" do
    @body "Hi.\n\n{{note}}\n\nIf this was you, no action is needed."

    test "it is left out of both bodies when its placeholders fill in blank" do
      out = html(@body, %{"note" => ""})

      refute out =~ ~r/<p[^>]*>\s*<\/p>/
      assert out =~ "Hi.</p>"

      assert Markdown.to_text(@body, %{"note" => ""}) ==
               "Hi.\n\nIf this was you, no action is needed."
    end

    test "an unbound placeholder is not blank: it stays visible" do
      assert html(@body) =~ "{{note}}"
      assert Markdown.to_text(@body, %{}) =~ "{{note}}"
    end

    test "a value that ends in a blank line stays its own paragraph" do
      note = "There were also 2 failed sign-in attempts.\n\n"
      out = html(@body, %{"note" => note})

      assert out =~ ~r/<p[^>]*>There were also 2 failed sign-in attempts\.\s*<\/p>/
      assert out =~ ~r/<p[^>]*>If this was you/

      assert Markdown.to_text(@body, %{"note" => note}) ==
               "Hi.\n\nThere were also 2 failed sign-in attempts.\n\nIf this was you, no action is needed."
    end

    test "text around the placeholder keeps the paragraph" do
      assert html("Note: {{note}}", %{"note" => ""}) =~ "Note:"
    end

    test "a paragraph with a link is never dropped, even when its label is blank" do
      out = html("[{{label}}](https://a.test)\n\nend", %{"label" => ""})
      assert out =~ ~s(href="https://a.test")
    end
  end

  describe "a paragraph that is exactly one raw placeholder" do
    @table "<table><tr><td>Widget</td></tr></table>"

    test "is the value alone, with no paragraph around it" do
      out = html("Your order:\n\n{{{items}}}\n\nThanks.", %{"items" => @table})

      assert out =~ ~r/Your order:<\/p>\s*#{Regex.escape(@table)}\s*<p[^>]*>Thanks\.<\/p>/
      refute out =~ ~r/<p[^>]*>\s*<table/
    end

    test "a double-brace placeholder alone keeps its paragraph, escaped" do
      out = html("{{items}}", %{"items" => @table})
      assert out =~ ~r/<p[^>]*>&lt;table&gt;/
    end

    test "a raw placeholder with text around it keeps the paragraph" do
      assert html("Items: {{{items}}}", %{"items" => "<b>x</b>"}) =~
               ~r/<p[^>]*>Items: <b>x<\/b><\/p>/
    end
  end

  describe "the address written out as its own label" do
    @fallback "If the button does not work, open this link: [{{url}}]({{url}})"

    test "is a link in the HTML" do
      out = html(@fallback, %{"url" => "https://a.test/c?x=1&y=2"})

      assert out =~
               ~s(<a href="https://a.test/c?x=1&amp;y=2" style="color:#{@accent};">https://a.test/c?x=1&amp;y=2</a>)
    end

    test "reads as the address once in the text" do
      assert Markdown.to_text(@fallback, %{"url" => "https://a.test/c"}) ==
               "If the button does not work, open this link: https://a.test/c"
    end

    test "a label that only differs from the address keeps both" do
      assert Markdown.to_text("[Open {{url}}]({{url}})", %{"url" => "https://a.test"}) ==
               "Open https://a.test: https://a.test"
    end

    test "an unsafe address leaves the label alone, still once" do
      assert Markdown.to_text("Link: [{{url}}]({{url}})", %{"url" => "javascript:x"}) ==
               "Link: javascript:x"
    end
  end

  describe "many links and images" do
    # Building them used to rescan the whole HTML and recompile the token set
    # per element: 5000 links took over half a minute. Counted in reductions
    # of this process rather than wall time, so a busy machine cannot fail the
    # test: four times the elements must cost about four times the work (the
    # old build cost eight times as much, its text body almost six).
    defp document(n) do
      Enum.map_join(1..n, "\n\n", &"[link #{&1}]({{url}}/#{&1}) and {{name}}") <>
        "\n\n" <>
        Enum.map_join(1..div(n, 2), "\n\n", &"![{{name}} #{&1}]({{url}}/#{&1}.png)") <>
        "\n\n" <> Enum.map_join(1..div(n, 2), "\n\n", &"[b #{&1}]({{url}}/b#{&1})")
    end

    defp reductions(fun) do
      {:reductions, before} = Process.info(self(), :reductions)
      result = fun.()
      {:reductions, later} = Process.info(self(), :reductions)
      {later - before, result}
    end

    # Wall time is not asserted, but a loaded test run is slow at this size.
    @tag timeout: 300_000
    test "the work grows linearly with the number of links and images" do
      variables = %{"url" => "https://a.test", "name" => "Ada", "accent_color" => @accent}
      small = document(500)
      large = document(2000)

      {html_small, _} = reductions(fn -> Markdown.to_html(small, variables) end)
      {html_large, html} = reductions(fn -> Markdown.to_html(large, variables) end)
      {text_small, _} = reductions(fn -> Markdown.to_text(small, variables) end)
      {text_large, text} = reductions(fn -> Markdown.to_text(large, variables) end)

      assert html =~
               ~s(<a href="https://a.test/2000" style="color:#{@accent};">link 2000</a> and Ada)

      assert html =~ ~s(<img src="https://a.test/1000.png" alt="Ada 1000")
      assert html =~ ~s(<a href="https://a.test/b1000" style="display:inline-block;)
      assert text =~ "link 2000: https://a.test/2000 and Ada"

      assert html_large / html_small < 5.5, "html: #{html_large / html_small}x"
      assert text_large / text_small < 5.0, "text: #{text_large / text_small}x"
    end
  end
end
