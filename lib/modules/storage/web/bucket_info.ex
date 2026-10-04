defmodule PhoenixKitWeb.Live.Modules.Storage.BucketInfo do
  @moduledoc """
  How the Storage settings describe a bucket in words: its type, the service it
  is on, where its files go. Shared by the Buckets list and the bucket's own
  page so the two never disagree.
  """
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.ObjectStorageServices, as: Services
  alias PhoenixKit.Modules.Storage.Endpoint

  @doc """
  The Object Storage connections a bucket may use, reduced to a name and the
  service each is for: `%{connection_uuid => %{name, service}}`. Nothing secret
  is kept: `list_connections/1` returns decrypted data, only the service is
  taken from it.
  """
  @spec connections() :: %{optional(term()) => %{name: String.t(), service: term()}}
  def connections do
    "object_storage"
    |> Integrations.list_connections()
    |> Map.new(fn %{uuid: uuid, name: name, data: data} ->
      {uuid, %{name: name, service: Services.current(data)}}
    end)
  rescue
    _ -> %{}
  end

  @doc "Local, or Cloud."
  @spec type(struct()) :: String.t()
  def type(%{provider: "local"}), do: gettext("Local")
  def type(_bucket), do: gettext("Cloud")

  @doc """
  The service a cloud bucket is on: the one its integration is for, else what
  the provider says (a bucket that carries its own keys has no integration).
  """
  @spec service(struct(), map()) :: String.t() | nil
  def service(%{provider: "local"}, _connections), do: nil

  def service(bucket, connections) do
    case connections[bucket.integration_uuid] do
      %{service: service} when is_binary(service) -> Services.name(service)
      _ -> provider_name(bucket.provider)
    end
  end

  @doc """
  Where the files go, in words: a path for a local bucket, otherwise the
  bucket's name on the service and the host it is reached at (or its region).
  """
  @spec location(struct()) :: String.t()
  def location(%{provider: "local"} = bucket),
    do: bucket.endpoint || gettext("No path configured")

  def location(bucket) do
    host =
      case Endpoint.parse(bucket.endpoint) do
        %{host: host} -> host
        _ -> bucket.region
      end

    [bucket.bucket_name || gettext("No bucket name"), host]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp provider_name("s3"), do: "AWS S3"
  defp provider_name("b2"), do: "Backblaze B2"
  defp provider_name("r2"), do: "Cloudflare R2"
  defp provider_name("tigris"), do: "Tigris"
  defp provider_name(provider), do: String.upcase(to_string(provider))
end
