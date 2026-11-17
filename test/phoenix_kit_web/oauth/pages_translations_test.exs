defmodule PhoenixKitWeb.OAuth.PagesTranslationsTest do
  @moduledoc """
  The strings of the authorization pages are in the catalogs, and every shipped language has them
  translated: the consent screen is a security decision, so nobody gets it in a foreign language
  by accident.
  """
  use ExUnit.Case, async: true

  @strings [
    "This connection cannot be started",
    "Start the connection again",
    "You cannot connect applications",
    "Allow access",
    "What it may do",
    "How long",
    "Allow",
    "Too many connections",
    "Back to the request",
    "Reading",
    "Changing data",
    "What this includes",
    "Yes, disconnect",
    "The application gets only what you tick here. If it needs other rights later, disconnect it under My API keys and connect it again."
  ]

  defp translate(locale, msgid),
    do:
      Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
        Gettext.dgettext(PhoenixKitWeb.Gettext, "default", msgid)
      end)

  test "Russian and Estonian have their own text, English falls back to the source string" do
    for msgid <- @strings do
      refute translate("ru", msgid) == msgid, "ru: #{msgid}"
      refute translate("et", msgid) == msgid, "et: #{msgid}"
      assert translate("en", msgid) == msgid
    end
  end

  test "an interpolated string keeps its placeholder" do
    for locale <- ["ru", "et"] do
      text =
        Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
          Gettext.dgettext(PhoenixKitWeb.Gettext, "default", "%{client} asks for access",
            client: "ACME"
          )
        end)

      assert text =~ "ACME"
      refute text =~ "%{"
    end
  end

  describe "every catalog" do
    @locales ~w(de es et fr it pl ru uk zh)
    @extra ["Deny", "Disconnect", "Connected", "Last used"]

    defp catalog(path), do: path |> Expo.PO.parse_file() |> elem(1)

    defp oauth_msgids do
      template = Path.join(:code.priv_dir(:phoenix_kit), "gettext/default.pot")

      from_pages =
        for %Expo.Message.Singular{} = message <- catalog(template).messages,
            message.references |> List.flatten() |> Enum.any?(&oauth_reference?/1) do
          IO.iodata_to_binary(message.msgid)
        end

      Enum.uniq(from_pages ++ @extra)
    end

    defp oauth_reference?({file, _line}), do: oauth_reference?(file)
    defp oauth_reference?(file) when is_binary(file), do: file =~ "phoenix_kit_web/oauth/"
    defp oauth_reference?(_other), do: false

    test "the strings of the pages are found in the template" do
      assert length(oauth_msgids()) >= 23 + length(@extra)
    end

    defp translations(locale) do
      path = Path.join(:code.priv_dir(:phoenix_kit), "gettext/#{locale}/LC_MESSAGES/default.po")

      for %Expo.Message.Singular{} = message <- catalog(path).messages, into: %{} do
        {IO.iodata_to_binary(message.msgid), IO.iodata_to_binary(message.msgstr)}
      end
    end

    test "each has a non-empty translation in every shipped language" do
      for locale <- @locales do
        translated = translations(locale)

        for msgid <- oauth_msgids() do
          assert Map.get(translated, msgid, "") != "", "#{locale}: #{msgid}"
        end
      end
    end

    test "a translation keeps the placeholders of its source" do
      for locale <- @locales do
        translated = translations(locale)

        for msgid <- oauth_msgids() do
          assert placeholders(translated[msgid]) == placeholders(msgid), "#{locale}: #{msgid}"
        end
      end
    end

    defp placeholders(text), do: ~r/%\{\w+\}/ |> Regex.scan(text) |> List.flatten() |> Enum.sort()
  end
end
