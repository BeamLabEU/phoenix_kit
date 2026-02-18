defmodule PhoenixKit.Modules.Entities.HtmlSanitizerTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Entities.HtmlSanitizer

  # --- sanitize/1 ---

  describe "sanitize/1" do
    test "preserves safe HTML" do
      assert HtmlSanitizer.sanitize("<p>Hello <strong>world</strong></p>") ==
               "<p>Hello <strong>world</strong></p>"
    end

    test "removes script tags and content" do
      assert HtmlSanitizer.sanitize("<p>Hello</p><script>alert('xss')</script>") ==
               "<p>Hello</p>"
    end

    test "removes script tags with attributes" do
      input = ~s[<p>Hi</p><script type="text/javascript">evil()</script>]
      result = HtmlSanitizer.sanitize(input)
      refute result =~ "script"
      assert result =~ "<p>Hi</p>"
    end

    test "removes style tags and content" do
      input = "<style>body{display:none}</style><p>Visible</p>"
      result = HtmlSanitizer.sanitize(input)
      refute result =~ "style"
      assert result =~ "<p>Visible</p>"
    end

    test "removes onclick event handlers" do
      result = HtmlSanitizer.sanitize(~s[<p onclick="doEvil()">Hello</p>])
      assert result == "<p>Hello</p>"
    end

    test "removes onerror event handlers" do
      result = HtmlSanitizer.sanitize(~s[<img onerror="doEvil()" src="x">])
      refute result =~ "onerror"
    end

    test "removes onload event handlers" do
      input = ~s[<body onload="evil()"><p>Content</p></body>]
      result = HtmlSanitizer.sanitize(input)
      refute result =~ "onload"
    end

    test "removes javascript: URLs from href" do
      result = HtmlSanitizer.sanitize(~s[<a href="javascript:void(0)">Click</a>])
      refute result =~ "javascript"
      assert result =~ "Click</a>"
    end

    test "removes javascript: URLs from src" do
      input = ~s[<img src="javascript:alert('xss')">]
      result = HtmlSanitizer.sanitize(input)
      refute result =~ "javascript"
    end

    test "removes data: URLs" do
      input = ~s[<a href="data:text/html,<script>alert('xss')</script>">Click</a>]
      result = HtmlSanitizer.sanitize(input)
      refute result =~ "data:"
    end

    test "removes iframe tags" do
      input = ~s(<iframe src="https://evil.com"></iframe><p>Safe</p>)
      result = HtmlSanitizer.sanitize(input)
      refute result =~ "iframe"
      assert result =~ "<p>Safe</p>"
    end

    test "removes object tags" do
      input = ~s(<object data="evil.swf"></object><p>Safe</p>)
      result = HtmlSanitizer.sanitize(input)
      refute result =~ "object"
    end

    test "removes embed tags" do
      input = ~s(<embed src="evil.swf"><p>Safe</p>)
      result = HtmlSanitizer.sanitize(input)
      refute result =~ "embed"
    end

    test "removes form tags" do
      input = ~s(<form action="/steal"><input name="password"></form>)
      result = HtmlSanitizer.sanitize(input)
      refute result =~ "form"
      refute result =~ "input"
    end

    test "preserves safe links" do
      input = ~s(<a href="https://example.com">Link</a>)
      assert HtmlSanitizer.sanitize(input) == input
    end

    test "preserves tables" do
      input = "<table><tr><td>Cell</td></tr></table>"
      assert HtmlSanitizer.sanitize(input) == input
    end

    test "preserves lists" do
      input = "<ul><li>Item 1</li><li>Item 2</li></ul>"
      assert HtmlSanitizer.sanitize(input) == input
    end

    test "returns nil for nil input" do
      assert HtmlSanitizer.sanitize(nil) == nil
    end

    test "returns empty string for empty input" do
      assert HtmlSanitizer.sanitize("") == ""
    end

    test "passes through non-string values" do
      assert HtmlSanitizer.sanitize(42) == 42
    end

    test "trims whitespace from result" do
      assert HtmlSanitizer.sanitize("  <p>Hello</p>  ") == "<p>Hello</p>"
    end
  end

  # --- sanitize_rich_text_fields/2 ---

  describe "sanitize_rich_text_fields/2" do
    test "sanitizes only rich_text fields" do
      fields = [
        %{"type" => "rich_text", "key" => "content"},
        %{"type" => "text", "key" => "title"}
      ]

      data = %{
        "content" => "<p>Hello</p><script>evil()</script>",
        "title" => "<script>should stay</script>Title"
      }

      result = HtmlSanitizer.sanitize_rich_text_fields(fields, data)

      assert result["content"] == "<p>Hello</p>"
      # text field is NOT sanitized
      assert result["title"] == "<script>should stay</script>Title"
    end

    test "handles multiple rich_text fields" do
      fields = [
        %{"type" => "rich_text", "key" => "body"},
        %{"type" => "rich_text", "key" => "summary"}
      ]

      data = %{
        "body" => "<p>Body</p><script>x</script>",
        "summary" => "<p>Summary</p><script>y</script>"
      }

      result = HtmlSanitizer.sanitize_rich_text_fields(fields, data)

      assert result["body"] == "<p>Body</p>"
      assert result["summary"] == "<p>Summary</p>"
    end

    test "skips nil values in rich_text fields" do
      fields = [%{"type" => "rich_text", "key" => "content"}]
      data = %{"content" => nil}

      result = HtmlSanitizer.sanitize_rich_text_fields(fields, data)
      assert result["content"] == nil
    end

    test "handles no rich_text fields" do
      fields = [%{"type" => "text", "key" => "name"}]
      data = %{"name" => "test"}

      result = HtmlSanitizer.sanitize_rich_text_fields(fields, data)
      assert result == data
    end

    test "handles empty fields list" do
      data = %{"content" => "<script>evil</script>"}
      result = HtmlSanitizer.sanitize_rich_text_fields([], data)
      assert result == data
    end

    test "returns data unchanged for invalid fields argument" do
      data = %{"test" => "value"}
      assert HtmlSanitizer.sanitize_rich_text_fields("invalid", data) == data
    end
  end
end
