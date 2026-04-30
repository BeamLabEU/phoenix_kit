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
  alias PhoenixKit.Integrations.OAuth
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
      |> assign(:uuid, nil)
      |> assign(:data, %{})
      |> assign(:success, nil)
      |> assign(:error, nil)
      |> assign(:new_name, "")
      |> assign(:testing, false)
      |> assign(:oauth_state, nil)

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

  defp apply_action(socket, :edit, %{"uuid" => uuid} = params) do
    case Integrations.get_integration_by_uuid(uuid) do
      {:ok, %{provider: provider_key, name: name, data: data}} ->
        provider = Providers.get(provider_key)
        full_key = "#{provider_key}:#{name}"

        socket =
          socket
          |> assign(:page_title, gettext("Edit Integration"))
          |> assign(:selected_provider, provider_key)
          |> assign(:provider, provider)
          |> assign(:name, name)
          |> assign(:uuid, uuid)
          |> assign(:data, data)

        # Handle OAuth callback (code in query params).
        # Only process during live WebSocket connection — during dead
        # (static) render the internal URI may differ from the external
        # URL (e.g. http vs https behind a reverse proxy), causing
        # redirect_uri mismatch with Google's token endpoint.
        if connected?(socket) do
          case params do
            %{"code" => code, "state" => state} when is_binary(code) and code != "" ->
              handle_oauth_callback(full_key, code, state, socket)

            %{"code" => code} when is_binary(code) and code != "" ->
              handle_oauth_callback(full_key, code, nil, socket)

            %{"error" => error} ->
              description = params["error_description"] || error
              clean_path = Routes.path("/admin/settings/integrations/#{uuid}")

              socket
              |> put_flash(
                :error,
                gettext("Authorization failed: %{reason}", reason: description)
              )
              |> push_navigate(to: clean_path)

            _ ->
              socket
          end
        else
          socket
        end

      {:error, _} ->
        socket
        |> put_flash(:error, gettext("Integration not found"))
        |> push_navigate(to: Routes.path("/admin/settings/integrations"))
    end
  end

  defp apply_action(socket, :edit, _params) do
    socket
    |> put_flash(:error, gettext("Invalid integration URL"))
    |> push_navigate(to: Routes.path("/admin/settings/integrations"))
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

    case Integrations.add_connection(provider_key, name, actor_uuid(socket)) do
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
    Integrations.disconnect(full_key, actor_uuid(socket))

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
        build_redirect_uri(socket, socket.assigns.uuid)

    state = OAuth.generate_state()

    case Integrations.authorization_url(full_key, redirect_uri, nil, state) do
      {:ok, url} ->
        # Store state in integration data for verification on callback
        save_oauth_state(full_key, state)
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
  # Events — Rename connection (edit mode, non-default only)
  # ---------------------------------------------------------------------------

  def handle_event("rename_connection", %{"name" => new_name}, socket) do
    provider_key = socket.assigns.selected_provider
    old_name = socket.assigns.name

    case Integrations.rename_connection(provider_key, old_name, new_name, actor_uuid(socket)) do
      {:ok, data} ->
        # URL is uuid-based, so a rename doesn't change the route — just
        # update local assigns and surface a success flash. The list page
        # picks up the new name through the `:integration_connection_renamed`
        # broadcast.
        socket =
          socket
          |> assign(:name, new_name)
          |> assign(:data, data)
          |> assign(:success, gettext("Connection renamed"))
          |> assign(:error, nil)

        {:noreply, socket}

      {:error, :already_exists} ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("A connection with that name already exists.")
         )}

      {:error, :empty_name} ->
        {:noreply, assign(socket, :error, gettext("Connection name can't be blank."))}

      {:error, :invalid_name} ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("Use letters, digits, hyphens, and underscores only.")
         )}

      {:error, _other} ->
        {:noreply, assign(socket, :error, gettext("Failed to rename connection."))}
    end
  end

  # ---------------------------------------------------------------------------
  # Async handlers
  # ---------------------------------------------------------------------------

  def handle_info(:do_test_connection, socket) do
    provider_key = socket.assigns.selected_provider
    name = socket.assigns.name
    full_key = "#{provider_key}:#{name}"
    provider = socket.assigns.provider

    uuid = actor_uuid(socket)
    result = run_connection_test(provider, full_key, uuid)
    Integrations.record_validation(full_key, result)

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

  # Catch-all to prevent crashes from unexpected messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp handle_oauth_callback(full_key, code, state, socket) do
    clean_path =
      Routes.path("/admin/settings/integrations/#{socket.assigns.uuid}")

    # Verify CSRF state token if one was stored
    case verify_oauth_state(full_key, state) do
      :ok ->
        # Use the actual browser URL as redirect_uri (must match what was sent to Google)
        redirect_uri =
          socket.assigns[:redirect_uri] ||
            build_redirect_uri(socket, socket.assigns.uuid)

        case Integrations.exchange_code(full_key, code, redirect_uri, actor_uuid(socket)) do
          {:ok, _data} ->
            push_navigate(socket, to: clean_path)

          {:error, reason} ->
            Logger.warning("[IntegrationForm] OAuth callback failed: #{inspect(reason)}")

            socket
            |> put_flash(:error, gettext("Failed to connect. Please try again."))
            |> push_navigate(to: clean_path)
        end

      {:error, :state_mismatch} ->
        Logger.warning("[IntegrationForm] OAuth state mismatch for #{full_key}")

        socket
        |> put_flash(:error, gettext("Security check failed. Please try connecting again."))
        |> push_navigate(to: clean_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp save_and_redirect(provider_key, name, params, socket) do
    full_key = "#{provider_key}:#{name}"
    attrs = extract_setup_attrs(provider_key, params)

    case Integrations.save_setup(full_key, attrs, actor_uuid(socket)) do
      {:ok, data} ->
        # The settings storage row's UUID is the new edit URL anchor.
        # `add_connection` already created the row; resolve its UUID
        # from the just-saved row before push_patching to the edit page.
        case lookup_connection_uuid(provider_key, name) do
          {:ok, uuid} ->
            edit_path = Routes.path("/admin/settings/integrations/#{uuid}")

            socket =
              socket
              |> assign(:name, name)
              |> assign(:uuid, uuid)
              |> assign(:data, data)
              |> assign(:success, gettext("Saved"))
              |> assign(:error, nil)
              |> push_patch(to: edit_path)
              |> maybe_auto_test(data)

            {:noreply, socket}

          :error ->
            {:noreply, assign(socket, :error, gettext("Failed to load saved connection"))}
        end

      {:error, _} ->
        {:noreply, assign(socket, :error, gettext("Failed to save"))}
    end
  end

  defp lookup_connection_uuid(provider_key, name) do
    Integrations.list_connections(provider_key)
    |> Enum.find(fn %{name: n} -> n == name end)
    |> case do
      %{uuid: uuid} when is_binary(uuid) -> {:ok, uuid}
      _ -> :error
    end
  end

  defp run_connection_test(_provider, full_key, actor_uuid) do
    Integrations.validate_connection(full_key, actor_uuid)
  end

  defp save_setup_fields(provider_key, name, params, socket) do
    full_key = "#{provider_key}:#{name}"
    attrs = extract_setup_attrs(provider_key, params)

    case Integrations.save_setup(full_key, attrs, actor_uuid(socket)) do
      {:ok, data} ->
        socket =
          socket
          |> assign(:name, name)
          |> assign(:data, data)
          |> assign(:success, gettext("Saved"))
          |> assign(:error, nil)
          |> maybe_auto_test(data)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, assign(socket, :error, gettext("Failed to save"))}
    end
  end

  # Auto-trigger validation right after save when there's something
  # testable. `:disconnected` post-save means an OAuth provider without
  # an access token yet — the user still needs to run the OAuth dance
  # via the "Connect Account" button before any validation can succeed,
  # so skip the auto-test there to avoid stamping a spurious error.
  defp maybe_auto_test(socket, %{"status" => status})
       when status in ["configured", "connected"] do
    send(self(), :do_test_connection)
    assign(socket, :testing, true)
  end

  defp maybe_auto_test(socket, _data), do: socket

  defp extract_setup_attrs(provider_key, params) do
    case Providers.get(provider_key) do
      nil ->
        %{}

      provider ->
        Enum.reduce(provider.setup_fields, %{}, fn field, acc ->
          value = String.trim(params[field.key] || "")

          # For password fields, skip empty values to keep the existing credential
          if field.type == :password and value == "" do
            acc
          else
            Map.put(acc, field.key, value)
          end
        end)
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

  defp save_oauth_state(full_key, state) do
    case Integrations.get_integration(full_key) do
      {:ok, data} ->
        Integrations.save_setup(full_key, Map.put(data, "oauth_state", state))

      _ ->
        :ok
    end
  end

  defp verify_oauth_state(full_key, callback_state) do
    case Integrations.get_integration(full_key) do
      {:ok, %{"oauth_state" => stored_state}}
      when is_binary(stored_state) and stored_state != "" ->
        if callback_state == stored_state do
          # Clear the used state token
          {:ok, data} = Integrations.get_integration(full_key)
          Integrations.save_setup(full_key, Map.delete(data, "oauth_state"))
          :ok
        else
          {:error, :state_mismatch}
        end

      _ ->
        # No state was stored (legacy flow or state not required) — allow
        :ok
    end
  end

  defp build_redirect_uri(socket, uuid) do
    base = Settings.get_setting("site_url", "")
    locale = socket.assigns[:current_locale_base]
    path = Routes.path("/admin/settings/integrations/#{uuid}", locale: locale)

    if is_binary(base) and base != "" do
      "#{String.trim_trailing(base, "/")}#{path}"
    else
      Logger.warning(
        "[IntegrationForm] site_url not configured — using localhost fallback for OAuth redirect URI"
      )

      "http://localhost:4000#{path}"
    end
  end

  defp actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> uuid
      _ -> nil
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
      escaped = Phoenix.HTML.html_escape(value || "") |> Phoenix.HTML.safe_to_string()
      String.replace(acc, "{#{key}}", escaped)
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
