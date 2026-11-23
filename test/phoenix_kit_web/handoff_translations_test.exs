defmodule PhoenixKitWeb.HandoffTranslationsTest do
  @moduledoc """
  The one line the handoff shows ("You are signed in as ..."): it is in the source and has a
  translation in every shipped locale, with its placeholder. Nothing checks the catalogues
  automatically and a missing entry only shows as English text in the browser. `en` is the source
  language and keeps an empty msgstr.
  """
  use ExUnit.Case, async: true

  @source "lib/phoenix_kit_web/controllers/handoff_controller.ex"
  @locales ~w(de es et fr it pl ru uk zh)
  @root Path.expand("../..", __DIR__)

  defp msgids do
    ~r/gettext\(\s*"((?:[^"\\]|\\.)*)"/s
    |> Regex.scan(File.read!(Path.join(@root, @source)))
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
  end

  defp catalogue(path) do
    {:ok, po} = Expo.PO.parse_file(Path.join(@root, path))

    for %Expo.Message.Singular{} = message <- po.messages, into: %{} do
      {IO.iodata_to_binary(message.msgid), IO.iodata_to_binary(message.msgstr)}
    end
  end

  test "the controller has the line to translate" do
    assert msgids() == ["You are signed in as %{email}."]
  end

  test "the template (.pot) has every msgid" do
    template = catalogue("priv/gettext/default.pot")

    for msgid <- msgids(),
        do: assert(Map.has_key?(template, msgid), "default.pot lacks #{inspect(msgid)}")
  end

  test "en keeps every msgstr empty" do
    catalogue = catalogue("priv/gettext/en/LC_MESSAGES/default.po")
    for msgid <- msgids(), do: assert(Map.fetch!(catalogue, msgid) == "")
  end

  for locale <- @locales do
    test "#{locale} translates every msgid, with its placeholders" do
      catalogue = catalogue("priv/gettext/#{unquote(locale)}/LC_MESSAGES/default.po")

      for msgid <- msgids() do
        msgstr = Map.get(catalogue, msgid)
        assert is_binary(msgstr) and msgstr != "", "#{unquote(locale)} lacks #{inspect(msgid)}"
        assert placeholders(msgstr) == placeholders(msgid)
        refute msgstr == msgid
      end
    end
  end

  defp placeholders(text),
    do: ~r/%\{(\w+)\}/ |> Regex.scan(text) |> Enum.map(&List.last/1) |> Enum.sort()
end
