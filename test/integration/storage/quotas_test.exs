defmodule PhoenixKit.Modules.Storage.QuotasTest do
  @moduledoc """
  Storage quotas, against the database and a real local bucket: what an
  account's libraries count (originals, sizes and tiles, once each, trash
  included, the owner paying for contributions, their own storage excluded),
  the limit (the site setting or the host's answer), and the upload check in
  `Storage.store_file_in_buckets/7` (a new file past the limit is refused, a
  duplicate never is).
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Library, Quotas, StorageProfile}
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    {:ok, _} = Settings.update_setting("storage_user_library_limit", "5")
    {:ok, _} = Settings.update_setting(Quotas.setting_key(), "0")

    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Quota #{n}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage")
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage.create_library")

    :persistent_term.erase(@buckets_cache)
    root = Path.join(System.tmp_dir!(), "pk_quotas_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "quotas-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    previous = Application.get_env(:phoenix_kit, :storage_quota)

    on_exit(fn ->
      restore_env(previous)
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    owner = user!(role)
    {:ok, library} = Libraries.create_user_library(scope(owner), %{"name" => "Quota #{n}"})

    %{role: role, owner: owner, library: library}
  end

  defp restore_env(nil), do: Application.delete_env(:phoenix_kit, :storage_quota)
  defp restore_env(value), do: Application.put_env(:phoenix_kit, :storage_quota, value)

  defp limit_bytes!(bytes),
    do: Application.put_env(:phoenix_kit, :storage_quota, fn _ -> bytes end)

  defp user!(role) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "quotas-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp store(user, library, content) do
    source = Path.join(System.tmp_dir!(), "pk_quotas_src_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    on_exit(fn -> File.rm(source) end)
    checksum = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    {result, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Storage.store_file_in_buckets(source, "document", user.uuid, checksum, "txt", "a.txt",
          library_uuid: library.uuid
        )
      end)

    result
  end

  defp bytes(n), do: String.duplicate("x", n)

  describe "usage/1" do
    test "counts originals and the sizes and tiles made from them, once each", ctx do
      {:ok, file} = store(ctx.owner, ctx.library, bytes(60))
      assert %{originals: 60, renditions: 0, total: 60} = Quotas.usage(ctx.owner.uuid)

      {:ok, _} =
        Storage.create_file_instance(%{
          file_uuid: file.uuid,
          variant_name: "thumbnail",
          file_name: "#{file.file_path}/thumb.jpg",
          mime_type: "image/jpeg",
          ext: "jpg",
          checksum: "abcd",
          size: 25,
          processing_status: "completed"
        })

      tile = Path.join(System.tmp_dir!(), "pk_quotas_tile_#{System.unique_integer([:positive])}")
      File.write!(tile, bytes(15))
      on_exit(fn -> File.rm(tile) end)

      {:ok, _} =
        Storage.store_system_file(tile, "#{file.file_path}/_tiles/0_0_0.jpg",
          parent_file_uuid: file.uuid,
          mime_type: "image/jpeg"
        )

      assert %{originals: 60, renditions: 40, total: 100} = Quotas.usage(ctx.owner.uuid)
    end

    test "a trashed file counts until it is purged", ctx do
      {:ok, file} = store(ctx.owner, ctx.library, bytes(30))
      {:ok, _} = Storage.update_file(file, %{status: "trashed"})

      assert Quotas.usage(ctx.owner.uuid).total == 30
    end

    test "a contributor's upload counts for the library's owner", ctx do
      contributor = user!(ctx.role)

      {:ok, _} =
        Libraries.add_member(scope(ctx.owner), ctx.library, contributor.email, "contributor")

      {:ok, _} = store(contributor, ctx.library, bytes(42))

      assert Quotas.usage(ctx.owner.uuid).total == 42
      assert Quotas.usage(contributor.uuid).total == 0
    end

    test "a library on the owner's own storage does not count", ctx do
      {:ok, _} = store(ctx.owner, ctx.library, bytes(50))
      own_storage!(ctx.owner, ctx.library)

      assert Quotas.usage(ctx.owner.uuid).total == 0
      limit_bytes!(10)
      assert Quotas.check_upload(ctx.library.uuid, 1_000) == :ok
    end
  end

  # Points the library at a profile the owner owns, as their own storage
  # (V206) would, without a real S3 bucket behind it.
  defp own_storage!(owner, library) do
    profile =
      Repo.insert!(%StorageProfile{
        name: "user-storage-#{System.unique_integer([:positive])}",
        owner_uuid: owner.uuid
      })

    {1, _} =
      Repo.update_all(from(l in Library, where: l.uuid == ^library.uuid),
        set: [storage_profile_uuid: profile.uuid]
      )
  end

  describe "limit/1" do
    test "is the site setting in MB, 0 for none", ctx do
      assert Quotas.limit(ctx.owner.uuid) == nil

      {:ok, _} = Settings.update_setting(Quotas.setting_key(), "1024")
      assert Quotas.limit(ctx.owner.uuid) == 1024 * 1024 * 1024
      assert Quotas.site_limit_mb() == 1024
    end

    test "the host's answer wins, and :default falls back to the setting", ctx do
      {:ok, _} = Settings.update_setting(Quotas.setting_key(), "1")
      owner = ctx.owner.uuid

      Application.put_env(:phoenix_kit, :storage_quota, fn
        ^owner -> 5_000
        _ -> :default
      end)

      assert Quotas.limit(owner) == 5_000
      assert Quotas.limit(Ecto.UUID.generate()) == 1024 * 1024

      Application.put_env(:phoenix_kit, :storage_quota, fn _ -> nil end)
      assert Quotas.limit(owner) == nil
    end
  end

  describe "the upload check" do
    test "a new file past the owner's limit is refused, and nothing is stored", ctx do
      limit_bytes!(100)

      assert {:ok, _} = store(ctx.owner, ctx.library, bytes(60))
      assert {:error, :quota_exceeded} = store(ctx.owner, ctx.library, "y" <> bytes(59))

      assert Quotas.usage(ctx.owner.uuid).total == 60
      assert %{over?: false, limit: 100} = Quotas.status(ctx.owner.uuid)
    end

    test "a duplicate the uploader already has is never refused", ctx do
      limit_bytes!(100)
      {:ok, file} = store(ctx.owner, ctx.library, bytes(80))

      limit_bytes!(10)
      assert {:ok, same, :duplicate} = store(ctx.owner, ctx.library, bytes(80))
      assert same.uuid == file.uuid
      assert Quotas.status(ctx.owner.uuid).over?
    end

    test "a contributor is refused when the owner is out of room", ctx do
      contributor = user!(ctx.role)

      {:ok, _} =
        Libraries.add_member(scope(ctx.owner), ctx.library, contributor.email, "contributor")

      limit_bytes!(50)
      {:ok, _} = store(ctx.owner, ctx.library, bytes(40))

      assert {:error, :quota_exceeded} = store(contributor, ctx.library, bytes(20))
    end

    test "an upload outside a user library is not limited" do
      limit_bytes!(0)
      assert Quotas.check_upload(nil, 1_000) == :ok

      {:ok, system} = Libraries.create_system_library(%{name: "Quota system"})
      assert Quotas.check_upload(system.uuid, 1_000) == :ok
    end
  end
end
