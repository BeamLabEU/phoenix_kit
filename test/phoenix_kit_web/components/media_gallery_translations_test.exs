defmodule PhoenixKitWeb.Components.MediaGalleryTranslationsTest do
  @moduledoc "The gallery tile menu's strings are in every shipped language."
  use ExUnit.Case, async: true

  @locales ~w(de es et fr it pl ru uk)

  @messages ["Remove from selection", "Move to trash", "Preview"]

  test "every tile menu message is translated in every language" do
    for locale <- @locales, msgid <- @messages do
      text =
        Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
          Gettext.gettext(PhoenixKitWeb.Gettext, msgid)
        end)

      assert text != msgid, "#{locale}: #{msgid}"
    end
  end
end
