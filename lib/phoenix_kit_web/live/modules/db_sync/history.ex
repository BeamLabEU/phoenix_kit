defmodule PhoenixKitWeb.Live.Modules.DBSync.History do
  @moduledoc """
  LiveView for DB Sync transfer history.

  Displays all data transfers with filtering and approval workflow support.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.DBSync
  alias PhoenixKit.DBSync.Transfers
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @per_page 20

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || "en"
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    config = DBSync.get_config()

    socket =
      socket
      |> assign(:page_title, "Transfer History")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/db-sync/history", locale: locale))
      |> assign(:config, config)
      |> assign(:page, 1)
      |> assign(:direction_filter, nil)
      |> assign(:status_filter, nil)
      |> assign(:show_approval_modal, false)
      |> assign(:selected_transfer, nil)
      |> load_transfers()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    direction_filter = params["direction"]
    status_filter = params["status"]

    socket =
      socket
      |> assign(:page, page)
      |> assign(:direction_filter, direction_filter)
      |> assign(:status_filter, status_filter)
      |> load_transfers()

    {:noreply, socket}
  end

  defp load_transfers(socket) do
    page = socket.assigns.page
    direction = socket.assigns.direction_filter
    status = socket.assigns.status_filter

    opts = [
      limit: @per_page,
      offset: (page - 1) * @per_page,
      preload: [:connection]
    ]

    opts = if direction, do: Keyword.put(opts, :direction, direction), else: opts
    opts = if status, do: Keyword.put(opts, :status, status), else: opts

    transfers = Transfers.list_transfers(opts)
    total_count = Transfers.count_transfers(Keyword.take(opts, [:direction, :status]))
    total_pages = max(1, ceil(total_count / @per_page))

    pending_count = Transfers.count_transfers(status: "pending_approval")

    socket
    |> assign(:transfers, transfers)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:pending_approval_count, pending_count)
  end

  @impl true
  def handle_event("filter", %{"direction" => direction, "status" => status}, socket) do
    params = %{}
    params = if direction != "", do: Map.put(params, "direction", direction), else: params
    params = if status != "", do: Map.put(params, "status", status), else: params

    path = Routes.path("/admin/db-sync/history", params)
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("clear_filters", _params, socket) do
    path = Routes.path("/admin/db-sync/history")
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("show_approval_modal", %{"id" => id}, socket) do
    transfer = Transfers.get_transfer_with_preloads(String.to_integer(id), preload: [:connection])

    socket =
      socket
      |> assign(:show_approval_modal, true)
      |> assign(:selected_transfer, transfer)

    {:noreply, socket}
  end

  def handle_event("close_approval_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_approval_modal, false)
      |> assign(:selected_transfer, nil)

    {:noreply, socket}
  end

  def handle_event("approve_transfer", %{"id" => id}, socket) do
    transfer = Transfers.get_transfer!(String.to_integer(id))
    current_user = socket.assigns.phoenix_kit_current_scope.user

    case Transfers.approve_transfer(transfer, current_user.id) do
      {:ok, _transfer} ->
        socket =
          socket
          |> put_flash(:info, "Transfer approved successfully")
          |> assign(:show_approval_modal, false)
          |> assign(:selected_transfer, nil)
          |> load_transfers()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to approve transfer")}
    end
  end

  def handle_event("deny_transfer", %{"transfer_id" => id, "reason" => reason}, socket) do
    transfer = Transfers.get_transfer!(String.to_integer(id))
    current_user = socket.assigns.phoenix_kit_current_scope.user
    reason = if reason == "", do: nil, else: reason

    case Transfers.deny_transfer(transfer, current_user.id, reason) do
      {:ok, _transfer} ->
        socket =
          socket
          |> put_flash(:info, "Transfer denied")
          |> assign(:show_approval_modal, false)
          |> assign(:selected_transfer, nil)
          |> load_transfers()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to deny transfer")}
    end
  end

  def handle_event("page", %{"page" => page}, socket) do
    params = %{"page" => page}

    params =
      if socket.assigns.direction_filter,
        do: Map.put(params, "direction", socket.assigns.direction_filter),
        else: params

    params =
      if socket.assigns.status_filter,
        do: Map.put(params, "status", socket.assigns.status_filter),
        else: params

    path = Routes.path("/admin/db-sync/history", params)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Transfer History"
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
            <h1 class="text-3xl font-bold text-base-content mb-2">Transfer History</h1>
            <p class="text-base-content/70">
              View and manage data transfers
            </p>
          </div>
        </header>

        <%= if not @config.enabled do %>
          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>DB Sync module is disabled.</span>
          </div>
        <% end %>

        <%!-- Pending Approvals Alert --%>
        <%= if @pending_approval_count > 0 do %>
          <div class="alert alert-info mb-6">
            <.icon name="hero-clock" class="w-5 h-5" />
            <span>
              <strong>{@pending_approval_count}</strong> transfer(s) pending approval
            </span>
            <button
              type="button"
              phx-click="filter"
              phx-value-direction=""
              phx-value-status="pending_approval"
              class="btn btn-sm btn-primary"
            >
              View Pending
            </button>
          </div>
        <% end %>

        <%!-- Filters --%>
        <div class="card bg-base-100 shadow mb-6">
          <div class="card-body py-4">
            <div class="flex flex-wrap gap-4 items-end">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Direction</span>
                </label>
                <select
                  class="select select-bordered select-sm"
                  phx-change="filter"
                  name="direction"
                >
                  <option value="" selected={@direction_filter == nil}>All</option>
                  <option value="send" selected={@direction_filter == "send"}>Sent</option>
                  <option value="receive" selected={@direction_filter == "receive"}>Received</option>
                </select>
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Status</span>
                </label>
                <select
                  class="select select-bordered select-sm"
                  phx-change="filter"
                  name="status"
                >
                  <option value="" selected={@status_filter == nil}>All</option>
                  <option value="pending" selected={@status_filter == "pending"}>Pending</option>
                  <option value="pending_approval" selected={@status_filter == "pending_approval"}>
                    Pending Approval
                  </option>
                  <option value="approved" selected={@status_filter == "approved"}>Approved</option>
                  <option value="denied" selected={@status_filter == "denied"}>Denied</option>
                  <option value="in_progress" selected={@status_filter == "in_progress"}>
                    In Progress
                  </option>
                  <option value="completed" selected={@status_filter == "completed"}>
                    Completed
                  </option>
                  <option value="failed" selected={@status_filter == "failed"}>Failed</option>
                  <option value="cancelled" selected={@status_filter == "cancelled"}>
                    Cancelled
                  </option>
                  <option value="expired" selected={@status_filter == "expired"}>Expired</option>
                </select>
              </div>

              <%= if @direction_filter || @status_filter do %>
                <button
                  type="button"
                  phx-click="clear_filters"
                  class="btn btn-ghost btn-sm"
                >
                  Clear Filters
                </button>
              <% end %>

              <div class="ml-auto text-sm text-base-content/70">
                {@total_count} transfer(s) found
              </div>
            </div>
          </div>
        </div>

        <%!-- Transfers Table --%>
        <div class="card bg-base-100 shadow">
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>Direction</th>
                  <th>Table</th>
                  <th>Records</th>
                  <th>Status</th>
                  <th>Connection</th>
                  <th>Date</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= if Enum.empty?(@transfers) do %>
                  <tr>
                    <td colspan="7" class="text-center text-base-content/70 py-8">
                      No transfers found
                    </td>
                  </tr>
                <% else %>
                  <%= for transfer <- @transfers do %>
                    <tr>
                      <td>
                        <.direction_badge direction={transfer.direction} />
                      </td>
                      <td class="font-mono text-sm">{transfer.table_name}</td>
                      <td>
                        <.record_counts transfer={transfer} />
                      </td>
                      <td>
                        <.status_badge status={transfer.status} />
                      </td>
                      <td class="text-sm text-base-content/70">
                        <%= if transfer.connection do %>
                          {transfer.connection.name}
                        <% else %>
                          <span class="opacity-50">Session</span>
                        <% end %>
                      </td>
                      <td class="text-sm text-base-content/70">
                        <.relative_time datetime={transfer.inserted_at} />
                      </td>
                      <td>
                        <%= if transfer.status == "pending_approval" do %>
                          <button
                            type="button"
                            phx-click="show_approval_modal"
                            phx-value-id={transfer.id}
                            class="btn btn-primary btn-xs"
                          >
                            Review
                          </button>
                        <% else %>
                          <button
                            type="button"
                            phx-click="show_approval_modal"
                            phx-value-id={transfer.id}
                            class="btn btn-ghost btn-xs"
                          >
                            Details
                          </button>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Pagination --%>
        <%= if @total_pages > 1 do %>
          <div class="flex justify-center mt-6">
            <div class="join">
              <button
                type="button"
                class="join-item btn btn-sm"
                disabled={@page <= 1}
                phx-click="page"
                phx-value-page={@page - 1}
              >
                «
              </button>
              <button class="join-item btn btn-sm">
                Page {@page} of {@total_pages}
              </button>
              <button
                type="button"
                class="join-item btn btn-sm"
                disabled={@page >= @total_pages}
                phx-click="page"
                phx-value-page={@page + 1}
              >
                »
              </button>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Approval/Details Modal --%>
      <%= if @show_approval_modal && @selected_transfer do %>
        <.transfer_modal transfer={@selected_transfer} />
      <% end %>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # ===========================================
  # COMPONENTS
  # ===========================================

  defp direction_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      if(@direction == "send", do: "badge-primary", else: "badge-secondary")
    ]}>
      <%= if @direction == "send" do %>
        <.icon name="hero-arrow-up-tray" class="w-3 h-3 mr-1" /> Sent
      <% else %>
        <.icon name="hero-arrow-down-tray" class="w-3 h-3 mr-1" /> Received
      <% end %>
    </span>
    """
  end

  defp status_badge(assigns) do
    color =
      case assigns.status do
        "pending" -> "badge-ghost"
        "pending_approval" -> "badge-warning"
        "approved" -> "badge-info"
        "denied" -> "badge-error"
        "in_progress" -> "badge-info"
        "completed" -> "badge-success"
        "failed" -> "badge-error"
        "cancelled" -> "badge-ghost"
        "expired" -> "badge-ghost"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge badge-sm #{@color}"}>
      {String.replace(@status, "_", " ") |> String.capitalize()}
    </span>
    """
  end

  defp record_counts(assigns) do
    ~H"""
    <div class="text-sm">
      <%= if @transfer.records_transferred > 0 do %>
        <span class="font-semibold">{@transfer.records_transferred}</span>
        <span class="text-base-content/50">transferred</span>
        <%= if @transfer.records_created > 0 do %>
          <span class="text-success">+{@transfer.records_created}</span>
        <% end %>
        <%= if @transfer.records_skipped > 0 do %>
          <span class="text-warning">~{@transfer.records_skipped}</span>
        <% end %>
        <%= if @transfer.records_failed > 0 do %>
          <span class="text-error">×{@transfer.records_failed}</span>
        <% end %>
      <% else %>
        <span class="text-base-content/50">
          {@transfer.records_requested || 0} requested
        </span>
      <% end %>
    </div>
    """
  end

  defp relative_time(assigns) do
    time_ago = format_time_ago(assigns.datetime)
    assigns = assign(assigns, :time_ago, time_ago)

    ~H"""
    <span title={Calendar.strftime(@datetime, "%Y-%m-%d %H:%M:%S UTC")}>
      {@time_ago}
    </span>
    """
  end

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

  defp transfer_modal(assigns) do
    ~H"""
    <div class="modal modal-open" phx-window-keydown="close_approval_modal" phx-key="escape">
      <div class="modal-box max-w-2xl">
        <button
          type="button"
          class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
          phx-click="close_approval_modal"
        >
          ✕
        </button>

        <h3 class="font-bold text-lg mb-4">
          Transfer Details <.status_badge status={@transfer.status} />
        </h3>

        <div class="grid gap-4">
          <%!-- Basic Info --%>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="text-sm text-base-content/70">Direction</label>
              <p class="font-semibold">
                <.direction_badge direction={@transfer.direction} />
              </p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">Table</label>
              <p class="font-mono">{@transfer.table_name}</p>
            </div>
          </div>

          <%!-- Records Info --%>
          <div class="grid grid-cols-3 gap-4">
            <div>
              <label class="text-sm text-base-content/70">Requested</label>
              <p class="font-semibold">{@transfer.records_requested || 0}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">Transferred</label>
              <p class="font-semibold">{@transfer.records_transferred}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">Bytes</label>
              <p class="font-semibold">{format_bytes(@transfer.bytes_transferred)}</p>
            </div>
          </div>

          <div class="grid grid-cols-4 gap-4">
            <div>
              <label class="text-sm text-base-content/70">Created</label>
              <p class="text-success font-semibold">{@transfer.records_created}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">Updated</label>
              <p class="text-info font-semibold">{@transfer.records_updated}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">Skipped</label>
              <p class="text-warning font-semibold">{@transfer.records_skipped}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">Failed</label>
              <p class="text-error font-semibold">{@transfer.records_failed}</p>
            </div>
          </div>

          <%!-- Connection Info --%>
          <%= if @transfer.connection do %>
            <div class="divider my-2"></div>
            <div>
              <label class="text-sm text-base-content/70">Connection</label>
              <p>{@transfer.connection.name}</p>
              <p class="text-sm text-base-content/50">{@transfer.connection.site_url}</p>
            </div>
          <% end %>

          <%!-- Request Context (for approval) --%>
          <%= if @transfer.requires_approval do %>
            <div class="divider my-2"></div>
            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="text-sm text-base-content/70">Requester IP</label>
                <p class="font-mono text-sm">{@transfer.requester_ip || "Unknown"}</p>
              </div>
              <div>
                <label class="text-sm text-base-content/70">Conflict Strategy</label>
                <p>{@transfer.conflict_strategy || "default"}</p>
              </div>
            </div>
          <% end %>

          <%!-- Error Message --%>
          <%= if @transfer.error_message do %>
            <div class="alert alert-error">
              <.icon name="hero-exclamation-circle" class="w-5 h-5" />
              <span>{@transfer.error_message}</span>
            </div>
          <% end %>

          <%!-- Denial Reason --%>
          <%= if @transfer.denial_reason do %>
            <div class="alert alert-warning">
              <.icon name="hero-x-circle" class="w-5 h-5" />
              <span>Denied: {@transfer.denial_reason}</span>
            </div>
          <% end %>

          <%!-- Timestamps --%>
          <div class="divider my-2"></div>
          <div class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <label class="text-base-content/70">Created</label>
              <p>{Calendar.strftime(@transfer.inserted_at, "%Y-%m-%d %H:%M:%S")}</p>
            </div>
            <%= if @transfer.started_at do %>
              <div>
                <label class="text-base-content/70">Started</label>
                <p>{Calendar.strftime(@transfer.started_at, "%Y-%m-%d %H:%M:%S")}</p>
              </div>
            <% end %>
            <%= if @transfer.completed_at do %>
              <div>
                <label class="text-base-content/70">Completed</label>
                <p>{Calendar.strftime(@transfer.completed_at, "%Y-%m-%d %H:%M:%S")}</p>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Action Buttons --%>
        <div class="modal-action">
          <%= if @transfer.status == "pending_approval" do %>
            <form phx-submit="deny_transfer" class="flex gap-2 items-end">
              <input type="hidden" name="transfer_id" value={@transfer.id} />
              <div class="form-control">
                <input
                  type="text"
                  name="reason"
                  placeholder="Reason (optional)"
                  class="input input-bordered input-sm w-48"
                />
              </div>
              <button type="submit" class="btn btn-error btn-sm">
                Deny
              </button>
            </form>
            <button
              type="button"
              phx-click="approve_transfer"
              phx-value-id={@transfer.id}
              class="btn btn-success btn-sm"
            >
              Approve
            </button>
          <% else %>
            <button type="button" phx-click="close_approval_modal" class="btn btn-ghost">
              Close
            </button>
          <% end %>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_approval_modal"></div>
    </div>
    """
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
end
