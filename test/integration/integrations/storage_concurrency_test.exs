defmodule PhoenixKit.Integrations.StorageConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.ConnectionLock
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Test.Repo

  @moduletag :integration

  setup do
    Sandbox.mode(Repo, :auto)
    {:ok, %{uuid: uuid}} = Integrations.add_connection("object_storage", "Storage race")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "service" => "aws_s3",
        "access_key" => "old",
        "secret_key" => "old-secret"
      })

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      buckets = Repo.all(from(b in Bucket, where: b.integration_uuid == ^uuid, select: b.uuid))

      Repo.delete_all(
        from(pb in PhoenixKit.Modules.Storage.ProfileBucket, where: pb.bucket_uuid in ^buckets)
      )

      Repo.delete_all(from(b in Bucket, where: b.uuid in ^buckets))

      Repo.delete_all(
        from(e in PhoenixKit.Activity.Entry,
          where: e.resource_uuid == ^uuid or e.resource_uuid in ^buckets
        )
      )

      Repo.delete_all(from(s in Setting, where: s.uuid == ^uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{uuid: uuid}
  end

  defp bucket_attrs(uuid) do
    %{
      name: "race-#{System.unique_integer([:positive])}",
      provider: "s3",
      bucket_name: "race-photos",
      integration_uuid: uuid
    }
  end

  test "a deletion that wins the lock cannot be followed by a dangling attachment", %{uuid: uuid} do
    test = self()

    remover =
      Task.async(fn ->
        ConnectionLock.run(uuid, fn ->
          send(test, :deleting)

          receive do
            :release -> :ok
          after
            5_000 -> raise "release timed out"
          end

          Integrations.remove_connection(uuid)
        end)
      end)

    assert_receive :deleting
    attachment = Task.async(fn -> Storage.create_bucket(bucket_attrs(uuid), profile: nil) end)
    assert Task.yield(attachment, 50) == nil
    send(remover.pid, :release)
    assert :ok = Task.await(remover)
    assert {:error, %Ecto.Changeset{}} = Task.await(attachment)
    refute Repo.exists?(from(b in Bucket, where: b.integration_uuid == ^uuid))
  end

  test "attachment that wins the lock prevents deletion", %{uuid: uuid} do
    test = self()

    attachment =
      Task.async(fn ->
        ConnectionLock.run(uuid, fn ->
          send(test, :attaching)

          receive do
            :release -> :ok
          after
            5_000 -> raise "release timed out"
          end

          Storage.create_bucket(bucket_attrs(uuid), profile: nil)
        end)
      end)

    assert_receive :attaching
    remover = Task.async(fn -> Integrations.remove_connection(uuid) end)
    assert Task.yield(remover, 50) == nil
    send(attachment.pid, :release)
    assert {:ok, _bucket} = Task.await(attachment)
    assert {:error, {:in_use, [_ | _]}} = Task.await(remover)
  end

  test "disconnection that wins the lock prevents an unusable attachment", %{uuid: uuid} do
    test = self()

    disconnect =
      Task.async(fn ->
        ConnectionLock.run(uuid, fn ->
          send(test, :disconnecting)

          receive do
            :release -> :ok
          after
            5_000 -> raise "release timed out"
          end

          Integrations.disconnect(uuid)
        end)
      end)

    assert_receive :disconnecting
    attachment = Task.async(fn -> Storage.create_bucket(bucket_attrs(uuid), profile: nil) end)
    assert Task.yield(attachment, 50) == nil
    send(disconnect.pid, :release)
    assert :ok = Task.await(disconnect)
    assert {:error, %Ecto.Changeset{}} = Task.await(attachment)
  end

  test "a bucket attached during credential testing forces a fresh validation", %{uuid: uuid} do
    {:ok, _} = Storage.create_bucket(bucket_attrs(uuid), profile: nil)
    test = self()

    rotate =
      Task.async(fn ->
        Integrations.save_setup(uuid, %{"access_key" => "new"}, nil,
          storage_probe: fn _bucket ->
            send(test, {:probing, self()})

            receive do
              :release -> :ok
            after
              5_000 -> raise "release timed out"
            end
          end
        )
      end)

    assert_receive {:probing, prober}
    assert {:ok, _} = Storage.create_bucket(bucket_attrs(uuid), profile: nil)
    send(prober, :release)
    assert {:error, :storage_changed} = Task.await(rotate)
    assert {:ok, %{data: %{"access_key" => "old"}}} = Integrations.get_integration_by_uuid(uuid)
  end
end
