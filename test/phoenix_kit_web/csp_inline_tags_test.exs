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

  @opening ~r/^\s*"?<(script|style)\b([^>]*)>/

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path not in @exempt,
          {line, number} <- path |> File.read!() |> code_lines(),
          [_, _kind, attrs] <- [Regex.run(@opening, line)],
          not String.contains?(attrs, "src="),
          not (line =~ "CSP.nonce(" or line =~ "CSP.attr("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without `nonce={PhoenixKitWeb.CSP.nonce(kind)}`:\n" <>
             Enum.join(offenders, "\n")
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

  # Lines of the file with `@moduledoc`/`@doc` heredocs blanked: a tag in documentation is an
  # example, not markup.
  defp code_lines(source) do
    ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
