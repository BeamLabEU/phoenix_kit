defmodule PhoenixKit.Modules.Storage.Bucket do
  @moduledoc """
  Schema for storage provider configurations.

  Buckets represent storage locations where files can be stored. They can be:
  - **Local** filesystem storage
  - **AWS S3** buckets
  - **Backblaze B2** buckets
  - **Cloudflare R2** buckets
  - **Tigris** buckets

  ## Priority (legacy)

  Where new files go is decided by the **storage profile**, which has an upload
  order (`write_priority`) per bucket. A bucket's own `priority` is no longer
  shown or edited in the admin and is not copied into any profile. It is read
  only by the pre-profile selection (`Manager.store_file/2` with
  `:redundancy_copies` / `:priority_buckets`, or a database with no profiles)
  and to order the buckets a read falls back to when a file has no recorded
  location:

  - `priority = 0` (default): the pool, in random order when writing
  - `priority > 0`: a fixed position (1 = first, 2 = second, etc.)

  ## Fields

  - `name` - Display name for the bucket
  - `provider` - Storage provider: "local", "s3", "b2", "r2", "tigris"
  - `region` - AWS region or equivalent (nullable)
  - `endpoint` - Custom S3-compatible endpoint (nullable)
  - `bucket_name` - S3 bucket name (nullable)
  - `access_key_id` - Credentials identifier (nullable, stored as-is — not a secret)
  - `secret_access_key` - Encrypted at rest via `PhoenixKit.Integrations.Encryption`
    (nullable); decrypted only at the point of use (e.g. `Providers.S3`'s AWS
    config builder), never by a general accessor like `Storage.get_bucket/1`.
    A value already in this column when encryption was added is migrated
    opportunistically, not by a bulk backfill: the changeset re-derives and
    re-encrypts it on the next save of the bucket for ANY reason (see
    `encrypt_secret_access_key/1`), so it stays plaintext only until then
  - `integration_uuid` - Alternative credential source: a `PhoenixKit.Integrations`
    connection uuid (nullable, no FK). Mutually exclusive with
    `access_key_id`/`secret_access_key` — a changeset may set one source or the
    other, never both
  - `cdn_url` - CDN endpoint for file serving (nullable)
  - `access_type` - How files are served: "public", "private", "signed" (default: "public")
  - `enabled` - Whether bucket is active
  - `priority` - Legacy selection priority (0 = random); see above
  - `max_size_mb` - Maximum storage capacity in MB (nullable = unlimited)
  - `owner_uuid` - Whose bucket it is (V206). NULL is the site's, which is every
    bucket an admin creates. A user's own bucket carries its owner, never
    appears in a site listing (`Storage.list_buckets/0`,
    `Storage.list_enabled_buckets/0`), cannot be `local`, and takes its keys
    from the owner's personal connection only. **Never cast from params**:
    only `owned_changeset/3` sets it, from the signed-in user. No foreign key
    (see `Migrations.Postgres.V206`).

  ## Access Types

  - `public` - Redirect to public URL (default, fastest, uses CDN)
  - `private` - Proxy files through server (for ACL-protected buckets)
  - `signed` - Redirect to a presigned URL made for each request (5 minutes);
    proxied when the provider cannot sign. The plain object URL is never
    handed out

  ## Examples

      # Local storage bucket
      %Bucket{
        name: "Local SSD",
        provider: "local",
        enabled: true,
        priority: 0,
        max_size_mb: 512_000  # 500 GB
      }

      # AWS S3 bucket
      %Bucket{
        name: "Production S3",
        provider: "s3",
        region: "us-east-1",
        bucket_name: "my-app-files",
        access_key_id: "AKIA...",
        secret_access_key: "...",
        cdn_url: "https://cdn.example.com",
        enabled: true,
        priority: 1  # Highest priority
      }

      # Backblaze B2 bucket
      %Bucket{
        name: "Backup B2",
        provider: "b2",
        endpoint: "s3.us-west-002.backblazeb2.com",
        bucket_name: "my-backup-bucket",
        access_key_id: "...",
        secret_access_key: "...",
        enabled: true,
        priority: 2
      }
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Modules.Storage.Endpoint
  alias PhoenixKit.Modules.Storage.Providers.S3

  # Every provider that speaks the S3 protocol and so needs a bucket name and
  # credentials. Tigris is one: it was once left out of this list, so a Tigris
  # bucket saved with neither.
  @cloud_providers ~w(s3 b2 r2 tigris)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t(),
          provider: String.t(),
          region: String.t() | nil,
          endpoint: String.t() | nil,
          bucket_name: String.t() | nil,
          access_key_id: String.t() | nil,
          secret_access_key: String.t() | nil,
          integration_uuid: UUIDv7.t() | nil,
          cdn_url: String.t() | nil,
          access_type: String.t(),
          enabled: boolean(),
          priority: integer(),
          max_size_mb: integer() | nil,
          owner_uuid: UUIDv7.t() | nil,
          file_locations:
            [PhoenixKit.Modules.Storage.FileLocation.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_buckets" do
    field :name, :string
    field :provider, :string
    field :region, :string
    field :endpoint, :string
    field :bucket_name, :string
    field :access_key_id, :string
    field :secret_access_key, :string, redact: true
    field :integration_uuid, UUIDv7
    field :cdn_url, :string
    field :access_type, :string, default: "public"
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 0
    field :max_size_mb, :integer
    field :owner_uuid, UUIDv7

    has_many :file_locations, PhoenixKit.Modules.Storage.FileLocation, foreign_key: :bucket_uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a bucket.

  ## Required Fields

  - `name`
  - `provider` (must be one of: "local", "s3", "b2", "r2", "tigris")

  ## Validation Rules

  - Provider must be valid
  - Priority must be >= 0
  - Quality must be between 1-100 (if provided)
  - S3/B2/R2 buckets require credentials — either `access_key_id`/
    `secret_access_key` directly, or an `integration_uuid`
  - `integration_uuid` and `access_key_id`/`secret_access_key` are mutually
    exclusive: setting both in the same change is a validation error, not a
    silent overwrite of one by the other

  `secret_access_key` is encrypted at rest (see
  `PhoenixKit.Integrations.Encryption`) as part of this changeset —
  already-encrypted values pass through unchanged. A row written before
  encryption existed stays plaintext until the next save of any kind (no
  bulk backfill — see the `secret_access_key` field doc above).
  """
  def changeset(bucket, attrs) do
    bucket
    |> cast(attrs, [
      :name,
      :provider,
      :region,
      :endpoint,
      :bucket_name,
      :access_key_id,
      :secret_access_key,
      :integration_uuid,
      :cdn_url,
      :access_type,
      :enabled,
      :priority,
      :max_size_mb
    ])
    |> validate_required([:name, :provider])
    |> validate_inclusion(:provider, ["local", "s3", "b2", "r2", "tigris"])
    |> validate_inclusion(:access_type, ["public", "private", "signed"])
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_number(:max_size_mb, greater_than: 0)
    |> validate_credentials_exclusive()
    |> validate_cloud_credentials()
    |> validate_endpoint()
    |> encrypt_secret_access_key()
    |> check_owned_rules()
  end

  # The database refuses an owned bucket that is `local`, carries keys of its
  # own, or serves plain object URLs (`phoenix_kit_buckets_owned_check`); as an
  # error on the changeset rather than a raise, for anything that edits one.
  defp check_owned_rules(changeset) do
    check_constraint(changeset, :owner_uuid,
      name: :phoenix_kit_buckets_owned_check,
      message: "a user's bucket must be S3-protocol, on a connection, and not public"
    )
  end

  @doc """
  Changeset for a user's own bucket (V206).

  `owner_uuid` comes from the signed-in user, never from `attrs`. Only S3
  protocol providers (a `local` bucket would be arbitrary filesystem access on
  the server), always on a connection the owner owns (never keys stored on the
  bucket), always `signed` (the plain object URL is never handed out), with no
  `cdn_url` and no priority: the owner's storage profile decides how it is used.

  The endpoint is checked under the `:personal` policy, resolving the host, at
  save time; `Providers.S3` checks it again whenever a request is built.
  `:connection_owned?` (a function of the connection uuid) says whether the
  owner owns the connection; `Storage` passes the real check.
  """
  def owned_changeset(bucket, attrs, owner_uuid, opts \\ []) when is_binary(owner_uuid) do
    owned? = Keyword.get(opts, :connection_owned?, fn _uuid -> false end)

    bucket
    |> cast(attrs, [
      :name,
      :provider,
      :region,
      :endpoint,
      :bucket_name,
      :integration_uuid,
      :enabled
    ])
    |> put_change(:owner_uuid, owner_uuid)
    |> put_change(:access_type, "signed")
    |> put_change(:access_key_id, nil)
    |> put_change(:secret_access_key, nil)
    |> validate_required([:name, :provider, :bucket_name, :integration_uuid])
    |> validate_inclusion(:provider, @cloud_providers)
    |> validate_bucket_name_syntax()
    |> validate_endpoint_required()
    |> validate_owned_endpoint()
    |> validate_connection_owned(owned?)
    |> check_owned_rules()
  end

  # The name goes into a request's host or path (and a presigned URL), so an
  # owned bucket's must be one an S3-protocol service accepts, nothing with a
  # delimiter in it.
  defp validate_bucket_name_syntax(changeset) do
    case get_field(changeset, :bucket_name) do
      nil ->
        changeset

      name ->
        if S3.valid_bucket_name?(name),
          do: changeset,
          else:
            add_error(
              changeset,
              :bucket_name,
              "must be 3-63 lowercase letters, digits, dots or hyphens"
            )
    end
  end

  # B2, R2 and Tigris have no default host: without an endpoint every request
  # would go to AWS.
  defp validate_endpoint_required(changeset) do
    if get_field(changeset, :provider) in ["b2", "r2", "tigris"],
      do: validate_required(changeset, [:endpoint]),
      else: changeset
  end

  defp validate_owned_endpoint(changeset) do
    case Endpoint.check(get_field(changeset, :endpoint), :personal, resolve: true) do
      :ok -> changeset
      {:error, reason} -> add_error(changeset, :endpoint, Endpoint.error_message(reason))
    end
  end

  defp validate_connection_owned(changeset, owned?) do
    case get_field(changeset, :integration_uuid) do
      nil ->
        changeset

      uuid ->
        if owned?.(uuid),
          do: changeset,
          else: add_error(changeset, :integration_uuid, "is not one of your connections")
    end
  end

  # A cloud bucket's endpoint must be one `Endpoint.parse/1` can use: a set but
  # unusable one would otherwise fail every operation. Its literal address is
  # checked too (no metadata or link-local target); a hostname is resolved by
  # the connection test, not on every keystroke. A local bucket's endpoint is
  # a filesystem path, not a URL.
  defp validate_endpoint(changeset) do
    provider = get_field(changeset, :provider)

    if provider == "local" do
      changeset
    else
      case Endpoint.check(get_field(changeset, :endpoint), :system) do
        :ok -> changeset
        {:error, reason} -> add_error(changeset, :endpoint, Endpoint.error_message(reason))
      end
    end
  end

  # A bucket may resolve its cloud credentials from ITS OWN
  # access_key_id/secret_access_key OR from an Integrations connection —
  # never both. Two independently-writable sources for the same secret is
  # exactly the silent-drift shape this fix exists to close, so a change
  # that sets both is rejected outright rather than letting one field win.
  defp validate_credentials_exclusive(changeset) do
    has_integration = present?(get_field(changeset, :integration_uuid))

    has_direct_keys =
      present?(get_field(changeset, :access_key_id)) or
        present?(get_field(changeset, :secret_access_key))

    if has_integration and has_direct_keys do
      add_error(
        changeset,
        :integration_uuid,
        "clear access_key_id and secret_access_key before setting integration_uuid " <>
          "(or clear integration_uuid to use direct credentials instead) — only one " <>
          "credential source at a time"
      )
    else
      changeset
    end
  end

  defp validate_cloud_credentials(changeset) do
    provider = get_field(changeset, :provider)

    if provider in @cloud_providers do
      changeset
      |> validate_required([:bucket_name])
      |> validate_credentials_present()
    else
      changeset
    end
  end

  defp validate_credentials_present(changeset) do
    if present?(get_field(changeset, :integration_uuid)) do
      changeset
    else
      validate_required(changeset, [:access_key_id, :secret_access_key])
    end
  end

  defp encrypt_secret_access_key(changeset) do
    case get_field(changeset, :secret_access_key) do
      nil -> changeset
      "" -> changeset
      value -> put_change(changeset, :secret_access_key, Encryption.encrypt_value(value))
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  @doc """
  Returns whether this bucket is a local storage bucket.
  """
  def local?(%__MODULE__{provider: "local"}), do: true
  def local?(_), do: false

  @doc """
  Returns whether this bucket is a cloud storage bucket (S3, B2, R2, Tigris).
  """
  def cloud?(%__MODULE__{provider: provider}) when provider in @cloud_providers, do: true
  def cloud?(_), do: false

  @doc """
  The kind of place a bucket is for the copies a storage profile counts:
  `:local` (the server's own disk) or `:cloud` (S3, B2, R2, Tigris).
  """
  @spec group(t() | map()) :: :local | :cloud
  def group(%{provider: "local"}), do: :local
  def group(_bucket), do: :cloud
end
