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
      |> assign(:form_values, %{})
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
    |> assign(:form_values, %{})
  end

  defp apply_action(socket, :edit, %{"uuid" => uuid} = params) do
    case Integrations.get_integration_by_uuid(uuid) do
      {:ok, %{provider: provider_key, name: name, data: data}} ->
        provider = Providers.get(provider_key)

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
              handle_oauth_callback(uuid, code, state, socket)

            %{"code" => code} when is_binary(code) and code != "" ->
              handle_oauth_callback(uuid, code, nil, socket)

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
      {:ok, %{uuid: uuid}} ->
        save_and_redirect(uuid, provider_key, name, params, socket)

      {:error, :already_exists} ->
        case lookup_connection_uuid(provider_key, name) do
          {:ok, uuid} -> save_and_redirect(uuid, provider_key, name, params, socket)
          :error -> {:noreply, assign(socket, :error, gettext("Failed to load connection"))}
        end

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
    save_setup_fields(socket.assigns.uuid, socket.assigns.selected_provider, params, socket)
  end

  # ---------------------------------------------------------------------------
  # Events — OAuth disconnect
  # ---------------------------------------------------------------------------

  def handle_event("disconnect_account", _params, socket) do
    uuid = socket.assigns.uuid

    # Keep the setup credentials (client_id/secret) but remove tokens
    Integrations.disconnect(uuid, actor_uuid(socket))

    # Reload data from the (now-disconnected) row
    data =
      case Integrations.get_integration_by_uuid(uuid) do
        {:ok, %{data: d}} -> d
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
    uuid = socket.assigns.uuid

    redirect_uri =
      socket.assigns[:redirect_uri] ||
        build_redirect_uri(socket, uuid)

    state = OAuth.generate_state()

    case Integrations.authorization_url(uuid, redirect_uri, nil, state) do
      {:ok, url} ->
        # Store state in integration data for verification on callback
        save_oauth_state(uuid, state)
        {:noreply, redirect(socket, external: url)}

      {:error, :client_id_not_configured} ->
        {:noreply, assign(socket, :error, gettext("Please save your Client ID first"))}

      {:error, _} ->
        {:noreply, assign(socket, :error, gettext("Failed to build authorization URL"))}
    end
  end

  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, success: nil, error: nil)}
  end

  # ---------------------------------------------------------------------------
  # Events — Unified form save (top-of-page Save button)
  # ---------------------------------------------------------------------------
  #
  # Dispatches based on current state and the optional `_intent`
  # flag (set by the Test Connection submit button):
  #
  # - `@name == nil` + `_intent: "test"` → /new flow, transient
  #   validation against the inputted credentials WITHOUT
  #   persisting. Lets the operator dry-run a key before committing
  #   to a connection row.
  # - `@name == nil` (no test intent) → create mode →
  #   `create_connection` (creates the storage row + saves
  #   credentials in one shot)
  # - `@name != nil` and posted name differs from current → rename
  #   first, then save credentials against the new name
  # - `@name != nil` and posted name matches → just save credentials
  #   (and `apply_save_outcome/2` may auto-test, see save_setup_fields)

  def handle_event("save_form", params, socket) do
    cond do
      socket.assigns.name == nil and params["_intent"] == "test" ->
        test_credentials_dry_run(params, socket)

      socket.assigns.name == nil ->
        # New connection — delegate to the existing create flow.
        handle_event("create_connection", params, socket)

      params["name"] && String.trim(params["name"]) != socket.assigns.name ->
        save_form_with_rename(params, socket)

      true ->
        # No rename — just save credentials.
        handle_event("save_setup", params, socket)
    end
  end

  # ---------------------------------------------------------------------------
  # Events — Delete connection (Danger Zone)
  # ---------------------------------------------------------------------------

  def handle_event("delete_connection", _params, socket) do
    case Integrations.remove_connection(socket.assigns.uuid, actor_uuid(socket)) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Connection removed"))
         |> push_navigate(to: Routes.path("/admin/settings/integrations"))}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, gettext("Failed to remove connection."))}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — Rename connection (edit mode, non-default only)
  # ---------------------------------------------------------------------------

  def handle_event("rename_connection", %{"name" => new_name}, socket) do
    case Integrations.rename_connection(socket.assigns.uuid, new_name, actor_uuid(socket)) do
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
    uuid = socket.assigns.uuid
    actor = actor_uuid(socket)
    result = Integrations.validate_connection(uuid, actor)
    Integrations.record_validation(uuid, result)

    data =
      case Integrations.get_integration_by_uuid(uuid) do
        {:ok, %{data: d}} -> d
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

  defp handle_oauth_callback(uuid, code, state, socket) do
    clean_path = Routes.path("/admin/settings/integrations/#{uuid}")

    # Verify CSRF state token if one was stored
    case verify_oauth_state(uuid, state) do
      :ok ->
        # Use the actual browser URL as redirect_uri (must match what was sent to Google)
        redirect_uri =
          socket.assigns[:redirect_uri] ||
            build_redirect_uri(socket, uuid)

        case Integrations.exchange_code(uuid, code, redirect_uri, actor_uuid(socket)) do
          {:ok, _data} ->
            push_navigate(socket, to: clean_path)

          {:error, reason} ->
            Logger.warning("[IntegrationForm] OAuth callback failed: #{inspect(reason)}")

            socket
            |> put_flash(:error, gettext("Failed to connect. Please try again."))
            |> push_navigate(to: clean_path)
        end

      {:error, :state_mismatch} ->
        Logger.warning("[IntegrationForm] OAuth state mismatch for #{uuid}")

        socket
        |> put_flash(:error, gettext("Security check failed. Please try connecting again."))
        |> push_navigate(to: clean_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Probe the provider's API with the values currently in the form,
  # without writing anything to storage. Used by Test Connection on
  # /new — operator wants to verify the api_key works before
  # committing to a connection row that might end up half-baked if
  # the test fails.
  #
  # Captures the typed-but-unsaved values onto socket assigns so the
  # form re-renders with what the user just typed, not the (still
  # empty) saved `@data`. Without this, a failed test would clear
  # the api_key field — confusing UX, makes it look like the form
  # ate the input.
  defp test_credentials_dry_run(params, socket) do
    provider_key = socket.assigns.selected_provider
    attrs = extract_setup_attrs(provider_key, params)
    name = String.trim(params["name"] || "")

    socket =
      socket
      |> assign(:new_name, name)
      |> assign(:form_values, attrs)

    case Integrations.validate_credentials(provider_key, attrs) do
      :ok ->
        {:noreply,
         socket
         |> assign(:success, gettext("Connection verified"))
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:error, "#{gettext("Test failed")}: #{reason}")
         |> assign(:success, nil)}
    end
  end

  defp save_form_with_rename(params, socket) do
    uuid = socket.assigns.uuid
    new_name = String.trim(params["name"])

    case Integrations.rename_connection(uuid, new_name, actor_uuid(socket)) do
      {:ok, data} ->
        socket =
          socket
          |> assign(:name, new_name)
          |> assign(:data, data)

        # Now save credentials under the new name.
        handle_event("save_setup", params, socket)

      {:error, :already_exists} ->
        {:noreply, assign(socket, :error, gettext("A connection with that name already exists."))}

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

  defp save_and_redirect(uuid, provider_key, name, params, socket) do
    attrs = extract_setup_attrs(provider_key, params)

    case Integrations.save_setup(uuid, attrs, actor_uuid(socket)) do
      {:ok, data} ->
        edit_path = Routes.path("/admin/settings/integrations/#{uuid}")

        socket =
          socket
          |> assign(:name, name)
          |> assign(:uuid, uuid)
          |> assign(:data, data)
          |> assign(:error, nil)
          |> push_patch(to: edit_path)
          |> apply_save_outcome(data)

        {:noreply, socket}

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

  defp save_setup_fields(uuid, provider_key, params, socket) do
    attrs = extract_setup_attrs(provider_key, params)

    case Integrations.save_setup(uuid, attrs, actor_uuid(socket)) do
      {:ok, data} ->
        socket =
          socket
          |> assign(:data, data)
          |> assign(:error, nil)
          |> apply_save_outcome(data)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, assign(socket, :error, gettext("Failed to save"))}
    end
  end

  # Choose the right post-save UI state. Two cases:
  #
  #   1. The save left the integration in a state we can immediately
  #      validate (`status in [configured, connected, error]`).
  #      Trigger the auto-test and let the test result own the
  #      success message — don't pre-set `success: "Saved"` first,
  #      otherwise the user sees a flash of "Saved" before
  #      "Connection verified" replaces it. The `"error"` case
  #      matters: a connection currently in error state still has
  #      credentials, the operator just edited them to (presumably)
  #      fix the problem, so we should re-test to either confirm
  #      the recovery or report the new error. This list mirrors
  #      the Test Connection button's visibility guard in the
  #      template — they have to stay in sync.
  #
  #   2. No test will fire — typically OAuth setup with no access
  #      token yet (`status: disconnected`). The user still needs to
  #      run the OAuth dance via "Connect Account". Surface "Saved"
  #      so they know their setup credentials persisted, then they
  #      can move on to the connect step.
  defp apply_save_outcome(socket, %{"status" => status} = _data)
       when status in ["configured", "connected", "error"] do
    send(self(), :do_test_connection)

    socket
    |> assign(:testing, true)
    |> assign(:success, nil)
  end

  defp apply_save_outcome(socket, _data) do
    assign(socket, :success, gettext("Saved"))
  end

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
    if socket.assigns[:uuid] do
      data =
        case Integrations.get_integration_by_uuid(socket.assigns.uuid) do
          {:ok, %{data: d}} -> d
          _ -> %{}
        end

      assign(socket, :data, data)
    else
      socket
    end
  end

  defp save_oauth_state(uuid, state) do
    case Integrations.get_integration_by_uuid(uuid) do
      {:ok, %{data: data}} ->
        Integrations.save_setup(uuid, Map.put(data, "oauth_state", state))

      _ ->
        :ok
    end
  end

  defp verify_oauth_state(uuid, callback_state) do
    case Integrations.get_integration_by_uuid(uuid) do
      {:ok, %{data: %{"oauth_state" => stored_state} = data}}
      when is_binary(stored_state) and stored_state != "" ->
        if callback_state == stored_state do
          # Clear the used state token
          Integrations.save_setup(uuid, Map.delete(data, "oauth_state"))
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

  # Humanize a UTC ISO8601 timestamp into a relative phrase like
  # "2 hours ago" / "3 days ago" / "Apr 28 2026". Falls back to the
  # raw string on parse failure.
  defp format_relative(nil), do: nil
  defp format_relative(""), do: nil

  defp format_relative(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        diff_seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff_seconds < 0 -> Calendar.strftime(dt, "%b %-d %Y")
          diff_seconds < 60 -> gettext("just now")
          diff_seconds < 3600 -> gettext_minutes(div(diff_seconds, 60))
          diff_seconds < 86_400 -> gettext_hours(div(diff_seconds, 3600))
          diff_seconds < 7 * 86_400 -> gettext_days(div(diff_seconds, 86_400))
          true -> Calendar.strftime(dt, "%b %-d %Y")
        end

      _ ->
        iso_string
    end
  end

  defp gettext_minutes(1), do: gettext("1 minute ago")
  defp gettext_minutes(n), do: gettext("%{n} minutes ago", n: n)

  defp gettext_hours(1), do: gettext("1 hour ago")
  defp gettext_hours(n), do: gettext("%{n} hours ago", n: n)

  defp gettext_days(1), do: gettext("1 day ago")
  defp gettext_days(n), do: gettext("%{n} days ago", n: n)
end
