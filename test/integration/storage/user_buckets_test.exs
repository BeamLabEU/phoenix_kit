defmodule PhoenixKit.Modules.Storage.UserBucketsTest do
  @moduledoc """
  A user's own bucket (V206): it is never part of the site's storage (no
  listing the site's code reads returns it), it is always an S3-protocol bucket
  on a connection its owner owns, the owner cannot be chosen through params,
  and the endpoint is held to the strict policy both when the bucket is saved
  and whenever a request to it is built.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.Providers.S3

  setup do
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-user-buckets")

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    %{owner: UUIDv7.generate(), other: UUIDv7.generate()}
  end

  defp personal_connection(owner, name \\ "mine") do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("object_storage", name, nil, owner: {:user, owner})

    {:ok, _} =
      Integrations.save_setup(
        uuid,
        %{"access_key" => "AKIA#{name}", "secret_key" => "secret-#{name}"},
        nil,
        owner: {:user, owner}
      )

    uuid
  end

  defp site_connection(name \\ "site") do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("object_storage", name)

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "access_key" => "AKIA#{name}",
        "secret_key" => "secret-#{name}"
      })

    uuid
  end

  defp attrs(connection, extra \\ %{}) do
    Map.merge(
      %{
        "name" => "My photos",
        "provider" => "s3",
        "bucket_name" => "my-photos",
        "region" => "eu-central-1",
        "integration_uuid" => connection
      },
      extra
    )
  end

  defp site_bucket do
    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "Site disk #{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: Path.join(System.tmp_dir!(), "pk_user_buckets"),
        enabled: true
      })

    bucket
  end

  describe "create_owned_bucket/2" do
    test "creates a signed bucket for its owner", %{owner: owner} do
      connection = personal_connection(owner)

      assert {:ok, %Bucket{} = bucket} = Storage.create_owned_bucket(owner, attrs(connection))

      assert bucket.owner_uuid == owner
      assert bucket.access_type == "signed"
      assert bucket.access_key_id == nil
      assert bucket.secret_access_key == nil
      assert bucket.integration_uuid == connection
    end

    test "the owner cannot be chosen through params", %{owner: owner, other: other} do
      connection = personal_connection(owner)

      assert {:ok, bucket} =
               Storage.create_owned_bucket(
                 owner,
                 attrs(connection, %{"owner_uuid" => other, "access_type" => "public"})
               )

      assert bucket.owner_uuid == owner
      assert bucket.access_type == "signed"
    end

    test "keys typed into params are not stored on the bucket", %{owner: owner} do
      connection = personal_connection(owner)

      assert {:ok, bucket} =
               Storage.create_owned_bucket(
                 owner,
                 attrs(connection, %{"access_key_id" => "AKIA", "secret_access_key" => "s"})
               )

      assert bucket.access_key_id == nil
      assert bucket.secret_access_key == nil
    end

    test "is never a filesystem path", %{owner: owner} do
      connection = personal_connection(owner)

      assert {:error, changeset} =
               Storage.create_owned_bucket(owner, attrs(connection, %{"provider" => "local"}))

      assert %{provider: [_]} = errors(changeset)
    end

    test "needs a connection, and it must be the owner's own", %{owner: owner, other: other} do
      assert {:error, changeset} =
               Storage.create_owned_bucket(owner, attrs(nil))

      assert %{integration_uuid: _} = errors(changeset)

      # Another user's, and the site's: both read as "not yours".
      for connection <- [personal_connection(other, "theirs"), site_connection()] do
        assert {:error, changeset} = Storage.create_owned_bucket(owner, attrs(connection))
        assert %{integration_uuid: ["is not one of your connections"]} = errors(changeset)
      end
    end

    test "B2, R2, Hetzner and Tigris need an endpoint: there is no default host", %{owner: owner} do
      connection = personal_connection(owner)

      for provider <- ~w(b2 r2 hetzner tigris) do
        assert {:error, changeset} =
                 Storage.create_owned_bucket(owner, attrs(connection, %{"provider" => provider}))

        assert %{endpoint: _} = errors(changeset), provider
      end
    end

    test "an endpoint on a local, private or metadata address, or plain http, is refused", %{
      owner: owner
    } do
      connection = personal_connection(owner)

      for endpoint <- [
            "https://127.0.0.1",
            "https://10.0.0.5",
            "https://192.168.1.1",
            "https://169.254.169.254",
            "http://8.8.8.8"
          ] do
        assert {:error, changeset} =
                 Storage.create_owned_bucket(owner, attrs(connection, %{"endpoint" => endpoint}))

        assert %{endpoint: [_]} = errors(changeset), endpoint
      end
    end

    test "a public https endpoint is accepted", %{owner: owner} do
      connection = personal_connection(owner)

      assert {:ok, _bucket} =
               Storage.create_owned_bucket(
                 owner,
                 attrs(connection, %{"endpoint" => "https://8.8.8.8"})
               )
    end

    test "does not join the Default storage profile", %{owner: owner} do
      connection = personal_connection(owner)
      {:ok, bucket} = Storage.create_owned_bucket(owner, attrs(connection))

      default = Storage.Profiles.default_profile()
      refute Enum.any?(default.buckets, &(&1.bucket_uuid == bucket.uuid))
    end
  end

  describe "editing a user's bucket" do
    test "cannot make it public or local", %{owner: owner} do
      {:ok, bucket} = Storage.create_owned_bucket(owner, attrs(personal_connection(owner)))

      # Not castable: an edit leaves it signed.
      assert {:ok, same} = Storage.update_bucket(bucket, %{access_type: "public"})
      assert same.access_type == "signed"

      assert {:error, changeset} =
               Storage.update_bucket(bucket, %{provider: "local", endpoint: "/tmp"})

      assert %{provider: [_]} = errors(changeset)
    end
  end

  describe "the site's listings never return a user's bucket" do
    test "list_buckets/0 and list_enabled_buckets/0", %{owner: owner} do
      connection = personal_connection(owner)
      {:ok, owned} = Storage.create_owned_bucket(owner, attrs(connection))
      site = site_bucket()

      assert site.uuid in Enum.map(Storage.list_buckets(), & &1.uuid)
      refute owned.uuid in Enum.map(Storage.list_buckets(), & &1.uuid)

      assert site.uuid in Enum.map(Storage.list_enabled_buckets(), & &1.uuid)
      refute owned.uuid in Enum.map(Storage.list_enabled_buckets(), & &1.uuid)
    end

    test "list_owned_buckets/1 returns only that owner's", %{owner: owner, other: other} do
      {:ok, mine} = Storage.create_owned_bucket(owner, attrs(personal_connection(owner)))

      {:ok, _theirs} =
        Storage.create_owned_bucket(other, attrs(personal_connection(other, "theirs")))

      assert [%{uuid: uuid}] = Storage.list_owned_buckets(owner)
      assert uuid == mine.uuid
      assert Storage.list_owned_buckets(nil) == []
    end

    test "get_buckets/1 reaches a user's bucket by uuid, for the read path", %{owner: owner} do
      {:ok, owned} = Storage.create_owned_bucket(owner, attrs(personal_connection(owner)))
      site = site_bucket()

      found = Storage.get_buckets([owned.uuid, site.uuid]) |> Enum.map(& &1.uuid) |> Enum.sort()

      assert found == Enum.sort([owned.uuid, site.uuid])
      assert Storage.get_buckets([]) == []
    end
  end

  describe "the S3 provider, for a user's bucket" do
    test "reads the owner's connection", %{owner: owner} do
      connection = personal_connection(owner, "mine")
      {:ok, bucket} = Storage.create_owned_bucket(owner, attrs(connection))

      assert S3.resolve_credentials(bucket) == {"AKIAmine", "secret-mine"}
    end

    test "does not read a site connection, or another user's", %{owner: owner, other: other} do
      # Saved through the changeset a bucket could never pass, to prove the
      # read side refuses on its own.
      for connection <- [site_connection(), personal_connection(other, "theirs")] do
        bucket = %Bucket{name: "x", owner_uuid: owner, integration_uuid: connection}

        assert S3.resolve_credentials(bucket) == {nil, nil}
      end
    end

    test "a site bucket does not read a user's connection", %{owner: owner} do
      bucket = %Bucket{name: "x", owner_uuid: nil, integration_uuid: personal_connection(owner)}

      assert S3.resolve_credentials(bucket) == {nil, nil}
    end

    test "building a request to a private endpoint raises, even if one was saved", %{owner: owner} do
      connection = personal_connection(owner)

      bucket = %Bucket{
        name: "x",
        provider: "s3",
        owner_uuid: owner,
        bucket_name: "review-bucket",
        integration_uuid: connection,
        endpoint: "https://10.0.0.5"
      }

      assert_raise ArgumentError, ~r/local, private or metadata/, fn -> S3.aws_config(bucket) end
    end

    test "a site bucket may still use a private endpoint (a MinIO on the same network)" do
      bucket = %Bucket{name: "x", provider: "s3", endpoint: "http://10.0.0.5:9000"}

      assert S3.aws_config(bucket)[:host] == "10.0.0.5"
    end
  end

  describe "test_connection/1" do
    test "checks a user's endpoint under the strict policy, before any request" do
      assert {:error, message} =
               Storage.test_connection(%{
                 "provider" => "s3",
                 "bucket_name" => "b",
                 "endpoint" => "https://10.0.0.5",
                 "owner_uuid" => UUIDv7.generate()
               })

      assert message =~ "local, private or metadata"
    end

    test "a site bucket's private endpoint goes on to the request" do
      assert {:error, message} =
               Storage.test_connection(%{
                 "provider" => "s3",
                 "bucket_name" => "b",
                 "endpoint" => "http://127.0.0.1:1"
               })

      refute message =~ "local, private or metadata"
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
