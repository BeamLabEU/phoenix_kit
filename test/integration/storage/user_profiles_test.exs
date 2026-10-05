defmodule PhoenixKit.Modules.Storage.UserProfilesTest do
  @moduledoc """
  The profile of a user's own storage (V206): "only" and "backup" modes, the
  backup mode's snapshot of the Default, a user's buckets and profiles kept
  apart from the site's and from each other, the choice of storage locked once
  made, and the clean-up when a user's storage goes.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Library, Profiles, StorageProfile}
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  setup do
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-user-profiles")

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    %{user: user!(), other: user!()}
  end

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "user-profiles-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp site_bucket!(attrs \\ %{}) do
    {:ok, bucket} =
      Storage.create_bucket(
        Map.merge(
          %{
            name: "site-#{System.unique_integer([:positive])}",
            provider: "local",
            endpoint: Path.join(System.tmp_dir!(), "pk_user_profiles"),
            enabled: true
          },
          attrs
        )
      )

    bucket
  end

  defp owned_bucket!(owner) do
    {:ok, %{uuid: connection}} =
      Integrations.add_connection("object_storage", "mine", nil, owner: {:user, owner})

    {:ok, _} =
      Integrations.save_setup(connection, %{"access_key" => "AKIA", "secret_key" => "s"}, nil,
        owner: {:user, owner}
      )

    {:ok, bucket} =
      Storage.create_owned_bucket(owner, %{
        "name" => "Mine #{System.unique_integer([:positive])}",
        "provider" => "s3",
        "bucket_name" => "mine",
        "integration_uuid" => connection
      })

    bucket
  end

  defp library!(user) do
    slug = "l#{System.unique_integer([:positive])}"

    Repo.insert!(%Library{
      name: "Mine #{slug}",
      kind: "user",
      owner_uuid: user.uuid,
      visibility: "private",
      key_prefix: slug,
      slug: slug
    })
  end

  defp rows(profile),
    do: Map.new(profile.buckets, &{to_string(&1.bucket_uuid), &1})

  describe "create_user_profile/3, only mode" do
    test "the user's bucket is the one primary", %{user: user} do
      bucket = owned_bucket!(user.uuid)

      assert {:ok, %StorageProfile{} = profile} =
               Profiles.create_user_profile(user.uuid, bucket, :only)

      assert profile.owner_uuid == user.uuid

      # The user's bucket is S3-compatible: its one copy is a cloud copy.
      assert {profile.copies_local, profile.copies_cloud, profile.min_copies_on_write} ==
               {0, 1, 1}

      assert profile.copies_originals == 1

      assert [%{role: "primary", status: "active"}] = profile.buckets
      assert to_string(hd(profile.buckets).bucket_uuid) == to_string(bucket.uuid)
    end

    test "is not in the site's list of profiles, but can be fetched", %{user: user} do
      bucket = owned_bucket!(user.uuid)
      {:ok, profile} = Profiles.create_user_profile(user.uuid, bucket, :only)

      refute profile.uuid in Enum.map(Profiles.list_profiles(), & &1.uuid)
      assert %StorageProfile{} = Profiles.get_profile(profile.uuid)
    end

    test "refuses a bucket that is not the user's", %{user: user, other: other} do
      assert {:error, :foreign_bucket} =
               Profiles.create_user_profile(user.uuid, owned_bucket!(other.uuid), :only)

      assert {:error, :foreign_bucket} =
               Profiles.create_user_profile(user.uuid, site_bucket!(), :only)
    end
  end

  describe "create_user_profile/3, backup mode" do
    test "snapshots the Default's buckets and adds the user's as a backup of the originals", %{
      user: user
    } do
      site = site_bucket!()
      bucket = owned_bucket!(user.uuid)
      default = Profiles.default_profile()

      assert {:ok, profile} = Profiles.create_user_profile(user.uuid, bucket, :backup)

      by_bucket = rows(profile)
      assert %{role: "backup"} = by_bucket[to_string(bucket.uuid)]
      assert %{role: "primary"} = by_bucket[to_string(site.uuid)]

      # Every site bucket the Default had, and only those, plus the backup.
      default_uuids = Enum.map(default.buckets, &to_string(&1.bucket_uuid))
      assert Enum.sort(Map.keys(by_bucket)) == Enum.sort([to_string(bucket.uuid) | default_uuids])

      # A copy on every site bucket (local ones on local) plus the backup in the
      # cloud: placement writes all primaries before any backup, so anything
      # less and the backup would never get a copy.
      site_rows = Enum.count(profile.buckets, &(&1.role != "backup"))
      assert profile.copies_local == site_rows
      assert profile.copies_cloud == 1
      assert profile.copies_originals == site_rows + 1
      assert profile.min_copies_on_write <= default.min_copies_on_write
    end

    test "a site bucket added to the Default later is not in the snapshot", %{user: user} do
      bucket = owned_bucket!(user.uuid)
      _before = site_bucket!()
      {:ok, profile} = Profiles.create_user_profile(user.uuid, bucket, :backup)

      later = site_bucket!()

      refute Map.has_key?(rows(Profiles.get_profile(profile.uuid)), to_string(later.uuid))
    end

    test "needs site storage to back up", %{user: user} do
      bucket = owned_bucket!(user.uuid)
      Repo.delete_all(PhoenixKit.Modules.Storage.ProfileBucket)

      assert {:error, :no_site_storage} = Profiles.create_user_profile(user.uuid, bucket, :backup)
    end
  end

  describe "a user's bucket and profile stay with their owner" do
    test "a user's bucket cannot be put in a site profile or another user's", %{
      user: user,
      other: other
    } do
      bucket = owned_bucket!(user.uuid)
      default = Profiles.default_profile()
      {:ok, others} = Profiles.create_user_profile(other.uuid, owned_bucket!(other.uuid), :only)

      assert {:error, :foreign_bucket} = Profiles.put_bucket(default, bucket.uuid, %{})
      assert {:error, :foreign_bucket} = Profiles.put_bucket(others, bucket.uuid, %{})
    end

    test "a site bucket may be in a user's profile", %{user: user} do
      {:ok, profile} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)
      site = site_bucket!()

      assert {:ok, _} = Profiles.put_bucket(profile, site.uuid, %{role: "replica"})
    end
  end

  describe "a library's storage is chosen once" do
    test "a new user library is pointed at its owner's profile", %{user: user} do
      library = library!(user)
      {:ok, profile} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)

      assert {:ok, %Library{storage_profile_uuid: uuid}} =
               Profiles.assign_user_profile(library, profile)

      assert to_string(uuid) == to_string(profile.uuid)
    end

    test "a profile that is not the library owner's cannot be assigned", %{
      user: user,
      other: other
    } do
      library = library!(user)
      {:ok, profile} = Profiles.create_user_profile(other.uuid, owned_bucket!(other.uuid), :only)

      assert_raise FunctionClauseError, fn -> Profiles.assign_user_profile(library, profile) end
    end

    test "set_library_profile/2 refuses to move a library off or onto user storage", %{
      user: user,
      other: other
    } do
      {:ok, mine} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)
      {:ok, theirs} = Profiles.create_user_profile(other.uuid, owned_bucket!(other.uuid), :only)

      on_own = library!(user)
      {:ok, on_own} = Profiles.assign_user_profile(on_own, mine)
      on_site = library!(user)

      # Off the user's own storage, to the Default or another profile…
      assert {:error, :user_storage_locked} = Profiles.set_library_profile(on_own, nil)

      assert {:error, :user_storage_locked} =
               Profiles.set_library_profile(on_own, Profiles.default_uuid())

      # …and onto anyone's, from site storage.
      assert {:error, :user_storage_locked} = Profiles.set_library_profile(on_site, mine.uuid)
      assert {:error, :user_storage_locked} = Profiles.set_library_profile(on_site, theirs.uuid)
    end

    test "a site library can still move between the site's profiles" do
      {:ok, site_profile} =
        Profiles.create_profile(%{name: "site-#{System.unique_integer([:positive])}"})

      library =
        Repo.insert!(%Library{
          name: "System #{System.unique_integer([:positive])}",
          kind: "system",
          key_prefix: "s#{System.unique_integer([:positive])}",
          slug: "s#{System.unique_integer([:positive])}"
        })

      assert {:ok, _} = Profiles.set_library_profile(library, site_profile.uuid)
    end
  end

  describe "delete_user_profile/1" do
    test "removes the profile and the buckets only it used, and nobody else's", %{
      user: user,
      other: other
    } do
      mine = owned_bucket!(user.uuid)
      theirs = owned_bucket!(other.uuid)
      {:ok, profile} = Profiles.create_user_profile(user.uuid, mine, :only)
      {:ok, others} = Profiles.create_user_profile(other.uuid, theirs, :only)

      assert :ok = Profiles.delete_user_profile(profile.uuid)

      assert Profiles.get_profile(profile.uuid) == nil
      assert Storage.get_bucket(mine.uuid) == nil

      assert %StorageProfile{} = Profiles.get_profile(others.uuid)
      assert Storage.get_bucket(theirs.uuid)
    end

    test "keeps a bucket another of the user's profiles still uses", %{user: user} do
      bucket = owned_bucket!(user.uuid)
      {:ok, first} = Profiles.create_user_profile(user.uuid, bucket, :only)
      {:ok, second} = Profiles.create_user_profile(user.uuid, bucket, :only)

      assert :ok = Profiles.delete_user_profile(first.uuid)

      assert Storage.get_bucket(bucket.uuid)
      assert %StorageProfile{} = Profiles.get_profile(second.uuid)
    end

    test "leaves a profile a library still uses, and says so", %{user: user} do
      {:ok, profile} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)
      {:ok, _} = Profiles.assign_user_profile(library!(user), profile)

      assert {:error, :in_use} = Profiles.delete_user_profile(profile.uuid)
      assert %StorageProfile{} = Profiles.get_profile(profile.uuid)
    end

    test "never touches a site profile" do
      assert :ok = Profiles.delete_user_profile(Profiles.default_uuid())
      assert %StorageProfile{} = Profiles.default_profile()
    end
  end

  describe "purging a user's library" do
    test "takes the user's profile and bucket with it", %{user: user} do
      bucket = owned_bucket!(user.uuid)
      {:ok, profile} = Profiles.create_user_profile(user.uuid, bucket, :only)
      library = library!(user)
      {:ok, library} = Profiles.assign_user_profile(library, profile)

      {:ok, library} =
        library
        |> Ecto.Changeset.change(trashed_at: DateTime.truncate(DateTime.utc_now(), :second))
        |> Repo.update()

      assert :ok = Libraries.purge_library(library)

      assert Repo.get(Library, library.uuid) == nil
      assert Profiles.get_profile(profile.uuid) == nil
      assert Storage.get_bucket(bucket.uuid) == nil
    end
  end
end
