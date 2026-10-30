defmodule PhoenixKit.Modules.Storage.LibraryAudienceTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Storage.{Libraries, Library}
  alias PhoenixKit.Modules.Storage.Libraries.Preferences
  alias PhoenixKit.Users.Auth.{Scope, User}

  defp library(attrs) do
    struct!(Library, Map.merge(%{kind: "user", visibility: "site", settings: %{}}, attrs))
  end

  defp scope(uuid, active \\ true) do
    %Scope{
      user: %User{uuid: uuid, is_active: active},
      authenticated?: true,
      cached_roles: [],
      cached_permissions: MapSet.new()
    }
  end

  test "published does not mean anonymous when the audience requires an account" do
    library = library(%{settings: %{"public_audience" => "authenticated"}})
    assert Libraries.published?(library)
    refute Libraries.public?(library)
    refute Libraries.audience_allows?(nil, library)
    refute Libraries.audience_allows?(Scope.for_user(nil), library)
    assert Libraries.audience_allows?(scope(Ecto.UUID.generate()), library)
    refute Libraries.audience_allows?(scope(Ecto.UUID.generate(), false), library)
  end

  test "anonymous publication is explicit and suspension and trash close that audience" do
    public = library(%{})
    assert Libraries.public?(public)
    assert Libraries.audience_allows?(nil, public)
    refute Libraries.audience_allows?(nil, %{public | visibility: "private"})
    refute Libraries.audience_allows?(nil, %{public | settings: %{"suspended" => true}})
    refute Libraries.audience_allows?(nil, %{public | trashed_at: DateTime.utc_now()})
    refute Libraries.public?(%{public | kind: "system"})
  end

  test "only the owner and site administrators may publish or edit addresses" do
    owner = Ecto.UUID.generate()
    library = library(%{owner_uuid: owner})
    assert Preferences.can_manage?(scope(owner), library)
    refute Preferences.can_manage?(scope(Ecto.UUID.generate()), library)
    refute Preferences.can_manage?(nil, library)
    admin = %{scope(Ecto.UUID.generate()) | cached_roles: ["Admin"]}
    assert Preferences.can_manage?(admin, library)
    refute Preferences.can_manage?(admin, %{library | kind: "system"})
    refute Preferences.can_manage?(admin, %{library | trashed_at: DateTime.utc_now()})
  end

  test "the host's public-library permission cannot be bypassed by editing an existing private library" do
    previous = Application.fetch_env(:phoenix_kit, :library_owner_publication)
    Application.put_env(:phoenix_kit, :library_owner_publication, false)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :library_owner_publication, value)
        :error -> Application.delete_env(:phoenix_kit, :library_owner_publication)
      end
    end)

    owner = Ecto.UUID.generate()
    private = library(%{owner_uuid: owner, visibility: "private"})
    scope = scope(owner)
    refute Preferences.can_publish?(scope, private)
    permitted = %{scope | cached_permissions: MapSet.new(["storage", "storage.public_library"])}
    assert Preferences.can_publish?(permitted, private)
    Application.put_env(:phoenix_kit, :library_owner_publication, true)
    assert Preferences.can_publish?(scope, private)
    refute Preferences.can_publish?(scope(Ecto.UUID.generate()), private)
  end
end
