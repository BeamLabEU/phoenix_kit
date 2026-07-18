defmodule PhoenixKit.Utils.HtmlSanitizerTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.HtmlSanitizer

  describe "sanitize/1 strips dangerous content" do
    test "literal dangerous schemes are removed" do
      for scheme <- ~w(javascript vbscript data file blob) do
        html = ~s(<a href="#{scheme}:alert1">x</a>)
        refute HtmlSanitizer.sanitize(html) =~ "#{scheme}:"
      end
    end

    test "entity-encoded scheme bypass is closed (the reported XSS)" do
      # A browser decodes the attribute before dispatching, so a blacklist over
      # the raw text misses these — normalize (decode + strip) then allowlist.
      vectors = [
        ~s(<a href="jav&#x61;script:alert1">x</a>),
        ~s(<a href="jav&#97;script:alert1">x</a>),
        ~s(<a href="java&Tab;script:alert1">x</a>),
        ~s(<a href="java&NewLine;script:alert1">x</a>),
        ~s(<a href="javascript&colon;alert1">x</a>)
      ]

      for html <- vectors do
        clean = HtmlSanitizer.sanitize(html)
        refute clean =~ ~r/href/i, "leaked a dangerous href: #{clean}"
      end
    end

    test "whitespace/control-char obfuscation in the scheme is closed" do
      clean = HtmlSanitizer.sanitize("<a href=\"java\tscript:alert1\">x</a>")
      refute clean =~ ~r/href/i
    end

    test "unquoted dangerous href is removed" do
      refute HtmlSanitizer.sanitize("<a href=javascript:alert1>x</a>") =~ "javascript"
    end
  end

  describe "sanitize/1 keeps safe URLs" do
    test "allowed schemes and relative URLs survive intact" do
      for url <- [
            "https://example.com/page?q=1",
            "http://example.com",
            "mailto:me@example.com",
            "tel:+123456789",
            "/relative/path",
            "#fragment",
            "?just=query"
          ] do
        html = ~s(<a href="#{url}">link</a>)
        assert HtmlSanitizer.sanitize(html) =~ ~s(href="#{url}")
      end
    end

    test "safe img src survives; a data: src is dropped" do
      assert HtmlSanitizer.sanitize(~s(<img src="/img/a.png">)) =~ ~s(src="/img/a.png")
      refute HtmlSanitizer.sanitize(~s(<img src="data:image/png;base64,AAAA">)) =~ "data:"
    end

    test "a href value that merely contains 'javascript' as text is not itself a scheme" do
      # e.g. a link TO a page about javascript — path, not scheme.
      html = ~s(<a href="/articles/javascript-guide">JS guide</a>)
      assert HtmlSanitizer.sanitize(html) =~ ~s(href="/articles/javascript-guide")
    end
  end

  describe "sanitize/1 non-URL vectors (unchanged behaviour)" do
    test "script/style/event handlers still stripped" do
      assert HtmlSanitizer.sanitize("<p>Hi</p><script>x</script>") == "<p>Hi</p>"
      assert HtmlSanitizer.sanitize("<p onclick=\"x()\">Hi</p>") == "<p>Hi</p>"
    end
  end
end
