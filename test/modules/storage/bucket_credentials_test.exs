defmodule PhoenixKit.Modules.Storage.BucketCredentialsTest do
  @moduledoc """
  Moving a legacy bucket's own keys into an `object_storage` Integrations
  connection: the keys must read back identically through the connection
  before the bucket's copy is cleared, buckets on one key pair share a single
  connection, and a failure leaves everything as it was.
  """
  # async: false — stamps the global `:phoenix_kit, :secret_key_base` app env,
  # same rationale as BucketPersistenceTest.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.BucketCredentials
  alias PhoenixKit.Modules.Storage.Providers.S3

  setup do
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-bucket-credentials")

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    :ok
  end

  defp legacy_bucket(name, attrs \\ %{}) do
    {:ok, bucket} =
      Storage.create_bucket(
        Map.merge(
          %{
            name: name,
            provider: "r2",
            bucket_name: "media",
            region: "auto",
            endpoint: "https://acct.r2.cloudflarestorage.com",
            access_key_id: "AKIALEGACY",
            secret_access_key: "legacy-secret"
          },
          attrs
        )
      )

    bucket
  end

  defp object_storage_connections, do: Integrations.list_connections("object_storage")

  test "a bucket with its own keys is legacy; one on a connection, or a local one, is not" do
    assert BucketCredentials.legacy?(legacy_bucket("Legacy"))

    {:ok, %{uuid: uuid}} = Integrations.add_connection("object_storage", "Account")

    {:ok, on_connection} =
      Storage.create_bucket(%{
        name: "On connection",
        provider: "s3",
        bucket_name: "b",
        integration_uuid: uuid
      })

    {:ok, local} = Storage.create_bucket(%{name: "Disk", provider: "local", endpoint: "/tmp/x"})

    refute BucketCredentials.legacy?(on_connection)
    refute BucketCredentials.legacy?(local)
  end

  describe "move_to_integration/2" do
    test "creates a connection, points the bucket at it and clears the bucket's own keys" do
      bucket = legacy_bucket("Legacy R2")
      actor = Ecto.UUID.generate()

      assert {:ok, moved} = BucketCredentials.move_to_integration(bucket, actor_uuid: actor)

      assert is_binary(moved.integration_uuid)
      assert moved.access_key_id == nil
      assert moved.secret_access_key == nil
      refute BucketCredentials.legacy?(moved)

      # The same keys, read through the connection.
      assert S3.resolve_credentials(moved) == {"AKIALEGACY", "legacy-secret"}

      # The bucket keeps its non-secret settings.
      assert moved.endpoint == "https://acct.r2.cloudflarestorage.com"
      assert moved.region == "auto"

      assert [%{uuid: uuid, name: "Legacy R2", data: data}] = object_storage_connections()
      assert uuid == moved.integration_uuid
      assert data["access_key"] == "AKIALEGACY"
      assert data["endpoint"] == "https://acct.r2.cloudflarestorage.com"

      # And it is what was stored, not only what was returned.
      assert Storage.get_bucket(bucket.uuid).integration_uuid == uuid
      assert Storage.get_bucket(bucket.uuid).secret_access_key == nil

      entry =
        Repo.one!(
          from e in PhoenixKit.Activity.Entry,
            where: e.action == "storage.bucket.updated" and e.resource_uuid == ^bucket.uuid
        )

      assert entry.actor_uuid == actor
      assert entry.metadata["changes"]["integration_uuid"]["to"] == uuid
    end

    test "buckets on the same key pair share one connection" do
      first = legacy_bucket("First", %{bucket_name: "one"})
      second = legacy_bucket("Second", %{bucket_name: "two"})

      assert {:ok, a} = BucketCredentials.move_to_integration(first)
      assert {:ok, b} = BucketCredentials.move_to_integration(second)

      assert a.integration_uuid == b.integration_uuid
      assert [_one] = object_storage_connections()
    end

    test "different key pairs get their own connections" do
      first = legacy_bucket("First", %{bucket_name: "one"})

      second =
        legacy_bucket("Second", %{
          bucket_name: "two",
          access_key_id: "AKIAOTHER",
          secret_access_key: "other-secret"
        })

      assert {:ok, a} = BucketCredentials.move_to_integration(first)
      assert {:ok, b} = BucketCredentials.move_to_integration(second)

      refute a.integration_uuid == b.integration_uuid
      assert S3.resolve_credentials(b) == {"AKIAOTHER", "other-secret"}
      assert [_, _] = object_storage_connections()
    end

    test "refuses a bucket that is not legacy, changing nothing" do
      bucket = legacy_bucket("Legacy")
      {:ok, moved} = BucketCredentials.move_to_integration(bucket)

      assert {:error, :not_legacy} = BucketCredentials.move_to_integration(moved)
      assert [_one] = object_storage_connections()
    end

    test "does not move a secret it cannot decrypt, and leaves no connection behind" do
      bucket = legacy_bucket("Legacy")

      # A secret that no longer decrypts (a rotated secret_key_base).
      Application.put_env(:phoenix_kit, :secret_key_base, "a-different-secret-entirely")

      assert {:error, :unreadable_credentials} = BucketCredentials.move_to_integration(bucket)

      assert object_storage_connections() == []

      assert %{integration_uuid: nil, access_key_id: "AKIALEGACY"} =
               Storage.get_bucket(bucket.uuid)
    end
  end

  describe "move_all_to_integrations/1" do
    test "moves every legacy bucket and reports each" do
      a = legacy_bucket("A", %{bucket_name: "a"})
      b = legacy_bucket("B", %{bucket_name: "b"})

      {:ok, _local} =
        Storage.create_bucket(%{name: "Disk", provider: "local", endpoint: "/tmp/x"})

      results = BucketCredentials.move_all_to_integrations()

      assert [{%{uuid: u1}, {:ok, _}}, {%{uuid: u2}, {:ok, _}}] =
               Enum.sort_by(results, fn {bucket, _} -> bucket.name end)

      assert Enum.sort([u1, u2]) == Enum.sort([a.uuid, b.uuid])
      assert BucketCredentials.legacy_buckets() == []
    end
  end
end
