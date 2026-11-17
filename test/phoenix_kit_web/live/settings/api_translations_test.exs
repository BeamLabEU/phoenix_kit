defmodule PhoenixKitWeb.Live.Settings.ApiTranslationsTest do
  @moduledoc """
  Every string of Settings -> API (and its sidebar label and permission label) is
  in the template and has a translation in every shipped locale.

  There is no automatic check of the catalogues, and a missing entry only shows
  as English text in the browser, so this test reads the `gettext/1` calls of the
  page's sources and looks each msgid up in the `.pot` and in the eight translated
  `.po` files. `en` is the source language and keeps empty msgstr values.
  """
  use ExUnit.Case, async: true

  # The page itself.
  @page_sources ~w(
    lib/phoenix_kit_web/live/settings/api.ex
    lib/phoenix_kit_web/live/settings/api.html.heex
  )
  # Strings the page's sources do not hold: the sidebar label is
  # `gettext_noop("API")` in admin_tabs.ex (which also holds hundreds of other
  # labels), and the permission label is data in `Permissions`.
  @extra_msgids ["API", "API keys"]
  @locales ~w(de es et fr it pl ru uk zh)

  @root Path.expand("../../../..", __DIR__)

  # Every literal first argument of a `gettext(...)` call in the page's sources.
  defp page_msgids do
    scanned =
      Enum.flat_map(@page_sources, fn source ->
        ~r/gettext\(\s*"((?:[^"\\]|\\.)*)"/s
        |> Regex.scan(File.read!(Path.join(@root, source)))
        |> Enum.map(&List.last/1)
      end)

    Enum.uniq(scanned ++ @extra_msgids)
  end

  defp catalogue(path) do
    {:ok, po} = Expo.PO.parse_file(Path.join(@root, path))

    # Plural entries have a msgstr per plural form; the page uses none.
    for %Expo.Message.Singular{} = message <- po.messages, into: %{} do
      {IO.iodata_to_binary(message.msgid), IO.iodata_to_binary(message.msgstr)}
    end
  end

  test "the page has strings to translate" do
    assert length(page_msgids()) > 40
  end

  test "the template (.pot) has every msgid" do
    template = catalogue("priv/gettext/default.pot")

    for msgid <- page_msgids() do
      assert Map.has_key?(template, msgid), "default.pot lacks #{inspect(msgid)}"
    end
  end

  for locale <- @locales do
    test "#{locale} translates every msgid" do
      catalogue = catalogue("priv/gettext/#{unquote(locale)}/LC_MESSAGES/default.po")

      for msgid <- page_msgids() do
        msgstr = Map.get(catalogue, msgid)
        assert is_binary(msgstr) and msgstr != "", "#{unquote(locale)} lacks #{inspect(msgid)}"
      end
    end
  end

  test "en keeps the source language: every msgid is present with an empty msgstr" do
    catalogue = catalogue("priv/gettext/en/LC_MESSAGES/default.po")

    for msgid <- page_msgids() do
      assert Map.get(catalogue, msgid) == ""
    end
  end

  test "the backend serves the translation, not the English text" do
    backend = PhoenixKitWeb.Gettext
    previous = Gettext.get_locale(backend)
    on_exit(fn -> Gettext.put_locale(backend, previous) end)

    assert Gettext.with_locale(backend, "de", fn ->
             Gettext.gettext(backend, "Revoke this key?")
           end) ==
             "Diesen Schlüssel entziehen?"

    assert Gettext.with_locale(backend, "uk", fn ->
             Gettext.gettext(backend, "Service users")
           end) == "Службові користувачі"
  end
end
