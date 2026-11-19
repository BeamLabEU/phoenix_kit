defmodule PhoenixKitWeb.Live.Components.ConnectedApps do
  @moduledoc """
  "Connected apps": the applications a person let act with their rights by signing in (OAuth,
  `PhoenixKit.API.OAuth`), with the button that ends a connection. A LiveComponent used inside
  `PhoenixKitWeb.Live.Components.PersonalApiKeys` (so "My API keys" and the `:api_keys` section of
  `PhoenixKitWeb.Live.Components.UserSettings` both show it) and, in the `:all` view, on the OAuth
  tab of Settings -> API.

  ## Contract

  The own view shows nothing while OAuth is off and the person has no connection (an install
  that does not use OAuth is not cluttered with an empty card).

  Required assigns: `id`, `scope` (the session's `PhoenixKit.Users.Auth.Scope`) and
  `impersonated` (a boolean: whether the session is borrowed, read with
  `PhoenixKitWeb.Users.MultiSession.impersonated?/1`). Optional: `mode`, `:own` (default, the
  person's own connections) or `:all` (every connection, an Owner's view); `refresh`, any value:
  the list is read again each time it changes (a parent that ended connections some other way
  bumps it); `notify`, `{module, id}` of a LiveComponent that shows the same grants: it is sent
  an update (`refresh: true`) each time a connection was ended here, so its counts follow. A
  component without a usable `scope` or boolean `impersonated` shows nothing and refuses every
  event.

  ## Rights are checked on every render and every event

  The list is read with a scope built from the database each time the component is updated, not
  with the scope captured at mount: a person who lost the right sees no rows, and an Owner who is
  none any more does not keep seeing everybody's connections (the `:all` view needs the Owner
  role of that fresh scope).

  Ending a connection first re-reads the person's rights from the database
  (`PhoenixKit.API.Access.fresh_scope/2`: `api_personal_keys` or `api` for the own view, `api` for
  the all view), refuses a borrowed session, and hands the **fresh** scope to
  `PhoenixKit.API.OAuth.Connections.revoke/3`, which finds the connection inside the view and
  authorizes again. The uuid of the connection to end is the one the server stored when the dialog
  opened, never a param of the confirming event. A person who lost the right in the meantime sees
  an error and an empty list (what a page opened now would show), and nothing is ended.

  A grant is not removed when its owner loses the right: it is listed as "No permission" and does
  not work (every request reads the owner's rights again) until the right comes back.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.API.Access
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.Connections
  alias PhoenixKit.API.OAuth.RedirectUri
  alias PhoenixKit.API.Registry
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @own_permissions ["api_personal_keys", "api"]

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:scope, Map.get(assigns, :scope, socket.assigns[:scope]))
      |> assign(:impersonated, Map.get(assigns, :impersonated, socket.assigns[:impersonated]))
      |> assign(:mode, Map.get(assigns, :mode, socket.assigns[:mode] || :own))
      |> assign(:notify, Map.get(assigns, :notify, socket.assigns[:notify]))
      |> assign_new(:message, fn -> nil end)
      |> assign_new(:revoke_confirmation, fn -> %{show: false} end)

    {:ok, socket |> assign(:usable, usable?(socket.assigns)) |> load_fresh()}
  end

  defp usable?(%{scope: %Scope{user: %User{}}, impersonated: impersonated, mode: mode})
       when is_boolean(impersonated) and mode in [:own, :all],
       do: true

  defp usable?(_assigns), do: false

  # Every render reads the person's rights again (as an event does): a list is never made from the
  # scope captured at mount, so a person who lost the right, or an Owner who is none any more, is
  # shown what a page opened now would show.
  defp load_fresh(%{assigns: %{usable: true, scope: scope, mode: mode}} = socket) do
    case fresh_scope(scope, mode) do
      {:ok, fresh} -> load(socket, fresh)
      :error -> socket |> assign(:oauth_enabled, Config.oauth_enabled?()) |> no_rows()
    end
  end

  defp load_fresh(socket), do: load(socket, nil)

  defp load(%{assigns: %{usable: true, mode: mode}} = socket, scope) do
    rows = Connections.list(scope, mode)

    socket
    |> assign(:rows, rows)
    |> assign(:scope_tools, scope_tools(rows))
    |> assign(:oauth_enabled, Config.oauth_enabled?())
    |> assign(:truncated, length(rows) >= Connections.limit())
  end

  defp load(socket, _scope) do
    socket
    |> assign(:rows, [])
    |> assign(:scope_tools, %{})
    |> assign(:oauth_enabled, true)
    |> assign(:truncated, false)
  end

  # A person whose right is gone is shown what a page opened now would show: no connection.
  defp no_rows(socket) do
    socket |> assign(:rows, []) |> assign(:scope_tools, %{}) |> assign(:truncated, false)
  end

  # Tells the component that shows the same grants (`notify`, `{module, id}`) to read them again.
  defp notify(%{assigns: %{notify: {module, id}}}) when is_atom(module) and is_binary(id),
    do: send_update(module, id: id, refresh: true)

  defp notify(_socket), do: :ok

  # Scope -> names of the tools it unlocks, for the hint on each badge.
  defp scope_tools([]), do: %{}

  defp scope_tools(rows) do
    scopes = rows |> Enum.flat_map(& &1.grant.scopes) |> Enum.uniq()

    Registry.all_tools()
    |> Enum.filter(&(&1.audience == :admin and &1.scope in scopes))
    |> Enum.group_by(& &1.scope, & &1.name)
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("request_revoke", %{"uuid" => uuid}, socket) do
    with_access(
      socket,
      fn socket ->
        case Enum.find(socket.assigns.rows, &(&1.grant.uuid == uuid)) do
          nil ->
            not_found(socket)

          row ->
            assign(socket, :revoke_confirmation, %{
              show: true,
              uuid: row.grant.uuid,
              name: app_name(row),
              person: person(socket, row)
            })
        end
      end,
      clear_message: true
    )
  end

  def handle_event("cancel_revoke", _params, socket) do
    {:noreply, assign(socket, :revoke_confirmation, %{show: false})}
  end

  def handle_event("confirm_revoke", _params, socket) do
    with_access(socket, fn socket ->
      uuid = Map.get(socket.assigns.revoke_confirmation, :uuid)
      socket = assign(socket, :revoke_confirmation, %{show: false})

      if uuid, do: revoke(socket, uuid), else: socket
    end)
  end

  def handle_event(_event, _params, socket) do
    {:noreply, error(socket, gettext("That action is not available."))}
  end

  # A confirm with no dialog open (a second click, a replayed event) does nothing at all.
  defp revoke(socket, uuid) do
    case Connections.revoke(socket.assigns.fresh_scope, uuid, socket.assigns.mode) do
      {:ok, _grant} ->
        notify(socket)
        info(socket, gettext("The connection was ended. The application stops working at once."))

      {:error, :forbidden} ->
        error(socket, gettext("You are not allowed to do that."))

      {:error, :not_found} ->
        not_found(socket)

      _other ->
        error(socket, gettext("The connection could not be ended."))
    end
  end

  # Every event that opens a dialog or ends something goes through here: the context must be
  # complete, the session must not be borrowed, and the person's rights are read again for THIS
  # event; the list is read again with the fresh scope. A refusal closes the dialog, or the
  # message would stay behind the backdrop.
  defp with_access(socket, fun, opts \\ []) do
    %{usable: usable, scope: scope, impersonated: impersonated, mode: mode} = socket.assigns

    cond do
      not usable ->
        {:noreply, deny(socket, gettext("You are not allowed to do that."))}

      impersonated ->
        {:noreply,
         deny(socket, gettext("Connections cannot be changed while you act in another account."))}

      true ->
        case fresh_scope(scope, mode) do
          {:ok, fresh} ->
            socket = assign(socket, :fresh_scope, fresh)
            socket = if opts[:clear_message], do: assign(socket, :message, nil), else: socket
            socket = socket |> fun.() |> then(&load(&1, fresh))
            {:noreply, socket}

          :error ->
            {:noreply, socket |> deny(gettext("You are not allowed to do that.")) |> no_rows()}
        end
    end
  end

  # The all-view is an Owner's: an Owner downgraded to Admin still holds `api`, so the role is
  # asked of the fresh scope too, before a dialog for someone else's connection opens.
  defp fresh_scope(scope, :own), do: Access.fresh_scope(scope, @own_permissions)

  defp fresh_scope(scope, :all) do
    with {:ok, fresh} <- Access.fresh_scope(scope, ["api"]),
         true <- Scope.owner?(fresh) do
      {:ok, fresh}
    else
      _ -> :error
    end
  end

  defp deny(socket, text),
    do: socket |> assign(:revoke_confirmation, %{show: false}) |> error(text)

  defp not_found(socket), do: error(socket, gettext("That connection was not found."))
  defp error(socket, text), do: assign(socket, :message, {:error, text})
  defp info(socket, text), do: assign(socket, :message, {:info, text})

  # ── Template helpers ───────────────────────────────────────────────

  # The name the person agreed to (pinned in the grant's key), else the client's own now.
  defp app_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp app_name(%{client: client}), do: client_name(client)

  defp client_name(%{client_name: name}) when is_binary(name) and name != "", do: name
  defp client_name(%{client_id: client_id}), do: client_id

  defp hosts(client) do
    client.redirect_uris |> Enum.map(&RedirectUri.host/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp person(%{assigns: %{mode: :all}}, row), do: row.owner.email
  defp person(_socket, _row), do: nil

  defp date(datetime, user), do: UtilsDate.format_date_with_user_timezone(datetime, user)

  defp badge_name(:active), do: "active"
  defp badge_name(_status), do: "suspended"

  defp status_label(:active), do: gettext("Active")
  defp status_label(:no_permission), do: gettext("No permission")
  defp status_label(:owner_inactive), do: gettext("Account inactive")
  defp status_label(:wrong_resource), do: gettext("Site address changed")

  defp message_role(:error), do: "alert"
  defp message_role(:info), do: "status"

  defp alert_class(:error), do: "alert alert-error text-sm"
  defp alert_class(:info), do: "alert alert-success text-sm"

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-4">
      <%= if @usable and (@mode == :all or @oauth_enabled or @rows != [] or @message != nil) do %>
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

        <div :if={@impersonated} id={"#{@id}-impersonated"} class="alert alert-warning text-sm">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
          <span>
            {gettext(
              "You are acting in another account, so connections are shown but cannot be ended here."
            )}
          </span>
        </div>

        <div :if={not @oauth_enabled} id={"#{@id}-oauth-off"} class="alert alert-warning text-sm">
          <.icon name="hero-power" class="w-5 h-5 shrink-0" />
          <span>
            {gettext("OAuth is switched off by an administrator. These connections do not work now.")}
          </span>
        </div>

        <.form_section
          id={"#{@id}-card"}
          title={gettext("Connected apps")}
          icon="hero-link"
          class="border border-base-200"
          body_class="space-y-4"
        >
          <:subtitle>
            {gettext(
              "Applications you let act with your rights after a sign-in, such as an AI assistant. A connection never has more rights than you, and stops working at once when you lose them."
            )}
          </:subtitle>

          <div :if={@rows != []} id={"#{@id}-table"}>
            <.table_default>
              <.table_default_header>
                <.table_default_row>
                  <.table_default_header_cell>{gettext("Application")}</.table_default_header_cell>
                  <.table_default_header_cell :if={@mode == :all}>
                    {gettext("Person")}
                  </.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Scopes")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Connected")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Last used")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Expires on")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Actions")}</.table_default_header_cell>
                </.table_default_row>
              </.table_default_header>

              <.table_default_body>
                <.table_default_row :for={row <- @rows} id={"#{@id}-grant-#{row.grant.uuid}"}>
                  <.table_default_cell>
                    <div class="font-medium">{app_name(row)}</div>
                    <div class="font-mono text-xs text-base-content/60">
                      {Enum.join(hosts(row.client), ", ")}
                    </div>
                  </.table_default_cell>
                  <.table_default_cell :if={@mode == :all} class="text-sm">
                    {row.owner.email}
                  </.table_default_cell>
                  <.table_default_cell>
                    <div class="flex flex-wrap gap-1 max-w-xs">
                      <span
                        :for={scope <- Enum.take(row.grant.scopes, 3)}
                        class="badge badge-ghost badge-xs font-mono"
                        title={Enum.join(Map.get(@scope_tools, scope, []), ", ")}
                      >
                        {scope}
                      </span>
                      <span
                        :if={length(row.grant.scopes) > 3}
                        class="badge badge-ghost badge-xs"
                        title={
                          row.grant.scopes
                          |> Enum.drop(3)
                          |> Enum.flat_map(&Map.get(@scope_tools, &1, []))
                          |> Enum.join(", ")
                        }
                      >
                        +{length(row.grant.scopes) - 3}
                      </span>
                    </div>
                  </.table_default_cell>
                  <.table_default_cell>
                    <span id={"#{@id}-status-#{row.grant.uuid}"} data-status={row.status}>
                      <.status_badge
                        status={badge_name(row.status)}
                        label={status_label(row.status)}
                      />
                    </span>
                    <div
                      :if={row.status == :no_permission}
                      id={"#{@id}-no-permission-#{row.grant.uuid}"}
                      class="text-xs text-base-content/60 mt-0.5 max-w-xs"
                    >
                      {gettext(
                        "The owner no longer holds the right to API keys: this connection does not work until they hold it again."
                      )}
                    </div>
                  </.table_default_cell>
                  <.table_default_cell class="text-sm">
                    {date(row.grant.inserted_at, @scope.user)}
                  </.table_default_cell>
                  <.table_default_cell>
                    <%= if row.grant.last_used_at do %>
                      <.time_ago
                        datetime={row.grant.last_used_at}
                        id={"#{@id}-used-#{row.grant.uuid}"}
                      />
                    <% else %>
                      <span class="text-xs text-base-content/40">{gettext("Never")}</span>
                    <% end %>
                  </.table_default_cell>
                  <.table_default_cell class="text-sm">
                    {date(row.grant.expires_at, @scope.user)}
                  </.table_default_cell>
                  <.table_default_cell>
                    <.button
                      :if={not @impersonated}
                      id={"#{@id}-revoke-#{row.grant.uuid}"}
                      type="button"
                      variant="outline"
                      size="xs"
                      aria-label={gettext("Disconnect %{name}", name: app_name(row))}
                      phx-click="request_revoke"
                      phx-value-uuid={row.grant.uuid}
                      phx-target={@myself}
                    >
                      {gettext("Disconnect")}
                    </.button>
                  </.table_default_cell>
                </.table_default_row>
              </.table_default_body>
            </.table_default>
          </div>

          <p :if={@truncated} id={"#{@id}-truncated"} class="text-sm text-base-content/70">
            {gettext("Only the newest %{count} are shown.", count: Connections.limit())}
          </p>

          <div :if={@rows == []} id={"#{@id}-empty"}>
            <.empty_state
              variant="compact"
              icon="hero-link"
              title={gettext("No application is connected.")}
              description={
                gettext("Add the server's address in the application, then sign in and allow access.")
              }
            />
          </div>
        </.form_section>

        <.modal
          show={@revoke_confirmation.show}
          on_close="cancel_revoke"
          id={"#{@id}-revoke-modal"}
          max_width="md"
        >
          <:title>
            <.icon name="hero-no-symbol" class="w-5 h-5 text-error" /> {gettext(
              "Disconnect this application?"
            )}
          </:title>

          <p :if={@revoke_confirmation[:name]} class="font-medium">
            {@revoke_confirmation[:name]}
          </p>
          <p :if={@revoke_confirmation[:person]} class="text-sm text-base-content/70">
            {@revoke_confirmation[:person]}
          </p>
          <div class="alert alert-warning text-sm mt-2">
            {gettext(
              "The application stops working at once and has to ask for access again. This cannot be undone."
            )}
          </div>

          <:actions>
            <.button type="button" variant="ghost" phx-click="cancel_revoke" phx-target={@myself}>
              {gettext("Cancel")}
            </.button>
            <.button
              type="button"
              variant="error"
              id={"#{@id}-revoke-confirm"}
              phx-click="confirm_revoke"
              phx-target={@myself}
            >
              {gettext("Disconnect")}
            </.button>
          </:actions>
        </.modal>
      <% end %>
    </div>
    """
  end
end
