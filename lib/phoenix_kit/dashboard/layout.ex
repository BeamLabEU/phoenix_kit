defmodule PhoenixKit.Dashboard.Layout do
  use Ecto.Schema

  schema "dashboard_layouts" do
    field :widget_uuid, :binary_id
    field :x, :integer
    field :y, :integer
    field :w, :integer
    field :h, :integer
    field :enabled, :boolean, default: false

    belongs_to :user_uuid, PhoenixKit.Users.Auth.User, type: :binary_id
  end
end
