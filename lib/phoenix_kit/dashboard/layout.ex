defmodule PhoenixKit.Dashboard.Layout do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7
  schema "phoenix_kit_dashboard_layouts" do
    field :x, :integer
    field :y, :integer
    field :w, :integer
    field :h, :integer
    field :enabled, :boolean, default: false

    belongs_to :user_uuid, PhoenixKit.Users.Auth.User
    timestamps(type: :utc_datetime)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:user_uuid, :uuid])
    |> validate_required([:user_uuid, :uuid])
    |> unique_constraint(
      [:user_uuid, :uuid],
      name: :phoenix_kit_dashboard_layouts_unique_index
    )
  end
end
