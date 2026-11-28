defmodule PhoenixKitWeb.AdminRouteDedupTest do
  @moduledoc """
  Pins the fix for the admin-tab route duplication defect.

  Two places generate `live` route declarations for the admin surface and
  neither dedupes against the other:

    * `PhoenixKitWeb.Integration.collect_module_tabs/2` calls
      `Enum.uniq_by(&(&1.path))`, but only across ONE module's own tab list.
    * `PhoenixKitWeb.Integration.compile_module_admin_routes/0` `flat_map`s
      that per-module list across ALL discovered modules with no dedup
      between them, and the host's own `:admin_dashboard_tabs` pages
      (`compile_custom_admin_routes/1`) are never checked against either.

  A host-declared admin page and a module tab that resolve to the SAME path
  therefore compile into TWO `live` declarations at an identical path. The
  router keeps the first and the second becomes dead code — reachable only
  by luck of declaration order, discovered by accident via the compiler's
  "this clause cannot match" warning (absent under `--warnings-as-errors`
  it isn't discovered at all).

  Compiled in a THROWAWAY router (`DedupProbeRouter` below), not
  `PhoenixKitWeb.Router`: the real dev/test router special-cases itself in
  `compile_custom_admin_routes/1` and `compile_plugin_admin_routes/1`
  (`caller_module == PhoenixKitWeb.Router` short-circuits to `[]` — "parent
  app modules aren't available when it compiles") so it can never exhibit
  this defect. A router under a different module name goes through the
  real code paths and lets the resulting `__routes__()` speak for itself.

  Config (`:admin_dashboard_tabs`, `:modules`) is set as PLAIN CODE at the
  top of this file, before `DedupProbeRouter` is defined — not inside
  `setup/1`. `phoenix_kit_routes()` expands at COMPILE time, which for a
  module nested in a test file happens the moment `Kernel.ParallelCompiler`
  reaches this file, well before any `setup` block would run.

  For the same reason, the `:user_dashboard_tabs` cross-module dedup test
  below (added post-#753 — the fix landed in this same review pass, see
  `PhoenixKitWeb.Integration.phoenix_kit_authenticated_routes/1`) lives in
  THIS file rather than a sibling one: two test files each mutating
  `Application.put_env(:phoenix_kit, :modules, ...)` as top-level compile-
  time code race against each other under `Kernel.ParallelCompiler`, which
  compiles multiple files concurrently — confirmed by extraction, which
  intermittently starved this file's own `FakeExternalModule` out of
  `:modules` mid-compile. `async: false` (an ExUnit/runtime concern) cannot
  fix a compile-time race. One file, one `Application.put_env` sequence,
  is the only reliable way to keep this fixture isolated.

  It also races an ASYNC test that writes `:modules`: ExUnit starts async
  modules while files are still loading, so such a test can overwrite the
  key while this file compiles (the router then loses its module tabs).
  A test that writes `:modules` must be `async: false` — sync modules run
  only after every file has loaded.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Dashboard.Tab

  # Two probe LiveViews per side so a real collision (same path) and a
  # non-collision (different paths) can be checked in the same router.
  defmodule HostCollisionLive do
    @moduledoc false
    use Phoenix.LiveView
    @impl true
    def render(assigns), do: ~H"<div>host-collision</div>"
  end

  defmodule ModuleCollisionLive do
    @moduledoc false
    use Phoenix.LiveView
    @impl true
    def render(assigns), do: ~H"<div>module-collision</div>"
  end

  defmodule HostOnlyLive do
    @moduledoc false
    use Phoenix.LiveView
    @impl true
    def render(assigns), do: ~H"<div>host-only</div>"
  end

  # A host tab written with the documented RELATIVE path ("analytics").
  # Lives in this file for the reason in the moduledoc: one file sets
  # `:admin_dashboard_tabs` at compile time.
  defmodule HostRelativeLive do
    @moduledoc false
    use Phoenix.LiveView
    @impl true
    def render(assigns), do: ~H"<div>host-relative</div>"
  end

  defmodule ModuleOnlyLive do
    @moduledoc false
    use Phoenix.LiveView
    @impl true
    def render(assigns), do: ~H"<div>module-only</div>"
  end

  # Two more probes for the `user_dashboard_tabs` cross-module collision
  # test below — a collision between TWO external modules, not host-vs-
  # module (there is no host `:user_dashboard_tabs` route source to collide
  # with; see the moduledoc).
  defmodule FirstDashboardCollisionLive do
    @moduledoc false
    use Phoenix.LiveView
    @impl true
    def render(assigns), do: ~H"<div>first-dashboard-collision</div>"
  end

  defmodule SecondDashboardCollisionLive do
    @moduledoc false
    use Phoenix.LiveView
    @impl true
    def render(assigns), do: ~H"<div>second-dashboard-collision</div>"
  end

  defmodule FirstDashboardOnlyLive do
    @moduledoc false
    use Phoenix.LiveView
    @impl true
    def render(assigns), do: ~H"<div>first-dashboard-only</div>"
  end

  defmodule SecondDashboardOnlyLive do
    @moduledoc false
    use Phoenix.LiveView
    @impl true
    def render(assigns), do: ~H"<div>second-dashboard-only</div>"
  end

  # Stand-in for an external PhoenixKit module discovered via the
  # `Application.get_env(:phoenix_kit, :modules, [])` fallback in
  # `PhoenixKit.ModuleDiscovery.discover_external_modules/0` — no beam
  # scanning or `@phoenix_kit_module` attribute required.
  defmodule FakeExternalModule do
    @moduledoc false

    def admin_tabs do
      [
        Tab.new!(
          id: :dedup_probe_module_collision_tab,
          label: "Module (collision)",
          path: "/admin/dedup-collision-probe",
          live_view: {PhoenixKitWeb.AdminRouteDedupTest.ModuleCollisionLive, :index}
        ),
        Tab.new!(
          id: :dedup_probe_module_only_tab,
          label: "Module-only",
          path: "module-only-probe",
          live_view: {PhoenixKitWeb.AdminRouteDedupTest.ModuleOnlyLive, :index}
        )
      ]
    end

    # `compile_module_user_routes/1` `flat_map`s this across every
    # discovered module with no dedup between them — the same defect class
    # #753 fixed for `admin_tabs`/`settings_tabs`, left open here.
    # `FakeExternalModule` is discovered before `SecondFakeExternalModule`
    # (declaration order in the `:modules` config below), so this is the
    # one expected to win the collision.
    def user_dashboard_tabs do
      [
        Tab.new!(
          id: :dedup_probe_first_dashboard_collision_tab,
          label: "First (dashboard collision)",
          path: "/dashboard/dedup-collision-probe",
          live_view: {PhoenixKitWeb.AdminRouteDedupTest.FirstDashboardCollisionLive, :index}
        ),
        Tab.new!(
          id: :dedup_probe_first_dashboard_only_tab,
          label: "First-only (dashboard)",
          path: "first-dashboard-only-probe",
          live_view: {PhoenixKitWeb.AdminRouteDedupTest.FirstDashboardOnlyLive, :index}
        )
      ]
    end
  end

  # Second stand-in module — exists only to give the `user_dashboard_tabs`
  # cross-module collision test a second module to collide with. No
  # `admin_tabs/0` of its own, so it's inert for the admin-side tests above.
  defmodule SecondFakeExternalModule do
    @moduledoc false

    def user_dashboard_tabs do
      [
        Tab.new!(
          id: :dedup_probe_second_dashboard_collision_tab,
          label: "Second (dashboard collision)",
          path: "/dashboard/dedup-collision-probe",
          live_view: {PhoenixKitWeb.AdminRouteDedupTest.SecondDashboardCollisionLive, :index}
        ),
        Tab.new!(
          id: :dedup_probe_second_dashboard_only_tab,
          label: "Second-only (dashboard)",
          path: "second-dashboard-only-probe",
          live_view: {PhoenixKitWeb.AdminRouteDedupTest.SecondDashboardOnlyLive, :index}
        )
      ]
    end
  end

  # --- compile-time fixture config, restored immediately after the router
  # below finishes compiling (routes are baked in; nothing after this point
  # reads these keys at compile time again) ---
  @previous_admin_dashboard_tabs Application.compile_env(:phoenix_kit, :admin_dashboard_tabs)
  @previous_modules Application.compile_env(:phoenix_kit, :modules)

  Application.put_env(:phoenix_kit, :admin_dashboard_tabs, [
    %{
      id: :dedup_probe_host_collision_tab,
      label: "Host (collision)",
      path: "/admin/dedup-collision-probe",
      live_view: {PhoenixKitWeb.AdminRouteDedupTest.HostCollisionLive, :index}
    },
    %{
      id: :dedup_probe_host_only_tab,
      label: "Host-only",
      path: "/admin/host-only-probe",
      live_view: {PhoenixKitWeb.AdminRouteDedupTest.HostOnlyLive, :index}
    },
    %{
      id: :dedup_probe_host_relative_tab,
      label: "Host (relative path)",
      path: "relative-host-probe",
      live_view: {PhoenixKitWeb.AdminRouteDedupTest.HostRelativeLive, :index}
    }
  ])

  Application.put_env(:phoenix_kit, :modules, [
    PhoenixKitWeb.AdminRouteDedupTest.FakeExternalModule,
    PhoenixKitWeb.AdminRouteDedupTest.SecondFakeExternalModule
  ])

  defmodule DedupProbeRouter do
    @moduledoc false
    use PhoenixKitWeb, :router

    import PhoenixKitWeb.Integration
    import PhoenixKitWeb.Users.Auth

    pipeline :browser do
      plug :accepts, ["html"]
      plug :fetch_session
      plug :fetch_live_flash
      plug :put_root_layout, html: PhoenixKit.LayoutConfig.get_root_layout()
      plug :protect_from_forgery
      plug :put_secure_browser_headers
      plug :ensure_session_uuid
      plug :fetch_phoenix_kit_current_user
    end

    phoenix_kit_routes()

    defp ensure_session_uuid(conn, _opts) do
      case Plug.Conn.get_session(conn, :phoenix_kit_session_uuid) do
        nil -> Plug.Conn.put_session(conn, :phoenix_kit_session_uuid, UUIDv7.generate())
        _ -> conn
      end
    end
  end

  if @previous_admin_dashboard_tabs do
    Application.put_env(:phoenix_kit, :admin_dashboard_tabs, @previous_admin_dashboard_tabs)
  else
    Application.delete_env(:phoenix_kit, :admin_dashboard_tabs)
  end

  if @previous_modules do
    Application.put_env(:phoenix_kit, :modules, @previous_modules)
  else
    Application.delete_env(:phoenix_kit, :modules)
  end

  defp routes_ending_in(suffix) do
    DedupProbeRouter.__routes__()
    |> Enum.filter(&(&1.verb == :get and String.ends_with?(&1.path, suffix)))
  end

  # Every admin page compiles to TWO routes by design — one for the plain
  # `/admin/...` shape, one for the locale-prefixed `/:locale/admin/...`
  # shape (see `build_live_surface/5`). That doubling is intentional and
  # orthogonal to this defect: a colliding path must collapse ONE pair
  # (host source vs. module source) into one surviving declaration PER
  # shape, i.e. 2 routes total, not 1 — and a non-colliding path must keep
  # its normal 2, unaffected.
  test "a host page and a module tab resolving to the same path compile to one declaration per URL shape, not two" do
    matches = routes_ending_in("/admin/dedup-collision-probe")

    assert length(matches) == 2,
           "expected 2 routes (one per URL shape) at the colliding path, found " <>
             "#{length(matches)}: #{inspect(Enum.map(matches, & &1.path))}"

    # The host declares the collision point, so it wins — the application
    # owner gets precedence over an installed module's opinion about the
    # same URL.
    live_views =
      matches
      |> Enum.map(fn route -> elem(route.metadata[:phoenix_live_view], 0) end)
      |> Enum.uniq()

    assert live_views == [PhoenixKitWeb.AdminRouteDedupTest.HostCollisionLive]
  end

  test "distinct paths are left alone — dedup does not swallow real pages" do
    assert length(routes_ending_in("/admin/host-only-probe")) == 2
    assert length(routes_ending_in("/admin/module-only-probe")) == 2
  end

  test "two modules' user_dashboard_tabs resolving to the same path compile to one declaration per URL shape, not two" do
    matches = routes_ending_in("/dashboard/dedup-collision-probe")

    assert length(matches) == 2,
           "expected 2 routes (one per URL shape) at the colliding path, found " <>
             "#{length(matches)}: #{inspect(Enum.map(matches, & &1.path))}"

    # First-discovered module wins — same precedence collect_module_tabs/2
    # already uses within a single module's own tab list, and
    # dedupe_admin_routes_by_path/2 uses for the admin surface above.
    live_views =
      matches
      |> Enum.map(fn route -> elem(route.metadata[:phoenix_live_view], 0) end)
      |> Enum.uniq()

    assert live_views == [PhoenixKitWeb.AdminRouteDedupTest.FirstDashboardCollisionLive]
  end

  test "distinct user_dashboard_tabs paths from different modules are left alone" do
    assert length(routes_ending_in("/dashboard/first-dashboard-only-probe")) == 2
    assert length(routes_ending_in("/dashboard/second-dashboard-only-probe")) == 2
  end

  test "a host tab with a relative path is routed under /admin, where the sidebar links it" do
    matches = routes_ending_in("relative-host-probe")

    assert length(matches) == 2,
           "expected 2 routes (one per URL shape), found #{inspect(Enum.map(matches, & &1.path))}"

    assert Enum.all?(matches, &String.ends_with?(&1.path, "/admin/relative-host-probe")),
           "routed outside /admin: #{inspect(Enum.map(matches, & &1.path))}"
  end

  # The guard itself (any failure answers "recompile") cannot be provoked from
  # here without unloading PhoenixKit; this pins that the generated function
  # still compiles in a host router and answers a boolean.
  test "the router's __mix_recompile__?/0 answers a boolean" do
    assert is_boolean(DedupProbeRouter.__mix_recompile__?())
  end
end
