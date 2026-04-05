defmodule PhoenixKitWeb.Live.Settings.IntegrationForm do
  @moduledoc """
  Form page for adding or editing an integration connection.

  - `:new` action — shows provider picker, then setup form with instructions
  - `:edit` action — shows the setup form for an existing connection
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
      |> assign(:page_title, gettext("Add Integration"))
      |> assign(:project_title, project_title)
      |> assign(:current_path, Routes.path("/admin/settings/integrations"))
      |> assign(:providers, Providers.all())
      |> assign(:selected_provider, nil)
      |> assign(:provider, nil)
      |> assign(:name, nil)
      |> assign(:data, %{})
      |> assign(:success, nil)
      |> assign(:error, nil)
      |> assign(:new_name, "")
      |> assign(:testing, false)

    {:ok, socket}
  end

  def handle_params(params, url, socket) do
    # Store the base redirect URI from the actual browser URL so that
    # OAuth callbacks use the same origin Google will redirect to.
    redirect_uri =
      case URI.parse(url) do
        %{scheme: scheme, authority: authority, path: path}
        when is_binary(scheme) and is_binary(authority) ->
          "#{scheme}://#{authority}#{path}"

        _ ->
          nil
      end

    socket = assign(socket, :redirect_uri, redirect_uri)
    socket = apply_action(socket, socket.assigns.live_action, params)
    {:noreply, socket}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, gettext("Add Integration"))
    |> assign(:selected_provider, nil)
    |> assign(:provider, nil)
    |> assign(:name, nil)
    |> assign(:data, %{})
  end

  defp apply_action(socket, :edit, %{"provider" => provider_key, "name" => name} = params) do
    provider = Providers.get(provider_key)
    full_key = "#{provider_key}:#{name}"

    data =
      case Integrations.get_integration(full_key) do
        {:ok, d} -> d
        _ -> %{}
      end

    socket =
      socket
      |> assign(:page_title, gettext("Edit Integration"))
      |> assign(:selected_provider, provider_key)
      |> assign(:provider, provider)
      |> assign(:name, name)
      |> assign(:data, data)

    # Handle OAuth callback (code in query params).
    # Only process during live WebSocket connection — during dead (static) render
    # the internal URI may differ from the external URL (e.g. http vs https behind
    # a reverse proxy), causing redirect_uri mismatch with Google's token endpoint.
    if connected?(socket) do
      case params do
        %{"code" => code} when is_binary(code) and code != "" ->
          handle_oauth_callback(full_key, code, socket)

        _ ->
          socket
      end
    else
      socket
    end
  end

  # ---------------------------------------------------------------------------
  # Events — provider selection (new mode)
  # ---------------------------------------------------------------------------

  def handle_event("select_provider", %{"provider" => provider_key}, socket) do
    provider = Providers.get(provider_key)

    {:noreply,
     socket
     |> assign(:selected_provider, provider_key)
     |> assign(:provider, provider)
     |> assign(:new_name, "")}
  end

  def handle_event("back_to_providers", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_provider, nil)
     |> assign(:provider, nil)}
  end

  # ---------------------------------------------------------------------------
  # Events — create new connection
  # ---------------------------------------------------------------------------

  def handle_event("create_connection", %{"name" => name} = params, socket) do
    provider_key = socket.assigns.selected_provider
    name = String.trim(name)

    # Default to "default" if empty
    name = if name == "", do: "default", else: name

    case Integrations.add_connection(provider_key, name) do
      {:ok, _} ->
        save_and_redirect(provider_key, name, params, socket)

      {:error, :already_exists} ->
        save_and_redirect(provider_key, name, params, socket)

      {:error, :empty_name} ->
        {:noreply, assign(socket, :error, gettext("Please enter a connection name."))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — save setup credentials (edit mode)
  # ---------------------------------------------------------------------------

  def handle_event("save_setup", params, socket) do
    provider_key = socket.assigns.selected_provider
    name = socket.assigns.name
    save_setup_fields(provider_key, name, params, socket)
  end

  # ---------------------------------------------------------------------------
  # Events — OAuth disconnect
  # ---------------------------------------------------------------------------

  def handle_event("disconnect_account", _params, socket) do
    provider_key = socket.assigns.selected_provider
    name = socket.assigns.name
    full_key = "#{provider_key}:#{name}"

    # Keep the setup credentials (client_id/secret) but remove tokens
    Integrations.disconnect(full_key)

    # Reload data
    data =
      case Integrations.get_integration(full_key) do
        {:ok, d} -> d
        _ -> %{}
      end

    {:noreply,
     socket
     |> assign(:data, data)
     |> assign(:success, gettext("Account disconnected"))
     |> assign(:error, nil)}
  end

  # ---------------------------------------------------------------------------
  # Events — OAuth connect
  # ---------------------------------------------------------------------------

  def handle_event("connect_oauth", _params, socket) do
    provider_key = socket.assigns.selected_provider
    name = socket.assigns.name || "default"
    full_key = "#{provider_key}:#{name}"

    redirect_uri =
      socket.assigns[:redirect_uri] ||
        build_redirect_uri(socket, provider_key, name)

    case Integrations.authorization_url(full_key, redirect_uri) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, :client_id_not_configured} ->
        {:noreply, assign(socket, :error, gettext("Please save your Client ID first"))}

      {:error, _} ->
        {:noreply, assign(socket, :error, gettext("Failed to build authorization URL"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — Test connection
  # ---------------------------------------------------------------------------

  def handle_event("test_connection", _params, socket) do
    send(self(), :do_test_connection)
    {:noreply, assign(socket, :testing, true)}
  end

  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, success: nil, error: nil)}
  end

  # ---------------------------------------------------------------------------
  # Async handlers
  # ---------------------------------------------------------------------------

  def handle_info(:do_test_connection, socket) do
    provider_key = socket.assigns.selected_provider
    name = socket.assigns.name
    full_key = "#{provider_key}:#{name}"
    provider = socket.assigns.provider

    result = run_connection_test(provider, full_key)
    save_validation_result(full_key, result)
    Events.broadcast_validated(full_key, result)

    data =
      case Integrations.get_integration(full_key) do
        {:ok, d} -> d
        _ -> socket.assigns.data
      end

    socket =
      case result do
        :ok ->
          socket
          |> assign(:data, data)
          |> assign(:success, gettext("Connection verified"))
          |> assign(:error, nil)

        {:error, reason} ->
          socket
          |> assign(:data, data)
          |> assign(:error, "#{gettext("Test failed")}: #{reason}")
          |> assign(:success, nil)
      end

    {:noreply, assign(socket, :testing, false)}
  end

  # PubSub: reload data when integrations change
  def handle_info({event, _, _}, socket)
      when event in [
             :integration_setup_saved,
             :integration_connected,
             :integration_connection_added,
             :integration_validated
           ],
      do: {:noreply, reload_data(socket)}

  def handle_info({event, _}, socket)
      when event in [:integration_disconnected, :integration_connection_removed],
      do: {:noreply, reload_data(socket)}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp handle_oauth_callback(full_key, code, socket) do
    # Use the actual browser URL as redirect_uri (must match what was sent to Google)
    redirect_uri =
      socket.assigns[:redirect_uri] ||
        build_redirect_uri(socket, socket.assigns.selected_provider, socket.assigns.name)

    case Integrations.exchange_code(full_key, code, redirect_uri) do
      {:ok, _data} ->
        # Redirect to clean URL (strip ?code=... params) to prevent re-exchange
        clean_path =
          Routes.path(
            "/admin/settings/integrations/#{socket.assigns.selected_provider}/#{socket.assigns.name}"
          )

        push_navigate(socket, to: clean_path)

      {:error, reason} ->
        Logger.warning("[IntegrationForm] OAuth callback failed: #{inspect(reason)}")

        # Redirect to clean URL to strip the dead ?code= from the URL
        clean_path =
          Routes.path(
            "/admin/settings/integrations/#{socket.assigns.selected_provider}/#{socket.assigns.name}"
          )

        socket
        |> put_flash(:error, gettext("Failed to connect. Please try again."))
        |> push_navigate(to: clean_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp save_and_redirect(provider_key, name, params, socket) do
    provider = Providers.get(provider_key)
    full_key = "#{provider_key}:#{name}"

    attrs =
      if provider do
        provider.setup_fields
        |> Enum.reduce(%{}, fn field, acc ->
          value = String.trim(params[field.key] || "")

          Map.put(acc, field.key, value)
        end)
      else
        %{}
      end

    Integrations.save_setup(full_key, attrs)

    edit_path = Routes.path("/admin/settings/integrations/#{provider_key}/#{name}")

    {:noreply, push_navigate(socket, to: edit_path)}
  end

  defp run_connection_test(provider, full_key) do
    case {provider && provider.auth_type, Integrations.get_credentials(full_key)} do
      {:api_key, {:ok, data}} -> test_api_key(provider, data)
      {:bot_token, {:ok, data}} -> test_bot_token(data)
      {_, {:error, _}} -> {:error, gettext("No credentials configured")}
      _ -> :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp test_api_key(provider, data) do
    if Map.has_key?(provider, :validation) and provider.validation != nil do
      v = provider.validation
      api_key = data["api_key"] || ""
      headers = [{v.auth_header, "#{v.auth_prefix}#{api_key}"}]

      case Req.get(v.url, headers: headers) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: 401}} ->
          {:error, gettext("Invalid API key")}

        {:ok, %{status: 403}} ->
          {:error, gettext("Access denied — check your API key permissions")}

        {:ok, %{status: status}} ->
          {:error, gettext("Service returned error %{status}", status: status)}

        {:error, _} ->
          {:error, gettext("Could not reach the service — check your internet connection")}
      end
    else
      :ok
    end
  end

  defp test_bot_token(data) do
    token = data["bot_token"] || ""

    case Req.get("https://api.telegram.org/bot#{token}/getMe") do
      {:ok, %{status: 200, body: %{"ok" => true}}} ->
        :ok

      {:ok, %{status: 401}} ->
        {:error, gettext("Invalid bot token")}

      {:ok, %{status: _}} ->
        {:error, gettext("Invalid bot token — check with @BotFather")}

      {:error, _} ->
        {:error, gettext("Could not reach Telegram — check your internet connection")}
    end
  end

  defp save_validation_result(full_key, result) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Integrations.get_integration(full_key) do
      {:ok, data} ->
        updated =
          case result do
            :ok ->
              Map.merge(data, %{
                "status" => "connected",
                "last_validated_at" => now,
                "validation_status" => "ok"
              })

            {:error, reason} ->
              Map.merge(data, %{
                "status" => "error",
                "last_validated_at" => now,
                "validation_status" => "error: #{reason}"
              })
          end

        Integrations.save_setup(full_key, updated)

      _ ->
        :ok
    end
  end

  defp save_setup_fields(provider_key, name, params, socket) do
    provider = Providers.get(provider_key)
    full_key = "#{provider_key}:#{name}"

    attrs =
      if provider do
        provider.setup_fields
        |> Enum.reduce(%{}, fn field, acc ->
          value = String.trim(params[field.key] || "")

          # For password fields, skip empty values to keep the existing credential
          Map.put(acc, field.key, value)
        end)
      else
        %{}
      end

    case Integrations.save_setup(full_key, attrs) do
      {:ok, data} ->
        {:noreply,
         socket
         |> assign(:name, name)
         |> assign(:data, data)
         |> assign(:success, gettext("Saved"))
         |> assign(:error, nil)}

      {:error, _} ->
        {:noreply, assign(socket, :error, gettext("Failed to save"))}
    end
  end

  defp reload_data(socket) do
    if socket.assigns.name && socket.assigns.selected_provider do
      full_key = "#{socket.assigns.selected_provider}:#{socket.assigns.name}"

      data =
        case Integrations.get_integration(full_key) do
          {:ok, d} -> d
          _ -> %{}
        end

      assign(socket, :data, data)
    else
      socket
    end
  end

  defp build_redirect_uri(socket, provider_key, name) do
    base = Settings.get_setting("site_url", "")
    locale = socket.assigns[:current_locale_base]
    path = Routes.path("/admin/settings/integrations/#{provider_key}/#{name}", locale: locale)

    if base != "" do
      "#{String.trim_trailing(base, "/")}#{path}"
    else
      "http://localhost:4000#{path}"
    end
  end

  # Simple inline markdown: **bold**, [links](url), `code`, and {variables}
  defp render_markdown_inline(text, vars) do
    text
    |> replace_vars(vars)
    |> String.replace(~r/`(.+?)`/, "<code class=\"bg-base-300 px-1 rounded text-xs\">\\1</code>")
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/\[(.+?)\]\((.+?)\)/, "<a href=\"\\2\" target=\"_blank\">\\1</a>")
  end

  defp replace_vars(text, vars) do
    Enum.reduce(vars, text, fn {key, value}, acc ->
      String.replace(acc, "{#{key}}", value || "")
    end)
  end

  defp has_setup_credentials?(data, provider) do
    Enum.all?(provider.setup_fields, fn field ->
      if field.required do
        val = data[field.key]
        is_binary(val) and val != ""
      else
        true
      end
    end)
  end

  defp format_date(nil), do: ""

  defp format_date(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d")
      _ -> iso_string
    end
  end
end
