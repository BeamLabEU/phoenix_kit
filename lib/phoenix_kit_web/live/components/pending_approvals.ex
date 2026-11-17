defmodule PhoenixKitWeb.Live.Components.PendingApprovals do
  @moduledoc """
  "Waiting for approval": the connections of applications that are not on the list of trusted
  ones (`PhoenixKit.API.OAuth.ClientPolicy`), which a person let in at the consent screen and
  which run nothing until an Owner approves them
  (`PhoenixKit.API.OAuth.Grants.approve/2`) or rejects them
  (`PhoenixKit.API.OAuth.Connections.reject/2`). A LiveComponent on the OAuth tab of Settings ->
  API, for an Owner; it is not part of `PhoenixKitWeb.Live.Components.ConnectedApps`, which lists
  every live connection.

  Each row says which application asks (its name, marked as not verified, the host of its
  metadata document when it has one, the hosts its answers go to), whose account it is, the
  rights it was given (reading and changing, by module), when and from which address.

  ## Contract

  Required assigns: `id`, `scope` (the session's `PhoenixKit.Users.Auth.Scope`) and
  `impersonated` (a boolean: whether the session is borrowed). Optional: `refresh`, any value:
  the list is read again each time it changes; `notify`, `{module, id}` of a LiveComponent that
  shows what a decision changes (the status count, the list of every connection): it is sent an
  update (`refresh: true`) after each decision. A component without a usable `scope` or boolean
  `impersonated` shows nothing and refuses every event.

  ## Rights are checked on every render and every event

  The list is read with a scope built from the database each time the component is updated, and
  it is an Owner's who holds `api`: anyone else sees no row. A decision first re-reads the rights
  (`PhoenixKit.API.Access.fresh_scope/2`), refuses a borrowed session, and hands the **fresh**
  scope to the function that decides, which checks the Owner right again and acts only on a
  connection that still waits. The uuid of the connection is the one the server stored when the
  confirmation dialog opened, never a param of the confirming event, and the dialog is how
  both decisions are taken: nothing is approved or rejected by one click.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.API.Access
  alias PhoenixKit.API.OAuth.Connections
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.RedirectUri
  alias PhoenixKit.API.OAuth.Scopes
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitWeb.Live.Settings.Api

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:scope, Map.get(assigns, :scope, socket.assigns[:scope]))
      |> assign(:impersonated, Map.get(assigns, :impersonated, socket.assigns[:impersonated]))
      |> assign(:notify, Map.get(assigns, :notify, socket.assigns[:notify]))
      |> assign_new(:message, fn -> nil end)
      |> assign_new(:confirmation, fn -> %{show: false} end)

    {:ok, socket |> assign(:usable, usable?(socket.assigns)) |> load_fresh()}
  end

  defp usable?(%{scope: %Scope{user: %User{}}, impersonated: impersonated})
       when is_boolean(impersonated),
       do: true

  defp usable?(_assigns), do: false

  # Every render reads the person's rights again, as an event does: the list is never made from
  # the scope captured at mount.
  defp load_fresh(%{assigns: %{usable: true, scope: scope}} = socket) do
    case fresh_scope(scope) do
      {:ok, fresh} -> load(socket, fresh)
      :error -> no_rows(socket)
    end
  end

  defp load_fresh(socket), do: no_rows(socket)

  defp load(socket, fresh) do
    rows = Connections.list_pending(fresh)

    socket
    |> assign(:rows, rows)
    |> assign(:rights, rights(rows))
    |> assign(:truncated, length(rows) >= Connections.limit())
  end

  defp no_rows(socket) do
    socket |> assign(:rows, []) |> assign(:rights, %{}) |> assign(:truncated, false)
  end

  # The rights of each grant by module: `%{grant_uuid => [%{key, label, reads, writes}]}`, built
  # from one description of every scope in the list.
  defp rights([]), do: %{}

  defp rights(rows) do
    entries = rows |> Enum.flat_map(& &1.grant.scopes) |> Enum.uniq() |> Scopes.describe()

    Map.new(rows, fn %{grant: grant} ->
      sections =
        entries
        |> Enum.filter(&(&1.scope in grant.scopes))
        |> Enum.chunk_by(& &1.module_key)
        |> Enum.map(fn [first | _] = module_entries ->
          {reads, writes} = Enum.split_with(module_entries, & &1.read?)

          %{
            key: first.module_key,
            label: Api.module_label(%{key: first.module_key, name: first.module_name}),
            reads: reads,
            writes: writes
          }
        end)

      {grant.uuid, sections}
    end)
  end

  # Tells the component that shows what a decision changes to read it again.
  defp notify(%{assigns: %{notify: {module, id}}}) when is_atom(module) and is_binary(id),
    do: send_update(module, id: id, refresh: true)

  defp notify(_socket), do: :ok

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("request_approve", %{"uuid" => uuid}, socket),
    do: request(socket, :approve, uuid)

  def handle_event("request_reject", %{"uuid" => uuid}, socket),
    do: request(socket, :reject, uuid)

  def handle_event("cancel_decision", _params, socket) do
    {:noreply, assign(socket, :confirmation, %{show: false})}
  end

  def handle_event("confirm_decision", _params, socket) do
    with_access(socket, fn socket ->
      confirmation = socket.assigns.confirmation
      socket = assign(socket, :confirmation, %{show: false})

      case confirmation do
        %{uuid: uuid, action: action} -> decide(socket, action, uuid)
        _no_dialog -> socket
      end
    end)
  end

  def handle_event(_event, _params, socket) do
    {:noreply, error(socket, gettext("That action is not available."))}
  end

  defp request(socket, action, uuid) do
    with_access(
      socket,
      fn socket ->
        case Enum.find(socket.assigns.rows, &(&1.grant.uuid == uuid)) do
          nil ->
            error(socket, not_waiting_text())

          row ->
            assign(socket, :confirmation, %{
              show: true,
              action: action,
              uuid: row.grant.uuid,
              name: app_name(row),
              person: row.owner.email
            })
        end
      end,
      clear_message: true
    )
  end

  # A confirm with no dialog open (a second click, a replayed event) does nothing at all.
  defp decide(socket, :approve, uuid) do
    case Grants.approve(socket.assigns.fresh_scope, uuid) do
      {:ok, _grant} ->
        notify(socket)

        info(
          socket,
          gettext(
            "The connection was approved. The application works now, with no need to connect again."
          )
        )

      {:error, :forbidden} ->
        error(socket, not_allowed_text())

      {:error, reason} when reason in [:not_pending, :not_found] ->
        error(socket, not_waiting_text())

      _other ->
        error(socket, gettext("The connection could not be approved."))
    end
  end

  defp decide(socket, :reject, uuid) do
    case Connections.reject(socket.assigns.fresh_scope, uuid) do
      {:ok, _grant} ->
        notify(socket)
        info(socket, gettext("The connection was rejected. The application stops at once."))

      {:error, :forbidden} ->
        error(socket, not_allowed_text())

      {:error, :not_found} ->
        error(socket, not_waiting_text())

      _other ->
        error(socket, gettext("The connection could not be rejected."))
    end
  end

  # Every event that opens the dialog or decides goes through here: the context must be complete,
  # the session must not be borrowed, and the Owner's rights are read again for THIS event; the
  # list is read again with the fresh scope. A refusal closes the dialog, or the message would
  # stay behind the backdrop.
  defp with_access(socket, fun, opts \\ []) do
    %{usable: usable, scope: scope, impersonated: impersonated} = socket.assigns

    cond do
      not usable ->
        {:noreply, deny(socket, not_allowed_text())}

      impersonated ->
        {:noreply,
         deny(socket, gettext("Connections cannot be changed while you act in another account."))}

      true ->
        case fresh_scope(scope) do
          {:ok, fresh} ->
            socket = assign(socket, :fresh_scope, fresh)
            socket = if opts[:clear_message], do: assign(socket, :message, nil), else: socket
            {:noreply, socket |> fun.() |> then(&load(&1, fresh))}

          :error ->
            {:noreply, socket |> deny(not_allowed_text()) |> no_rows()}
        end
    end
  end

  # An Owner who holds `api`; the role is asked of the fresh scope too, so an Owner downgraded to
  # Admin (who still holds `api`) is not one any more.
  defp fresh_scope(scope) do
    with {:ok, fresh} <- Access.fresh_scope(scope, ["api"]),
         true <- Scope.owner?(fresh) do
      {:ok, fresh}
    else
      _ -> :error
    end
  end

  defp deny(socket, text), do: socket |> assign(:confirmation, %{show: false}) |> error(text)

  defp not_allowed_text, do: gettext("You are not allowed to do that.")
  defp not_waiting_text, do: gettext("That connection is not waiting for approval any more.")
  defp error(socket, text), do: assign(socket, :message, {:error, text})
  defp info(socket, text), do: assign(socket, :message, {:info, text})

  # ── Template helpers ───────────────────────────────────────────────

  # The name the person agreed to (pinned in the grant's key), else the client's own now.
  defp app_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp app_name(%{client: client}), do: client_name(client)

  defp client_name(%{client_name: name}) when is_binary(name) and name != "", do: name
  defp client_name(%{client_id: client_id}), do: client_id

  defp redirect_hosts(client) do
    client.redirect_uris |> Enum.map(&RedirectUri.host/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  # An application that names itself by a metadata document lives at the host of that address.
  defp described_at(%{kind: "cimd", client_id: client_id}) when is_binary(client_id) do
    case URI.parse(client_id) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> nil
    end
  end

  defp described_at(_client), do: nil

  defp date(datetime, user), do: UtilsDate.format_date_with_user_timezone(datetime, user)

  defp message_role(:error), do: "alert"
  defp message_role(:info), do: "status"

  defp alert_class(:error), do: "alert alert-error text-sm"
  defp alert_class(:info), do: "alert alert-success text-sm"

  defp right_label(%{read?: true, resource: resource}),
    do: gettext("Read: %{resource}", resource: resource)

  defp right_label(%{resource: resource, action: action}),
    do: gettext("Change: %{resource} (%{action})", resource: resource, action: action)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-4">
      <%= if @usable do %>
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

        <.form_section
          id={"#{@id}-card"}
          title={gettext("Waiting for approval")}
          icon="hero-clock"
          class="border border-base-200"
          body_class="space-y-4"
        >
          <:subtitle>
            {gettext(
              "Applications that are not on the list of trusted ones. A person signed in and allowed them access, but nothing runs on the connection until an Owner approves it. A connection nobody decides on ends after %{days} days.",
              days: Grants.approval_days()
            )}
          </:subtitle>
          <:actions>
            <span
              :if={@rows != []}
              id={"#{@id}-count"}
              class="badge badge-warning"
              aria-label={gettext("Connections waiting: %{count}", count: length(@rows))}
            >
              {length(@rows)}
            </span>
          </:actions>

          <div :if={@rows != []} id={"#{@id}-table"}>
            <.table_default>
              <.table_default_header>
                <.table_default_row>
                  <.table_default_header_cell>{gettext("Application")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Person")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Scopes")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Connected")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Actions")}</.table_default_header_cell>
                </.table_default_row>
              </.table_default_header>

              <.table_default_body>
                <.table_default_row :for={row <- @rows} id={"#{@id}-grant-#{row.grant.uuid}"}>
                  <.table_default_cell>
                    <div class="font-medium break-all">{app_name(row)}</div>
                    <div
                      id={"#{@id}-unverified-#{row.grant.uuid}"}
                      class="text-xs text-warning"
                    >
                      {gettext("The name is the application's own and has not been checked.")}
                    </div>
                    <div
                      :if={described_at(row.client)}
                      id={"#{@id}-described-#{row.grant.uuid}"}
                      class="text-xs text-base-content/60 break-all"
                    >
                      {gettext("The application is described at %{address}",
                        address: described_at(row.client)
                      )}
                    </div>
                    <div
                      id={"#{@id}-hosts-#{row.grant.uuid}"}
                      class="font-mono text-xs text-base-content/60 break-all"
                    >
                      {Enum.join(redirect_hosts(row.client), ", ")}
                    </div>
                  </.table_default_cell>
                  <.table_default_cell class="text-sm break-all">
                    {row.owner.email}
                  </.table_default_cell>
                  <.table_default_cell>
                    <div
                      :for={section <- Map.get(@rights, row.grant.uuid, [])}
                      class="mb-1"
                    >
                      <div class="text-xs font-medium">{section.label}</div>
                      <div class="flex flex-wrap gap-1 max-w-xs">
                        <span
                          :for={entry <- section.reads}
                          class="badge badge-ghost badge-xs"
                        >
                          {right_label(entry)}
                        </span>
                        <span
                          :for={entry <- section.writes}
                          class="badge badge-warning badge-xs"
                        >
                          {right_label(entry)}
                        </span>
                      </div>
                    </div>
                  </.table_default_cell>
                  <.table_default_cell class="text-sm">
                    <div>{date(row.grant.inserted_at, @scope.user)}</div>
                    <div
                      :if={row.grant.created_ip}
                      class="font-mono text-xs text-base-content/60"
                    >
                      {row.grant.created_ip}
                    </div>
                  </.table_default_cell>
                  <.table_default_cell>
                    <div :if={not @impersonated} class="flex flex-wrap gap-2">
                      <.button
                        id={"#{@id}-approve-#{row.grant.uuid}"}
                        type="button"
                        variant="primary"
                        size="xs"
                        aria-label={gettext("Approve %{name}", name: app_name(row))}
                        phx-click="request_approve"
                        phx-value-uuid={row.grant.uuid}
                        phx-target={@myself}
                      >
                        {gettext("Approve")}
                      </.button>
                      <.button
                        id={"#{@id}-reject-#{row.grant.uuid}"}
                        type="button"
                        variant="outline"
                        size="xs"
                        aria-label={gettext("Reject %{name}", name: app_name(row))}
                        phx-click="request_reject"
                        phx-value-uuid={row.grant.uuid}
                        phx-target={@myself}
                      >
                        {gettext("Reject")}
                      </.button>
                    </div>
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
              icon="hero-clock"
              title={gettext("No connection is waiting for approval.")}
            />
          </div>
        </.form_section>

        <.modal
          show={@confirmation.show}
          on_close="cancel_decision"
          id={"#{@id}-decision-modal"}
          max_width="md"
        >
          <:title>
            <%= if @confirmation[:action] == :reject do %>
              <.icon name="hero-no-symbol" class="w-5 h-5 text-error" /> {gettext(
                "Reject this application?"
              )}
            <% else %>
              <.icon name="hero-check-circle" class="w-5 h-5 text-success" /> {gettext(
                "Approve this application?"
              )}
            <% end %>
          </:title>

          <p :if={@confirmation[:name]} class="font-medium break-all">{@confirmation[:name]}</p>
          <p :if={@confirmation[:person]} class="text-sm text-base-content/70 break-all">
            {@confirmation[:person]}
          </p>
          <div
            :if={@confirmation[:action] == :reject}
            id={"#{@id}-reject-warning"}
            class="alert alert-warning text-sm mt-2"
          >
            {gettext(
              "The connection ends at once and the application has to ask for access again. This cannot be undone."
            )}
          </div>
          <div
            :if={@confirmation[:action] != :reject}
            id={"#{@id}-approve-warning"}
            class="alert alert-warning text-sm mt-2"
          >
            {gettext(
              "From now on the application acts with the rights of this person, limited to the rights it was given. Approve it only if you know the application and trust the address its answers go to."
            )}
          </div>

          <:actions>
            <.button type="button" variant="ghost" phx-click="cancel_decision" phx-target={@myself}>
              {gettext("Cancel")}
            </.button>
            <.button
              type="button"
              variant={if @confirmation[:action] == :reject, do: "error", else: "primary"}
              id={"#{@id}-decision-confirm"}
              phx-click="confirm_decision"
              phx-target={@myself}
            >
              {if @confirmation[:action] == :reject, do: gettext("Reject"), else: gettext("Approve")}
            </.button>
          </:actions>
        </.modal>
      <% end %>
    </div>
    """
  end
end
