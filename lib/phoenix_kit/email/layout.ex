defmodule PhoenixKit.Email.Layout do
  @moduledoc """
  The shared HTML layout every email built from a file or a default is wrapped in.

  `PhoenixKit.Email.Content.resolve/5` calls `render/3` on the file/default
  path, so an email reaches the reader as HTML even when all it has is text:
  core's auth emails and the defaults a module passes to
  `PhoenixKit.Mailer.send_from_template/4` ship no `html` part of their own.
  Content from a database template is never wrapped — it carries its own
  chrome.

  ## Three parts: layout, header, footer

  The layout is the document around the body; the header and footer are
  rendered on their own and handed to it, so a host can replace just the
  header without copying the rest:

      <host>/priv/phoenix_kit_templates/
      ├── _layout/html.html      <- the document; must place {{{content}}}
      ├── _header/html.html      <- placed as {{{header}}}
      └── _footer/html.html      <- placed as {{{footer}}}

  Each is resolved like any other template (`PhoenixKit.Templates`): the
  message's own locale and override roots, `html.de.html` before `html.html`.
  Only the `html` part is read, and only the variables below are bound — not
  the message's own, since every email shares these parts.

  `render_parts/2` renders the header and footer alone, chosen the same way,
  for a caller that builds its own document around them.

  An empty or whitespace-only `_header`/`_footer` file counts as missing.
  Neither needs a placeholder. A `_layout` with no `content` placeholder (an
  empty file, a typo such as `{{{contnet}}}`) would drop the body of every
  email, so it is refused and the next layout in line is used; a warning is
  logged once per layout name, override roots and locale for the life of the
  VM.

  ## Groups

  A group of emails can have chrome of its own: `_layout-<group>`,
  `_header-<group>`, `_footer-<group>`. Each falls back on its own — to the
  shared `_layout`/`_header`/`_footer`, then to core's — so a `billing` group
  may replace only its footer. The group is the `:group` option here;
  `Content.resolve/5` takes it from `layout: "<group>"` or from the email's
  own `layout.txt`. A group name is `[a-z0-9-]+`; any other is ignored, with a
  warning.

  ## Core's defaults

  `default_html/1`, `default_header_html/1` and `default_footer_html/1` are
  core's own parts, kept in code for the same reason the message defaults are
  Gettext calls rather than files: core ships no files of its own. They are
  deliberately neutral — table markup with inline styles, no external
  resources but the site's own logo — and carry **no words of their own**,
  so they need no translation.

    * The header shows the logo (`{{logo_url}}`, from Settings) when there is
      one, else the site's name.
    * The footer shows the site's name and a link to the site.
    * The layout is a card with the header, the body and the footer, and a
      thin bar in the accent colour on top once the `email_accent_color`
      setting holds a colour.

  ## Variables

  Every part sees:

  | placeholder | value |
  |---|---|
  | `{{subject}}` | the message subject, for `<title>` |
  | `{{site_name}}` | `PhoenixKit.Settings.get_project_title/0` |
  | `{{site_url}}` | `PhoenixKit.Utils.Routes.base_url/0` |
  | `{{logo_url}}` | `PhoenixKit.Email.Branding` — `""` without a logo |
  | `{{accent_color}}` | `PhoenixKit.Email.Branding` — `#rrggbb` |

  and the layout also:

  | placeholder | value |
  |---|---|
  | `{{{content}}}` | the message body, **already HTML** |
  | `{{{header}}}` | the rendered header, **already HTML** |
  | `{{{footer}}}` | the rendered footer, **already HTML** |

  `site_url` is whatever the site is configured with. Core's footer links it
  only when it is an `http(s)://` address and prints it as text otherwise.

  `content`, `header` and `footer` must be written with **three** braces.
  The `html` part escapes every `{{variable}}`, which is right for `subject`
  and the site's name but would print the body's markup as visible text.
  Triple braces are the escaping opt-out, and these values are safe to insert
  raw because they were escaped when they were built.

  ## Opting out

  `layout: false` to `Content.resolve/5` or `Mailer.send_from_template/4`
  leaves the message exactly as resolved. An `html` part that is already a
  whole document is never wrapped either — an export of an old database
  template is one. It is a document when, after any byte-order mark,
  whitespace, `<!-- comments -->` and `<?xml … ?>` prolog, it starts with
  `<!doctype` or an `<html` tag (`<html>`, `<html lang="…">`), in any case.
  """

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Email.Content
  alias PhoenixKit.Settings
  alias PhoenixKit.Templates.Overrides
  alias PhoenixKit.Templates.Substitution
  alias PhoenixKit.Utils.Routes

  require Logger

  @name "_layout"
  @header "_header"
  @footer "_footer"

  @group_pattern ~r/\A[a-z0-9-]+\z/

  @font "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

  # Longer than any address a reader would click; left as text, which also
  # bounds the work a pathological value can cause.
  @max_link_bytes 2048

  # Sentence punctuation that ends a sentence rather than an address.
  @trailing ~c".,;:!?'\""

  @typedoc "Where one part of the chrome came from: a host file, or core's own."
  @type source :: {:file, Path.t()} | :default

  @typedoc """
  Where the layout, header and footer of one render came from. `header` and
  `footer` are `nil` when the layout used does not place them. `ignored`
  lists the files that were found but passed over: `{:blank_file, path}` for
  an empty header or footer, `{:no_content, path}` for a layout that does not
  place `{{{content}}}`.
  """
  @type sources :: %{
          layout: source(),
          header: source() | nil,
          footer: source() | nil,
          ignored: [{:blank_file | :no_content, Path.t()}]
        }

  @typedoc """
  The header and footer of one message, rendered on their own (see
  `render_parts/2`).

    * `header`, `footer` — **already HTML**, to be placed with three braces.
    * `variables` — the variables the parts were rendered with (see
      "Variables" above, without `content`/`header`/`footer`), for a caller
      whose own wrapper names `{{site_name}}`, `{{accent_color}}` and the like.
      These are **raw text, not HTML**: `subject`, `site_name`, `site_url`
      and `logo_url` are not escaped. Place them with two braces and
      substitute with `escape: true`; only `header` and `footer` take three.
      Any other key of a caller's `:branding` map is carried through as given
      (`render/3` places it in the layout the same way); `subject`,
      `site_name` and `site_url` always win over a key of the same name.
    * `sources` — where each part came from (`{:file, path}` or `:default`),
      and under `ignored` the files passed over on the way
      (`{:blank_file, path}` for an empty one).
  """
  @type parts :: %{
          header: String.t(),
          footer: String.t(),
          variables: %{String.t() => term()},
          sources: %{
            header: source(),
            footer: source(),
            ignored: [{:blank_file, Path.t()}]
          }
        }

  @doc "The reserved template name the layout resolves under."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The reserved template name the header resolves under."
  @spec header_name() :: String.t()
  def header_name, do: @header

  @doc "The reserved template name the footer resolves under."
  @spec footer_name() :: String.t()
  def footer_name, do: @footer

  @doc """
  Whether `group` is a usable group name: `[a-z0-9-]+`.
  """
  @spec valid_group?(term()) :: boolean()
  def valid_group?(group), do: is_binary(group) and Regex.match?(@group_pattern, group)

  @doc """
  Core's layout: a card with the header, the body and the footer — and a bar
  in the accent colour on top when the site has chosen one.

  ## Options

    * `:locale` — becomes the document's `lang` attribute when it is a
      well-formed language tag (`pt_BR` is written `pt-BR`); omitted
      otherwise.
    * `:accent_bar` — `true` draws a 3px bar in `{{accent_color}}` on top
      of the card. Default `false`.
  """
  @spec default_html(keyword()) :: String.t()
  def default_html(opts \\ []) do
    lang = lang_attribute(Keyword.get(opts, :locale))

    bar =
      if Keyword.get(opts, :accent_bar, false),
        do: "border-top:3px solid {{accent_color}};",
        else: ""

    """
    <!DOCTYPE html>
    <html#{lang}>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{subject}}</title>
    </head>
    <body style="margin:0;padding:0;background-color:#f4f4f5;" bgcolor="#f4f4f5">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#f4f4f5" style="background-color:#f4f4f5;">
    <tr>
    <td align="center" bgcolor="#f4f4f5" style="padding:24px 12px;background-color:#f4f4f5;">
    <!--[if mso]><table role="presentation" width="600" align="center" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" bgcolor="#ffffff" style="width:100%;max-width:600px;background-color:#ffffff;border:1px solid #e4e4e7;#{bar}">
    <tr>
    <td style="padding:20px 32px;border-bottom:1px solid #e4e4e7;font-family:#{@font};font-size:18px;font-weight:bold;color:#18181b;">{{{header}}}</td>
    </tr>
    <tr>
    <td style="padding:24px 32px;font-family:#{@font};font-size:15px;line-height:1.6;color:#27272a;">
    {{{content}}}
    </td>
    </tr>
    <tr>
    <td style="padding:16px 32px;border-top:1px solid #e4e4e7;font-family:#{@font};font-size:12px;line-height:1.5;color:#71717a;">{{{footer}}}</td>
    </tr>
    </table>
    <!--[if mso]></td></tr></table><![endif]-->
    </td>
    </tr>
    </table>
    </body>
    </html>
    """
  end

  @doc """
  Core's header: the logo when there is one, else the site's name.

  ## Options

    * `:logo` — `true` when `{{logo_url}}` is set. Default `false`.
  """
  @spec default_header_html(keyword()) :: String.t()
  def default_header_html(opts \\ []) do
    if Keyword.get(opts, :logo, false),
      do:
        ~s(<img src="{{logo_url}}" alt="{{site_name}}" height="40" ) <>
          ~s(style="display:block;height:40px;width:auto;max-width:100%;border:0;">),
      else: "{{site_name}}"
  end

  @doc """
  Core's footer: the site's name and a link to the site.

  ## Options

    * `:link` — `false` prints `{{site_url}}` as text instead of a link.
      Default `true`.
  """
  @spec default_footer_html(keyword()) :: String.t()
  def default_footer_html(opts \\ []) do
    site =
      if Keyword.get(opts, :link, true),
        do: ~s(<a href="{{site_url}}" style="color:#71717a;">{{site_url}}</a>),
        else: "{{site_url}}"

    "{{site_name}}<br>" <> site
  end

  @doc """
  Plain text as an HTML fragment.

  Every character of `text` is escaped. A blank line separates paragraphs,
  each a `<p>`; a single line break becomes `<br>`. An `http://` or `https://`
  address becomes a link. It ends at `<`, `>`, `"`, any Unicode whitespace or
  separator, any invisible format character (zero-width spaces and joiners,
  the soft hyphen, the byte-order mark, bidirectional controls — which could
  otherwise make a link display a different address from the one it opens),
  guillemets, the em dash and the punctuation after it up to the ellipsis
  (U+2014–U+2027: typographic quotes, `…` and the like), and CJK/fullwidth
  punctuation. Hyphens and the en dash do not end it, since real addresses
  carry them. Trailing sentence punctuation and unbalanced closing
  parentheses stay outside it. No other scheme becomes a link, so
  `javascript:` and friends remain text, and neither does an address longer
  than #{@max_link_bytes} bytes.
  """
  @spec text_to_html(String.t()) :: String.t()
  def text_to_html(text) when is_binary(text) do
    text
    |> String.replace(["\r\n", "\r"], "\n")
    |> String.split(~r/\n[ \t]*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("\n", fn paragraph ->
      lines = paragraph |> String.split("\n") |> Enum.map_join("<br>\n", &linkify/1)
      ~s(<p style="margin:0 0 16px;">) <> lines <> "</p>"
    end)
  end

  @doc """
  Wraps an HTML fragment in the layout for this message's locale.

  `subject` may be `nil`. See `render/3` for the options.
  """
  @spec wrap(String.t(), String.t() | nil, keyword()) :: String.t()
  def wrap(content, subject, opts \\ []) when is_binary(content) do
    content |> render(subject, opts) |> elem(0)
  end

  @doc """
  Wraps an HTML fragment in the layout, and says where the layout, header
  and footer came from.

  ## Options

    * `:locale`, `:paths` — the message's own, so the chrome resolves from
      the same override roots and for the same reader as the message.
    * `:group` — the email's group (see "Groups" above); `nil` for none.
    * `:branding` — the `logo_url`/`accent_color` variables, when the caller
      has already read them (an invalid value reads as no logo / the neutral
      colour); read from `PhoenixKit.Email.Branding` otherwise.
    * `:accent_bar` — whether core's layout draws its accent bar. Defaults
      to whether the `email_accent_color` setting holds a colour, so a site
      that never chose one looks as it did before the bar existed.
  """
  @spec render(String.t(), String.t() | nil, keyword()) :: {String.t(), sources()}
  def render(content, subject, opts \\ []) when is_binary(content) do
    options = options(opts)
    parts = parts(subject, options, opts)

    accent_bar? =
      Keyword.get_lazy(opts, :accent_bar, fn -> Branding.configured_accent_color() != nil end)

    {layout, layout_source, layout_ignored} =
      layout(options.group, options.locale, options.paths, accent_bar?)

    placed = Substitution.variables(layout)

    variables =
      Map.merge(parts.variables, %{
        "content" => content,
        "header" => parts.header,
        "footer" => parts.footer
      })

    sources = %{
      layout: layout_source,
      header: if("header" in placed, do: parts.sources.header),
      footer: if("footer" in placed, do: parts.sources.footer),
      ignored: layout_ignored ++ parts.sources.ignored
    }

    {Substitution.substitute(layout, variables, escape: true), sources}
  end

  @doc """
  The header and footer for a message, rendered on their own, without the
  layout around them.

  For a caller that builds its own document but wants the site's chrome in
  it — a newsletter's wrapper, say, placing `{{{header}}}` and `{{{footer}}}`
  around its own body. The parts are chosen exactly as `render/3` chooses
  them — both use the same private resolution: per group, locale and
  override root, an empty file counting as missing, core's own part last
  (see "Groups" and "Core's defaults" above).

  Takes `render/3`'s `:locale`, `:paths`, `:group` and `:branding` options;
  `subject` may be `nil`. One default differs: without `:paths` (or with
  `paths: nil`) the host's override roots are read,
  `PhoenixKit.Email.Content.override_paths/0` — the same roots
  `PhoenixKit.Email.Content.resolve/5` reads — so a caller gets the host's
  `_header`/`_footer` files without naming them. Pass `paths: []` for core's
  parts only. Returns `t:parts/0`:

      parts = Layout.render_parts(subject, locale: "de", group: "newsletters")

      variables =
        Map.merge(parts.variables, %{
          "header" => parts.header,
          "footer" => parts.footer,
          "content" => body_html
        })

      Substitution.substitute(wrapper, variables, escape: true)

  `header` and `footer` are HTML: place them with three braces. Everything
  in `variables` is raw text: place it with two braces, under `escape: true`.
  """
  @spec render_parts(String.t() | nil, keyword()) :: parts()
  def render_parts(subject, opts \\ []) do
    opts = Keyword.put(opts, :paths, Keyword.get(opts, :paths) || Content.override_paths())
    parts(subject, options(opts), opts)
  end

  # The options both `render/3` and `render_parts/2` read, normalised once so
  # an invalid group is warned about once per render.
  defp options(opts) do
    %{
      locale: Keyword.get(opts, :locale),
      paths: Keyword.get(opts, :paths) || [],
      group: group(Keyword.get(opts, :group))
    }
  end

  defp parts(subject, %{locale: locale, paths: paths, group: group}, opts) do
    site_url = Routes.base_url()

    # A caller's branding is checked like any other: only a `#rrggbb` colour
    # reaches a `style` attribute, only an http(s) address a `src`.
    branding =
      case Keyword.fetch(opts, :branding) do
        {:ok, branding} ->
          Branding.merge(branding, %{
            "logo_url" => "",
            "accent_color" => Branding.default_accent_color()
          })

        :error ->
          Branding.variables()
      end

    variables =
      Map.merge(branding, %{
        "subject" => subject || "",
        "site_name" => Settings.get_project_title(),
        "site_url" => site_url
      })

    logo? = present?(Map.get(variables, "logo_url"))
    found = &chrome(&1, group, &2, variables, locale, paths)
    {header, header_source, header_ignored} = found.(@header, default_header_html(logo: logo?))

    {footer, footer_source, footer_ignored} =
      found.(@footer, default_footer_html(link: http_url?(site_url)))

    %{
      header: header,
      footer: footer,
      variables: variables,
      sources: %{
        header: header_source,
        footer: footer_source,
        ignored: header_ignored ++ footer_ignored
      }
    }
  end

  @doc """
  Whether `html` is a whole document rather than a fragment to wrap.

  Leading byte-order marks, whitespace (non-breaking included), comments and
  an XML prolog are skipped before looking for `<!doctype` or `<html`.
  """
  @spec document?(String.t()) :: boolean()
  def document?(html) when is_binary(html) do
    Regex.match?(~r/\A<(!doctype|html[\s>])/i, skip_preamble(html))
  end

  # A header or footer: the group's file, the shared file, core's default —
  # the first that has something in it.
  defp chrome(base, group, default, variables, locale, paths) do
    {found, ignored} =
      first_file(names(base, group), locale, paths, fn _name, content ->
        if present?(content), do: :ok, else: :blank_file
      end)

    {template, source} = found || {default, :default}
    {Substitution.substitute(template, variables, escape: true), source, ignored}
  end

  # The layout: the group's file, the shared file, core's default — the first
  # that places the body. The check reads the same file the render uses.
  defp layout(group, locale, paths, accent_bar?) do
    {found, ignored} =
      first_file(names(@name, group), locale, paths, fn name, content ->
        if "content" in Substitution.variables(content) do
          :ok
        else
          warn_once_without_content(name, paths, locale)
          :no_content
        end
      end)

    {template, source} =
      found || {default_html(locale: locale, accent_bar: accent_bar?), :default}

    {template, source, ignored}
  end

  # The first of `names` whose file `usable` accepts, and the files passed
  # over on the way, each with the reason `usable` gave.
  defp first_file(names, locale, paths, usable) do
    {found, ignored} =
      Enum.reduce_while(names, {nil, []}, fn name, {nil, ignored} ->
        case Overrides.locate(paths, name, :html, locale) do
          nil ->
            {:cont, {nil, ignored}}

          {path, content} ->
            case usable.(name, content) do
              :ok -> {:halt, {{content, {:file, path}}, ignored}}
              reason -> {:cont, {nil, [{reason, path} | ignored]}}
            end
        end
      end)

    {found, Enum.reverse(ignored)}
  end

  defp names(base, nil), do: [base]
  defp names(base, group), do: [base <> "-" <> group, base]

  defp group(group) when is_binary(group) do
    if valid_group?(group) do
      group
    else
      Logger.warning(
        "Email layout group #{inspect(group)} is not a valid group name ([a-z0-9-]+); " <>
          "using the shared layout"
      )

      nil
    end
  end

  defp group(_none), do: nil

  defp present?(part), do: is_binary(part) and String.trim(part) != ""

  defp skip_preamble(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: skip_preamble(rest)
  defp skip_preamble("<!--" <> rest), do: rest |> after_marker("-->") |> skip_preamble()
  defp skip_preamble("<?" <> rest), do: rest |> after_marker("?>") |> skip_preamble()

  defp skip_preamble(html) do
    case String.trim_leading(html) do
      ^html -> html
      trimmed -> skip_preamble(trimmed)
    end
  end

  defp after_marker(rest, marker) do
    case :binary.split(rest, marker) do
      [_skipped, after_it] -> after_it
      [_unterminated] -> ""
    end
  end

  # The layout is resolved on every send, so a broken one would log on every
  # send. One warning per (name, roots, locale) is enough to be seen; the keys
  # are bounded by the layout names on disk times the configured roots times
  # the well-formed language tags.
  defp warn_once_without_content(name, paths, locale) do
    key = {__MODULE__, :warned_without_content, name, paths, language_tag(locale)}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "Email layout #{name}/html for locale #{inspect(locale)} in #{inspect(paths)} " <>
          "has no {{{content}}} placeholder; using the next layout in line instead"
      )
    end
  end

  defp lang_attribute(locale) do
    case language_tag(locale) do
      nil -> ""
      tag -> ~s( lang="#{escape(tag)}")
    end
  end

  # A locale as an HTML language tag: `pt_BR` is written `pt-BR`. Anything that
  # is not a well-formed tag is no tag at all.
  defp language_tag(locale) when is_binary(locale) do
    tag = String.replace(locale, "_", "-")
    if Regex.match?(~r/\A[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8}){0,3}\z/, tag), do: tag
  end

  defp language_tag(_locale), do: nil

  defp http_url?(url), do: Regex.match?(~r{\Ahttps?://[^\s]}i, url)

  # Escapes a line, turning each http(s) address in it into a link. Splitting
  # with the matches kept alternates text and address, so odd positions are
  # always addresses. A line that is not valid UTF-8 cannot be scanned as
  # Unicode and is escaped whole.
  defp linkify(line) do
    if String.valid?(line) do
      ~r/https?:\/\/[^\s\p{Z}\p{Cf}<>"\x{00AB}\x{00BB}\x{2014}-\x{2027}\x{3000}-\x{303F}\x{FF01}-\x{FF65}]+/iu
      |> Regex.split(line, include_captures: true)
      |> Enum.with_index()
      |> Enum.map_join(fn
        {text, index} when rem(index, 2) == 0 -> escape(text)
        {url, _index} -> link(url)
      end)
    else
      escape(line)
    end
  end

  defp link(url) do
    {href, trailing} = split_trailing(url)

    if byte_size(href) <= @max_link_bytes and http_url?(href) do
      ~s(<a href="#{escape(href)}">#{escape(href)}</a>) <> escape(trailing)
    else
      escape(url)
    end
  end

  # "Visit https://example.com." links the address, not the full stop. A
  # closing parenthesis stays when the address opened one itself, as in a
  # Wikipedia URL. One pass from the end over bytes — the characters it strips
  # are all ASCII, which never occurs inside a multi-byte UTF-8 sequence — with
  # the parentheses counted once, so its cost is linear in the address.
  defp split_trailing(url) do
    opens = count(url, "(")
    closes = count(url, ")")
    keep = keep_bytes(url, byte_size(url), opens, closes)

    {binary_part(url, 0, keep), binary_part(url, keep, byte_size(url) - keep)}
  end

  defp keep_bytes(_url, 0, _opens, _closes), do: 0

  defp keep_bytes(url, size, opens, closes) do
    case :binary.at(url, size - 1) do
      char when char in @trailing -> keep_bytes(url, size - 1, opens, closes)
      ?) when closes > opens -> keep_bytes(url, size - 1, opens, closes - 1)
      _other -> size
    end
  end

  defp count(string, pattern), do: length(:binary.matches(string, pattern))

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
