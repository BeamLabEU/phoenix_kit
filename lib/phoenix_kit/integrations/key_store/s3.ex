defmodule PhoenixKit.Integrations.KeyStore.S3 do
  @moduledoc """
  Optional off-host copy of the encryption secret, in an S3-compatible bucket.

  AWS S3, Cloudflare R2, Backblaze B2, Tigris, MinIO — anything the existing
  `ex_aws_s3` dependency talks to. **Optional in the strong sense**: PhoenixKit
  works with no bucket, no AWS account and no network. Use it as a second member
  of `PhoenixKit.Integrations.KeyStore.Chain`, behind the local file, so the
  bucket is a spare copy rather than the thing everything depends on:

      config :phoenix_kit,
        integrations_key_store:
          {PhoenixKit.Integrations.KeyStore.Chain,
           stores: [
             PhoenixKit.Integrations.KeyStore.File,
             {PhoenixKit.Integrations.KeyStore.S3, bucket: "my-ops-bucket"}
           ]}

  ## Why the credentials do NOT come from an integration connection

  The obvious idea is to configure this through the integrations system, the
  same way any other provider is configured. It cannot carry the read path, and
  the reason is structural rather than a matter of effort.

  An integration connection's `secret_key` is in
  `PhoenixKit.Integrations.Encryption.sensitive_fields/0`, so it is stored
  **encrypted with the integration key**. Reading the secret out of a bucket
  whose credentials are themselves encrypted under that secret requires the
  secret you are trying to fetch. Writes work — during a rotation the old key is
  live, so the credentials decrypt — which is the dangerous part: it would
  produce a backup that is written successfully and can never be restored from.
  A backup you cannot restore from is worse than none, because you stop looking
  for a real one.

  So credentials come from `ExAws`'s own resolution: environment variables, an
  instance role, or an explicit `:ex_aws_config`. On AWS with an instance role
  there is no stored secret at all, which removes the circularity completely.

  What the integrations system *can* usefully hold is the part that is not
  secret — which bucket, which region, which object — and that is a later,
  separate step; nothing here needs it.

  ## What is stored

  One object, the secret as its body, written with `AES256` server-side
  encryption. Bucket-side access control is the operator's to set: this module
  refuses to pretend it can make a public bucket safe.
  """

  @behaviour PhoenixKit.Integrations.KeyStore

  alias PhoenixKit.Modules.Storage.Providers.S3Request

  @default_object "phoenix_kit/integrations-encryption.key"

  @impl true
  def read(opts) do
    with :ok <- ensure_ex_aws(),
         {:ok, bucket} <- bucket(opts) do
      bucket
      |> ExAws.S3.get_object(object_key(opts))
      |> request(opts)
      |> case do
        {:ok, %{body: body}} -> interpret(String.trim(body), bucket, opts)
        {:error, {:http_error, 404, _}} -> :not_configured
        {:error, reason} -> {:error, {:s3_read_failed, location(opts), sanitize(reason)}}
      end
    end
  end

  # Consistent with the file store: an object that exists and holds nothing is
  # an error, not "nothing stored yet". The two lead to opposite actions.
  defp interpret("", bucket, opts), do: {:error, {:empty, location(bucket, opts)}}
  defp interpret(secret, _bucket, _opts), do: {:ok, secret}

  @impl true
  def write(secret, opts) when is_binary(secret) do
    with :ok <- ensure_ex_aws(),
         {:ok, bucket} <- bucket(opts) do
      bucket
      |> ExAws.S3.put_object(object_key(opts), secret, server_side_encryption: "AES256")
      |> request(opts)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:s3_write_failed, location(opts), sanitize(reason)}}
      end
    end
  end

  @impl true
  def preflight(opts) do
    with :ok <- ensure_ex_aws(),
         {:ok, bucket} <- bucket(opts) do
      # A probe object, never the real one: a pre-flight must not be able to
      # truncate a secret that is already stored.
      probe = object_key(opts) <> ".preflight"

      bucket
      |> ExAws.S3.put_object(probe, "", server_side_encryption: "AES256")
      |> request(opts)
      |> case do
        {:ok, _} -> remove_probe(bucket, probe, opts)
        {:error, reason} -> {:error, {:s3_not_writable, location(opts), sanitize(reason)}}
      end
    end
  end

  # An ignored delete result here means a preflight that failed to clean up
  # after itself still reports :ok — worth saying rather than leaving orphan
  # probe objects behind on every check, same as the file store's own probe
  # cleanup.
  defp remove_probe(bucket, probe, opts) do
    bucket
    |> ExAws.S3.delete_object(probe)
    |> request(opts)
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, {:s3_probe_not_removable, location(bucket, opts), sanitize(reason)}}
    end
  end

  @impl true
  def describe(opts), do: location(opts)

  defp location(opts) do
    case bucket(opts) do
      {:ok, bucket} -> location(bucket, opts)
      _ -> "s3://<bucket not configured>"
    end
  end

  defp location(bucket, opts), do: "s3://#{bucket}/#{object_key(opts)}"

  defp object_key(opts), do: Keyword.get(opts, :key, @default_object)

  defp bucket(opts) do
    case Keyword.get(opts, :bucket) do
      bucket when is_binary(bucket) and bucket != "" -> {:ok, bucket}
      _ -> {:error, {:bucket_not_configured, __MODULE__}}
    end
  end

  # Through `S3Request`, or a Backblaze B2 region raises before the host applies.
  defp request(operation, opts) do
    S3Request.request(operation, Keyword.get(opts, :ex_aws_config, []))
  rescue
    # A misconfigured ExAws (no region, unusable credential provider) raises
    # rather than returning. Keep only the exception type: its message can quote
    # request details.
    e -> {:error, {:ex_aws_raised, e.__struct__}}
  end

  # A hard dependency today, but a release can be assembled without it. Saying
  # so beats an UndefinedFunctionError whose report would carry the arguments —
  # and for `write/2` the argument is the secret.
  defp ensure_ex_aws do
    if Code.ensure_loaded?(ExAws) and Code.ensure_loaded?(ExAws.S3) do
      :ok
    else
      {:error, {:ex_aws_unavailable, __MODULE__}}
    end
  end

  # ExAws error terms carry response bodies and, depending on the operation,
  # request details. Reduce to something an operator can act on and nothing
  # else: this value ends up in logs and operator-facing messages.
  defp sanitize({:http_error, status, _body}), do: {:http_error, status}
  defp sanitize(reason) when is_atom(reason), do: reason
  defp sanitize(reason) when is_binary(reason), do: reason
  defp sanitize(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp sanitize(_reason), do: :unrecognised_error
end
