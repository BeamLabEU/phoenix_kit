defmodule PhoenixKitWeb.Live.Users.MyApiKeysTranslationsTest do
  @moduledoc """
  Every string of "My API keys" (the page, the shared component and the tab label) is in the
  `.pot` and has a translation in every shipped locale; `en` keeps empty msgstr values.
  Reads the `gettext/1` calls of the sources, like `ApiTranslationsTest`.
  """
  use ExUnit.Case, async: true

  @sources ~w(
    lib/phoenix_kit_web/live/components/personal_api_keys.ex
    lib/phoenix_kit_web/live/users/my_api_keys.ex
  )
  # The tab label is `gettext("API keys")` in profile_settings_tabs.ex, a file of many tabs.
  @extra_msgids ["API keys", "Profile Settings"]
  @locales ~w(de es et fr it pl ru uk)

  @root Path.expand("../../../..", __DIR__)

  defp msgids do
    scanned =
      Enum.flat_map(@sources, fn source ->
        ~r/gettext\(\s*"((?:[^"\\]|\\.)*)"/s
        |> Regex.scan(File.read!(Path.join(@root, source)))
        |> Enum.map(&List.last/1)
      end)

    Enum.uniq(scanned ++ @extra_msgids)
  end

  defp catalogue(path) do
    {:ok, po} = Expo.PO.parse_file(Path.join(@root, path))

    for %Expo.Message.Singular{} = message <- po.messages, into: %{} do
      {IO.iodata_to_binary(message.msgid), IO.iodata_to_binary(message.msgstr)}
    end
  end

  test "the sources have strings to translate" do
    assert length(msgids()) > 40
  end

  test "the template (.pot) has every msgid" do
    template = catalogue("priv/gettext/default.pot")

    for msgid <- msgids() do
      assert Map.has_key?(template, msgid), "default.pot lacks #{inspect(msgid)}"
    end
  end

  for locale <- @locales do
    test "#{locale} translates every msgid" do
      catalogue = catalogue("priv/gettext/#{unquote(locale)}/LC_MESSAGES/default.po")

      for msgid <- msgids() do
        msgstr = Map.get(catalogue, msgid)
        assert is_binary(msgstr) and msgstr != "", "#{unquote(locale)} lacks #{inspect(msgid)}"
      end
    end
  end

  test "en keeps the source language: every msgid is present with an empty msgstr" do
    catalogue = catalogue("priv/gettext/en/LC_MESSAGES/default.po")

    for msgid <- msgids() do
      assert Map.get(catalogue, msgid) == ""
    end
  end

  test "the backend serves the translation, not the English text" do
    backend = PhoenixKitWeb.Gettext
    previous = Gettext.get_locale(backend)
    on_exit(fn -> Gettext.put_locale(backend, previous) end)

    assert Gettext.with_locale(backend, "de", fn ->
             Gettext.gettext(backend, "How to connect")
           end) == "So verbinden Sie sich"
  end
end
