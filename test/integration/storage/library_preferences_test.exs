defmodule PhoenixKit.Modules.Storage.LibraryPreferencesTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage.{Libraries, Library, VariantSets}
  alias PhoenixKit.Modules.Storage.Libraries.Preferences
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Live.Components.LibraryPreferences

  setup do
    previous = Application.fetch_env(:phoenix_kit, :library_owner_publication)
    Application.put_env(:phoenix_kit, :library_owner_publication, false)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :library_owner_publication, value)
        :error -> Application.delete_env(:phoenix_kit, :library_owner_publication)
      end
    end)

    {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", false)
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    {:ok, role} = Roles.create_role(%{name: "Publisher #{System.unique_integer([:positive])}"})

    for key <- ~w(storage storage.create_library storage.public_library),
        do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

    owner = user!(role.name)
    {:ok, library} = Libraries.create_user_library(scope(owner), %{"name" => "Photos"})
    %{owner: owner, role: role, library: library}
  end

  defp user!(role) do
    {:ok, user} =
      Auth.register_user(%{
        email: "library-prefs-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role)
    user
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp publish(scope, library),
    do: Preferences.update(scope, library.uuid, %{"access" => "anonymous", "confirm" => "true"})

  test "an anonymous scope is refused without looking up a missing user", ctx do
    assert {:error, :not_allowed} =
             Preferences.update(Scope.for_user(nil), ctx.library.uuid, %{"name" => "Changed"})
  end

  test "a revoked publication permission takes effect with a stale scope", ctx do
    stale = scope(ctx.owner)
    :ok = Permissions.revoke_permission(ctx.role.uuid, "storage.public_library")

    assert {:error, :publishing_not_allowed} = publish(stale, ctx.library)
    assert Repo.get!(Library, ctx.library.uuid).visibility == "private"
  end

  test "a former administrator cannot rename someone else's library", ctx do
    admin = user!("Admin")
    stale = scope(admin)
    {:ok, _} = Roles.remove_role(admin, "Admin")

    assert {:error, :not_allowed} =
             Preferences.update(stale, ctx.library.uuid, %{"name" => "Changed"})

    assert Repo.get!(Library, ctx.library.uuid).name == "Photos"
  end

  test "a blocked owner cannot change preferences", ctx do
    stale = scope(ctx.owner)
    ctx.owner |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

    assert {:error, :not_allowed} =
             Preferences.update(stale, ctx.library.uuid, %{"name" => "Changed"})
  end

  test "an active owner can save and publish with their current permission", ctx do
    assert {:ok, updated} = publish(scope(ctx.owner), ctx.library)
    assert updated.visibility == "site"
    assert is_binary(updated.settings["access_revision"])
  end

  test "refreshing never widens a switched role to another held role", ctx do
    {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", true)
    {:ok, limited} = Roles.create_role(%{name: "Limited #{System.unique_integer([:positive])}"})
    {:ok, _} = Permissions.grant_permission(limited.uuid, "storage")
    {:ok, _} = Roles.assign_role(ctx.owner, limited.name)
    user = Repo.get!(Auth.User, ctx.owner.uuid)
    narrowed = Scope.for_user(%{user | active_role_uuid: limited.uuid})
    assert Scope.active_role(narrowed).uuid == limited.uuid

    assert {:error, :publishing_not_allowed} = publish(narrowed, ctx.library)
    assert {:ok, _} = Preferences.update(narrowed, ctx.library.uuid, %{"name" => "My photos"})
  end

  test "another held role cannot restore a permission removed from the active role", ctx do
    {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", true)

    {:ok, other} =
      Roles.create_role(%{name: "Other publisher #{System.unique_integer([:positive])}"})

    {:ok, _} = Permissions.grant_permission(other.uuid, "storage.public_library")
    {:ok, _} = Roles.assign_role(ctx.owner, other.name)
    user = Repo.get!(Auth.User, ctx.owner.uuid)
    stale = Scope.for_user(%{user | active_role_uuid: ctx.role.uuid})
    assert Scope.active_role(stale).uuid == ctx.role.uuid
    :ok = Permissions.revoke_permission(ctx.role.uuid, "storage.public_library")

    assert {:error, :publishing_not_allowed} = publish(stale, ctx.library)
  end

  test "a former administrator cannot change renditions through the open component", ctx do
    admin = user!("Admin")
    {:ok, set} = VariantSets.create_variant_set(%{name: "Preview", selectable: true})

    {:ok, socket} =
      LibraryPreferences.update(
        %{
          id: "library-preferences",
          library_uuid: ctx.library.uuid,
          scope: scope(admin)
        },
        %Phoenix.LiveView.Socket{}
      )

    {:ok, _} = Roles.remove_role(admin, "Admin")

    {:noreply, socket} =
      LibraryPreferences.handle_event("renditions", %{"set" => set.uuid}, socket)

    assert socket.assigns.error
    assert is_nil(Repo.get!(Library, ctx.library.uuid).variant_set_uuid)
  end
end
