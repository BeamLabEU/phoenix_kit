defmodule PhoenixKit.Integrations.Events do
  @moduledoc """
  PubSub helpers for broadcasting integration changes in real-time.

  Allows multiple admins viewing the Integrations settings page to see
  changes immediately without page refresh. Also notifies other LiveViews
  that depend on integration status (e.g., document creator, AI endpoints).

  ## Topic

  All events are broadcast on the `"phoenix_kit:integrations"` topic.

  ## Events

  - `{:integration_setup_saved, provider_key, data}` — setup credentials saved (client_id/secret, API key, etc.)
  - `{:integration_connected, provider_key, data}` — OAuth flow completed, integration is now connected
  - `{:integration_disconnected, provider_key}` — integration was disconnected
  - `{:integration_validated, provider_key, :ok | {:error, reason}}` — health check completed

  ## Usage

      # Subscribe in a LiveView mount
      if connected?(socket), do: PhoenixKit.Integrations.Events.subscribe()

      # Handle events
      def handle_info({:integration_connected, provider_key, _data}, socket) do
        {:noreply, reload_data(socket)}
      end
  """

  alias PhoenixKit.PubSub.Manager

  @topic "phoenix_kit:integrations"

  @doc "Subscribe to all integration change events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Manager.subscribe(@topic)
  end

  @doc "Broadcast that an integration's setup credentials were saved."
  @spec broadcast_setup_saved(String.t(), map()) :: :ok
  def broadcast_setup_saved(provider_key, data) do
    broadcast({:integration_setup_saved, provider_key, data})
  end

  @doc "Broadcast that an OAuth integration was connected (tokens obtained)."
  @spec broadcast_connected(String.t(), map()) :: :ok
  def broadcast_connected(provider_key, data) do
    broadcast({:integration_connected, provider_key, data})
  end

  @doc "Broadcast that an integration was disconnected (tokens removed)."
  @spec broadcast_disconnected(String.t()) :: :ok
  def broadcast_disconnected(provider_key) do
    broadcast({:integration_disconnected, provider_key})
  end

  @doc "Broadcast that an integration's health check completed."
  @spec broadcast_validated(String.t(), :ok | {:error, term()}) :: :ok
  def broadcast_validated(provider_key, status) do
    broadcast({:integration_validated, provider_key, status})
  end

  @doc "Broadcast that a new named connection was added for a provider."
  @spec broadcast_connection_added(String.t(), String.t()) :: :ok
  def broadcast_connection_added(provider_key, name) do
    broadcast({:integration_connection_added, provider_key, name})
  end

  @doc "Broadcast that a named connection was removed from a provider."
  @spec broadcast_connection_removed(String.t(), String.t()) :: :ok
  def broadcast_connection_removed(provider_key, name) do
    broadcast({:integration_connection_removed, provider_key, name})
  end

  @doc "Broadcast that a named connection was renamed."
  @spec broadcast_connection_renamed(String.t(), String.t(), String.t()) :: :ok
  def broadcast_connection_renamed(provider_key, old_name, new_name) do
    broadcast({:integration_connection_renamed, provider_key, old_name, new_name})
  end

  defp broadcast(message) do
    Manager.broadcast(@topic, message)
  rescue
    _ -> :ok
  end
end
