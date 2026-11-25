defmodule PhoenixKit.Modules.Storage.PublicPersonalLibraryTest do
  @moduledoc """
  The public library a host may give its accounts (`ensure_public_library/2`,
  `backfill_public_libraries/1`), the slugs a host reserves for its pages
  (`reserved_slug?/1`, `change_library_slug/3`) and the usernames it reserves
  (`User.reserved_username?/1`).
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.{Libraries, Library}
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  setup do
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    :ok
  end

  defp register!(attrs \\ %{}) do
    {:ok, user} =
      Auth.register_user(
        Map.merge(
          %{
            "email" => "public-personal-#{System.unique_integer([:positive])}@example.com",
            "password" => "ValidPassword123!"
          },
          attrs
        )
      )

    user
  end

  defp owned(user),
    do:
      Repo.all(
        from(l in Library,
          where: l.kind == "user" and l.owner_uuid == ^user.uuid,
          order_by: l.inserted_at
        )
      )

  defp with_config(key, value, fun) do
    old = Application.get_env(:phoenix_kit, key)
    Application.put_env(:phoenix_kit, key, value)

    try do
      fun.()
    after
      if old == nil,
        do: Application.delete_env(:phoenix_kit, key),
        else: Application.put_env(:phoenix_kit, key, old)
    end
  end

  describe "ensure_public_library/2" do
    test "makes a public library named Public, once" do
      user = register!()

      assert {:ok, %Library{name: "Public", slug: "public", visibility: "site"} = library} =
               Libraries.ensure_public_library(user.uuid)

      assert Libraries.public?(library)
      assert {:ok, :exists} = Libraries.ensure_public_library(user.uuid)

      assert length(owned(user)) == 1
    end

    test "is never the default; the personal one made first is" do
      user = register!()

      assert {:ok, %Library{name: "Private", is_default: true, visibility: "private"}} =
               Libraries.ensure_personal_library(user.uuid, name: "Private")

      assert {:ok, %Library{is_default: false}} = Libraries.ensure_public_library(user.uuid)
      assert %{name: "Private"} = Libraries.default_user_library(user.uuid)
    end

    test "the two are independent: either one does not count as the other" do
      user = register!()
      assert {:ok, %Library{}} = Libraries.ensure_public_library(user.uuid)
      assert {:ok, %Library{visibility: "private"}} = Libraries.ensure_personal_library(user.uuid)
      assert Enum.sort(Enum.map(owned(user), & &1.visibility)) == ["private", "site"]
    end

    test "a user who trashed theirs is not given another" do
      user = register!()
      {:ok, library} = Libraries.ensure_public_library(user.uuid)

      Repo.update_all(from(l in Library, where: l.uuid == ^library.uuid),
        set: [trashed_at: DateTime.utc_now() |> DateTime.truncate(:second), slug: nil]
      )

      assert {:ok, :exists} = Libraries.ensure_public_library(user.uuid)
    end

    test ":name names it" do
      user = register!()

      assert {:ok, %Library{name: "Open", slug: "open"}} =
               Libraries.ensure_public_library(user.uuid, name: "Open")
    end

    test "makes nothing while user libraries are off" do
      {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", false)
      user = register!()
      assert {:error, :user_libraries_off} = Libraries.ensure_public_library(user.uuid)
      assert owned(user) == []
    end

    test "is written to the history as made by the system" do
      user = register!()
      {:ok, library} = Libraries.ensure_public_library(user.uuid)

      assert Repo.exists?(
               from(e in PhoenixKit.Activity.Entry,
                 where:
                   e.action == "storage.library_published" and e.resource_uuid == ^library.uuid
               )
             )
    end
  end

  describe "backfill_public_libraries/1" do
    test "makes one for an account that has none, and repeats safely" do
      user = register!()

      assert %{created: created} = Libraries.backfill_public_libraries()
      assert created >= 1
      assert Enum.any?(owned(user), &(&1.visibility == "site"))

      assert %{created: 0, failed: 0} = Libraries.backfill_public_libraries()
      assert length(owned(user)) == 1
    end
  end

  describe "reserved slugs" do
    test "a reserved slug is skipped when a library is named, and refused when changed" do
      with_config(:reserved_library_slugs, ["Photos", "admin"], fn ->
        assert Libraries.reserved_slug?("photos")
        assert Libraries.reserved_slug?("ADMIN")
        refute Libraries.reserved_slug?("private")
        refute Libraries.reserved_slug?(nil)

        user = register!()

        assert {:ok, %Library{slug: "photos-2"}} =
                 Libraries.ensure_public_library(user.uuid, name: "Photos")

        [library] = owned(user)
        assert {:error, changeset} = Libraries.change_library_slug(library, "admin")
        assert {"is reserved", _} = changeset.errors[:slug]
      end)
    end

    test "nothing is reserved unless the host says so" do
      refute Libraries.reserved_slug?("photos")
    end
  end

  describe "change_library_slug/3" do
    test "changes the slug, keeping name and owner" do
      user = register!()
      {:ok, library} = Libraries.ensure_personal_library(user.uuid, name: "Private")
      {:ok, library} = Libraries.change_library_slug(library, "mine")
      assert %Library{slug: "mine", name: "Private"} = Repo.get!(Library, library.uuid)
    end

    test "refuses a badly shaped slug and one the owner already uses" do
      user = register!()
      {:ok, private} = Libraries.ensure_personal_library(user.uuid, name: "Private")
      {:ok, _public} = Libraries.ensure_public_library(user.uuid)

      assert {:error, %{errors: [slug: {_, _}]}} =
               Libraries.change_library_slug(private, "Not A Slug")

      assert {:error, %{errors: errors}} = Libraries.change_library_slug(private, "public")
      assert Keyword.has_key?(errors, :slug)
    end

    test "two owners may use the same slug" do
      a = register!()
      b = register!()
      {:ok, la} = Libraries.ensure_personal_library(a.uuid, name: "Private")
      {:ok, lb} = Libraries.ensure_personal_library(b.uuid, name: "Private")
      assert {:ok, %{slug: "shared"}} = Libraries.change_library_slug(la, "shared")
      assert {:ok, %{slug: "shared"}} = Libraries.change_library_slug(lb, "shared")
    end
  end

  describe "reserved usernames" do
    test "are refused when asked for, case-insensitively" do
      with_config(:reserved_usernames, ["admin", "Photos"], fn ->
        assert User.reserved_username?("ADMIN")
        assert User.reserved_username?("photos")
        refute User.reserved_username?("fotkin")

        assert {:error, changeset} =
                 Auth.register_user(%{
                   "email" => "res-#{System.unique_integer([:positive])}@example.com",
                   "password" => "ValidPassword123!",
                   "username" => "Admin"
                 })

        assert {"is reserved", _} = changeset.errors[:username]
      end)
    end

    test "a name generated from an email address that is reserved gets a number" do
      with_config(:reserved_usernames, ["bookings"], fn ->
        user =
          register!(%{"email" => "bookings@example-#{System.unique_integer([:positive])}.com"})

        assert user.username == "bookings_1"
      end)
    end

    test "nothing is reserved unless the host says so" do
      refute User.reserved_username?("admin")
    end
  end
end
