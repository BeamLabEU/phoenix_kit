defmodule PhoenixKitWeb.Live.Settings.Integrations do
  @moduledoc """
  Integrations list page — shows all configured service connections.

  Each connection is displayed as a card with status, connected account info,
  and quick actions (disconnect, test). An "Add Integration" button links to
  the form page for creating new connections.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Events
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:page_title, gettext("Integrations"))
      |> assign(:project_title, project_title)
      |> assign(:current_path, get_current_path(socket.assigns.current_locale_base))
      |> load_connections()
      |> assign(:validating, nil)

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  def handle_event("disconnect", %{"provider" => provider_key}, socket) do
    Integrations.disconnect(provider_key)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Disconnected"))
     |> load_connections()}
  end

  def handle_event("validate_connection", %{"provider" => provider_key}, socket) do
    send(self(), {:do_validate, provider_key})
    {:noreply, assign(socket, :validating, provider_key)}
  end

  def handle_event("remove_connection", %{"provider" => provider_key, "name" => name}, socket) do
    case Integrations.remove_connection(provider_key, name) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Connection removed"))
         |> load_connections()}

      {:error, :cannot_remove_default} ->
        {:noreply, put_flash(socket, :error, gettext("Cannot remove the default connection"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove connection"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Async validation
  # ---------------------------------------------------------------------------

  def handle_info({:do_validate, provider_key}, socket) do
    result = validate_connection(provider_key)

    case Integrations.get_integration(provider_key) do
      {:ok, data} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        updated =
          case result do
            :ok ->
              Map.merge(data, %{
                "last_validated_at" => now,
                "validation_status" => "ok",
                "status" => "connected"
              })

            {:error, reason} ->
              Map.merge(data, %{
                "last_validated_at" => now,
                "validation_status" => "error: #{reason}",
                "status" => "error"
              })
          end

        Integrations.save_setup(provider_key, updated)

      _ ->
        :ok
    end

    Events.broadcast_validated(provider_key, result)

    {:noreply,
     socket
     |> assign(:validating, nil)
     |> load_connections()}
  end

  # ---------------------------------------------------------------------------
  # PubSub handlers
  # ---------------------------------------------------------------------------

  def handle_info({:integration_setup_saved, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connected, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_disconnected, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_validated, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connection_added, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connection_removed, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  # Catch-all to prevent crashes from unexpected messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_connections(socket) do
    used_by = Providers.used_by_modules()
    providers = Providers.all()
    provider_keys = Enum.map(providers, & &1.key)
    providers_by_key = Map.new(providers, &{&1.key, &1})

    # Single query for all providers instead of N+1
    all_connections = Integrations.load_all_connections(provider_keys)

    connections =
      Enum.flat_map(providers, fn provider ->
        Map.get(all_connections, provider.key, [])
        |> Enum.map(fn %{uuid: uuid, name: name, data: data} ->
          full_key = "#{provider.key}:#{name}"

          %{
            provider: providers_by_key[provider.key],
            uuid: uuid,
            name: name,
            full_key: full_key,
            data: data,
            used_by: Map.get(used_by, provider.key, [])
          }
        end)
      end)

    assign(socket, :connections, connections)
  end

  defp validate_connection(provider_key) do
    Integrations.validate_connection(provider_key)
  end

  defp get_current_path(locale) do
    Routes.path("/admin/settings/integrations", locale: locale)
  end

  defp integration_status_badge("connected"), do: {"badge-success", gettext("Connected")}
  defp integration_status_badge("configured"), do: {"badge-warning", gettext("Not tested")}
  defp integration_status_badge("disconnected"), do: {"badge-ghost", gettext("Not connected")}
  defp integration_status_badge("error"), do: {"badge-error", gettext("Error")}
  defp integration_status_badge(_), do: {"badge-ghost", gettext("Not configured")}
end
