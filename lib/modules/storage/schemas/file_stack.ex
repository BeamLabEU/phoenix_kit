defmodule PhoenixKit.Modules.Storage.FileStack do
  @moduledoc """
  A stack: two or more files of one library seen as one thing, such as the pages of a
  document or a burst (V232). Its files point at it (`File.stack_uuid`) and keep their
  places in it (`File.stack_position`).

  A stack has no date and no cover of its own: its date is its files' capture dates,
  and its cover is the first of its files a reader may see. What it does have is an
  optional `title` and `description`. `PhoenixKit.Modules.Storage.Stacks` makes and
  changes stacks.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @max_title 200
  @max_description 5000

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          library_uuid: UUIDv7.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          created_by_uuid: UUIDv7.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_file_stacks" do
    field :library_uuid, UUIDv7
    field :title, :string
    field :description, :string
    field :created_by_uuid, UUIDv7

    timestamps(type: :naive_datetime)
  end

  @doc "The longest title a stack may have, in characters."
  def max_title, do: @max_title

  @doc "The longest description a stack may have, in characters."
  def max_description, do: @max_description

  @doc """
  A new stack's row, or a change of its title and description. Blank text is stored as
  `nil`, so a stack without a title has none rather than an empty one.
  """
  def changeset(stack, attrs) do
    stack
    |> cast(attrs, [:library_uuid, :title, :description, :created_by_uuid])
    |> update_change(:title, &trim/1)
    |> update_change(:description, &trim/1)
    |> validate_required([:library_uuid])
    |> validate_length(:title, max: @max_title)
    |> validate_length(:description, max: @max_description)
    |> foreign_key_constraint(:library_uuid)
  end

  defp trim(nil), do: nil

  defp trim(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
