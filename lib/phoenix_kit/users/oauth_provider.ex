defmodule PhoenixKit.Users.OAuthProvider do
  @moduledoc """
  OAuth Provider schema for external authentication providers.

  This schema stores OAuth authentication provider information for users,
  allowing them to authenticate through services like Google, Apple, GitHub, etc.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User

  @supported_providers ~w(google apple github facebook twitter microsoft)

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_user_oauth_providers" do
    field :id, :integer, read_after_writes: true
    field :user_id, :integer
    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7

    field :provider, :string
    field :provider_uid, :string
    field :provider_email, :string
    field :access_token, :string
    field :refresh_token, :string
    field :token_expires_at, :utc_datetime_usec
    field :raw_data, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating or updating an OAuth provider association.
  """
  def changeset(oauth_provider, attrs) do
    oauth_provider
    |> cast(attrs, [
      :user_id,
      :user_uuid,
      :provider,
      :provider_uid,
      :provider_email,
      :access_token,
      :refresh_token,
      :token_expires_at,
      :raw_data
    ])
    |> validate_required([:user_uuid, :provider, :provider_uid])
    |> validate_provider()
    |> validate_length(:provider_uid, min: 1, max: 255)
    |> foreign_key_constraint(:user_uuid)
    |> unique_constraint([:user_uuid, :provider],
      name: :phoenix_kit_oauth_providers_user_uuid_provider_idx
    )
    |> unique_constraint([:provider, :provider_uid],
      name: :phoenix_kit_oauth_providers_provider_uid_idx
    )
  end

  def supported_providers, do: @supported_providers

  defp validate_provider(changeset) do
    validate_change(changeset, :provider, fn :provider, provider ->
      if provider in @supported_providers do
        []
      else
        [provider: "must be one of: #{Enum.join(@supported_providers, ", ")}"]
      end
    end)
  end
end
