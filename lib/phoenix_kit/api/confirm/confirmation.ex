defmodule PhoenixKit.API.Confirm.Confirmation do
  @moduledoc """
  One confirmation code of a dangerous API operation, or one approval request of a write
  call (table `phoenix_kit_api_confirmations`).

    * `kind` - `"token"` (a one-time code returned with a preview) or
      `"approval"` (a request that waits for a person).
    * `tool`, `input_hash`, `fingerprint` - what the row is bound to: the tool, a
      canonical hash of the arguments (control fields excluded) and a hash of the
      current values the operation would touch.
    * `input` - the arguments of an approval; `nil` for a code, and cleared when an
      approval is decided or expires.
    * `context` - for an approval: language, currency, hosts, base URL and request id of the
      original request (it runs without a request); only an approval's context is read
      back as such a snapshot. For a session's code: `%{}`, or, for a write held for a
      linked Telegram chat, `"origin"` (`"telegram"`), `"connection_uuid"` and `"chat_id"`
      (a string), which bind the row to that chat (`PhoenixKit.API.Confirm.from_origin?/2`).
    * `actor_key_uuid` / `client_token_hash` / `actor_user_uuid` - who it belongs to: an API
      key, the hash of a public caller's client token (the database column keeps the name it
      was created with; the field's `source:` maps it), or the person whose live session
      asked for the operation.
    * `preview` - what the person sees.
    * `status` - codes: `unused | used | expired | rejected` (`rejected`: a session's row the
      person turned down). Approvals: `pending | approved | executing | executed | failed |
      rejected | stale | expired`.
    * `result` - an approval's result, error and partial results.

  The flow is in `PhoenixKit.API.Confirm` and `PhoenixKit.API.Approvals`.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @kinds ~w(token approval)
  @statuses ~w(unused used expired pending approved executing executed failed rejected stale)

  # `fingerprint` is a `varchar(64)`: the one definition of what it may hold.
  @fingerprint_max 64

  schema "phoenix_kit_api_confirmations" do
    field :kind, :string
    field :tool, :string
    field :input_hash, :string
    field :fingerprint, :string
    field :input, :map
    field :context, :map, default: %{}
    field :actor_key_uuid, UUIDv7
    field :client_token_hash, :string, source: :cart_token_hash
    field :actor_user_uuid, UUIDv7
    field :preview, :map, default: %{}
    field :status, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :decided_by_uuid, UUIDv7
    field :decided_at, :utc_datetime
    field :result, :map
    field :notified_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "All statuses a row can have."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The longest fingerprint, in bytes."
  @spec fingerprint_max() :: pos_integer()
  def fingerprint_max, do: @fingerprint_max

  @doc "Whether the column can hold `fingerprint`: 1 to `fingerprint_max/0` bytes of UTF-8."
  @spec fingerprint_valid?(term()) :: boolean()
  def fingerprint_valid?(fingerprint) when is_binary(fingerprint),
    do: byte_size(fingerprint) in 1..@fingerprint_max and String.valid?(fingerprint)

  def fingerprint_valid?(_fingerprint), do: false

  @doc """
  The changeset the flow inserts rows with. Internal: nothing user-supplied is cast
  through it.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = row, attrs) do
    row
    |> cast(attrs, [
      :kind,
      :tool,
      :input_hash,
      :fingerprint,
      :input,
      :context,
      :actor_key_uuid,
      :client_token_hash,
      :actor_user_uuid,
      :preview,
      :status,
      :expires_at
    ])
    |> validate_required([:kind, :tool, :input_hash, :fingerprint, :status, :expires_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:tool, max: 120)
    |> validate_change(:fingerprint, fn :fingerprint, fingerprint ->
      if fingerprint_valid?(fingerprint),
        do: [],
        else: [fingerprint: "must be 1 to #{@fingerprint_max} bytes of UTF-8"]
    end)
    |> validate_actor()
  end

  defp validate_actor(changeset) do
    if get_field(changeset, :actor_key_uuid) || get_field(changeset, :client_token_hash) ||
         get_field(changeset, :actor_user_uuid) do
      changeset
    else
      add_error(changeset, :actor_key_uuid, "or a client token hash or a user is required")
    end
  end
end
