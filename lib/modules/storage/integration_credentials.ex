defmodule PhoenixKit.Modules.Storage.IntegrationCredentials do
  @moduledoc """
  Checks edits to storage connections without publishing candidate credentials.

  Network probes run before taking a database lock. The caller then takes the
  integration row lock shared by bucket attachments and checks the fingerprint
  again. A changed connection or dependency set refuses the save. Bucket
  endpoints remain fixed: changing service or destination means creating a new
  integration. Key rotation must pass a write/read/delete probe on every
  dependent bucket, including disabled buckets and trashed libraries.
  """

  import Ecto.Query

  alias PhoenixKit.Integrations.ObjectStorageServices
  alias PhoenixKit.Integrations.Probe
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.Endpoint
  alias PhoenixKit.Modules.Storage.FileLocation
  alias PhoenixKit.Modules.Storage.ProviderRegistry
  alias PhoenixKit.RepoHelper

  @identity_fields ~w(endpoint region account_id jurisdiction)
  @credential_fields ~w(access_key secret_key)

  def prepare(uuid, existing, attrs, opts) do
    candidate = Map.merge(existing, attrs)
    service = ObjectStorageServices.current(existing)
    buckets = dependent_buckets(uuid)

    result =
      cond do
        service != nil and ObjectStorageServices.current(candidate) != service ->
          {:error, :service_immutable}

        buckets != [] and destination_changed?(existing, attrs) ->
          {:error, :storage_destination_immutable}

        buckets != [] and changed?(existing, attrs, @credential_fields) ->
          validate_rotation(buckets, candidate, opts)

        true ->
          :ok
      end

    case result do
      :ok -> {:ok, fingerprint(existing, attrs, buckets)}
      error -> error
    end
  end

  def validate_prepared(uuid, existing, attrs, prepared) do
    if prepared == fingerprint(existing, attrs, dependent_buckets(uuid)),
      do: :ok,
      else: {:error, :storage_changed}
  end

  defp fingerprint(existing, attrs, buckets) do
    identity =
      Map.take(
        existing,
        ~w(service access_key secret_key endpoint region account_id jurisdiction)
      )

    dependencies =
      Enum.map(
        buckets,
        &Map.take(&1, [
          :uuid,
          :owner_uuid,
          :integration_uuid,
          :provider,
          :endpoint,
          :region,
          :bucket_name,
          :updated_at
        ])
      )

    :crypto.hash(:sha256, :erlang.term_to_binary({identity, attrs, dependencies}))
  end

  defp dependent_buckets(uuid) do
    from(b in Bucket, where: b.integration_uuid == ^uuid, order_by: b.uuid)
    |> RepoHelper.repo().all()
  end

  defp changed?(existing, attrs, fields) do
    Enum.any?(fields, fn key ->
      Map.has_key?(attrs, key) and normalize(attrs[key]) != normalize(existing[key])
    end)
  end

  # The edit form rebuilds `endpoint` from the service (`ObjectStorageServices.attrs/1`):
  # a stored `https://` URL becomes the bare host, and a standard AWS endpoint
  # becomes blank. That spelling is the same place. A different region, account,
  # jurisdiction, or host is still a destination change, including a custom AWS
  # host the form would otherwise blank.
  defp destination_changed?(existing, attrs) do
    existing = string_map(existing)
    attrs = string_map(attrs)
    proposed = Map.merge(existing, attrs)
    canonical_existing = identity_view(existing)
    canonical_proposed = identity_view(proposed)

    region =
      case normalize_identity(canonical_proposed["region"]) do
        nil -> canonical_existing["region"]
        region -> region
      end

    Enum.any?(@identity_fields, fn
      "endpoint" ->
        Map.has_key?(attrs, "endpoint") and
          not same_place?(existing["endpoint"], proposed["endpoint"], region)

      key ->
        Map.has_key?(attrs, key) and
          normalize_identity(canonical_existing[key]) !=
            normalize_identity(canonical_proposed[key])
    end)
  end

  defp identity_view(data) do
    data
    |> ObjectStorageServices.saved(%{})
    |> ObjectStorageServices.attrs()
  end

  defp same_place?(left, right, region) do
    parsed_place(left, region) == parsed_place(right, region)
  end

  defp parsed_place(endpoint, region) do
    case Endpoint.parse(endpoint) do
      nil ->
        :amazon_s3

      %{host: host, port: port} ->
        host = String.downcase(host)

        if port == 443 and aws_standard_host?(host, region),
          do: :amazon_s3,
          else: {host, port}

      _ ->
        {:raw, endpoint}
    end
  end

  # Blank AWS uses the region. These hosts are that same endpoint, so the form
  # may store the blank form. Any other host, including a VPC endpoint, is not.
  defp aws_standard_host?(host, region) do
    region = region |> to_string() |> String.trim() |> String.downcase()

    regional = [
      "s3.#{region}.amazonaws.com",
      "s3.dualstack.#{region}.amazonaws.com",
      "s3-#{region}.amazonaws.com"
    ]

    host == "s3.amazonaws.com" or (region != "" and host in regional)
  end

  defp string_map(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp normalize_identity(value) do
    case normalize(value) do
      nil -> nil
      binary when is_binary(binary) -> binary |> String.trim() |> String.downcase()
      other -> other
    end
  end

  defp normalize(value) when value in [nil, ""], do: nil
  defp normalize(value), do: value

  defp probe_candidate(bucket) do
    with :ok <- Storage.probe_bucket(bucket) do
      check_existing_object(bucket)
    end
  end

  # A key able to read only objects it just wrote must not be mistaken for a
  # key that can still read the library. Check an existing object's metadata
  # as well as the new probe object, without downloading a large original.
  defp check_existing_object(bucket) do
    path =
      RepoHelper.repo().one(
        from(l in FileLocation,
          where: l.bucket_uuid == ^bucket.uuid and l.status == "active",
          order_by: l.uuid,
          limit: 1,
          select: l.path
        )
      )

    if path do
      Probe.run(fn ->
        with {:ok, provider} <- ProviderRegistry.get_provider(bucket.provider),
             true <- provider.file_exists?(bucket, path) do
          :ok
        else
          _ -> {:error, :existing_object_unreadable}
        end
      end)
    else
      :ok
    end
  end

  defp validate_rotation(buckets, candidate, opts) do
    if Enum.all?(@credential_fields, &(is_binary(candidate[&1]) and candidate[&1] != "")) do
      probe = Keyword.get(opts, :storage_probe, &probe_candidate/1)

      Enum.reduce_while(buckets, :ok, fn bucket, :ok ->
        # Candidate keys exist on this throwaway struct only. S3 resolves its
        # direct keys rather than loading the old integration from the DB.
        probe_bucket = %{
          bucket
          | integration_uuid: nil,
            access_key_id: candidate["access_key"],
            secret_access_key: candidate["secret_key"]
        }

        case probe.(probe_bucket) do
          :ok -> {:cont, :ok}
          _ -> {:halt, {:error, {:storage_validation_failed, bucket.name}}}
        end
      end)
    else
      {:error, :storage_credentials_required}
    end
  end
end
