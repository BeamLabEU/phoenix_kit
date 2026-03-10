defmodule PhoenixKit.Modules.Newsletters.List do
  @moduledoc """
  Ecto schema for newsletter lists.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["active", "archived"]

  schema "phoenix_kit_newsletters_lists" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :status, :string, default: "active"
    field :is_default, :boolean, default: false
    field :subscriber_count, :integer, default: 0

    has_many :members, PhoenixKit.Modules.Newsletters.ListMember,
      foreign_key: :list_uuid,
      references: :uuid

    has_many :broadcasts, PhoenixKit.Modules.Newsletters.Broadcast,
      foreign_key: :list_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  def changeset(list, attrs) do
    list
    |> cast(attrs, [:name, :slug, :description, :status, :is_default])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:slug, min: 1, max: 255)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> unique_constraint(:slug)
    |> auto_generate_slug()
  end

  defp auto_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        case get_change(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end

      _ ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
