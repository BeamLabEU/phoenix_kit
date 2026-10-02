defmodule PhoenixKit.Email.Markdown do
  @moduledoc """
  An email body written in Markdown, as HTML and as plain text.

  `PhoenixKit.Email.Content.resolve/5` uses this for a `markdown` part
  (`markdown[.<locale>].md`): the HTML body comes from it when the message has
  no `html` part, and the text body when it has no `text` part.

  ## Placeholders

  `{{variable}}` and `{{{variable}}}` work as in an `html` part: two braces
  escape the value, three insert it raw. They are substituted **after** the
  Markdown is rendered — a renderer percent-encodes `{{url}}` in a link
  target, so a value substituted before it would arrive as `%7B%7Burl%7D%7D`,
  and a value rendered as Markdown could change the markup around it. Each
  placeholder is swapped for an opaque token, the Markdown is rendered and
  sanitized (`PhoenixKit.Utils.HtmlSanitizer`), the placeholders are put back
  and substituted with `PhoenixKit.Templates.Substitution`.

  ## Links and buttons

  Every link and image is built here rather than by the renderer, so its
  address is known after substitution:

    * The address is the link target with its placeholders filled in, raw or
      not — inside an attribute both spellings are escaped as an attribute
      value.
    * Only an `http://`, `https://` or `mailto:` address (images: `http(s)`
      only) is kept. Anything else — `javascript:`, a relative path, a
      placeholder nothing bound — drops the link and keeps its label as text.
    * A paragraph that is exactly one `[label](url)` link becomes a button: a
      table cell in the accent colour, which renders the same in every email
      client. A bare address on its own line stays a link.
    * Other links are coloured with the accent colour.

  The accent colour is the `accent_color` variable, checked by
  `PhoenixKit.Email.Branding.normalize_color/1`.

  ## A paragraph that is only placeholders

  A top-level paragraph of plain text whose placeholders all fill in blank —
  `{{failed_attempts}}` on its own line, with nothing to report — is left
  out of both bodies, rather than sent as an empty paragraph. A value that
  is a sentence ending in a blank line, written as its own paragraph, stays
  its own paragraph.

  A paragraph that is exactly one `{{{variable}}}` is the value alone, with
  no `<p>` around it — the way to place a block of HTML a caller built (a
  table of invoice lines) between Markdown paragraphs. The text body
  substitutes it as is, so a caller that passes HTML that way gives the
  email a `text` part of its own.

  ## Raw HTML

  HTML written inside the Markdown is not rendered: a placeholder inside an
  attribute of it could not be checked like a link target. A body that needs
  markup of its own belongs in an `html` part.
  """

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Email.Layout
  alias PhoenixKit.Templates.Substitution
  alias PhoenixKit.Utils.HtmlSanitizer

  @mdex_options [
    extension: [strikethrough: true, table: true, autolink: true],
    parse: [smart: true],
    render: [unsafe: false]
  ]

  # The placeholder grammar of `PhoenixKit.Templates.Substitution`: triple and
  # double braces, one pass. Linear — no nested quantifiers.
  @placeholder ~r/\{\{\{\s*[a-zA-Z_][a-zA-Z0-9_]*\s*\}\}\}|\{\{\s*[a-zA-Z_][a-zA-Z0-9_]*\s*\}\}/

  @font "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

  @paragraph ~s(<p style="margin:0 0 16px;">)

  @doc """
  `markdown` as a sanitized HTML fragment with `variables` substituted.
  """
  @spec to_html(String.t(), Substitution.variables()) :: String.t()
  def to_html(markdown, variables) when is_binary(markdown) do
    if String.valid?(markdown),
      do: render_html(markdown, variables),
      else: fallback_html(markdown, variables)
  end

  defp render_html(markdown, variables) do
    accent = variables |> fetch("accent_color") |> Branding.normalize_color()
    {protected, tokens} = protect(markdown)

    case MDEx.parse_document(protected, @mdex_options) do
      {:ok, document} ->
        document = drop_blank_paragraphs(document, tokens, variables)
        {document, extracted} = extract(document, %{nonce: tokens.nonce, elements: [], count: 0})

        html =
          document
          |> MDEx.to_html!(@mdex_options)
          |> HtmlSanitizer.sanitize()

        {elements, attributes} = place(extracted.elements, tokens, variables)

        html
        |> assemble(tokens.nonce, elements, accent)
        |> unwrap_raw_paragraphs(tokens)
        |> String.replace("<p>", @paragraph)
        |> restore(tokens)
        |> Substitution.substitute(variables, escape: true)
        |> restore_attributes(tokens.nonce, attributes)

      {:error, _reason} ->
        fallback_html(markdown, variables)
    end
  end

  # Content MDEx cannot take (it raises on invalid UTF-8) is sent as escaped
  # text rather than failing the send.
  defp fallback_html(markdown, variables),
    do: markdown |> Substitution.substitute(variables) |> Layout.text_to_html()

  @doc """
  `markdown` as plain text with `variables` substituted.

  Headings and paragraphs are lines separated by a blank line, list items
  start with `- ` (`1. ` when numbered), `[label](url)` becomes
  `label: url` — just `url` when the label is the address itself, as in
  `[{{url}}]({{url}})` — an image becomes its alt text, and emphasis, code
  and raw HTML marks are dropped. A value that ends in blank lines never
  leaves more than one blank line in a row.
  """
  @spec to_text(String.t(), Substitution.variables()) :: String.t()
  def to_text(markdown, variables) when is_binary(markdown) do
    if String.valid?(markdown),
      do: render_text(markdown, variables),
      else: markdown |> String.trim() |> Substitution.substitute(variables)
  end

  defp render_text(markdown, variables) do
    {protected, tokens} = protect(markdown)

    case MDEx.parse_document(protected, @mdex_options) do
      {:ok, document} ->
        document = drop_blank_paragraphs(document, tokens, variables)
        {document, {urls, _count}} = text_urls(document, {%{}, 0}, tokens, variables)

        document.nodes
        |> blocks_text()
        |> String.trim()
        |> restore(tokens)
        |> Substitution.substitute(variables)
        |> restore_attributes(tokens.nonce, urls)
        |> collapse_blank_lines()

      {:error, _reason} ->
        markdown |> String.trim() |> Substitution.substitute(variables)
    end
  end

  ## Placeholders

  # Each placeholder becomes `0pk<nonce>x<i>x`: letters and digits only, so no
  # Markdown construct, no percent-encoding and no sanitizer touches it, and
  # the renderer sees an ordinary word — in an email address it is part of the
  # address, so `{{user}}@example.com` is linked like any other. The leading
  # digit keeps `<{{url}}>` from reading as an HTML tag (a tag name starts with
  # a letter), which would drop it. The nonce is random and absent from the
  # source, so a token can only be one this render minted; the closing `x`
  # keeps token 1 from matching inside token 12, and hex digits never contain
  # an `x`, `y` or `z`.
  defp protect(markdown) do
    nonce = nonce(markdown)

    {pieces, placeholders} =
      @placeholder
      |> Regex.split(markdown, include_captures: true)
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn
        {text, index}, acc when rem(index, 2) == 0 ->
          {text, acc}

        {placeholder, index}, acc ->
          token = "0pk#{nonce}x#{index}x"
          {token, Map.put(acc, token, placeholder)}
      end)

    tokens = %{
      nonce: nonce,
      placeholders: placeholders,
      # Compiled once per render: every restore is then one linear pass.
      pattern: Regex.compile!("0pk#{nonce}x[0-9]+x")
    }

    {IO.iodata_to_binary(pieces), tokens}
  end

  defp nonce(source) do
    nonce = 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    if String.contains?(source, "pk" <> nonce), do: nonce(source), else: nonce
  end

  # A paragraph that is exactly one `{{{raw}}}` placeholder holds a block of
  # HTML (a table), and a block inside `<p>` is split by every parser into an
  # empty paragraph, the block and a stray `</p>`. Such a paragraph is the
  # value alone, the way a button replaces its paragraph.
  defp unwrap_raw_paragraphs(html, %{placeholders: placeholders})
       when map_size(placeholders) == 0,
       do: html

  defp unwrap_raw_paragraphs(html, %{nonce: nonce, placeholders: placeholders}) do
    "<p>(0pk#{nonce}x[0-9]+x)</p>"
    |> Regex.compile!()
    |> Regex.replace(html, fn paragraph, token ->
      if String.starts_with?(Map.get(placeholders, token, ""), "{{{"),
        do: token,
        else: paragraph
    end)
  end

  # Puts the placeholders back, in one pass.
  defp restore(string, %{placeholders: placeholders}) when map_size(placeholders) == 0,
    do: string

  defp restore(string, %{placeholders: placeholders, pattern: pattern}),
    do: Regex.replace(pattern, string, &Map.get(placeholders, &1, &1))

  # Puts the attribute values (`pk<nonce>y<i>z`/`…a`, or the text body's
  # `pk<nonce>z<i>z`) in, in one pass.
  defp restore_attributes(string, _nonce, attributes) when map_size(attributes) == 0,
    do: string

  defp restore_attributes(string, nonce, attributes) do
    "pk#{nonce}(?:y[0-9]+[za]|z[0-9]+z)"
    |> Regex.compile!()
    |> Regex.replace(string, &Map.get(attributes, &1, &1))
  end

  ## Links, buttons and images

  # Links and images leave the document as marker tokens — `pk<nonce>y<i>o`
  # before the label and `pk<nonce>y<i>c` after it, or one `pk<nonce>y<i>i`
  # for an image — and are built after sanitizing, once their address is
  # known. The label stays in the document, so it is rendered and sanitized
  # with everything else.
  #
  # Only a top-level paragraph that is exactly one link is a button: a link
  # alone in a list item or a quote stays a link.
  defp extract(%MDEx.Document{} = document, acc) do
    {nodes, acc} = Enum.map_reduce(document.nodes, acc, &extract_block/2)
    {%{document | nodes: List.flatten(nodes)}, acc}
  end

  defp extract(%MDEx.Link{} = link, acc) do
    {label, acc} = extract_list(link.nodes, acc)
    {open, close, acc} = add_element(acc, {:link, link.url})
    {[text(open)] ++ label ++ [text(close)], acc}
  end

  defp extract(%MDEx.Image{} = image, acc) do
    {marker, _close, acc} = add_element(acc, {:image, image.url, inline_text(image.nodes)})
    {text(marker), acc}
  end

  defp extract(%{nodes: nodes} = node, acc) when is_list(nodes), do: extract_children(node, acc)
  defp extract(node, acc), do: {node, acc}

  defp extract_block(%MDEx.Paragraph{nodes: [%MDEx.Link{} = link]} = paragraph, acc) do
    if autolink?(link) do
      extract_children(paragraph, acc)
    else
      {label, acc} = extract_list(link.nodes, acc)
      {open, close, acc} = add_element(acc, {:button, link.url})
      {%{paragraph | nodes: [text(open)] ++ label ++ [text(close)]}, acc}
    end
  end

  defp extract_block(node, acc), do: extract(node, acc)

  defp extract_children(node, acc) do
    {nodes, acc} = extract_list(node.nodes, acc)
    {%{node | nodes: nodes}, acc}
  end

  defp extract_list(nodes, acc) do
    {nodes, acc} = Enum.map_reduce(nodes, acc, &extract/2)
    {List.flatten(nodes), acc}
  end

  defp add_element(acc, element) do
    prefix = "pk#{acc.nonce}y#{acc.count}"
    marker = if elem(element, 0) == :image, do: prefix <> "i", else: prefix <> "o"

    {marker, prefix <> "c",
     %{acc | elements: [{acc.count, element} | acc.elements], count: acc.count + 1}}
  end

  defp text(literal), do: %MDEx.Text{literal: literal}

  # `<https://a.test>` or a bare address the autolink extension found
  # (`www.a.test` gains `http://`, `a@b.test` gains `mailto:`): the label is
  # the address itself. A line holding only an address reads as a link, not
  # as a button labelled with a URL.
  defp autolink?(%MDEx.Link{url: url, nodes: [%MDEx.Text{literal: literal}]}),
    do: url in [literal, "mailto:" <> literal, "http://" <> literal]

  defp autolink?(_link), do: false

  # Attribute values — the address, an image's alt text — are filled in and
  # escaped here, each on its own, and travel as tokens (`…z` for the
  # address, `…a` for the alt) until the body's placeholders are filled: in
  # an attribute `{{{x}}}` is escaped like `{{x}}`, and a value is
  # substituted once. Returns each element with whether its address may be
  # linked, and the token values.
  defp place(elements, tokens, variables) do
    Enum.reduce(elements, {%{}, %{}}, fn {index, element}, {placed, attributes} ->
      prefix = "pk#{tokens.nonce}y#{index}"
      url = element |> elem(1) |> fill(tokens, variables)
      safe? = safe_url?(url, elem(element, 0))

      attributes =
        if safe?,
          do: Map.put(attributes, prefix <> "z", escape(String.trim(url))),
          else: attributes

      attributes =
        case element do
          {:image, _url, alt} ->
            Map.put(attributes, prefix <> "a", alt |> fill(tokens, variables) |> escape())

          _link ->
            attributes
        end

      {Map.put(placed, index, {element, safe?}), attributes}
    end)
  end

  defp fill(text, tokens, variables),
    do: text |> restore(tokens) |> Substitution.substitute(variables)

  # One pass over the rendered HTML: each marker is replaced by its element,
  # a link's label being everything between its two markers. A button
  # replaces the paragraph that held it, so the `<p>` before its opening
  # marker and the `</p>` after its closing one go.
  defp assemble(html, _nonce, elements, _accent) when map_size(elements) == 0, do: html

  defp assemble(html, nonce, elements, accent) do
    prefix_size = byte_size("pk#{nonce}y")

    {out, stack, _strip?} =
      "pk#{nonce}y[0-9]+[oci]"
      |> Regex.compile!()
      |> Regex.split(html, include_captures: true)
      |> Enum.with_index()
      |> Enum.reduce({[], [], false}, fn
        {text, index}, {out, stack, strip?} when rem(index, 2) == 0 ->
          text = if strip?, do: String.replace_prefix(text, "</p>", ""), else: text
          {[text | out], stack, false}

        {marker, _index}, state ->
          {element_index, kind} =
            marker |> binary_part(prefix_size, byte_size(marker) - prefix_size) |> Integer.parse()

          marker(kind, element_index, Map.fetch!(elements, element_index), state, nonce, accent)
      end)

    # Markers always pair up; should one ever be missing, keep what it held.
    stack
    |> Enum.reduce(out, fn {_index, outer}, inner -> inner ++ outer end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp marker("i", index, {_image, safe?}, {out, stack, _strip?}, nonce, _accent),
    do: {[image(attribute(nonce, index), safe?) | out], stack, false}

  defp marker("o", index, {element, _safe?}, {out, stack, _strip?}, _nonce, _accent) do
    out =
      case {element, out} do
        {{:button, _url}, [last | rest]} -> [String.replace_suffix(last, "<p>", "") | rest]
        _other -> out
      end

    {[], [{index, out} | stack], false}
  end

  defp marker("c", index, {element, safe?}, {out, [{index, outer} | stack], _}, nonce, accent) do
    label = out |> Enum.reverse() |> IO.iodata_to_binary()
    markup = build(element, label, attribute(nonce, index), safe?, accent)
    {[markup | outer], stack, match?({:button, _url}, element)}
  end

  defp marker(_kind, _index, _element, {out, stack, _strip?}, _nonce, _accent),
    do: {out, stack, false}

  defp attribute(nonce, index), do: "pk#{nonce}y#{index}"

  defp build({:button, _url}, label, prefix, true, accent),
    do: button(prefix <> "z", label, accent)

  defp build({:button, _url}, label, _prefix, false, _accent), do: "<p>" <> label <> "</p>"

  defp build({:link, _url}, label, prefix, true, accent),
    do: ~s(<a href="#{prefix}z" style="color:#{accent};">#{label}</a>)

  defp build({:link, _url}, label, _prefix, false, _accent), do: label

  defp image(prefix, true),
    do:
      ~s(<img src="#{prefix}z" alt="#{prefix}a" ) <>
        ~s(style="max-width:100%;height:auto;border:0;">)

  defp image(prefix, false), do: prefix <> "a"

  # A bulletproof button: the colour is on the table cell, so clients that
  # ignore padding on `<a>` (Outlook) still show a coloured block.
  defp button(href, label, accent) do
    text_color = Branding.text_color_on(accent)

    ~s(<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 16px;">) <>
      ~s(<tr><td align="center" bgcolor="#{accent}" style="border-radius:6px;background-color:#{accent};">) <>
      ~s(<a href="#{href}" style="display:inline-block;padding:12px 24px;border-radius:6px;) <>
      ~s(font-family:#{@font};font-size:15px;font-weight:bold;line-height:1.2;) <>
      ~s(color:#{text_color};text-decoration:none;">#{label}</a>) <>
      "</td></tr></table>"
  end

  defp safe_url?(url, :image), do: Regex.match?(~r/\Ahttps?:\/\/[^\s]/i, String.trim(url))

  defp safe_url?(url, _link),
    do: Regex.match?(~r/\A(?:https?:\/\/[^\s]|mailto:[^\s])/i, String.trim(url))

  ## Plain text

  # The text body gets the same address rules as the HTML one: a link target
  # is substituted and checked on its own, and travels as a token until the
  # body's own placeholders are filled, so a value is never substituted twice.
  # An unsafe target leaves only the label (`url: ""`).
  defp text_urls(%MDEx.Link{} = link, acc, tokens, variables) do
    {nodes, acc} = text_urls_list(link.nodes, acc, tokens, variables)
    link = %{link | nodes: nodes}

    if autolink?(link) do
      {link, acc}
    else
      {urls, count} = acc
      url = fill(link.url, tokens, variables)

      cond do
        # `[{{url}}]({{url}})` — the address written out as its own label —
        # reads `url`, not `url: url`. Compared filled, so it holds for a
        # placeholder and for a literal address alike.
        safe_url?(url, :link) and label_is_address?(link.nodes, url, tokens, variables) ->
          {%{link | url: ""}, acc}

        safe_url?(url, :link) ->
          token = "pk#{tokens.nonce}z#{count}z"
          {%{link | url: token}, {Map.put(urls, token, String.trim(url)), count + 1}}

        true ->
          {%{link | url: ""}, acc}
      end
    end
  end

  defp text_urls(%{nodes: nodes} = node, acc, tokens, variables) when is_list(nodes) do
    {nodes, acc} = text_urls_list(nodes, acc, tokens, variables)
    {%{node | nodes: nodes}, acc}
  end

  defp text_urls(node, acc, _tokens, _variables), do: {node, acc}

  defp text_urls_list(nodes, acc, tokens, variables) do
    Enum.map_reduce(nodes, acc, &text_urls(&1, &2, tokens, variables))
  end

  defp label_is_address?(nodes, url, tokens, variables) do
    nodes |> inline_text() |> fill(tokens, variables) |> String.trim() == String.trim(url)
  end

  # A value ending in a blank line (`{{failed_attempts}}`), in its own
  # paragraph, would otherwise leave two blank lines where the paragraphs
  # meet. Linear: one class, one quantifier.
  defp collapse_blank_lines(text), do: Regex.replace(~r/\n[ \t]*\n(?:[ \t]*\n)+/, text, "\n\n")

  ## Paragraphs that are only placeholders

  # A top-level paragraph of plain text (no link, image or emphasis) that
  # fills in blank is dropped before rendering, from both bodies. Before
  # filling it cannot be blank — the parser keeps no empty paragraph — so
  # only a paragraph whose placeholders all came out empty goes.
  defp drop_blank_paragraphs(%MDEx.Document{nodes: nodes} = document, tokens, variables) do
    %{document | nodes: Enum.reject(nodes, &blank_paragraph?(&1, tokens, variables))}
  end

  defp blank_paragraph?(%MDEx.Paragraph{nodes: nodes}, tokens, variables) do
    Enum.all?(nodes, &plain_inline?/1) and
      nodes |> inline_text() |> fill(tokens, variables) |> String.trim() == ""
  end

  defp blank_paragraph?(_node, _tokens, _variables), do: false

  defp plain_inline?(%MDEx.Text{}), do: true
  defp plain_inline?(%MDEx.SoftBreak{}), do: true
  defp plain_inline?(%MDEx.LineBreak{}), do: true
  defp plain_inline?(_node), do: false

  defp blocks_text(nodes, separator \\ "\n\n") do
    nodes
    |> Enum.map(&block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(separator)
  end

  defp block_text(%MDEx.Heading{nodes: nodes}), do: inline_text(nodes)
  defp block_text(%MDEx.Paragraph{nodes: nodes}), do: inline_text(nodes)
  defp block_text(%MDEx.ThematicBreak{}), do: "---"
  defp block_text(%MDEx.CodeBlock{literal: literal}), do: String.trim_trailing(literal)
  defp block_text(%MDEx.HtmlBlock{}), do: ""

  defp block_text(%MDEx.BlockQuote{nodes: nodes}) do
    nodes |> blocks_text() |> prefix_lines("> ", "> ")
  end

  defp block_text(%MDEx.List{nodes: items} = list) do
    items
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {item, index} ->
      marker = if list.list_type == :ordered, do: "#{list.start + index}. ", else: "- "

      item.nodes
      |> blocks_text("\n")
      |> prefix_lines(marker, String.duplicate(" ", String.length(marker)))
    end)
  end

  defp block_text(%MDEx.Table{nodes: rows}) do
    Enum.map_join(rows, "\n", fn row ->
      Enum.map_join(row.nodes, " | ", &inline_text(&1.nodes))
    end)
  end

  defp block_text(%{nodes: nodes}) when is_list(nodes), do: blocks_text(nodes)
  defp block_text(_node), do: ""

  defp prefix_lines(text, first, rest) do
    [head | tail] = String.split(text, "\n")

    Enum.join(
      [
        first <> head
        | Enum.map(tail, &if(&1 == "", do: String.trim_trailing(rest), else: rest <> &1))
      ],
      "\n"
    )
  end

  defp inline_text(nodes), do: Enum.map_join(nodes, &inline/1)

  defp inline(%MDEx.Text{literal: literal}), do: literal
  defp inline(%MDEx.Code{literal: literal}), do: literal
  defp inline(%MDEx.SoftBreak{}), do: "\n"
  defp inline(%MDEx.LineBreak{}), do: "\n"
  defp inline(%MDEx.HtmlInline{}), do: ""
  defp inline(%MDEx.Image{nodes: nodes}), do: inline_text(nodes)

  defp inline(%MDEx.Link{url: url, nodes: nodes} = link) do
    label = inline_text(nodes)

    cond do
      autolink?(link) or url == "" -> label
      label == "" -> url
      true -> label <> ": " <> url
    end
  end

  defp inline(%{nodes: nodes}) when is_list(nodes), do: inline_text(nodes)
  defp inline(_node), do: ""

  defp fetch(variables, key) when is_map(variables) do
    Enum.find_value(variables, fn {k, v} -> if to_string(k) == key, do: v end)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
