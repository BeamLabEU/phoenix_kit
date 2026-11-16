defmodule PhoenixKitWeb.OAuth.PagesTranslationsTest do
  @moduledoc """
  The strings of the authorization pages are in the catalogs, and the Russian and Estonian ones
  are translated.
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
    "Back to the request"
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
end
