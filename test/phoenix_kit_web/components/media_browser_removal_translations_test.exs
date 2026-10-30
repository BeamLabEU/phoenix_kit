defmodule PhoenixKitWeb.Components.MediaBrowserRemovalTranslationsTest do
  @moduledoc """
  The removal guard's dialog and its messages are in every shipped language,
  with the plural forms the language needs.
  """
  use ExUnit.Case, async: true

  @locales ~w(de es et fr it pl ru uk)

  @singular [
    "There is nothing left to remove.",
    "The files changed. Check the list and confirm again.",
    "The files could not be checked, so nothing was removed. Try again later.",
    "The files could not be freed. Nothing was removed.",
    "This cannot be undone.",
    "Not available to you",
    "Could not check the files"
  ]

  @plural [
    {"and %{count} more file", "and %{count} more files"},
    {"%{count} file is in use and stays in the trash:",
     "%{count} files are in use and stay in the trash:"},
    {"Cannot delete: the file is in use", "Cannot delete: %{count} files are in use"},
    {"Move %{count} folder and its contents to trash?",
     "Move %{count} folders and their contents to trash?"},
    {"Delete %{count} folder and its contents for good?",
     "Delete %{count} folders and their contents for good?"},
    {"Delete %{count} file for good?", "Delete %{count} files for good?"},
    {"%{count} item permanently deleted", "%{count} items permanently deleted"},
    {"%{count} item moved to trash", "%{count} items moved to trash"}
  ]

  test "every message is translated in every language" do
    for locale <- @locales, msgid <- @singular do
      text =
        Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
          Gettext.gettext(PhoenixKitWeb.Gettext, msgid)
        end)

      assert text != msgid, "#{locale}: #{msgid}"
    end
  end

  test "the counted messages are translated, with the count in them" do
    for locale <- @locales, {one, many} <- @plural, n <- [1, 2, 5, 21] do
      text =
        Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
          Gettext.ngettext(PhoenixKitWeb.Gettext, one, many, n)
        end)

      refute text =~ "%{", "#{locale}: #{one} (#{n})"
      refute text in [one, many], "#{locale}: #{one} (#{n})"

      if n != 1 or (many =~ "%{count}" and one =~ "%{count}"),
        do: assert(text =~ Integer.to_string(n), "#{locale}: #{one} (#{n})")
    end
  end

  test "the summary of what was kept carries both numbers" do
    for locale <- @locales do
      text =
        Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
          Gettext.gettext(PhoenixKitWeb.Gettext, "%{deleted} deleted, %{kept} kept: in use",
            deleted: 4,
            kept: 7
          )
        end)

      assert text =~ "4" and text =~ "7", locale
      refute text =~ "%{", locale
    end
  end
end
