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
    |> repo().insert(
      on_conflict: {:replace, [:x, :y, :w, :h, :updated_at]},
      conflict_target: [:user_uuid],
      returning: true
    )
  end

  import Ecto.Query

  def delete_layout(user_uuid, uuid) do
    from(l in Layout,
      where:
        l.user_uuid == ^user_uuid and
          l.uuid == ^uuid
    )
    |> repo().delete_all()
  end

  def add_widget(user, uuid, attrs \\ %{}) do
    repo().insert(%Layout{
      user_uuid: user.uuid,
      uuid: uuid,
      x: Map.get(attrs, :x, 0),
      y: Map.get(attrs, :y, 0),
      w: Map.get(attrs, :w, 3),
      h: Map.get(attrs, :h, 2),
    })
  end

  def save_grid(user, layouts) do
    Repo.insert_all(
      Layout,
      layouts,
      on_conflict: {:replace, [:x, :y, :w, :h, :updated_at]},
      conflict_target: [:user_uuid, :widget_uuid]
    )

    :ok
  end

  def remove_widget(user, widget_uuid) do
    Repo.transaction(fn ->
      from(l in PhoenixKit.DashboardLayout,
        where: l.user_uuid == ^user.uuid and l.widget_uuid == ^widget_uuid
      )
      |> Repo.delete_all()
    end)
  end
end
