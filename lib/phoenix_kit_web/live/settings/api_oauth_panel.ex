defmodule PhoenixKitWeb.Live.Settings.ApiOauthPanel do
  @moduledoc """
  The "Sign-in (OAuth)" tab of Settings -> API (`?tab=oauth`): the two switches of the OAuth side
  of the MCP endpoint (`api_oauth_enabled`, `api_oauth_dcr_enabled`), its status and addresses
  (`PhoenixKit.API.OAuth.Status`), the settings form (`PhoenixKit.API.OAuthConfig`: access token
  life, connections per person, limits, which clients may connect), the clients an administrator
  adds by hand and removes, and, for an Owner, every connected application
  (`PhoenixKitWeb.Live.Components.ConnectedApps` in its `:all` view).

  A LiveComponent that `PhoenixKitWeb.Live.Settings.Api` mounts when its tab is opened, so the
  other tabs do not read this tab's data. Assigns: `id`, `scope` (the page's scope) and
  `impersonated` (a boolean, for the connected apps below).

  ## Rights are checked on the server

  Every event re-reads the person's rights (`PhoenixKit.API.Access.fresh_scope/1`, the `api`
  permission) and acts as that person: a right lost since the page was opened is refused and
  nothing is written. The form is all or nothing and each changed setting is a permanent
  `setting.changed` Activity entry (`PhoenixKit.API.OAuthConfig.save/2`); adding a client writes
  `oauth.client_registered`, removing one ends every connection of it first
  (`PhoenixKit.API.OAuth.Clients.delete/2`, one `oauth.grant_revoked` entry each).

  Only the fields of the form are read from the params, each as text; the client to remove is the
  uuid the server stored when its dialog opened, never a param of the confirming event.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.API.Access
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.RedirectUri
  alias PhoenixKit.API.OAuth.Status
  alias PhoenixKit.API.OAuthConfig
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Live.Components.ConnectedApps

  @max_redirects 10

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:scope, Map.get(assigns, :scope, socket.assigns[:scope]))
      |> assign(:impersonated, Map.get(assigns, :impersonated, socket.assigns[:impersonated]))
      |> assign_new(:message, fn -> nil end)
      |> assign_new(:settings_params, fn -> OAuthConfig.current() end)
      |> assign_new(:settings_errors, fn -> [] end)
      |> assign_new(:client_params, fn -> blank_client() end)
      |> assign_new(:client_errors, fn -> [] end)
      |> assign_new(:delete_confirmation, fn -> %{show: false} end)

    {:ok, load(socket)}
  end

  defp load(socket) do
    socket
    |> assign(:status, Status.report())
    |> assign(:oauth_setting, Settings.get_boolean_setting("api_oauth_enabled", false))
    |> assign(:dcr_setting, Settings.get_boolean_setting("api_oauth_dcr_enabled", false))
    |> assign(:clients, Clients.list())
    |> assign(:owner?, Scope.owner?(socket.assigns.scope))
  end

  defp blank_client, do: %{"client_id" => "", "client_name" => "", "redirect_uris" => ""}

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("set_oauth", %{"state" => state}, socket) when state in ["on", "off"] do
    with_access(socket, fn socket ->
      if state == "on" and not Config.admin_enabled?(),
        do: error(socket, gettext("Switch the admin API on first.")),
        else: write_switch(socket, "api_oauth_enabled", state == "on")
    end)
  end

  def handle_event("set_dcr", %{"state" => state}, socket) when state in ["on", "off"] do
    with_access(socket, fn socket ->
      if state == "on" and not Settings.get_boolean_setting("api_oauth_enabled", false),
        do: error(socket, gettext("Switch OAuth on first.")),
        else: write_switch(socket, "api_oauth_dcr_enabled", state == "on")
    end)
  end

  def handle_event("save_settings", %{"oauth" => params}, socket) when is_map(params) do
    with_access(socket, fn socket ->
      params = normalize_settings(params)

      case OAuthConfig.save(params, history(socket)) do
        {:ok, _changed} ->
          socket
          |> assign(:settings_params, OAuthConfig.current())
          |> assign(:settings_errors, [])
          |> info(gettext("The settings were saved."))

        {:error, :save_failed} ->
          socket
          |> assign(:settings_params, params)
          |> assign(:settings_errors, [gettext("The settings could not be saved.")])

        {:error, fields} when is_list(fields) ->
          socket
          |> assign(:settings_params, params)
          |> assign(:settings_errors, [
            gettext(
              "Every number must be a whole number inside its range, and the hosts must be plain host names, one per line."
            )
          ])
      end
    end)
  end

  def handle_event("add_client", %{"client" => params}, socket) when is_map(params) do
    with_access(socket, fn socket -> add_client(socket, normalize_client(params)) end)
  end

  def handle_event("request_delete_client", %{"uuid" => uuid}, socket) do
    with_access(
      socket,
      fn socket ->
        case Enum.find(socket.assigns.clients, &(&1.client.uuid == uuid)) do
          nil ->
            error(socket, gettext("That client was not found."))

          %{client: client, grants: grants} ->
            assign(socket, :delete_confirmation, %{
              show: true,
              uuid: client.uuid,
              name: client_name(client),
              grants: grants
            })
        end
      end,
      clear_message: true
    )
  end

  def handle_event("cancel_delete_client", _params, socket) do
    {:noreply, assign(socket, :delete_confirmation, %{show: false})}
  end

  def handle_event("confirm_delete_client", _params, socket) do
    with_access(socket, fn socket ->
      uuid = Map.get(socket.assigns.delete_confirmation, :uuid)
      socket = assign(socket, :delete_confirmation, %{show: false})

      case uuid && Clients.delete(uuid, actor_uuid: Scope.user_uuid(socket.assigns.fresh_scope)) do
        {:ok, _client} -> info(socket, gettext("The client was removed."))
        {:error, :not_found} -> error(socket, gettext("That client was not found."))
        _other -> error(socket, gettext("The client could not be removed."))
      end
    end)
  end

  def handle_event(_event, _params, socket) do
    {:noreply, error(socket, gettext("That action is not available."))}
  end

  # Every event that changes something goes through here: the person's rights are read again for
  # THIS event, and the fresh scope is the one that acts. A refusal closes the dialog.
  defp with_access(socket, fun, opts \\ []) do
    case Access.fresh_scope(socket.assigns.scope) do
      {:ok, fresh} ->
        socket = assign(socket, :fresh_scope, fresh)
        socket = if opts[:clear_message], do: assign(socket, :message, nil), else: socket
        {:noreply, socket |> fun.() |> load()}

      :error ->
        {:noreply,
         socket
         |> assign(:delete_confirmation, %{show: false})
         |> error(gettext("You are not allowed to do that."))}
    end
  end

  defp history(socket),
    do: [actor_uuid: Scope.user_uuid(socket.assigns.fresh_scope), source: "settings"]

  defp write_switch(socket, setting, on?) do
    case Settings.update_boolean_setting_with_module(setting, on?, "api", history(socket)) do
      {:ok, _setting} -> assign(socket, :message, nil)
      {:error, _changeset} -> error(socket, gettext("The switch could not be saved."))
    end
  end

  defp error(socket, text), do: assign(socket, :message, {:error, text})
  defp info(socket, text), do: assign(socket, :message, {:info, text})

  # ── The settings form ──────────────────────────────────────────────

  # Only the fields of the form survive, each a string.
  defp normalize_settings(params) do
    fields = Enum.map(OAuthConfig.fields(), & &1.field) ++ ["client_policy", "allow_hosts"]
    Map.new(fields, fn field -> {field, text(params[field])} end)
  end

  # ── Clients ────────────────────────────────────────────────────────

  defp normalize_client(params) do
    Map.new(["client_id", "client_name", "redirect_uris"], &{&1, text(params[&1])})
  end

  defp add_client(socket, params) do
    redirects = Config.parse_list(params["redirect_uris"])

    attrs = %{
      client_id: String.trim(params["client_id"]),
      client_name: params["client_name"],
      redirect_uris: redirects
    }

    if redirects == [] or length(redirects) > @max_redirects do
      socket
      |> assign(:client_params, params)
      |> assign(:client_errors, [gettext("Give from 1 to 10 redirect addresses, one per line.")])
    else
      actor = Scope.user_uuid(socket.assigns.fresh_scope)

      case Clients.register_preregistered(attrs, actor_uuid: actor) do
        {:ok, _client} ->
          socket
          |> assign(:client_params, blank_client())
          |> assign(:client_errors, [])
          |> info(gettext("The client was added."))

        {:error, %Ecto.Changeset{} = changeset} ->
          socket
          |> assign(:client_params, params)
          |> assign(:client_errors, client_errors(changeset))
      end
    end
  end

  defp client_errors(%Ecto.Changeset{errors: errors}) do
    messages =
      Enum.map(errors, fn
        {:client_id, {_message, opts}} ->
          if opts[:constraint] == :unique,
            do: gettext("That client ID is already registered."),
            else: gettext("The client ID is required (at most 2048 characters, plain text).")

        {:redirect_uris, _error} ->
          gettext(
            "A redirect address must be https, or http to 127.0.0.1 or [::1], with no fragment and no wildcard."
          )

        {_field, _error} ->
          gettext("The client could not be saved.")
      end)

    Enum.uniq(messages)
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  # ── Template helpers ───────────────────────────────────────────────

  defp client_name(%Client{client_name: name}) when is_binary(name) and name != "", do: name
  defp client_name(%Client{client_id: client_id}), do: client_id

  defp kind_label(%Client{kind: "preregistered"}), do: gettext("Added by hand")
  defp kind_label(%Client{kind: "dcr"}), do: gettext("Registered itself")
  defp kind_label(%Client{kind: "cimd"}), do: gettext("Metadata document")

  defp redirect_hosts(%Client{redirect_uris: uris}) do
    uris |> Enum.map(&RedirectUri.host/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp url_label(:resource), do: gettext("MCP server")
  defp url_label(:protected_resource_metadata), do: gettext("Protected resource metadata")
  defp url_label(:authorization_server_metadata), do: gettext("Authorization server metadata")
  defp url_label(:authorization), do: gettext("Authorization endpoint")
  defp url_label(:token), do: gettext("Token endpoint")
  defp url_label(:revocation), do: gettext("Revocation endpoint")
  defp url_label(:registration), do: gettext("Registration endpoint")

  defp warning_text(:admin_api_off),
    do:
      gettext("The admin API is off, so every OAuth address answers 404 whatever this tab says.")

  defp warning_text(:origin_not_https),
    do:
      gettext(
        "The site address is not https. Web assistants refuse to connect to it: set the site address in the general settings."
      )

  defp warning_text(:allow_list_empty),
    do:
      gettext(
        "Only listed hosts may connect and the list is empty: no application can connect, except one added by hand below."
      )

  defp policy_options do
    [
      {gettext("Any application (its address is shown to the person)"), "any"},
      {gettext("Only the hosts listed below"), "allow_list"}
    ]
  end

  defp message_role(:error), do: "alert"
  defp message_role(:info), do: "status"

  defp alert_class(:error), do: "alert alert-error text-sm"
  defp alert_class(:info), do: "alert alert-success text-sm"

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-6">
      <div id={"#{@id}-messages"} aria-live="polite">
        <div
          :if={@message}
          id={"#{@id}-message"}
          role={message_role(elem(@message, 0))}
          class={alert_class(elem(@message, 0))}
        >
          {elem(@message, 1)}
        </div>
      </div>

      <%!-- Switches --%>
      <.form_section
        id="api-oauth-switches"
        title={gettext("Sign-in connections (OAuth)")}
        icon="hero-link"
        class="border border-base-200"
        body_class="space-y-4"
      >
        <:subtitle>
          {gettext(
            "Lets AI assistants such as Claude and ChatGPT connect after a sign-in, with no key to copy. It is off until you switch it on; while it is off every OAuth address answers 404."
          )}
        </:subtitle>

        <div id="api-oauth-switch-row" class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <h3 id="api-oauth-switch-title" class="font-medium">
              {gettext("OAuth for the MCP server")}
            </h3>
            <p id="api-oauth-switch-text" class="text-sm text-base-content/70">
              {gettext(
                "Needs the admin API. A person who may keep personal API keys connects an application by signing in and allowing access."
              )}
            </p>
          </div>
          <.checkbox
            id="api-oauth-switch"
            name="api-oauth-switch"
            variant="toggle"
            class="toggle-lg"
            wrapper_class="shrink-0 flex-row-reverse"
            label={if @status.oauth_enabled, do: gettext("Enabled"), else: gettext("Disabled")}
            aria-labelledby="api-oauth-switch-title"
            aria-describedby="api-oauth-switch-text"
            checked={@oauth_setting}
            phx-click="set_oauth"
            phx-value-state={if @oauth_setting, do: "off", else: "on"}
            phx-target={@myself}
          />
        </div>

        <div id="api-oauth-dcr-row" class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <h3 id="api-oauth-dcr-title" class="font-medium">
              {gettext("Self-registration of applications")}
            </h3>
            <p id="api-oauth-dcr-text" class="text-sm text-base-content/70">
              {gettext(
                "Lets programs register themselves (Claude Code, MCP Inspector). Off by default. Applications that name themselves by a metadata document, as Claude and ChatGPT do, do not need it."
              )}
            </p>
          </div>
          <.checkbox
            id="api-oauth-dcr"
            name="api-oauth-dcr"
            variant="toggle"
            class="toggle-lg"
            wrapper_class="shrink-0 flex-row-reverse"
            label={if @status.dcr_enabled, do: gettext("Enabled"), else: gettext("Disabled")}
            aria-labelledby="api-oauth-dcr-title"
            aria-describedby="api-oauth-dcr-text"
            checked={@dcr_setting}
            phx-click="set_dcr"
            phx-value-state={if @dcr_setting, do: "off", else: "on"}
            phx-target={@myself}
          />
        </div>
      </.form_section>

      <%!-- Status and addresses --%>
      <.form_section
        id="api-oauth-status"
        title={gettext("Status and addresses")}
        icon="hero-signal"
        class="border border-base-200"
        body_class="space-y-4"
      >
        <div
          :for={warning <- @status.warnings}
          id={"api-oauth-warning-#{warning}"}
          role="note"
          class="alert alert-warning text-sm"
        >
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
          <span>{warning_text(warning)}</span>
        </div>

        <dl class="grid grid-cols-1 sm:grid-cols-[14rem_1fr] gap-x-4 gap-y-2 text-sm">
          <%= for {id, url} <- @status.urls do %>
            <dt class="font-medium">{url_label(id)}</dt>
            <dd>
              <code id={"api-oauth-url-#{id}"} class="font-mono break-all">{url}</code>
              <span
                :if={id == :registration and not @status.dcr_enabled}
                class="badge badge-ghost badge-sm ml-2"
              >
                {gettext("Disabled")}
              </span>
            </dd>
          <% end %>
        </dl>
        <p id="api-oauth-urls-note" class="text-sm text-base-content/70">
          {gettext(
            "These addresses answer without a key, and only while OAuth is on. An application that cannot open them cannot connect."
          )}
        </p>
      </.form_section>

      <%!-- Settings --%>
      <.form_section
        id="api-oauth-settings-card"
        title={gettext("OAuth settings")}
        icon="hero-adjustments-horizontal"
        class="border border-base-200"
        body_class="space-y-4"
      >
        <:subtitle>
          {gettext(
            "How long a connection lasts is chosen by the person, up to the longest life of a personal key. Every change is kept in the history of the settings."
          )}
        </:subtitle>

        <form
          id="api-oauth-settings-form"
          phx-submit="save_settings"
          phx-target={@myself}
          class="space-y-4"
        >
          <div
            :if={@settings_errors != []}
            id="api-oauth-settings-errors"
            class="alert alert-error text-sm"
          >
            <ul class="list-disc pl-4">
              <li :for={message <- @settings_errors}>{message}</li>
            </ul>
          </div>

          <div class="grid grid-cols-1 items-end gap-4 md:grid-cols-2">
            <.input
              id="api-oauth-access-ttl"
              name="oauth[access_ttl_seconds]"
              type="text"
              inputmode="numeric"
              wrap_label
              label={gettext("Access token life, in seconds (300 to 86400)")}
              value={@settings_params["access_ttl_seconds"]}
            />
            <.input
              id="api-oauth-grants-per-person"
              name="oauth[grants_per_person]"
              type="text"
              inputmode="numeric"
              wrap_label
              label={gettext("Connections one person may have (1 to 100)")}
              value={@settings_params["grants_per_person"]}
            />
          </div>

          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <.select
              id="api-oauth-client-policy"
              name="oauth[client_policy]"
              wrap_label
              label={gettext("Which applications may connect")}
              value={@settings_params["client_policy"]}
              options={policy_options()}
            />
            <.textarea
              id="api-oauth-allow-hosts"
              name="oauth[allow_hosts]"
              rows="3"
              spellcheck="false"
              class="font-mono text-sm"
              wrap_label
              label={gettext("Allowed hosts (one per line)")}
              hint={
                gettext(
                  "For example claude.ai. Judged on the host of the application's address and of each redirect address; an application added by hand below is always allowed."
                )
              }
              value={@settings_params["allow_hosts"]}
            />
          </div>

          <details id="api-oauth-limits" class="collapse collapse-arrow border border-base-200">
            <summary class="collapse-title text-sm font-medium">
              {gettext("Limits of the public OAuth addresses")}
            </summary>
            <div class="collapse-content grid grid-cols-1 items-end gap-4 md:grid-cols-2">
              <.input
                id="api-oauth-authorize-per-min"
                name="oauth[authorize_per_min]"
                type="text"
                inputmode="numeric"
                wrap_label
                label={gettext("Authorization requests per minute, per address")}
                value={@settings_params["authorize_per_min"]}
              />
              <.input
                id="api-oauth-token-per-min"
                name="oauth[token_per_min]"
                type="text"
                inputmode="numeric"
                wrap_label
                label={gettext("Token requests per minute, per address")}
                value={@settings_params["token_per_min"]}
              />
              <.input
                id="api-oauth-requests-ceiling"
                name="oauth[requests_ceiling]"
                type="text"
                inputmode="numeric"
                wrap_label
                label={gettext("Authorization requests waiting for an answer, in all")}
                value={@settings_params["requests_ceiling"]}
              />
              <.input
                id="api-oauth-cimd-per-min"
                name="oauth[cimd_per_min]"
                type="text"
                inputmode="numeric"
                wrap_label
                label={gettext("Metadata document downloads per minute, per address")}
                value={@settings_params["cimd_per_min"]}
              />
              <.input
                id="api-oauth-cimd-client-per-min"
                name="oauth[cimd_client_per_min]"
                type="text"
                inputmode="numeric"
                wrap_label
                label={gettext("Metadata document downloads per minute, per application")}
                value={@settings_params["cimd_client_per_min"]}
              />
              <.input
                id="api-oauth-register-per-hour"
                name="oauth[register_per_hour]"
                type="text"
                inputmode="numeric"
                wrap_label
                label={gettext("Registrations per hour, per address")}
                value={@settings_params["register_per_hour"]}
              />
              <.input
                id="api-oauth-register-per-day"
                name="oauth[register_per_day]"
                type="text"
                inputmode="numeric"
                wrap_label
                label={gettext("Registrations per day, in all")}
                value={@settings_params["register_per_day"]}
              />
            </div>
          </details>

          <div class="flex justify-end">
            <.button type="submit" id="api-oauth-settings-submit">
              {gettext("Save the settings")}
            </.button>
          </div>
        </form>
      </.form_section>

      <%!-- Clients --%>
      <.form_section
        id="api-oauth-clients-card"
        title={gettext("Known applications")}
        icon="hero-squares-2x2"
        class="border border-base-200"
        body_class="space-y-4"
      >
        <:subtitle>
          {gettext(
            "Applications that connected or registered, and those you add by hand. Removing one ends every connection it has."
          )}
        </:subtitle>

        <div :if={@clients != []} id="api-oauth-clients-table">
          <.table_default>
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell>{gettext("Application")}</.table_default_header_cell>
                <.table_default_header_cell>
                  {gettext("How it became known")}
                </.table_default_header_cell>
                <.table_default_header_cell>{gettext("Connections")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Actions")}</.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <.table_default_row :for={row <- @clients} id={"api-oauth-client-#{row.client.uuid}"}>
                <.table_default_cell>
                  <div class="font-medium">{client_name(row.client)}</div>
                  <div class="font-mono text-xs text-base-content/60 break-all">
                    {row.client.client_id}
                  </div>
                  <div class="font-mono text-xs text-base-content/60">
                    {Enum.join(redirect_hosts(row.client), ", ")}
                  </div>
                </.table_default_cell>
                <.table_default_cell class="text-sm">{kind_label(row.client)}</.table_default_cell>
                <.table_default_cell class="text-sm">{row.grants}</.table_default_cell>
                <.table_default_cell>
                  <.button
                    id={"api-oauth-client-remove-#{row.client.uuid}"}
                    type="button"
                    variant="outline"
                    size="xs"
                    phx-click="request_delete_client"
                    phx-value-uuid={row.client.uuid}
                    phx-target={@myself}
                  >
                    {gettext("Remove")}
                  </.button>
                </.table_default_cell>
              </.table_default_row>
            </.table_default_body>
          </.table_default>
        </div>

        <div :if={@clients == []} id="api-oauth-clients-empty">
          <.empty_state
            variant="compact"
            icon="hero-squares-2x2"
            title={gettext("No application is known yet.")}
          />
        </div>

        <form
          id="api-oauth-client-form"
          phx-submit="add_client"
          phx-target={@myself}
          class="space-y-4 border-t border-base-200 pt-4"
        >
          <h3 class="font-medium">{gettext("Add an application by hand")}</h3>

          <div
            :if={@client_errors != []}
            id="api-oauth-client-errors"
            class="alert alert-error text-sm"
          >
            <ul class="list-disc pl-4">
              <li :for={message <- @client_errors}>{message}</li>
            </ul>
          </div>

          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <.input
              id="api-oauth-client-id"
              name="client[client_id]"
              type="text"
              wrap_label
              label={gettext("Client ID")}
              value={@client_params["client_id"]}
            />
            <.input
              id="api-oauth-client-name"
              name="client[client_name]"
              type="text"
              wrap_label
              label={gettext("Name shown to the person")}
              value={@client_params["client_name"]}
            />
          </div>
          <.textarea
            id="api-oauth-client-redirects"
            name="client[redirect_uris]"
            rows="3"
            spellcheck="false"
            class="font-mono text-sm"
            wrap_label
            label={gettext("Redirect addresses (one per line)")}
            hint={
              gettext(
                "Where the application receives the answer: https, or http to 127.0.0.1 or [::1]. Compared exactly (a loopback port may differ)."
              )
            }
            value={@client_params["redirect_uris"]}
          />
          <div class="flex justify-end">
            <.button type="submit" id="api-oauth-client-submit">{gettext("Add")}</.button>
          </div>
        </form>
      </.form_section>

      <%!-- Every connection, for an Owner --%>
      <.live_component
        :if={@owner?}
        module={ConnectedApps}
        id="api-oauth-connected-apps"
        scope={@scope}
        impersonated={@impersonated}
        mode={:all}
      />

      <.modal
        show={@delete_confirmation.show}
        on_close="cancel_delete_client"
        id="api-oauth-client-delete-modal"
        max_width="md"
      >
        <:title>
          <.icon name="hero-trash" class="w-5 h-5 text-error" /> {gettext("Remove this application?")}
        </:title>

        <p :if={@delete_confirmation[:name]} class="font-medium break-all">
          {@delete_confirmation[:name]}
        </p>
        <div class="alert alert-warning text-sm mt-2">
          {gettext(
            "Every connection of this application ends at once and it has to ask for access again. An application that names itself by a metadata document is known again when it is used."
          )}
        </div>

        <:actions>
          <.button type="button" variant="ghost" phx-click="cancel_delete_client" phx-target={@myself}>
            {gettext("Cancel")}
          </.button>
          <.button
            type="button"
            variant="error"
            id="api-oauth-client-delete-confirm"
            phx-click="confirm_delete_client"
            phx-target={@myself}
          >
            {gettext("Remove")}
          </.button>
        </:actions>
      </.modal>
    </div>
    """
  end
end
