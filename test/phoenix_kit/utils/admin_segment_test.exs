defmodule PhoenixKit.Utils.AdminSegmentTest do
  @moduledoc """
  Coverage for the configurable admin segment (`config :phoenix_kit, admin_path:`).

  The feature is a matched pair of rewrites, and the whole design rests on them
  being exact inverses:

    * **emit** — `Routes.apply_admin_segment/1` moves a canonical `/admin...`
      onto the configured segment. Reached by every URL core hands out, and by
      the router's own route table at compile time.
    * **read** — `Routes.canonical_admin_path/1` moves it back, so anything
      comparing an incoming request path against a path written in code sees
      both spelled the same way.

  A test that only exercised the emit half would pass on a build where tab
  highlighting is silently dead, so the round trip is asserted directly and the
  `Tab.matches_path?/2` consequence is asserted on top of it.

  Deliberately plain `ExUnit.Case` for the same reason as
  `PhoenixKit.Utils.SafeDestinationTest`: `DataCase` would stamp
  `@moduletag :integration` and auto-exclude the file on exactly the runs where
  it is most useful. Nothing here needs a database.

  Not `async` — the segment lives in `:persistent_term` (via
  `PhoenixKit.Config.get_admin_path/0`), so a test that flips it is flipping
  global state for the whole node.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Config
  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKit.Utils.Routes

  @renamed "/backoffice"

  # ── A router compiled under a RENAMED admin segment ────────────────────
  #
  # This is the only assertion that can prove the rename reached the router
  # rather than only the link builders — everything else in this file would
  # pass just as happily against a route table still nailed to `/admin`.
  #
  # Compiled from source inside `setup_all` rather than as a `defmodule` in the
  # file body, and that is load-bearing. `mix test` loads test files with
  # `Kernel.ParallelCompiler`, so a flip in a file BODY overlaps the loading of
  # every other test file — including the ones that compile routers of their
  # own. The segment is cached in `:persistent_term`, so a parallel reader that
  # cached "/backoffice" a moment before this file restored the default pinned
  # it there for the whole run: ~25 unrelated tests failed with 404s on
  # `/phoenix_kit/en/backoffice/...`, none of them anywhere near this feature.
  #
  # `setup_all` runs in the SYNC phase instead — after every async module has
  # finished, with one sync module running at a time — so the flip has the node
  # to itself.
  setup_all do
    router =
      with_segment(@renamed, fn ->
        # `phoenix_kit_routes()` defines helper modules of its own, so the head
        # of what `compile_string/1` returns is not reliably the router. Name it.
        Code.compile_string("""
        defmodule PhoenixKit.Utils.AdminSegmentTest.RenamedAdminRouter do
          use PhoenixKitWeb, :router

          import PhoenixKitWeb.Integration

          pipeline :browser do
            plug :accepts, ["html"]
            plug :fetch_session
            plug :fetch_live_flash
            plug :protect_from_forgery
            plug :put_secure_browser_headers
          end

          phoenix_kit_routes()
        end
        """)

        PhoenixKit.Utils.AdminSegmentTest.RenamedAdminRouter
      end)

    assert function_exported?(router, :__routes__, 0)

    %{renamed_router: router}
  end

  defp conn_for(router) do
    %Plug.Conn{private: %{phoenix_router: router}, host: "localhost"}
  end

  # The segment is global state; give each block the value it is about and put
  # it back afterwards.
  defp with_segment(value, fun) do
    previous = Application.fetch_env(:phoenix_kit, :admin_path)
    Application.put_env(:phoenix_kit, :admin_path, value)
    Config.clear_admin_path_cache()

    try do
      fun.()
    after
      case previous do
        {:ok, prior} -> Application.put_env(:phoenix_kit, :admin_path, prior)
        :error -> Application.delete_env(:phoenix_kit, :admin_path)
      end

      Config.clear_admin_path_cache()
    end
  end

  describe "the compiled route table" do
    test "serves the admin area under the configured segment", %{renamed_router: renamed} do
      conn = conn_for(renamed)

      assert Routes.routable?(conn, "/phoenix_kit/backoffice")
      assert Routes.routable?(conn, "/phoenix_kit/backoffice/users")
      assert Routes.routable?(conn, "/phoenix_kit/backoffice/settings")
    end

    test "keeps the locale-prefixed shape of the admin area", %{renamed_router: renamed} do
      # Both URL shapes share one live_session, so the rename has to reach both
      # or an in-admin locale switch lands on a 404.
      assert Routes.routable?(conn_for(renamed), "/phoenix_kit/uk/backoffice/users")
    end

    test "no longer serves the old segment", %{renamed_router: renamed} do
      # The rename MOVES the tree — it does not alias it. This is the assertion
      # that would catch a rewrite applied to link building alone.
      refute Routes.routable?(conn_for(renamed), "/phoenix_kit/admin")
      refute Routes.routable?(conn_for(renamed), "/phoenix_kit/admin/users")
    end

    test "leaves every non-admin surface exactly where it was", %{renamed_router: renamed} do
      conn = conn_for(renamed)

      assert Routes.routable?(conn, "/phoenix_kit/users/log-in")
      assert Routes.routable?(conn, "/phoenix_kit/users/register")
      assert Routes.routable?(conn, "/phoenix_kit/profile/settings")
    end

    test "the default configuration is byte-identical to before" do
      # PhoenixKitWeb.Router is compiled with no :admin_path set at all, so it
      # is the control for "an unconfigured host is untouched".
      conn = conn_for(PhoenixKitWeb.Router)

      assert Routes.routable?(conn, "/phoenix_kit/admin")
      assert Routes.routable?(conn, "/phoenix_kit/admin/users")
      refute Routes.routable?(conn, "/phoenix_kit/backoffice")
    end
  end

  describe "Config.get_admin_path/0" do
    test "defaults to /admin" do
      assert Config.get_admin_path() == "/admin"
    end

    test "normalises a segment written without a leading slash" do
      with_segment("backoffice", fn -> assert Config.get_admin_path() == "/backoffice" end)
    end

    test "normalises a trailing slash away" do
      with_segment("/backoffice/", fn -> assert Config.get_admin_path() == "/backoffice" end)
    end

    test "falls back to /admin when set to an empty string" do
      with_segment("   ", fn -> assert Config.get_admin_path() == "/admin" end)
    end

    test "refuses a nested path" do
      # `admin_area_path?/1` — the redirect-loop guard — compares one segment,
      # so a nested value would compile and then fail open.
      assert_raise ArgumentError, ~r/single lowercase path segment/, fn ->
        with_segment("/a/b", &Config.get_admin_path/0)
      end
    end

    test "refuses characters that are not path-safe" do
      assert_raise ArgumentError, ~r/single lowercase path segment/, fn ->
        with_segment("/Back Office", &Config.get_admin_path/0)
      end
    end

    test "refuses a segment core already owns" do
      for taken <- ~w(/users /profile /api /mcp /oauth /assets) do
        assert_raise ArgumentError, ~r/already declares/, fn ->
          with_segment(taken, &Config.get_admin_path/0)
        end
      end
    end

    test "`/dashboard` is reserved only while the user dashboard is routed" do
      # `user_dashboard_enabled` defaults to false, so nothing occupies
      # /dashboard and the admin area is free to move onto it — the rename a
      # host retiring the user dashboard is most likely to want.
      refute Config.user_dashboard_enabled?()
      assert with_segment("/dashboard", &Config.get_admin_path/0) == "/dashboard"
    end
  end

  describe "apply_admin_segment/1 and canonical_admin_path/1" do
    test "are a no-op on the default configuration" do
      assert Routes.apply_admin_segment("/admin/users") == "/admin/users"
      assert Routes.canonical_admin_path("/admin/users") == "/admin/users"
    end

    test "round-trip" do
      with_segment(@renamed, fn ->
        for canonical <- ["/admin", "/admin/users", "/admin/settings/users", "/admin?tab=1"] do
          real = Routes.apply_admin_segment(canonical)

          refute real == canonical
          assert Routes.canonical_admin_path(real) == canonical
        end
      end)
    end

    test "apply is idempotent — an already-rewritten path passes through" do
      with_segment(@renamed, fn ->
        assert Routes.apply_admin_segment("/backoffice/users") == "/backoffice/users"
      end)
    end

    test "respect segment boundaries in both directions" do
      # `String.starts_with?(path, "/admin")` also claimed `/administrators`,
      # which was cosmetic until a rewrite started acting on the match — it
      # would have produced `/backofficeistrators`.
      with_segment(@renamed, fn ->
        assert Routes.apply_admin_segment("/administrators") == "/administrators"
        assert Routes.canonical_admin_path("/backofficexyz") == "/backofficexyz"
      end)
    end

    test "leave non-admin paths alone" do
      with_segment(@renamed, fn ->
        assert Routes.apply_admin_segment("/users/log-in") == "/users/log-in"
        assert Routes.canonical_admin_path("/users/log-in") == "/users/log-in"
      end)
    end
  end

  describe "URL building" do
    test "Routes.path/2 emits the configured segment" do
      with_segment(@renamed, fn ->
        assert Routes.path("/admin/users", locale: :none) == "/phoenix_kit/backoffice/users"
      end)
    end

    test "Routes.admin_path/2 emits the configured segment with the locale kept" do
      # A locale segment only exists on a multilingual site.
      LanguageSettings.multilingual!()

      with_segment(@renamed, fn ->
        assert Routes.admin_path("/admin/users", "uk") == "/phoenix_kit/uk/backoffice/users"
      end)
    end

    test "call sites keep naming /admin" do
      # The point of the design: nothing outside the two primitives is written
      # against the configured value, so this is the same call an unconfigured
      # host makes.
      with_segment(@renamed, fn ->
        assert Routes.path("/admin", locale: :none) == "/phoenix_kit/backoffice"
      end)

      assert Routes.path("/admin", locale: :none) == "/phoenix_kit/admin"
    end
  end

  describe "tab matching" do
    test "a canonical tab path matches a renamed request path" do
      # Tabs are declared canonically and the browser sends the configured
      # spelling. Without `canonical_admin_path/1` in `Tab.normalize_path/1`
      # these never meet and every admin tab renders inactive.
      tab = %Tab{id: :users, label: "Users", path: "/admin/users", match: :exact}

      with_segment(@renamed, fn ->
        assert Tab.matches_path?(tab, "/phoenix_kit/backoffice/users")
        assert Tab.matches_path?(tab, "/phoenix_kit/uk/backoffice/users")
      end)
    end

    test "prefix matching still respects segment boundaries" do
      tab = %Tab{id: :users, label: "Users", path: "/admin/users", match: :prefix}

      with_segment(@renamed, fn ->
        assert Tab.matches_path?(tab, "/phoenix_kit/backoffice/users/roles")
        refute Tab.matches_path?(tab, "/phoenix_kit/backoffice/userstats")
      end)
    end

    test "still matches on the default configuration" do
      tab = %Tab{id: :users, label: "Users", path: "/admin/users", match: :exact}

      assert Tab.matches_path?(tab, "/phoenix_kit/admin/users")
    end
  end

  describe "admin_area_path?/1" do
    test "follows the configured segment" do
      with_segment(@renamed, fn ->
        assert Routes.admin_area_path?("/phoenix_kit/backoffice/users")
        assert Routes.admin_area_path?("/phoenix_kit/et/backoffice/users")

        # The old name is just a path like any other once the area has moved.
        refute Routes.admin_area_path?("/phoenix_kit/admin/users")
      end)
    end
  end

  describe "the admin-area redirect guard" do
    # `safe_destination(skip_admin: true)` must never hand an admin URL back to
    # a visitor it just refused — that is the `ERR_TOO_MANY_REDIRECTS` this
    # guard exists for. On a renamed host the refused URL wears the new name,
    # so a guard that only knew `"admin"` would match nothing and the loop
    # would come straight back.
    test "rejects a renamed admin path as a destination", %{renamed_router: renamed} do
      with_segment(@renamed, fn ->
        result =
          Routes.safe_destination(conn_for(renamed),
            scope: plain_user(),
            return_to: "/phoenix_kit/backoffice/users",
            skip_admin: true
          )

        refute result == "/phoenix_kit/backoffice/users"
      end)
    end

    test "accepts a non-admin path as a destination", %{renamed_router: renamed} do
      with_segment(@renamed, fn ->
        assert Routes.safe_destination(conn_for(renamed),
                 scope: plain_user(),
                 return_to: "/phoenix_kit/profile/settings",
                 skip_admin: true
               ) == "/phoenix_kit/profile/settings"
      end)
    end
  end

  defp plain_user do
    %PhoenixKit.Users.Auth.Scope{
      user: nil,
      authenticated?: true,
      cached_roles: ["User"],
      cached_permissions: MapSet.new([])
    }
  end

  describe "Config.admin_panel_label/0" do
    setup do
      on_exit(fn -> Application.delete_env(:phoenix_kit, :admin_panel_label) end)
      Application.delete_env(:phoenix_kit, :admin_panel_label)
      :ok
    end

    test "defaults to the translated Admin Panel preset" do
      assert Config.admin_panel_label() == {:preset, :admin_panel}
    end

    test "an explicit preset wins" do
      Application.put_env(:phoenix_kit, :admin_panel_label, :workspace)
      assert Config.admin_panel_label() == {:preset, :workspace}
    end

    test "a string is carried through verbatim, trimmed" do
      Application.put_env(:phoenix_kit, :admin_panel_label, "  Acme HQ  ")
      assert Config.admin_panel_label() == {:custom, "Acme HQ"}
    end

    test "derives the preset from admin_path so the URL and the wording agree" do
      for {segment, preset} <- [
            {"/backoffice", :backoffice},
            {"/console", :console},
            {"/workspace", :workspace},
            {"/studio", :studio}
          ] do
        with_segment(segment, fn ->
          assert Config.admin_panel_label() == {:preset, preset},
                 "expected #{segment} to derive #{inspect(preset)}"
        end)
      end
    end

    test "treats - and _ as the same segment spelling" do
      for segment <- ["/control-panel", "/control_panel"] do
        with_segment(segment, fn ->
          assert Config.admin_panel_label() == {:preset, :control_panel}
        end)
      end
    end

    test "a segment matching no preset keeps Admin Panel, it does not invent one" do
      with_segment("/x7q", fn ->
        assert Config.admin_panel_label() == {:preset, :admin_panel}
      end)
    end

    test "an explicit label beats the derivation" do
      with_segment("/backoffice", fn ->
        Application.put_env(:phoenix_kit, :admin_panel_label, :console)
        assert Config.admin_panel_label() == {:preset, :console}
      end)
    end

    @tag :capture_log
    test "junk falls back to the derivation rather than raising" do
      # Cosmetic setting: a typo must not take the admin area down in prod.
      with_segment("/portal", fn ->
        for junk <- [:not_a_preset, "", "   ", 42, %{}] do
          Application.put_env(:phoenix_kit, :admin_panel_label, junk)

          assert Config.admin_panel_label() == {:preset, :portal},
                 "expected #{inspect(junk)} to fall through to the derivation"
        end
      end)
    end
  end

  describe "AdminLabel" do
    alias PhoenixKitWeb.Components.Core.AdminLabel

    test "every preset renders to non-empty text" do
      for {preset, _segment} <- Config.admin_label_presets() do
        text = AdminLabel.preset_text(preset)
        assert is_binary(text) and text != "", "#{inspect(preset)} rendered #{inspect(text)}"
      end
    end

    test "every preset in the config list has a preset_text/1 clause" do
      # The two lists live in different modules on purpose (msgids must be
      # literal `gettext/1` calls for extraction). This is what keeps them
      # in step — adding a preset without its clause fails here, loudly,
      # instead of raising FunctionClauseError on somebody's admin header.
      for {preset, _segment} <- Config.admin_label_presets() do
        assert AdminLabel.preset_text(preset)
      end
    end

    test "text/0 renders a custom string verbatim" do
      Application.put_env(:phoenix_kit, :admin_panel_label, "Acme HQ")
      on_exit(fn -> Application.delete_env(:phoenix_kit, :admin_panel_label) end)
      assert AdminLabel.text() == "Acme HQ"
    end
  end
end
