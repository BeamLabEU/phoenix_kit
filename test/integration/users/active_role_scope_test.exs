defmodule PhoenixKit.Integration.Users.ActiveRoleScopeTest do
  @moduledoc """
  `Scope.for_user/1` against real roles and permissions: with the role
  switcher on, a user acting as one role gets that role's access and nothing
  else.

  Settings writes stay inside each test's sandbox transaction, but role-order
  changes also update the shared system roles. Run synchronously to avoid
  conflicting with another sandbox transaction reordering those same rows.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  defp create_user(role_names) do
    {:ok, user} =
      Auth.register_user(%{
        email: "active_role_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    for name <- role_names, do: {:ok, _} = Roles.assign_role(user, name)
    user
  end

  defp create_role(prefix) do
    {:ok, role} = Roles.create_role(%{name: "#{prefix}#{System.unique_integer([:positive])}"})
    role
  end

  # What `UserToken.verify_session_token_query/1` does for a session that
  # switched: the role rides on the user's virtual field.
  defp store_active_role(user, role), do: %{user | active_role_uuid: role.uuid}

  defp enable, do: Settings.update_boolean_setting("role_switcher_enabled", true)

  setup do
    seller = create_role("Seller")
    buyer = create_role("Buyer")
    {:ok, _} = Permissions.grant_permission(seller.uuid, "dashboard")
    {:ok, _} = Permissions.grant_permission(buyer.uuid, "media")
    %{seller: seller, buyer: buyer}
  end

  describe "switcher off (the default)" do
    test "a multi-role user keeps the union", %{seller: seller} do
      user = create_user(["Admin", seller.name]) |> store_active_role(seller)
      scope = Scope.for_user(user)

      assert Scope.has_role?(scope, "Admin")
      assert Scope.has_role?(scope, seller.name)
      assert Scope.can_access_admin_area?(scope)
      assert Scope.active_role(scope) == nil
      assert Enum.sort(Scope.held_roles(scope)) == Enum.sort(scope.cached_roles)
    end
  end

  describe "switcher on" do
    setup do
      enable()
      :ok
    end

    test "an Admin with nothing stored acts as Admin", %{seller: seller} do
      user = create_user(["Admin", seller.name])
      scope = Scope.for_user(user)

      assert Scope.active_role(scope).name == "Admin"
      assert Scope.has_role?(scope, "Admin")
      refute Scope.has_role?(scope, seller.name)
      assert seller.name in Scope.held_roles(scope)
    end

    test "an Admin acting as Seller has no admin access", %{seller: seller} do
      user = create_user(["Admin", seller.name]) |> store_active_role(seller)
      scope = Scope.for_user(user)

      assert Scope.active_role(scope).uuid == seller.uuid
      refute Scope.has_role?(scope, "Admin")
      refute Scope.system_role?(scope)
      refute Scope.has_module_access?(scope, "users")
      assert Scope.has_module_access?(scope, "dashboard")
      assert "Admin" in Scope.held_roles(scope)
    end

    test "permissions come from the active role only", %{seller: seller, buyer: buyer} do
      user = create_user([seller.name, buyer.name])

      # Nothing stored: the default is the first switchable role in ROLE ORDER
      # — Seller was created before Buyer, so it comes first.
      scope = Scope.for_user(user)
      assert Scope.active_role(scope).uuid == seller.uuid
      assert Scope.has_module_access?(scope, "dashboard")
      refute Scope.has_module_access?(scope, "media")

      scope = user |> store_active_role(buyer) |> Scope.for_user()
      assert Scope.has_module_access?(scope, "media")
      refute Scope.has_module_access?(scope, "dashboard")
    end

    test "the operator's role order decides the default", %{seller: seller, buyer: buyer} do
      user = create_user([seller.name, buyer.name])
      :ok = Roles.reorder_roles([buyer.uuid, seller.uuid])

      assert Scope.active_role(Scope.for_user(user)).uuid == buyer.uuid
    end

    test "a user loaded without a session acts as their default role", %{seller: seller} do
      user = create_user(["Admin", seller.name])
      # `Auth.get_user/1` (jobs, admin lists) never fills the virtual field:
      # the default applies, never the union.
      scope = user.uuid |> Auth.get_user() |> Scope.for_user()

      assert Scope.active_role(scope).name == "Admin"
      assert Scope.has_role?(scope, "Admin")
      refute Scope.has_role?(scope, seller.name)
    end

    test "a stored role the user no longer holds falls back to the default", %{seller: seller} do
      user = create_user(["Admin", seller.name]) |> store_active_role(seller)
      {:ok, _} = Roles.remove_role(user, seller.name)

      scope = Scope.for_user(user)
      # One switchable role left: nothing to narrow.
      assert Scope.active_role(scope) == nil
      assert Scope.has_role?(scope, "Admin")
    end

    test "always-on roles apply in every mode", %{seller: seller} do
      newsletter = create_role("Newsletter")
      {:ok, _} = Permissions.grant_permission(newsletter.uuid, "media")
      Settings.update_setting("role_switcher_always_on_roles", newsletter.uuid)

      user = create_user(["Admin", seller.name, newsletter.name]) |> store_active_role(seller)
      scope = Scope.for_user(user)

      assert Scope.active_role(scope).uuid == seller.uuid
      assert Scope.has_role?(scope, newsletter.name)
      assert Scope.has_module_access?(scope, "media")
      assert Scope.has_module_access?(scope, "dashboard")
      refute Scope.has_role?(scope, "Admin")
    end

    test "User is always on, never a mode", %{seller: seller} do
      user = create_user([seller.name])
      scope = Scope.for_user(user)

      assert Scope.active_role(scope) == nil
      assert Scope.has_role?(scope, "User")
    end

    test "narrow: false builds the union", %{seller: seller} do
      user = create_user(["Admin", seller.name]) |> store_active_role(seller)
      scope = Scope.for_user(user, narrow: false)

      assert Scope.active_role(scope) == nil
      assert Scope.has_role?(scope, "Admin")
      assert Scope.has_role?(scope, seller.name)
    end
  end

  describe "Owner acting as another role" do
    setup :demote_seed_owner

    setup do
      enable()
      :ok
    end

    test "is not Owner and does not get every permission", %{seller: seller} do
      {:ok, owner} =
        Auth.register_user(%{
          email: "active_role_owner_#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      assert Roles.user_has_role_owner?(owner)
      {:ok, _} = Roles.assign_role(owner, seller.name)

      assert Scope.owner?(Scope.for_user(owner))

      scope = owner |> store_active_role(seller) |> Scope.for_user()
      refute Scope.owner?(scope)
      refute Scope.superadmin?(scope)
      refute Scope.has_module_access?(scope, "users")
      assert "Owner" in Scope.held_roles(scope)
    end
  end
end
