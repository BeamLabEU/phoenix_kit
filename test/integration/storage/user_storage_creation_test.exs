defmodule PhoenixKit.Modules.Storage.UserStorageCreationTest do
  @moduledoc """
  Creating a user library on the user's own storage (V206): who may, both
  modes end to end (bucket, profile, library in one transaction), the probe
  that runs before anything is written, every failure leaving nothing behind,
  and the choice being final.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Library, Profiles}
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope

  setup do
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-own-storage")

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", true)
    {:ok, _} = Settings.update_setting("storage_user_library_limit", "5")

    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Own storage #{n}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage")
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage.create_library")
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage.own_storage")
    {:ok, _} = Permissions.grant_permission(role.uuid, "integrations")

    {:ok, plain_role} = Roles.create_role(%{name: "Plain #{n}"})
    {:ok, _} = Permissions.grant_permission(plain_role.uuid, "storage")
    {:ok, _} = Permissions.grant_permission(plain_role.uuid, "storage.create_library")

    {:ok, site} =
      Storage.create_bucket(%{
        name: "site-#{n}",
        provider: "local",
        endpoint: Path.join(System.tmp_dir!(), "pk_own_storage"),
        enabled: true
      })

    %{role: role, plain_role: plain_role, site: site}
  end

  defp user!(role) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "own-storage-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp connection!(user, name \\ "mine") do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("object_storage", name, nil, owner: {:user, user.uuid})

    {:ok, _} =
      Integrations.save_setup(uuid, %{"access_key" => "AKIA", "secret_key" => "s"}, nil,
        owner: {:user, user.uuid}
      )

    uuid
  end

  defp storage(user, extra \\ %{}) do
    Map.merge(
      %{
        "mode" => "only",
        "integration_uuid" => connection!(user),
        "provider" => "s3",
        "bucket_name" => "my-photos",
        "region" => "eu-central-1"
      },
      extra
    )
  end

  # A probe that says the bucket works, and remembers what it was asked.
  defp probe_ok do
    test = self()

    fn params ->
      send(test, {:probed, params})
      :ok
    end
  end

  defp create(user, storage, opts \\ [probe: probe_ok()]) do
    Libraries.create_user_library(scope(user), %{"name" => "Photos", "storage" => storage}, opts)
  end

  describe "who may" do
    test "needs the storage.own_storage permission", %{plain_role: role} do
      user = user!(role)

      refute Libraries.may_use_own_storage?(scope(user))
      assert {:error, :not_allowed} = create(user, storage(user))
      assert Storage.list_owned_buckets(user.uuid) == []
    end

    test "needs the Integrations permission: the keys are a personal connection", %{role: role} do
      {:ok, no_integrations} =
        Roles.create_role(%{name: "No integrations #{System.unique_integer([:positive])}"})

      for key <- ["storage", "storage.create_library", "storage.own_storage"],
          do: {:ok, _} = Permissions.grant_permission(no_integrations.uuid, key)

      user = user!(no_integrations)
      refute Libraries.may_use_own_storage?(scope(user))

      assert Libraries.may_use_own_storage?(scope(user!(role)))
    end

    test "needs the site to allow it", %{role: role} do
      user = user!(role)
      assert Libraries.may_use_own_storage?(scope(user))

      {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", false)

      refute Libraries.may_use_own_storage?(scope(user))
      assert {:error, :not_allowed} = create(user, storage(user))
    end

    test "a library on the site's storage needs neither", %{plain_role: role} do
      user = user!(role)

      assert {:ok, %Library{storage_profile_uuid: nil}} =
               Libraries.create_user_library(scope(user), %{"name" => "Plain"})

      assert {:ok, %Library{storage_profile_uuid: nil}} =
               Libraries.create_user_library(scope(user), %{
                 "name" => "Plain too",
                 "storage" => %{"mode" => "site"}
               })
    end

    test "an unknown mode is refused", %{role: role} do
      user = user!(role)

      assert {:error, :not_allowed} = create(user, storage(user, %{"mode" => "both"}))
    end
  end

  describe "only mode" do
    test "creates the bucket, the profile and the library together", %{role: role} do
      user = user!(role)

      assert {:ok, %Library{} = library} = create(user, storage(user))

      assert is_binary(library.storage_profile_uuid)
      profile = Profiles.get_profile(library.storage_profile_uuid)
      assert profile.owner_uuid == user.uuid
      assert [%{role: "primary"}] = profile.buckets

      assert [%{owner_uuid: owner, name: "Photos", bucket_name: "my-photos"}] =
               Storage.list_owned_buckets(user.uuid)

      assert owner == user.uuid
    end

    test "probes the bucket first, as the user", %{role: role} do
      user = user!(role)
      {:ok, _} = create(user, storage(user))

      assert_received {:probed, params}
      assert params["owner_uuid"] == user.uuid
      assert params["bucket_name"] == "my-photos"
      assert is_binary(params["integration_uuid"])
    end
  end

  describe "backup mode" do
    test "keeps the site's buckets and adds the user's as a backup", %{role: role, site: site} do
      user = user!(role)

      assert {:ok, library} = create(user, storage(user, %{"mode" => "backup"}))

      profile = Profiles.get_profile(library.storage_profile_uuid)
      roles = Map.new(profile.buckets, &{to_string(&1.bucket_uuid), &1.role})

      assert roles[to_string(site.uuid)] == "primary"
      assert "backup" in Map.values(roles)
    end

    test "refuses a backup of the site's AWS bucket, including a blank endpoint and an amazonaws host",
         %{role: role} do
      user = user!(role)

      site_aws!(%{
        bucket_name: "shared-photos",
        endpoint: "https://s3.eu-west-1.amazonaws.com"
      })

      assert {:error, {:storage, message}} =
               create(
                 user,
                 storage(user, %{"mode" => "backup", "bucket_name" => "shared-photos"})
               )

      assert message =~ "same bucket"
      assert Storage.list_owned_buckets(user.uuid) == []
      assert Libraries.list_user_libraries(user.uuid) == []
    end

    test "a different AWS bucket is not the site bucket", %{role: role} do
      user = user!(role)

      site_aws!(%{bucket_name: "site-photos", endpoint: "https://s3.amazonaws.com"})

      assert {:ok, _library} =
               create(
                 user,
                 storage(user, %{"mode" => "backup", "bucket_name" => "my-photos"})
               )
    end
  end

  describe "a failure leaves nothing behind" do
    test "a probe that fails creates nothing, and says why", %{role: role} do
      user = user!(role)
      failing = fn _params -> {:error, "The bucket can be read but not written to"} end

      assert {:error, {:storage, "The bucket can be read but not written to"}} =
               create(user, storage(user), probe: failing)

      assert Storage.list_owned_buckets(user.uuid) == []
      assert Libraries.list_user_libraries(user.uuid) == []
    end

    test "bucket fields that do not pass are reported as a changeset, and not probed", %{
      role: role
    } do
      user = user!(role)

      assert {:error, {:storage, %Ecto.Changeset{} = changeset}} =
               create(user, storage(user, %{"endpoint" => "https://10.0.0.5"}))

      assert %{endpoint: [_]} =
               Ecto.Changeset.traverse_errors(changeset, fn {message, _} -> message end)

      refute_received {:probed, _}
      assert Storage.list_owned_buckets(user.uuid) == []
      assert Libraries.list_user_libraries(user.uuid) == []
    end

    test "someone else's connection is refused", %{role: role} do
      user = user!(role)
      other = user!(role)

      assert {:error, {:storage, %Ecto.Changeset{}}} =
               create(user, storage(user, %{"integration_uuid" => connection!(other)}))

      assert Storage.list_owned_buckets(user.uuid) == []
    end

    test "backup mode with no site storage to back up creates nothing", %{role: role} do
      user = user!(role)
      Repo.delete_all(PhoenixKit.Modules.Storage.ProfileBucket)

      assert {:error, :no_site_storage} = create(user, storage(user, %{"mode" => "backup"}))

      assert Storage.list_owned_buckets(user.uuid) == []
      assert Libraries.list_user_libraries(user.uuid) == []
    end

    test "the library limit is still enforced, and leaves no bucket behind", %{role: role} do
      user = user!(role)
      {:ok, _} = Settings.update_setting("storage_user_library_limit", "1")
      {:ok, _} = Libraries.create_user_library(scope(user), %{"name" => "First"})

      assert {:error, :limit_reached} = create(user, storage(user))
      assert Storage.list_owned_buckets(user.uuid) == []
    end
  end

  describe "buckets from the integration" do
    test "the provider, region and endpoint are the integration's, not asked again", %{role: role} do
      user = user!(role)

      {:ok, %{uuid: uuid}} =
        Integrations.add_connection("object_storage", "tigris", nil, owner: {:user, user.uuid})

      {:ok, _} =
        Integrations.save_setup(
          uuid,
          %{"access_key" => "AKIA", "secret_key" => "s", "endpoint" => "t3.storage.dev"},
          nil,
          owner: {:user, user.uuid}
        )

      assert {:ok, library} =
               create(user, %{
                 "mode" => "only",
                 "targets" => [%{"integration_uuid" => uuid, "bucket_name" => "my-photos"}]
               })

      assert %{bucket: bucket} = Profiles.user_storage_for([library])[to_string(library.uuid)]

      assert {bucket.provider, bucket.endpoint, bucket.integration_uuid} ==
               {"tigris", "t3.storage.dev", uuid}

      assert_received {:probed, %{"provider" => "tigris", "endpoint" => "t3.storage.dev"}}
    end

    test "more integrations than the maximum are refused before anything is made", %{role: role} do
      user = user!(role)

      targets =
        for n <- 1..(Profiles.max_user_buckets() + 1) do
          %{"integration_uuid" => connection!(user, "int#{n}"), "bucket_name" => "bucket-#{n}"}
        end

      assert {:error, {:storage, message}} =
               create(user, %{"mode" => "only", "targets" => targets})

      assert message =~ "at most"
      assert Storage.list_owned_buckets(user.uuid) == []
    end

    test "the same bucket twice is refused", %{role: role} do
      user = user!(role)
      uuid = connection!(user)
      target = %{"integration_uuid" => uuid, "bucket_name" => "same"}

      assert {:error, {:storage, message}} =
               create(user, %{"mode" => "only", "targets" => [target, target]})

      assert message =~ "same bucket"
    end

    test "list_own_buckets asks the integration, described without its keys", %{role: role} do
      user = user!(role)
      uuid = connection!(user)
      test = self()

      list = fn bucket ->
        send(test, {:listed, bucket})
        {:ok, ["b-two", "a-one"]}
      end

      assert {:ok, ["b-two", "a-one"]} = Libraries.list_own_buckets(scope(user), uuid, list: list)

      assert_received {:listed, bucket}
      assert bucket.integration_uuid == uuid
      assert bucket.owner_uuid == user.uuid
      assert bucket.provider == "s3"
      assert is_nil(bucket.access_key_id) and is_nil(bucket.secret_access_key)
    end

    test "list_own_buckets is for a user who may use their own storage, and their own integration",
         %{role: role, plain_role: plain_role} do
      user = user!(role)
      other = user!(role)
      theirs = connection!(other)
      list = fn _bucket -> flunk("must not be asked") end

      assert {:error, :not_allowed} =
               Libraries.list_own_buckets(scope(user!(plain_role)), connection!(user), list: list)

      assert {:error, message} = Libraries.list_own_buckets(scope(user), theirs, list: list)
      assert message =~ "not yours"
    end

    test "integration_summary names the service and never a secret", %{role: role} do
      user = user!(role)
      uuid = connection!(user)

      summary = Libraries.integration_summary(user.uuid, uuid)

      assert %{provider: "s3", service: "aws_s3"} = summary
      refute inspect(summary) =~ "AKIA"
      assert is_nil(Libraries.integration_summary(user!(role).uuid, uuid))
    end
  end

  test "the choice is final: the library cannot be moved off its own storage", %{role: role} do
    user = user!(role)
    {:ok, library} = create(user, storage(user))

    assert {:error, :user_storage_locked} = Profiles.set_library_profile(library, nil)
  end

  describe "adding backup storage to an existing library" do
    test "appends a backup and increases copies while preserving primary and write requirements",
         %{role: role} do
      user = user!(role)
      {:ok, library} = create(user, storage(user))
      before = Profiles.for_library(library)
      target = storage(user, %{"bucket_name" => "second-photos"})

      assert {:ok, _} =
               Libraries.add_user_storage(scope(user), library, target, probe: probe_ok())

      after_profile = Profiles.for_library(library)
      assert after_profile.uuid == before.uuid
      assert after_profile.copies_cloud == before.copies_cloud + 1
      assert after_profile.min_copies_on_write == before.min_copies_on_write
      assert after_profile.revision > before.revision

      assert Enum.find(after_profile.buckets, &(&1.role == "primary")).bucket_uuid ==
               hd(before.buckets).bucket_uuid

      assert [%{role: "backup", bucket: %{bucket_name: "second-photos"}}] =
               Enum.filter(after_profile.buckets, &(&1.role == "backup"))
    end

    test "two integrations pointing at the same bucket cannot count as two copies", %{role: role} do
      user = user!(role)
      {:ok, library} = create(user, storage(user))

      assert {:error, :duplicate_bucket} =
               Libraries.add_user_storage(scope(user), library, storage(user), probe: probe_ok())

      assert length(Storage.list_owned_buckets(user.uuid)) == 1
    end

    test "a failed probe changes neither the profile nor its buckets", %{role: role} do
      user = user!(role)
      {:ok, library} = create(user, storage(user))
      before = Profiles.for_library(library)
      targets = Storage.list_owned_buckets(user.uuid)

      assert {:error, "denied"} =
               Libraries.add_user_storage(
                 scope(user),
                 library,
                 storage(user, %{"bucket_name" => "second-photos"}),
                 probe: fn _ -> {:error, "denied"} end
               )

      assert Profiles.for_library(library) == before
      assert Storage.list_owned_buckets(user.uuid) == targets
    end

    test "rejects duplicate buckets and the per-library cap without leaving rows behind", %{
      role: role
    } do
      user = user!(role)
      first = storage(user)
      {:ok, library} = create(user, first)

      assert {:error, :duplicate_bucket} =
               Libraries.add_user_storage(scope(user), library, first, probe: probe_ok())

      second = storage(user, %{"bucket_name" => "second-photos"})
      third = storage(user, %{"bucket_name" => "third-photos"})

      assert {:ok, _} =
               Libraries.add_user_storage(scope(user), library, %{"targets" => [second, third]},
                 probe: probe_ok()
               )

      assert {:error, :too_many_buckets} =
               Libraries.add_user_storage(scope(user), library, storage(user), probe: probe_ok())

      assert length(Storage.list_owned_buckets(user.uuid)) == 3
    end

    test "rejects another owner, a trashed library and revoked permission", %{role: role} do
      user = user!(role)
      {:ok, library} = create(user, storage(user))
      target = storage(user)
      other = user!(role)

      assert {:error, :not_allowed} =
               Libraries.add_user_storage(scope(other), library, target, probe: probe_ok())

      stale_scope = scope(user)
      :ok = Permissions.revoke_permission(role.uuid, "storage.own_storage")

      assert {:error, :not_allowed} =
               Libraries.add_user_storage(stale_scope, library, target, probe: probe_ok())

      {:ok, _} = Permissions.grant_permission(role.uuid, "storage.own_storage")

      {:ok, _} =
        library
        |> Ecto.Changeset.change(trashed_at: DateTime.truncate(DateTime.utc_now(), :second))
        |> Repo.update()

      assert {:error, :not_allowed} =
               Libraries.add_user_storage(scope(user), library, target, probe: probe_ok())
    end

    test "refuses an integration changed after the probe instead of attaching untested credentials",
         %{role: role} do
      user = user!(role)
      {:ok, library} = create(user, storage(user))
      target = storage(user, %{"bucket_name" => "second-photos"})

      probe = fn _ ->
        {:ok, _} =
          Integrations.save_setup(target["integration_uuid"], %{"access_key" => "changed"}, nil,
            owner: {:user, user.uuid}
          )

        :ok
      end

      assert {:error, :storage_changed} =
               Libraries.add_user_storage(scope(user), library, target, probe: probe)

      assert length(Storage.list_owned_buckets(user.uuid)) == 1
    end

    test "refuses a foreign integration and preserves site primaries in backup mode", %{
      role: role,
      site: site
    } do
      user = user!(role)
      {:ok, library} = create(user, storage(user, %{"mode" => "backup"}))

      assert {:error, %Ecto.Changeset{}} =
               Libraries.add_user_storage(
                 scope(user),
                 library,
                 storage(user!(role), %{"bucket_name" => "foreign-photos"}),
                 probe: probe_ok()
               )

      assert {:ok, _} =
               Libraries.add_user_storage(
                 scope(user),
                 library,
                 storage(user, %{"bucket_name" => "second-photos"}),
                 probe: probe_ok()
               )

      profile = Profiles.for_library(library)
      assert Enum.any?(profile.buckets, &(&1.bucket_uuid == site.uuid and &1.role == "primary"))
      assert Enum.count(profile.buckets, &(&1.role == "backup")) == 2
    end

    test "a blank AWS endpoint and an amazonaws host are one bucket", %{role: role} do
      user = user!(role)
      {:ok, library} = create(user, storage(user, %{"bucket_name" => "my-photos"}))
      [bucket] = Storage.list_owned_buckets(user.uuid)

      {:ok, _} =
        bucket
        |> Ecto.Changeset.change(endpoint: "https://s3.eu-west-1.amazonaws.com")
        |> Repo.update()

      assert {:error, :duplicate_bucket} =
               Libraries.add_user_storage(
                 scope(user),
                 library,
                 storage(user, %{"bucket_name" => "my-photos"}),
                 probe: probe_ok()
               )

      assert length(Storage.list_owned_buckets(user.uuid)) == 1
    end

    test "adding a backup cannot repeat the site bucket kept on the profile", %{role: role} do
      user = user!(role)

      site_aws = site_aws!(%{bucket_name: "shared-photos"})

      {:ok, library} =
        create(user, storage(user, %{"mode" => "backup", "bucket_name" => "my-photos"}))

      assert {:error, :duplicate_bucket} =
               Libraries.add_user_storage(
                 scope(user),
                 library,
                 storage(user, %{
                   "bucket_name" => "shared-photos",
                   "endpoint" => "https://s3.eu-west-1.amazonaws.com"
                 }),
                 probe: probe_ok()
               )

      profile = Profiles.for_library(library)
      assert Enum.any?(profile.buckets, &(&1.bucket_uuid == site_aws.uuid))
      assert Enum.count(profile.buckets, &(&1.bucket.owner_uuid == user.uuid)) == 1
    end
  end

  describe "the session role, with the switcher on" do
    setup do
      {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", true)

      on_exit(fn ->
        Settings.update_boolean_setting("role_switcher_enabled", false)
      end)

      :ok
    end

    test "create and adding a backup follow the switched role, not the default" do
      blocked = storage_role(false)
      allowed = storage_role(true)
      user = user_with([blocked, allowed])
      scope = acting_as(user, allowed)
      assert Scope.active_role(scope).uuid == allowed.uuid

      assert {:ok, library} =
               Libraries.create_user_library(
                 scope,
                 %{"name" => "Photos", "storage" => storage(user)},
                 probe: probe_ok()
               )

      assert {:ok, _} =
               Libraries.add_user_storage(
                 scope,
                 library,
                 storage(user, %{"bucket_name" => "second-photos"}),
                 probe: probe_ok()
               )
    end

    test "a switched role without own storage is refused when the default role has it" do
      allowed = storage_role(true)
      blocked = storage_role(false)
      user = user_with([allowed, blocked])
      assert Scope.active_role(acting_as(user, blocked)).uuid == blocked.uuid

      assert Libraries.may_use_own_storage?(scope(user))

      assert {:error, :not_allowed} =
               Libraries.create_user_library(
                 acting_as(user, blocked),
                 %{"name" => "Photos", "storage" => storage(user)},
                 probe: probe_ok()
               )

      {:ok, library} = create(user, storage(user))

      assert {:error, :not_allowed} =
               Libraries.add_user_storage(
                 acting_as(user, blocked),
                 library,
                 storage(user, %{"bucket_name" => "second-photos"}),
                 probe: probe_ok()
               )

      assert length(Storage.list_owned_buckets(user.uuid)) == 1
    end
  end

  defp storage_role(own_storage?) do
    {:ok, role} = Roles.create_role(%{name: "Session #{System.unique_integer([:positive])}"})

    keys =
      if own_storage?,
        do: ~w(storage storage.create_library storage.own_storage integrations),
        else: ~w(storage storage.create_library integrations)

    for key <- keys, do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    role
  end

  defp user_with(roles) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "session-role-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    for role <- roles, do: {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  defp acting_as(user, role) do
    user = Repo.get!(Auth.User, user.uuid)
    Scope.for_user(%{user | active_role_uuid: role.uuid})
  end

  defp site_aws!(attrs) do
    bucket =
      Repo.insert!(
        struct!(
          Storage.Bucket,
          Map.merge(
            %{
              name: "site-aws-#{System.unique_integer([:positive])}",
              provider: "s3",
              region: "eu-west-1",
              enabled: true
            },
            attrs
          )
        )
      )

    :ok = Profiles.add_to_default(bucket)
    bucket
  end
end
