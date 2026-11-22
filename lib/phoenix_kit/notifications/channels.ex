defmodule PhoenixKit.Notifications.Channels do
  @moduledoc """
  Registry of notification delivery channels.

  `list/0` returns core channels first, then channels contributed by feature
  modules via `PhoenixKit.Module`'s `notification_channels/0` — the same
  core-first, dedupe-by-key, rescue-guarded merge that
  `PhoenixKit.Notifications.Types.list/0` uses for types. A module channel whose
  `key/0` collides with a core (or already-seen) key is dropped with a warning,
  so core always wins.

  Every entry is a module implementing `PhoenixKit.Notifications.Channel`.
  """

  require Logger

  alias PhoenixKit.ModuleRegistry

  # Core channels ship here. Keep alphabetical-by-key for stable UI ordering.
  @core_channels [
    PhoenixKit.Notifications.Channels.Email,
    PhoenixKit.Notifications.Channels.Push,
    PhoenixKit.Notifications.Channels.Telegram
  ]

  @doc """
  All registered channel modules — core first, then valid module-contributed
  ones, with duplicate keys rejected (first claim wins).
  """
  @spec list() :: [module()]
  def list do
    Enum.reduce(@core_channels ++ external_channels(), {[], MapSet.new()}, fn mod, {acc, seen} ->
      case safe_key(mod) do
        nil ->
          {acc, seen}

        key ->
          if MapSet.member?(seen, key) do
            Logger.warning(
              "[Notifications.Channels] duplicate channel key #{inspect(key)} from #{inspect(mod)} ignored"
            )

            {acc, seen}
          else
            {[mod | acc], MapSet.put(seen, key)}
          end
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "The channel module for `key`, or `nil`."
  @spec get(String.t()) :: module() | nil
  def get(key) when is_binary(key) do
    Enum.find(list(), fn mod -> safe_key(mod) == key end)
  end

  @doc "All channel keys, in `list/0` order."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(list(), & &1.key())

  # Collect `notification_channels/0` from every registered module, rescue-guarded
  # per module so one bad callback can't take down the whole registry.
  defp external_channels do
    ModuleRegistry.all_modules()
    |> Enum.flat_map(fn mod ->
      # `Code.ensure_loaded?/1` first — `function_exported?/3` answers false for
      # a module that simply hasn't been loaded yet (the norm under a release's
      # lazy loading), which would silently drop that module's channels. Mirrors
      # `PhoenixKit.Notifications.Types.external_types/0`.
      if Code.ensure_loaded?(mod) and function_exported?(mod, :notification_channels, 0) do
        try do
          mod.notification_channels() |> List.wrap()
        rescue
          e ->
            Logger.warning(
              "[Notifications.Channels] #{inspect(mod)}.notification_channels/0 failed: #{Exception.message(e)}"
            )

            []
        end
      else
        []
      end
    end)
  end

  # A channel module must load and answer key/0 with a binary, or it's skipped.
  defp safe_key(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :key, 0) do
      case mod.key() do
        key when is_binary(key) and key != "" -> key
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end
end
