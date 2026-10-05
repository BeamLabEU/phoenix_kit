defmodule PhoenixKit.Integration.Users.RoleOrderTest do
  @moduledoc """
  Role order (`phoenix_kit_user_roles.position`, V190), the sessions that
  carry an active role, and what removing a role does to them.
  """
  # Reordering updates the committed system roles as well as this test's roles.
  # Run after async cases so two sandbox transactions cannot lock them in opposite orders.
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.Sessions

  defp create_role(prefix) do
    {:ok, role} = Roles.create_role(%{name: "#{prefix}#{System.unique_integer([:positive])}"})
    role
  end

  defp create_user(role_names) do
    {:ok, user} =
      Auth.register_user(%{
        email: "role_order_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    for name <- role_names, do: {:ok, _} = Roles.assign_role(user, name)
    user
  end

  defp session_in_role(user, role) do
    token = Auth.generate_user_session_token(user)

    if role do
      Repo.update_all(from(t in UserToken, where: t.token == ^token),
        set: [active_role_uuid: role.uuid]
      )
    end

    token
  end

  defp session_alive?(token), do: Auth.get_user_by_session_token(token) != nil

  describe "role order" do
    test "system roles come first, custom roles in creation order" do
      seller = create_role("Seller")
      buyer = create_role("Buyer")

      names = Roles.list_roles() |> Enum.map(& &1.name)
      assert ["Owner", "Admin", "User" | custom] = names

      assert Enum.find_index(custom, &(&1 == seller.name)) <
               Enum.find_index(custom, &(&1 == buyer.name))

      assert buyer.position > seller.position
    end

    test "reorder_roles/1 sets the order and keeps unlisted roles after" do
      seller = create_role("Seller")
      buyer = create_role("Buyer")

      :ok = Roles.reorder_roles([buyer.uuid, seller.uuid])

      uuids = Roles.list_roles() |> Enum.map(& &1.uuid)
      assert Enum.take(uuids, 2) == [buyer.uuid, seller.uuid]
      assert Roles.get_role_by_name("Owner").uuid in uuids
    end

    test "move_role/2 moves one step and stops at the ends" do
      seller = create_role("Seller")
      buyer = create_role("Buyer")
      before = Roles.list_roles() |> Enum.map(& &1.uuid)

      :ok = Roles.move_role(buyer.uuid, :up)
      after_up = Roles.list_roles() |> Enum.map(& &1.uuid)

      assert Enum.find_index(after_up, &(&1 == buyer.uuid)) ==
               Enum.find_index(before, &(&1 == seller.uuid))

      :ok = Roles.move_role(buyer.uuid, :down)
      assert Roles.list_roles() |> Enum.map(& &1.uuid) == before

      # The last role cannot move further down; the first not further up.
      :ok = Roles.move_role(buyer.uuid, :down)
      assert Roles.list_roles() |> Enum.map(& &1.uuid) == before
      :ok = Roles.move_role(hd(before), :up)
      assert Roles.list_roles() |> Enum.map(& &1.uuid) == before
    end

    test "get_user_role_records/1 follows the order" do
      seller = create_role("Seller")
      buyer = create_role("Buyer")
      user = create_user([seller.name, buyer.name])

      assert [%{name: "User"}, %{uuid: seller_uuid}, %{uuid: buyer_uuid}] =
               Roles.get_user_role_records(user)

      assert {seller_uuid, buyer_uuid} == {seller.uuid, buyer.uuid}

      # Reordering puts the two custom roles at the very front, before User.
      :ok = Roles.reorder_roles([buyer.uuid, seller.uuid])

      assert [%{uuid: ^buyer_uuid}, %{uuid: ^seller_uuid}, %{name: "User"}] =
               Roles.get_user_role_records(user)
    end
  end

  describe "removing a role" do
    setup do
      Settings.update_boolean_setting("role_switcher_enabled", true)
      :ok
    end

    test "signs out only the sessions acting as it", %{} do
      seller = create_role("Seller")
      user = create_user(["Admin", seller.name])

      as_seller = session_in_role(user, seller)
      as_admin = session_in_role(user, Roles.get_role_by_name("Admin"))
      as_default = session_in_role(user, nil)

      assert {:ok, _} = Roles.remove_role(user, seller.name)

      refute session_alive?(as_seller)
      assert session_alive?(as_admin)
      assert session_alive?(as_default)
    end

    test "sync_user_roles/3 revokes the same way" do
      seller = create_role("Seller")
      user = create_user(["Admin", seller.name])
      as_seller = session_in_role(user, seller)
      as_admin = session_in_role(user, Roles.get_role_by_name("Admin"))

      assert {:ok, _} = Roles.sync_user_roles(user, ["Admin"], actor: :system)

      refute session_alive?(as_seller)
      assert session_alive?(as_admin)
    end
  end

  describe "sessions lists" do
    test "carry the role each session acts as" do
      Settings.update_boolean_setting("role_switcher_enabled", true)
      seller = create_role("Seller")
      user = create_user(["Admin", seller.name])

      as_seller = session_in_role(user, seller)
      as_default = session_in_role(user, nil)

      by_token =
        user
        |> Sessions.list_user_sessions()
        |> Map.new(&{&1.token_uuid, &1.active_role})

      seller_uuid = token_uuid(as_seller)
      default_uuid = token_uuid(as_default)

      assert %{^seller_uuid => seller_name, ^default_uuid => "Admin"} = by_token
      assert seller_name == seller.name

      assert %{active_role: "Admin"} = Sessions.get_session_info(default_uuid)

      assert [%{active_role: _}, %{active_role: _}] =
               Sessions.list_user_device_sessions(user, as_default)
    end

    test "show nothing while the switcher is off" do
      seller = create_role("Seller")
      user = create_user(["Admin", seller.name])
      _token = session_in_role(user, seller)

      assert [%{active_role: nil}] = Sessions.list_user_sessions(user)
      assert ActiveRole.session_role_names([]) == %{}
    end
  end

  defp token_uuid(token) do
    Repo.one!(from(t in UserToken, where: t.token == ^token, select: t.uuid))
  end
end
