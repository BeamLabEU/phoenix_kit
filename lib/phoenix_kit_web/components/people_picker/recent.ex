defmodule PhoenixKitWeb.Components.PeoplePicker.Recent do
  @moduledoc """
  A viewer's recent picks for the people picker, kept on their own account
  in `custom_fields["people_picker_recent"]` — `%{list_key => [%{"kind",
  "uuid"}]}`, newest first, at most #{20}. A source that has no store of
  its own uses it (`UserSource` does); `list_key` keeps two pickers' lists
  apart.

  Written with `Auth.merge_user_custom_fields/3` (only this key, no
  broadcast: a pick must not refresh the viewer's open pages) and never
  raises into the picker.
  """

  require Logger

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  @field "people_picker_recent"
  @cap 20

  @doc "The viewer's remembered keys for `list_key`, newest first."
  @spec keys(map(), String.t()) :: [{String.t(), String.t()}]
  def keys(%{viewer_uuid: uuid}, list_key) when is_binary(uuid) and is_binary(list_key) do
    case Auth.get_user(uuid) do
      %User{custom_fields: %{@field => %{} = lists}} ->
        for %{"kind" => kind, "uuid" => uuid} <- List.wrap(lists[list_key]),
            is_binary(kind) and is_binary(uuid),
            do: {kind, uuid}

      _ ->
        []
    end
  rescue
    _ -> []
  end

  def keys(_ctx, _list_key), do: []

  @doc "Puts `key` first in the viewer's `list_key` list."
  @spec put(map(), String.t(), {String.t(), String.t()}) :: :ok
  def put(%{viewer_uuid: uuid}, list_key, {kind, id})
      when is_binary(uuid) and is_binary(list_key) and is_binary(kind) and is_binary(id) do
    case Auth.get_user(uuid) do
      %User{} = user ->
        lists =
          case user.custom_fields do
            %{@field => %{} = lists} -> lists
            _ -> %{}
          end

        entry = %{"kind" => kind, "uuid" => id}

        list =
          [entry | Enum.reject(List.wrap(lists[list_key]), &(&1 == entry))] |> Enum.take(@cap)

        _ =
          Auth.merge_user_custom_fields(user, %{@field => Map.put(lists, list_key, list)},
            ensure_definitions: false,
            broadcast: false
          )

        :ok

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("[PeoplePicker] remembering a pick failed: #{inspect(e.__struct__)}")
      :ok
  end

  def put(_ctx, _list_key, _key), do: :ok
end
