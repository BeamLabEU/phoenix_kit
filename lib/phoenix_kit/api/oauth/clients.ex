defmodule PhoenixKit.API.OAuth.Clients do
  @moduledoc """
  The applications that may ask for access (`PhoenixKit.API.OAuth.Client`).

  `register_preregistered/1` is the one way a client enters the table so far: an administrator
  names it, with the redirect URIs it may use. Looking one up is by its row (`get/1`) or by the
  `client_id` it presents (`get_by_client_id/1`).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @max_name_length 160

  @doc """
  Registers a client an administrator named: `attrs` takes `client_id` (required, unique),
  `client_name` (cut to 160 characters), `client_uri` and `redirect_uris`.

  Returns the row, or a changeset error (a taken `client_id` is `{"has already been taken", ...}`
  on `:client_id`).
  """
  @spec register_preregistered(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def register_preregistered(attrs) when is_map(attrs) do
    %Client{kind: "preregistered"}
    |> Ecto.Changeset.cast(attrs, [:client_id, :client_name, :client_uri, :redirect_uris])
    |> Ecto.Changeset.validate_required([:client_id])
    |> Ecto.Changeset.update_change(:client_name, &String.slice(&1, 0, @max_name_length))
    |> Ecto.Changeset.validate_length(:client_id, max: 2048)
    |> Ecto.Changeset.unique_constraint(:client_id)
    |> repo().insert()
  end

  @doc "A client by its row uuid; `nil` for an unknown or malformed uuid."
  @spec get(term()) :: Client.t() | nil
  def get(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid), do: repo().get(Client, uuid), else: nil
  end

  def get(_uuid), do: nil

  @doc "A client by the `client_id` it presents; `nil` when unknown."
  @spec get_by_client_id(term()) :: Client.t() | nil
  def get_by_client_id(client_id) when is_binary(client_id),
    do: repo().one(from(c in Client, where: c.client_id == ^client_id))

  def get_by_client_id(_client_id), do: nil

  defp repo, do: RepoHelper.repo()
end
