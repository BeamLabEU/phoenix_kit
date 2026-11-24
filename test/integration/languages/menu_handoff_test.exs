defmodule PhoenixKit.Integration.Languages.MenuHandoffTest do
  @moduledoc """
  The account menus' language list sends a visitor to the language's own domain through the
  cross-domain handoff, so the cart and the sign-in travel with them.

  A language is handed over to when the handoff is enabled, the page's host is one of the site's
  hosts (`start` refuses any other), and the language has a host of its own that is not the
  page's. Every other entry, and a site with no domain map at all, renders exactly as it did.

  `async: false`: the tests set the host resolver.
  """

  use PhoenixKit.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Test.HandoffResolver
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.AccountMenu
  alias PhoenixKitWeb.Components.AdminNav
  alias PhoenixKitWeb.Components.UserDashboardNav

  @path "/phoenix_kit/users/log-in?from=home"

  defmodule OneHostResolver do
    def host(_language), do: "only.test"
  end

  # en-US shares the host of its base `en` (`shop.test`), de-DE is `shop-de.test`, fr-FR
  # `shop-fr.test`; the test resolver answers nothing for any other language.
  setup do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    {:ok, _} = Languages.add_language("fr-FR")
    Application.put_env(:phoenix_kit, :canonical_host_resolver, {HandoffResolver, :host})
    on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)
    :ok
  end

  defp section(opts) do
    host = Keyword.get(opts, :host)
    locale = Keyword.get(opts, :locale, "en-US")

    assigns = %{
      languages: AccountMenu.languages(locale, host),
      path: Keyword.get(opts, :path, @path),
      locale: locale,
      switch: Keyword.get(opts, :switch, :link)
    }

    rendered_to_string(~H"""
    <AccountMenu.language_section
      languages={@languages}
      current_path={@path}
      current_locale={@locale}
      switch={@switch}
    />
    """)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp hrefs(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> hrefs_of()
  defp hrefs_of(nodes), do: LazyHTML.attribute(nodes, "href")

  defp handoff_links(html), do: hrefs(html, "a[rel=nofollow]")

  # What an entry leads to: the href of a link, the url an event button hands to the LiveView.
  defp handoff_urls(html, :link), do: handoff_links(html)

  defp handoff_urls(html, :event) do
    html
    |> doc()
    |> LazyHTML.query("button[phx-value-url]")
    |> LazyHTML.attribute("phx-value-url")
    |> Enum.filter(&String.starts_with?(&1, "/phoenix_kit/handoff/start"))
  end

  defp langs(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> lang_of()
  defp lang_of(nodes), do: LazyHTML.attribute(nodes, "lang")

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        email: "menu-handoff-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  describe "a language with a host of its own, other than the page's" do
    for switch <- [:link, :event] do
      test "leads to the handoff start in #{switch} mode" do
        html = section(host: "shop.test", switch: unquote(switch))

        assert handoff_urls(html, unquote(switch)) == [
                 "/phoenix_kit/handoff/start?lang=de-DE&to=%2Fphoenix_kit%2Fusers%2Flog-in%3Ffrom%3Dhome",
                 "/phoenix_kit/handoff/start?lang=fr-FR&to=%2Fphoenix_kit%2Fusers%2Flog-in%3Ffrom%3Dhome"
               ]

        assert langs(html, "a [lang], button [lang]") == ["de-DE", "fr-FR"]
      end
    end

    test "is a plain nofollow link in link mode" do
      html = section(host: "shop.test", switch: :link)
      nodes = html |> doc() |> LazyHTML.query("a[rel=nofollow]")

      assert LazyHTML.attribute(nodes, "href") |> length() == 2
      assert html |> doc() |> LazyHTML.query("button") |> LazyHTML.attribute("type") == []
    end

    test "stays the locale event in event mode, so the person's choice is still saved" do
      html = section(host: "shop.test", switch: :event)
      nodes = html |> doc() |> LazyHTML.query("button")

      assert LazyHTML.attribute(nodes, "phx-click") == [
               "phoenix_kit_set_locale",
               "phoenix_kit_set_locale"
             ]

      assert LazyHTML.attribute(nodes, "phx-value-locale") == ["de-DE", "fr-FR"]
      assert html |> doc() |> LazyHTML.query("a") |> LazyHTML.attribute("href") == []
    end

    test "carries the path the target domain serves, without a locale segment" do
      html =
        section(
          host: "shop-de.test",
          locale: "de-DE",
          path: "/phoenix_kit/de/users/log-in?from=home"
        )

      assert handoff_links(html) == [
               "/phoenix_kit/handoff/start?lang=en-US&to=%2Fphoenix_kit%2Fusers%2Flog-in%3Ffrom%3Dhome",
               "/phoenix_kit/handoff/start?lang=fr-FR&to=%2Fphoenix_kit%2Fusers%2Flog-in%3Ffrom%3Dhome"
             ]
    end

    test "a page without a locale segment keeps its path whole" do
      html = section(host: "shop.test", path: "/phoenix_kit/admin/users")

      assert Enum.all?(
               handoff_links(html),
               &String.ends_with?(&1, "to=%2Fphoenix_kit%2Fadmin%2Fusers")
             )
    end

    test "keeps the dialect's own segment when the target host serves another dialect first" do
      {:ok, _} = Languages.add_language("en-GB")

      for switch <- [:link, :event] do
        html =
          section(
            host: "shop-de.test",
            locale: "de-DE",
            path: "/phoenix_kit/de/users/log-in",
            switch: switch
          )

        # shop.test serves en-US without a segment; en-GB is its sibling, at /en-gb.
        assert handoff_urls(html, switch) == [
                 "/phoenix_kit/handoff/start?lang=en-US&to=%2Fphoenix_kit%2Fusers%2Flog-in",
                 "/phoenix_kit/handoff/start?lang=fr-FR&to=%2Fphoenix_kit%2Fusers%2Flog-in",
                 "/phoenix_kit/handoff/start?lang=en-GB&to=%2Fphoenix_kit%2Fen-gb%2Fusers%2Flog-in"
               ]
      end
    end

    test "a bare locale root with a query loses its segment" do
      html = section(host: "shop.test", path: "/phoenix_kit/en?x=1")

      assert Enum.all?(
               handoff_links(html),
               &String.ends_with?(&1, "to=%2Fphoenix_kit%2F%3Fx%3D1")
             )
    end

    test "the host is compared by name, in any case" do
      assert section(host: "SHOP.test") == section(host: "shop.test")
    end
  end

  describe "an entry that stays a plain language switch" do
    setup do
      # No host of its own: the resolver answers nothing for Japanese.
      {:ok, _} = Languages.add_language("ja")
      :ok
    end

    test "a language without a host of its own keeps today's link in link mode" do
      html = section(host: "shop.test")

      assert hrefs(html, "a:not([rel=nofollow])") == ["/phoenix_kit/ja/users/log-in?from=home"]
      assert length(handoff_links(html)) == 2
    end

    test "a language without a host of its own keeps today's event in event mode" do
      html = section(host: "shop.test", switch: :event)
      nodes = html |> doc() |> LazyHTML.query("button[phx-value-locale=ja]")

      assert LazyHTML.attribute(nodes, "phx-click") == ["phoenix_kit_set_locale"]

      assert LazyHTML.attribute(nodes, "phx-value-url") ==
               ["/phoenix_kit/ja/users/log-in?from=home"]
    end

    test "a sibling dialect on the page's own host keeps its plain switch" do
      {:ok, _} = Languages.add_language("en-GB")
      html = section(host: "shop.test", locale: "en-GB")

      # en-US and en-GB share `shop.test`, the page's host.
      assert length(handoff_links(html)) == 2
      plain = hrefs(html, "a:not([rel=nofollow])")
      assert "/phoenix_kit/ja/users/log-in?from=home" in plain
      assert length(plain) == 2
      refute Enum.any?(handoff_links(html), &String.contains?(&1, "lang=en"))
    end
  end

  describe "markup that must not change" do
    @unchanged [
      {"no host is known", nil},
      {"the page's host is not one of the site's", "www.example.com"},
      {"the page's host is another site's look-alike", "shop.test.evil.test"}
    ]

    for {name, host} <- @unchanged, switch <- [:link, :event] do
      test "#{name} (#{switch})" do
        html = section(host: unquote(host), switch: unquote(switch))

        assert html == section(switch: unquote(switch))
        assert handoff_links(html) == []
        assert html =~ "/phoenix_kit/de/users/log-in?from=home"
      end
    end

    for switch <- [:link, :event] do
      test "the handoff is disabled: one host only (#{switch})" do
        Application.put_env(:phoenix_kit, :canonical_host_resolver, {OneHostResolver, :host})
        html = section(host: "only.test", switch: unquote(switch))

        assert html == section(switch: unquote(switch))
        assert handoff_links(html) == []
      end

      test "a site with no domain map renders the same with or without a host (#{switch})" do
        Application.delete_env(:phoenix_kit, :canonical_host_resolver)

        html = section(host: "shop.test", switch: unquote(switch))

        assert html == section(switch: unquote(switch))
        assert handoff_links(html) == []
        assert html =~ "/phoenix_kit/de/users/log-in?from=home"
        assert html =~ "/phoenix_kit/fr/users/log-in?from=home"
      end
    end
  end

  describe "the site is read once per menu" do
    defp questions(acc \\ []) do
      receive do
        {:resolver_asked, language} -> questions([language | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "building the list asks the resolver once per language, and rendering it asks nothing" do
      _ = questions()
      languages = AccountMenu.languages("en-US", "shop.test")
      asked = questions()

      assert asked != []
      assert asked == Enum.uniq(asked)

      assigns = %{languages: languages}

      _html =
        rendered_to_string(~H"""
        <AccountMenu.language_section languages={@languages} current_path="/x" />
        """)

      assert questions() == []
    end

    test "without a host nothing is asked" do
      _ = questions()
      AccountMenu.languages("en-US")
      assert questions() == []
    end
  end

  describe "the menus the hosts put in their headers" do
    test "user_dropdown takes the page's host, signed in" do
      assigns = %{scope: Scope.for_user(user!())}

      html =
        rendered_to_string(~H"""
        <UserDashboardNav.user_dropdown
          scope={@scope}
          current_path="/phoenix_kit/dashboard"
          current_locale="en-US"
          current_host="shop.test"
        />
        """)

      assert handoff_links(html) == [
               "/phoenix_kit/handoff/start?lang=de-DE&to=%2Fphoenix_kit%2Fdashboard",
               "/phoenix_kit/handoff/start?lang=fr-FR&to=%2Fphoenix_kit%2Fdashboard"
             ]
    end

    test "user_dropdown takes the page's host, as a guest on a sign-in page" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UserDashboardNav.user_dropdown
          scope={nil}
          current_path="/phoenix_kit/users/log-in"
          current_locale="en-US"
          current_host="shop.test"
        />
        """)

      assert length(handoff_links(html)) == 2
    end

    test "user_dropdown without a host is what it was" do
      assigns = %{scope: Scope.for_user(user!())}

      html =
        rendered_to_string(~H"""
        <UserDashboardNav.user_dropdown
          scope={@scope}
          current_path="/phoenix_kit/dashboard"
          current_locale="en-US"
        />
        """)

      assert handoff_links(html) == []
      assert Enum.any?(hrefs(html, "a"), &String.contains?(&1, "/de/"))
    end

    test "admin_user_dropdown takes the page's host" do
      assigns = %{scope: Scope.for_user(user!())}

      html =
        rendered_to_string(~H"""
        <AdminNav.admin_user_dropdown
          scope={@scope}
          current_path="/phoenix_kit/admin"
          current_locale="en-US"
          current_host="shop.test"
        />
        """)

      assert handoff_urls(html, :event) == [
               "/phoenix_kit/handoff/start?lang=de-DE&to=%2Fphoenix_kit%2Fadmin",
               "/phoenix_kit/handoff/start?lang=fr-FR&to=%2Fphoenix_kit%2Fadmin"
             ]
    end
  end
end
