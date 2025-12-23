defmodule PhoenixKitWeb.Live.Modules.DBSync.ConnectionsLive do
  @moduledoc """
  LiveView for managing DB Sync permanent connections.

  Allows creating, editing, and managing persistent connections between
  PhoenixKit instances with access control settings.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.DBSync
  alias PhoenixKit.DBSync.Connection
  alias PhoenixKit.DBSync.Connections
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || "en"
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    config = DBSync.get_config()

    socket =
      socket
      |> assign(:page_title, "Connections")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/db-sync/connections", locale: locale))
      |> assign(:config, config)
      |> assign(:view_mode, :list)
      |> assign(:selected_connection, nil)
      |> assign(:changeset, nil)
      |> assign(:new_token, nil)
      |> assign(:direction_filter, nil)
      |> load_connections()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    action = params["action"]
    id = params["id"]

    socket =
      case {action, id} do
        {"new", _} ->
          changeset = Connection.changeset(%Connection{}, %{})

          socket
          |> assign(:view_mode, :new)
          |> assign(:changeset, changeset)

        {"edit", id} when not is_nil(id) ->
          connection = Connections.get_connection!(String.to_integer(id))
          changeset = Connection.settings_changeset(connection, %{})

          socket
          |> assign(:view_mode, :edit)
          |> assign(:selected_connection, connection)
          |> assign(:changeset, changeset)

        {"show", id} when not is_nil(id) ->
          connection = Connections.get_connection!(String.to_integer(id))

          socket
          |> assign(:view_mode, :show)
          |> assign(:selected_connection, connection)

        _ ->
          socket
          |> assign(:view_mode, :list)
          |> assign(:selected_connection, nil)
          |> assign(:changeset, nil)
          |> assign(:direction_filter, params["direction"])
          |> load_connections()
      end

    {:noreply, socket}
  end

  defp load_connections(socket) do
    direction = socket.assigns[:direction_filter]
    opts = if direction, do: [direction: direction], else: []

    sender_connections = Connections.list_connections(Keyword.put(opts, :direction, "sender"))
    receiver_connections = Connections.list_connections(Keyword.put(opts, :direction, "receiver"))

    socket
    |> assign(:sender_connections, sender_connections)
    |> assign(:receiver_connections, receiver_connections)
  end

  @impl true
  def handle_event("filter", %{"direction" => direction}, socket) do
    params = if direction != "", do: %{direction: direction}, else: %{}
    path = path_with_params("/admin/db-sync/connections", params)
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("new_connection", _params, socket) do
    path = path_with_params("/admin/db-sync/connections", %{action: "new"})
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("show_connection", %{"id" => id}, socket) do
    path = path_with_params("/admin/db-sync/connections", %{action: "show", id: id})
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("edit_connection", %{"id" => id}, socket) do
    path = path_with_params("/admin/db-sync/connections", %{action: "edit", id: id})
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("cancel", _params, socket) do
    path = Routes.path("/admin/db-sync/connections")

    socket =
      socket
      |> assign(:new_token, nil)

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("validate", %{"connection" => params}, socket) do
    changeset =
      case socket.assigns.view_mode do
        :new ->
          %Connection{}
          |> Connection.changeset(params)
          |> Map.put(:action, :validate)

        :edit ->
          socket.assigns.selected_connection
          |> Connection.settings_changeset(params)
          |> Map.put(:action, :validate)
      end

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"connection" => params}, socket) do
    case socket.assigns.view_mode do
      :new -> do_create_connection(socket, params)
      :edit -> do_update_connection(socket, params)
    end
  end

  def handle_event("approve_connection", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))
    current_user = socket.assigns.phoenix_kit_current_scope.user

    case Connections.approve_connection(connection, current_user.id) do
      {:ok, _connection} ->
        socket =
          socket
          |> put_flash(:info, "Connection approved")
          |> load_connections()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to approve connection")}
    end
  end

  def handle_event("suspend_connection", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))
    current_user = socket.assigns.phoenix_kit_current_scope.user

    case Connections.suspend_connection(connection, current_user.id) do
      {:ok, _connection} ->
        socket =
          socket
          |> put_flash(:info, "Connection suspended")
          |> load_connections()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to suspend connection")}
    end
  end

  def handle_event("reactivate_connection", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))

    case Connections.reactivate_connection(connection) do
      {:ok, _connection} ->
        socket =
          socket
          |> put_flash(:info, "Connection reactivated")
          |> load_connections()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to reactivate connection")}
    end
  end

  def handle_event("revoke_connection", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))
    current_user = socket.assigns.phoenix_kit_current_scope.user

    case Connections.revoke_connection(connection, current_user.id, "Revoked by admin") do
      {:ok, _connection} ->
        socket =
          socket
          |> put_flash(:info, "Connection revoked")
          |> load_connections()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke connection")}
    end
  end

  def handle_event("regenerate_token", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))

    case Connections.regenerate_token(connection) do
      {:ok, _connection, new_token} ->
        socket =
          socket
          |> put_flash(:info, "Token regenerated")
          |> assign(:new_token, new_token)
          |> load_connections()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate token")}
    end
  end

  def handle_event("delete_connection", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))

    case Connections.delete_connection(connection) do
      {:ok, _connection} ->
        socket =
          socket
          |> put_flash(:info, "Connection deleted")
          |> load_connections()

        path = Routes.path("/admin/db-sync/connections")
        {:noreply, push_patch(socket, to: path)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete connection")}
    end
  end

  def handle_event("copy_token", _params, socket) do
    {:noreply, put_flash(socket, :info, "Token copied to clipboard")}
  end

  # ===========================================
  # PRIVATE HELPERS FOR SAVE
  # ===========================================

  defp do_create_connection(socket, params) do
    current_user = socket.assigns.phoenix_kit_current_scope.user
    params = Map.put(params, "created_by", current_user.id)

    case Connections.create_connection(params) do
      {:ok, _connection, token} ->
        socket =
          socket
          |> put_flash(:info, "Connection created successfully")
          |> assign(:new_token, token)
          |> load_connections()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp do_update_connection(socket, params) do
    case Connections.update_connection(socket.assigns.selected_connection, params) do
      {:ok, _connection} ->
        socket =
          socket
          |> put_flash(:info, "Connection updated successfully")
          |> load_connections()

        path = Routes.path("/admin/db-sync/connections")
        {:noreply, push_patch(socket, to: path)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Connections"
      current_path={@current_path}
      project_title={@project_title}
      current_locale={@current_locale}
    >
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <.link
            navigate={Routes.path("/admin/db-sync", locale: @current_locale)}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to DB Sync
          </.link>

          <div class="text-center">
            <h1 class="text-3xl font-bold text-base-content mb-2">Connections</h1>
            <p class="text-base-content/70">
              Manage permanent connections for data sync
            </p>
          </div>
        </header>

        <%= if not @config.enabled do %>
          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>DB Sync module is disabled.</span>
          </div>
        <% end %>

        <%!-- New Token Display --%>
        <%= if @new_token do %>
          <div class="alert alert-success mb-6">
            <.icon name="hero-key" class="w-5 h-5" />
            <div class="flex-1">
              <p class="font-semibold">
                Connection created! Save this token - it won't be shown again:
              </p>
              <div class="flex items-center gap-2 mt-2">
                <code class="bg-base-300 px-3 py-1 rounded font-mono text-sm select-all">
                  {@new_token}
                </code>
                <button
                  type="button"
                  phx-click="copy_token"
                  phx-hook="CopyToClipboard"
                  data-copy={@new_token}
                  id="copy-token-btn"
                  class="btn btn-ghost btn-sm"
                >
                  <.icon name="hero-clipboard" class="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <%= case @view_mode do %>
          <% :list -> %>
            <.connections_list
              sender_connections={@sender_connections}
              receiver_connections={@receiver_connections}
              direction_filter={@direction_filter}
            />
          <% :new -> %>
            <.connection_form changeset={@changeset} action={:new} />
          <% :edit -> %>
            <.connection_form
              changeset={@changeset}
              action={:edit}
              connection={@selected_connection}
            />
          <% :show -> %>
            <.connection_details connection={@selected_connection} />
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # ===========================================
  # LIST VIEW
  # ===========================================

  defp connections_list(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Actions Bar --%>
      <div class="flex justify-between items-center">
        <div class="flex gap-2">
          <select
            class="select select-bordered select-sm"
            phx-change="filter"
            name="direction"
          >
            <option value="" selected={@direction_filter == nil}>All Directions</option>
            <option value="sender" selected={@direction_filter == "sender"}>Senders Only</option>
            <option value="receiver" selected={@direction_filter == "receiver"}>
              Receivers Only
            </option>
          </select>
        </div>
        <button type="button" phx-click="new_connection" class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> New Connection
        </button>
      </div>

      <%!-- Sender Connections --%>
      <%= if @direction_filter != "receiver" do %>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title">
              <.icon name="hero-arrow-up-tray" class="w-5 h-5" /> Sender Connections
              <span class="badge badge-ghost">{length(@sender_connections)}</span>
            </h2>
            <p class="text-sm text-base-content/70 mb-4">
              Sites that can pull data from this site
            </p>

            <%= if Enum.empty?(@sender_connections) do %>
              <p class="text-center text-base-content/50 py-4">
                No sender connections configured
              </p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Site URL</th>
                      <th>Status</th>
                      <th>Approval Mode</th>
                      <th>Usage</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for conn <- @sender_connections do %>
                      <tr>
                        <td class="font-semibold">{conn.name}</td>
                        <td class="text-sm font-mono">{conn.site_url}</td>
                        <td><.status_badge status={conn.status} /></td>
                        <td class="text-sm">{format_approval_mode(conn.approval_mode)}</td>
                        <td class="text-sm">
                          {conn.downloads_used}
                          <%= if conn.max_downloads do %>
                            /{conn.max_downloads}
                          <% end %>
                          downloads
                        </td>
                        <td>
                          <.connection_actions connection={conn} />
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Receiver Connections --%>
      <%= if @direction_filter != "sender" do %>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title">
              <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> Receiver Connections
              <span class="badge badge-ghost">{length(@receiver_connections)}</span>
            </h2>
            <p class="text-sm text-base-content/70 mb-4">
              Sites this site can pull data from
            </p>

            <%= if Enum.empty?(@receiver_connections) do %>
              <p class="text-center text-base-content/50 py-4">
                No receiver connections configured
              </p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Site URL</th>
                      <th>Status</th>
                      <th>Auto Sync</th>
                      <th>Last Transfer</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for conn <- @receiver_connections do %>
                      <tr>
                        <td class="font-semibold">{conn.name}</td>
                        <td class="text-sm font-mono">{conn.site_url}</td>
                        <td><.status_badge status={conn.status} /></td>
                        <td class="text-sm">
                          <%= if conn.auto_sync_enabled do %>
                            <span class="badge badge-success badge-sm">On</span>
                          <% else %>
                            <span class="badge badge-ghost badge-sm">Off</span>
                          <% end %>
                        </td>
                        <td class="text-sm text-base-content/70">
                          <%= if conn.last_transfer_at do %>
                            {format_time_ago(conn.last_transfer_at)}
                          <% else %>
                            Never
                          <% end %>
                        </td>
                        <td>
                          <.connection_actions connection={conn} />
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp connection_actions(assigns) do
    ~H"""
    <div class="flex gap-1">
      <button
        type="button"
        phx-click="show_connection"
        phx-value-id={@connection.id}
        class="btn btn-ghost btn-xs"
        title="View details"
      >
        <.icon name="hero-eye" class="w-4 h-4" />
      </button>
      <button
        type="button"
        phx-click="edit_connection"
        phx-value-id={@connection.id}
        class="btn btn-ghost btn-xs"
        title="Edit"
      >
        <.icon name="hero-pencil" class="w-4 h-4" />
      </button>
      <%= if @connection.status == "pending" do %>
        <button
          type="button"
          phx-click="approve_connection"
          phx-value-id={@connection.id}
          class="btn btn-success btn-xs"
          title="Approve"
        >
          <.icon name="hero-check" class="w-4 h-4" />
        </button>
      <% end %>
      <%= if @connection.status == "active" do %>
        <button
          type="button"
          phx-click="suspend_connection"
          phx-value-id={@connection.id}
          class="btn btn-warning btn-xs"
          title="Suspend"
        >
          <.icon name="hero-pause" class="w-4 h-4" />
        </button>
      <% end %>
      <%= if @connection.status == "suspended" do %>
        <button
          type="button"
          phx-click="reactivate_connection"
          phx-value-id={@connection.id}
          class="btn btn-info btn-xs"
          title="Reactivate"
        >
          <.icon name="hero-play" class="w-4 h-4" />
        </button>
      <% end %>
    </div>
    """
  end

  # ===========================================
  # FORM VIEW
  # ===========================================

  defp connection_form(assigns) do
    assigns = assign_new(assigns, :connection, fn -> nil end)

    ~H"""
    <div class="card bg-base-100 shadow max-w-2xl mx-auto">
      <div class="card-body">
        <h2 class="card-title">
          <%= if @action == :new do %>
            New Connection
          <% else %>
            Edit Connection
          <% end %>
        </h2>

        <.form
          for={@changeset}
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <%!-- Basic Info --%>
          <div class="form-control">
            <label class="label">
              <span class="label-text">Name *</span>
            </label>
            <input
              type="text"
              name="connection[name]"
              value={Ecto.Changeset.get_field(@changeset, :name)}
              class={"input input-bordered #{if @changeset.errors[:name], do: "input-error"}"}
              placeholder="Production Server"
              required
            />
            <%= if @changeset.errors[:name] do %>
              <label class="label">
                <span class="label-text-alt text-error">{elem(@changeset.errors[:name], 0)}</span>
              </label>
            <% end %>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Direction *</span>
            </label>
            <select
              name="connection[direction]"
              class="select select-bordered"
              required
              disabled={@action == :edit}
            >
              <option value="">Select direction...</option>
              <option
                value="sender"
                selected={Ecto.Changeset.get_field(@changeset, :direction) == "sender"}
              >
                Sender - Allow this site to share data
              </option>
              <option
                value="receiver"
                selected={Ecto.Changeset.get_field(@changeset, :direction) == "receiver"}
              >
                Receiver - Pull data from remote site
              </option>
            </select>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Site URL *</span>
            </label>
            <input
              type="url"
              name="connection[site_url]"
              value={Ecto.Changeset.get_field(@changeset, :site_url)}
              class={"input input-bordered #{if @changeset.errors[:site_url], do: "input-error"}"}
              placeholder="https://example.com"
              required
            />
          </div>

          <%!-- Sender-specific settings --%>
          <%= if Ecto.Changeset.get_field(@changeset, :direction) == "sender" do %>
            <div class="divider">Access Control</div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">Approval Mode</span>
              </label>
              <select name="connection[approval_mode]" class="select select-bordered">
                <option
                  value="require_approval"
                  selected={
                    Ecto.Changeset.get_field(@changeset, :approval_mode) == "require_approval"
                  }
                >
                  Require Approval - Manual approval for each transfer
                </option>
                <option
                  value="auto_approve"
                  selected={Ecto.Changeset.get_field(@changeset, :approval_mode) == "auto_approve"}
                >
                  Auto Approve - All transfers automatically allowed
                </option>
                <option
                  value="per_table"
                  selected={Ecto.Changeset.get_field(@changeset, :approval_mode) == "per_table"}
                >
                  Per Table - Some tables auto-approved, others need approval
                </option>
              </select>
            </div>

            <div class="divider">Limits</div>

            <div class="grid grid-cols-2 gap-4">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Max Downloads</span>
                </label>
                <input
                  type="number"
                  name="connection[max_downloads]"
                  value={Ecto.Changeset.get_field(@changeset, :max_downloads)}
                  class="input input-bordered"
                  placeholder="Unlimited"
                  min="1"
                />
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Max Records/Request</span>
                </label>
                <input
                  type="number"
                  name="connection[max_records_per_request]"
                  value={Ecto.Changeset.get_field(@changeset, :max_records_per_request) || 10000}
                  class="input input-bordered"
                  min="1"
                />
              </div>
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">Expires At</span>
              </label>
              <input
                type="datetime-local"
                name="connection[expires_at]"
                value={format_datetime_for_input(Ecto.Changeset.get_field(@changeset, :expires_at))}
                class="input input-bordered"
              />
            </div>
          <% end %>

          <%!-- Receiver-specific settings --%>
          <%= if Ecto.Changeset.get_field(@changeset, :direction) == "receiver" do %>
            <div class="divider">Import Settings</div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">Default Conflict Strategy</span>
              </label>
              <select name="connection[default_conflict_strategy]" class="select select-bordered">
                <option
                  value="skip"
                  selected={
                    Ecto.Changeset.get_field(@changeset, :default_conflict_strategy) == "skip"
                  }
                >
                  Skip - Don't overwrite existing records
                </option>
                <option
                  value="overwrite"
                  selected={
                    Ecto.Changeset.get_field(@changeset, :default_conflict_strategy) == "overwrite"
                  }
                >
                  Overwrite - Replace existing records
                </option>
                <option
                  value="merge"
                  selected={
                    Ecto.Changeset.get_field(@changeset, :default_conflict_strategy) == "merge"
                  }
                >
                  Merge - Combine with existing records
                </option>
              </select>
            </div>

            <div class="form-control">
              <label class="label cursor-pointer justify-start gap-2">
                <input
                  type="checkbox"
                  name="connection[auto_sync_enabled]"
                  class="checkbox checkbox-primary"
                  checked={Ecto.Changeset.get_field(@changeset, :auto_sync_enabled)}
                />
                <span class="label-text">Enable Auto Sync</span>
              </label>
            </div>
          <% end %>

          <%!-- Actions --%>
          <div class="card-actions justify-end pt-4">
            <button type="button" phx-click="cancel" class="btn btn-ghost">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              {if @action == :new, do: "Create Connection", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ===========================================
  # DETAILS VIEW
  # ===========================================

  defp connection_details(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow max-w-2xl mx-auto">
      <div class="card-body">
        <div class="flex justify-between items-start">
          <div>
            <h2 class="card-title">{@connection.name}</h2>
            <.status_badge status={@connection.status} />
          </div>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="edit_connection"
              phx-value-id={@connection.id}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="w-4 h-4" /> Edit
            </button>
          </div>
        </div>

        <div class="divider"></div>

        <%!-- Basic Info --%>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <label class="text-sm text-base-content/70">Direction</label>
            <p class="font-semibold capitalize">{@connection.direction}</p>
          </div>
          <div>
            <label class="text-sm text-base-content/70">Site URL</label>
            <p class="font-mono text-sm">{@connection.site_url}</p>
          </div>
        </div>

        <%!-- Sender Settings --%>
        <%= if @connection.direction == "sender" do %>
          <div class="divider">Access Control</div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="text-sm text-base-content/70">Approval Mode</label>
              <p>{format_approval_mode(@connection.approval_mode)}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">Downloads</label>
              <p>
                {@connection.downloads_used}
                <%= if @connection.max_downloads do %>
                  /{@connection.max_downloads}
                <% end %>
              </p>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-4 mt-4">
            <div>
              <label class="text-sm text-base-content/70">Records Downloaded</label>
              <p>{@connection.records_downloaded}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">Max Records/Request</label>
              <p>{@connection.max_records_per_request}</p>
            </div>
          </div>

          <%= if @connection.expires_at do %>
            <div class="mt-4">
              <label class="text-sm text-base-content/70">Expires At</label>
              <p>{Calendar.strftime(@connection.expires_at, "%Y-%m-%d %H:%M")}</p>
            </div>
          <% end %>
        <% end %>

        <%!-- Receiver Settings --%>
        <%= if @connection.direction == "receiver" do %>
          <div class="divider">Import Settings</div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="text-sm text-base-content/70">Conflict Strategy</label>
              <p class="capitalize">{@connection.default_conflict_strategy}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">Auto Sync</label>
              <p>
                <%= if @connection.auto_sync_enabled do %>
                  <span class="badge badge-success">Enabled</span>
                <% else %>
                  <span class="badge badge-ghost">Disabled</span>
                <% end %>
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Statistics --%>
        <div class="divider">Statistics</div>

        <div class="grid grid-cols-3 gap-4">
          <div>
            <label class="text-sm text-base-content/70">Total Transfers</label>
            <p class="text-2xl font-bold">{@connection.total_transfers}</p>
          </div>
          <div>
            <label class="text-sm text-base-content/70">Records Transferred</label>
            <p class="text-2xl font-bold">{@connection.total_records_transferred}</p>
          </div>
          <div>
            <label class="text-sm text-base-content/70">Bytes Transferred</label>
            <p class="text-2xl font-bold">{format_bytes(@connection.total_bytes_transferred)}</p>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4 mt-4">
          <div>
            <label class="text-sm text-base-content/70">Last Connected</label>
            <p>
              <%= if @connection.last_connected_at do %>
                {format_time_ago(@connection.last_connected_at)}
              <% else %>
                Never
              <% end %>
            </p>
          </div>
          <div>
            <label class="text-sm text-base-content/70">Last Transfer</label>
            <p>
              <%= if @connection.last_transfer_at do %>
                {format_time_ago(@connection.last_transfer_at)}
              <% else %>
                Never
              <% end %>
            </p>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="divider">Actions</div>

        <div class="flex flex-wrap gap-2">
          <%= if @connection.status == "pending" do %>
            <button
              type="button"
              phx-click="approve_connection"
              phx-value-id={@connection.id}
              class="btn btn-success btn-sm"
            >
              <.icon name="hero-check" class="w-4 h-4" /> Approve
            </button>
          <% end %>

          <%= if @connection.status == "active" do %>
            <button
              type="button"
              phx-click="suspend_connection"
              phx-value-id={@connection.id}
              class="btn btn-warning btn-sm"
            >
              <.icon name="hero-pause" class="w-4 h-4" /> Suspend
            </button>
          <% end %>

          <%= if @connection.status == "suspended" do %>
            <button
              type="button"
              phx-click="reactivate_connection"
              phx-value-id={@connection.id}
              class="btn btn-info btn-sm"
            >
              <.icon name="hero-play" class="w-4 h-4" /> Reactivate
            </button>
          <% end %>

          <%= if @connection.status not in ["revoked"] do %>
            <button
              type="button"
              phx-click="regenerate_token"
              phx-value-id={@connection.id}
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-key" class="w-4 h-4" /> Regenerate Token
            </button>

            <button
              type="button"
              phx-click="revoke_connection"
              phx-value-id={@connection.id}
              class="btn btn-error btn-sm"
              data-confirm="Are you sure you want to revoke this connection?"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" /> Revoke
            </button>
          <% end %>

          <button
            type="button"
            phx-click="delete_connection"
            phx-value-id={@connection.id}
            class="btn btn-ghost btn-sm text-error"
            data-confirm="Are you sure you want to delete this connection?"
          >
            <.icon name="hero-trash" class="w-4 h-4" /> Delete
          </button>
        </div>

        <%!-- Back Button --%>
        <div class="card-actions justify-end pt-4">
          <button type="button" phx-click="cancel" class="btn btn-ghost">
            Back to List
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ===========================================
  # HELPER COMPONENTS
  # ===========================================

  defp status_badge(assigns) do
    color =
      case assigns.status do
        "pending" -> "badge-warning"
        "active" -> "badge-success"
        "suspended" -> "badge-error"
        "revoked" -> "badge-ghost"
        "expired" -> "badge-ghost"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge badge-sm #{@color}"}>
      {String.capitalize(@status)}
    </span>
    """
  end

  # ===========================================
  # HELPER FUNCTIONS
  # ===========================================

  defp format_approval_mode("auto_approve"), do: "Auto Approve"
  defp format_approval_mode("require_approval"), do: "Require Approval"
  defp format_approval_mode("per_table"), do: "Per Table"
  defp format_approval_mode(mode), do: mode

  defp format_time_ago(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  defp format_bytes(bytes) when is_nil(bytes) or bytes == 0, do: "0 B"

  defp format_bytes(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_datetime_for_input(nil), do: nil

  defp format_datetime_for_input(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M")
  end

  defp path_with_params(base_path, params) when map_size(params) == 0 do
    Routes.path(base_path)
  end

  defp path_with_params(base_path, params) do
    query_string = URI.encode_query(params)
    "#{Routes.path(base_path)}?#{query_string}"
  end
end
