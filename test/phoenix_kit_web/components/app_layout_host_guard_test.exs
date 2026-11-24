defmodule PhoenixKitWeb.Components.AppLayoutHostGuardTest do
  @moduledoc """
  Every admin page of the kit that calls `LayoutWrapper.app_layout/1` directly has to give the
  admin header's account menu the page's host: either its `socket` (the layout reads the host
  from it) or an explicit `current_host`. Without one the menu silently keeps its plain language
  switches on that page (`PhoenixKit.Handoff`), and nothing else notices.

  A structural guard, because the part that rots is the attribute each template has to remember.
  """
  use ExUnit.Case, async: true

  # `layout_wrapper.ex` holds the component itself, its docs and the auth pages' layout, which
  # wear no admin chrome.
  @skipped ["lib/phoenix_kit_web/components/layout_wrapper.ex"]
  @call ~r{<(?:[A-Za-z]+\.)*app_layout\b|<\.app_layout\b}

  defp sources do
    Path.wildcard("lib/**/*.{ex,heex}") -- @skipped
  end

  # The opening tag starting at `offset`: up to the `>` that is outside every `{...}`.
  defp opening_tag(source, offset) do
    source
    |> binary_part(offset, byte_size(source) - offset)
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn
      ">", {acc, 0} -> {:halt, {acc, 0}}
      "{", {acc, depth} -> {:cont, {acc <> "{", depth + 1}}
      "}", {acc, depth} -> {:cont, {acc <> "}", depth - 1}}
      char, {acc, depth} -> {:cont, {acc <> char, depth}}
    end)
    |> elem(0)
  end

  defp calls do
    for file <- sources(),
        source = File.read!(file),
        [{offset, _}] <- Regex.scan(@call, source, return: :index),
        # Documentation and install templates quote the tag; a real call sits in a template.
        String.ends_with?(file, ".heex") or not doc_context?(source, offset) do
      {file, opening_tag(source, offset)}
    end
  end

  # Inside a heredoc that is not a `~H` template: documentation and install templates quote the
  # tag, a real call sits in a template.
  defp doc_context?(source, offset) do
    openers = Regex.scan(~r/^.*"""/m, binary_part(source, 0, offset))

    case rem(length(openers), 2) do
      1 -> not (openers |> List.last() |> hd() |> String.contains?("~H"))
      0 -> false
    end
  end

  test "the scan finds the kit's admin templates" do
    assert length(calls()) > 40
  end

  test "every direct call passes its socket or a current_host" do
    offenders =
      for {file, tag} <- calls(),
          not (tag =~ "socket={" or tag =~ "current_host=" or tag =~ "{assigns}"),
          do: file

    assert offenders == [],
           "these call app_layout/1 without socket={...} or current_host={...}, so the admin " <>
             "account menu cannot hand a visitor over to another domain on them: " <>
             inspect(offenders)
  end
end
