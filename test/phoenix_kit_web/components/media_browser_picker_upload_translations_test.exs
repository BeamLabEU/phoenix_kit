defmodule PhoenixKitWeb.Components.MediaBrowserPickerUploadTranslationsTest do
  @moduledoc """
  What a picker says when an uploaded file cannot be picked is in every
  shipped language.
  """
  use ExUnit.Case, async: true

  @locales ~w(de es et fr it pl ru uk zh)

  @messages [
    "The file was saved, but it cannot be picked here.",
    "This file is not a kind of file this picker takes.",
    "This file is already stored as another kind of file, so it cannot be picked here.",
    "This file is already stored, but it cannot be picked here."
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
