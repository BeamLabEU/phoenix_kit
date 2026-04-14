defmodule PhoenixKit.Dashboard.Widget.Layout do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7
  schema "phoenix_kit_dashboard_widget_layouts" do
    field :x, :integer
    field :y, :integer
    field :w, :integer
    field :h, :integer
    field :enabled, :boolean, default: false

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7
  end

  alias PhoenixKit.Dashboard.Widget.Layout

  defp repo, do: PhoenixKit.RepoHelper.repo()

  def changeset(layout, attrs) do
    layout
    |> cast(attrs, [:x, :y, :w, :h, :user_uuid])
    |> validate_required([:x, :y, :w, :h, :user_uuid])
    |> unique_constraint(:user_uuid, name: :dashboard_layouts_user_uuid_index)
  end

  def upsert_layout(user_uuid, attrs) do
    attrs = Map.put(attrs, :user_uuid, user_uuid)

    %Layout{}
    |> Layout.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:x, :y, :w, :h, :updated_at]},
      conflict_target: [:user_uuid],
      returning: true
    )
  end

  import Ecto.Query

  def delete_layout(user_uuid, widget_uuid) do
    from(l in Layout,
      where:
        l.user_uuid == ^user_uuid and
          l.uuid == ^widget_uuid
    )
    |> Repo.delete_all()
  end
end
