defmodule PhoenixKit.Notifications.ChannelConfig do
  @moduledoc """
  Per-user configuration for notification delivery channels, stored on
  `users.custom_fields` (JSONB — no migration).

  **One top-level key per channel** — `"notification_channel:<key>"` — so that
  `Auth.merge_user_custom_fields/3`'s atomic top-level `custom_fields || ...`
  merge updates a channel without clobbering another channel or the unrelated
  `notification_preferences` map. (A single shared `"notification_channels"`
  object would be replaced wholesale by that shallow merge, losing concurrent
  writes.)

  The stored map is opaque to the core except two reserved keys the routing
  layer reads:

    * `"enabled"` — channel master switch (default **on** once configured).
    * `"types"` — `%{type_key => boolean}`, per-type opt-in. Absent/unknown ⇒
      **off** (external routing is fail-closed, unlike the fail-open in-app inbox).

  Channel-specific keys (e.g. Telegram's `"connection_uuid"` / `"chat_id"` /
  `"status"`) live in the same map and are the channel's business.

  All reads/writes take a loaded `%User{}` (the caller already has it — the
  settings page has the current user, the delivery worker loads the recipient).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  @prefix "notification_channel:"

  @doc "The `custom_fields` key a channel's config is stored under."
  @spec config_key(String.t()) :: String.t()
  def config_key(channel_key) when is_binary(channel_key), do: @prefix <> channel_key

  @doc "Every channel config on the user, as `%{channel_key => config_map}`."
  @spec all_for(map()) :: %{optional(String.t()) => map()}
  def all_for(user) do
    (user.custom_fields || %{})
    |> Enum.flat_map(fn
      {@prefix <> channel_key, %{} = config} -> [{channel_key, config}]
      _ -> []
    end)
    |> Map.new()
  end

  @doc "The config map for one channel (`%{}` if unset)."
  @spec for_channel(map(), String.t()) :: map()
  def for_channel(user, channel_key) when is_binary(channel_key) do
    case (user.custom_fields || %{})[config_key(channel_key)] do
      %{} = config -> config
      _ -> %{}
    end
  end

  @doc """
  Writes a channel's config, replacing that channel's key atomically and leaving
  every other `custom_fields` key untouched. `ensure_definitions: false` because
  this is an internal routing blob, not a user-facing custom-field definition.
  """
  @spec put(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(user, channel_key, %{} = config) when is_binary(channel_key) do
    Auth.merge_user_custom_fields(user, %{config_key(channel_key) => config},
      ensure_definitions: false
    )
  end

  @doc """
  Read-modify-write a channel's config with `fun`, on the row as it stands: the
  config is read under a row lock, not off the passed `user`, which only names
  the account. A struct from earlier (a page's assigns, a worker's load before a
  send) would write back keys removed since, and a chat dropped from the Telegram
  channel is a revoked credential (`PhoenixKit.Integrations.Telegram.Linking`).

  Returns `{:error, :not_found}` when the row is gone.
  """
  @spec update(map(), String.t(), (map() -> map())) :: {:ok, map()} | {:error, term()}
  def update(user, channel_key, fun) when is_binary(channel_key) and is_function(fun, 1) do
    repo = RepoHelper.repo()

    locked =
      from(u in User,
        where: u.uuid == ^user.uuid,
        select: u.custom_fields,
        lock: "FOR NO KEY UPDATE"
      )

    result =
      repo.transaction(fn ->
        case repo.all(locked) do
          [fields] ->
            put(user, channel_key, fun.(for_channel(%{custom_fields: fields}, channel_key)))

          [] ->
            {:error, :not_found}
        end
      end)

    case result do
      {:ok, written} -> written
      {:error, _reason} = error -> error
    end
  end

  @doc "Removes a channel's config entirely (e.g. user disconnects it)."
  @spec delete(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete(user, channel_key) when is_binary(channel_key) do
    Auth.delete_user_custom_field(user, config_key(channel_key))
  end

  # --- Reserved-key readers (routing) ---------------------------------------

  @doc "Channel master switch — defaults ON once the channel has any config."
  @spec enabled?(map()) :: boolean()
  def enabled?(config) when is_map(config), do: Map.get(config, "enabled", true) == true

  @doc "Whether `type_key` is routed to this channel — fail-CLOSED (default off)."
  @spec type_enabled?(map(), String.t()) :: boolean()
  def type_enabled?(config, type_key) when is_map(config) and is_binary(type_key) do
    case config["types"] do
      %{} = types -> types[type_key] == true
      _ -> false
    end
  end

  # --- Aggregation cadence --------------------------------------------------

  @cadences ~w(immediate hourly 12h daily weekly)

  @doc "The valid delivery cadences, in escalating order."
  @spec cadences() :: [String.t()]
  def cadences, do: @cadences

  @doc """
  Delivery cadence for `type_key` on this channel (from the aggregation popup) —
  `"immediate"` (default, send each as it happens) or a digest window
  (`"hourly"` / `"12h"` / `"daily"` / `"weekly"`, batched into one summary).
  """
  @spec cadence(map(), String.t()) :: String.t()
  def cadence(config, type_key) when is_map(config) and is_binary(type_key) do
    case get_in(config, ["cadences", type_key]) do
      c when c in @cadences -> c
      _ -> "immediate"
    end
  end

  @doc "True unless `type_key` is routed on a digest (non-immediate) cadence."
  @spec immediate?(map(), String.t()) :: boolean()
  def immediate?(config, type_key), do: cadence(config, type_key) == "immediate"
end
