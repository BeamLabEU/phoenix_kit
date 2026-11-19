defmodule PhoenixKit.API.OAuth.Client do
  @moduledoc """
  An application that may ask for access to the MCP endpoint (table
  `phoenix_kit_api_oauth_clients`).

    * `client_id` - unique: the URL of a metadata document, an id issued at registration, or
      one an admin entered.
    * `kind` - `"cimd"`, `"dcr"` or `"preregistered"`: how the client became known.
    * `redirect_uris` - what the client declared; a redirect is accepted only when it is on
      this list (`PhoenixKit.API.OAuth.Clients`).
    * `metadata_fetched_at`, `metadata_expires_at` - the metadata cache of a `"cimd"` client.
    * `last_seen_at` - the last authorization request, so a registered client nobody uses can
      be removed.

  This module is the schema only.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @kinds ~w(cimd dcr preregistered)

  schema "phoenix_kit_api_oauth_clients" do
    field :client_id, :string
    field :kind, :string
    field :client_name, :string
    field :client_uri, :string
    field :redirect_uris, {:array, :string}, default: []
    field :metadata_fetched_at, :utc_datetime
    field :metadata_expires_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "The kinds a client can be."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds
end
