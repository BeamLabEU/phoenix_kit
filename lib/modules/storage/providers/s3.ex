defmodule PhoenixKit.Modules.Storage.Providers.S3 do
  @moduledoc """
  AWS S3 storage provider.

  Stores files in Amazon S3 buckets using the ExAWS library.
  Supports all S3-compatible services (like Backblaze B2, Cloudflare R2, Tigris).

  Files under 5 MB are uploaded via `put_object` (single request).
  Files at or above 5 MB use multipart upload via `ExAws.S3.upload/4`
  with streaming and concurrent chunk uploads.
  """

  require Logger

  alias ExAws.S3.Upload
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Modules.Storage.Endpoint

  @behaviour PhoenixKit.Modules.Storage.Provider

  # Files at or above this size use multipart upload
  @multipart_threshold 5 * 1024 * 1024

  @impl true
  def store_file(bucket, source_path, destination_path, opts \\ []) do
    case File.stat(source_path) do
      {:ok, %{size: size}} when size >= @multipart_threshold ->
        multipart_upload(bucket, source_path, destination_path, opts)

      {:ok, _stat} ->
        simple_upload(bucket, source_path, destination_path, opts)

      {:error, reason} ->
        Logger.error("S3 upload: cannot access source file #{source_path}: #{inspect(reason)}")
        {:error, "Cannot access source file: #{inspect(reason)}"}
    end
  rescue
    error ->
      Logger.error("S3 upload exception for #{bucket.name}: #{Exception.message(error)}")
      {:error, "Error storing file to S3: #{inspect(error)}"}
  end

  @impl true
  def retrieve_file(bucket, file_path, destination_path) do
    destination_dir = Path.dirname(destination_path)
    File.mkdir_p!(destination_dir)

    case ExAws.S3.download_file(bucket.bucket_name, file_path, destination_path)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, "Failed to download from S3: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error retrieving file from S3: #{inspect(error)}"}
  end

  @impl true
  def delete_file(bucket, file_path) do
    case ExAws.S3.delete_object(bucket.bucket_name, file_path)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, "Failed to delete from S3: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error deleting file from S3: #{inspect(error)}"}
  end

  # Only a 404 means the object is not there. Any other failure (denied,
  # a timeout, a client that cannot parse the reply) raises, naming the
  # bucket and the reason, never a credential: a broken connection must not
  # read as missing data. Every caller rescues it into "not here, for this
  # request" and logs it (`Manager`, the location backfill).
  @impl true
  def file_exists?(bucket, file_path) do
    case ExAws.S3.head_object(bucket.bucket_name, file_path)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} ->
        true

      {:error, {:http_error, 404, _}} ->
        false

      {:error, reason} ->
        raise "S3 HEAD on bucket #{bucket.name} failed: #{inspect(reason, limit: 5)}"
    end
  end

  @impl true
  def public_url(bucket, file_path) do
    cond do
      bucket.cdn_url ->
        "#{String.trim_trailing(bucket.cdn_url, "/")}/#{file_path}"

      # R2's S3 API host does not answer anonymous reads: a public R2 bucket
      # is read through its r2.dev or custom domain (`cdn_url`). Without
      # one there is no public URL, and the manager proxies instead.
      bucket.provider == "r2" ->
        nil

      true ->
        case endpoint(bucket) do
          nil -> aws_public_url(bucket, file_path)
          {:error, _reason} -> nil
          %{} = endpoint -> object_url(bucket, endpoint, file_path)
        end
    end
  end

  defp aws_public_url(bucket, file_path) do
    region = bucket.region || "us-east-1"
    "https://#{bucket.bucket_name}.s3.#{region}.amazonaws.com/#{file_path}"
  end

  # A custom S3-compatible endpoint is where the object is, not
  # amazonaws.com, addressed the way the requests are: virtual-host style
  # for Tigris (it refuses path style for newer buckets), path style for
  # the rest (B2, MinIO, Wasabi).
  defp object_url(bucket, %{scheme: scheme, host: host, port: port}, file_path) do
    authority = "#{url_host(host)}#{port_suffix(scheme, port)}"

    if virtual_host?(bucket),
      do: "#{scheme}://#{bucket.bucket_name}.#{authority}/#{file_path}",
      else: "#{scheme}://#{authority}/#{bucket.bucket_name}/#{file_path}"
  end

  # An IPv6 literal goes in brackets in a URL.
  defp url_host(host), do: if(String.contains?(host, ":"), do: "[#{host}]", else: host)

  @doc false
  # Whether requests to this bucket name it in the host
  # (`bucket.host/key`) rather than the path (`host/bucket/key`).
  def virtual_host?(%{provider: "tigris"}), do: true
  def virtual_host?(_bucket), do: false

  @doc """
  A bucket's endpoint, parsed: `%{scheme:, host:, port:}`; nil when none is
  set (plain AWS); `{:error, :invalid_endpoint}` when one is set but cannot
  be used. The one place a bucket's endpoint is read, so the host requests go
  to and the host a public URL names cannot disagree. The parsing itself is
  `PhoenixKit.Modules.Storage.Endpoint.parse/1`, shared with the Integrations
  validator so a connection is checked against the host it will be used on.
  """
  @spec endpoint(map()) :: Endpoint.parsed() | nil | {:error, :invalid_endpoint}
  def endpoint(%{endpoint: endpoint}), do: Endpoint.parse(endpoint)
  def endpoint(_bucket), do: nil

  defp ipv6_endpoint?(bucket) do
    case endpoint(bucket) do
      %{host: host} -> String.contains?(host, ":")
      _ -> false
    end
  end

  defp port_suffix("https", 443), do: ""
  defp port_suffix("http", 80), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  @impl true
  def signed_download_url(bucket, file_path, opts) do
    case resolve_credentials(bucket) do
      {key, secret} when is_binary(key) and key != "" and is_binary(secret) and secret != "" ->
        query_params =
          [
            {"response-content-disposition", Keyword.get(opts, :disposition)},
            {"response-content-type", Keyword.get(opts, :content_type)}
          ]
          |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)

        # ExAws writes an IPv6 host into a presigned URL unbracketed, which
        # no browser can open: such a bucket is proxied instead.
        if ipv6_endpoint?(bucket) do
          {:error, :ipv6_endpoint}
        else
          :s3
          |> ExAws.Config.new(aws_config(bucket))
          |> ExAws.S3.presigned_url(:get, bucket.bucket_name, file_path,
            expires_in: Keyword.get(opts, :expires_in, 3600),
            query_params: query_params,
            virtual_host: virtual_host?(bucket)
          )
        end

      _ ->
        {:error, :no_credentials}
    end
  rescue
    error -> {:error, "Error signing S3 download URL: #{Exception.message(error)}"}
  end

  # A bucket is usable only if an object can be written, read back and deleted,
  # so the check does all three with one throwaway object: read-only keys are
  # the most common misconfiguration, and listing the bucket (which a key scoped
  # to a prefix may not do) says nothing about object reads. The key is fresh
  # and unpredictable for every call, so it can never overwrite, or delete, an
  # object the bucket already holds, and two checks at once do not meet. What
  # this call wrote is removed again whatever stage failed.
  @impl true
  def test_connection(bucket) do
    config = aws_config(bucket)
    key = probe_key()

    with :ok <- probe_put(bucket, config, key) do
      read = probe_get(bucket, config, key)
      deleted = probe_delete(bucket, config, key)

      case {read, deleted} do
        {:ok, :ok} -> :ok
        {{:error, _} = error, _} -> error
        {:ok, {:error, _} = error} -> error
      end
    end
  rescue
    error -> {:error, "Error testing S3 connection: #{Exception.message(error)}"}
  end

  defp probe_key,
    do:
      ".phoenix_kit/connection-test-" <>
        Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp probe_put(bucket, config, key) do
    case ExAws.S3.put_object(bucket.bucket_name, key, "ok", acl: "private")
         |> ExAws.request(config) do
      {:ok, _result} ->
        :ok

      {:error, {:http_error, 404, _}} ->
        {:error, "Bucket not found"}

      {:error, {:http_error, 403, _}} ->
        if bucket.provider == "r2" do
          {:error,
           "R2 refused the test upload (HTTP 403). Give this integration's token Object Read & Write access to this bucket, or Admin Read & Write access. Permission to list buckets alone does not allow uploads."}
        else
          {:error, "The bucket could not be written to - check the key's write permission"}
        end

      {:error, reason} ->
        {:error, "Could not write a test file: #{inspect(reason, limit: 5)}"}
    end
  end

  defp probe_get(bucket, config, key) do
    case ExAws.S3.get_object(bucket.bucket_name, key) |> ExAws.request(config) do
      {:ok, %{body: "ok"}} ->
        :ok

      {:ok, _other} ->
        {:error, "The test file read back differently from what was written"}

      {:error, {:http_error, 403, _}} ->
        {:error,
         "A test file was written but could not be read back - the key needs read permission"}

      {:error, reason} ->
        {:error, "Could not read the test file back: #{inspect(reason, limit: 5)}"}
    end
  end

  defp probe_delete(bucket, config, key) do
    case ExAws.S3.delete_object(bucket.bucket_name, key) |> ExAws.request(config) do
      {:ok, _result} ->
        :ok

      {:error, {:http_error, 403, _}} ->
        {:error,
         "The bucket can be written to but files cannot be deleted - the key needs delete " <>
           "permission (a test file was left at #{key})"}

      {:error, reason} ->
        {:error, "Could not delete the test file #{key}: #{inspect(reason, limit: 5)}"}
    end
  end

  @doc false
  # The caller's `:content_type` when it passes one, otherwise the type of the
  # key's extension. Callers such as `Manager.copy_object/3` (the reconcile after
  # a profile change) pass no options, and an object stored without a
  # `Content-Type` is served as binary/octet-stream, which a browser downloads
  # instead of showing. (#951)
  @spec upload_content_type(keyword(), String.t()) :: String.t()
  def upload_content_type(opts, destination_path),
    do: Keyword.get(opts, :content_type) || MIME.from_path(destination_path)

  # Single-request upload for small files (<5 MB).
  # Reads entire file into memory and sends in one PUT request.
  defp simple_upload(bucket, source_path, destination_path, opts) do
    content_type = upload_content_type(opts, destination_path)

    case File.read(source_path) do
      {:ok, file_content} ->
        put_opts = [acl: Keyword.get(opts, :acl, "private"), content_type: content_type]

        case ExAws.S3.put_object(bucket.bucket_name, destination_path, file_content, put_opts)
             |> ExAws.request(aws_config(bucket)) do
          {:ok, _result} ->
            {:ok, public_url(bucket, destination_path)}

          {:error, reason} ->
            Logger.error("S3 put_object failed for #{bucket.name}: #{inspect(reason)}")
            {:error, "Failed to upload to S3: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("S3 upload: cannot read source file #{source_path}: #{inspect(reason)}")
        {:error, "Cannot read source file: #{inspect(reason)}"}
    end
  end

  # Multipart streaming upload for large files (>=5 MB).
  # Streams file in chunks with concurrent part uploads.
  defp multipart_upload(bucket, source_path, destination_path, opts) do
    content_type = upload_content_type(opts, destination_path)

    upload_opts = [
      acl: Keyword.get(opts, :acl, "private"),
      max_concurrency: 4,
      timeout: 60_000,
      content_type: content_type
    ]

    case source_path
         |> Upload.stream_file()
         |> ExAws.S3.upload(bucket.bucket_name, destination_path, upload_opts)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} ->
        {:ok, public_url(bucket, destination_path)}

      {:error, reason} ->
        Logger.error("S3 multipart upload failed for #{bucket.name}: #{inspect(reason)}")
        {:error, "Failed multipart upload to S3: #{inspect(reason)}"}
    end
  end

  # Build per-request ExAws config from bucket credentials.
  # Passed to ExAws.request/2 instead of using global Application.put_env.
  #
  # The HTTP client is Req, set here rather than left to the host's
  # `config :ex_aws, http_client:`. ExAws's default, hackney, returns a
  # 3-tuple for a HEAD under hackney 4 (which PhoenixKit requires), and
  # ExAws 2.7's hackney adapter does not match it: every HEAD raised, so
  # every object on an S3/R2 bucket read as missing and every download
  # (which starts with a HEAD) failed (#882; ex-aws/ex_aws#1255).
  @doc false
  def aws_config(bucket), do: build_config(bucket, virtual_host?(bucket), true)

  # The config for a call on the SERVICE rather than on one bucket (listing
  # the buckets an account holds): the endpoint's own host, never a bucket's
  # name in front of it, and no bucket name to validate.
  @doc false
  def service_config(bucket), do: build_config(bucket, false, false)

  defp build_config(bucket, virtual_host, bucket_scoped?) do
    {access_key_id, secret_access_key} = resolve_credentials(bucket)

    config = [
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      region: bucket.region || "us-east-1",
      http_client: ExAws.Request.Req
    ]

    config = if virtual_host, do: config ++ [virtual_host: true], else: config
    if bucket_scoped?, do: ensure_bucket_name!(bucket)

    case endpoint(bucket) do
      nil ->
        config

      # A set but unusable endpoint must not fall through to real AWS: the
      # operation fails with the reason instead (every provider call
      # rescues it into an error).
      {:error, :invalid_endpoint} ->
        raise ArgumentError, "bucket #{bucket.name}: the endpoint is not a usable URL"

      %{scheme: scheme, host: host, port: port} = endpoint ->
        # The host a request really goes to: a virtual-host bucket (Tigris) puts
        # its name in front of the endpoint's host, and it is THAT host the
        # policy must see — a name can resolve somewhere the base host does not.
        request = %{endpoint | host: if(virtual_host, do: request_host(bucket, host), else: host)}

        # An IP literal in a metadata/link-local/reserved range is never a
        # storage endpoint, whoever set it. Names are not resolved here for the
        # site's buckets (this runs per request); the bucket changeset and the
        # connection check resolve them when an endpoint is saved or tested.
        case Endpoint.check(request, endpoint_policy(bucket), endpoint_check_opts(bucket)) do
          :ok ->
            config ++ [host: host, scheme: scheme <> "://", port: port]

          {:error, reason} ->
            raise ArgumentError,
                  "bucket #{bucket.name}: the endpoint #{Endpoint.error_message(reason)}"
        end
    end
  end

  @doc """
  The names of the buckets the credentials of `bucket` (its integration) can
  see, sorted: S3's `ListBuckets`, the account-level call.

  `bucket` is only the connection's description here (`provider`, `region`,
  `endpoint`, `integration_uuid`, `owner_uuid`); it needs no bucket name.
  A key limited to one bucket is usually refused, and that is not a failure of
  the connection, so the reason says what to do instead.
  """
  @spec list_remote_buckets(map()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_remote_buckets(bucket) do
    config = service_config(bucket)

    case ExAws.S3.list_buckets() |> ExAws.request(config) do
      {:ok, %{body: %{buckets: buckets}}} when is_list(buckets) ->
        {:ok, buckets |> Enum.map(& &1.name) |> Enum.filter(&is_binary/1) |> Enum.sort()}

      {:ok, _other} ->
        {:error, "The service answered, but not with a list of buckets"}

      {:error, {:http_error, status, _}} when status in [401, 403] ->
        {:error,
         "This key is not allowed to list buckets (a key limited to one bucket cannot). " <>
           "Type the bucket name instead."}

      {:error, reason} ->
        {:error, "Could not list the buckets: #{inspect(reason, limit: 5)}"}
    end
  rescue
    error -> {:error, "Could not list the buckets: #{Exception.message(error)}"}
  end

  # Where a request for `bucket` is sent: its name in front of the endpoint's
  # host when the provider addresses buckets by host, the endpoint's host
  # otherwise.
  @doc false
  def request_host(bucket, host) do
    if virtual_host?(bucket) and is_binary(bucket.bucket_name),
      do: "#{bucket.bucket_name}.#{host}",
      else: host
  end

  # An owned bucket's name goes into the request's host or path: a delimiter in
  # it would change where a request or a presigned URL points.
  defp ensure_bucket_name!(%{owner_uuid: owner} = bucket) when is_binary(owner) do
    unless valid_bucket_name?(bucket.bucket_name),
      do: raise(ArgumentError, "bucket #{bucket.name}: the bucket name is not valid")
  end

  defp ensure_bucket_name!(_bucket), do: :ok

  @doc """
  Whether `name` is a bucket name an S3-protocol service accepts: 3 to 63
  lowercase letters, digits, dots and hyphens, starting and ending with a letter
  or digit, no `..`, and not shaped like an IP address. Nothing that could
  change the host or path of a request.
  """
  @spec valid_bucket_name?(term()) :: boolean()
  def valid_bucket_name?(name) when is_binary(name) do
    name =~ ~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/ and not String.contains?(name, "..") and
      not (name =~ ~r/\A\d+\.\d+\.\d+\.\d+\z/)
  end

  def valid_bucket_name?(_name), do: false

  # A user's own bucket is held to the strict policy every time a request is
  # built, with the host resolved: the name may have changed since it was saved.
  # The site's buckets are literal-only here (this is a per-request path).
  defp endpoint_policy(%{owner_uuid: owner}) when is_binary(owner), do: :personal
  defp endpoint_policy(_bucket), do: :system

  defp endpoint_check_opts(%{owner_uuid: owner}) when is_binary(owner), do: [resolve: true]
  defp endpoint_check_opts(_bucket), do: []

  # Resolves the actual (plaintext) access key id / secret access key for a
  # bucket — the one place this happens, right where the ExAws config needs
  # them. `Bucket.changeset/2` guarantees only one of the two credential
  # sources below is ever set on a saved bucket.
  #
  # Every failure path here returns {nil, nil} / a nil secret rather than
  # raising — a bad/expired credential should fail as an ExAws auth error on
  # the actual request, not crash the caller. Each path logs why first,
  # naming the bucket and the failure REASON only, never a credential value.
  #
  # Public and `@doc false` (not part of the `Provider` behaviour) purely so
  # the test suite can exercise both branches directly, without a real S3
  # endpoint — same rationale as `V174.repair_statements/1`.
  @doc false
  @spec resolve_credentials(PhoenixKit.Modules.Storage.Bucket.t()) ::
          {String.t() | nil, String.t() | nil}
  def resolve_credentials(%{integration_uuid: integration_uuid} = bucket)
      when is_binary(integration_uuid) and integration_uuid != "" do
    # The owner is passed, never left at the `:any` default: a bucket may
    # only read a connection its own owner owns. Every bucket is a system
    # bucket until buckets can be user-owned (V206), which adds its owner here.
    case Integrations.get_credentials(integration_uuid, owner: credential_owner(bucket)) do
      {:ok, creds} ->
        # "access_key"/"secret_key" is the generic key-secret shape
        # `PhoenixKit.Integrations` providers use for AWS-style credentials
        # (see `aws_ses`, and `PhoenixKit.Mailer.swoosh_config_for/1`) — the
        # `object_storage` provider this bucket-side integration_uuid exists
        # for (`PhoenixKit.Integrations.Providers.object_storage/0`, added in
        # a parallel branch) declares the same two field keys.
        access_key = creds["access_key"]
        secret_key = creds["secret_key"]

        if is_binary(access_key) and access_key != "" and is_binary(secret_key) and
             secret_key != "" do
          {access_key, secret_key}
        else
          Logger.error(
            "S3 bucket #{bucket.name}: integration #{integration_uuid} has no " <>
              "access_key/secret_key configured"
          )

          {nil, nil}
        end

      {:error, reason} ->
        Logger.error(
          "S3 bucket #{bucket.name}: failed to resolve credentials from integration " <>
            "#{integration_uuid}: #{inspect(reason)}"
        )

        {nil, nil}
    end
  end

  def resolve_credentials(bucket) do
    secret =
      case Encryption.decrypt_value(bucket.secret_access_key) do
        {:ok, plaintext} ->
          plaintext

        {:error, reason} ->
          Logger.error(
            "S3 bucket #{bucket.name}: failed to decrypt secret_access_key: #{inspect(reason)}"
          )

          nil
      end

    {bucket.access_key_id, secret}
  end

  # Whose connections a bucket may read: the owner's, for a user's own bucket
  # (V206); the site's for every other.
  defp credential_owner(%{owner_uuid: owner}) when is_binary(owner), do: {:user, owner}
  defp credential_owner(_bucket), do: :system
end
