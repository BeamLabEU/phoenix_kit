defmodule PhoenixKitWeb.RoutePrecedenceTest do
  @moduledoc """
  Guards the declaration order of the PhoenixKit LiveView surfaces.

  `:locale` is an ordinary path segment. Phoenix.Router has no segment
  constraints — `Phoenix.Router.Scope.push/2` reads only :path, :alias,
  :as, :host, :private, :assigns, :log and :trailing_slash, and silently
  discards anything else — so a `locale: ~r/.../` option on a scope looks
  like a guard, compiles without a warning, and does nothing. The public
  surface therefore contains routes of the shape `/<prefix>/:locale/<lit>`
  that match ANY first segment.

  While the public surface was emitted before the admin one, a module that
  put a public page at `/shop` and its admin page at `/admin/shop` (which
  `phoenix_kit_ecommerce` does) had its admin page swallowed:
  `/<prefix>/admin/shop` bound to `/<prefix>/:locale/shop` with
  `locale = "admin"`. Root-mounted installs were bounced to the public
  storefront; prefixed installs redirected to themselves forever.

  These tests pin the fix from both directions — the mechanism in
  isolation, and the invariant on the real router.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Users.Auth

  defmodule DummyController do
    @moduledoc false
    use Phoenix.Controller, formats: []
    def admin_shop(conn, _), do: conn
    def public_shop(conn, _), do: conn
  end

  # The fixed order: the literal-segment admin route is declared first.
  defmodule AdminFirstRouter do
    @moduledoc false
    use Phoenix.Router

    scope "/phoenix_kit" do
      get "/admin/shop", DummyController, :admin_shop
    end

    scope "/phoenix_kit/:locale" do
      get "/shop", DummyController, :public_shop
    end
  end

  # The broken order that shipped. Kept so the failure mode is executable
  # rather than folklore: if someone "tidies" the emission order in
  # `PhoenixKitWeb.Integration.phoenix_kit_routes/0`, the contrast between
  # these two routers is the explanation.
  defmodule PublicFirstRouter do
    @moduledoc false
    use Phoenix.Router

    scope "/phoenix_kit/:locale" do
      get "/shop", DummyController, :public_shop
    end

    scope "/phoenix_kit" do
      get "/admin/shop", DummyController, :admin_shop
    end
  end

  defp info(router, path), do: Phoenix.Router.route_info(router, "GET", path, "localhost")

  describe "the mechanism, in isolation" do
    test "a bogus :locale scope constraint is accepted and ignored by Phoenix" do
      # If Phoenix ever grows real segment constraints this test fails and
      # the whole workaround can be revisited. Until then: `:locale`
      # matches "admin" just as happily as it matches "en".
      assert %{path_params: %{"locale" => "admin"}} =
               info(PublicFirstRouter, "/phoenix_kit/admin/shop")
    end

    test "admin-first: the literal route wins over the same-arity :locale route" do
      assert %{plug_opts: :admin_shop} = info(AdminFirstRouter, "/phoenix_kit/admin/shop")
    end

    test "admin-first does not steal genuinely localized public URLs" do
      assert %{plug_opts: :public_shop, path_params: %{"locale" => "en"}} =
               info(AdminFirstRouter, "/phoenix_kit/en/shop")

      assert %{plug_opts: :public_shop, path_params: %{"locale" => "et"}} =
               info(AdminFirstRouter, "/phoenix_kit/et/shop")
    end

    test "public-first: reproduces the original bug" do
      assert %{plug_opts: :public_shop} = info(PublicFirstRouter, "/phoenix_kit/admin/shop")
    end
  end

  describe "the real router" do
    defp live_session_name(route) do
      case route.metadata[:phoenix_live_view] do
        {_view, _action, _opts, %{name: name}} -> name
        _ -> nil
      end
    end

    @gated_surfaces [:phoenix_kit_admin, :phoenix_kit_authenticated]

    defp prefix_segments do
      PhoenixKit.Config.get_url_prefix() |> to_string() |> String.split("/", trim: true)
    end

    # True when the first *significant* path segment is a `:param` — i.e.
    # the route matches any value in that position and will swallow
    # literal-rooted routes declared after it.
    #
    # "Significant" means: after the mount prefix for routes that carry
    # it, and simply first otherwise. Not every route is prefixed — the
    # sitemap and PDF-viewer fallbacks are deliberately mounted at the
    # site root (`/sitemaps/:filename`, `/_pdfjs/...`). Dropping N
    # segments unconditionally reads `:filename` as their first segment
    # and reports a route that is in fact literal-rooted and harmless.
    defp param_rooted?(path) do
      segments = String.split(path, "/", trim: true)
      prefix = prefix_segments()

      significant =
        case Enum.split(segments, length(prefix)) do
          {^prefix, rest} -> rest
          _ -> segments
        end

      case significant do
        [first | _] -> String.starts_with?(first, ":")
        [] -> false
      end
    end

    test "no foreign :locale-rooted route is declared before the gated surfaces" do
      # The real invariant, and the one that survives mutation. Testing
      # "first admin index < first public index" does NOT: it stays green
      # if someone moves a single route table (e.g. the shop admin block)
      # out of the admin surface, or introduces a `/:locale` route through
      # `module_public_routes` — neither shifts the FIRST admin route.
      #
      # What actually has to hold is that nothing which matches an
      # arbitrary first segment is declared ahead of the surfaces whose
      # paths start with a literal one. The admin and authenticated
      # surfaces contain `/<prefix>/:locale/admin/...` routes of their
      # own, so they are excluded — the hazard is a FOREIGN param-rooted
      # route, from any other block, appearing too early.
      routes = PhoenixKitWeb.Router.__routes__()

      gated_indexes =
        routes
        |> Enum.with_index()
        |> Enum.filter(fn {route, _i} -> live_session_name(route) in @gated_surfaces end)
        |> Enum.map(&elem(&1, 1))

      assert gated_indexes != [], "no admin/authenticated live_session routes found"
      last_gated = Enum.max(gated_indexes)

      offenders =
        routes
        |> Enum.with_index()
        |> Enum.filter(fn {route, i} ->
          i < last_gated and live_session_name(route) not in @gated_surfaces and
            param_rooted?(route.path)
        end)
        |> Enum.map(fn {route, i} -> "  index #{i}: #{route.verb} #{route.path}" end)

      assert offenders == [], """
      These routes match an arbitrary first path segment and are declared
      BEFORE the admin/authenticated surfaces end (index #{last_gated}),
      so they can swallow admin or dashboard URLs:

      #{Enum.join(offenders, "\n")}

      Emit them after the gated surfaces in
      PhoenixKitWeb.Integration.phoenix_kit_routes/0, or the next module
      that adds a colliding public page silently breaks an admin page.
      See this module's @moduledoc.
      """
    end

    test "no fully-literal route is shadowed by an earlier route" do
      routes = PhoenixKitWeb.Router.__routes__()

      literal? = fn path ->
        path
        |> String.split("/", trim: true)
        |> Enum.all?(&(not String.starts_with?(&1, [":", "*"])))
      end

      shadowed =
        for route <- routes,
            route.verb == :get,
            literal?.(route.path),
            resolved =
              Phoenix.Router.route_info(PhoenixKitWeb.Router, "GET", route.path, "localhost"),
            is_map(resolved),
            resolved.route != route.path do
          {route.path, resolved.route, resolved.path_params}
        end

      assert shadowed == [], """
      These declared routes do not resolve to themselves — an earlier
      route is swallowing them:

      #{Enum.map_join(shadowed, "\n", fn {declared, actual, params} -> "  #{declared}\n    -> #{actual}  #{inspect(params)}" end)}
      """
    end
  end

  describe "the /admin index shares the admin live_session, and the GATE admits" do
    # `/admin` is the terminal of `PhoenixKit.Utils.Routes.safe_destination/2`
    # — the page core promises EVERY signed-in visitor can be sent to. A
    # terminal that bounces its own visitor is an infinite redirect, so
    # something has to admit a visitor holding no permissions.
    #
    # That something is the GATE, not the router. The index route stays in
    # `live_session :phoenix_kit_admin` under `:phoenix_kit_ensure_admin` like
    # every other `/admin/*` page, and the hook exempts this one VIEW
    # (`PhoenixKitWeb.Users.Auth.landing_view?/1`) from its two permission
    # checks. These tests pin the router half of that sentence: the exemption
    # is a single view, and the admin surface is a single live_session.
    #
    # Why the router half matters. An earlier attempt moved the route to
    # `live_session :phoenix_kit_authenticated` instead, which broke three
    # things a test can still catch here:
    #
    #   * LiveView cannot live-navigate ACROSS live_sessions, so every click
    #     from the landing into any admin page (and back) became a full page
    #     reload — see `lib/phoenix_kit/dashboard/ADMIN_README.md`.
    #   * that session carries `{PhoenixKitWeb.Dashboard.ContextProvider,
    #     :default}`, which halt-redirects a visitor with zero contexts when a
    #     host configures `empty_behavior: {:redirect, path}` — the guaranteed
    #     landing bouncing its own visitor, the exact thing being prevented.
    #   * its pipeline runs `:phoenix_kit_require_authenticated` BEFORE
    #     `:phoenix_kit_locale_validation`, so an anonymous visitor to
    #     `/<prefix>/et/admin` was sent to a login page in the site default
    #     language.
    #
    # The behavioural half — who the gate lets through — is pinned in
    # `test/phoenix_kit_web/users/auth_test.exs` ("admin_gate_decision/2"),
    # which can drive the decision with literal scopes and no database.
    defp admin_index_paths do
      prefix =
        PhoenixKit.Config.get_url_prefix()
        |> to_string()
        |> String.trim_trailing("/")

      [prefix <> "/admin", prefix <> "/:locale/admin"]
    end

    # After the mount prefix (and an optional `:locale`), does the path start
    # with the literal `admin` segment?
    defp admin_surface_path?(path) do
      prefix = prefix_segments()

      significant =
        case path |> String.split("/", trim: true) |> Enum.split(length(prefix)) do
          {^prefix, rest} -> rest
          _ -> []
        end

      case significant do
        [":locale", "admin" | _] -> true
        ["admin" | _] -> true
        _ -> false
      end
    end

    defp on_mount_ids(route) do
      case route.metadata[:phoenix_live_view] do
        {_view, _action, _opts, %{extra: %{on_mount: hooks}}} -> Enum.map(hooks, & &1.id)
        _ -> []
      end
    end

    defp live_view_module(route) do
      case route.metadata[:phoenix_live_view] do
        {view, _action, _opts, _extra} -> view
        _ -> nil
      end
    end

    test "both URL shapes exist, mount Live.Dashboard, and carry the ADMIN hook" do
      routes = PhoenixKitWeb.Router.__routes__()

      for path <- admin_index_paths() do
        route = Enum.find(routes, &(&1.verb == :get and &1.path == path))

        assert route, "#{path} is not declared — the guaranteed landing must exist in both shapes"

        assert {PhoenixKitWeb.Live.Dashboard, :index, _opts, _extra} =
                 route.metadata[:phoenix_live_view]

        assert live_session_name(route) == :phoenix_kit_admin

        # The account gate protects the landing; the invitation hook adds
        # pending invitations without changing access to the dashboard.
        assert on_mount_ids(route) == [
                 {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin},
                 {PhoenixKitWeb.Hooks.InvitationHook, :default}
               ]
      end
    end

    test "the whole admin surface is ONE live_session, index included" do
      admin_routes =
        PhoenixKitWeb.Router.__routes__()
        |> Enum.filter(&admin_surface_path?(&1.path))
        # Test-support probes (`test/support/*_probe_live.ex`) sit under /admin
        # so the admin chrome draws, outside the live_session on purpose.
        |> Enum.reject(&String.contains?(&1.path, "/__test/"))

      assert length(admin_routes) > 20,
             "expected the admin surface to hold its route table, found #{length(admin_routes)}"

      # Both shapes of the index are in there, and they are not special.
      assert Enum.all?(admin_index_paths(), fn p ->
               Enum.any?(admin_routes, &(&1.verb == :get and &1.path == p))
             end)

      strays =
        for route <- admin_routes,
            live_session_name(route) != :phoenix_kit_admin,
            do:
              "  #{route.verb} #{route.path} -> #{inspect(live_session_name(route))} #{inspect(on_mount_ids(route))}"

      assert strays == [], """
      These /admin routes are NOT in live_session :phoenix_kit_admin:

      #{Enum.join(strays, "\n")}

      LiveView cannot live-navigate across live_sessions, so each of these
      turns navigation to and from the rest of the admin area into a full page
      reload. Admitting a visitor who lacks a permission is the GATE's job
      (`PhoenixKitWeb.Users.Auth.admin_gate_decision/2`), never the router's.
      """
    end

    test "exactly one admin route mounts the landing view" do
      # The gate exemption is keyed on the VIEW, so a second route mounting
      # `PhoenixKitWeb.Live.Dashboard` would silently inherit it — a whole
      # extra page open to every authenticated visitor. Both URL shapes of
      # `/admin` mount it; nothing else may.
      landing_routes =
        PhoenixKitWeb.Router.__routes__()
        |> Enum.filter(&Auth.landing_view?(live_view_module(&1)))
        |> Enum.map(& &1.path)
        |> Enum.sort()

      assert landing_routes == Enum.sort(admin_index_paths())
    end

    test "no OTHER admin view is treated as the landing" do
      # The complement of the test above, stated over views rather than
      # routes: `landing_view?/1` must answer false for every other admin
      # LiveView the router mounts, or the exemption has widened.
      admin_views =
        PhoenixKitWeb.Router.__routes__()
        |> Enum.filter(&admin_surface_path?(&1.path))
        |> Enum.map(&live_view_module/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      assert length(admin_views) > 20

      exempt = Enum.filter(admin_views, &Auth.landing_view?/1)

      assert exempt == [PhoenixKitWeb.Live.Dashboard]
    end
  end
end
