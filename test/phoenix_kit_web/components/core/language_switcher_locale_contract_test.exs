defmodule PhoenixKitWeb.Components.Core.LanguageSwitcherLocaleContractTest do
  @moduledoc """
  The locale routing contract, as the switcher implements it.

  A host built with the language in the session filed "give the switcher a
  URL hook, or a session mode". The answer is no — the language lives in the
  URL (see the component's moduledoc and `guides/locale-routing.md`) — and
  these tests pin what the kit offers instead:

    * `locale_path/2`, public, so a host building its own switcher gets the
      exact links the component renders;
    * a working `goto_home` (it was declared and never read, while the
      languages admin page generates snippets that pass it);
    * the predicate behind the dev-only warning for a session-locale page.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher

  # The switcher is for a multilingual site: with the switch off no URL carries
  # a locale segment. Primed on, so the cache (a global process) makes the file
  # `async: false`.
  setup do
    LanguageSettings.multilingual!()
  end

  defp two_languages do
    [
      %{code: "en-US", name: "English (US)", is_primary: true},
      %{code: "fr", name: "French", is_primary: false}
    ]
  end

  describe "locale_path/2" do
    test "puts a non-default language's segment on the current page" do
      assert LanguageSwitcher.locale_path("/phoenix_kit/some/page", "fr") ==
               "/phoenix_kit/fr/some/page"
    end

    test "replaces the language already in the path" do
      assert LanguageSwitcher.locale_path("/phoenix_kit/fr/some/page", "et") ==
               "/phoenix_kit/et/some/page"
    end

    test "accepts a dialect and links by its base language" do
      assert LanguageSwitcher.locale_path("/phoenix_kit/some/page", "fr-CA") ==
               "/phoenix_kit/fr/some/page"
    end

    test "a served sibling segment is stripped instead of stacked" do
      LanguageSettings.put_languages(~w(en-US en-GB de))

      # The public switcher links by base language. en-GB is that base's
      # sibling URL, and switching away must not leave it in the path.
      assert LanguageSwitcher.locale_path("/phoenix_kit/en-gb/some/page", "de") ==
               "/phoenix_kit/de/some/page"
    end

    test "matches the links the dropdown renders" do
      assigns = %{languages: two_languages()}

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/phoenix_kit/some/page"
        />
        """)

      assert html =~ ~s(href="#{LanguageSwitcher.locale_path("/phoenix_kit/some/page", "fr")}")
    end
  end

  describe "goto_home" do
    test "sends every language to its home page instead of the current page" do
      assigns = %{languages: two_languages()}

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/phoenix_kit/some/page"
          goto_home={true}
        />
        """)

      assert html =~ ~s(href="/phoenix_kit/fr")
      refute html =~ ~s(href="/phoenix_kit/fr/some/page")
    end

    test "is off by default" do
      assigns = %{languages: two_languages()}

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_buttons
          current_locale="en"
          languages={@languages}
          current_path="/phoenix_kit/some/page"
        />
        """)

      assert html =~ ~s(href="/phoenix_kit/fr/some/page")
    end
  end

  describe "session_locale_page?/2" do
    test "a non-default language at a URL without a locale is a session-locale page" do
      assert LanguageSwitcher.session_locale_page?("fr", "/phoenix_kit/some/page")
    end

    test "a non-default language at its own URL is fine" do
      refute LanguageSwitcher.session_locale_page?("fr", "/phoenix_kit/fr/some/page")
    end

    test "a query string does not hide the language segment" do
      refute LanguageSwitcher.session_locale_page?("fr", "/phoenix_kit/fr?page=2")
      refute LanguageSwitcher.session_locale_page?("fr", "/phoenix_kit/fr/some/page?page=2#top")
      assert LanguageSwitcher.session_locale_page?("fr", "/phoenix_kit/some/page?lang=fr")
    end

    test "any page whose URL already carries a language is fine" do
      refute LanguageSwitcher.session_locale_page?("et", "/phoenix_kit/fr/some/page")
    end
  end
end
