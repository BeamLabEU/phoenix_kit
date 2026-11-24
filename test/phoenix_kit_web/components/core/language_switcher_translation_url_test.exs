defmodule PhoenixKitWeb.Components.Core.LanguageSwitcherTranslationUrlTest do
  @moduledoc """
  `LanguageSwitcher.translation_url/2`: the one place that reads a page's per-language URLs, for
  the switcher and for the account menus. Accepts publishing's list
  (`phoenix_kit_publishing_translations`, atom- or string-keyed) and a plain `%{code => url}`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.Core.LanguageSwitcher

  defp url(entries, code), do: LanguageSwitcher.translation_url(entries, code)

  @publishing [
    %{
      code: "en",
      name: "English",
      flag: "x",
      url: "/en/docs/start",
      current: true,
      enabled: true
    },
    %{
      code: "de",
      name: "Deutsch",
      flag: "x",
      url: "/de/docs/anfang",
      current: false,
      enabled: true
    }
  ]

  test "reads publishing's list, atom-keyed and string-keyed" do
    assert url(@publishing, "de") == "/de/docs/anfang"

    string_keyed = [%{"code" => "de", "url" => "/de/docs/anfang"}]
    assert url(string_keyed, "de") == "/de/docs/anfang"
  end

  test "reads a plain map keyed by language code, strings or atoms" do
    assert url(%{"de" => "/de/x"}, "de") == "/de/x"
    assert url(%{de: "/de/x"}, "de") == "/de/x"
  end

  test "an exact code wins over a base match, whatever the order" do
    entries = [%{code: "en-GB", url: "/gb"}, %{code: "en-US", url: "/us"}]

    assert url(entries, "en-US") == "/us"
    assert url(entries, "en-GB") == "/gb"
    assert url(%{"en-GB" => "/gb", "en-US" => "/us"}, "en-US") == "/us"
  end

  test "without an exact code the base language matches, either way round" do
    assert url(@publishing, "de-DE") == "/de/docs/anfang"
    assert url([%{code: "de-AT", url: "/at"}], "de") == "/at"
    assert url([%{code: "de-AT", url: "/at"}], "de-DE") == "/at"
    assert url(%{"de" => "/de/x"}, "de-DE") == "/de/x"
  end

  test "the bare base language is preferred to a sibling dialect" do
    entries = [%{code: "en-GB", url: "/gb"}, %{code: "en", url: "/en"}]

    assert url(entries, "en-US") == "/en"
    # With no bare entry the first dialect of the base answers.
    assert url([%{code: "en-GB", url: "/gb"}, %{code: "en-AU", url: "/au"}], "en-US") == "/gb"
    assert url([%{code: "en-GB", url: "/gb"}, %{code: "en-AU", url: "/au"}], "en") == "/gb"
  end

  test "codes are compared without regard to case" do
    assert url([%{code: "DE", url: "/de"}], "de") == "/de"
    assert url(%{"en-gb" => "/gb"}, "en-GB") == "/gb"
  end

  test "a language with no entry, or none at all, has no url" do
    assert url(@publishing, "fr") == nil
    assert url([], "de") == nil
    assert url(nil, "de") == nil
    assert url(%{}, "de") == nil
    assert url("not entries", "de") == nil
    assert url(@publishing, nil) == nil
  end

  test "an entry without a usable url (an unpublished draft) has no url, and does not fall to a sibling" do
    assert url([%{code: "de", url: nil}], "de") == nil
    assert url([%{code: "de-AT", url: "/at"}, %{code: "de", url: nil}], "de") == nil
    assert url([%{code: "de", url: 5}], "de") == nil
    assert url(%{"de" => nil}, "de") == nil
  end

  test "an entry with a blank code answers for no language" do
    assert url([%{code: "", url: "/x"}, %{code: "  ", url: "/y"}], "en-GB") == nil
    assert url(%{"" => "/x"}, "en") == nil
  end

  describe "the standalone switcher's own rule (:base)" do
    # The switcher always took the first entry of the asked base language, in list order.
    test "the first entry of that base wins, bare or dialect" do
      assert LanguageSwitcher.translation_url(
               [%{code: "en-US", url: "/a"}, %{code: "en", url: "/b"}],
               "en",
               :base
             ) == "/a"

      assert LanguageSwitcher.translation_url(
               [%{code: "en", url: "/b"}, %{code: "en-US", url: "/a"}],
               "en",
               :base
             ) == "/b"
    end

    test "a first entry without a url answers nil, it does not fall to the next" do
      assert LanguageSwitcher.translation_url(
               [%{code: "en-US", url: nil}, %{code: "en", url: "/a"}],
               "en",
               :base
             ) == nil
    end
  end

  test "an entry that is not a map, or has no code, is skipped" do
    assert url([:junk, %{url: "/x"}, %{code: nil, url: "/y"}, %{code: "de", url: "/de"}], "de") ==
             "/de"
  end
end
