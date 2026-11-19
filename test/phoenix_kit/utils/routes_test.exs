defmodule PhoenixKit.Utils.RoutesTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKit.Utils.Routes

  # Locale segments only exist on a multilingual site; with nothing configured
  # the switch reads as off and no URL carries one (see
  # `single_language_routes_test.exs`).
  setup do
    LanguageSettings.multilingual!()
  end

  # All assertions below assume the default language resolves to "en".
  # `Routes.get_default_language_base/0` rescues any DB lookup failure and
  # falls back to "en", so these tests run without a connected database.
  #
  # `Routes.prefixless_primary?/0` (the new gate on primary-language
  # stripping) ALSO rescues into `false` when no DB is reachable, so this
  # whole file exercises the "setting is OFF" branch of the new
  # site-wide `default_language_no_prefix` behaviour. The "setting is ON"
  # branch is covered by the integration tests in
  # `test/phoenix_kit/modules/languages/default_language_no_prefix_test.exs`
  # (DB-backed).

  describe "admin_path/2 — primary-language prefix (setting OFF, the default)" do
    test "primary locale (en) KEEPS its prefix" do
      assert Routes.admin_path("/admin/users", "en") == "/phoenix_kit/en/admin/users"
    end

    test "non-primary locale keeps its prefix" do
      assert Routes.admin_path("/admin/users", "de") == "/phoenix_kit/de/admin/users"
      assert Routes.admin_path("/admin/users", "fr") == "/phoenix_kit/fr/admin/users"
    end

    test "nil locale falls back to no prefix (no locale segment)" do
      # When no locale is supplied, admin_path delegates to `path/1`. With
      # the gettext fallback set to "en" (the default), the path uses the
      # `build_path_with_locale/3` branch which respects the setting.
      # Setting OFF + primary locale = prefixed shape.
      assert Routes.admin_path("/admin/users", nil) == "/phoenix_kit/en/admin/users"
    end

    test "nested admin paths follow the same rule" do
      assert Routes.admin_path("/admin/users/edit/123", "en") ==
               "/phoenix_kit/en/admin/users/edit/123"

      assert Routes.admin_path("/admin/users/edit/123", "de") ==
               "/phoenix_kit/de/admin/users/edit/123"
    end
  end

  describe "path/2 — non-admin routes (setting OFF, the default)" do
    test "primary locale KEEPS its prefix" do
      assert Routes.path("/users/log-in", locale: "en") == "/phoenix_kit/en/users/log-in"
    end

    test "non-primary locale keeps its prefix" do
      assert Routes.path("/users/log-in", locale: "de") == "/phoenix_kit/de/users/log-in"
    end

    test ":none locale opt skips the prefix entirely" do
      assert Routes.path("/users/log-in", locale: :none) == "/phoenix_kit/users/log-in"
    end
  end

  describe "path/2 — root path locale prefixing (anonymous landing)" do
    # Regression: `Routes.path("/", locale: x)` must NOT emit a trailing
    # slash for the prefixed shape. Phoenix routers don't match a trailing
    # slash, so `/{locale}/` 404s a parent app's `/:locale` landing route.
    # The switcher's locale-rewrite default routes through this helper, so
    # this is what an anonymous visitor's language link resolves to on "/".
    test "non-primary locale on root → /{locale} (no trailing slash)" do
      assert Routes.path("/", locale: "de") == "/phoenix_kit/de"
      assert Routes.path("/", locale: "ru") == "/phoenix_kit/ru"
    end

    test "primary locale on root (setting OFF) → prefixed, still no trailing slash" do
      assert Routes.path("/", locale: "en") == "/phoenix_kit/en"
    end

    test ":none locale on root keeps the bare root" do
      assert Routes.path("/", locale: :none) == "/phoenix_kit/"
    end
  end

  describe "admin_path/2 — backcompat for legacy /en/admin URLs" do
    # Both URL shapes resolve at the router level — the admin route
    # macros declare both `/:locale/admin/*` AND `/admin/*` scopes — so
    # legacy `/phoenix_kit/en/admin/...` bookmarks still reach the page
    # regardless of the new setting. This test pins the helper-side
    # behaviour for both setting states.
    test "explicit primary locale with setting OFF → prefixed (default)" do
      assert Routes.admin_path("/admin/users", "en") == "/phoenix_kit/en/admin/users"
    end

    test "explicit non-primary locale → prefixed (legacy shape passes through)" do
      assert Routes.admin_path("/admin/users", "de") == "/phoenix_kit/de/admin/users"
    end

    test "dialect-shaped locale code is emitted as its base and keeps the prefix" do
      # en-US is not a configured dialect here, so its URL is the base
      # code's — the locale plug redirects /en-US/ there. Normalising must
      # not drop the prefix: with the setting OFF the primary keeps it.
      assert Routes.admin_path("/admin/users", "en-US") == "/phoenix_kit/en/admin/users"
    end
  end

  describe "explicit full-dialect locale — a base's only enabled dialect" do
    # The URL segment is what the locale plug serves: a base's own dialect
    # lives at its base code (the plug redirects /en-US/ to /en/).
    setup do
      LanguageSettings.put_languages(["et", "ru", "en-US"])
    end

    test "path/2 emits the base code, whatever the case" do
      assert Routes.path("/users/log-in", locale: "en-US") == "/phoenix_kit/en/users/log-in"
      assert Routes.path("/users/log-in", locale: "en-us") == "/phoenix_kit/en/users/log-in"
    end

    test "admin paths emit the base code too" do
      assert Routes.path("/admin/orders", locale: "en-US") == "/phoenix_kit/en/admin/orders"
      assert Routes.admin_path("/admin/orders", "en-US") == "/phoenix_kit/en/admin/orders"
    end

    test "a dialect that is not enabled is emitted as its base" do
      assert Routes.path("/users/log-in", locale: "en-GB") == "/phoenix_kit/en/users/log-in"
    end

    test "the prefixless-primary rule applies after normalising" do
      PhoenixKit.Cache.put(:settings, "default_language_no_prefix", "true")

      assert Routes.path("/users/log-in", locale: "et-EE") == "/phoenix_kit/users/log-in"
      assert Routes.admin_path("/admin/orders", "et-EE") == "/phoenix_kit/admin/orders"
      assert Routes.path("/users/log-in", locale: "en-US") == "/phoenix_kit/en/users/log-in"
    end

    test ":none and nil are unchanged" do
      assert Routes.path("/users/log-in", locale: :none) == "/phoenix_kit/users/log-in"
      assert Routes.admin_path("/admin/users", nil) == Routes.path("/admin/users")
    end
  end

  describe "explicit full-dialect locale — sibling dialects of one base" do
    # en-US (primary) owns /en/; the en-GB sibling is addressed by its
    # lowercase full code, the shape publishing's sibling URLs use.
    setup do
      LanguageSettings.put_languages(["en-US", "en-GB", "es"])
    end

    test "the primary dialect is emitted as its base code" do
      assert Routes.path("/blog", locale: "en-US") == "/phoenix_kit/en/blog"
    end

    test "the sibling keeps its lowercase full code" do
      assert Routes.path("/blog", locale: "en-GB") == "/phoenix_kit/en-gb/blog"
      assert Routes.path("/blog", locale: "en-gb") == "/phoenix_kit/en-gb/blog"
      assert Routes.admin_path("/admin/users", "en-GB") == "/phoenix_kit/en-gb/admin/users"
    end

    test "a base code is untouched" do
      assert Routes.path("/blog", locale: "en") == "/phoenix_kit/en/blog"
    end
  end

  describe "explicit full-dialect locale — siblings whose owner is ambiguous" do
    # en-GB is the site's primary language (content serves it at /en/) while
    # en-US is English's default dialect (core resolves /en/ to it). With the
    # two disagreeing, neither is redirected away from its full code, so both
    # keep their own URL.
    setup do
      LanguageSettings.put_languages(["en-GB", "en-US"])
    end

    test "both dialects keep their lowercase full codes" do
      assert Routes.path("/blog", locale: "en-US") == "/phoenix_kit/en-us/blog"
      assert Routes.path("/blog", locale: "en-GB") == "/phoenix_kit/en-gb/blog"
    end
  end

  describe "local_path?/1 — the open-redirect guard" do
    test "accepts ordinary local paths" do
      assert Routes.local_path?("/")
      assert Routes.local_path?("/admin/dashboard")
      assert Routes.local_path?("/checkout?step=2&x=a+b")
      assert Routes.local_path?("/ru/профиль")
      assert Routes.local_path?("/path#fragment")
    end

    test "rejects host-switching and non-path values" do
      refute Routes.local_path?("//evil.example")
      refute Routes.local_path?("/\\evil.example")
      refute Routes.local_path?("https://evil.example")
      refute Routes.local_path?("evil.example")
      refute Routes.local_path?(nil)
      refute Routes.local_path?(:not_a_string)
      refute Routes.local_path?("")
    end

    # Browsers strip tab/CR/LF while parsing a URL, so "/\t/evil.example"
    # reaches window.location as "//evil.example" — a cross-origin
    # navigation. Phoenix.Controller.redirect/2 rejects these itself, but
    # LiveView's validate_local_url! only blocks "\\" and a leading "//",
    # so this guard is the one thing standing between a LiveView
    # redirect(to: ...) and an open redirect.
    test "rejects ASCII control characters browsers strip" do
      refute Routes.local_path?("/\t/evil.example")
      refute Routes.local_path?("/\n/evil.example")
      refute Routes.local_path?("/\r/evil.example")
      refute Routes.local_path?("/\0/evil.example")
      refute Routes.local_path?("/\x7F/evil.example")
      refute Routes.local_path?("/ok/path\r\nX-Injected: 1")
    end

    test "rejects control characters anywhere in the path, not just up front" do
      refute Routes.local_path?("/legit/looking/path\t/evil.example")
    end
  end

  describe "post_auth_path/1" do
    # The settings fallback needs a DB; these cases all short-circuit on a
    # valid candidate before reaching it.
    test "returns the first candidate that passes the guard" do
      assert Routes.post_auth_path(["/checkout"]) == "/checkout"
      assert Routes.post_auth_path([nil, "/second"]) == "/second"
      assert Routes.post_auth_path(["https://evil.example", "/safe"]) == "/safe"
      assert Routes.post_auth_path(["/\t/evil.example", "/safe"]) == "/safe"
    end

    # A `?return_to=` is whatever a link contained, so it gets the same
    # loop/lockout guard the saved settings get. `/users/log-out` is the one
    # that actually hurts: it's a real GET route, so the user is signed back
    # out the instant they sign in.
    test "skips candidates that land on a sign-in page" do
      assert Routes.post_auth_path(["/users/log-out", "/safe"]) == "/safe"
      assert Routes.post_auth_path(["/users/log-in", "/safe"]) == "/safe"
      assert Routes.post_auth_path(["/et/users/register/", "/safe"]) == "/safe"
      assert Routes.post_auth_path(["/users/confirm?token=x", "/safe"]) == "/safe"
    end
  end

  describe "auth_page?/1" do
    test "matches the auth pages under any locale or mount prefix" do
      assert Routes.auth_page?("/users/log-in")
      assert Routes.auth_page?("/users/log-out")
      assert Routes.auth_page?("/app/et/users/register")
      assert Routes.auth_page?("/users/magic-link/")
      assert Routes.auth_page?("/users/qr-login#x")
      assert Routes.auth_page?("/users/reset-password?token=abc")
    end

    test "leaves ordinary destinations alone" do
      refute Routes.auth_page?("/")
      refute Routes.auth_page?("/dashboard")
      refute Routes.auth_page?("/users/settings")
      refute Routes.auth_page?(nil)
    end
  end

  describe "admin_area_path?/1" do
    # Public since module packages were hand-rolling
    # `String.contains?(path, "/admin/")` to allowlist a redirect target, which
    # gets both the lookalikes and a renamed admin segment wrong.

    test "matches a real admin URL, with or without a locale segment" do
      assert Routes.admin_area_path?("/phoenix_kit/admin")
      assert Routes.admin_area_path?("/phoenix_kit/admin/users")
      assert Routes.admin_area_path?("/phoenix_kit/et/admin/users")
    end

    test "ignores a query string or fragment" do
      assert Routes.admin_area_path?("/phoenix_kit/admin/users?page=2")
      assert Routes.admin_area_path?("/phoenix_kit/admin/users#row-3")
    end

    test "compares by segment, so lookalikes are not admin" do
      # The exact bug in the hand-rolled version: `/administrators` contains
      # "/admin" and `String.contains?/2` said yes.
      refute Routes.admin_area_path?("/phoenix_kit/administrators")
      refute Routes.admin_area_path?("/phoenix_kit/admin-tools/x")
    end

    test "leaves non-admin destinations alone" do
      refute Routes.admin_area_path?("/phoenix_kit/users/log-in")
      refute Routes.admin_area_path?("/shop")
      refute Routes.admin_area_path?("/")
    end

    test "is over-strict on a host page that happens to be named admin" do
      # Documented and deliberate: refusing `/shop/admin` as a redirect target
      # is a better failure than the loop (or open redirect) the alternative
      # invites. Pinned so the trade-off cannot be quietly reversed.
      assert Routes.admin_area_path?("/shop/admin")
    end

    test "answers false for anything that is not a binary" do
      refute Routes.admin_area_path?(nil)
      refute Routes.admin_area_path?(:admin)
      refute Routes.admin_area_path?(123)
    end
  end

  describe "path/2 — reserved prefixes never get a locale" do
    test "the API and MCP paths stay where they are, whatever locale is asked for" do
      for path <- [
            "/api/admin/v1/system.get_identity",
            "/api/public/v1/openapi.json",
            "/mcp/admin",
            "/mcp/public"
          ] do
        assert Routes.path(path, locale: "de") == Routes.prefix_base() <> path, path
        assert Routes.path(path, locale: "en") == Routes.prefix_base() <> path, path
      end
    end

    test "/oauth is the authorization server's: itself and what lies under it, not a longer name" do
      for path <- [
            "/oauth",
            "/oauth/authorize",
            "/oauth/token",
            "/oauth/consent/abc",
            "/oauth?x=1"
          ] do
        assert Routes.path(path, locale: "de") == Routes.prefix_base() <> path, path
        assert Routes.path(path, locale: "en") == Routes.prefix_base() <> path, path
      end

      for name <- ["/oauth-guide", "/oauthx"] do
        assert Routes.path(name, locale: "de") == Routes.prefix_base() <> "/de" <> name, name
      end
    end

    test "a path that is not reserved still gets its locale" do
      assert Routes.path("/shop/cart", locale: "de") == Routes.prefix_base() <> "/de/shop/cart"
    end

    test "/mcp is reserved as a path segment: itself and what lies under it, not a longer name" do
      for path <- ["/mcp", "/mcp/x", "/mcp?x=1"] do
        assert Routes.path(path, locale: "de") == Routes.prefix_base() <> path, path
      end

      for name <- ["/mcp-servers", "/mcpfoo"] do
        assert Routes.path(name, locale: "de") == Routes.prefix_base() <> "/de" <> name, name
      end
    end
  end
end
