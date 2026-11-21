defmodule PhoenixKit.Modules.Storage.CDNSource do
  @moduledoc "Storage bucket mappings and end-to-end checks for CDN integrations."
  import Ecto.Query
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.ConnectionLock
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.Endpoint
  alias PhoenixKit.Modules.Storage.Providers.{Local, S3}
  alias PhoenixKit.RepoHelper

  def choices(owner) do
    buckets =
      case owner do
        :system -> Storage.list_buckets()
        {:user, id} -> Storage.list_owned_buckets(id)
      end

    for bucket <- buckets, bucket.enabled do
      %{
        uuid: bucket.uuid,
        name: bucket.name,
        provider: bucket.provider,
        region: bucket.region,
        origin: suggestion(bucket)
      }
    end
  end

  def suggestion(%Bucket{provider: "local"}), do: nil

  def suggestion(%Bucket{} = bucket) do
    # Legacy cdn_url can already be an edge hostname. Never point a zone at itself.
    case S3.public_url(%{bucket | cdn_url: nil}, "cdn-pilot/") do
      "https://" <> _ = url -> url
      _ -> nil
    end
  end

  def setup_path(id), do: setup_path(id, mapping(id))

  def setup_path(id, nil),
    do: "/admin/settings/integrations/new?service=cdn_delivery&source_bucket_uuid=" <> id

  def setup_path(_, %{uuid: uuid}), do: "/admin/settings/integrations/" <> uuid

  def mappings(ids, owner \\ :system), do: Integrations.cdn_bucket_mappings(ids, owner)

  def verify(uuid, owner) do
    with {:ok, %{provider: provider, data: data}} <-
           Integrations.get_integration_by_uuid(uuid, owner),
         %{cdn_adapter: adapter} <- Providers.get(provider),
         {:ok, id} <- Ecto.UUID.cast(data["source_bucket_uuid"]),
         %Bucket{enabled: true} = bucket <- RepoHelper.repo().get(Bucket, id),
         true <- bucket_owner(bucket) == owner,
         {:ok, base} <- adapter.check_origin(uuid, owner, data["source_origin"]),
         %{scheme: "https"} = endpoint <- Endpoint.parse(base),
         :ok <- Endpoint.check(endpoint, :personal, resolve: true),
         :ok <- probe(bucket, base, uuid, owner, adapter) do
      record_check(uuid, owner, data)
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_cdn_source}
    end
  end

  defp record_check(uuid, owner, expected) do
    ConnectionLock.run(uuid, fn ->
      with {:ok, %{data: ^expected}} <- Integrations.get_integration_by_uuid(uuid, owner),
           {:ok, _} <-
             Integrations.save_setup(
               uuid,
               %{"source_checked_at" => DateTime.to_iso8601(DateTime.utc_now())},
               nil,
               owner: owner
             ) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :configuration_changed}
      end
    end)
  end

  # Only a random, disposable file under the dedicated delivery prefix is exposed.
  # No management key or origin credentials go to the edge.
  defp probe(bucket, base, uuid, owner, adapter) do
    key = "check-" <> UUIDv7.generate() <> ".txt"
    body = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    store = if bucket.provider == "local", do: Local, else: S3
    path = "cdn-pilot/" <> key

    with {:ok, tmp} <- Plug.Upload.random_file("cdn-check") do
      try do
        with :ok <- File.write(tmp, body),
             {:ok, _} <- store.store_file(bucket, tmp, path, content_type: "text/plain") do
          url = base <> "/" <> key
          cold = check_bytes(url, body)

          with :ok <- store.delete_file(bucket, path) do
            # An exact second read after origin deletion proves this edge cached it.
            warm = if cold == :ok, do: check_bytes(url, body), else: cold
            purge = adapter.purge(uuid, owner, key)

            cond do
              cold != :ok ->
                cold

              purge != :ok ->
                {:error, :withdrawal_failed}

              warm != :ok ->
                {:error, :cache_miss}

              true ->
                case edge_get(url, byte_size(body)) do
                  {:ok, %{status: status}} when status in [403, 404, 410] -> :ok
                  _ -> {:error, :withdrawal_failed}
                end
            end
          end
        end
      after
        File.rm(tmp)
      end
    end
  end

  defp check_bytes(url, expected) do
    case edge_get(url, byte_size(expected)) do
      {:ok, %{status: 200, body: ^expected}} -> :ok
      _ -> {:error, :test_object_unreadable}
    end
  end

  defp edge_get(url, limit) do
    into = fn {:data, chunk}, {req, resp} ->
      body = (resp.body || "") <> chunk

      if byte_size(body) > limit,
        do: {:halt, {req, %{resp | body: :oversized}}},
        else: {:cont, {req, %{resp | body: body}}}
    end

    test_opts =
      Keyword.take(Application.get_env(:phoenix_kit, :integrations_check_req_options, []), [:plug])

    Req.get(url, [redirect: false, retry: false, receive_timeout: 8_000, into: into] ++ test_opts)
  end

  def reset_check(data, attrs) do
    if data["source_checked_at"] && Enum.any?(attrs, fn {key, value} -> data[key] != value end),
      do: Map.delete(data, "source_checked_at"),
      else: data
  end

  def mapping(bucket_uuid) do
    Map.get(mappings([bucket_uuid]), bucket_uuid)
  end

  # Called inside the integration's write transaction. Serializing on the target
  # bucket prevents two different connections from claiming it at the same time.
  def validate(provider, uuid, owner, %{"source_bucket_uuid" => id} = attrs) do
    if Providers.cdn_delivery?(Providers.get(provider)),
      do: validate_bucket(uuid, owner, id, attrs),
      else: {:error, :invalid_cdn_source}
  end

  def validate(_, _, _, %{"source_origin" => _}), do: {:error, :invalid_cdn_source}
  def validate(_, _, _, _), do: :ok

  defp validate_bucket(uuid, owner, id, attrs) do
    if id == "" and attrs["source_origin"] in [nil, ""] do
      :ok
    else
      with {:ok, ^id} <- Ecto.UUID.cast(id),
           true <- String.downcase(id) == id,
           %Bucket{enabled: true} = bucket <-
             RepoHelper.repo().one(from b in Bucket, where: b.uuid == ^id, lock: "FOR UPDATE"),
           true <- owner == bucket_owner(bucket),
           true <- valid_origin?(attrs["source_origin"]),
           existing when is_nil(existing) or existing.uuid == uuid <- mappings([id], owner)[id] do
        :ok
      else
        _ -> {:error, :invalid_cdn_source}
      end
    end
  end

  defp bucket_owner(%Bucket{owner_uuid: nil}), do: :system
  defp bucket_owner(%Bucket{owner_uuid: id}), do: {:user, id}

  defp valid_origin?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: h, userinfo: nil, query: nil, fragment: nil}} ->
        is_binary(h) and h != ""

      _ ->
        false
    end
  end

  defp valid_origin?(_), do: false
end
