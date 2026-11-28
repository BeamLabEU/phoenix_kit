defmodule PhoenixKitWeb.Live.Settings.ApiRateLimitTest do
  @moduledoc """
  Settings -> API: a key's own rate limit, on the create form and in the key's "Rate limit"
  dialog. The key comes from the server (the uuid stored when the dialog was opened, found
  again in the person's own key list); the value is checked again; a forged event and a
  lost `api` change nothing.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api")

  setup %{conn: conn} do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()

    {admin, _token} = create_admin_user()
    role = Roles.get_role_by_name("Admin")

    for key <- ["api", "media"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

    scope = KeyTestSupport.scope_of(admin)

    {key, _token} =
      KeyTestSupport.create_key!(admin, scope, %{
        name: "Limited",
        scopes: [KeyTestSupport.read_scope()]
      })

    %{conn: log_in_user(conn, admin), admin: admin, scope: scope, key: key}
  end

  defp open_dialog(view, key) do
    view
    |> element(~s(#api-key-menu-#{key.uuid} button[phx-click="request_edit_rate_limit"]))
    |> render_click()
  end

  defp save(view, value) do
    view
    |> form("#edit-key-rate-limit-form", %{"key_rate_limit" => %{"value" => value}})
    |> render_submit()
  end

  test "an existing key has no own limit and shows no badge", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)
    refute has_element?(view, "#api-key-rate-limit-#{key.uuid}")
  end

  test "the dialog sets and clears the limit", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)

    open_dialog(view, key)
    assert has_element?(view, "#edit-key-rate-limit-modal")
    html = save(view, "12")

    assert html =~ "The rate limit was saved."
    assert Keys.get_key(key.uuid).rate_limit_per_minute == 12
    assert has_element?(view, "#api-key-rate-limit-#{key.uuid}")

    open_dialog(view, key)
    save(view, "")
    assert Keys.get_key(key.uuid).rate_limit_per_minute == nil
  end

  test "zero, negative and non-numbers are refused in the dialog", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)

    for bad <- ["0", "-4", "abc", "1.5", "1000001"] do
      open_dialog(view, key)
      html = save(view, bad)
      assert html =~ "whole number from 1 to 1000000"
      assert Keys.get_key(key.uuid).rate_limit_per_minute == nil
    end
  end

  test "the create form takes a limit and refuses a bad one", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, @path)

    render_click(view, "open_create_key", %{})

    view
    |> form("#create-api-key-form", %{"key" => %{"name" => "With limit", "rate_limit" => "0"}})
    |> render_submit()

    refute Enum.any?(Keys.list_keys(scope), &(&1.name == "With limit"))

    view
    |> form("#create-api-key-form", %{"key" => %{"name" => "With limit", "rate_limit" => "30"}})
    |> render_submit()

    assert [%{rate_limit_per_minute: 30}] =
             Enum.filter(Keys.list_keys(scope), &(&1.name == "With limit"))
  end

  test "a forged save without an opened dialog changes nothing", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)

    render_submit(view, "save_key_rate_limit", %{
      "key_rate_limit" => %{"value" => "3", "uuid" => key.uuid}
    })

    assert Keys.get_key(key.uuid).rate_limit_per_minute == nil
  end

  test "a forged dialog for a key the person may not manage is refused", %{conn: conn} do
    {other, _role} = KeyTestSupport.user_with(["media"])
    {foreign, _token} = KeyTestSupport.issue_key!(other, [KeyTestSupport.read_scope()])

    {:ok, view, _html} = live(conn, @path)
    render_click(view, "request_edit_rate_limit", %{"uuid" => foreign.uuid})
    render_submit(view, "save_key_rate_limit", %{"key_rate_limit" => %{"value" => "3"}})

    assert Keys.get_key(foreign.uuid).rate_limit_per_minute == nil
  end

  test "losing api mid-session: the save is refused", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)
    open_dialog(view, key)

    role = Roles.get_role_by_name("Admin")

    {1, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == "api")
      )

    # The page answers by redirecting away (or by a flash); either way nothing is saved.
    try do
      save(view, "5")
    catch
      :exit, _redirected -> :ok
    end

    assert Keys.get_key(key.uuid).rate_limit_per_minute == nil
  end
end
