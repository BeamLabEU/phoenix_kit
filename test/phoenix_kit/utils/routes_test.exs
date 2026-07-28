defmodule PhoenixKit.Utils.RoutesTest do
  use ExUnit.Case

  alias PhoenixKit.Utils.Routes

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

    test "dialect-shaped locale code keeps its prefix verbatim" do
      # Full dialect codes (e.g. en-US) shouldn't ever reach the helper —
      # callers normalise to base via DialectMapper first — but if they
      # do, the helper passes them through unchanged. Pinning this so a
      # future "smart-strip" refactor doesn't accidentally treat
      # "en-US" the same as "en" and drop the prefix.
      assert Routes.admin_path("/admin/users", "en-US") == "/phoenix_kit/en-US/admin/users"
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
  end
end
