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
  Replaces the user's preference map with `prefs` (a `%{key => boolean}` map).

  Full replace of the `notification_preferences` value — callers must include
  every key they intend to keep, so this is for cases that own the whole map
  (pause/resume, which pass a computed full snapshot). For a partial write that
  must NOT drop keys it doesn't render, use `merge/2`. Other `custom_fields`
  keys are preserved either way — the write touches the
  `notification_preferences` key alone (see `write/2`).

  Returns `{:error, :not_found}` if the user row was deleted concurrently.
  """
  @spec update(User.t(), %{optional(String.t()) => boolean()}) ::
          {:ok, User.t()} | {:error, :not_found}
  def update(%User{} = user, prefs) when is_map(prefs) do
    write(user, sanitize(prefs))
  end

  @doc """
  Merge-preserving write: reads the user's current preferences and overlays only
  the keys in `prefs`, so keys this caller doesn't render survive.

  This is the safe write for any partial surface (the settings page renders all
  keys but uses this anyway; the deprecated dashboard settings component renders
  only base keys and MUST use this or it would drop every sub-type entry). Using
  it by construction closes the whole "full-replace caller drops keys" class.

  Note the overlay is computed from the passed `user`'s prefs, so a concurrent
  write to the *same* `notification_preferences` key can still be lost; only
  sibling `custom_fields` keys are protected. Callers that must not lose one
  should pass a freshly-loaded user.

  Returns `{:error, :not_found}` if the user row was deleted concurrently.
  """
  @spec merge(User.t(), %{optional(String.t()) => boolean()}) ::
          {:ok, User.t()} | {:error, :not_found}
  def merge(%User{} = user, prefs) when is_map(prefs) do
    merged =
      prefs
      |> sanitize()
      |> then(&Map.merge(get(user), &1))

    write(user, merged)
  end

  # Coerce to `%{binary_key => boolean}` via the single write-side helper.
  defp sanitize(prefs) do
    Enum.reduce(prefs, %{}, fn
      {k, v}, acc when is_binary(k) -> put_pref(acc, k, v)
      _, acc -> acc
    end)
  end

  # Writes ONLY the `notification_preferences` key, at the database level.
  # The historical whole-map replace (`Map.put(user.custom_fields, ...)` +
  # `update_user_custom_fields/3`) rebuilt the column from whatever snapshot
  # the caller happened to hold — and both callers hold a long-lived one (the
  # settings LiveView loads the user in `mount/3`, the settings component in
  # its assigns). Every sibling key in that column is now written atomically
  # (`ChannelConfig.put/delete`, `update_user_locale_preference`), so a save
  # here would silently roll back a Telegram connect or a locale switch that
  # landed after the page was opened. `ensure_definitions: false` because this
  # is an internal blob, not an admin-managed custom field — same reason
  # `ChannelConfig.put/3` passes it.
  defp write(%User{} = user, prefs_map) do
    Auth.merge_user_custom_fields(user, %{@prefs_key => prefs_map}, ensure_definitions: false)
  end

  # ── The single-point per-key value seam ───────────────────────────────
  # These two functions are the ONLY places a stored per-key value is read or
  # written. When per-key values later become a richer map (e.g. `%{"enabled"
  # => bool, "channels" => %{...}, "digest" => ...}` for the deferred
  # channel/digest work), only these change — resolution and storage shape stay
  # put. (Note: this is a PARTIAL seam — the settings form-building + full-replace
  # `update/2` path also assume a bool, so a shape change touches those too.)

  # Is a single key enabled? true/false stored value, else the key's own default.
  @spec pref_enabled?(map(), String.t()) :: boolean()
  defp pref_enabled?(prefs, key) do
    case Map.get(prefs, key) do
      true -> true
      false -> false
      _ -> Types.default_for(key)
    end
  end

  @spec put_pref(map(), String.t(), term()) :: map()
  defp put_pref(prefs, key, enabled), do: Map.put(prefs, key, !!enabled)

  @doc """
  Answers "would this user want a notification for this action?"

  Resolves the action to its most-specific preference key (`Types.key_for_action/1`)
  and applies the master switch: a base key is checked alone; a dotted sub key is
  wanted only when BOTH its base master AND the sub itself are enabled. Fail-open
  on every ambiguity — unknown action, missing pref (→ key default), or any raise
  → `true` — so a notification is never silently dropped by a bad row.
  """
  @spec user_wants?(String.t() | User.t(), String.t()) :: boolean()
  def user_wants?(user_uuid, action) when is_binary(user_uuid) and is_binary(action) do
    do_user_wants?(user_uuid, action)
  rescue
    e ->
      Logger.warning("Notifications.Prefs.user_wants? crashed: #{inspect(e)}")
      true
  end

  # Struct clause — lets a caller that already loaded the user (e.g. the
  # delivery choke point, which also needs the user for channel routing) avoid a
  # second load. `get/1` accepts a `%User{}` directly.
  def user_wants?(%User{} = user, action) when is_binary(action) do
    do_user_wants?(user, action)
  rescue
    e ->
      Logger.warning("Notifications.Prefs.user_wants? crashed: #{inspect(e)}")
      true
  end

  defp do_user_wants?(user_uuid, action) do
    case Types.key_for_action(action) do
      nil -> true
      key -> wants_key?(get(user_uuid), key)
    end
  end

  # Master-switch resolution shared by user_wants?/2 and user_wants_type?/2.
  # Base key → itself; dotted sub key → base master AND the sub.
  @spec wants_key?(map(), String.t()) :: boolean()
  defp wants_key?(prefs, key) do
    case Types.parent_type_key(key) do
      nil -> pref_enabled?(prefs, key)
      base -> pref_enabled?(prefs, base) and pref_enabled?(prefs, key)
    end
  end

  @doc """
  Like `user_wants?/2` but checks a preference **key** directly — a base type key
  (`"account"`, `"posts"`) or a dotted sub key (`"comments.replies"`). Used by
  `Notifications.create/1` when a caller passes `:type`. Applies the same master
  switch and the same fail-open contract (unknown key → its default; crash → `true`).
  """
  @spec user_wants_type?(String.t() | User.t(), String.t()) :: boolean()
  def user_wants_type?(user_uuid, type_key) when is_binary(user_uuid) and is_binary(type_key) do
    wants_key?(get(user_uuid), type_key)
  rescue
    e ->
      Logger.warning("Notifications.Prefs.user_wants_type? crashed: #{inspect(e)}")
      true
  end

  # Struct clause — lets a caller that already loaded the user (e.g. the digest
  # sweep, iterating many types for one user) avoid a reload per type.
  def user_wants_type?(%User{} = user, type_key) when is_binary(type_key) do
    wants_key?(get(user), type_key)
  rescue
    e ->
      Logger.warning("Notifications.Prefs.user_wants_type? crashed: #{inspect(e)}")
      true
  end
end
