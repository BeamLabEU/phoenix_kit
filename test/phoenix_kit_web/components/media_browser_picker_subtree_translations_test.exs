defmodule PhoenixKitWeb.Components.MediaBrowserPickerSubtreeTranslationsTest do
  @moduledoc """
  The picker's "Include subfolders" switch is in every shipped language.
  """
  use ExUnit.Case, async: true

  @locales ~w(de es et fr it pl ru uk)

  @messages [
    "Include subfolders",
    "Show the files of the folders below this one too"
  ]

  test "every message is translated in every language" do
    for locale <- @locales, msgid <- @messages do
      text =
        Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
          Gettext.gettext(PhoenixKitWeb.Gettext, msgid)
        end)

      assert text != msgid, "#{locale}: #{msgid}"
    end
  end
end
