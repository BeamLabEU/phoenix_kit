defmodule PhoenixKit.Notifications.Prefs do
  @moduledoc """
  Per-user notification preferences.

  Preferences live inside the user's existing `custom_fields` JSONB column
  under the `"notification_preferences"` key — a flat `%{type_key =>
  boolean}` map. Unset keys default to the type's own `:default` flag via
  `PhoenixKit.Notifications.Types.default_for/1`, so behaviour before a
  user has opted in anywhere is unchanged.

  The filter function `user_wants?/2` is called once per notification
  fan-out from `PhoenixKit.Notifications.maybe_create_from_activity/1`. It's
  designed to fail open: any lookup error, unknown action, or malformed
  prefs map returns `true` so the system never silently drops a
  notification due to a bad row.
  """

  require Logger

  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  @prefs_key "notification_preferences"

  @doc """
  Returns the user's raw preference map.

  Accepts either a loaded `%User{}` (zero DB work) or a UUID (one lookup).
  Missing preferences return `%{}`.
  """
  @spec get(User.t() | String.t()) :: %{optional(String.t()) => boolean()}
  def get(%User{custom_fields: fields}) when is_map(fields) do
    case Map.get(fields, @prefs_key) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  def get(%User{}), do: %{}

  def get(uuid) when is_binary(uuid) do
    case Auth.get_user(uuid) do
      %User{} = user -> get(user)
      _ -> %{}
    end
  end

  @doc """
  Saves a preference map into the user's `custom_fields`.

  `prefs` is the full map of `%{type_key => boolean}` — callers should
  include entries for every rendered toggle, since the storage is a
  replace, not a merge-at-the-key level. Other custom-field keys are
  preserved (we merge at the `custom_fields` level, not inside it).
  """
  @spec update(User.t(), %{optional(String.t()) => boolean()}) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update(%User{} = user, prefs) when is_map(prefs) do
    sanitized =
      prefs
      |> Enum.reduce(%{}, fn
        {k, v}, acc when is_binary(k) -> Map.put(acc, k, !!v)
        _, acc -> acc
      end)

    merged = Map.put(user.custom_fields || %{}, @prefs_key, sanitized)
    Auth.update_user_custom_fields(user, merged)
  end

  @doc """
  Answers "would this user want a notification for this action?"

  Returns `true` on any ambiguity so new actions, unknown prefs, or a
  failing user lookup never cause a silent drop.

  Order of checks:

    1. Unknown action (no registered type) → `true` (fail open)
    2. Prefs map has the type key set to `true` or `false` → that value
    3. No entry → the type's `:default` from `Types.default_for/1`
    4. Any raise → logged as a warning and returns `true`
  """
  @spec user_wants?(String.t(), String.t()) :: boolean()
  def user_wants?(user_uuid, action) when is_binary(user_uuid) and is_binary(action) do
    do_user_wants?(user_uuid, action)
  rescue
    e ->
      Logger.warning("Notifications.Prefs.user_wants? crashed: #{inspect(e)}")
      true
  end

  defp do_user_wants?(user_uuid, action) do
    case Types.type_for_action(action) do
      nil ->
        true

      type_key ->
        prefs = get(user_uuid)

        case Map.get(prefs, type_key) do
          true -> true
          false -> false
          _ -> Types.default_for(type_key)
        end
    end
  end
end
