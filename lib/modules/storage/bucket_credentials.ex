defmodule PhoenixKit.Modules.Storage.BucketCredentials do
  @moduledoc """
  Moves a bucket's cloud keys into the Integrations system.

  A bucket used to carry its own `access_key_id` / `secret_access_key`. Keys now
  belong to an `object_storage` connection (**Settings → Integrations**), which
  buckets reference by `integration_uuid`: one place to rotate or revoke a key,
  one encrypted copy, and the same connection can serve several buckets.

  A bucket that still carries its own keys is **legacy** and keeps working for
  as long as it is left alone: `Providers.S3.resolve_credentials/1` reads either
  source. Nothing here runs by itself. An operator moves a bucket, or all of
  them, on purpose, and `move_to_integration/2` refuses to clear a key it could
  not read back through the new connection.

  The bucket keeps its own `region` and `endpoint`. They are not secrets, and
  reading them from the connection would put a settings lookup behind every
  public URL a file grid builds.
  """

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.Providers.S3

  @provider "object_storage"

  @type reason ::
          :not_legacy
          | :unreadable_credentials
          | :credentials_mismatch
          | Ecto.Changeset.t()
          | term()

  @doc "The Integrations provider key a bucket's keys move into."
  @spec provider_key() :: String.t()
  def provider_key, do: @provider

  @doc """
  Whether `bucket` is a cloud bucket that still carries its own keys, with no
  connection set.
  """
  @spec legacy?(Bucket.t()) :: boolean()
  def legacy?(%Bucket{} = bucket) do
    Bucket.cloud?(bucket) and not present?(bucket.integration_uuid) and
      (present?(bucket.access_key_id) or present?(bucket.secret_access_key))
  end

  @doc "Every bucket that still carries its own keys."
  @spec legacy_buckets() :: [Bucket.t()]
  def legacy_buckets, do: Enum.filter(Storage.list_buckets(), &legacy?/1)

  @doc """
  Moves one bucket's keys into a system `object_storage` connection.

  A connection that already holds the same key pair is reused, so buckets in
  one account share a single connection. Otherwise one is created, named after
  the bucket. The bucket's own keys are cleared only after the connection is
  read back and returns exactly the keys the bucket had; any failure rolls the
  whole move back, the new connection included.

  Options: `:actor_uuid` (recorded on the connection's and bucket's activity entries).
  """
  @spec move_to_integration(Bucket.t(), keyword()) :: {:ok, Bucket.t()} | {:error, reason()}
  def move_to_integration(%Bucket{} = bucket, opts \\ []) do
    actor_uuid = Keyword.get(opts, :actor_uuid)
    repo = PhoenixKit.RepoHelper.repo()

    repo.transaction(fn ->
      with :ok <- ensure_legacy(bucket),
           {:ok, keys} <- read_keys(bucket),
           {:ok, uuid} <- find_or_create_connection(bucket, keys, actor_uuid),
           :ok <- verify_round_trip(bucket, uuid, keys),
           {:ok, moved} <- clear_keys(bucket, uuid, opts) do
        moved
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  @doc """
  Moves every legacy bucket. Returns `[{bucket, {:ok, moved} | {:error, reason}}]`,
  one entry per bucket that was tried; a bucket that fails does not stop the rest.
  """
  @spec move_all_to_integrations(keyword()) :: [
          {Bucket.t(), {:ok, Bucket.t()} | {:error, reason()}}
        ]
  def move_all_to_integrations(opts \\ []) do
    Enum.map(legacy_buckets(), &{&1, move_to_integration(&1, opts)})
  end

  defp ensure_legacy(bucket), do: if(legacy?(bucket), do: :ok, else: {:error, :not_legacy})

  # The plaintext pair, from the one place that produces it. A secret that
  # cannot be decrypted (a rotated `secret_key_base`) must never be "moved":
  # that would replace a key that is merely unreadable now with a blank one.
  defp read_keys(bucket) do
    case S3.resolve_credentials(bucket) do
      {key, secret} when is_binary(key) and key != "" and is_binary(secret) and secret != "" ->
        {:ok, {key, secret}}

      _ ->
        {:error, :unreadable_credentials}
    end
  end

  defp find_or_create_connection(bucket, {key, secret}, actor_uuid) do
    existing =
      Enum.find(Integrations.list_connections(@provider), fn %{data: data} ->
        data["access_key"] == key and data["secret_key"] == secret
      end)

    case existing do
      %{uuid: uuid} -> {:ok, uuid}
      nil -> create_connection(bucket, {key, secret}, actor_uuid)
    end
  end

  defp create_connection(bucket, {key, secret}, actor_uuid) do
    attrs =
      Map.reject(
        %{
          "access_key" => key,
          "secret_key" => secret,
          "region" => bucket.region,
          "endpoint" => bucket.endpoint
        },
        fn {_field, value} -> not present?(value) end
      )

    with {:ok, %{uuid: uuid}} <- Integrations.add_connection(@provider, bucket.name, actor_uuid),
         {:ok, _saved} <- Integrations.save_setup(uuid, attrs, actor_uuid) do
      {:ok, uuid}
    end
  end

  # Reads the keys back through the connection the bucket is about to point at.
  defp verify_round_trip(bucket, uuid, keys) do
    through_connection = %{
      bucket
      | integration_uuid: uuid,
        access_key_id: nil,
        secret_access_key: nil
    }

    if S3.resolve_credentials(through_connection) == keys,
      do: :ok,
      else: {:error, :credentials_mismatch}
  end

  defp clear_keys(bucket, uuid, opts) do
    Storage.update_bucket(
      bucket,
      %{integration_uuid: uuid, access_key_id: nil, secret_access_key: nil},
      opts
    )
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
