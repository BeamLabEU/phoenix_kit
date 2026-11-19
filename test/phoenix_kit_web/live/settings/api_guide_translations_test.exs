defmodule PhoenixKitWeb.Live.Settings.ApiGuideTranslationsTest do
  @moduledoc """
  Every string of the admin API guide is in the template and has a translation in
  every shipped locale. The code samples and the tool texts are shown as declared and
  are not translated; the page's own sentences are. There is no automatic check of the
  catalogues, and a missing entry only shows as English text in the browser, so this
  test reads the `gettext/1` calls of the page's sources and looks each msgid up in the
  `.pot` and in the eight translated `.po` files. `en` is the source language and keeps
  empty msgstr values.
  """
  use ExUnit.Case, async: true

  @page_sources ~w(
    lib/phoenix_kit_web/live/settings/api_guide_panel.ex
    lib/phoenix_kit_web/live/settings/api_guide_panel.html.heex
  )
  @locales ~w(de es et fr it pl ru uk zh)
  @root Path.expand("../../../..", __DIR__)

  # Every literal first argument of a `gettext(...)` or `ngettext(...)` call in the
  # page's sources.
  defp page_msgids do
    @page_sources
    |> Enum.flat_map(fn source ->
      ~r/gettext\(\s*"((?:[^"\\]|\\.)*)"/s
      |> Regex.scan(File.read!(Path.join(@root, source)))
      |> Enum.map(&List.last/1)
    end)
    |> Enum.uniq()
  end

  # The singular and the plural msgids of every `ngettext(...)` call.
  defp page_plurals do
    @page_sources
    |> Enum.flat_map(fn source ->
      ~r/ngettext\(\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"/s
      |> Regex.scan(File.read!(Path.join(@root, source)))
      |> Enum.map(fn [_, singular, plural] -> {singular, plural} end)
    end)
    |> Enum.uniq()
  end

  # msgid => msgstr; for a plural message, the msgstr of the first form.
  defp catalogue(path) do
    {:ok, po} = Expo.PO.parse_file(Path.join(@root, path))

    for message <- po.messages, into: %{} do
      case message do
        %Expo.Message.Singular{} ->
          {IO.iodata_to_binary(message.msgid), IO.iodata_to_binary(message.msgstr)}

        %Expo.Message.Plural{} ->
          {IO.iodata_to_binary(message.msgid), IO.iodata_to_binary(message.msgstr[0])}
      end
    end
  end

  # msgid => {msgid_plural, [msgstr of each form]}, plural messages only.
  defp plural_catalogue(path) do
    {:ok, po} = Expo.PO.parse_file(Path.join(@root, path))

    for %Expo.Message.Plural{} = message <- po.messages, into: %{} do
      forms =
        message.msgstr
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&IO.iodata_to_binary(elem(&1, 1)))

      {IO.iodata_to_binary(message.msgid), {IO.iodata_to_binary(message.msgid_plural), forms}}
    end
  end

  defp placeholders(text),
    do: ~r/%\{(\w+)\}/ |> Regex.scan(text) |> Enum.map(&List.last/1) |> Enum.sort()

  test "the page has strings to translate" do
    assert length(page_msgids()) > 30
  end

  test "the template (.pot) has every msgid" do
    template = catalogue("priv/gettext/default.pot")

    for msgid <- page_msgids() do
      assert Map.has_key?(template, msgid), "default.pot lacks #{inspect(msgid)}"
    end
  end

  for locale <- @locales do
    test "#{locale} translates every msgid and keeps its placeholders" do
      catalogue = catalogue("priv/gettext/#{unquote(locale)}/LC_MESSAGES/default.po")

      for msgid <- page_msgids() do
        msgstr = Map.get(catalogue, msgid)
        assert is_binary(msgstr) and msgstr != "", "#{unquote(locale)} lacks #{inspect(msgid)}"

        assert placeholders(msgstr) == placeholders(msgid),
               "#{unquote(locale)} changes the placeholders of #{inspect(msgid)}"
      end
    end
  end

  test "the page counts hours, rows and seconds with ngettext" do
    assert length(page_plurals()) == 4
  end

  test "the template (.pot) has both msgids of every plural, with two forms" do
    template = plural_catalogue("priv/gettext/default.pot")

    for {singular, plural} <- page_plurals() do
      assert {^plural, [_, _]} = Map.get(template, singular), "default.pot lacks #{singular}"
    end
  end

  for {locale, forms} <- [
        {"de", 2},
        {"en", 2},
        {"es", 2},
        {"et", 2},
        {"fr", 2},
        {"it", 2},
        {"pl", 3},
        {"ru", 3},
        {"uk", 3}
      ] do
    test "#{locale} has #{forms} forms for every plural and keeps its placeholders" do
      catalogue = plural_catalogue("priv/gettext/#{unquote(locale)}/LC_MESSAGES/default.po")

      for {singular, plural} <- page_plurals() do
        assert {^plural, forms} = Map.get(catalogue, singular),
               "#{unquote(locale)} lacks #{singular}"

        assert length(forms) == unquote(forms)

        for form <- forms, unquote(locale) != "en" do
          assert form != ""
          assert placeholders(form) == placeholders(plural)
        end
      end
    end
  end

  test "en keeps the source language: every msgid is present with an empty msgstr" do
    catalogue = catalogue("priv/gettext/en/LC_MESSAGES/default.po")

    for msgid <- page_msgids() do
      assert Map.get(catalogue, msgid) == ""
    end
  end

  test "the backend picks the plural form of the language" do
    backend = PhoenixKitWeb.Gettext
    rows = "Any write that touches more than %{count} row is dangerous too."
    rows_plural = "Any write that touches more than %{count} rows is dangerous too."

    in_locale = fn locale, n ->
      Gettext.with_locale(backend, locale, fn ->
        Gettext.ngettext(backend, rows, rows_plural, n)
      end)
    end

    assert in_locale.("de", 1) =~ "mehr als 1 Zeile berührt"
    assert in_locale.("de", 2) =~ "mehr als 2 Zeilen berührt"
    assert in_locale.("fr", 1) =~ "plus de 1 ligne "
    assert in_locale.("ru", 1) =~ "более 1 строки,"
    assert in_locale.("ru", 21) =~ "более 21 строки,"
    assert in_locale.("ru", 2) =~ "более 2 строк,"
    assert in_locale.("ru", 11) =~ "более 11 строк,"
    assert in_locale.("uk", 21) =~ "понад 21 рядок,"
    assert in_locale.("uk", 3) =~ "понад 3 рядки,"
    assert in_locale.("uk", 5) =~ "понад 5 рядків"
    assert in_locale.("pl", 1) =~ "więcej niż 1 wiersza"
    assert in_locale.("pl", 3) =~ "więcej niż 3 wierszy"
  end

  test "the backend serves the translation, not the English text" do
    backend = PhoenixKitWeb.Gettext
    previous = Gettext.get_locale(backend)
    on_exit(fn -> Gettext.put_locale(backend, previous) end)

    assert Gettext.with_locale(backend, "de", fn ->
             Gettext.gettext(backend, "Dangerous operations")
           end) == "Gefährliche Vorgänge"

    assert Gettext.with_locale(backend, "uk", fn ->
             Gettext.gettext(backend, "Dangerous operations")
           end) == "Небезпечні операції"
  end
end
