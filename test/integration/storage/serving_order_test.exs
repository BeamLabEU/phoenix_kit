defmodule PhoenixKit.Modules.Storage.ServingOrderTest do
  @moduledoc """
  Serving by role and serve order (V205, step 3), against real local
  buckets: the copy served is the first primary in the profile's serve
  order, a replica only when no primary has it, a copy on a bucket the
  profile no longer lists after those, and a backup never, though reading
  the bytes to process them may still use it.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Bucket, Libraries, Locations, Manager, Profiles}
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  @cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@cache)
    n = System.unique_integer([:positive])
    roots = for side <- ~w(a b), do: Path.join(System.tmp_dir!(), "pk_serving_#{n}_#{side}")

    [a, b] =
      for root <- roots do
        {:ok, bucket} =
          Storage.create_bucket(%{
            name: "serving-#{Path.basename(root)}",
            provider: "local",
            endpoint: root,
            enabled: true,
            priority: 0
          })

        bucket
      end

    on_exit(fn ->
      :persistent_term.erase(@cache)
      Enum.each(roots, &File.rm_rf/1)
    end)

    {:ok, library} = Libraries.create_system_library(%{name: "Serving #{n}"})
    {:ok, profile} = Profiles.create_profile(%{name: "Serving #{n}", copies_originals: 2})
    {:ok, _} = Profiles.put_bucket(profile, a.uuid, %{serve_order: 1})
    {:ok, _} = Profiles.put_bucket(profile, b.uuid, %{serve_order: 2})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "serving-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    path = Path.join(System.tmp_dir!(), "pk_serving_src_#{n}")
    File.write!(path, "served bytes #{n}")
    on_exit(fn -> File.rm(path) end)
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "document", user.uuid, sha, "txt", "a.txt",
        library_uuid: library.uuid
      )

    key = Storage.get_file_instance_by_name(file.uuid, "original").file_name
    assert length(Locations.bucket_uuids(key)) == 2

    %{a: a, b: b, profile: Profiles.get_profile(profile.uuid), key: key}
  end

  defp served_from(key) do
    case Manager.get_file_access(key) do
      {:local, path} -> path
      other -> other
    end
  end

  defp from?(path, bucket), do: is_binary(path) and String.starts_with?(path, bucket.endpoint)

  # The emergency stop, set on the table: `Storage.update_bucket/3` refuses to
  # disable a bucket a storage profile lists, and these tests keep it listed.
  defp disable!(bucket) do
    {1, _} =
      Repo.update_all(from(b in Bucket, where: b.uuid == ^bucket.uuid), set: [enabled: false])

    Manager.invalidate_bucket_cache()
  end

  test "the first primary in serve order is served", ctx do
    assert from?(served_from(ctx.key), ctx.a)

    {:ok, _} = Profiles.put_bucket(ctx.profile, ctx.a.uuid, %{serve_order: 3})
    assert from?(served_from(ctx.key), ctx.b)
  end

  test "a replica is served only when no primary has the copy", ctx do
    {:ok, _} = Profiles.put_bucket(ctx.profile, ctx.a.uuid, %{role: "replica"})
    assert from?(served_from(ctx.key), ctx.b)

    File.rm!(Path.join(ctx.b.endpoint, ctx.key))
    assert from?(served_from(ctx.key), ctx.a)
  end

  test "a backup is never served, but may be read", ctx do
    {:ok, _} = Profiles.put_bucket(ctx.profile, ctx.a.uuid, %{role: "backup"})
    assert from?(served_from(ctx.key), ctx.b)

    File.rm!(Path.join(ctx.b.endpoint, ctx.key))
    assert served_from(ctx.key) == {:error, :not_found}
    assert Manager.public_url(ctx.key) == nil

    assert Manager.file_exists?(ctx.key)
    assert {:ok, temp} = Manager.retrieve_file(ctx.key)
    File.rm(temp)
  end

  test "a copy on a bucket the profile no longer lists comes after its buckets", ctx do
    :ok = Profiles.remove_bucket(ctx.profile, ctx.a.uuid)

    assert [%{role: "primary"}, %{role: nil}] = Locations.ranked(ctx.key)
    assert from?(served_from(ctx.key), ctx.b)

    File.rm!(Path.join(ctx.b.endpoint, ctx.key))
    assert from?(served_from(ctx.key), ctx.a)
  end

  test "a disabled bucket is not served from", ctx do
    # The emergency stop applies whatever the profile says: set on the table,
    # because `update_bucket/3` refuses to disable a bucket a profile lists.
    disable!(ctx.a)
    assert from?(served_from(ctx.key), ctx.b)
  end
end
