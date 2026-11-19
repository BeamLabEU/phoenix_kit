defmodule PhoenixKitWeb.Live.Settings.ApiOauthTranslationsTest do
  @moduledoc """
  Every string of the "Connected apps" card and of the OAuth tab of Settings -> API is in the
  sources and has a translation in every shipped locale. Nothing checks the catalogues
  automatically and a missing entry only shows as English text in the browser, so this test reads
  the `gettext/1` calls of the two sources and looks each msgid up in the `.pot` and in the nine
  translated `.po` files. `en` is the source language and keeps empty msgstr values.
  """
  use ExUnit.Case, async: true

  @sources ~w(
    lib/phoenix_kit_web/live/components/connected_apps.ex
    lib/phoenix_kit_web/live/settings/api_oauth_panel.ex
  )
  @locales ~w(de es et fr it pl ru uk zh)
  @root Path.expand("../../../..", __DIR__)

  defp msgids do
    @sources
    |> Enum.flat_map(fn source ->
      ~r/gettext\(\s*"((?:[^"\\]|\\.)*)"/s
      |> Regex.scan(File.read!(Path.join(@root, source)))
      |> Enum.map(&List.last/1)
    end)
    |> Enum.uniq()
  end

  defp catalogue(path) do
    {:ok, po} = Expo.PO.parse_file(Path.join(@root, path))

    for %Expo.Message.Singular{} = message <- po.messages, into: %{} do
      {IO.iodata_to_binary(message.msgid), IO.iodata_to_binary(message.msgstr)}
    end
  end

  defp placeholders(text),
    do: ~r/%\{(\w+)\}/ |> Regex.scan(text) |> Enum.map(&List.last/1) |> Enum.sort()

  test "the sources have strings to translate" do
    assert length(msgids()) > 60
  end

  test "the template (.pot) has every msgid" do
    template = catalogue("priv/gettext/default.pot")

    for msgid <- msgids() do
      assert Map.has_key?(template, msgid), "default.pot lacks #{inspect(msgid)}"
    end
  end

  test "en keeps every msgstr empty" do
    catalogue = catalogue("priv/gettext/en/LC_MESSAGES/default.po")

    for msgid <- msgids() do
      assert Map.fetch!(catalogue, msgid) == "", "en translates #{inspect(msgid)}"
    end
  end

  for locale <- @locales do
    test "#{locale} translates every msgid and keeps its placeholders" do
      catalogue = catalogue("priv/gettext/#{unquote(locale)}/LC_MESSAGES/default.po")

      for msgid <- msgids() do
        msgstr = Map.get(catalogue, msgid)
        assert is_binary(msgstr) and msgstr != "", "#{unquote(locale)} lacks #{inspect(msgid)}"

        assert placeholders(msgstr) == placeholders(msgid),
               "#{unquote(locale)} changes the placeholders of #{inspect(msgid)}"
      end
    end
  end
end
