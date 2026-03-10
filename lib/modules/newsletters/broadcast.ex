defmodule PhoenixKit.Modules.Newsletters.Broadcast do
  @moduledoc """
  Ecto schema for newsletter broadcasts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["draft", "scheduled", "sending", "sent", "cancelled"]

  schema "phoenix_kit_newsletters_broadcasts" do
    field :subject, :string
    field :markdown_body, :string
    field :html_body, :string
    field :text_body, :string
    field :status, :string, default: "draft"
    field :scheduled_at, :utc_datetime
    field :sent_at, :utc_datetime
    field :total_recipients, :integer, default: 0
    field :sent_count, :integer, default: 0
    field :delivered_count, :integer, default: 0
    field :opened_count, :integer, default: 0
    field :bounced_count, :integer, default: 0
    field :template_uuid, UUIDv7
    field :list_uuid, UUIDv7
    field :created_by_user_uuid, UUIDv7

    belongs_to :list, PhoenixKit.Modules.Newsletters.List,
      foreign_key: :list_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    belongs_to :template, PhoenixKit.Modules.Emails.Template,
      foreign_key: :template_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    belongs_to :created_by, PhoenixKit.Users.Auth.User,
      foreign_key: :created_by_user_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    has_many :deliveries, PhoenixKit.Modules.Newsletters.Delivery,
      foreign_key: :broadcast_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  def changeset(broadcast, attrs) do
    broadcast
    |> cast(attrs, [
      :subject,
      :markdown_body,
      :html_body,
      :text_body,
      :status,
      :scheduled_at,
      :sent_at,
      :total_recipients,
      :sent_count,
      :delivered_count,
      :opened_count,
      :bounced_count,
      :template_uuid,
      :list_uuid,
      :created_by_user_uuid
    ])
    |> validate_required([:subject, :list_uuid])
    |> validate_length(:subject, min: 1, max: 998)
    |> validate_inclusion(:status, @valid_statuses)
  end

  def valid_statuses, do: @valid_statuses
end
