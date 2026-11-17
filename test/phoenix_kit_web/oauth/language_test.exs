defmodule PhoenixKitWeb.OAuth.LanguageTest do
  @moduledoc """
  The language of the pages of the authorization flow, through the real endpoint: the order in
  which the `lang` parameter, the person's `preferred_locale`, the `Accept-Language` header and
  the site's default are tried, that each is checked against the languages the install has
  enabled (and never reflected), the switcher, and that a chosen language survives the answers
  of the pages.

  The site here is Estonian by default, with Russian and English (US) enabled and German
  configured but off.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthFlowSupport

  import PhoenixKit.API.OAuthTestSupport,
    only: [client!: 0, enable_oauth!: 0, pkce: 0]

  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.OAuth.Language

  @moduletag :capture_log
  @read "testkit.items:read"
  @title "Allow access"

  setup do
    setup_api()
    enable_oauth!()
    configure_languages()

    {user, _role} = holder(["dashboard", "settings"])
    {_verifier, challenge} = pkce()
    %{user: user, client: client!(), challenge: challenge}
  end

  defp configure_languages(codes \\ ~w(et ru en-US)) do
    languages =
      codes
      |> Enum.with_index()
      |> Enum.map(fn {code, index} ->
        %{
          "code" => code,
          "name" => code,
          "native" => "native " <> code,
          "is_default" => index == 0,
          "is_enabled" => true,
          "position" => index
        }
      end)
      |> Kernel.++([
        %{
          "code" => "de",
          "name" => "German",
          "is_default" => false,
          "is_enabled" => false,
          "position" => 9
        }
      ])

    KeyTestSupport.put_setting("languages_enabled", "true")

    KeyTestSupport.write_setting(fn ->
      Settings.update_json_setting("languages_config", %{"languages" => languages})
    end)
  end

  defp request_id(client, challenge),
    do: browser() |> authorize(authorize_params(client, challenge)) |> consent_id()

  defp with_header(conn, value), do: Plug.Conn.put_req_header(conn, "accept-language", value)

  defp prefer(user, locale) do
    {:ok, user} = Auth.update_user_locale_preference(user, locale)
    user
  end

  defp doc(conn), do: Floki.parse_document!(conn.resp_body)

  defp html_lang(conn), do: conn |> doc() |> Floki.attribute("html", "lang") |> List.first()

  defp title(conn), do: conn |> doc() |> Floki.find("title") |> Floki.text()

  defp translate(locale, msgid),
    do:
      Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
        Gettext.dgettext(PhoenixKitWeb.Gettext, "default", msgid)
      end)

  # The page is in `locale`: the document says so and the title is that language's text.
  defp assert_in(conn, code, gettext_locale) do
    assert html_lang(conn) == code
    assert title(conn) == translate(gettext_locale, @title)
  end

  test "the texts the tests tell apart do differ" do
    assert translate("ru", @title) != translate("et", @title)
    assert translate("et", @title) != @title
    assert translate("en", @title) == @title
  end

  describe "the order of the sources" do
    # {the query, the person's preferred_locale, the header, the language}
    @table [
      {"", nil, nil, {"et", "et"}},
      {"", nil, "ru", {"ru", "ru"}},
      {"", "en-US", "ru", {"en-US", "en"}},
      {"", "en-US", nil, {"en-US", "en"}},
      {"lang=ru", "en-US", "et", {"ru", "ru"}},
      {"lang=en-US", nil, "ru", {"en-US", "en"}},
      {"lang=de", "en-US", "ru", {"en-US", "en"}},
      {"lang=de", nil, "ru", {"ru", "ru"}},
      {"lang=de", nil, nil, {"et", "et"}},
      {"", "de-DE", "ru", {"ru", "ru"}},
      {"", "de-DE", nil, {"et", "et"}}
    ]

    for {query, preferred, header, {code, gettext}} <- @table do
      test "lang=#{inspect(query)}, preferred #{inspect(preferred)}, header #{inspect(header)} -> #{code}",
           %{user: user, client: client, challenge: challenge} do
        user = if unquote(preferred), do: prefer(user, unquote(preferred)), else: user
        id = request_id(client, challenge)
        conn = browser(user)
        conn = if unquote(header), do: with_header(conn, unquote(header)), else: conn

        page = consent(conn, id, unquote(query))
        assert page.status == 200
        assert_in(page, unquote(code), unquote(gettext))
      end
    end
  end

  describe "a candidate that is not an enabled language is ignored" do
    for {label, query} <- [
          {"an unknown code", "lang=xx"},
          {"a disabled language", "lang=de"},
          {"an empty value", "lang="},
          {"a very long value", "lang=" <> String.duplicate("a", 5000)},
          {"a NUL byte", "lang=ru%00"},
          {"a NUL before the code", "lang=%00ru"},
          {"script tags", "lang=%3Cscript%3Ealert(1)%3C%2Fscript%3E"},
          {"a quote that closes the attribute", "lang=ru%22%3E%3Cscript%3E"},
          {"a list", "lang[]=ru"},
          {"a map", "lang[a]=ru"},
          {"a path", "lang=..%2F..%2Fru"},
          {"a code with a space", "lang=ru%20"},
          {"a wildcard", "lang=*"}
        ] do
      test "#{label}: the header is next", %{user: user, client: client, challenge: challenge} do
        id = request_id(client, challenge)
        page = consent(with_header(browser(user), "en-US"), id, unquote(query))

        assert page.status == 200
        assert_in(page, "en-US", "en")
        refute page.resp_body =~ "<script>alert"
        refute page.resp_body =~ "<script>"
        refute page.resp_body =~ "%00"
        refute page.resp_body =~ <<0>>
      end
    end

    test "nothing of the request's own text reaches the page or its links", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      evil = "ru\"><script>alert(1)</script>"
      query = "lang=" <> URI.encode_www_form(evil)

      page = consent(browser(user), id, query)

      assert_in(page, "et", "et")
      refute page.resp_body =~ "alert(1)"
      refute page.resp_body =~ "script>alert"

      for href <- doc(page) |> Floki.find("#language-switcher a") |> Floki.attribute("href") do
        refute href =~ "alert"
      end
    end

    test "an unsupported language in the person's profile is ignored", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      user = prefer(user, "de-DE")
      id = request_id(client, challenge)
      assert_in(consent(with_header(browser(user), "ru"), id), "ru", "ru")
    end
  end

  describe "Accept-Language" do
    for {header, code, gettext} <- [
          {"et;q=0.5, ru;q=0.9, en-US;q=0.8", "ru", "ru"},
          {"ru;q=0.5, en-US;q=0.5", "ru", "ru"},
          {"en-US;q=0.5, ru;q=0.5", "en-US", "en"},
          {"ru;q=0, en-US", "en-US", "en"},
          {"*, ru", "ru", "ru"},
          {"*", "et", "et"},
          {"de, fr;q=0.9, ru;q=0.1", "ru", "ru"},
          {"ru;q=abc, en-US", "en-US", "en"},
          {"ru;q=1.5, en-US", "en-US", "en"},
          {"ru;q=, en-US", "en-US", "en"},
          {"RU", "ru", "ru"},
          {" ru-RU ; q=0.8 , en-US;q=0.3", "ru", "ru"},
          {"en-GB,en;q=0.9", "en-US", "en"},
          {"en-gb", "en-US", "en"},
          {"ru_RU", "ru", "ru"},
          {"zh-Hans-CN, ru;q=0.2", "ru", "ru"},
          {"fr, de", "et", "et"},
          {"<script>, ru", "ru", "ru"},
          {"ru;q=0.9;x=y, en-US;q=0.1", "ru", "ru"},
          {"", "et", "et"}
        ] do
      test "#{inspect(header)} -> #{code}", %{user: user, client: client, challenge: challenge} do
        id = request_id(client, challenge)
        page = consent(with_header(browser(user), unquote(header)), id)
        assert_in(page, unquote(code), unquote(gettext))
      end
    end

    test "a header of unreasonable size is ignored", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      header = String.duplicate("de,", 2000) <> "ru"
      assert_in(consent(with_header(browser(user), header), id), "et", "et")
    end

    test "only the first entries are read", %{user: user, client: client, challenge: challenge} do
      id = request_id(client, challenge)
      header = String.duplicate("de,", 30) <> "ru"
      assert_in(consent(with_header(browser(user), header), id), "et", "et")
    end
  end

  describe "the languages of the install" do
    test "a dialect is mapped to the enabled language of its base", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)

      for {query, code, gettext} <- [
            {"lang=ru-RU", "ru", "ru"},
            {"lang=en-GB", "en-US", "en"},
            {"lang=EN-us", "en-US", "en"},
            {"lang=et_EE", "et", "et"}
          ] do
        assert_in(consent(browser(user), id, query), code, gettext)
      end
    end

    test "when the site has a single language, every request is in it", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      KeyTestSupport.put_setting("languages_enabled", "false")
      id = request_id(client, challenge)
      default = html_lang(consent(browser(user), id))
      assert default != "ru"

      user = prefer(user, "ru")

      for query <- ["lang=ru", "lang=en-US", ""] do
        page = consent(with_header(browser(user), "ru"), id, query)
        assert page.status == 200
        assert html_lang(page) == default
        assert [] = doc(page) |> Floki.find("#language-switcher")
      end
    end

    test "a site whose languages are two dialects of one base lists both", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      configure_languages(~w(en-US en-GB ru))
      id = request_id(client, challenge)

      page = consent(browser(user), id, "lang=en-GB")
      assert html_lang(page) == "en-GB"
      assert [_, _, _] = doc(page) |> Floki.find("#language-switcher a")
      assert doc(page) |> Floki.attribute("#language-en-GB", "aria-current") == ["true"]
      assert doc(page) |> Floki.attribute("#language-en-US", "aria-current") == []

      assert html_lang(consent(with_header(browser(user), "en-GB"), id)) == "en-GB"
    end
  end

  describe "the switcher" do
    test "the consent page links every enabled language, the current one is marked", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)

      for {current, others} <- [{"ru", ~w(et en-US)}, {"et", ~w(ru en-US)}, {"en-US", ~w(et ru)}] do
        page = consent(browser(user), id, "lang=" <> current)
        html = doc(page)

        assert [_, _, _] = Floki.find(html, "#language-switcher a")

        assert Floki.attribute(html, "#language-switcher", "aria-label") == [
                 translate(gettext_of(current), "Language")
               ]

        for code <- [current | others] do
          assert [href] = Floki.attribute(html, "#language-#{code}", "href")
          assert href == path("/consent/" <> id) <> "?lang=" <> code
          assert [name] = Floki.find(html, "#language-#{code}") |> Enum.map(&Floki.text/1)
          assert String.trim(name) == "native " <> code
        end

        assert Floki.attribute(html, "#language-#{current}", "aria-current") == ["true"]

        for code <- others,
            do: assert(Floki.attribute(html, "#language-#{code}", "aria-current") == [])

        assert [_] = Floki.find(html, "a[aria-current]")
      end
    end

    test "a disabled language is not offered", %{user: user, client: client, challenge: challenge} do
      id = request_id(client, challenge)
      html = consent(browser(user), id) |> doc()

      assert [] = Floki.find(html, "#language-de")
    end

    test "the default language is the current one when nothing asks for another", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      html = consent(browser(user), id) |> doc()
      assert Floki.attribute(html, "a[aria-current]", "id") == ["language-et"]
    end

    test "an id that is not a token gets the language but no links", %{user: user} do
      page = consent(with_header(browser(user), "ru"), "x\"><b>")
      assert page.status == 400
      assert html_lang(page) == "ru"
      assert [] = doc(page) |> Floki.find("#language-switcher")
      refute page.resp_body =~ "<b>"
    end

    test "the page of a request that is gone has the switcher, in the chosen language", %{
      user: user
    } do
      id = String.duplicate("a", 43)
      page = consent(browser(user), id, "lang=ru")

      assert page.status == 400
      assert html_lang(page) == "ru"
      assert title(page) == translate("ru", "Start the connection again")
      assert [href] = doc(page) |> Floki.attribute("#language-et", "href")
      assert href == path("/consent/" <> id) <> "?lang=et"
    end
  end

  describe "the chosen language survives the answers" do
    test "the form of the consent page carries it, and a refused answer comes back in it", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)

      page = consent(with_header(browser(user), "et"), id, "lang=ru")
      assert [form] = doc(page) |> Floki.find("#consent-form")
      assert Floki.attribute(form, "action") == [path("/consent/" <> id) <> "?lang=ru"]

      # The form is posted to that action, with nothing chosen: the screen comes back in Russian.
      refused =
        decide(
          with_header(browser(user), "et"),
          id,
          %{"decision" => "allow", "scopes" => []},
          "lang=ru"
        )

      assert refused.status == 422
      assert_in(refused, "ru", "ru")
      assert [error] = doc(refused) |> Floki.find("#consent-error")
      assert Floki.text(error) =~ translate("ru", "Choose at least one permission.")

      assert doc(refused) |> Floki.attribute("#consent-form", "action") ==
               [path("/consent/" <> id) <> "?lang=ru"]

      assert doc(refused) |> Floki.attribute("#language-ru", "aria-current") == ["true"]
    end

    test "a language that came from the header or the profile is not written into the links", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      page = consent(with_header(browser(user), "ru"), id)
      assert_in(page, "ru", "ru")
      assert doc(page) |> Floki.attribute("#consent-form", "action") == [path("/consent/" <> id)]

      user = prefer(user, "en-US")
      page = consent(browser(user), id)
      assert_in(page, "en-US", "en")
      assert doc(page) |> Floki.attribute("#consent-form", "action") == [path("/consent/" <> id)]
    end

    test "Deny answers to the client and does not depend on the page's language", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      answer = decide(browser(user), id, %{"decision" => "deny"}, "lang=ru")
      assert answer.status == 302
      assert %{"error" => "access_denied"} = location_params(answer)
      refute location(answer) =~ "lang="
    end

    test "the page at the ceiling and the disconnect round trip keep it", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      put_setting("api_oauth_grants_per_person", "1")
      code_for(user, client, [@read])
      id = request_id(client, challenge)
      [grant] = Grants.list_live(user.uuid)

      page = consent(with_header(browser(user), "et"), id, "lang=ru")
      html = doc(page)
      assert html_lang(page) == "ru"
      assert title(page) == translate("ru", "Too many connections")

      assert Floki.attribute(html, "#limit-back", "href") == [
               path("/consent/" <> id) <> "?lang=ru"
             ]

      assert Floki.attribute(html, "#grant-#{grant.uuid} form", "action") == [
               path("/consent/" <> id <> "/revoke") <> "?lang=ru"
             ]

      asked = disconnect(browser(user), id, %{"grant" => grant.uuid}, "lang=ru")
      assert asked.status == 200
      assert html_lang(asked) == "ru"
      assert title(asked) == translate("ru", "Disconnect this application?")

      assert doc(asked) |> Floki.attribute("#disconnect-confirm-form", "action") == [
               path("/consent/" <> id <> "/revoke") <> "?lang=ru"
             ]

      assert doc(asked) |> Floki.attribute("#disconnect-cancel", "href") == [
               path("/consent/" <> id) <> "?lang=ru"
             ]

      assert [] = doc(asked) |> Floki.find("#language-switcher")

      done =
        disconnect(browser(user), id, %{"grant" => grant.uuid, "confirm" => "yes"}, "lang=ru")

      assert redirected_to(done, 302) == path("/consent/" <> id) <> "?lang=ru"
      assert %DateTime{} = Repo.reload!(grant).revoked_at

      # Back on the request, still in Russian.
      back = consent(browser(user), id, "lang=ru")
      assert_in(back, "ru", "ru")
      assert [_] = doc(back) |> Floki.find("#consent-form")
    end

    test "a disconnect without a chosen language redirects without one", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      put_setting("api_oauth_grants_per_person", "1")
      code_for(user, client, [@read])
      id = request_id(client, challenge)
      [grant] = Grants.list_live(user.uuid)

      done =
        disconnect(with_header(browser(user), "ru"), id, %{
          "grant" => grant.uuid,
          "confirm" => "yes"
        })

      assert redirected_to(done, 302) == path("/consent/" <> id)
    end

    test "the refusal of a person who may not connect is in the chosen language too", %{
      client: client,
      challenge: challenge
    } do
      {user, _role} = KeyTestSupport.user_without_api(["dashboard"])
      id = request_id(client, challenge)

      page = consent(browser(user), id, "lang=ru")
      assert page.status == 403
      assert title(page) == translate("ru", "You cannot connect applications")
      assert html_lang(page) == "ru"
    end
  end

  describe "the authorize endpoint" do
    test "an error page is in the language of the lang parameter, then of the header", %{
      client: client,
      challenge: challenge
    } do
      params = authorize_params(client, challenge, %{"client_id" => "no-such-client"})

      page = authorize(browser(), Map.put(params, "lang", "ru"))
      assert page.status == 400
      assert html_lang(page) == "ru"
      assert title(page) == translate("ru", "This connection cannot be started")

      page = authorize(with_header(browser(), "ru, et;q=0.5"), params)
      assert html_lang(page) == "ru"

      page = authorize(with_header(browser(), "ru"), Map.put(params, "lang", "en-US"))
      assert html_lang(page) == "en-US"
      assert title(page) == translate("en", "This connection cannot be started")

      page = authorize(browser(), params)
      assert html_lang(page) == "et"
    end

    test "the person's profile is not read there: nobody is asked who they are", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      params = authorize_params(client, challenge, %{"client_id" => "no-such-client"})
      page = authorize(browser(prefer(user, "ru")), params)
      assert html_lang(page) == "et"
    end

    test "a refused request offers the same request in each language, once", %{
      client: client,
      challenge: challenge
    } do
      params =
        authorize_params(client, challenge, %{"client_id" => "no-such-client", "lang" => "ru"})

      page = authorize(browser(), params)
      html = doc(page)

      for code <- ~w(et ru en-US) do
        assert [href] = Floki.attribute(html, "#language-#{code}", "href")
        assert %URI{path: path, query: query} = URI.parse(href)
        assert path == path("/authorize")
        decoded = URI.decode_query(query)
        assert decoded["lang"] == code
        assert decoded["client_id"] == "no-such-client"
        assert decoded["state"] == params["state"]
        assert length(String.split(query, "lang=")) == 2
      end

      assert Floki.attribute(html, "a[aria-current]", "id") == ["language-ru"]
    end

    test "a lang parameter does not make a valid request an error", %{
      client: client,
      challenge: challenge
    } do
      answer = authorize(browser(), authorize_params(client, challenge, %{"lang" => "ru"}))
      assert answer.status == 302
    end
  end

  describe "headers" do
    test "the pages vary on Accept-Language and stay out of every cache", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)

      for page <- [
            consent(browser(user), id),
            consent(browser(user), String.duplicate("a", 43)),
            authorize(browser(), %{})
          ] do
        assert get_resp_header(page, "vary") |> Enum.join(",") =~ "Accept-Language"
        assert get_resp_header(page, "cache-control") == ["no-store"]
      end
    end
  end

  test "the language plug leaves a conn it did not run on alone" do
    assert Language.assigns(Plug.Test.conn(:get, "/"), "/x") == %{}
    assert Language.url(Plug.Test.conn(:get, "/"), "/x") == "/x"
  end

  defp gettext_of("en-US"), do: "en"
  defp gettext_of(code), do: code
end
