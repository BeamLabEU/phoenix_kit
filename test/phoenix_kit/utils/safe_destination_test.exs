defmodule PhoenixKit.Utils.SafeDestinationTest do
  @moduledoc """
  Unit coverage for `Routes.safe_destination/2`, `Routes.routable?/2` and
  `Routes.main_page_path/0`.

  Deliberately plain `ExUnit.Case`: `PhoenixKit.DataCase` / `ConnCase` stamp
  `@moduletag :integration`, which auto-excludes them when no PostgreSQL is
  reachable — exactly the runs where this file is most valuable. Nothing here
  needs a database: `Scope` structs are built by hand, routers are compiled
  inline, and settings reads fall back to their supplied default when the DB is
  unreachable.
  """
  use ExUnit.Case, async: false

  # `EmptyRouter` deliberately cannot match core's own landing, which is the one
  # case the resolver logs as a misconfiguration. Expected here, so it is
  # captured rather than printed over the run.
  @moduletag :capture_log

  alias Ecto.Adapters.SQL.Sandbox

  # The chain reads settings (`main_page_path`, `after_login_path`). With no
  # database that short-circuits to nil and this file needs nothing; with one
  # reachable it becomes a real query from a process owning no sandbox
  # connection, which raises rather than returning a miss.
  #
  # `test_repo_available` is the flag test_helper.exs already sets. The repo
  # PROCESS starts even with no database — only its connections fail — so
  # `Process.whereis/1` answers the wrong question and made every test here hang
  # on a checkout that could never succeed.
  #
  # The file is written for a multilingual site (a locale segment on the
  # primary language, `LocalizedHomeRouter`), and a site with the switch off
  # emits none — so it primes the switch on, which makes the file `async:
  # false`: the settings cache is a globally named process.
  setup do
    if Application.get_env(:phoenix_kit, :test_repo_available, false) do
      :ok = Sandbox.checkout(PhoenixKit.Test.Repo)
    end

    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :settings})
    PhoenixKit.Cache.put(:settings, "languages_enabled", "true")
    :ok
  end

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  # `after_login_path` and `main_page_path` sit at the TAIL of their chains, so
  # most assertions never reach them; the ones that exhaust the chain read an
  # unset setting and get `nil`. Both hold with no database.

  # Never dispatched — `routable?/2` only asks the router whether a route
  # matches, so the plug just has to exist.
  defmodule FakeController do
    def init(opts), do: opts
    def call(conn, _opts), do: conn
  end

  defmodule HostRouter do
    use Phoenix.Router

    get "/", PhoenixKit.Utils.SafeDestinationTest.FakeController, :home
    get "/shop", PhoenixKit.Utils.SafeDestinationTest.FakeController, :shop
  end

  defmodule EmptyRouter do
    use Phoenix.Router
  end

  # A multilingual host that declared BOTH shapes of its home page — the setup
  # core's own release notes have been asking for ("the parent app declares a
  # `/:locale` landing"). The literal below is what `Routes.path("/")` emits
  # under this suite's config (`url_prefix: "/phoenix_kit"`, default locale
  # `en`); it is asserted rather than assumed in the test that uses it, so a
  # config change fails loudly instead of silently testing nothing.
  defmodule LocalizedHomeRouter do
    use Phoenix.Router

    get "/", PhoenixKit.Utils.SafeDestinationTest.FakeController, :home
    get "/phoenix_kit/en", PhoenixKit.Utils.SafeDestinationTest.FakeController, :locale_home
  end

  # A host with a profile catch-all at the root (`/:username`), which routes
  # core's bare mount point `/phoenix_kit` like any other segment.
  defmodule CatchAllRouter do
    use Phoenix.Router

    get "/", PhoenixKit.Utils.SafeDestinationTest.FakeController, :home
    get "/:username", PhoenixKit.Utils.SafeDestinationTest.FakeController, :profile
  end

  # Routes /admin (both plain and locale-prefixed) but NOT /dashboard.
  # Stands in for a host with `user_dashboard_enabled: false` that still mounts
  # the core admin area — the shape that decides where a non-admin goes when
  # their own page has been compiled out. It used to be steered away from
  # /admin (the page rejected them, so the guard bounced them into a loop);
  # `:phoenix_kit_ensure_admin` now exempts the admin index from its permission
  # checks (`PhoenixKitWeb.Users.Auth.landing_view?/1`) and greets them instead.
  #
  # The paths cover both URL shapes core emits: prefixless-primary (/phoenix_kit/admin)
  # and locale-prefixed (/phoenix_kit/:locale/admin).
  defmodule AdminOnlyRouter do
    use Phoenix.Router

    get "/phoenix_kit/admin",
        PhoenixKit.Utils.SafeDestinationTest.FakeController,
        :admin

    get "/phoenix_kit/:locale/admin",
        PhoenixKit.Utils.SafeDestinationTest.FakeController,
        :admin_locale
  end

  # Routes /admin AND /dashboard. Stands in for a host that has turned the
  # deprecated user dashboard back on with `user_dashboard_enabled: true` —
  # which is now the opt-in, not the default. `@core` below is compiled with
  # the flag off, so it is no longer the router that can exercise the
  # `/dashboard` CANDIDATE in `authenticated_candidates/1`; this one is.
  #
  # Both URL shapes, same as AdminOnlyRouter, plus the settings page used as a
  # routable non-admin `return_to` target.
  defmodule DashboardRouter do
    use Phoenix.Router

    get "/phoenix_kit/admin",
        PhoenixKit.Utils.SafeDestinationTest.FakeController,
        :admin

    get "/phoenix_kit/:locale/admin",
        PhoenixKit.Utils.SafeDestinationTest.FakeController,
        :admin_locale

    get "/phoenix_kit/:locale/admin/users",
        PhoenixKit.Utils.SafeDestinationTest.FakeController,
        :admin_users

    get "/phoenix_kit/dashboard",
        PhoenixKit.Utils.SafeDestinationTest.FakeController,
        :dashboard

    get "/phoenix_kit/:locale/dashboard",
        PhoenixKit.Utils.SafeDestinationTest.FakeController,
        :dashboard_locale
  end

  # The real core router — mounts `phoenix_kit_routes()`, so it is the oracle
  # for "does core own this path". Compiled with the shipped default
  # `user_dashboard_enabled: false`, so it does NOT route /dashboard.
  @core PhoenixKitWeb.Router

  defp conn_for(router, host \\ "localhost") do
    %Plug.Conn{private: %{phoenix_router: router}, host: host}
  end

  defp socket_for(router) do
    %Phoenix.LiveView.Socket{router: router, host_uri: URI.parse("http://localhost")}
  end

  defp anonymous, do: Scope.for_user(nil)

  defp scope(roles, permissions \\ []) do
    %Scope{
      user: nil,
      authenticated?: true,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  defp owner, do: scope(["Owner"])
  defp admin, do: scope(["Admin"])
  # A Client is a plain User who holds `client_portal` — they pass
  # `can_access_admin_area?/1` and the host routes them onward from `/admin`.
  defp client, do: scope(["User"], ["client_portal"])
  defp plain_user, do: scope(["User"])

  describe "routable?/2" do
    test "reads the router off a conn" do
      assert Routes.routable?(conn_for(HostRouter), "/shop")
      refute Routes.routable?(conn_for(HostRouter), "/nope")
    end

    test "reads the router off a socket" do
      assert Routes.routable?(socket_for(HostRouter), "/shop")
      refute Routes.routable?(socket_for(HostRouter), "/nope")
    end

    test "strips query and fragment before probing segments" do
      assert Routes.routable?(conn_for(HostRouter), "/shop?tab=1")
      assert Routes.routable?(conn_for(HostRouter), "/shop#top")
    end

    test "fails closed when the router cannot be determined" do
      refute Routes.routable?(nil, "/shop")
      refute Routes.routable?(%Plug.Conn{private: %{}, host: "localhost"}, "/shop")
      refute Routes.routable?(%Phoenix.LiveView.Socket{}, "/shop")
    end

    test "fails closed on a non-binary path" do
      refute Routes.routable?(conn_for(HostRouter), nil)
      refute Routes.routable?(conn_for(HostRouter), :shop)
    end

    test "core routes its own landings but not the locale-prefixed root" do
      assert Routes.routable?(conn_for(@core), Routes.path("/users/log-in"))
      assert Routes.routable?(conn_for(@core), Routes.path("/admin"))
      assert Routes.routable?(conn_for(@core), Routes.path("/profile/settings"))

      # NOT /dashboard: `user_dashboard_enabled` defaults to false, so the
      # route family is not compiled. A host that opts back in gets it, which
      # is what DashboardRouter stands in for.
      refute Routes.routable?(conn_for(@core), Routes.path("/dashboard"))
      assert Routes.routable?(conn_for(DashboardRouter), Routes.path("/dashboard"))

      # The shipped bug, at the router level.
      refute Routes.routable?(conn_for(@core), Routes.path("/"))
      refute Routes.routable?(conn_for(@core), "/")
    end
  end

  describe "safe_destination/2 — authenticated" do
    test "an admin-area visitor lands on /admin" do
      for s <- [owner(), admin(), client()] do
        assert Scope.can_access_admin_area?(s)
        assert Routes.safe_destination(conn_for(@core), scope: s) == Routes.path("/admin")
      end
    end

    test "a plain user lands on /admin, the guaranteed landing" do
      refute Scope.can_access_admin_area?(plain_user())

      # /dashboard is no longer routed by default, so the CANDIDATE is skipped
      # and the chain runs on to the terminal — the admin index, which
      # `landing_view?/1` opens to every authenticated visitor.
      assert Routes.safe_destination(conn_for(@core), scope: plain_user()) ==
               Routes.path("/admin")
    end

    test "a plain user still lands on /dashboard where a host opted back in" do
      # The reversibility that `user_dashboard_enabled: true` is for: the
      # candidate is probed, not assumed, so turning the routes back on
      # restores the destination as well as the page.
      assert Routes.safe_destination(conn_for(DashboardRouter), scope: plain_user()) ==
               Routes.path("/dashboard")
    end

    test "an explicit return_to wins over the role branch" do
      # /profile/settings rather than /dashboard: routed unconditionally, so it
      # is a stable non-admin target whatever `user_dashboard_enabled` says.
      assert Routes.safe_destination(conn_for(@core),
               scope: owner(),
               return_to: Routes.path("/profile/settings")
             ) == Routes.path("/profile/settings")
    end

    test "a return_to keeps its query string" do
      target = Routes.path("/profile/settings") <> "?tab=1"

      assert Routes.safe_destination(conn_for(@core), scope: owner(), return_to: target) == target
    end

    test "an unroutable return_to is skipped, not served" do
      assert Routes.safe_destination(conn_for(@core), scope: owner(), return_to: "/no/such/page") ==
               Routes.path("/admin")
    end

    test "skip_admin suppresses the /admin step — the admin-area guard case" do
      # DashboardRouter, because the assertion is that the /admin CANDIDATE is
      # skipped in favour of a LATER one. On `@core` there is no later
      # candidate left to reach, so the chain would exhaust to the terminal —
      # which is /admin, and would prove nothing about suppression.
      result =
        Routes.safe_destination(conn_for(DashboardRouter), scope: owner(), skip_admin: true)

      assert result == Routes.path("/dashboard")
      refute result =~ "/admin"
    end

    test "skip_admin refuses a return_to that points back into the admin area" do
      # Routable, and refused all the same. `skip_admin` says the caller has
      # just rejected this visitor from the admin area, so no CANDIDATE may put
      # them back into it — routability is necessary but not sufficient there,
      # because a gated admin page resolves perfectly well and then denies them,
      # re-entering this function with the same arguments.
      target = Routes.path("/admin/users")
      assert Routes.routable?(conn_for(DashboardRouter), target)

      result =
        Routes.safe_destination(conn_for(DashboardRouter),
          scope: owner(),
          return_to: target,
          skip_admin: true
        )

      refute result == target
      assert result == Routes.path("/dashboard")

      # Nothing changed off the rejection path: an explicit destination still
      # wins for a visitor nobody has refused.
      assert Routes.safe_destination(conn_for(DashboardRouter),
               scope: owner(),
               return_to: target
             ) == target
    end

    test "skip_admin is a no-op for a non-admin" do
      assert Routes.safe_destination(conn_for(DashboardRouter),
               scope: plain_user(),
               skip_admin: true
             ) == Routes.path("/dashboard")

      # And on the shipped default, where /dashboard is not routed, it is a
      # no-op in the other direction: the terminal is /admin either way.
      assert Routes.safe_destination(conn_for(@core), scope: plain_user(), skip_admin: true) ==
               Routes.path("/admin")
    end

    test "the host's own \"/\" is used when the host actually declares it" do
      # HostRouter routes `/` and nothing core owns, so every earlier candidate
      # is skipped and the home page — the destination these sites had before
      # this branch — is still reached.
      assert Routes.safe_destination(conn_for(HostRouter), scope: owner()) == "/"
      assert Routes.safe_destination(conn_for(HostRouter), scope: plain_user()) == "/"
    end

    test "a plain user IS sent to /admin when /dashboard is compiled out" do
      # AdminOnlyRouter routes /admin (both URL shapes) but NOT /dashboard.
      #
      # This asserted the opposite until /admin became the guaranteed landing.
      # The old terminal gated every /admin arm on `can_access_admin_area?`
      # because the page rejected a non-admin: the guard bounced them back with
      # `skip_admin: true`, the resolver produced the same arm, and the redirect
      # never terminated. The admin index is now exempted from both permission
      # checks by `:phoenix_kit_ensure_admin` itself
      # (`PhoenixKitWeb.Users.Auth.landing_view?/1`) and greets a visitor
      # holding no rights, so it is a legitimate landing for exactly the visitor
      # the old gate had to steer away from — and there is nothing left to
      # bounce off.
      assert Routes.safe_destination(conn_for(AdminOnlyRouter), scope: plain_user()) ==
               Routes.path("/admin")

      # `skip_admin` suppresses the /admin CANDIDATE, not the terminal. It means
      # "do not prefer the admin area"; the caller that sets it is rejecting the
      # visitor from a deeper admin page, which the index is not.
      assert Routes.safe_destination(conn_for(AdminOnlyRouter), scope: owner(), skip_admin: true) ==
               Routes.path("/admin")

      # And the candidate really is suppressed wherever another one resolves.
      assert Routes.safe_destination(conn_for(DashboardRouter), scope: owner(), skip_admin: true) ==
               Routes.path("/dashboard")
    end

    test "terminates on the guaranteed landing when nothing else resolves" do
      # EmptyRouter has no routes at all — not even `/` — so every candidate is
      # skipped, and it never called `phoenix_kit_routes()` either, so core's own
      # landings do not resolve there.
      #
      # The terminal is ASSERTED rather than probed: /admin is declared
      # unconditionally by core and admits every authenticated visitor, so there
      # is nothing to fall through to and nothing to choose between. A router
      # that cannot match it is misconfigured, and the resolver names that in
      # the log while still returning the path.
      #
      # This used to `refute` both arms, which pinned the older design where the
      # terminal was probed and could exhaust.
      for s <- [owner(), plain_user()] do
        result = Routes.safe_destination(conn_for(EmptyRouter), scope: s)

        assert result == Routes.path("/admin")

        # Never an auth page for a signed-in visitor: that page bounces them out
        # through `post_auth_path/2`, which re-enters the resolver — a loop
        # rather than a fallback.
        refute Routes.auth_page?(result)
      end

      # The anonymous terminal is licensed by a different fact — the public auth
      # surface declares /users/log-in unconditionally — so it is asserted too.
      assert Routes.safe_destination(conn_for(EmptyRouter), scope: nil) ==
               Routes.path("/users/log-in")
    end

    test "an undeterminable router still gets the guaranteed landing" do
      # `routable?/2` fails closed with no router, so no candidate can be proven
      # and the chain reaches the terminal immediately. This used to `refute`
      # both core landings, because a probed terminal could not assert one
      # either. It can now: the terminal does not depend on the router being
      # readable, only on core having declared the route.
      for s <- [plain_user(), owner()] do
        result = Routes.safe_destination(nil, scope: s)

        assert result == Routes.path("/admin")
        refute Routes.auth_page?(result)
      end

      assert Routes.safe_destination(nil, scope: nil) == Routes.path("/users/log-in")
    end

    test "no authenticated input terminates on an auth page" do
      for ctx <- [nil, conn_for(EmptyRouter), conn_for(@core), conn_for(HostRouter)],
          s <- [owner(), admin(), client(), plain_user()],
          skip <- [true, false] do
        result = Routes.safe_destination(ctx, scope: s, skip_admin: skip)

        refute Routes.auth_page?(result),
               "authenticated visitor sent to #{result} (skip_admin=#{skip})"
      end
    end
  end

  describe "safe_destination/2 — anonymous" do
    test "no scope and an anonymous scope behave identically" do
      # `Scope.for_user(nil)` is a STRUCT, not nil — testing `is_nil` instead of
      # `Scope.authenticated?/1` would route it down the authenticated chain.
      assert Routes.safe_destination(conn_for(@core), scope: nil) ==
               Routes.path("/users/log-in")

      assert Routes.safe_destination(conn_for(@core), scope: anonymous()) ==
               Routes.path("/users/log-in")

      assert Routes.safe_destination(conn_for(@core)) == Routes.path("/users/log-in")
    end

    test "return_to is ignored for an anonymous visitor" do
      # A ROUTABLE target, so this proves the anonymous branch ignores
      # `return_to` rather than merely that the path failed the probe.
      assert Routes.safe_destination(conn_for(@core),
               scope: nil,
               return_to: Routes.path("/profile/settings")
             ) == Routes.path("/users/log-in")
    end

    test "never selects a locale-prefixed root the host does not declare" do
      # The shipped defect: `path("/")` emitted without asking the router.
      refute Routes.routable?(conn_for(@core), Routes.path("/"))
      refute Routes.safe_destination(conn_for(@core), scope: nil) == Routes.path("/")
      refute Routes.safe_destination(conn_for(@core), scope: nil) == "/"
    end

    test "lands on the site home when the host declares one" do
      # The pre-branch behaviour for a logged-out visitor, restored: `/` is a
      # candidate like any other, selected exactly where it resolves.
      assert Routes.safe_destination(conn_for(HostRouter), scope: nil) == "/"
      assert Routes.safe_destination(socket_for(HostRouter), scope: anonymous()) == "/"
    end

    test "prefers the locale-prefixed root where the host declares that too" do
      # Guards the fixture: if the suite's prefix or default locale changes,
      # `LocalizedHomeRouter` stops standing for what it claims to.
      assert Routes.path("/") == "/phoenix_kit/en"
      assert Routes.routable?(conn_for(LocalizedHomeRouter), Routes.path("/"))

      # Both shapes resolve here, and the locale-carrying one wins — otherwise
      # a logout on a multilingual host silently switches the visitor's
      # language, which is what dropping the candidate altogether did.
      assert Routes.safe_destination(conn_for(LocalizedHomeRouter), scope: nil) ==
               Routes.path("/")

      assert Routes.safe_destination(conn_for(LocalizedHomeRouter), scope: plain_user()) ==
               Routes.path("/")
    end
  end

  describe "safe_destination/2 — single-language site under a mount prefix" do
    setup do
      PhoenixKit.Cache.put(:settings, "languages_enabled", "false")
      :ok
    end

    test "never lands on core's bare mount point, even where a catch-all routes it" do
      # Guards the fixture: the bare mount is what `path("/")` emits here, and
      # the catch-all really does answer for it.
      assert Routes.path("/") == "/phoenix_kit/"
      assert Routes.routable?(conn_for(CatchAllRouter), Routes.path("/"))
      assert Routes.routable?(conn_for(CatchAllRouter), "/phoenix_kit")

      for scope <- [nil, anonymous(), plain_user()] do
        assert Routes.safe_destination(conn_for(CatchAllRouter), scope: scope) == "/"
      end
    end

    test "falls through to core's landing when the host has no root either" do
      refute Routes.safe_destination(conn_for(EmptyRouter), scope: nil) in [
               "/phoenix_kit",
               "/phoenix_kit/"
             ]
    end
  end

  describe "open-redirect guard" do
    @hostile [
      "https://evil.example",
      "//evil.example",
      "/\\evil.example",
      "/\t/evil.example",
      "/ok\r\nX-Injected: 1",
      "evil.example",
      "",
      nil,
      :not_a_path
    ]

    test "a hostile return_to never survives the chain" do
      for candidate <- @hostile, s <- [owner(), plain_user()] do
        result = Routes.safe_destination(conn_for(@core), scope: s, return_to: candidate)

        refute result == candidate
        assert Routes.local_path?(result)
      end
    end

    test "an auth page is never selected as a return_to" do
      for candidate <- ["/users/log-out", "/et/users/register/", "/users/log-in"] do
        result = Routes.safe_destination(conn_for(@core), scope: owner(), return_to: candidate)
        refute result == candidate
      end
    end
  end

  describe "main_page_path/0" do
    test "is nil when the setting is unset (no database in this suite)" do
      assert Routes.main_page_path() == nil
    end
  end

  describe "THE INVARIANT" do
    # Stated as what is actually guaranteed, which is NOT "never `/`": `/` is a
    # legitimate destination on a host that declares one, and refusing it there
    # would regress every install that never had the locale-prefixed-root bug.
    # What core promises is that it never emits a path nobody has shown to
    # exist — every result is either PROVEN routable in the caller's own router
    # or one of the two landings core declares unconditionally.
    test "every result is either proven routable or a core-owned terminal" do
      scopes = [nil, anonymous(), owner(), admin(), client(), plain_user()]
      return_tos = [nil, "/shop", "https://evil.example", "//evil", "/\t/evil", "/users/log-out"]

      contexts = [
        nil,
        conn_for(@core),
        socket_for(@core),
        conn_for(HostRouter),
        conn_for(EmptyRouter),
        # Has /admin (both URL shapes) but no /dashboard — the host that
        # compiled the user dashboard out. The terminal is what decides where a
        # non-admin goes there.
        conn_for(AdminOnlyRouter),
        # Declares BOTH shapes of its home page — the only context in which
        # `Routes.path("/")` is a legitimate answer, and the one that would
        # slip past the assertions below if they still refused it categorically.
        conn_for(LocalizedHomeRouter)
      ]

      # `EmptyRouter` and `AdminOnlyRouter` never mounted `phoenix_kit_routes()`,
      # so core's landings are not all declared there and the terminal returns a
      # path they cannot serve (logged, deliberately). Both are excluded from the
      # routability assertion below by asking the router.
      routerless = fn ctx -> not Routes.routable?(ctx, Routes.path("/users/log-in")) end

      for s <- scopes, rt <- return_tos, skip <- [true, false], ctx <- contexts do
        result = Routes.safe_destination(ctx, scope: s, return_to: rt, skip_admin: skip)

        context =
          "scope=#{inspect(s && s.cached_roles)} return_to=#{inspect(rt)} skip=#{skip} ctx=#{inspect((ctx && get_in(ctx, [Access.key(:private, %{}), :phoenix_router])) || (ctx && Map.get(ctx, :router)))}"

        assert Routes.local_path?(result), context

        # Neither shape of the home page is ever SYNTHESIZED — the shipped bug
        # was returning `path("/")` without asking the router, not naming it.
        # Both are allowed exactly where the host proves it declared them, and
        # the general routability assertion below is what proves that; these
        # two make the home page's own case explicit rather than incidental.
        if result in [Routes.path("/"), "/"] and not routerless.(ctx) do
          assert Routes.routable?(ctx, result), context
        end

        # An auth page is only ever the ANONYMOUS terminal; sending a signed-in
        # visitor there just bounces them off it again.
        if Routes.auth_page?(result) do
          assert result == Routes.path("/users/log-in"), context
          refute Scope.authenticated?(s), context
        end

        # No waiver for terminals. They used to be exempt here, which is exactly
        # why an unroutable `/dashboard` terminal passed this test while 404ing
        # in production. The only exemption is a host that declares no routes at
        # all, and it is decided by asking the router.
        unless routerless.(ctx) do
          assert Routes.routable?(ctx, result),
                 "unroutable destination #{inspect(result)} for #{context}"
        end

        # The authorisation dimension, which the `routable?` check above cannot
        # catch: /admin IS routable in AdminOnlyRouter, so routability alone
        # passes even when the destination is wrong for this visitor.
        #
        # This used to read "never /admin without `can_access_admin_area?`".
        # That is no longer the rule — /admin is the guaranteed landing and
        # greets a visitor who holds no rights. Two narrower facts survive, and
        # they are what the old assertion was really protecting:
        #
        #   * an ANONYMOUS visitor is never sent into the admin area, and
        #   * the only admin path the resolver ever synthesizes is the INDEX.
        #     Deeper admin pages stay permission-gated and would bounce a
        #     visitor back here — the loop the old `admin?` gate existed to
        #     prevent.
        if String.contains?(result, "/admin") do
          assert Scope.authenticated?(s),
                 "admin area selected for an anonymous visitor: #{result} (#{context})"

          assert result == Routes.path("/admin"),
                 "resolver synthesized a gated admin page, not the index: #{result} (#{context})"
        end
      end
    end
  end
end
