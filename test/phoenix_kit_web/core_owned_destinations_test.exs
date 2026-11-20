defmodule PhoenixKitWeb.CoreOwnedDestinationsTest do
  @moduledoc """
  The invariant this branch exists to establish: **core never sends anyone to a
  path it does not own.**

  Three halves, all database-free:

    * the router-level facts the resolver's safety argument rests on — core does
      NOT route `/` or its locale-prefixed twin, and DOES route the two landings
      the chain can terminate at (plus `/dashboard`, still a candidate), in
      every locale shape;
    * behavioral tests that directly invoke the mount functions of the three
      LiveViews that gate post-auth flow and assert the computed destination
      resolves in a core-only router — the check a static scan cannot perform
      because the destination is stored in a variable before being passed to
      `redirect(to: destination)`;
    * behavioral tests on the resolver itself, asserting that every chain
      terminates on a path this router declares. These replaced a pair of
      whole-file regexes over `lib/**/*.ex` that hunted for a literal `to: "/"`:
      a regex can only prove a negative about source text, and it was blind to
      exactly the computed-destination shape above.

  `PhoenixKitWeb.Router` is a real compiled router that calls
  `phoenix_kit_routes()` (documented as "used only for development and
  testing"), so `Phoenix.Router.route_info/4` against it is the oracle for
  "does core own this path".
  """
  use ExUnit.Case, async: true

  # `EmptyRouter` below cannot match core's own landing, which is the one case
  # the resolver logs as a misconfiguration. Deliberate here.
  @moduletag :capture_log

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User, as: AuthUser
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Confirmation
  alias PhoenixKitWeb.Users.ConfirmationInstructions
  alias PhoenixKitWeb.Users.ReferralGate

  @router PhoenixKitWeb.Router

  # A host that mounted nothing at all: every candidate AND the terminal fail
  # `routable?/2`, so the resolver has only its own guarantee left to stand on.
  defmodule EmptyRouter do
    use Phoenix.Router
  end

  defp resolves?(path) do
    Phoenix.Router.route_info(@router, "GET", path, "localhost") != :error
  end

  defp conn_for(router), do: %Plug.Conn{private: %{phoenix_router: router}, host: "localhost"}

  defp scope(roles, permissions \\ []) do
    %Scope{
      user: nil,
      authenticated?: true,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  describe "what core does and does not route" do
    test "core does not route \"/\" — the premise of this whole branch" do
      refute resolves?("/")
    end

    test "core does not route the locale-prefixed root either — the shipped bug" do
      # `Routes.path("/")` emits `/phoenix_kit/en`. Nine call sites used to send
      # users there; the route belongs to the host, which may never have
      # declared it.
      refute resolves?(Routes.path("/"))
    end

    test "every path the resolver can reach resolves, in every locale shape" do
      # `/admin` and `/users/log-in` are the two the chain can TERMINATE at, and
      # core declares both unconditionally — which is exactly why they are the
      # ones worth asserting in every locale shape.
      #
      # `/dashboard` is deliberately NOT here. It is a candidate only, and
      # `user_dashboard_enabled` now defaults to false, so core's own router
      # does not declare it. A candidate that does not resolve is skipped by
      # `admissible_candidate?/3` — that is the designed behaviour, not a
      # routing hole, and it is covered in `SafeDestinationTest`.
      for landing <- ["/admin", "/users/log-in"],
          locale <- [nil, :none, "en", "de", "ru", "en-GB"] do
        path = Routes.path(landing, locale: locale)

        assert resolves?(path),
               "#{landing} with locale #{inspect(locale)} emitted #{path}, which does not resolve"
      end
    end
  end

  describe "LiveViews that gate post-auth flow assign routable destinations" do
    # The destination each of these mounts computes goes into a variable before
    # reaching `redirect(to: destination)`, so no source-level check can see it.
    # These call the mounts and assert on the value.
    #
    # All three LiveViews call `Routes.post_auth_path/2` in `mount/3`. That call
    # used to synthesize `"/"` whenever no `:context` was threaded, which 404s
    # on any host that declares no root route — the configuration this branch
    # exists to handle. All three thread a context now, and the context-less
    # tail is a core-owned landing rather than `"/"`, so the failure is closed
    # from both ends.
    #
    # Each mount is called directly with a socket whose router is
    # `PhoenixKitWeb.Router` (which does not declare `"/"`). No database is
    # needed: none of the three mounts issue a DB query for the anonymous /
    # access-satisfied scenarios exercised here.

    defp lv_socket do
      %Phoenix.LiveView.Socket{
        router: @router,
        host_uri: URI.parse("http://localhost"),
        assigns: %{__changed__: %{}}
      }
    end

    test "Confirmation.mount assigns a destination that resolves" do
      # Anonymous mount with a probe token; `destination` is computed from
      # params/session and stored in assigns. The token's validity is irrelevant
      # here — the DB check only happens in `handle_event("confirm_account", ...)`.
      params = %{"token" => "probe_token"}

      {:ok, socket, _opts} =
        Confirmation.mount(params, %{}, lv_socket())

      destination = socket.assigns.destination

      assert resolves?(destination),
             "Confirmation.mount assigned unroutable destination #{inspect(destination)}"
    end

    test "ConfirmationInstructions.mount assigns a destination that resolves" do
      # Anonymous mount (no user in assigns): takes the `is_nil(user)` cond branch,
      # assigns `destination:` without touching the database.
      {:ok, socket} =
        ConfirmationInstructions.mount(%{}, %{}, lv_socket())

      destination = socket.assigns.destination

      assert resolves?(destination),
             "ConfirmationInstructions.mount assigned unroutable destination #{inspect(destination)}"
    end

    test "ReferralGate.mount redirects to a destination that resolves" do
      # With `referral_codes_required` unset (default false / no DB),
      # `Referrals.access_satisfied?/1` short-circuits to `true` without reading
      # any user fields, so mount takes the second cond branch and redirects to
      # `destination`. The redirect target is extracted from `socket.redirected`.
      user = %AuthUser{uuid: Ecto.UUID.generate(), email: "probe@example.com"}

      socket_with_user =
        Map.update!(lv_socket(), :assigns, &Map.put(&1, :phoenix_kit_current_user, user))

      {:ok, result} = ReferralGate.mount(%{}, %{}, socket_with_user)

      {:redirect, %{to: destination}} = result.redirected

      assert resolves?(destination),
             "ReferralGate.mount redirected to unroutable destination #{inspect(destination)}"
    end
  end

  describe "the resolver terminates on a path core declares" do
    # This replaced two whole-file regexes over `lib/**/*.ex` (`to: "/"` and
    # `to: Routes.path("/")`). They proved a negative about source text and
    # could not see the shape that actually mattered — a destination computed
    # into a variable. What core promises is a property of the value the
    # resolver returns, so that is what is asserted, against the router that is
    # the oracle for "does core own this path".

    test "an authenticated visitor with nothing else to go on lands on /admin" do
      # Two contexts where every candidate fails: a router that declares
      # nothing, and no router at all (`routable?/2` fails closed). Both leave
      # the terminal as the only thing standing, and the terminal is asserted
      # rather than probed because core declares `/admin` unconditionally and
      # admits every authenticated visitor to it.
      for scope <- [scope(["User"]), scope(["Admin"]), scope(["Owner"])],
          ctx <- [nil, conn_for(EmptyRouter)],
          skip <- [true, false] do
        result = Routes.safe_destination(ctx, scope: scope, skip_admin: skip)

        assert result == Routes.path("/admin"),
               "terminated on #{inspect(result)} for #{inspect(scope.cached_roles)} (skip=#{skip})"

        assert resolves?(result),
               "the terminal core guarantees does not resolve in core's own router: #{result}"
      end
    end

    test "an anonymous visitor with nothing else to go on lands on /users/log-in" do
      # Licensed by a separate fact from the /admin decision: the public auth
      # surface declares this route unconditionally.
      for ctx <- [nil, conn_for(EmptyRouter)] do
        result = Routes.safe_destination(ctx, scope: nil)

        assert result == Routes.path("/users/log-in")
        assert resolves?(result)
      end
    end

    test "post_auth_path with no context returns a path core declares" do
      # The structural close for callers that have no conn/socket to thread.
      # This returned a bare `"/"` — the host's home page, which core cannot
      # declare and many hosts never route — until `/admin` became guaranteed.
      result = Routes.post_auth_path([])

      assert result == Routes.path("/admin")
      assert resolves?(result)
      refute Routes.auth_page?(result)
    end

    test "on core's own router every destination the resolver returns resolves" do
      scopes = [nil, Scope.for_user(nil), scope(["User"]), scope(["Admin"]), scope(["Owner"])]
      return_tos = [nil, "/", "/no/such/page", "https://evil.example", "/users/log-out"]

      for s <- scopes, rt <- return_tos, skip <- [true, false] do
        result =
          Routes.safe_destination(conn_for(@router), scope: s, return_to: rt, skip_admin: skip)

        assert resolves?(result),
               "unroutable destination #{inspect(result)} (scope=#{inspect(s && s.cached_roles)} return_to=#{inspect(rt)} skip=#{skip})"
      end
    end
  end
end
