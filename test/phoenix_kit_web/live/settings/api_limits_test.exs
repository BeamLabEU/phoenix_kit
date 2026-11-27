defmodule PhoenixKitWeb.Live.Settings.ApiLimitsTest do
  @moduledoc """
  Settings -> API: the "Limits and advanced" card.

  It edits `api_disabled_tools`, `api_mcp_allowed_origins` and the six numbers of
  `PhoenixKit.API.Config.rate_limits/0`. All or nothing: one invalid field saves
  none of them. Only values that changed are written, each with this admin as the
  actor, so each is a permanent `setting.changed` entry in the Activity log.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Config
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api")

  setup %{conn: conn} do
    {admin, _token} = create_admin_user()
    role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(role.uuid, "api")

    %{conn: log_in_user(conn, admin), admin: admin}
  end

  # The form as it stands, with `overrides` on top: what a browser would submit.
  defp params(overrides) do
    limits = Config.rate_limits()

    %{
      "disabled_tools" => "",
      "mcp_allowed_origins" => "",
      "admin_total_per_min" => "",
      "preauth_fail_per_min" => Integer.to_string(limits.preauth_fail_per_min),
      "admin_per_min" => Integer.to_string(limits.admin_per_min),
      "public_token_per_min" => Integer.to_string(limits.public_token_per_min),
      "public_ip_per_min" => Integer.to_string(limits.public_ip_per_min),
      "new_rows_ip_hour" => Integer.to_string(limits.new_rows_ip_hour),
      "new_rows_global_hour" => Integer.to_string(limits.new_rows_global_hour)
    }
    |> Map.merge(overrides)
  end

  defp save(view, overrides) do
    view
    |> form("#api-limits-form", %{"limits" => params(overrides)})
    |> render_submit()
  end

  defp changed_settings(admin) do
    Activity.list(action: "setting.changed", actor_uuid: admin.uuid).entries
    |> Enum.map(& &1.metadata["key"])
    |> Enum.sort()
  end

  # The page's scope is captured at mount; a plain delete sends no PubSub message,
  # so the page does not hear of it: the window the server-side re-check is for.
  defp drop_api_silently! do
    role = Roles.get_role_by_name("Admin")

    {1, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == "api")
      )

    :ok
  end

  test "the card shows the current values", %{conn: conn} do
    limits = Config.rate_limits()
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#api-limits-card")
    assert has_element?(view, "#api-disabled-tools")
    assert has_element?(view, "#api-mcp-origins")
    assert has_element?(view, ~s(#api-limit-admin-per-min[value="#{limits.admin_per_min}"]))

    assert has_element?(
             view,
             ~s(#api-limit-new-rows-global-hour[value="#{limits.new_rows_global_hour}"])
           )
  end

  test "the total for all keys is optional: empty is none, a number caps, zero is refused",
       %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, ~s(#api-limit-admin-total-per-min[value=""]))
    assert Config.admin_total_per_min() == nil

    # Saving the form as it stands writes no total.
    save(view, %{})
    refute "api_total_rate_per_min" in changed_settings(admin)

    save(view, %{"admin_total_per_min" => "5000"})
    assert Config.admin_total_per_min() == 5000
    assert has_element?(view, ~s(#api-limit-admin-total-per-min[value="5000"]))

    assert save(view, %{"admin_total_per_min" => "0"}) =~
             "Every limit must be a whole number from 1 to 1000000."

    assert Config.admin_total_per_min() == 5000

    save(view, %{"admin_total_per_min" => ""})
    assert Config.admin_total_per_min() == nil
  end

  test "the card names the limits without a module in them", %{conn: conn} do
    {:ok, view, html} = live(conn, @path)

    assert html =~ "Calls per minute, per client token (public API)"
    assert html =~ "New rows per hour, per address"
    assert html =~ "New rows per hour, all addresses"
    assert has_element?(view, "#api-limit-new-rows-help", "Rows a module creates")
    refute has_element?(view, "#api-limit-public-cart-per-min")
  end

  test "the old setting names are ignored: the card shows the defaults, a save leaves the rows alone",
       %{conn: conn, admin: admin} do
    {:ok, _} = Settings.update_setting("api_public_cart_rate_per_min", "55")
    {:ok, _} = Settings.update_setting("api_public_cart_rows_per_ip_hour", "66")
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, ~s(#api-limit-public-token-per-min[value="120"]))
    assert has_element?(view, ~s(#api-limit-new-rows-ip-hour[value="120"]))

    save(view, %{"admin_per_min" => "700"})

    assert changed_settings(admin) == ["api_admin_rate_per_min"]
    assert Settings.get_setting("api_public_cart_rate_per_min") == "55"
    assert Config.rate_limits().public_token_per_min == 120
  end

  test "saving the default with nothing set writes nothing", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, @path)

    save(view, %{})

    assert changed_settings(admin) == []
  end

  test "saving writes the settings, Config reads them back, and the history has them", %{
    conn: conn,
    admin: admin
  } do
    {:ok, view, _html} = live(conn, @path)

    save(view, %{
      "disabled_tools" => "catalogue.list_products\ncatalogue.set_price",
      "mcp_allowed_origins" => "https://assistant.example.com",
      "admin_per_min" => "900"
    })

    assert Config.disabled_tools() == ["catalogue.list_products", "catalogue.set_price"]
    assert Config.mcp_allowed_origins() == ["https://assistant.example.com"]
    assert Config.rate_limits().admin_per_min == 900
    refute has_element?(view, "#api-limits-errors")

    assert changed_settings(admin) ==
             ["api_admin_rate_per_min", "api_disabled_tools", "api_mcp_allowed_origins"]
  end

  test "only the values that changed are written", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, @path)

    save(view, %{"admin_per_min" => "700"})

    assert changed_settings(admin) == ["api_admin_rate_per_min"]
  end

  for bad <- ["0", "-5", "abc", "1.5", "", "1000001"] do
    test "a limit of #{inspect(bad)} is refused and nothing is saved", %{conn: conn, admin: admin} do
      before = Config.rate_limits()
      {:ok, view, _html} = live(conn, @path)

      # A valid change rides along: the refusal must take it back too.
      html = save(view, %{"admin_per_min" => unquote(bad), "public_ip_per_min" => "999"})

      assert has_element?(view, "#api-limits-errors")
      assert html =~ "a whole number from 1 to 1000000"
      assert Config.rate_limits() == before
      assert changed_settings(admin) == []
    end
  end

  test "an invalid tool name refuses the whole form", %{conn: conn, admin: admin} do
    before = Config.rate_limits()
    {:ok, view, _html} = live(conn, @path)

    html = save(view, %{"disabled_tools" => "ok.tool_name\nNot A Tool", "admin_per_min" => "700"})

    assert html =~ "Tool names look like"
    assert Config.disabled_tools() == []
    assert Config.rate_limits() == before
    assert changed_settings(admin) == []
  end

  test "an origin must be a scheme and a host, nothing else", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, @path)

    for bad <- [
          "example.com",
          "ftp://example.com",
          "https://example.com/path",
          "https://",
          "javascript:alert(1)"
        ] do
      html = save(view, %{"mcp_allowed_origins" => bad})
      assert html =~ "Origins look like", "#{inspect(bad)} was accepted"
    end

    assert Config.mcp_allowed_origins() == []
    assert changed_settings(admin) == []
  end

  test "blank lines, duplicates and Windows line ends are cleaned up", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    save(view, %{"disabled_tools" => " a.b_c \r\n\r\na.b_c\r\nd.e_f\n"})

    assert Config.disabled_tools() == ["a.b_c", "d.e_f"]
  end

  test "emptying a list clears the setting", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)
    save(view, %{"disabled_tools" => "a.b_c"})
    assert Config.disabled_tools() == ["a.b_c"]

    save(view, %{"disabled_tools" => ""})

    assert Config.disabled_tools() == []
  end

  test "params of the wrong shape do not crash the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert render_submit(view, "save_limits", %{"limits" => "not a map"}) =~
             "That action is not available."

    assert render_submit(view, "save_limits", %{}) =~ "That action is not available."
    assert has_element?(view, "#api-settings-page")
  end

  test "save_limits after the person lost api writes nothing", %{conn: conn, admin: admin} do
    before = Config.rate_limits()
    {:ok, view, _html} = live(conn, @path)

    drop_api_silently!()
    # Not vacuous: the page has not heard of it, its scope still says api.
    assert Scope.can?(:sys.get_state(view.pid).socket.assigns.phoenix_kit_current_scope, "api")

    html = save(view, %{"admin_per_min" => "700", "disabled_tools" => "a.b_c"})

    assert html =~ "You are not allowed to do that."
    assert Config.rate_limits() == before
    assert Config.disabled_tools() == []
    assert changed_settings(admin) == []
  end
end
