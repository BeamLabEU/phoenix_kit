defmodule PhoenixKit.API.AccessAnyOfTest do
  @moduledoc """
  `PhoenixKit.API.Access.fresh_scope/2`: the rights of a person read again, where any one
  of several permissions will do (the "My API keys" page takes `api_personal_keys` or `api`).
  Both the scope captured at mount and the full scope built now must hold one of them.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.Access
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions

  @any ["api_personal_keys", "api"]

  test "a holder of either permission gets a full scope built now" do
    {user, _role} = user_without_api(["api_personal_keys"])
    assert {:ok, %Scope{} = fresh} = Access.fresh_scope(scope_of(user), @any)
    assert Scope.user_uuid(fresh) == user.uuid
    assert Scope.can?(fresh, "api_personal_keys")

    {_user, _role, api_scope} = api_holder(["media"])
    assert {:ok, _fresh} = Access.fresh_scope(api_scope, @any)
  end

  test "fresh_scope/1 still asks for api alone" do
    {user, _role} = user_without_api(["api_personal_keys"])
    assert :error = Access.fresh_scope(scope_of(user))
  end

  test "a permission taken away since mount is noticed" do
    {user, role} = user_without_api(["api_personal_keys"])
    scope = scope_of(user)
    :ok = Permissions.revoke_permission(role.uuid, "api_personal_keys")

    assert :error = Access.fresh_scope(scope, @any)
  end

  test "the scope captured at mount must hold one of them too" do
    {user, _role} = user_without_api(["api_personal_keys"])
    # The session acts as a role without the permission (role switcher): narrowed scope.
    narrowed = %{scope_of(user) | cached_permissions: MapSet.new()}

    assert :error = Access.fresh_scope(narrowed, @any)
  end

  test "a blocked person and nobody are refused" do
    {user, _role} = user_without_api(["api_personal_keys"])
    scope = scope_of(user)
    {:ok, _} = Auth.update_user_status(user, %{is_active: false})

    assert :error = Access.fresh_scope(scope, @any)
    assert :error = Access.fresh_scope(nil, @any)
    assert :error = Access.fresh_scope(scope_of(owner_user()), [])
  end
end
