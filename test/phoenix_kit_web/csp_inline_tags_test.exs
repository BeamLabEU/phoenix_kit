defmodule PhoenixKitWeb.CSPInlineTagsTest do
  @moduledoc """
  Every inline `<script>` and `<style>` the kit renders carries the host's CSP nonce
  (`PhoenixKitWeb.CSP`). A new tag without one is blocked on every host with a strict policy.
  """
  use ExUnit.Case, async: true

  # Documents that are cached or served to everyone the same, so no request (and no nonce of
  # one) may shape them. Their style is a constant a host can allow by hash.
  @bundles ~w(phoenix_kit.js phoenix_kit_admin.js phoenix_kit_sortable.js
              phoenix_kit_upload_manager.js)
  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  @exempt [
    "lib/modules/sitemap/html_generator.ex",
    "lib/phoenix_kit/api/public_discovery/guide_html.ex"
  ]

  # Files that handle `<script>` / `<style>` as text (a sanitizer, the installer's edits of a
  # host layout, a linter), not as markup they render.
  @tags_as_data [
    "lib/phoenix_kit/utils/html_sanitizer.ex",
    "lib/phoenix_kit/install/js_integration.ex",
    "lib/mix/tasks/compile.phoenix_kit_js_sources.ex",
    "lib/phoenix_kit/conformance/component_assigns.ex"
  ]

  # Anywhere in the file, on one line or several: the old check saw a tag only when it opened a
  # line and closed on it.
  @tag_opening ~r/<(script|style)\b[^>]*>/s

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path not in @exempt,
          path not in @tags_as_data,
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not (opening =~ "CSP.nonce(" or opening =~ "CSP.attr("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without `nonce={PhoenixKitWeb.CSP.nonce(kind)}`:\n" <>
             Enum.join(offenders, "\n")
  end

  test "the scan sees a tag that closes on a later line, and one in the middle of a line" do
    openings = tag_openings("lib/phoenix_kit_web/components/layouts/root.html.heex")

    assert Enum.any?(openings, fn {opening, _number} ->
             opening =~ "<script" and opening =~ "defer" and opening =~ "\n" and
               opening =~ "src="
           end)

    # `"<style#{…}>.auth-bg {…}</style>"`: a string that opens with a quote, mid-line.
    assert Enum.any?(
             tag_openings("lib/phoenix_kit_web/components/auth_page_wrapper.ex"),
             fn {opening, _number} -> opening =~ "<style" and opening =~ "CSP.attr(" end
           )
  end

  # `nonce={…}` is HEEx. In a plain string it is rendered as written, a literal
  # attribute the browser cannot match (the theme toggle shipped that way once).
  test "a `nonce={…}` attribute in an .ex file sits inside a ~H template" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          lines = path |> File.read!() |> code_lines(),
          {line, number} <- lines,
          line =~ "nonce={PhoenixKitWeb.CSP",
          not in_heex?(lines, number),
          do: "#{path}:#{number}"

    assert offenders == [],
           "write `<style\#{PhoenixKitWeb.CSP.attr(:style)}>` in a plain string:\n" <>
             Enum.join(offenders, "\n")
  end

  # The nearest heredoc opener above the line is a `~H`.
  defp in_heex?(lines, number) do
    lines
    |> Enum.take(number - 1)
    |> Enum.reverse()
    |> Enum.find(fn {line, _} -> line =~ ~s(""") end)
    |> case do
      {opener, _} -> opener =~ ~s(~H""")
      nil -> false
    end
  end

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a data attribute handled in " <>
             "phoenix_kit.js, a hook or a `phx-` binding):\n" <> Enum.join(offenders, "\n")
  end

  test "the bundles build no markup with an inline event handler" do
    offenders =
      for file <- @bundles,
          {line, number} <-
            "priv/static/assets/#{file}"
            |> File.read!()
            |> String.split("\n")
            |> Enum.with_index(1),
          not (line =~ ~r{^\s*(//|\*)}),
          line =~ ~r/\son[a-z]+=\\?["']/,
          do: "#{file}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # A `<style>` a bundle creates is checked against the page's policy like any other: it is
  # stamped with the page's nonce (`adoptStyle`) before it has any text, and never written as a
  # string for `innerHTML`, where a nonce is not applied.
  test "every <style> a bundle creates is stamped, and none is written as a string" do
    offenders =
      for file <- @bundles,
          lines = "priv/static/assets/#{file}" |> File.read!() |> String.split("\n"),
          {line, index} <- Enum.with_index(lines),
          not (line =~ ~r{^\s*(//|\*)}),
          problem = style_problem(line, Enum.slice(lines, index + 1, 4)),
          do: "#{file}:#{index + 1} #{problem}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  defp style_problem(line, next_lines) do
    cond do
      line =~ ~r/createElement\(["']style["']\)/ and
          not Enum.any?(next_lines, &(&1 =~ ~r/adoptStyle|adopt\(/i)) ->
        "creates a <style> that is not stamped in the next lines"

      line =~ ~r/["'`]<style\b/ ->
        "builds a <style> tag as a string"

      true ->
        nil
    end
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  # Lines of the file with `@moduledoc`/`@doc` heredocs blanked: a tag in documentation is an
  # example, not markup.
  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
