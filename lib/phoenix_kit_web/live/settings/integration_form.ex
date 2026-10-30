defmodule PhoenixKitWeb.Live.Settings.IntegrationForm do
  @moduledoc """
  Form page for adding or editing an integration connection.

  - `:new` action — shows provider picker, then setup form with instructions
  - `:edit` action — shows the setup form for an existing connection
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.IntegrationsUI,
    only: [setup_field: 1, validation_note_style: 1, connection_usage: 1, integration_error: 1]

  require Logger

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Events
  alias PhoenixKit.Integrations.OAuth
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Integrations.Telegram.SiteBot
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor

  @impl true
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
      |> assign(:storage_usage, [])
      |> assign(:data, %{})
      |> assign(:success, nil)
      |> assign(:error, nil)
      |> assign(:warning, nil)
      |> assign(:new_name, "")
      |> assign(:form_values, %{})
      |> assign(:testing, false)
      |> assign(:saving, false)
      |> assign(:oauth_state, nil)
      |> assign(:site_bot, false)
      |> assign(:site_bot_webhook, false)

    {:ok, socket}
  end

  @impl true
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

  defp apply_action(socket, :new, params) do
    # `?provider=key` opens the form on that provider (another page links here,
    # e.g. the storage bucket form's "Add a connection"). Only a provider a
    # website-wide connection may use is taken; anything else shows the picker.
    provider = preselected_provider(params["provider"])

    socket
    |> assign(:page_title, gettext("Add Integration"))
    |> assign(:selected_provider, provider && provider.key)
    |> assign(:provider, provider)
    |> assign(:name, nil)
    |> assign(:data, %{})
    |> assign(:form_values, %{})
  end

  defp apply_action(socket, :edit, %{"uuid" => uuid} = params) do
    # Owner-scoped edit-load: the system form only ever loads SYSTEM
    # connections, so a crafted URL to a user's personal uuid fails closed
    # (redirects) instead of rendering that user's decrypted credentials.
    case Integrations.get_integration_by_uuid(uuid, :system) do
      {:ok, %{provider: provider_key, name: name, data: data}} ->
        provider = Providers.get(provider_key)

        socket =
          socket
          |> assign(:page_title, gettext("Edit Integration"))
          |> assign(:selected_provider, provider_key)
          |> assign(:provider, provider)
          |> assign(:name, name)
          |> assign(:uuid, uuid)
          |> assign(:storage_usage, Integrations.usage(uuid, owner: :system))
          |> assign(
            :bucket_uses,
            Map.get(Storage.bucket_counts_by_connection(), uuid, 0)
          )
          |> assign(:data, data)
          |> assign(:site_bot, provider_key == "telegram" and SiteBot.selected?(uuid))
          |> assign(:site_bot_webhook, false)
          # Values typed on /new (a dry-run Test) are saved by now. Kept, they
          # would be rendered as typed — a secret included — on the edit page
          # that Create patches to.
          |> assign(:form_values, %{})

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

  # Dependencies disable removal in the UI and are enforced by the context.
  defp delete_confirm(0, false),
    do: gettext("Permanently delete this connection? This cannot be undone.")

  defp delete_confirm(count, false) do
    ngettext(
      "%{count} storage bucket uses this connection and prevents its removal.",
      "%{count} storage buckets use this connection and prevent its removal.",
      count
    )
  end

  # The website's notification bot: every user who linked a chat to it stops
  # getting Telegram notifications, and has to link again to a new one.
  defp delete_confirm(count, true) do
    gettext(
      "This is the website's Telegram bot for user notifications — everyone who linked a chat to it will stop receiving them. %{rest}",
      rest: delete_confirm(count, false)
    )
  end

  defp preselected_provider(key) when is_binary(key) do
    case Providers.get(key) do
      %{} = provider -> if :system in Providers.scopes_of(provider), do: provider
      _ -> nil
    end
  end

  defp preselected_provider(_key), do: nil

  # ---------------------------------------------------------------------------
  # Events — provider selection (new mode)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event(event, _params, %{assigns: %{live_action: :edit}} = socket)
      when event in ["select_provider", "back_to_providers"], do: {:noreply, socket}

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

    case Integrations.add_connection(provider_key, name, Actor.uuid(socket), owner: :system) do
      {:ok, %{uuid: uuid}} ->
        save_and_redirect(uuid, provider_key, name, params, socket)

      {:error, :empty_name} ->
        {:noreply,
         socket
         |> assign(:new_name, name)
         |> assign(:form_values, extract_setup_attrs(provider_key, params))
         |> assign(:error, gettext("Please enter a connection name."))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:new_name, name)
         |> assign(:form_values, extract_setup_attrs(provider_key, params))
         |> assign(:error, "Failed: #{inspect(reason)}")}
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

    case Integrations.disconnect(uuid, Actor.uuid(socket)) do
      :ok ->
        data =
          case Integrations.get_integration_by_uuid(uuid, :system) do
            {:ok, %{data: data}} -> data
            _ -> %{}
          end

        {:noreply,
         socket
         |> assign(:data, data)
         |> assign(:success, gettext("Account disconnected"))
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, integration_error(reason))}
    end
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

  # A field that re-shapes the form (the object-storage service) changed: keep
  # what is typed so far and render the fields the new choice asks for. Only
  # the declared keys are taken, and the name is kept so the re-render does not
  # blank it.
  def handle_event("setup_changed", params, socket) do
    provider = socket.assigns.provider
    keys = Enum.map(provider.setup_fields, & &1.key)

    # Seed only the service from saved data: secrets must never become typed
    # values and be echoed into the page. This also preserves an inferred
    # legacy service on the first change to another field.
    previous =
      Map.put_new(
        socket.assigns.form_values,
        "service",
        Providers.setup_saved(provider, socket.assigns.data, %{})["service"]
      )

    typed = Providers.setup_changed(provider, previous, Map.take(params, keys))

    socket = assign(socket, :form_values, typed)

    socket =
      if socket.assigns.name == nil and is_binary(params["name"]),
        do: assign(socket, :new_name, params["name"]),
        else: socket

    {:noreply, socket}
  end

  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, success: nil, error: nil, warning: nil)}
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

  # Telegram: deliver users' notifications through this website bot. The
  # checkbox is a phx-change form, so the hidden "false" fallback is what
  # arrives when it is cleared.
  def handle_event("set_site_bot", %{"enabled" => enabled}, socket)
      when is_binary(socket.assigns.uuid) do
    uuid = socket.assigns.uuid
    opts = [actor_uuid: Actor.uuid(socket), source: "integrations"]

    result = if enabled == "true", do: SiteBot.select(uuid, opts), else: SiteBot.clear(opts)

    socket =
      case result do
        :ok -> assign(socket, :site_bot, SiteBot.selected?(uuid))
        _ -> assign(socket, :error, gettext("Could not change this setting."))
      end

    {:noreply, check_site_bot_webhook(socket)}
  end

  # No saved connection yet (new mode): nothing to choose.
  def handle_event("set_site_bot", _params, socket), do: {:noreply, socket}

  def handle_event("delete_connection", _params, socket) do
    case Integrations.remove_connection(socket.assigns.uuid, Actor.uuid(socket)) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Connection removed"))
         |> push_navigate(to: Routes.path("/admin/settings/integrations"))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, integration_error(reason))}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — Rename connection (edit mode, non-default only)
  # ---------------------------------------------------------------------------

  def handle_event("rename_connection", %{"name" => new_name}, socket) do
    case Integrations.rename_connection(socket.assigns.uuid, new_name, Actor.uuid(socket)) do
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

      {:error, :empty_name} ->
        {:noreply, assign(socket, :error, gettext("Connection name can't be blank."))}

      {:error, _other} ->
        {:noreply, assign(socket, :error, gettext("Failed to rename connection."))}
    end
  end

  # ---------------------------------------------------------------------------
  # Async handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:do_test_connection, socket) do
    uuid = socket.assigns.uuid
    actor = Actor.uuid(socket)
    result = Integrations.validate_connection(uuid, actor)
    Integrations.record_validation(uuid, result)

    data =
      case Integrations.get_integration_by_uuid(uuid, :system) do
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
          |> assign(:warning, nil)

        # The check passed but could not verify everything — say so instead of
        # showing a bare "verified" the operator would read as "sending works".
        {:ok, note} ->
          socket
          |> assign(:data, data)
          |> assign(
            :success,
            "#{gettext("Connection verified")} — #{Integrations.note_text({:ok, note})}"
          )
          |> assign(:error, nil)
          |> assign(:warning, nil)

        # Neither a pass nor a failure — this provider has no way to check a
        # connection at all, so nothing ran. Saying "verified" would repeat
        # the bug this exists to fix; saying "failed" would blame the
        # operator for something that was never attempted.
        :unverified ->
          socket
          |> assign(:data, data)
          |> assign(:warning, gettext("Not tested — this provider has no connection check"))
          |> assign(:success, nil)
          |> assign(:error, nil)

        {:error, reason} ->
          socket
          |> assign(:data, data)
          |> assign(:error, "#{gettext("Test failed")}: #{reason}")
          |> assign(:success, nil)
          |> assign(:warning, nil)
      end

    {:noreply, socket |> assign(:testing, false) |> check_site_bot_webhook()}
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

  @impl true
  def handle_async(:save_storage, {:ok, {uuid, result}}, socket) do
    socket = assign(socket, :saving, false)

    if socket.assigns.uuid == uuid,
      do: save_setup_result(socket, result),
      else: {:noreply, socket}
  end

  def handle_async(:save_storage, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:saving, false)
     |> assign(:error, gettext("Saving stopped unexpectedly. Refresh before trying again."))}
  end

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

        case Integrations.exchange_code(uuid, code, redirect_uri, Actor.uuid(socket)) do
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
         |> assign(:error, nil)
         |> assign(:warning, nil)}

      {:ok, note} ->
        {:noreply,
         socket
         |> assign(
           :success,
           "#{gettext("Connection verified")} — #{Integrations.note_text({:ok, note})}"
         )
         |> assign(:error, nil)
         |> assign(:warning, nil)}

      # See the matching :unverified clause in handle_info(:do_test_connection, _) —
      # same "neither pass nor fail" case, hit here before the row even exists.
      :unverified ->
        {:noreply,
         socket
         |> assign(:warning, gettext("Not tested — this provider has no connection check"))
         |> assign(:success, nil)
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:error, "#{gettext("Test failed")}: #{reason}")
         |> assign(:success, nil)
         |> assign(:warning, nil)}
    end
  end

  defp save_form_with_rename(params, socket) do
    save_setup_fields(socket.assigns.uuid, socket.assigns.selected_provider, params, socket)
  end

  defp save_and_redirect(uuid, provider_key, name, params, socket) do
    attrs = extract_setup_attrs(provider_key, params)

    case Integrations.save_setup(uuid, attrs, Actor.uuid(socket)) do
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

      {:error, reason} ->
        {:noreply, assign(socket, :error, integration_error(reason))}
    end
  end

  defp save_setup_fields(uuid, provider_key, params, socket) do
    attrs = Providers.setup_edit_attrs(Providers.get(provider_key), socket.assigns.data, params)
    actor = Actor.uuid(socket)
    name = String.trim(params["name"] || socket.assigns.name)

    if provider_key == "object_storage" and socket.assigns.storage_usage != [] do
      {:noreply,
       socket
       |> assign(:saving, true)
       |> start_async(:save_storage, fn ->
         {uuid, Integrations.update_connection(uuid, name, attrs, actor)}
       end)}
    else
      save_setup_result(socket, Integrations.update_connection(uuid, name, attrs, actor))
    end
  end

  defp save_setup_result(socket, {:ok, data}) do
    socket = assign(socket, :name, data["name"])

    {:noreply,
     socket
     |> assign(:data, data)
     |> assign(:error, nil)
     |> assign(:form_values, %{})
     |> apply_save_outcome(data)}
  end

  defp save_setup_result(socket, {:error, reason}) do
    {:noreply,
     socket
     |> assign(:storage_usage, Integrations.usage(socket.assigns.uuid))
     |> assign(:error, integration_error(reason))}
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
    Providers.setup_attrs(Providers.get(provider_key), params)
  end

  # Linking reads the bot's updates, which Telegram refuses on a bot with a
  # webhook — say so while the admin is looking, not when a user's link
  # silently never completes.
  defp check_site_bot_webhook(%{assigns: %{site_bot: true, uuid: uuid}} = socket) do
    assign(socket, :site_bot_webhook, SiteBot.webhook_set?(uuid))
  end

  defp check_site_bot_webhook(socket), do: assign(socket, :site_bot_webhook, false)

  defp reload_data(socket) do
    if socket.assigns[:uuid] do
      data =
        case Integrations.get_integration_by_uuid(socket.assigns.uuid, :system) do
          {:ok, %{data: d}} -> d
          _ -> %{}
        end

      assign(socket, :data, data)
    else
      socket
    end
  end

  defp save_oauth_state(uuid, state) do
    case Integrations.get_integration_by_uuid(uuid, :system) do
      {:ok, %{data: data}} ->
        Integrations.save_setup(uuid, Map.put(data, "oauth_state", state))

      _ ->
        :ok
    end
  end

  defp verify_oauth_state(uuid, callback_state) do
    case Integrations.get_integration_by_uuid(uuid, :system) do
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
        # No state stored: either someone bypassed `connect_oauth` (which
        # always calls `save_oauth_state/2` before the redirect, see
        # `:227`) or the row was modified between authorize and callback.
        # Both shapes are CSRF-relevant — refuse rather than silently
        # accepting. Pre-2026-05 the lenient `:ok` here was justified by
        # an older flow that didn't save state; that flow is gone.
        {:error, :state_mismatch}
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
      # `to_string/1` guards against non-binary `value` reaching
      # `safe_to_string/1`, which would crash. Current callers pass
      # strings only (`%{"redirect_uri" => ...}`), but a future
      # caller stuffing an integer port or atom in shouldn't 500
      # the instructions panel.
      escaped =
        (value || "")
        |> to_string()
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string()

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
