defmodule PhoenixKit.Integration.Languages.SwitcherGatingTest do
  @moduledoc """
  A language menu offers only languages the site serves.

  With the Languages module off, `Languages.get_display_languages/0` is the
  admin page's preview list (a dozen defaults), and `enabled_locale_codes/0` is
  just the default locale — so a switcher built from the preview linked to
  `/ja/...`, `/es/...` routes that do not exist. The admin user menu and the
  frontend switcher read `get_enabled_languages/0` instead, which is empty while
  the module is off.
  """

  use PhoenixKit.DataCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.AccountMenu
  alias PhoenixKitWeb.Components.AdminNav
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher

  defp switcher_html do
    assigns = %{}

    rendered_to_string(~H"""
    <LanguageSwitcher.language_switcher_dropdown current_locale="en-US" />
    """)
  end

  defp switcher_buttons_html do
    assigns = %{}

    rendered_to_string(~H"""
    <LanguageSwitcher.language_switcher_buttons current_locale="en-US" />
    """)
  end

  defp switcher_inline_html do
    assigns = %{}

    rendered_to_string(~H"""
    <LanguageSwitcher.language_switcher_inline current_locale="en-US" />
    """)
  end

  defp admin_menu_html do
    {:ok, user} =
      Auth.register_user(%{
        email: "gating-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    assigns = %{scope: Scope.for_user(user)}

    rendered_to_string(~H"""
    <AdminNav.admin_user_dropdown scope={@scope} current_path="/admin" current_locale="en-US" />
    """)
  end

  defp offered(html),
    do: Regex.scan(~r/phx-value-locale="([^"]+)"/, html) |> Enum.map(&List.last/1)

  describe "with the module off" do
    test "the preview list still exists for the admin page" do
      refute Languages.enabled?()
      assert length(Languages.get_display_languages()) > 1
    end

    test "nothing is enabled to offer" do
      assert Languages.get_enabled_languages() == []
      assert Languages.get_enabled_languages_by_continent() == []
    end

    test "the frontend switcher offers no language" do
      assert offered(switcher_html()) == []
      assert offered(switcher_buttons_html()) == []
      assert offered(switcher_inline_html()) == []
      refute switcher_html() =~ "language-switcher-dropdown"
    end

    test "the admin user menu has no language section" do
      html = admin_menu_html()
      assert offered(html) == []
      refute html =~ ~r/>\s*Language\s*</
    end
  end

  describe "with the module on" do
    setup do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("ja")
      {:ok, _} = Languages.add_language("de-DE")
      :ok
    end

    test "the frontend switcher offers the configured languages, not the defaults" do
      offered = offered(switcher_html())

      assert "ja" in offered
      assert "de" in offered
      refute "ko" in offered
      refute "ar" in offered
    end

    test "the session menu shows the current language and offers only the alternatives" do
      html = admin_menu_html()
      doc = LazyHTML.from_fragment(html)
      assert LazyHTML.attribute(LazyHTML.query(doc, "summary [lang]"), "lang") == ["en-US"]
      assert Enum.sort(offered(html)) == ["de-DE", "ja"]
    end

    test "a guest can follow the other dialect's link when both share a base" do
      {:ok, _} = Languages.add_language("en-GB")
      assigns = %{languages: AccountMenu.languages("en-GB")}

      # The locale plug serves the sibling as the lowercase segment.
      doc =
        rendered_to_string(~H"""
        <AccountMenu.language_section
          languages={@languages}
          current_path="/en-gb/users/log-in?from=home"
          current_locale="en-GB"
        />
        """)
        |> LazyHTML.from_fragment()

      assert LazyHTML.attribute(LazyHTML.query(doc, "summary [lang]"), "lang") == ["en-GB"]

      assert Enum.sort(LazyHTML.attribute(LazyHTML.query(doc, "a [lang]"), "lang")) ==
               ["de-DE", "en-US", "ja"]

      hrefs = LazyHTML.attribute(LazyHTML.query(doc, "a"), "href")

      assert Enum.all?(hrefs, &String.ends_with?(&1, "/users/log-in?from=home"))
      refute Enum.any?(hrefs, &String.contains?(&1, "en-gb"))
      assert Enum.any?(hrefs, &String.contains?(&1, "/de/users/log-in?from=home"))
      assert Enum.any?(hrefs, &String.contains?(&1, "/ja/users/log-in?from=home"))

      # en-US owns /en/, which is omitted when the primary language is prefixless.
      en =
        Enum.find(hrefs, fn href ->
          not String.contains?(href, "/de/") and not String.contains?(href, "/ja/")
        end)

      assert en in [
               "/phoenix_kit/en/users/log-in?from=home",
               "/phoenix_kit/users/log-in?from=home"
             ]
    end

    test "a configured language switched off is not offered" do
      {:ok, _} = Languages.add_language("ko")
      {:ok, _} = Languages.disable_language("ko")

      refute "ko" in offered(switcher_html())
      refute "ko" in offered(switcher_buttons_html())
      refute "ko" in offered(switcher_inline_html())
      refute "ko" in offered(admin_menu_html())
    end
  end

  describe "with one language" do
    test "the admin user menu has nothing to switch between" do
      {:ok, _} = Languages.enable_system()

      assert length(Languages.get_enabled_languages()) == 1
      assert offered(admin_menu_html()) == []
    end
  end
end
