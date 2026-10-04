defmodule PhoenixKit.Modules.Storage.BucketLogEntry do
  @moduledoc """
  One line of a site bucket's log (V208): a probe, or a write, read or delete
  that failed. The same failure seen again within a minute is one row whose
  `count` grows. Go through `PhoenixKit.Modules.Storage.BucketLog`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          bucket_uuid: UUIDv7.t() | nil,
          kind: String.t(),
          ok: boolean(),
          latency_ms: non_neg_integer() | nil,
          message: String.t() | nil,
          count: pos_integer(),
          inserted_at: NaiveDateTime.t() | nil,
          last_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_bucket_log" do
    field :bucket_uuid, UUIDv7
    field :kind, :string
    field :ok, :boolean
    field :latency_ms, :integer
    field :message, :string
    field :count, :integer, default: 1
    field :inserted_at, :naive_datetime
    field :last_at, :naive_datetime
  end
end
