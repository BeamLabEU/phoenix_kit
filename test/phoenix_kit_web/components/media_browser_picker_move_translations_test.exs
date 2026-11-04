defmodule PhoenixKitWeb.Components.MediaBrowserPickerMoveTranslationsTest do
  @moduledoc """
  The picker's move says "Nothing to move", and how many of a pick moved, in every
  shipped language.
  """
  use ExUnit.Case, async: true

  @locales ~w(de es et fr it pl ru uk)

  test "the message is translated in every language" do
    for locale <- @locales do
      text =
        Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
          Gettext.gettext(PhoenixKitWeb.Gettext, "Nothing to move")
        end)

      assert text != "Nothing to move", locale
    end
  end

  test "so is the partial count" do
    for locale <- @locales do
      text =
        Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
          Gettext.gettext(PhoenixKitWeb.Gettext, "%{moved} of %{total} items moved",
            moved: 1,
            total: 2
          )
        end)

      refute text == "1 of 2 items moved", locale
      assert text =~ "1" and text =~ "2", locale
    end
  end
end
