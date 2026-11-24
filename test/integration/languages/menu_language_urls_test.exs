defmodule PhoenixKit.Integration.Languages.MenuLanguageUrlsTest do
  @moduledoc """
  The account menus' `language_urls`: the page's own URL per language (publishing's
  `phoenix_kit_publishing_translations`, or a plain `%{code => url}`), for the pages whose address
  differs per language. An entry whose language has one leads there instead of to the current
  path rewritten for that language, on this domain and through the cross-domain handoff alike.

  Nothing the attr carries may lead off the site: only a local path, or an absolute URL of the
  host the entry is for, is used; anything else is ignored, as if the language had no entry.

  `async: false`: the tests set the host resolver.
  """

  use PhoenixKit.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Test.HandoffResolver
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.AccountMenu
  alias PhoenixKitWeb.Components.AdminNav
  alias PhoenixKitWeb.Components.UserDashboardNav

  @path "/phoenix_kit/docs/start"

  setup do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    {:ok, _} = Languages.add_language("fr-FR")
    :ok
  end

  defp resolver!,
    do: Application.put_env(:phoenix_kit, :canonical_host_resolver, {HandoffResolver, :host})

  defp section(opts) do
    locale = Keyword.get(opts, :locale, "en-US")

    assigns = %{
      languages: AccountMenu.languages(locale, opts[:host], opts[:urls]),
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

  # {language, where the entry leads}, in the order of the list.
  defp leads(html, :link) do
    nodes = html |> doc() |> LazyHTML.query("a")
    langs = nodes |> LazyHTML.query("[lang]") |> LazyHTML.attribute("lang")
    Enum.zip(langs, LazyHTML.attribute(nodes, "href"))
  end

  defp leads(html, :event) do
    nodes = html |> doc() |> LazyHTML.query("button")
    locales = LazyHTML.attribute(nodes, "phx-value-locale")
    Enum.zip(locales, LazyHTML.attribute(nodes, "phx-value-url"))
  end

  defp start(lang, to),
    do: Routes.path("/handoff/start") <> "?" <> URI.encode_query(lang: lang, to: to)

  @publishing [
    %{code: "de", name: "Deutsch", flag: "x", url: "/phoenix_kit/de/docs/anfang", current: false},
    %{code: "fr", name: "Francais", flag: "x", url: "/phoenix_kit/fr/docs/debut", current: false},
    %{code: "en", name: "English", flag: "x", url: "/phoenix_kit/docs/start", current: true}
  ]

  describe "on this domain (no handoff)" do
    for switch <- [:link, :event] do
      test "an entry with a url leads there, #{switch} mode" do
        html =
          section(urls: %{"de" => "/phoenix_kit/de/docs/anfang"}, switch: unquote(switch))

        assert leads(html, unquote(switch)) |> Enum.sort() ==
                 Enum.sort([
                   {"de-DE", "/phoenix_kit/de/docs/anfang"},
                   {"fr-FR", "/phoenix_kit/fr/docs/start"}
                 ])
      end
    end

    test "publishing's list is accepted as it is, matched by base language" do
      assert leads(section(urls: @publishing), :link) |> Enum.sort() ==
               Enum.sort([
                 {"de-DE", "/phoenix_kit/de/docs/anfang"},
                 {"fr-FR", "/phoenix_kit/fr/docs/debut"}
               ])
    end

    test "the event keeps saving the person's choice with the page's own url" do
      html = section(urls: @publishing, switch: :event)
      nodes = html |> doc() |> LazyHTML.query("button")

      assert LazyHTML.attribute(nodes, "phx-click") ==
               ["phoenix_kit_set_locale", "phoenix_kit_set_locale"]

      assert leads(html, :event) == [
               {"de-DE", "/phoenix_kit/de/docs/anfang"},
               {"fr-FR", "/phoenix_kit/fr/docs/debut"}
             ]
    end

    test "an exact code wins over a base match" do
      {:ok, _} = Languages.add_language("en-GB")

      urls = [
        %{code: "en-GB", url: "/phoenix_kit/en-gb/docs/x"},
        %{code: "en", url: "/phoenix_kit/docs/y"}
      ]

      html = section(urls: urls, locale: "de-DE", path: "/phoenix_kit/de/docs/anfang")

      assert {"en-GB", "/phoenix_kit/en-gb/docs/x"} in leads(html, :link)
      assert {"en-US", "/phoenix_kit/docs/y"} in leads(html, :link)
    end

    test "an absolute url of this page's own host leads to its path and query" do
      html =
        section(
          host: "www.example.com",
          urls: %{"de" => "https://WWW.example.com/de/docs/a?x=1#top"}
        )

      assert {"de-DE", "/de/docs/a?x=1"} in leads(html, :link)
    end

    test "an absolute url is ignored when the page's host is not known" do
      assert section(urls: %{"de" => "https://www.example.com/de/docs/a"}) == section([])
    end
  end

  describe "through the handoff" do
    setup do
      resolver!()
      on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)
    end

    for switch <- [:link, :event] do
      test "the destination is the page's url as the other domain serves it, #{switch} mode" do
        html =
          section(
            host: "shop.test",
            urls: %{"de" => "/phoenix_kit/de/docs/anfang", "fr" => "/phoenix_kit/fr/docs/debut"},
            switch: unquote(switch)
          )

        assert leads(html, unquote(switch)) == [
                 {"de-DE", start("de-DE", "/phoenix_kit/docs/anfang")},
                 {"fr-FR", start("fr-FR", "/phoenix_kit/docs/debut")}
               ]
      end
    end

    test "an absolute url of that language's own host is used as it is" do
      html =
        section(
          host: "shop.test",
          urls: %{"de" => "https://shop-de.test/phoenix_kit/docs/anfang?x=1", "fr" => "/x"}
        )

      assert {"de-DE", start("de-DE", "/phoenix_kit/docs/anfang?x=1")} in leads(html, :link)
    end

    test "an absolute url of any other host is ignored, for that entry only" do
      html =
        section(
          host: "shop.test",
          urls: %{
            "de" => "https://shop-fr.test/phoenix_kit/docs/anfang",
            "fr" => "/phoenix_kit/fr/docs/debut"
          }
        )

      assert leads(html, :link) == [
               {"de-DE", start("de-DE", "/phoenix_kit/docs/start")},
               {"fr-FR", start("fr-FR", "/phoenix_kit/docs/debut")}
             ]
    end

    test "a dialect that shares the target's host keeps its own segment" do
      {:ok, _} = Languages.add_language("en-GB")

      html =
        section(
          host: "shop-de.test",
          locale: "de-DE",
          path: "/phoenix_kit/de/docs/anfang",
          urls: %{
            "en-GB" => "/phoenix_kit/en-gb/docs/start",
            "en-US" => "/phoenix_kit/en/docs/start"
          }
        )

      assert {"en-GB", start("en-GB", "/phoenix_kit/en-gb/docs/start")} in leads(html, :link)
      assert {"en-US", start("en-US", "/phoenix_kit/docs/start")} in leads(html, :link)
    end

    test "the language with no entry keeps the computed destination" do
      html = section(host: "shop.test", urls: %{"de" => "/phoenix_kit/de/docs/anfang"})

      assert {"fr-FR", start("fr-FR", "/phoenix_kit/docs/start")} in leads(html, :link)
    end
  end

  describe "a url outside the kit's prefix is an address as it stands" do
    # A host that serves public pages outside the kit's prefix (publishing's own
    # `:public_url_prefix`, a shop) hands such urls over.
    setup do
      resolver!()
      on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)
    end

    defp prefix!(prefix) do
      previous = Application.fetch_env(:phoenix_kit, :url_prefix)
      Application.put_env(:phoenix_kit, :url_prefix, prefix)
      PhoenixKit.Config.clear_url_prefix_cache()

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit, :url_prefix, value)
          :error -> Application.delete_env(:phoenix_kit, :url_prefix)
        end

        PhoenixKit.Config.clear_url_prefix_cache()
      end)
    end

    # What the same entry leads to on this domain and through the handoff.
    defp both(url, code \\ "de", opts \\ []) do
      host = Keyword.get(opts, :host, "shop.test")
      urls = %{code => url}

      plain = section(host: "www.example.com", urls: urls, locale: opts[:locale] || "en-US")
      via = section(host: host, urls: urls, locale: opts[:locale] || "en-US")
      {leads(plain, :link), leads(via, :link)}
    end

    test "the handoff destination is the url itself, minus only the language's own segment" do
      {_, via} = both("/de/docs/anfang?x=1")
      assert {"de-DE", start("de-DE", "/docs/anfang?x=1")} in via

      # Under the kit's prefix, the segment after it goes.
      {_, via} = both("/phoenix_kit/de/docs/anfang")
      assert {"de-DE", start("de-DE", "/phoenix_kit/docs/anfang")} in via

      # Publishing's own prefix: the url is the address, there is no segment where one is dropped.
      {_, via} = both("/blog/de/docs/anfang")
      assert {"de-DE", start("de-DE", "/blog/de/docs/anfang")} in via
      {_, via} = both("/blog/docs/anfang")
      assert {"de-DE", start("de-DE", "/blog/docs/anfang")} in via
    end

    test "the two branches agree: the same url, the same address" do
      for url <- [
            "/de/docs/anfang?x=1",
            "/phoenix_kit/de/docs/anfang",
            "/blog/docs/anfang",
            "/de"
          ] do
        {plain, via} = both(url)

        assert {"de-DE", ^url} = Enum.find(plain, &(elem(&1, 0) == "de-DE"))

        {"de-DE", started} = Enum.find(via, &(elem(&1, 0) == "de-DE"))
        %URI{query: query} = URI.parse(started)
        to = URI.decode_query(query)["to"]

        # Whatever the handoff drops is the language's segment at its position, nothing else.
        assert to == Routes.domain_page_path(url, "de-DE")
      end
    end

    test "a dialect sharing the domain keeps the address it was given" do
      {:ok, _} = Languages.add_language("en-GB")
      opts = [host: "shop-de.test", locale: "de-DE"]

      {_, via} = both("/en-gb/docs/start", "en-GB", opts)
      assert {"en-GB", start("en-GB", "/en-gb/docs/start")} in via

      {_, via} = both("/phoenix_kit/en-gb/docs/start", "en-GB", opts)
      assert {"en-GB", start("en-GB", "/phoenix_kit/en-gb/docs/start")} in via

      # The host language of that domain loses its segment.
      {_, via} = both("/en/docs/start", "en-US", opts)
      assert {"en-US", start("en-US", "/docs/start")} in via
    end

    test "with the kit mounted at the root" do
      prefix!("/")

      {plain, via} = both("/de/docs/anfang?x=1")
      assert {"de-DE", "/de/docs/anfang?x=1"} in plain
      assert {"de-DE", start("de-DE", "/docs/anfang?x=1")} in via

      {_, via} = both("/phoenix_kit/de/docs")
      assert {"de-DE", start("de-DE", "/phoenix_kit/de/docs")} in via
    end

    test "an absolute url of the language's host is already its address" do
      {_, via} = both("https://shop-de.test/de/docs/anfang")
      assert {"de-DE", start("de-DE", "/de/docs/anfang")} in via
    end

    test "an absolute url with no path is the home page" do
      {_, via} = both("https://shop-de.test")
      assert {"de-DE", start("de-DE", "/")} in via
      {_, via} = both("https://shop-de.test?x=1")
      assert {"de-DE", start("de-DE", "/?x=1")} in via

      assert {"de-DE", "/?x=1"} in leads(
               section(host: "www.example.com", urls: %{"de" => "https://www.example.com?x=1"}),
               :link
             )
    end

    test "no url, and no path of the page, can raise in a render" do
      for url <- [
            "/phoenix_kit?x=1",
            "/phoenix_kit?",
            "/phoenix_kit#f",
            "/phoenix_kitn",
            "/phoenix_kit/"
          ],
          host <- [nil, "www.example.com", "shop.test"],
          switch <- [:link, :event] do
        assert is_binary(section(host: host, urls: %{"de" => url, "fr" => url}, switch: switch))
      end

      for path <- ["/phoenix_kit?x=1", "/phoenix_kit?", "/phoenix_kitn", "/phoenix_kit/de?x=1"],
          host <- [nil, "shop.test"] do
        assert is_binary(section(host: host, path: path))
      end
    end

    test "a page path is local after the rewriting too, whatever the mount" do
      prefix!("/")
      languages = AccountMenu.languages("en-US", "shop.test", %{"de" => "/de//evil.test/x"})

      for language <- languages, path = language.page_path do
        assert String.starts_with?(path, "/") and not String.starts_with?(path, "//")
      end

      # The entry falls back to the computed destination.
      de = Enum.find(languages, &(&1.code == "de-DE"))
      assert de.page_path == nil
    end
  end

  describe "nothing it carries may lead off the site" do
    @hostile [
      "https://evil.test/phoenix_kit/docs",
      "http://shop-de.test.evil.test/x",
      "https://shop.test@evil.test/x",
      "//evil.test/x",
      "///evil.test/x",
      "/\\evil.test/x",
      "javascript:alert(1)",
      "JaVaScRiPt:alert(1)",
      "data:text/html,x",
      "ftp://www.example.com/x",
      "https://www.example.com//evil.test/x",
      "docs/relative",
      "",
      "  ",
      "/ok\n/x",
      5,
      nil
    ]

    for {hostile, i} <- Enum.with_index(@hostile), switch <- [:link, :event] do
      test "ignored on this domain, #{inspect(hostile)} (#{i}, #{switch})" do
        html =
          section(
            host: "www.example.com",
            urls: %{"de" => unquote(hostile), "fr" => unquote(hostile)},
            switch: unquote(switch)
          )

        assert html == section(host: "www.example.com", switch: unquote(switch))
      end

      test "ignored through the handoff, #{inspect(hostile)} (#{i}, #{switch})" do
        resolver!()
        on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)

        html =
          section(
            host: "shop.test",
            urls: %{"de" => unquote(hostile), "fr" => unquote(hostile)},
            switch: unquote(switch)
          )

        assert html == section(host: "shop.test", switch: unquote(switch))
      end
    end

    test "every link the menu renders stays a path of this site" do
      resolver!()
      on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)

      for hostile <- @hostile, switch <- [:link, :event] do
        html = section(host: "shop.test", urls: %{"de" => hostile}, switch: switch)

        for {_lang, href} <- leads(html, switch) do
          assert String.starts_with?(href, "/") and not String.starts_with?(href, "//"),
                 "#{inspect(hostile)} produced #{inspect(href)}"
        end
      end
    end
  end

  describe "markup that must not change" do
    for switch <- [:link, :event],
        urls <- [nil, %{}, [], %{"ja" => "/x"}, [%{code: "ko", url: "/k"}]] do
      test "no entry for any listed language: #{inspect(urls)} (#{switch})" do
        assert section(urls: unquote(Macro.escape(urls)), switch: unquote(switch)) ==
                 section(switch: unquote(switch))
      end
    end

    test "with the handoff, an absent attr is the same as an empty one" do
      resolver!()
      on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)

      assert section(host: "shop.test", urls: %{}) == section(host: "shop.test")
      assert section(host: "shop.test", urls: []) == section(host: "shop.test")
    end

    test "the urls alone ask the resolver nothing" do
      resolver!()
      on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)
      flush()

      AccountMenu.languages("en-US", nil, %{"de" => "/x"})
      assert flush() == []
    end

    defp flush(acc \\ []) do
      receive do
        {:resolver_asked, l} -> flush([l | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end

  describe "the menus the hosts put in their headers" do
    defp scope! do
      {:ok, user} =
        Auth.register_user(%{
          email: "menu-urls-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      Scope.for_user(user)
    end

    defp hrefs(html),
      do: html |> doc() |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href")

    test "user_dropdown, signed in" do
      assigns = %{scope: scope!(), urls: %{"de" => "/phoenix_kit/de/docs/anfang"}}

      html =
        rendered_to_string(~H"""
        <UserDashboardNav.user_dropdown
          scope={@scope}
          current_path="/phoenix_kit/docs/start"
          current_locale="en-US"
          language_urls={@urls}
        />
        """)

      assert "/phoenix_kit/de/docs/anfang" in hrefs(html)
    end

    test "user_dropdown, guest" do
      assigns = %{urls: %{"de" => "/phoenix_kit/de/docs/anfang"}}

      html =
        rendered_to_string(~H"""
        <UserDashboardNav.user_dropdown
          scope={nil}
          current_path="/phoenix_kit/docs/start"
          current_locale="en-US"
          language_urls={@urls}
        />
        """)

      assert "/phoenix_kit/de/docs/anfang" in hrefs(html)
    end

    test "user_dropdown, hidden language list stays hidden" do
      assigns = %{urls: %{"de" => "/phoenix_kit/de/docs/anfang"}, scope: scope!()}

      for scope <- [nil, assigns.scope] do
        assigns = Map.put(assigns, :scope, scope)

        html =
          rendered_to_string(~H"""
          <UserDashboardNav.user_dropdown
            scope={@scope}
            current_path="/phoenix_kit/docs/start"
            current_locale="en-US"
            language_urls={@urls}
            show_language_switcher={false}
          />
          """)

        refute "/phoenix_kit/de/docs/anfang" in hrefs(html)
        refute html =~ "pk-session-languages"
      end
    end

    test "admin_user_dropdown" do
      assigns = %{scope: scope!(), urls: @publishing}

      html =
        rendered_to_string(~H"""
        <AdminNav.admin_user_dropdown
          scope={@scope}
          current_path="/phoenix_kit/docs/start"
          current_locale="en-US"
          language_urls={@urls}
        />
        """)

      urls = html |> doc() |> LazyHTML.query("button") |> LazyHTML.attribute("phx-value-url")
      assert "/phoenix_kit/de/docs/anfang" in urls
    end
  end
end
