defmodule PhoenixKit.Integration.Users.AuthLocaleTest do
  @moduledoc """
  Pins the locale-aware redirect behaviour in
  `PhoenixKitWeb.Users.Auth`:

    * `redirect_invalid_locale/2` — swap-vs-strip behaviour gated on
      `Languages.default_language_no_prefix?/0`.
    * `process_valid_locale/2`'s canonical redirect — only fires for
      non-admin primary-locale URLs when the setting is ON.

  Both behaviours need a DB-backed setting for the gate to read, so
  this file uses `DataCase` rather than the no-DB unit
  `auth_test.exs`.
  """

  use PhoenixKit.DataCase, async: false

  import Phoenix.ConnTest

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.Users.Auth

  # What Plug sends on any response that sets no cache-control of its own.
  @plug_default_cache "max-age=0, private, must-revalidate"

  setup do
    config = %{
      "languages" => [
        %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true},
        %{"code" => "es", "name" => "Spanish", "is_default" => false, "is_enabled" => true}
      ]
    }

    Settings.update_setting("languages_enabled", "true")
    Settings.update_json_setting("languages_config", config)

    on_exit(fn ->
      # Use the typed setter (mirrors the `setup` block in the
      # `setting ON` describe further down) so any future cache /
      # invalidation logic Languages.set_* wires up runs in cleanup
      # too — the raw Settings call would skip it.
      Languages.set_default_language_no_prefix(false)
      Settings.update_setting("languages_enabled", "false")
    end)

    :ok
  end

  describe "redirect_invalid_locale/2 with setting OFF (default)" do
    test "swaps invalid locale for the primary base code (preserves prefixed canonical shape)" do
      conn = build_invalid_locale_conn("/phoenix_kit/xx/admin/users")

      conn = Auth.redirect_invalid_locale(conn, "xx")

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/en/admin/users"
    end

    test "handles invalid locale at the end of the path" do
      conn = build_invalid_locale_conn("/phoenix_kit/xx")

      conn = Auth.redirect_invalid_locale(conn, "xx")

      assert redirected_to(conn) == "/phoenix_kit/en"
    end

    test "handles a non-ASCII invalid locale at the end of the path" do
      conn = build_invalid_locale_conn("/phoenix_kit/" <> URI.encode("дордол"))

      conn = Auth.redirect_invalid_locale(conn, "дордол")

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/en"
    end

    test "carries the query string across the redirect" do
      conn = build_invalid_locale_conn("/phoenix_kit/xx/admin/users?return_to=%2Fadmin%2Fx")

      conn = Auth.redirect_invalid_locale(conn, "xx")

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/en/admin/users?return_to=%2Fadmin%2Fx"
    end

    test "stays inside a Plug.forward mount when redirecting" do
      # `conn.path_info` is router-relative; a router reached through
      # `Plug.forward` (e.g. a `/tenant` mount) carries the mount
      # segments in `conn.script_name` instead, and `request_path`
      # still carries the full incoming path. Build both by hand the
      # way `Plug.forward` would leave them.
      conn =
        build_invalid_locale_conn("/tenant/phoenix_kit/xx/admin/users")
        |> Map.put(:script_name, ["tenant"])
        |> Map.put(:path_info, ["phoenix_kit", "xx", "admin", "users"])

      conn = Auth.redirect_invalid_locale(conn, "xx")

      assert conn.halted
      assert redirected_to(conn) == "/tenant/phoenix_kit/en/admin/users"
    end

    test "a dot-segment in `rest` does not silently escape the mount prefix" do
      # `/phoenix_kit/zz/../../shop` is an entirely ordinary invalid-locale
      # request ("zz" is the only thing wrong with it) — `rest` is
      # client-supplied path content, `["..", "..", "shop"]`. Not caught by
      # Phoenix's own local-path validation at all (dot-segments aren't on
      # its char list), but a browser resolves them per RFC 3986 §5.2.4
      # before navigating: swapping "zz" for "en" would rebuild
      # "/phoenix_kit/en/../../shop", which a browser collapses to "/shop"
      # — outside "/phoenix_kit" entirely. `unsafe_redirect_target?/1`'s
      # dot-segment check declines this rather than redirecting there.
      conn = build_invalid_locale_conn("/phoenix_kit/zz/../../shop")

      conn = Auth.redirect_invalid_locale(conn, "zz")

      refute conn.halted
      assert conn.assigns.current_locale_base == "en"
    end

    test "a single-percent-encoded '%2E%2E' segment in `rest` is also treated as a dot-segment" do
      # `conn.path_info` stays exactly as the client sent it for content
      # this module doesn't touch — a literal "%2E%2E" segment survives
      # into `rest` completely unmodified (Phoenix only decodes the segment
      # bound to the `:locale` route parameter, never the rest of
      # `path_info`). Undecoded, "%2E%2E" is six harmless printable
      # characters; a browser (or any downstream consumer that decodes the
      # `Location` header before resolving dot-segments) would read it as
      # "..". `dot_segment?/1` decodes each segment one more time before
      # comparing, the same "check what it would become" technique this
      # module already uses for the `%09`-as-text bug.
      conn = build_invalid_locale_conn("/phoenix_kit/zz/%2E%2E/shop")

      conn = Auth.redirect_invalid_locale(conn, "zz")

      refute conn.halted
      assert conn.assigns.current_locale_base == "en"
    end
  end

  describe "redirect_to_base_locale/2 — Plug.forward mount" do
    test "stays inside a Plug.forward mount when redirecting" do
      conn =
        build_invalid_locale_conn("/tenant/phoenix_kit/en-US/admin/users")
        |> Map.put(:script_name, ["tenant"])
        |> Map.put(:path_info, ["phoenix_kit", "en-US", "admin", "users"])

      conn = Auth.redirect_to_base_locale(conn, "en-US")

      assert conn.halted
      assert redirected_to(conn) == "/tenant/phoenix_kit/en/admin/users"
    end
  end

  describe "redirect_invalid_locale/2 with setting ON" do
    setup do
      Languages.set_default_language_no_prefix(true)
      :ok
    end

    test "strips the invalid locale entirely (canonical is prefixless)" do
      conn = build_invalid_locale_conn("/phoenix_kit/xx/admin/users")

      conn = Auth.redirect_invalid_locale(conn, "xx")

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/admin/users"
    end

    test "handles invalid locale at the end of the path (strips to bare prefix)" do
      conn = build_invalid_locale_conn("/phoenix_kit/xx")

      conn = Auth.redirect_invalid_locale(conn, "xx")

      # With setting ON, the invalid trailing segment is stripped
      # entirely, leaving the bare PhoenixKit URL prefix.
      assert redirected_to(conn) == "/phoenix_kit"
    end

    test "handles a non-ASCII invalid locale at the end of the path (strips to bare prefix)" do
      conn = build_invalid_locale_conn("/phoenix_kit/" <> URI.encode("дордол"))

      conn = Auth.redirect_invalid_locale(conn, "дордол")

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit"
    end
  end

  describe "redirect_invalid_locale/2 — non-ASCII locale segment (#849)" do
    test "never redirects to itself for a percent-encoded non-ASCII locale" do
      # `conn.request_path`/`path_info` are percent-encoded, but the
      # `locale` argument (like `conn.path_params["locale"]` in
      # production) is the DECODED value Phoenix router binding
      # actually produces. The old `String.replace`-based
      # implementation matched the raw Cyrillic against the still
      # encoded request path, never found it, and redirected to the
      # unchanged original path — a browser-visible "too many
      # redirects" loop (verified against the pre-fix implementation:
      # `String.replace/3` leaves the encoded path untouched, so
      # `corrected_path == conn.request_path`).
      raw_locale = "дордол"
      request_path = "/" <> URI.encode(raw_locale) <> "/shop"

      conn =
        build_conn(:get, request_path)
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => raw_locale})

      conn = Auth.redirect_invalid_locale(conn, raw_locale)

      # This bare top-level path carries no `/phoenix_kit` prefix, so
      # `locale_segment_path/3` cannot locate the locale segment and
      # returns :error — the plug declines to redirect (which would
      # have bounced the browser back to itself) and falls through to
      # the default locale instead. The custom message keeps the
      # pre-fix failure diagnostic: against the old code this conn IS
      # halted, redirected straight back to `request_path`.
      refute conn.halted,
             "declined redirect expected; got a redirect to #{if conn.halted, do: redirected_to(conn)}"

      assert conn.assigns.current_locale_base == "en"
    end
  end

  describe "validate_and_set_locale/2 — percent-encoded default-locale segment (setting ON)" do
    setup do
      Languages.set_default_language_no_prefix(true)
      :ok
    end

    test "an encoded ASCII locale still triggers the canonical clean-URL redirect" do
      # Percent-encoding an entirely ASCII locale segment reproduces the
      # same class of bug as the non-ASCII case: `/phoenix_kit/%65n/shop`
      # binds `path_params["locale"] == "en"` but `conn.request_path`
      # still holds the encoded "%65n", so a plain `String.replace`
      # against the decoded locale is a no-op and would have looped.
      conn =
        build_conn(:get, "/phoenix_kit/%65n/shop")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn = Auth.validate_and_set_locale(conn, [])

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/shop"
    end

    test "a hostile segment in `rest` does not raise through redirect_default_locale_to_clean_url/2" do
      # This function reaches `locale_segment_path/3` via a different
      # caller than `redirect_invalid_locale/2`/`redirect_to_base_locale/2`,
      # but the same pre-existing `rest`-based landmine applies: "en" itself
      # is the ordinary, canonical primary locale (nothing hostile about the
      # locale segment being rewritten), the hostile content sits entirely
      # in a LATER segment. Root `url_prefix` — the actual production
      # configuration — is what makes the literal "/%09" substring land at
      # the very front of the rebuilt path.
      with_url_prefix("/", fn ->
        conn =
          build_conn(:get, "/en/%09evil/shop")
          |> Plug.Conn.fetch_query_params()
          |> Map.put(:path_params, %{"locale" => "en"})

        conn = Auth.validate_and_set_locale(conn, [])

        refute conn.halted
        assert conn.assigns.current_locale_base == "en"
      end)
    end
  end

  describe "validate_and_set_locale/2 — primary-locale canonical redirect" do
    # `process_valid_locale/2` (private) decides whether to redirect
    # `/<default>/<non-admin>` to `/<non-admin>` so there's one canonical
    # URL when the site-wide setting is ON. With setting OFF (default)
    # the `/<default>/...` shape IS canonical and must NOT redirect —
    # the redirect would discard POST bodies. Reference incident: the bug
    # that broke login mid-browser-test before this gate was added.

    test "primary locale on non-admin URL is NOT redirected when setting is OFF" do
      conn =
        build_conn(:get, "/phoenix_kit/en/users/log-in")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn = Auth.validate_and_set_locale(conn, [])

      refute conn.halted
      assert conn.status != 301
      assert conn.assigns.current_locale_base == "en"
    end

    test "primary locale on non-admin URL IS redirected when setting is ON" do
      Languages.set_default_language_no_prefix(true)

      conn =
        build_conn(:get, "/phoenix_kit/en/users/log-in")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn = Auth.validate_and_set_locale(conn, [])

      assert conn.halted
      # The status (302 unless the host opts in) is pinned by the
      # `:default_locale_redirect` tests below; this one pins the target.
      assert redirected_to(conn) == "/phoenix_kit/users/log-in"
    end

    test "the redirect is a 302 with Plug's default cache header unless the host opts in" do
      Languages.set_default_language_no_prefix(true)

      conn = Auth.validate_and_set_locale(primary_locale_conn(:get), [])

      assert conn.halted
      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "cache-control") == [@plug_default_cache]
    end

    test "an opted-in host gets a permanent redirect cached for max_age on GET and HEAD" do
      Languages.set_default_language_no_prefix(true)
      put_redirect_config(status: 301, max_age: 3600)

      for method <- [:get, :head] do
        conn = Auth.validate_and_set_locale(primary_locale_conn(method), [])

        assert conn.halted
        assert redirected_to(conn, 301) == "/phoenix_kit/users/log-in"
        assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
      end
    end

    test "atom statuses are accepted, and max_age 0 is kept" do
      Languages.set_default_language_no_prefix(true)

      put_redirect_config(status: :moved_permanently, max_age: 0)
      conn = Auth.validate_and_set_locale(primary_locale_conn(:get), [])
      assert redirected_to(conn, 301) == "/phoenix_kit/users/log-in"
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=0"]

      put_redirect_config(status: :permanent_redirect)
      conn = Auth.validate_and_set_locale(primary_locale_conn(:get), [])
      assert redirected_to(conn, 308) == "/phoenix_kit/users/log-in"
    end

    test "a config that isn't a keyword list, or an unknown atom, keeps the 302" do
      Languages.set_default_language_no_prefix(true)

      for config <- [%{status: 301}, 301, true, [status: :not_a_status]] do
        put_redirect_config(config)
        conn = Auth.validate_and_set_locale(primary_locale_conn(:get), [])

        assert conn.status == 302
        assert Plug.Conn.get_resp_header(conn, "cache-control") == [@plug_default_cache]
      end
    end

    test "a misconfigured option is logged once, not per request" do
      Languages.set_default_language_no_prefix(true)
      put_redirect_config(status: 307)
      :persistent_term.erase({Auth, :default_locale_redirect_warned})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..3, do: Auth.validate_and_set_locale(primary_locale_conn(:get), [])
        end)

      assert length(String.split(log, ":default_locale_redirect must be")) == 2
    end

    test "308 is accepted, and a missing or invalid max_age falls back to one day" do
      Languages.set_default_language_no_prefix(true)

      for opts <- [[status: 308], [status: 308, max_age: -1], [status: 308, max_age: "1h"]] do
        put_redirect_config(opts)
        conn = Auth.validate_and_set_locale(primary_locale_conn(:get), [])

        assert redirected_to(conn, 308) == "/phoenix_kit/users/log-in"
        assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=86400"]
      end
    end

    test "other methods and unsupported statuses keep the 302" do
      Languages.set_default_language_no_prefix(true)

      put_redirect_config(status: 301)
      conn = Auth.validate_and_set_locale(primary_locale_conn(:post), [])
      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "cache-control") == [@plug_default_cache]

      put_redirect_config(status: 307)
      conn = Auth.validate_and_set_locale(primary_locale_conn(:get), [])
      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "cache-control") == [@plug_default_cache]
    end

    test "primary locale on admin URL is NEVER redirected (both settings)" do
      # Admin paths share a dual-scope router emission; both shapes
      # resolve to the same live_session so a redirect would create a
      # wasteful round-trip mid-session.

      conn_off =
        build_conn(:get, "/phoenix_kit/en/admin/users")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn_off = Auth.validate_and_set_locale(conn_off, [])
      refute conn_off.halted

      Languages.set_default_language_no_prefix(true)

      conn_on =
        build_conn(:get, "/phoenix_kit/en/admin/users")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn_on = Auth.validate_and_set_locale(conn_on, [])
      refute conn_on.halted
    end

    test "non-primary locale on non-admin URL is never redirected" do
      conn =
        build_conn(:get, "/phoenix_kit/es/blog/post")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "es"})

      conn = Auth.validate_and_set_locale(conn, [])

      refute conn.halted
      assert conn.assigns.current_locale_base == "es"
    end
  end

  describe "validate_and_set_locale/2 — reserved segments" do
    test "a reserved segment 307s to the stripped path, query intact" do
      # `/<prefix>/api/shop` binds `:locale = "api"` on any `/:locale/...`
      # route. The corrected URL has to keep the query — this pipeline
      # also carries `post "/:locale/users/log-in"`, which is why the
      # redirect is a 307 (method + body preserved) rather than a 302.
      conn =
        build_conn(:get, "/phoenix_kit/api/shop?page=2")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "api"})

      conn = Auth.validate_and_set_locale(conn, [])

      assert conn.halted
      assert conn.status == 307
      assert redirected_to(conn, 307) == "/phoenix_kit/shop?page=2"
    end

    test "a hostile segment in `rest` does not raise on the reserved-segment 307 path" do
      # `process_as_default_locale/1` goes through `strip_locale_segment/2`
      # (a thin wrapper over `locale_segment_path/3`) — the same
      # `rest`-based landmine as the other three functions applies here
      # too, under the default NAMED `url_prefix` this file otherwise uses
      # throughout.
      conn =
        build_conn(:get, "/phoenix_kit/api/%09evil/shop")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "api"})

      conn = Auth.validate_and_set_locale(conn, [])

      refute conn.halted
      assert conn.assigns.current_locale_base == "en"
    end

    test "a segment that is not where the prefix says renders instead of looping" do
      # `strip_locale_segment/2` returns :error when the path is not
      # `<prefix>/<locale>/...`, and the plug must then fall through.
      # Redirecting to an unchanged path is what used to spin the browser.
      conn =
        build_conn(:get, "/somewhere/else/entirely")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "admin"})

      conn = Auth.validate_and_set_locale(conn, [])

      refute conn.halted
      assert conn.assigns.current_locale_base == "en"
    end
  end

  describe "validate_and_set_locale/2 — percent-encoded admin segment" do
    setup do
      Languages.set_default_language_no_prefix(true)
      :ok
    end

    test "an encoded /admin still counts as an admin request" do
      # Phoenix binds routes against a DECODED copy of the path but leaves
      # `conn.path_info` encoded, so `%61dmin` reaches the admin route
      # while a raw `"admin" in path_info` reports "not admin" and hands
      # the request to the canonicaliser — a redirect on a URL that is
      # already where it belongs.
      conn =
        build_conn(:get, "/phoenix_kit/en/%61dmin/users")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn = Auth.validate_and_set_locale(conn, [])

      refute conn.halted
    end

    test "the canonical redirect still fires for genuinely non-admin URLs, with its query" do
      conn =
        build_conn(:get, "/phoenix_kit/en/users/log-in?return_to=%2Fadmin%2Fusers")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en"})

      conn = Auth.validate_and_set_locale(conn, [])

      assert conn.halted
      assert redirected_to(conn) == "/phoenix_kit/users/log-in?return_to=%2Fadmin%2Fusers"
    end
  end

  describe "enabled full-dialect locale segments" do
    # Sibling-dialect public URLs (phoenix_kit_publishing): when two dialects
    # of one base are enabled (en-US + en-GB), the non-primary sibling is
    # addressed by its lowercase full code (/en-gb/...). The plug used to
    # 301 EVERY hyphenated segment to its base, which made those URLs
    # structurally impossible — an enabled dialect must process, matched
    # case-insensitively; any other hyphenated segment keeps the redirect.

    setup do
      config = %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English (US)",
            "is_default" => true,
            "is_enabled" => true
          },
          %{
            "code" => "en-GB",
            "name" => "English (UK)",
            "is_default" => false,
            "is_enabled" => true
          },
          %{"code" => "es", "name" => "Spanish", "is_default" => false, "is_enabled" => true}
        ]
      }

      Settings.update_json_setting("languages_config", config)
      :ok
    end

    test "a lowercase enabled dialect processes with the stored-case locale" do
      conn =
        build_conn(:get, "/phoenix_kit/en-gb/blog")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en-gb"})

      conn = Auth.validate_and_set_locale(conn, [])

      refute conn.halted
      assert conn.assigns.current_locale == "en-GB"
      assert conn.assigns.current_locale_base == "en"
    end

    test "the stored-case form processes identically" do
      conn =
        build_conn(:get, "/phoenix_kit/en-GB/blog")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "en-GB"})

      conn = Auth.validate_and_set_locale(conn, [])

      refute conn.halted
      assert conn.assigns.current_locale == "en-GB"
    end

    test "a NON-enabled dialect keeps the historical redirect to its base" do
      conn =
        build_conn(:get, "/phoenix_kit/es-MX/blog")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:path_params, %{"locale" => "es-MX"})

      conn = Auth.validate_and_set_locale(conn, [])

      assert conn.halted
      assert redirected_to(conn) =~ "/es/"
    end
  end

  describe "redirect_invalid_locale/2 and redirect_to_base_locale/2 — ROOT url_prefix" do
    # Every test above runs under `url_prefix: "/phoenix_kit"`
    # (`config/config.exs`), but BOTH live apps mount PhoenixKit at the
    # ROOT ("/"): hydroforce configures `url_prefix: "/"`, decor
    # `url_prefix: ""` (normalized to "/" — see `compute_url_prefix/0`).
    # That is the configuration #849 was actually reported against, and
    # it exercises a distinct branch of `locale_segment_path/3`:
    # `prefix_segments == []`, so the locale has to sit at `path_info`
    # index 0 rather than after a named prefix segment.
    #
    # `url_prefix` is cached in `:persistent_term` (same as `admin_path`
    # in `PhoenixKit.Utils.AdminSegmentTest`), so it's flipped through
    # the public `PhoenixKit.Config.clear_url_prefix_cache/0` API rather
    # than poking the cache directly — `with_url_prefix/2` (module level,
    # alongside `build_invalid_locale_conn/1`) mirrors that file's
    # `with_segment/2` helper.

    test "the literal #849 URL redirects away instead of looping (setting OFF)" do
      with_url_prefix("/", fn ->
        request_path = "/" <> URI.encode("дордол") <> "/shop"
        conn = locale_conn(request_path, "дордол")

        conn = Auth.redirect_invalid_locale(conn, "дордол")

        assert conn.halted
        assert redirected_to(conn) == "/en/shop"
      end)
    end

    test "the literal #849 URL redirects away instead of looping (setting ON)" do
      with_url_prefix("/", fn ->
        Languages.set_default_language_no_prefix(true)
        request_path = "/" <> URI.encode("дордол") <> "/shop"
        conn = locale_conn(request_path, "дордол")

        conn = Auth.redirect_invalid_locale(conn, "дордол")

        assert conn.halted
        assert redirected_to(conn) == "/shop"
      end)
    end

    test "a locale-only root path strips to '/', not an empty string" do
      with_url_prefix("/", fn ->
        Languages.set_default_language_no_prefix(true)
        request_path = "/" <> URI.encode("дордол")
        conn = locale_conn(request_path, "дордол")

        conn = Auth.redirect_invalid_locale(conn, "дордол")

        assert conn.halted
        assert redirected_to(conn) == "/"
      end)
    end

    test "a locale-only root path swaps to the default base, not strips (setting OFF)" do
      with_url_prefix("/", fn ->
        request_path = "/" <> URI.encode("дордол")
        conn = locale_conn(request_path, "дордол")

        conn = Auth.redirect_invalid_locale(conn, "дордол")

        assert conn.halted
        assert redirected_to(conn) == "/en"
      end)
    end

    test "a dialect redirect at root drops the prefix, not just the dialect" do
      with_url_prefix("/", fn ->
        conn = locale_conn("/en-US/blog", "en-US")

        conn = Auth.redirect_to_base_locale(conn, "en-US")

        assert conn.halted
        assert redirected_to(conn) == "/en/blog"
      end)
    end

    test "a locale at a non-first path index is not matched (positional, not substring)" do
      with_url_prefix("/", fn ->
        # `/shop/xx` binds `locale` at index 1, not 0. Using an invalid
        # locale that DIFFERS from the default base ("en") makes this
        # fixture actually discriminate: a substring implementation
        # would still find "/xx" in the path and redirect to
        # "/shop/en", while the positional match at index 0 finds
        # "shop" there instead of "xx" and declines. (A same-as-default
        # locale like "en" would make the replacement equal the
        # original segment, so even a substring implementation would
        # produce an unchanged path and this test would pass either
        # way — it would prove the guardrail, not positionality.)
        conn = locale_conn("/shop/xx", "xx")

        conn = Auth.redirect_invalid_locale(conn, "xx")

        refute conn.halted
        assert conn.assigns.current_locale_base == "en"
      end)
    end

    test "declines to redirect when the :ok branch itself produces an unchanged path" do
      with_url_prefix("/", fn ->
        # Setting OFF → the replacement segment for an "invalid" locale
        # IS the default base code. Calling this with `invalid_locale ==
        # default_base` makes `locale_segment_path/3` succeed (`:ok`)
        # with a path identical to the request — the guardrail has to
        # catch this branch too, not just the helper's `:error` branch.
        conn = locale_conn("/en/shop", "en")

        conn = Auth.redirect_invalid_locale(conn, "en")

        refute conn.halted
        assert conn.assigns.current_locale_base == "en"
      end)
    end

    # Pre-existing landmine, not introduced by the #849 fix: `rest` (every
    # path segment AFTER the locale, spliced RAW into the redirect target
    # by design, to preserve whatever encoding the client sent there) was
    # never validated at all. A perfectly ordinary invalid locale ("zz")
    # with a hostile LATER segment reproduces the same literal "/%09"
    # substring `Phoenix.Controller.redirect/2` refuses — nothing about
    # `replacement_segments`/`safe_path_segment?/1` touches this, since
    # `rest` never passes through that guard. Only the final-joined-path
    # check (`unsafe_redirect_target?/1`) catches it.
    test "a hostile segment in `rest` does not raise even with an ordinary invalid locale" do
      with_url_prefix("/", fn ->
        conn = locale_conn("/zz/%09evil/shop", "zz")

        conn = Auth.redirect_invalid_locale(conn, "zz")

        refute conn.halted
        assert conn.assigns.current_locale_base == "en"
      end)
    end

    test "redirect_to_base_locale/2 also declines rather than crashes on a hostile `rest` segment" do
      with_url_prefix("/", fn ->
        # "en-US" is itself a perfectly fine, enabled dialect (base "en") —
        # `replacement_segments` is `["en"]`, which sails through
        # `safe_path_segment?/1` untouched. The hostile content sits
        # entirely in `rest`, same as the test above.
        conn = locale_conn("/en-US/%09evil/shop", "en-US")

        conn = Auth.redirect_to_base_locale(conn, "en-US")

        refute conn.halted
        assert conn.assigns.current_locale_base == "en"
      end)
    end
  end

  describe "redirect_to_base_locale/2 — no-redirect fallback locale" do
    # When the dialect segment is not where the url_prefix says (so no
    # redirect can be built), the request renders un-halted. It may keep
    # the requested language only when that base would have been accepted
    # as a bare `/<base>/...` segment — predefined AND enabled. The setup
    # above enables en + es only.

    test "keeps an enabled base" do
      conn = build_invalid_locale_conn("/shop/es-MX") |> Auth.redirect_to_base_locale("es-MX")

      refute conn.halted
      assert conn.assigns.current_locale_base == "es"
    end

    test "falls back to the default for a predefined but disabled base" do
      conn = build_invalid_locale_conn("/shop/fr-CA") |> Auth.redirect_to_base_locale("fr-CA")

      refute conn.halted
      assert conn.assigns.current_locale_base == "en"
    end

    test "falls back to the default for an unknown base" do
      conn = build_invalid_locale_conn("/shop/zz-QQ") |> Auth.redirect_to_base_locale("zz-QQ")

      refute conn.halted
      assert conn.assigns.current_locale_base == "en"
    end
  end

  defp build_invalid_locale_conn(path) do
    build_conn(:get, path)
    |> Plug.Conn.fetch_query_params()
  end

  defp with_url_prefix(value, fun) do
    previous = Application.fetch_env(:phoenix_kit, :url_prefix)
    Application.put_env(:phoenix_kit, :url_prefix, value)
    Config.clear_url_prefix_cache()

    try do
      fun.()
    after
      case previous do
        {:ok, prior} -> Application.put_env(:phoenix_kit, :url_prefix, prior)
        :error -> Application.delete_env(:phoenix_kit, :url_prefix)
      end

      Config.clear_url_prefix_cache()
    end
  end

  defp locale_conn(path, locale) do
    build_conn(:get, path)
    |> Plug.Conn.fetch_query_params()
    |> Map.put(:path_params, %{"locale" => locale})
  end

  defp primary_locale_conn(method) do
    build_conn(method, "/phoenix_kit/en/users/log-in")
    |> Plug.Conn.fetch_query_params()
    |> Map.put(:path_params, %{"locale" => "en"})
  end

  defp put_redirect_config(opts) do
    previous = Application.fetch_env(:phoenix_kit, :default_locale_redirect)
    Application.put_env(:phoenix_kit, :default_locale_redirect, opts)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :default_locale_redirect, value)
        :error -> Application.delete_env(:phoenix_kit, :default_locale_redirect)
      end
    end)
  end
end
