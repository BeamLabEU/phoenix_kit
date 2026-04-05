defmodule PhoenixKitWeb.Live.Settings.Integrations do
  @moduledoc """
  Integrations list page — shows all configured service connections.

  Each connection is displayed as a card with status, connected account info,
  and quick actions (disconnect, test). An "Add Integration" button links to
  the form page for creating new connections.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

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

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_connections(socket) do
    used_by = Providers.used_by_modules()

    connections =
      Providers.all()
      |> Enum.flat_map(fn provider ->
        Integrations.list_connections(provider.key)
        |> Enum.map(fn %{uuid: uuid, name: name, data: data} ->
          full_key = "#{provider.key}:#{name}"

          %{
            provider: provider,
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
    do_validate_connection(provider_key)
  rescue
    e ->
      Logger.error(
        "[Integrations] validate_connection crashed for #{provider_key}: #{Exception.message(e)}"
      )

      {:error, "Validation failed unexpectedly"}
  end

  defp do_validate_connection(provider_key) do
    with {:ok, data} <- Integrations.get_credentials(provider_key),
         provider when not is_nil(provider) <- Providers.get(provider_key) do
      validate_by_auth_type(provider, data)
    else
      {:error, _} -> {:error, "Not configured"}
      nil -> {:error, "Unknown provider"}
    end
  end

  defp validate_by_auth_type(%{auth_type: :oauth2} = provider, data) do
    token = data["access_token"]
    config = provider.oauth_config || %{}
    userinfo_url = config[:userinfo_url] || config["userinfo_url"]

    cond do
      not (is_binary(token) and token != "") -> {:error, "No access token"}
      is_nil(userinfo_url) -> :ok
      true -> check_http(userinfo_url, [{"authorization", "Bearer #{token}"}])
    end
  end

  defp validate_by_auth_type(%{auth_type: :api_key} = provider, data) do
    api_key = data["api_key"]

    cond do
      not (is_binary(api_key) and api_key != "") ->
        {:error, "No API key configured"}

      Map.has_key?(provider, :validation) and provider.validation != nil ->
        # Use provider's validation endpoint to actually test the key
        v = provider.validation
        headers = [{v.auth_header, "#{v.auth_prefix}#{api_key}"}]
        check_http(v.url, headers)

      true ->
        :ok
    end
  end

  defp validate_by_auth_type(%{auth_type: :bot_token}, data) do
    token = data["bot_token"]

    if is_binary(token) and token != "" do
      case Req.get("https://api.telegram.org/bot#{token}/getMe") do
        {:ok, %{status: 200, body: %{"ok" => true}}} -> :ok
        {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      {:error, "No bot token configured"}
    end
  end

  defp validate_by_auth_type(_, _data), do: :ok

  defp check_http(url, headers) do
    case Req.get(url, headers: headers) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, gettext("Invalid credentials")}
      {:ok, %{status: 403}} -> {:error, gettext("Access denied")}
      {:ok, %{status: status}} -> {:error, gettext("Service error %{status}", status: status)}
      {:error, _reason} -> {:error, gettext("Could not reach the service")}
    end
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
