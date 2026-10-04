defmodule PhoenixKit.Email.LayoutTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Email.Layout
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @moduletag :tmp_dir

  defp write(root, name, file, content) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), content)
  end

  describe "text_to_html/1" do
    test "a blank line starts a paragraph, a single line break becomes <br>" do
      assert Layout.text_to_html("one\ntwo\n\nthree\n") ==
               ~s(<p style="margin:0 0 16px;">one<br>\ntwo</p>\n) <>
                 ~s(<p style="margin:0 0 16px;">three</p>)
    end

    test "CRLF line endings and whitespace-only separator lines count the same" do
      assert Layout.text_to_html("one\r\ntwo\r\n  \r\nthree") ==
               Layout.text_to_html("one\ntwo\n\nthree")
    end

    test "every character of the text is escaped" do
      html = Layout.text_to_html(~s[Hi <script>alert("x")</script> & 'you'])

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;you&#39;"
    end

    test "an http(s) address becomes a link; the full stop after it does not" do
      html = Layout.text_to_html("Open https://example.com/c/abc?x=1&y=2. Or http://a.test")

      assert html =~
               ~s(<a href="https://example.com/c/abc?x=1&amp;y=2">https://example.com/c/abc?x=1&amp;y=2</a>.)

      assert html =~ ~s(<a href="http://a.test">http://a.test</a>)
    end

    test "a closing parenthesis stays inside the link only when the link opened one" do
      assert Layout.text_to_html("(see https://a.test/x)") =~
               ~s{(see <a href="https://a.test/x">https://a.test/x</a>)}

      assert Layout.text_to_html("https://a.test/Foo_(bar)") =~
               ~s{<a href="https://a.test/Foo_(bar)">}
    end

    test "an address cannot break out of the href attribute" do
      html = Layout.text_to_html(~s(https://a.test/"onmouseover="x https://b.test/'q))

      # `"` ends the address; `'` is part of it but escaped inside the attribute.
      assert html =~ ~s(<a href="https://a.test/">https://a.test/</a>&quot;onmouseover=)
      assert html =~ ~s(<a href="https://b.test/&#39;q">)
    end

    test "no other scheme becomes a link" do
      html =
        Layout.text_to_html("javascript:alert(1) data:text/html,x ftp://a.test mailto:a@b.c")

      refute html =~ "<a"
      assert html =~ "javascript:alert(1)"
    end

    test "an address ends at Unicode whitespace and CJK/fullwidth punctuation" do
      for separator <- ["\u00A0", "\u2028", "\u3000", "\u3002", "\uFF0C", "\u200A"] do
        html = Layout.text_to_html("https://a.test/x" <> separator <> "tail")

        assert html =~ ~s(<a href="https://a.test/x">https://a.test/x</a>),
               "separator #{inspect(separator)}: #{html}"

        refute html =~ "tail</a>"
      end
    end

    test "non-ASCII letters stay part of the address" do
      assert Layout.text_to_html("https://de.wikipedia.org/wiki/Köln") =~
               ~s(<a href="https://de.wikipedia.org/wiki/Köln">)
    end

    test "hyphens and the en dash stay inside the address" do
      url = "https://en.wikipedia.org/wiki/Michelson–Morley_experiment"

      assert Layout.text_to_html("See #{url}.") =~ ~s(<a href="#{url}">#{url}</a>.)
      assert Layout.text_to_html("https://a.test/a\u2010b\u2011c") =~ "a\u2010b\u2011c</a>"
    end

    test "an invisible format character ends the address, so a link shows what it opens" do
      # U+202E reverses what follows on screen: linked, "moc.knab" would read as
      # part of the address while the href points at evil.test.
      for char <- ["\u202E", "\u00AD", "\u200E", "\u200F", "\u202A", "\u2066", "\u2069", "\uFEFF"] do
        html = Layout.text_to_html("https://evil.test/" <> char <> "moc.knab")

        assert html =~
                 ~s(<a href="https://evil.test/">https://evil.test/</a>) <> char <> "moc.knab",
               "char #{inspect(char)}: #{html}"
      end
    end

    test "an address ends at typographic quotes, guillemets, the em dash, an ellipsis" do
      for {text, after_link} <- [
            {"«https://a.test/x»", "</a>»"},
            {"“https://a.test/x”", "</a>”"},
            {"‘https://a.test/x’", "</a>’"},
            {"https://a.test/x…", "</a>…"},
            {"https://a.test/x—next", "</a>—next"},
            {"https://a.test/x\u200Bnext", "</a>\u200Bnext"}
          ] do
        html = Layout.text_to_html(text)

        assert html =~ ~s(<a href="https://a.test/x">https://a.test/x) <> after_link,
               "#{inspect(text)}: #{html}"
      end
    end

    test "a long run of punctuation after an address neither raises nor stalls" do
      for text <- [
            "https://a.test/" <> String.duplicate(".", 5000) <> "a",
            "see https://a.test/x" <> String.duplicate("!", 5000) <> "wow",
            "https://a.test/x" <> String.duplicate(".", 20_000)
          ] do
        {microseconds, html} = :timer.tc(fn -> Layout.text_to_html(text) end)

        assert is_binary(html)
        assert microseconds < 500_000
      end
    end

    test "trailing punctuation is split off in time linear in its length" do
      for text <- [
            "https://a.test/x" <> String.duplicate(")", 50_000),
            "https://a.test/x" <> String.duplicate(".)", 20_000)
          ] do
        {microseconds, html} = :timer.tc(fn -> Layout.text_to_html(text) end)

        assert html =~ ~s(<a href="https://a.test/x">https://a.test/x</a>)
        assert microseconds < 500_000
      end
    end

    test "an address longer than 2 KB stays text" do
      long = "https://a.test/" <> String.duplicate("a", 2100)
      html = Layout.text_to_html(long)

      refute html =~ "<a"
      assert html =~ long
    end

    test "a line that is not valid UTF-8 is escaped whole instead of raising" do
      html = Layout.text_to_html(<<"<b> https://a.test/ ", 0xFF>>)

      assert html =~ "&lt;b&gt;"
      refute html =~ "<a"
    end

    test "empty text is no paragraphs at all" do
      assert Layout.text_to_html("") == ""
      assert Layout.text_to_html("\n\n  \n") == ""
    end
  end

  describe "document?/1" do
    test "a doctype or an html element opens a whole document" do
      assert Layout.document?("<!DOCTYPE html><html></html>")
      assert Layout.document?("  \n<!doctype html>")
      assert Layout.document?("<HTML lang=\"en\">")
      assert Layout.document?("<html>")
    end

    test "a byte-order mark, comments, an XML prolog and any whitespace come first" do
      assert Layout.document?("\uFEFF<!DOCTYPE html><html></html>")
      assert Layout.document?("<!-- exported 2026-09-30 --><html>")
      assert Layout.document?(~s(<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>))
      assert Layout.document?("\u00A0\u2003<html>")
      assert Layout.document?("\uFEFF \n<!-- a -->\n<!-- b --> <?xml?><html lang=\"de\">")
    end

    test "a comment or prolog before a fragment is still a fragment" do
      refute Layout.document?("<!-- note --><p>Hi</p>")
      refute Layout.document?("<?xml version=\"1.0\"?><p>Hi</p>")
      refute Layout.document?("<!-- never closed <html>")
    end

    test "anything else is a fragment" do
      refute Layout.document?("<p>Hi</p>")
      refute Layout.document?("<htmlish>")
      refute Layout.document?("Text mentioning <html> later")
      refute Layout.document?("")
    end
  end

  describe "default_html/0" do
    test "carries no words of its own, so it needs no translation" do
      words =
        Layout.default_html()
        |> String.replace(~r/<[^>]*>/s, " ")
        |> String.replace(~r/\{\{\{?\s*\w+\s*\}?\}\}/, " ")
        |> String.trim()

      assert words == ""
    end

    test "names the document's language only for a well-formed tag" do
      assert Layout.default_html(locale: "de") =~ ~s(<html lang="de">)
      assert Layout.default_html(locale: "pt-BR") =~ ~s(<html lang="pt-BR">)
      assert Layout.default_html(locale: "pt_BR") =~ ~s(<html lang="pt-BR">)
      assert Layout.default_html() =~ "<html>\n"
      assert Layout.default_html(locale: ~s(de" onload="x)) =~ "<html>\n"
    end

    test "places the header, the body and the footer, all raw" do
      html = Layout.default_html()

      assert html =~ "{{{header}}}"
      assert html =~ "{{{content}}}"
      assert html =~ "{{{footer}}}"
    end

    test "draws the accent bar only when asked to" do
      assert Layout.default_html(accent_bar: true) =~ "border-top:3px solid {{accent_color}};"
      refute Layout.default_html() =~ "border-top:3px"
    end

    test "carries bgcolor for clients that drop CSS backgrounds, and an Outlook width" do
      html = Layout.default_html()

      assert html =~ ~s(bgcolor="#f4f4f5")
      assert html =~ ~s(bgcolor="#ffffff")
      assert html =~ "<!--[if mso]>"
    end

    test "is table markup with inline styles and nothing loaded from outside" do
      html = Layout.default_html()

      assert html =~ "<table role=\"presentation\""
      assert html =~ "max-width:600px"
      refute html =~ "<style"
      refute html =~ "<link"
      refute html =~ ~r/src=/
      refute html =~ "url("
    end
  end

  describe "wrap/3 with core's default layout" do
    test "puts the body in raw and escapes the subject" do
      html = Layout.wrap("<p>Body &amp; soul</p>", ~s(Tom & "Jerry" <b>))

      assert html =~ "<p>Body &amp; soul</p>"
      assert html =~ "<title>Tom &amp; &quot;Jerry&quot; &lt;b&gt;</title>"
    end

    test "names and links the site, from the settings core already has" do
      # This process owns no database connection: Settings answers from its
      # fallbacks rather than crashing, and so does the layout.
      html = Layout.wrap("<p>x</p>", "s")

      site_name = Settings.get_project_title()
      site_url = Routes.base_url()

      assert is_binary(site_name) and site_name != ""
      assert is_binary(site_url) and site_url != ""
      assert html =~ ">#{Phoenix.HTML.html_escape(site_name) |> Phoenix.HTML.safe_to_string()}<"
      assert html =~ ~s(href="#{site_url}")
    end

    test "the reader's locale becomes the document's language" do
      assert Layout.wrap("<p>x</p>", "s", locale: "et") =~ ~s(<html lang="et">)
    end

    test "a nil subject leaves an empty title rather than a placeholder" do
      html = Layout.wrap("<p>x</p>", nil)

      assert html =~ "<title></title>"
      refute html =~ "{{"
    end

    test "an override root with no _layout still gets the default", %{tmp_dir: root} do
      assert Layout.wrap("<p>x</p>", "s", paths: [root]) == Layout.wrap("<p>x</p>", "s")
    end
  end

  describe "wrap/3 with a host _layout" do
    test "the host's file replaces core's layout", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "<main>{{{content}}}</main>")

      assert Layout.wrap("<p>x</p>", "s", paths: [root]) == "<main><p>x</p></main>"
    end

    test "a locale file wins for its readers, the rest fall back", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "any:{{{content}}}")
      write(root, "_layout", "html.de.html", "de:{{{content}}}")

      assert Layout.wrap("b", "s", paths: [root], locale: "de") == "de:b"
      assert Layout.wrap("b", "s", paths: [root], locale: "de-AT") == "de:b"
      assert Layout.wrap("b", "s", paths: [root], locale: "fr") == "any:b"
      assert Layout.wrap("b", "s", paths: [root]) == "any:b"
    end

    test "a layout that drops the body is refused, with a warning", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "<main>{{{contnet}}}</main>")

      log =
        capture_log(fn ->
          html = Layout.wrap("<p>the body</p>", "s", paths: [root])

          assert html =~ "<p>the body</p>"
          assert html =~ "<!DOCTYPE html>"
        end)

      assert log =~ "has no {{{content}}} placeholder"

      # Once per roots and locale, not on every send.
      refute capture_log(fn -> Layout.wrap("<p>again</p>", "s", paths: [root]) end) =~
               "has no {{{content}}} placeholder"

      assert capture_log(fn -> Layout.wrap("<p>x</p>", "s", paths: [root], locale: "de") end) =~
               "has no {{{content}}} placeholder"
    end

    test "an empty layout file is refused the same way", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "")

      capture_log(fn ->
        assert Layout.wrap("<p>the body</p>", "s", paths: [root]) =~ "<p>the body</p>"
      end)
    end

    test "triple braces keep the body's markup; double braces escape", %{tmp_dir: root} do
      write(
        root,
        "_layout",
        "html.html",
        "<title>{{subject}}</title>{{{content}}}|{{content}}|{{site_name}}|{{site_url}}"
      )

      html = Layout.wrap("<p>x</p>", "<i>s</i>", paths: [root])

      assert html =~ "<title>&lt;i&gt;s&lt;/i&gt;</title><p>x</p>|&lt;p&gt;x&lt;/p&gt;|"
      refute html =~ "{{site_name}}"
      refute html =~ "{{site_url}}"
    end
  end

  describe "header and footer" do
    @no_logo %{"logo_url" => "", "accent_color" => "#1d4ed8"}
    @logo %{"logo_url" => "https://a.test/logo.jpg", "accent_color" => "#1d4ed8"}

    test "core's header is the site's name without a logo, the logo with one" do
      without = Layout.wrap("<p>x</p>", "s", branding: @no_logo)
      with_logo = Layout.wrap("<p>x</p>", "s", branding: @logo)

      refute without =~ "<img"

      assert with_logo =~
               ~s(<img src="https://a.test/logo.jpg" alt="#{escape(Settings.get_project_title())}" height="40")
    end

    test "core's footer names and links the site" do
      html = Layout.wrap("<p>x</p>", "s", branding: @no_logo)

      assert html =~ ~s(<a href="#{Routes.base_url()}" style="color:#71717a;">)
    end

    test "the accent bar shows only for a site that chose a colour" do
      # No database here, so no setting: the card looks as it did in 2.43.
      refute Layout.wrap("<p>x</p>", "s", branding: @no_logo) =~ "border-top:3px"

      assert Layout.wrap("<p>x</p>", "s", branding: @no_logo, accent_bar: true) =~
               "border-top:3px solid #1d4ed8;"
    end

    test "invalid branding values read as no logo and the neutral colour" do
      html =
        Layout.wrap("<p>x</p>", "s",
          branding: %{"logo_url" => "javascript:alert(1)", "accent_color" => "red;x:url(y)"},
          accent_bar: true
        )

      refute html =~ "<img"
      refute html =~ "javascript"
      refute html =~ "url(y)"
      assert html =~ "border-top:3px solid #18181b;"
    end

    test "a host _header replaces only the header", %{tmp_dir: root} do
      write(root, "_header", "html.html", ~s(<b class="brand">{{site_name}} {{accent_color}}</b>))

      {html, sources} = Layout.render("<p>x</p>", "s", paths: [root], branding: @logo)

      assert html =~ ~s(<b class="brand">#{escape(Settings.get_project_title())} #1d4ed8</b>)
      # Core's layout and footer are still there; core's header is not.
      assert html =~ "<!DOCTYPE html>"
      assert html =~ ~s(style="color:#71717a;")
      refute html =~ "<img"

      assert sources == %{
               layout: :default,
               header: {:file, Path.join([root, "_header", "html.html"])},
               footer: :default,
               ignored: []
             }
    end

    test "a host _footer replaces only the footer, per locale", %{tmp_dir: root} do
      write(root, "_footer", "html.html", "any-footer")
      write(root, "_footer", "html.de.html", "de-footer {{logo_url}}")

      assert Layout.wrap("b", "s", paths: [root], branding: @logo, locale: "de") =~
               "de-footer https://a.test/logo.jpg"

      assert Layout.wrap("b", "s", paths: [root], branding: @logo, locale: "fr") =~ "any-footer"
    end

    test "an empty or blank header file counts as missing, without a warning", %{tmp_dir: root} do
      write(root, "_header", "html.html", "  \n\t ")

      log =
        capture_log(fn ->
          {html, sources} = Layout.render("<p>x</p>", "s", paths: [root], branding: @logo)

          assert html =~ "<img"
          assert sources.header == :default
          assert sources.ignored == [{:blank_file, Path.join([root, "_header", "html.html"])}]
        end)

      # Other async tests log too; nothing here may be about this header.
      refute log =~ "_header"
      refute log =~ "Email layout"
    end

    test "header and footer values are escaped where written with two braces",
         %{tmp_dir: root} do
      write(root, "_header", "html.html", "<h1>{{subject}}</h1>")

      assert Layout.wrap("b", "<i>s</i>", paths: [root], branding: @logo) =~
               "<h1>&lt;i&gt;s&lt;/i&gt;</h1>"
    end

    test "a host layout places the header and footer as raw HTML", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "[{{{header}}}|{{{content}}}|{{{footer}}}]")
      write(root, "_header", "html.html", "<b>H</b>")
      write(root, "_footer", "html.html", "<i>F</i>")

      assert Layout.wrap("<p>x</p>", "s", paths: [root], branding: @logo) ==
               "[<b>H</b>|<p>x</p>|<i>F</i>]"
    end

    test "a layout that does not place the header reports no header source",
         %{tmp_dir: root} do
      write(root, "_layout", "html.html", "<main>{{{content}}}</main>")
      write(root, "_header", "html.html", "<b>H</b>")

      {_html, sources} = Layout.render("x", "s", paths: [root], branding: @logo)

      assert sources == %{
               layout: {:file, Path.join([root, "_layout", "html.html"])},
               header: nil,
               footer: nil,
               ignored: []
             }
    end
  end

  describe "groups" do
    @branding %{"logo_url" => "", "accent_color" => "#18181b"}

    test "a group's own layout, header and footer win", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "shared[{{{header}}}{{{content}}}{{{footer}}}]")

      write(
        root,
        "_layout-billing",
        "html.html",
        "billing[{{{header}}}{{{content}}}{{{footer}}}]"
      )

      write(root, "_header", "html.html", "h")
      write(root, "_header-billing", "html.html", "bh")
      write(root, "_footer-billing", "html.html", "bf")

      opts = [paths: [root], branding: @branding]

      assert Layout.wrap("x", "s", [group: "billing"] ++ opts) == "billing[bhxbf]"
      assert Layout.wrap("x", "s", opts) =~ "shared[hx"
    end

    test "each part falls back on its own: group → shared → core", %{tmp_dir: root} do
      write(root, "_header", "html.html", "shared-header")
      write(root, "_footer-billing", "html.html", "billing-footer")

      {html, sources} =
        Layout.render("<p>x</p>", "s", paths: [root], group: "billing", branding: @branding)

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "shared-header"
      assert html =~ "billing-footer"

      assert sources == %{
               layout: :default,
               header: {:file, Path.join([root, "_header", "html.html"])},
               footer: {:file, Path.join([root, "_footer-billing", "html.html"])},
               ignored: []
             }
    end

    test "a group with no files of its own is the shared chrome", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "<main>{{{content}}}</main>")

      assert Layout.wrap("x", "s", paths: [root], group: "nothing-here", branding: @branding) ==
               "<main>x</main>"
    end

    test "a group layout that drops the body falls back to the shared one", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "<main>{{{content}}}</main>")
      write(root, "_layout-billing", "html.html", "<main>{{{contnet}}}</main>")

      log =
        capture_log(fn ->
          assert Layout.wrap("x", "s", paths: [root], group: "billing", branding: @branding) ==
                   "<main>x</main>"
        end)

      assert log =~ "_layout-billing/html"
      assert log =~ "has no {{{content}}} placeholder"

      capture_log(fn ->
        {_html, sources} =
          Layout.render("x", "s", paths: [root], group: "billing", branding: @branding)

        assert sources.layout == {:file, Path.join([root, "_layout", "html.html"])}

        assert sources.ignored == [
                 {:no_content, Path.join([root, "_layout-billing", "html.html"])}
               ]
      end)
    end

    test "an invalid group name is ignored, with a warning", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "<main>{{{content}}}</main>")

      for group <- ["Billing", "../etc", "bill_ing", ""] do
        log =
          capture_log(fn ->
            assert Layout.wrap("x", "s", paths: [root], group: group, branding: @branding) ==
                     "<main>x</main>"
          end)

        assert log =~ "not a valid group name", inspect(group)
      end
    end

    test "valid_group?/1" do
      assert Layout.valid_group?("billing")
      assert Layout.valid_group?("shop-2")
      refute Layout.valid_group?("Billing")
      refute Layout.valid_group?("a_b")
      refute Layout.valid_group?("a/b")
      refute Layout.valid_group?("")
      refute Layout.valid_group?(nil)
    end
  end

  describe "render_parts/2" do
    @branding %{"logo_url" => "", "accent_color" => "#1d4ed8"}

    test "without host files: core's header and footer, and the variables they saw" do
      parts = Layout.render_parts("Hi", paths: [], branding: @branding)

      site_name = Settings.get_project_title()

      assert parts.header == escape(site_name)

      assert parts.footer ==
               escape(site_name) <>
                 ~s(<br><a href="#{Routes.base_url()}" style="color:#71717a;">#{Routes.base_url()}</a>)

      assert parts.variables == %{
               "subject" => "Hi",
               "site_name" => site_name,
               "site_url" => Routes.base_url(),
               "logo_url" => "",
               "accent_color" => "#1d4ed8"
             }

      assert parts.sources == %{header: :default, footer: :default, ignored: []}
    end

    test "a host _header and _footer are used, with their sources", %{tmp_dir: root} do
      write(root, "_header", "html.html", "<b>{{site_name}}</b>")
      write(root, "_footer", "html.html", "<i>{{accent_color}}</i>")

      parts = Layout.render_parts("s", paths: [root], branding: @branding)

      assert parts.header == "<b>#{escape(Settings.get_project_title())}</b>"
      assert parts.footer == "<i>#1d4ed8</i>"

      assert parts.sources == %{
               header: {:file, Path.join([root, "_header", "html.html"])},
               footer: {:file, Path.join([root, "_footer", "html.html"])},
               ignored: []
             }
    end

    test "a group: its own part, else the shared one, else core's", %{tmp_dir: root} do
      write(root, "_header-newsletter", "html.html", "group-header")
      write(root, "_header", "html.html", "shared-header")
      write(root, "_footer", "html.html", "shared-footer")

      grouped = Layout.render_parts("s", paths: [root], group: "newsletter", branding: @branding)
      assert {grouped.header, grouped.footer} == {"group-header", "shared-footer"}

      shared = Layout.render_parts("s", paths: [root], branding: @branding)
      assert {shared.header, shared.footer} == {"shared-header", "shared-footer"}

      other = Layout.render_parts("s", paths: [root], group: "billing", branding: @branding)
      assert other.header == "shared-header"

      core = Layout.render_parts("s", paths: [], group: "newsletter", branding: @branding)
      assert core.sources == %{header: :default, footer: :default, ignored: []}
    end

    test "the reader's locale picks the locale file", %{tmp_dir: root} do
      write(root, "_footer", "html.html", "any-footer")
      write(root, "_footer", "html.de.html", "de-footer")
      write(root, "_header-newsletter", "html.et.html", "et-group-header")
      write(root, "_header", "html.html", "any-header")

      de = Layout.render_parts("s", paths: [root], locale: "de", branding: @branding)
      fr = Layout.render_parts("s", paths: [root], locale: "fr", branding: @branding)

      assert {de.header, de.footer} == {"any-header", "de-footer"}
      assert {fr.header, fr.footer} == {"any-header", "any-footer"}

      et =
        Layout.render_parts("s",
          paths: [root],
          locale: "et",
          group: "newsletter",
          branding: @branding
        )

      assert et.header == "et-group-header"

      ru = Layout.render_parts("s", paths: [root], locale: "ru", group: "newsletter")
      assert ru.header == "any-header"
    end

    test "branding: the logo in core's header; invalid values read as none" do
      logo =
        Layout.render_parts("s",
          paths: [],
          branding: %{"logo_url" => "https://a.test/logo.jpg", "accent_color" => "#1d4ed8"}
        )

      assert logo.header =~ ~s(<img src="https://a.test/logo.jpg")
      assert logo.variables["logo_url"] == "https://a.test/logo.jpg"

      bad =
        Layout.render_parts("s",
          paths: [],
          branding: %{"logo_url" => "javascript:alert(1)", "accent_color" => "red;x:url(y)"}
        )

      refute bad.header =~ "<img"
      assert bad.variables["logo_url"] == ""
      assert bad.variables["accent_color"] == "#18181b"
    end

    test "an empty or blank file counts as missing and is reported", %{tmp_dir: root} do
      write(root, "_header-newsletter", "html.html", "")
      write(root, "_header", "html.html", " \n ")
      write(root, "_footer", "html.html", "")

      parts = Layout.render_parts("s", paths: [root], group: "newsletter", branding: @branding)

      assert parts.header == escape(Settings.get_project_title())
      assert parts.footer =~ "<br>"

      assert parts.sources == %{
               header: :default,
               footer: :default,
               ignored: [
                 {:blank_file, Path.join([root, "_header-newsletter", "html.html"])},
                 {:blank_file, Path.join([root, "_header", "html.html"])},
                 {:blank_file, Path.join([root, "_footer", "html.html"])}
               ]
             }
    end

    test "variables in the parts are escaped where written with two braces; nil subject",
         %{tmp_dir: root} do
      write(root, "_header", "html.html", "<h1>{{subject}}</h1>")

      assert Layout.render_parts("<i>s</i>", paths: [root]).header ==
               "<h1>&lt;i&gt;s&lt;/i&gt;</h1>"

      parts = Layout.render_parts(nil, paths: [root])
      assert parts.header == "<h1></h1>"
      assert parts.variables["subject"] == ""
    end

    test "an invalid group is ignored, with one warning per call", %{tmp_dir: root} do
      write(root, "_header", "html.html", "shared-header")
      write(root, "_layout", "html.html", "[{{{header}}}|{{{content}}}]")

      # A group name no other test uses, so the count is this call's alone.
      group = "../render-parts-#{System.unique_integer([:positive])}"

      parts_log =
        capture_log(fn ->
          assert Layout.render_parts("s", paths: [root], group: group).header ==
                   "shared-header"
        end)

      render_log =
        capture_log(fn ->
          assert Layout.wrap("x", "s", paths: [root], group: group) == "[shared-header|x]"
        end)

      for log <- [parts_log, render_log] do
        assert length(Regex.scan(~r/#{Regex.escape(inspect(group))} is not a valid group/, log)) ==
                 1
      end
    end

    test "render/3 places exactly these parts", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "[{{{header}}}|{{{content}}}|{{{footer}}}]")
      write(root, "_header-newsletter", "html.de.html", "<b>{{subject}}</b>")
      write(root, "_footer", "html.html", "")

      for opts <- [
            [paths: [root], branding: @branding],
            [paths: [root], group: "newsletter", locale: "de", branding: @branding],
            [paths: [root], group: "newsletter", locale: "fr"]
          ] do
        parts = Layout.render_parts("<s>", opts)
        {html, sources} = Layout.render("<p>x</p>", "<s>", opts)

        assert html == "[#{parts.header}|<p>x</p>|#{parts.footer}]"
        assert sources.header == parts.sources.header
        assert sources.footer == parts.sources.footer
        assert sources.ignored == parts.sources.ignored
      end
    end
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
