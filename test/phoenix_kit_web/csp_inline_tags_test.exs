defmodule PhoenixKitWeb.CSPInlineTagsTest do
  @moduledoc """
  Every inline `<script>` and `<style>` the kit renders carries the host's CSP nonce
  (`PhoenixKitWeb.CSP`). A new tag without one is blocked on every host with a strict policy.
  """
  use ExUnit.Case, async: true

  # Documents that are cached or served to everyone the same, so no request (and no nonce of
  # one) may shape them. Their style is a constant a host can allow by hash.
  @exempt [
    "lib/modules/sitemap/html_generator.ex",
    "lib/phoenix_kit/api/public_discovery/guide_html.ex"
  ]

  # The opening tag may close on a later line (`<script` … `>`). A check that
  # requires `>` on the same line never sees that tag.
  @tag_open ~r/^\s*"?<(script|style)\b/

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path not in @exempt,
          {text, number} <- tag_openings(path),
          opening = opening_only(text),
          not String.contains?(opening, "src="),
          not (opening =~ "CSP.nonce(" or opening =~ "CSP.attr("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without `nonce={PhoenixKitWeb.CSP.nonce(kind)}`:\n" <>
             Enum.join(offenders, "\n")
  end

  test "a tag that closes on a later line is still seen" do
    openings = tag_openings("lib/phoenix_kit_web/components/layouts/root.html.heex")

    assert Enum.any?(openings, fn {text, _number} ->
             opening = opening_only(text)
             opening =~ "<script" and opening =~ "defer" and opening =~ "src="
           end)
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

  @handler ~r/\son[a-z]+=["{]/

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a data attribute handled in " <>
             "phoenix_kit.js, a hook or a `phx-` binding):\n" <> Enum.join(offenders, "\n")
  end

  test "the bundles build no markup with an inline event handler" do
    offenders =
      for file <- ~w(phoenix_kit.js phoenix_kit_admin.js),
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

  defp tag_openings(path) do
    path |> File.read!() |> code_lines() |> accumulate_tags([])
  end

  defp accumulate_tags([], acc), do: Enum.reverse(acc)

  defp accumulate_tags([{line, number} | rest], acc) do
    if Regex.match?(@tag_open, line) do
      {text, rest} = take_tag(line, rest)
      accumulate_tags(rest, [{text, number} | acc])
    else
      accumulate_tags(rest, acc)
    end
  end

  # The first `>` ends the opening tag. What follows on that line is the body.
  defp take_tag(line, rest) do
    if String.contains?(line, ">") do
      {line, rest}
    else
      case rest do
        [{next, _} | rest] ->
          {more, rest} = take_tag(next, rest)
          {line <> "\n" <> more, rest}

        [] ->
          {line, []}
      end
    end
  end

  defp opening_only(text) do
    case String.split(text, ">", parts: 2) do
      [open, _] -> open
      [open] -> open
    end
  end

  # Lines of the file with `@moduledoc`/`@doc` heredocs blanked: a tag in documentation is an
  # example, not markup.
  defp code_lines(source) do
    ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
