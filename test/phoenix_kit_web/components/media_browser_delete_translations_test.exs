defmodule PhoenixKitWeb.Components.MediaBrowserDeleteTranslationsTest do
  @moduledoc """
  What the media page says when a permanent delete leaves something behind
  because it is in use, in the languages it ships. A message with no
  translation silently falls back to English, which is how a Russian- or
  Estonian-speaking person ends up reading the one sentence that explains why
  Delete did not delete.
  """
  use ExUnit.Case, async: true

  @backend PhoenixKitWeb.Gettext

  @singular [
    "This file is in use by something else (a comment, for instance), so it can't be deleted.",
    "Some files in this folder are in use by something else, so they and their folders were kept.",
    "Could not delete the folder. Nothing was removed.",
    "Could not move the folder to the trash. Nothing was moved."
  ]

  @plural [
    {"%{count} item is in use by something else and was kept.",
     "%{count} items are in use by something else and were kept."},
    {"%{count} item could not be removed.", "%{count} items could not be removed."}
  ]

  for locale <- ~w(de es et fr it pl ru uk) do
    describe "#{locale}" do
      test "the single messages are translated" do
        Gettext.with_locale(@backend, unquote(locale), fn ->
          for msgid <- @singular do
            translated = Gettext.dgettext(@backend, "default", msgid)
            refute translated == msgid, "untranslated in #{unquote(locale)}: #{msgid}"
          end
        end)
      end

      test "the counted messages are translated for every count, and keep the number" do
        Gettext.with_locale(@backend, unquote(locale), fn ->
          for {one, many} <- @plural, n <- [1, 2, 4, 5, 11, 21] do
            translated = Gettext.dngettext(@backend, "default", one, many, n, count: n)
            refute translated in [one, many], "untranslated in #{unquote(locale)} (#{n}): #{one}"
            assert translated =~ Integer.to_string(n), "#{n} missing from: #{translated}"
            refute translated =~ "%{", "placeholder left in: #{translated}"
          end
        end)
      end
    end
  end

  test "English is the source and reads as written" do
    Gettext.with_locale(@backend, "en", fn ->
      assert Gettext.dngettext(
               @backend,
               "default",
               "%{count} item is in use by something else and was kept.",
               "%{count} items are in use by something else and were kept.",
               3,
               count: 3
             ) ==
               "3 items are in use by something else and were kept."
    end)
  end
end
