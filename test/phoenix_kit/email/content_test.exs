defmodule PhoenixKit.Email.ContentTest do
  use ExUnit.Case, async: true

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Bitwise
  import ExUnit.CaptureLog

  alias PhoenixKit.Email.Content

  @moduletag :tmp_dir

  # The real msgids core sends, so the assertions below break if a translation
  # is reworded rather than passing against copy invented for the test.
  defp defaults do
    fn ->
      %{
        subject: gettext("Confirm your account"),
        text:
          gettext("""
          Hi {{user_email}},

          You can confirm your account by visiting the URL below:

          {{confirmation_url}}

          If you didn't create an account with us, please ignore this.
          """)
      }
    end
  end

  defp user(locale), do: %{email: "a@b.c", custom_fields: %{"preferred_locale" => locale}}

  defp text_only(text), do: fn -> %{subject: "Hello <you>", text: text} end

  defp file_name(:html), do: "html.html"
  defp file_name(:markdown), do: "markdown.md"
  defp file_name(:text), do: "text.txt"

  defp marker(layer, part), do: "#{layer}#{part}marker"

  defp write(root, name, file, content) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), content)
  end

  describe "resolve/4 without a host override" do
    test "evaluates the defaults inside the recipient's locale" do
      # The point of the whole exercise: the sender's locale is not the
      # recipient's, and these render on a process that has neither.
      assert Content.resolve("register", user("de"), %{}, defaults()).subject ==
               "Bestätigen Sie Ihr Konto"

      assert Content.resolve("register", user("ru"), %{}, defaults()).subject ==
               "Подтвердите ваш аккаунт"
    end

    test "substitutes variables into the translated body" do
      resolved =
        Content.resolve("register", user("de"), %{"user_email" => "a@b.c"}, defaults())

      assert resolved.text =~ "Hallo a@b.c,"
      # An unbound placeholder stays visible rather than blanking silently.
      assert resolved.text =~ "{{confirmation_url}}"
    end

    test "a feature module's defaults are in the recipient's language too" do
      # Billing's defaults translate through its own backend, which reads the
      # process-global locale, not `PhoenixKitWeb.Gettext`'s. The sender here
      # is an admin working in Portuguese.
      module_defaults = fn ->
        %{
          subject: Gettext.dgettext(PhoenixKit.Test.ModuleGettext, "default", "Your invoice"),
          text: "{{invoice_number}}"
        }
      end

      Gettext.put_locale("pt")

      assert Content.resolve("billing_invoice", user("es-ES"), %{}, module_defaults).subject ==
               "Su factura"

      assert Gettext.get_locale() == "pt"
    end

    test "reports no database template on this path" do
      assert Content.resolve("register", user("de"), %{}, defaults()).db_template == nil
    end

    test "a recipient with no preference still resolves to a usable locale" do
      resolved = Content.resolve("register", "stranger@example.com", %{}, defaults())

      assert is_binary(resolved.subject) and resolved.subject != ""
    end
  end

  describe "resolve/4 with a host override" do
    test "an override replaces that part and leaves the others translated", %{tmp_dir: root} do
      write(root, "register", "text.txt", "Custom body for {{user_email}}.")

      resolved =
        Content.resolve("register", user("de"), %{"user_email" => "a@b.c"}, defaults(),
          paths: [root]
        )

      assert resolved.text == "Custom body for a@b.c."
      assert resolved.subject == "Bestätigen Sie Ihr Konto"
    end

    test "the recipient's locale selects among override files", %{tmp_dir: root} do
      write(root, "register", "text.txt", "fallback")
      write(root, "register", "text.de.txt", "deutscher Text")

      assert Content.resolve("register", user("de"), %{}, defaults(), paths: [root]).text ==
               "deutscher Text"

      assert Content.resolve("register", user("fr"), %{}, defaults(), paths: [root]).text ==
               "fallback"
    end
  end

  describe "resolve/5 and the shared layout" do
    test "a text-only message gets an HTML body: layout, escaped paragraphs, a link" do
      resolved =
        Content.resolve(
          "layout_probe",
          user("en"),
          %{"name" => ~s[<script>alert("x")</script>], "url" => "https://example.test/c/abc"},
          text_only("Hi {{name}},\n\nOpen {{url}}.\nOr javascript:alert(1)\n")
        )

      html = resolved.html

      # Core's layout around the body.
      assert html =~ "<!DOCTYPE html>"
      assert html =~ "<title>Hello &lt;you&gt;</title>"
      # The variable's markup and quotes are text, not HTML.
      refute html =~ "<script>"
      assert html =~ "Hi &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;,</p>"
      assert html =~ ~s(<a href="https://example.test/c/abc">https://example.test/c/abc</a>.<br>)
      refute html =~ ~s(href="javascript)

      # The text and subject are what they always were.
      assert resolved.text ==
               ~s[Hi <script>alert("x")</script>,\n\nOpen https://example.test/c/abc.\nOr javascript:alert(1)\n]

      assert resolved.subject == "Hello <you>"
    end

    test "core's own translated default arrives as HTML in the reader's language" do
      html =
        Content.resolve(
          "register",
          user("de"),
          %{"user_email" => "a@b.c", "confirmation_url" => "https://example.test/c"},
          defaults()
        ).html

      assert html =~ "<title>Bestätigen Sie Ihr Konto</title>"
      assert html =~ "Hallo a@b.c,"
      assert html =~ ~s(<a href="https://example.test/c">)
    end

    test "layout: false leaves a text-only message without HTML" do
      resolved =
        Content.resolve("layout_probe", user("en"), %{}, text_only("body"), layout: false)

      assert resolved.html == nil
      assert resolved.text == "body"
    end

    test "an html fragment is wrapped, its own markup kept", %{tmp_dir: root} do
      write(root, "fragment_probe", "html.html", "<p class=\"x\">Hi {{name}}</p>")

      resolved =
        Content.resolve("fragment_probe", user("en"), %{"name" => "<b>"}, text_only("t"),
          paths: [root]
        )

      assert resolved.html =~ "<!DOCTYPE html>"
      assert resolved.html =~ ~s(<p class="x">Hi &lt;b&gt;</p>)
      assert resolved.text == "t"
    end

    test "a whole html document is left alone", %{tmp_dir: root} do
      document = "  <!doctype html>\n<html><body>Own chrome</body></html>"
      write(root, "document_probe", "html.html", document)

      assert Content.resolve("document_probe", user("en"), %{}, text_only("t"), paths: [root]).html ==
               document
    end

    test "layout: false leaves a fragment as it was", %{tmp_dir: root} do
      write(root, "fragment_off_probe", "html.html", "<p>bare</p>")

      assert Content.resolve("fragment_off_probe", user("en"), %{}, text_only("t"),
               paths: [root],
               layout: false
             ).html == "<p>bare</p>"
    end

    test "a whole document behind a byte-order mark and a comment is left alone",
         %{tmp_dir: root} do
      document = "\uFEFF<!-- exported -->\n<!DOCTYPE html><html><body>Own</body></html>"
      write(root, "bom_document_probe", "html.html", document)

      assert Content.resolve("bom_document_probe", user("en"), %{}, text_only("t"), paths: [root]).html ==
               document
    end

    test "an empty html file counts as no html: the text is wrapped", %{tmp_dir: root} do
      write(root, "empty_html_probe", "html.html", "")

      html =
        Content.resolve("empty_html_probe", user("en"), %{}, text_only("from text"),
          paths: [root]
        ).html

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "from text</p>"
    end

    test "blank html and blank text resolve to nil" do
      resolved =
        Content.resolve("blank_probe", user("en"), %{}, fn ->
          %{subject: "s", text: "", html: "  \n"}
        end)

      assert resolved.html == nil
      assert resolved.text == nil
    end

    test "a blank part is no part without the layout either", %{tmp_dir: root} do
      write(root, "blank_off_probe", "html.html", "")

      resolved =
        Content.resolve("blank_off_probe", user("en"), %{}, fn -> %{subject: "s", text: " "} end,
          paths: [root],
          layout: false
        )

      assert %{html: nil, text: nil} = resolved
    end

    test "the layout resolves from the message's own roots and reader locale",
         %{tmp_dir: root} do
      write(root, "_layout", "html.html", "ANY[{{{content}}}]")
      write(root, "_layout", "html.de.html", "DE[{{{content}}}]")

      assert Content.resolve("layout_locale_probe", user("de"), %{}, text_only("body"),
               paths: [root]
             ).html =~ ~r/\ADE\[<p[^>]*>body<\/p>\]\z/

      assert Content.resolve("layout_locale_probe", user("fr"), %{}, text_only("body"),
               paths: [root]
             ).html =~ ~r/\AANY\[/

      # The :locale option wins over the recipient's own preference.
      assert Content.resolve("layout_locale_probe", user("fr"), %{}, text_only("body"),
               paths: [root],
               locale: "de"
             ).html =~ ~r/\ADE\[/
    end

    test "nothing to wrap leaves every part nil" do
      resolved = Content.resolve("empty_probe", user("en"), %{}, fn -> %{} end)

      assert %{subject: nil, text: nil, html: nil} = resolved
    end
  end

  describe "resolve/5 with a markdown part" do
    test "markdown is the HTML body and, with no text part, the text body", %{tmp_dir: root} do
      write(root, "register", "markdown.ru.md", """
      Здравствуйте, {{user_email}}!

      [Подтвердить]({{confirmation_url}})
      """)

      resolved =
        Content.resolve(
          "register",
          user("ru"),
          %{"user_email" => "a@b.c", "confirmation_url" => "https://example.test/c/tok"},
          fn -> %{subject: "s"} end,
          paths: [root]
        )

      assert resolved.html =~ "<!DOCTYPE html>"
      assert resolved.html =~ "Здравствуйте, a@b.c!"
      # The button, with the real address — not `%7B%7Bconfirmation_url%7D%7D`.
      assert resolved.html =~ ~s(<table role="presentation" cellpadding="0")

      assert resolved.html =~
               ~s(<a href="https://example.test/c/tok" style="display:inline-block;)

      refute resolved.html =~ "%7B"

      assert resolved.text ==
               "Здравствуйте, a@b.c!\n\nПодтвердить: https://example.test/c/tok"
    end

    test "a host's markdown replaces core's default text in both bodies", %{tmp_dir: root} do
      write(root, "register", "markdown.md", "Custom **{{user_email}}**")

      {resolved, sources} =
        Content.resolve_with_sources(
          "register",
          user("de"),
          %{"user_email" => "a@b.c"},
          defaults(),
          paths: [root]
        )

      assert resolved.html =~ "Custom <strong>a@b.c</strong>"
      # The host chose the body: core's default text does not ride along.
      assert resolved.text == "Custom a@b.c"
      assert sources.text == :default
      assert sources.text_from == :markdown
      assert resolved.subject == "Bestätigen Sie Ihr Konto"
    end

    test "a host's text outranks a caller's html default in the HTML body too",
         %{tmp_dir: root} do
      write(root, "host_text_probe", "text.txt", "host words")

      {resolved, sources} =
        Content.resolve_with_sources(
          "host_text_probe",
          user("en"),
          %{},
          fn -> %{subject: "s", html: "<p>module html</p>", text: "module text"} end,
          paths: [root]
        )

      assert resolved.html =~ "host words</p>"
      refute resolved.html =~ "module html"
      assert resolved.text == "host words"
      assert sources.html_from == :text
      assert sources.html == :default
    end

    # The case the reorder exists for: core's defaults are Markdown, and a host
    # that rewrote `text.txt` before they were must not be sent an HTML version
    # that still carries core's copy.
    test "a host's text outranks a caller's markdown default: HTML and text agree",
         %{tmp_dir: root} do
      write(root, "host_text_md_probe", "text.txt", "Host copy: {{url}}")

      {resolved, sources} =
        Content.resolve_with_sources(
          "host_text_md_probe",
          user("en"),
          %{"url" => "https://a.test/c"},
          fn -> %{subject: "s", markdown: "Core copy\n\n[Confirm]({{url}})"} end,
          paths: [root]
        )

      assert resolved.text == "Host copy: https://a.test/c"
      assert resolved.html =~ "Host copy:"
      assert resolved.html =~ ~s(<a href="https://a.test/c">https://a.test/c</a>)
      refute resolved.html =~ "Core copy"
      refute resolved.html =~ "Confirm"
      assert sources.html_from == :text
      assert sources.text_from == :text
    end

    test "without a host file a caller's markdown default builds both bodies" do
      {resolved, sources} =
        Content.resolve_with_sources(
          "md_default_probe",
          user("en"),
          %{"url" => "https://a.test/c"},
          fn -> %{subject: "s", markdown: "Core copy\n\n[Confirm]({{url}})"} end
        )

      assert resolved.html =~ "Core copy"
      assert resolved.html =~ ~r/<table role="presentation".*href="https:\/\/a.test\/c"/s
      assert resolved.text == "Core copy\n\nConfirm: https://a.test/c"
      assert sources.html_from == :markdown
      assert sources.text_from == :markdown
    end

    test "a host's markdown outranks a caller's html default", %{tmp_dir: root} do
      write(root, "host_md_probe", "markdown.md", "host *words*")

      resolved =
        Content.resolve(
          "host_md_probe",
          user("en"),
          %{},
          fn -> %{subject: "s", html: "<p>module html</p>", text: "module text"} end,
          paths: [root]
        )

      assert resolved.html =~ "host <em>words</em>"
      refute resolved.html =~ "module html"
      assert resolved.text == "host words"
    end

    test "a host's html keeps the caller's text default for the text body", %{tmp_dir: root} do
      write(root, "host_html_probe", "html.html", "<p>host html</p>")

      resolved =
        Content.resolve("host_html_probe", user("en"), %{}, text_only("module text"),
          paths: [root]
        )

      assert resolved.html =~ "<p>host html</p>"
      assert resolved.text == "module text"
    end

    # Every combination of host files and defaults over html/markdown/text,
    # against the order table in the moduledoc. A part a host file supplies
    # shadows the default for that same part.
    @html_order [
      {:host, :html},
      {:host, :markdown},
      {:host, :text},
      {:default, :html},
      {:default, :markdown},
      {:default, :text}
    ]
    @text_order [{:host, :text}, {:host, :markdown}, {:default, :text}, {:default, :markdown}]
    @body_parts [{:host, :html}, {:host, :markdown}, {:host, :text}] ++
                  [{:default, :html}, {:default, :markdown}, {:default, :text}]

    test "every combination of host and default parts picks by the order table",
         %{tmp_dir: root} do
      for mask <- 0..63 do
        present =
          for {entry, bit} <- Enum.with_index(@body_parts), (mask >>> bit &&& 1) == 1, do: entry

        name = "combo_#{mask}"

        for {:host, part} <- present do
          write(root, name, file_name(part), marker(:host, part))
        end

        defaults =
          Map.new(for({:default, part} <- present, do: {part, marker(:default, part)}))
          |> Map.put(:subject, "s")

        resolved =
          Content.resolve(name, user("en"), %{}, fn -> defaults end, paths: [root])

        available = fn {layer, part} ->
          {layer, part} in present and (layer == :host or {:host, part} not in present)
        end

        case Enum.find(@html_order, available) do
          nil -> assert resolved.html == nil, "mask #{mask}: #{inspect(present)}"
          {layer, part} -> assert resolved.html =~ marker(layer, part), "mask #{mask}"
        end

        case Enum.find(@text_order, available) do
          nil -> assert resolved.text == nil, "mask #{mask}: #{inspect(present)}"
          {layer, part} -> assert resolved.text =~ marker(layer, part), "mask #{mask}"
        end
      end
    end

    test "within the same layer html comes before markdown, markdown before text" do
      resolved =
        Content.resolve("order_probe", user("en"), %{}, fn ->
          %{subject: "s", html: "<p>h</p>", markdown: "m", text: "t"}
        end)

      assert resolved.html =~ "<p>h</p>"
      assert resolved.text == "t"
    end

    test "markdown that renders to nothing is no body" do
      resolved =
        Content.resolve("md_empty_probe", user("en"), %{}, fn ->
          %{subject: "s", markdown: "<div>raw only</div>"}
        end)

      assert %{html: nil, text: nil} = resolved
    end

    test "a host's markdown that renders to nothing gives way to the default text",
         %{tmp_dir: root} do
      write(root, "md_empty_host_probe", "markdown.md", "<div>pasted html</div>")

      {resolved, sources} =
        Content.resolve_with_sources("md_empty_host_probe", user("en"), %{}, text_only("default"),
          paths: [root]
        )

      assert resolved.text == "default"
      assert resolved.html =~ "default</p>"
      assert sources.text_from == :text
      assert sources.html_from == :text
    end

    test "a markdown file that is not UTF-8 still sends, as escaped text", %{tmp_dir: root} do
      write(root, "md_latin1_probe", "markdown.md", <<"Gr", 0xFC, "ß <b>{{name}}</b>"::binary>>)

      resolved =
        Content.resolve(
          "md_latin1_probe",
          user("en"),
          %{"name" => "Ada"},
          fn -> %{subject: "s"} end,
          paths: [root]
        )

      assert resolved.html =~ "<!DOCTYPE html>"
      assert resolved.html =~ "&lt;b&gt;Ada&lt;/b&gt;"
      assert resolved.text =~ "<b>Ada</b>"
    end

    test "an html part wins over markdown for the HTML body", %{tmp_dir: root} do
      write(root, "md_html_probe", "html.html", "<p>from html</p>")
      write(root, "md_html_probe", "markdown.md", "from markdown")

      resolved =
        Content.resolve("md_html_probe", user("en"), %{}, fn -> %{subject: "s"} end,
          paths: [root]
        )

      assert resolved.html =~ "<p>from html</p>"
      refute resolved.html =~ "from markdown"
      # No text part: the text body comes from the markdown.
      assert resolved.text == "from markdown"
    end

    test "a blank markdown file counts as no markdown", %{tmp_dir: root} do
      write(root, "md_blank_probe", "markdown.md", " \n")

      {resolved, sources} =
        Content.resolve_with_sources("md_blank_probe", user("en"), %{}, text_only("t"),
          paths: [root]
        )

      assert resolved.html =~ "t</p>"
      assert resolved.text == "t"
      assert sources.markdown == {:blank_file, Path.join([root, "md_blank_probe", "markdown.md"])}
      assert sources.html_from == :text
    end

    test "layout: false sends the markdown's HTML unwrapped", %{tmp_dir: root} do
      write(root, "md_off_probe", "markdown.md", "# Hi")

      resolved =
        Content.resolve("md_off_probe", user("en"), %{}, fn -> %{subject: "s"} end,
          paths: [root],
          layout: false
        )

      assert resolved.html == "<h1>Hi</h1>"
    end

    test "markdown from the caller's defaults works like a file" do
      resolved =
        Content.resolve(
          "md_default_probe",
          user("en"),
          %{"url" => "https://example.test/x"},
          fn -> %{subject: "s", markdown: "[Open]({{url}})"} end
        )

      assert resolved.html =~ ~s(<a href="https://example.test/x" style="display:inline-block;)
      assert resolved.text == "Open: https://example.test/x"
    end

    test "the result never carries the markdown or layout parts", %{tmp_dir: root} do
      write(root, "md_keys_probe", "markdown.md", "x")
      write(root, "md_keys_probe", "layout.txt", "billing")

      resolved =
        Content.resolve("md_keys_probe", user("en"), %{}, fn -> %{} end, paths: [root])

      assert resolved |> Map.keys() |> Enum.sort() == [:db_template, :html, :subject, :text]
    end
  end

  describe "resolve/5 and layout groups" do
    defp group_files(root) do
      write(root, "_layout", "html.html", "SHARED[{{{content}}}]")
      write(root, "_layout-billing", "html.html", "BILLING[{{{content}}}]")
      write(root, "_layout-shop", "html.html", "SHOP[{{{content}}}]")
    end

    test "layout.txt in the email's directory names its group", %{tmp_dir: root} do
      group_files(root)
      write(root, "invoice_probe", "layout.txt", "billing\n")

      assert Content.resolve("invoice_probe", user("en"), %{}, text_only("b"), paths: [root]).html =~
               ~r/\ABILLING\[/

      # Another email in the same roots keeps the shared layout.
      assert Content.resolve("other_probe", user("en"), %{}, text_only("b"), paths: [root]).html =~
               ~r/\ASHARED\[/
    end

    test "the layout: option wins over layout.txt", %{tmp_dir: root} do
      group_files(root)
      write(root, "invoice_probe", "layout.txt", "billing")

      {resolved, sources} =
        Content.resolve_with_sources("invoice_probe", user("en"), %{}, text_only("b"),
          paths: [root],
          layout: "shop"
        )

      assert resolved.html =~ ~r/\ASHOP\[/
      assert sources.group == "shop"
      assert sources.group_from == :option
    end

    test "a group named in the caller's defaults applies", %{tmp_dir: root} do
      group_files(root)

      {resolved, sources} =
        Content.resolve_with_sources(
          "invoice_default_probe",
          user("en"),
          %{},
          fn -> %{text: "b", layout: "billing"} end,
          paths: [root]
        )

      assert resolved.html =~ ~r/\ABILLING\[/
      assert sources.group_from == :default
    end

    test "an invalid group in layout.txt is ignored, with a warning", %{tmp_dir: root} do
      group_files(root)
      write(root, "bad_group_probe", "layout.txt", "../billing")

      log =
        capture_log(fn ->
          assert Content.resolve("bad_group_probe", user("en"), %{}, text_only("b"),
                   paths: [root]
                 ).html =~ ~r/\ASHARED\[/
        end)

      assert log =~ "not a valid group name"
    end

    test "layout: false wins over layout.txt", %{tmp_dir: root} do
      group_files(root)
      write(root, "invoice_probe", "layout.txt", "billing")

      assert Content.resolve("invoice_probe", user("en"), %{}, text_only("b"),
               paths: [root],
               layout: false
             ).html == nil
    end
  end

  describe "resolve/5 and branding" do
    test "logo_url and accent_color are bound in the body" do
      resolved =
        Content.resolve(
          "branding_probe",
          user("en"),
          %{},
          text_only("[{{logo_url}}] {{accent_color}}")
        )

      # No database here: no logo, the neutral accent colour.
      assert resolved.text == "[] #18181b"
    end

    test "a variable the caller passes under the same name wins, atom keys too" do
      resolved =
        Content.resolve(
          "branding_probe",
          user("en"),
          %{accent_color: "#00aa00"},
          fn -> %{subject: "s", markdown: "[Go](https://a.test)"} end
        )

      assert resolved.html =~ ~s(bgcolor="#00aa00")
      # No `email_accent_color` setting here: no bar, as in 2.43.
      refute resolved.html =~ "border-top:3px"
    end

    test "a caller's invalid logo_url or accent_color is replaced by the site's, in every part",
         %{tmp_dir: root} do
      write(
        root,
        "bad_branding_probe",
        "html.html",
        ~s(<p style="color:{{accent_color}};"><img src="{{logo_url}}">{{{accent_color}}}</p>)
      )

      write(root, "_footer", "html.html", ~s(<i style="color:{{accent_color}};">{{logo_url}}</i>))

      resolved =
        Content.resolve(
          "bad_branding_probe",
          user("en"),
          %{"accent_color" => "red;background:url(x)", logo_url: "javascript:alert(1)"},
          fn -> %{subject: "s", text: "[{{logo_url}}] {{accent_color}}"} end,
          paths: [root]
        )

      assert resolved.html =~ ~s(<p style="color:#18181b;"><img src="">#18181b</p>)
      assert resolved.html =~ ~s(<i style="color:#18181b;"></i>)
      refute resolved.html =~ "javascript"
      refute resolved.html =~ "url(x)"
      assert resolved.text == "[] #18181b"
    end

    test "a caller's valid logo_url and accent_color are kept" do
      resolved =
        Content.resolve(
          "good_branding_probe",
          user("en"),
          %{"accent_color" => " #00AA00 ", "logo_url" => "https://cdn.test/l.png"},
          fn -> %{subject: "s", text: "[{{logo_url}}] {{accent_color}}"} end
        )

      assert resolved.text == "[https://cdn.test/l.png] #00aa00"
      assert resolved.html =~ ~s(<img src="https://cdn.test/l.png")
    end
  end

  describe "resolve_with_sources/5" do
    test "names the file, the default and the absent part", %{tmp_dir: root} do
      write(root, "register", "text.de.txt", "Text")
      write(root, "_header", "html.html", "<b>H</b>")

      {resolved, sources} =
        Content.resolve_with_sources("register", user("de"), %{}, defaults(), paths: [root])

      assert resolved == Content.resolve("register", user("de"), %{}, defaults(), paths: [root])

      assert sources == %{
               subject: :default,
               text: {:file, Path.join([root, "register", "text.de.txt"])},
               html: nil,
               markdown: nil,
               html_from: :text,
               text_from: :text,
               group: nil,
               group_from: nil,
               layout: :default,
               header: {:file, Path.join([root, "_header", "html.html"])},
               footer: :default,
               ignored: []
             }
    end

    test "says the text came from markdown and the group from layout.txt", %{tmp_dir: root} do
      write(root, "src_probe", "markdown.md", "Hi")
      write(root, "src_probe", "layout.txt", "billing")
      write(root, "_layout-billing", "html.html", "<main>{{{content}}}</main>")

      {_resolved, sources} =
        Content.resolve_with_sources("src_probe", user("en"), %{}, fn -> %{subject: "s"} end,
          paths: [root]
        )

      assert sources.markdown == {:file, Path.join([root, "src_probe", "markdown.md"])}
      assert sources.html_from == :markdown
      assert sources.text_from == :markdown
      assert sources.group == "billing"
      assert sources.group_from == {:file, Path.join([root, "src_probe", "layout.txt"])}
      assert sources.layout == {:file, Path.join([root, "_layout-billing", "html.html"])}
      # This layout places no header or footer.
      assert sources.header == nil
      assert sources.footer == nil
    end

    test "a blank file is told apart from the default it suppresses", %{tmp_dir: root} do
      write(root, "register", "text.txt", "")

      {resolved, sources} =
        Content.resolve_with_sources("register", user("de"), %{}, defaults(), paths: [root])

      assert resolved.text == nil
      assert sources.text == {:blank_file, Path.join([root, "register", "text.txt"])}
      assert sources.text_from == nil
    end

    test "layout: false reports no chrome" do
      {_resolved, sources} =
        Content.resolve_with_sources("register", user("de"), %{}, defaults(), layout: false)

      assert %{layout: nil, header: nil, footer: nil, html_from: nil} = sources
    end
  end

  describe "subject from a file" do
    test "the newline at the end of a subject file is not part of the subject",
         %{tmp_dir: root} do
      write(root, "register", "subject.txt", "Welcome aboard\r\n")

      assert Content.resolve("register", user("de"), %{}, defaults(), paths: [root]).subject ==
               "Welcome aboard"
    end
  end

  describe "override_paths/0" do
    test "always answers with a list" do
      # An unloaded parent application is the normal state inside a mix task,
      # where "no overrides" is the right answer and a crash is not.
      assert is_list(Content.override_paths())
    end
  end
end
