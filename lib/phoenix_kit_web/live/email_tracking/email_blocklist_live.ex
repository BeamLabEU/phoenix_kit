defmodule PhoenixKitWeb.Live.EmailTracking.EmailBlocklistLive do
  @moduledoc """
  LiveView for managing email blocklist and blocked addresses.

  Provides comprehensive management of blocked email addresses, including:

  - **Blocklist Viewing**: List all blocked email addresses with filtering
  - **Block Management**: Add/remove email addresses from blocklist
  - **Bulk Operations**: Import/export blocklists, bulk add/remove
  - **Temporary Blocks**: Set expiration dates for temporary blocks
  - **Block Reasons**: Categorize blocks by reason (spam, bounce, manual, etc.)
  - **Search & Filter**: Find blocked addresses by email, reason, or date

  ## Features

  - **Real-time Updates**: Live updates when blocks are added/removed
  - **CSV Import/Export**: Bulk management through CSV files
  - **Automatic Blocking**: Integration with rate limiter for auto-blocks
  - **Audit Trail**: Track who blocked addresses and when
  - **Expiration Management**: Automatic cleanup of expired blocks
  - **Statistics**: Analytics on blocked addresses and reasons

  ## Route

  This LiveView is mounted at `{prefix}/admin/email/blocklist` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-blocklist", PhoenixKitWeb.Live.EmailTracking.EmailBlocklistLive, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.EmailTracking
  alias PhoenixKit.EmailTracking.RateLimiter
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  # Auto-refresh every 30 seconds
  @refresh_interval 30_000

  # Items per page for pagination
  @per_page 50

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, session, socket) do
    # Check if email tracking is enabled
    if EmailTracking.enabled?() do
      # Get current path for navigation
      current_path = get_current_path(socket, session)

      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Schedule periodic refresh
      if connected?(socket) do
        Process.send_after(self(), :refresh_blocklist, @refresh_interval)
      end

      socket =
        socket
        |> assign(:current_path, current_path)
        |> assign(:project_title, project_title)
        |> assign(:loading, true)
        |> assign(:blocked_emails, [])
        |> assign(:total_blocked, 0)
        |> assign(:page, 1)
        |> assign(:per_page, @per_page)
        |> assign(:search_term, "")
        |> assign(:reason_filter, "")
        |> assign(:status_filter, "all")
        |> assign(:selected_emails, [])
        |> assign(:show_add_form, false)
        |> assign(:show_import_form, false)
        |> assign(:bulk_action, nil)
        |> assign(:last_updated, DateTime.utc_now())
        |> assign(:statistics, %{})
        |> load_blocklist_data()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Email tracking is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_blocklist_data()}
  end

  @impl true
  def handle_event("search", %{"search" => search_term}, socket) do
    {:noreply,
     socket
     |> assign(:search_term, search_term)
     |> assign(:page, 1)
     |> load_blocklist_data()}
  end

  @impl true
  def handle_event("filter_reason", %{"reason" => reason}, socket) do
    {:noreply,
     socket
     |> assign(:reason_filter, reason)
     |> assign(:page, 1)
     |> load_blocklist_data()}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:status_filter, status)
     |> assign(:page, 1)
     |> load_blocklist_data()}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    case Integer.parse(page) do
      {page_num, _} when page_num > 0 ->
        {:noreply,
         socket
         |> assign(:page, page_num)
         |> load_blocklist_data()}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_add_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_form, !socket.assigns.show_add_form)}
  end

  @impl true
  def handle_event("toggle_import_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import_form, !socket.assigns.show_import_form)}
  end

  @impl true
  def handle_event("add_block", params, socket) do
    %{
      "email" => email,
      "reason" => reason,
      "expires_at" => expires_at
    } = params

    opts = []

    opts =
      if expires_at && expires_at != "" do
        case Date.from_iso8601(expires_at) do
          {:ok, date} ->
            expires_datetime = DateTime.new!(date, ~T[23:59:59])
            [expires_at: expires_datetime] ++ opts

          _ ->
            opts
        end
      else
        opts
      end

    case RateLimiter.add_to_blocklist(email, reason, opts) do
      :ok ->
        {:noreply,
         socket
         |> assign(:show_add_form, false)
         |> put_flash(:info, "Email address blocked successfully")
         |> load_blocklist_data()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to block email: #{reason}")}
    end
  end

  @impl true
  def handle_event("remove_block", %{"email" => email}, socket) do
    RateLimiter.remove_from_blocklist(email)

    {:noreply,
     socket
     |> put_flash(:info, "Email address unblocked successfully")
     |> load_blocklist_data()}
  end

  @impl true
  def handle_event("toggle_email_selection", %{"email" => email}, socket) do
    selected = socket.assigns.selected_emails

    new_selected =
      if email in selected do
        List.delete(selected, email)
      else
        [email | selected]
      end

    {:noreply,
     socket
     |> assign(:selected_emails, new_selected)}
  end

  @impl true
  def handle_event("select_all_visible", _params, socket) do
    all_emails = Enum.map(socket.assigns.blocked_emails, & &1.email)

    {:noreply,
     socket
     |> assign(:selected_emails, all_emails)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_emails, [])
     |> assign(:bulk_action, nil)}
  end

  @impl true
  def handle_event("set_bulk_action", %{"action" => action}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_action, action)}
  end

  @impl true
  def handle_event("execute_bulk_action", _params, socket) do
    case socket.assigns.bulk_action do
      "remove" ->
        execute_bulk_remove(socket)

      "export" ->
        execute_bulk_export(socket)

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid bulk action")}
    end
  end

  @impl true
  def handle_event("export_blocklist", %{"format" => format}, socket) do
    case format do
      "csv" ->
        csv_content = export_blocklist_csv(socket.assigns.blocked_emails)
        filename = "email_blocklist_#{Date.utc_today()}.csv"

        {:noreply,
         socket
         |> push_event("download", %{
           filename: filename,
           content: csv_content,
           mime_type: "text/csv"
         })}

      "json" ->
        json_content = Jason.encode!(socket.assigns.blocked_emails, pretty: true)
        filename = "email_blocklist_#{Date.utc_today()}.json"

        {:noreply,
         socket
         |> push_event("download", %{
           filename: filename,
           content: json_content,
           mime_type: "application/json"
         })}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Unsupported export format")}
    end
  end

  @impl true
  def handle_event("import_csv", %{"csv_content" => csv_content}, socket) do
    case import_blocklist_csv(csv_content) do
      {:ok, imported_count} ->
        {:noreply,
         socket
         |> assign(:show_import_form, false)
         |> put_flash(:info, "Successfully imported #{imported_count} blocked emails")
         |> load_blocklist_data()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Import failed: #{reason}")}
    end
  end

  @impl true
  def handle_info(:refresh_blocklist, socket) do
    # Schedule next refresh
    Process.send_after(self(), :refresh_blocklist, @refresh_interval)

    {:noreply,
     socket
     |> assign(:last_updated, DateTime.utc_now())
     |> load_blocklist_data()}
  end

  ## --- Template ---

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Email Blocklist"
      current_path={@current_path}
      project_title={@project_title}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <%!-- Back Button --%>
          <.link
            navigate={Routes.path("/admin")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0 -mb-12"
          >
            <.icon_arrow_left /> Back to Admin
          </.link>

          <%!-- Title Section --%>
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">
              🚫 Email Blocklist
            </h1>
            <p class="text-lg text-base-content/70">
              Manage blocked email addresses and anti-spam protection
            </p>
          </div>
        </header>

        <%!-- Statistics Cards --%>
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-6">
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4 text-center">
              <p class="text-2xl font-bold">{@total_blocked}</p>
              <p class="text-sm text-base-content/60">Total Blocked</p>
            </div>
          </div>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4 text-center">
              <p class="text-2xl font-bold">{@statistics[:active_blocks] || 0}</p>
              <p class="text-sm text-base-content/60">Active Blocks</p>
            </div>
          </div>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4 text-center">
              <p class="text-2xl font-bold">{@statistics[:expired_today] || 0}</p>
              <p class="text-sm text-base-content/60">Expired Today</p>
            </div>
          </div>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4 text-center">
              <p class="text-2xl font-bold">{length(@selected_emails)}</p>
              <p class="text-sm text-base-content/60">Selected</p>
            </div>
          </div>
        </div>

        <%!-- Controls Section --%>
        <div class="card bg-base-100 shadow-sm mb-6">
          <div class="card-body">
            <div class="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
              <%!-- Search and Filters --%>
              <div class="flex flex-col md:flex-row gap-2 flex-1">
                <div class="form-control">
                  <input
                    type="text"
                    placeholder="Search email addresses..."
                    class="input input-bordered input-sm w-full md:w-80"
                    value={@search_term}
                    phx-change="search"
                    name="search"
                  />
                </div>
                <select
                  class="select select-bordered select-sm"
                  phx-change="filter_reason"
                  name="reason"
                >
                  <option value="">All Reasons</option>
                  <option value="spam">Spam</option>
                  <option value="bounce">Bounce</option>
                  <option value="complaint">Complaint</option>
                  <option value="manual">Manual</option>
                  <option value="rate_limit">Rate Limit</option>
                </select>
                <select
                  class="select select-bordered select-sm"
                  phx-change="filter_status"
                  name="status"
                >
                  <option value="all">All Status</option>
                  <option value="active">Active</option>
                  <option value="expired">Expired</option>
                  <option value="permanent">Permanent</option>
                </select>
              </div>

              <%!-- Action Buttons --%>
              <div class="flex gap-2">
                <%= if length(@selected_emails) > 0 do %>
                  <div class="dropdown dropdown-end">
                    <div tabindex="0" role="button" class="btn btn-sm btn-outline">
                      Actions ({length(@selected_emails)})
                    </div>
                    <ul
                      tabindex="0"
                      class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52"
                    >
                      <li>
                        <a phx-click="set_bulk_action" phx-value-action="remove">
                          Remove Selected
                        </a>
                      </li>
                      <li>
                        <a phx-click="set_bulk_action" phx-value-action="export">
                          Export Selected
                        </a>
                      </li>
                    </ul>
                  </div>
                  <button class="btn btn-sm btn-ghost" phx-click="clear_selection">
                    Clear
                  </button>
                <% else %>
                  <button class="btn btn-sm btn-outline" phx-click="select_all_visible">
                    Select All
                  </button>
                <% end %>

                <button
                  class="btn btn-sm btn-success"
                  phx-click="toggle_add_form"
                >
                  Add Block
                </button>

                <div class="dropdown dropdown-end">
                  <div tabindex="0" role="button" class="btn btn-sm btn-outline">
                    Import/Export
                  </div>
                  <ul
                    tabindex="0"
                    class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52"
                  >
                    <li>
                      <a phx-click="toggle_import_form">
                        Import CSV
                      </a>
                    </li>
                    <li>
                      <a phx-click="export_blocklist" phx-value-format="csv">
                        Export as CSV
                      </a>
                    </li>
                    <li>
                      <a phx-click="export_blocklist" phx-value-format="json">
                        Export as JSON
                      </a>
                    </li>
                  </ul>
                </div>

                <button
                  class="btn btn-sm btn-outline"
                  phx-click="refresh"
                  disabled={@loading}
                >
                  <%= if @loading do %>
                    <span class="loading loading-spinner loading-xs"></span>
                  <% else %>
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                      />
                    </svg>
                  <% end %>
                  Refresh
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Add Block Modal --%>
        <%= if @show_add_form do %>
          <div class="modal modal-open">
            <div class="modal-box">
              <h3 class="font-bold text-lg mb-4">Add Email to Blocklist</h3>
              <form phx-submit="add_block">
                <div class="form-control mb-4">
                  <label class="label">
                    <span class="label-text">Email Address</span>
                  </label>
                  <input
                    type="email"
                    name="email"
                    class="input input-bordered w-full"
                    placeholder="user@example.com"
                    required
                  />
                </div>
                <div class="form-control mb-4">
                  <label class="label">
                    <span class="label-text">Reason</span>
                  </label>
                  <select name="reason" class="select select-bordered w-full" required>
                    <option value="">Select reason</option>
                    <option value="spam">Spam</option>
                    <option value="bounce">Hard Bounce</option>
                    <option value="complaint">Complaint</option>
                    <option value="manual">Manual Block</option>
                    <option value="rate_limit">Rate Limit Exceeded</option>
                  </select>
                </div>
                <div class="form-control mb-4">
                  <label class="label">
                    <span class="label-text">Expires At (Optional)</span>
                  </label>
                  <input
                    type="date"
                    name="expires_at"
                    class="input input-bordered w-full"
                    min={Date.utc_today() |> Date.to_iso8601()}
                  />
                  <label class="label">
                    <span class="label-text-alt">Leave empty for permanent block</span>
                  </label>
                </div>
                <div class="modal-action">
                  <button type="submit" class="btn btn-success">Add Block</button>
                  <button type="button" class="btn" phx-click="toggle_add_form">Cancel</button>
                </div>
              </form>
            </div>
          </div>
        <% end %>

        <%!-- Import CSV Modal --%>
        <%= if @show_import_form do %>
          <div class="modal modal-open">
            <div class="modal-box">
              <h3 class="font-bold text-lg mb-4">Import Blocklist from CSV</h3>
              <form phx-submit="import_csv">
                <div class="form-control mb-4">
                  <label class="label">
                    <span class="label-text">CSV Content</span>
                  </label>
                  <textarea
                    name="csv_content"
                    class="textarea textarea-bordered h-40 w-full"
                    placeholder="email,reason,expires_at&#10;spam@example.com,spam,2025-12-31&#10;bounce@example.com,bounce,"
                    required
                  ></textarea>
                  <label class="label">
                    <span class="label-text-alt">
                      Format: email,reason,expires_at (expires_at optional)
                    </span>
                  </label>
                </div>
                <div class="modal-action">
                  <button type="submit" class="btn btn-primary">Import</button>
                  <button type="button" class="btn" phx-click="toggle_import_form">Cancel</button>
                </div>
              </form>
            </div>
          </div>
        <% end %>

        <%!-- Bulk Action Confirmation --%>
        <%= if @bulk_action do %>
          <div class="alert alert-warning mb-4">
            <svg class="stroke-current shrink-0 w-6 h-6" fill="none" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16c-.77.833.192 2.5 1.732 2.5z"
              />
            </svg>
            <span>
              Are you sure you want to {@bulk_action} {length(@selected_emails)} blocked emails?
            </span>
            <div>
              <button class="btn btn-sm btn-primary" phx-click="execute_bulk_action">
                Confirm
              </button>
              <button class="btn btn-sm btn-ghost" phx-click="clear_selection">
                Cancel
              </button>
            </div>
          </div>
        <% end %>

        <%!-- Loading State --%>
        <%= if @loading do %>
          <div class="flex justify-center items-center h-32">
            <span class="loading loading-spinner loading-lg"></span>
            <span class="ml-3 text-lg">Loading blocklist...</span>
          </div>
        <% else %>
          <%!-- Blocklist Table --%>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body">
              <%= if length(@blocked_emails) > 0 do %>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>
                          <input
                            type="checkbox"
                            class="checkbox checkbox-sm"
                            checked={
                              length(@selected_emails) > 0 &&
                                length(@selected_emails) == length(@blocked_emails)
                            }
                            phx-click="select_all_visible"
                          />
                        </th>
                        <th>Email Address</th>
                        <th>Reason</th>
                        <th>Status</th>
                        <th>Added</th>
                        <th>Expires</th>
                        <th>Actions</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for blocked <- @blocked_emails do %>
                        <tr>
                          <td>
                            <input
                              type="checkbox"
                              class="checkbox checkbox-sm"
                              checked={blocked.email in @selected_emails}
                              phx-click="toggle_email_selection"
                              phx-value-email={blocked.email}
                            />
                          </td>
                          <td class="font-mono">{blocked.email}</td>
                          <td>
                            <span class={[
                              "badge badge-sm",
                              (blocked.reason == "spam" && "badge-error") ||
                                (blocked.reason == "bounce" && "badge-warning") ||
                                (blocked.reason == "complaint" && "badge-error") ||
                                (blocked.reason == "manual" && "badge-info") ||
                                "badge-ghost"
                            ]}>
                              {blocked.reason}
                            </span>
                          </td>
                          <td>
                            <%= if is_nil(blocked.expires_at) do %>
                              <span class="badge badge-neutral badge-sm">Permanent</span>
                            <% else %>
                              <%= if DateTime.compare(blocked.expires_at, DateTime.utc_now()) == :gt do %>
                                <span class="badge badge-success badge-sm">Active</span>
                              <% else %>
                                <span class="badge badge-ghost badge-sm">Expired</span>
                              <% end %>
                            <% end %>
                          </td>
                          <td class="text-sm">
                            {UtilsDate.format_date_with_user_format(
                              DateTime.to_date(blocked.inserted_at)
                            )}
                          </td>
                          <td class="text-sm">
                            <%= if blocked.expires_at do %>
                              {UtilsDate.format_date_with_user_format(
                                DateTime.to_date(blocked.expires_at)
                              )}
                            <% else %>
                              <span class="text-base-content/50">Never</span>
                            <% end %>
                          </td>
                          <td>
                            <button
                              class="btn btn-xs btn-error"
                              phx-click="remove_block"
                              phx-value-email={blocked.email}
                              phx-confirm="Are you sure you want to unblock this email?"
                            >
                              Remove
                            </button>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>

                <%!-- Pagination --%>
                <%= if @total_blocked > @per_page do %>
                  <div class="flex justify-center items-center gap-2 mt-4">
                    <div class="join">
                      <%= for page <- pagination_range(@page, div(@total_blocked, @per_page) + 1) do %>
                        <button
                          class={[
                            "join-item btn btn-sm",
                            (page == @page && "btn-active") || "btn-outline"
                          ]}
                          phx-click="change_page"
                          phx-value-page={page}
                        >
                          {page}
                        </button>
                      <% end %>
                    </div>
                    <span class="text-sm text-base-content/60 ml-4">
                      Showing {(@page - 1) * @per_page + 1}-{min(@page * @per_page, @total_blocked)} of {@total_blocked}
                    </span>
                  </div>
                <% end %>
              <% else %>
                <div class="text-center text-base-content/50 py-8">
                  <%= if @search_term != "" || @reason_filter != "" || @status_filter != "all" do %>
                    No blocked emails match your filters.
                    <button class="btn btn-sm btn-outline ml-2" phx-click="search" phx-value-search="">
                      Clear Filters
                    </button>
                  <% else %>
                    No blocked emails found. Great job on maintaining a clean list! 🎉
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Status Footer --%>
        <div class="text-center text-sm text-base-content/60 mt-4">
          Last updated: {UtilsDate.format_datetime_with_user_format(@last_updated)}
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  ## --- Private Functions ---

  defp get_current_path(_socket, _session) do
    Routes.path("/admin/email/blocklist")
  end

  defp load_blocklist_data(socket) do
    filters = build_filters(socket.assigns)

    # This would be implemented with actual blocklist queries
    # For now, using mock data that integrates with RateLimiter
    blocked_emails = load_blocked_emails(filters)
    total_blocked = count_blocked_emails(filters)
    statistics = load_blocklist_statistics()

    socket
    |> assign(:blocked_emails, blocked_emails)
    |> assign(:total_blocked, total_blocked)
    |> assign(:statistics, statistics)
    |> assign(:loading, false)
  end

  defp build_filters(assigns) do
    %{
      search: assigns.search_term,
      reason: assigns.reason_filter,
      status: assigns.status_filter,
      page: assigns.page,
      per_page: assigns.per_page
    }
  end

  defp load_blocked_emails(_filters) do
    # This would query the actual blocklist table
    # For now, return mock data
    [
      %{
        email: "spam@example.com",
        reason: "spam",
        inserted_at: DateTime.add(DateTime.utc_now(), -86_400),
        expires_at: nil
      },
      %{
        email: "bounce@test.com",
        reason: "bounce",
        inserted_at: DateTime.add(DateTime.utc_now(), -3600),
        expires_at: DateTime.add(DateTime.utc_now(), 86_400)
      }
    ]
  end

  defp count_blocked_emails(_filters) do
    # This would count the actual blocklist entries
    2
  end

  defp load_blocklist_statistics do
    # This would load real statistics from RateLimiter
    status = RateLimiter.get_rate_limit_status()
    Map.get(status, :blocklist, %{active_blocks: 0, expired_today: 0})
  end

  defp execute_bulk_remove(socket) do
    selected_emails = socket.assigns.selected_emails

    success_count =
      Enum.reduce(selected_emails, 0, fn email, acc ->
        RateLimiter.remove_from_blocklist(email)
        acc + 1
      end)

    message = "Removed #{success_count} of #{length(selected_emails)} emails from blocklist"

    {:noreply,
     socket
     |> assign(:selected_emails, [])
     |> assign(:bulk_action, nil)
     |> put_flash(:info, message)
     |> load_blocklist_data()}
  end

  defp execute_bulk_export(socket) do
    selected_emails = socket.assigns.selected_emails
    blocked_data = Enum.filter(socket.assigns.blocked_emails, &(&1.email in selected_emails))

    csv_content = export_blocklist_csv(blocked_data)
    filename = "selected_blocklist_#{Date.utc_today()}.csv"

    {:noreply,
     socket
     |> push_event("download", %{
       filename: filename,
       content: csv_content,
       mime_type: "text/csv"
     })}
  end

  defp export_blocklist_csv(blocked_emails) do
    headers = "email,reason,added_at,expires_at\n"

    rows =
      Enum.map_join(blocked_emails, "\n", fn blocked ->
        expires_str =
          if blocked.expires_at,
            do: Date.to_iso8601(DateTime.to_date(blocked.expires_at)),
            else: ""

        "#{blocked.email},#{blocked.reason},#{Date.to_iso8601(DateTime.to_date(blocked.inserted_at))},#{expires_str}"
      end)

    headers <> rows
  end

  defp import_blocklist_csv(csv_content) do
    lines =
      String.split(csv_content, "\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    # Skip header line if it looks like headers
    lines =
      case List.first(lines) do
        "email,reason" <> _ -> List.delete_at(lines, 0)
        _ -> lines
      end

    imported_count =
      Enum.reduce(lines, 0, fn line, acc ->
        case parse_csv_line(line) do
          {:ok, email, reason, expires_at} ->
            opts = if expires_at, do: [expires_at: expires_at], else: []

            case RateLimiter.add_to_blocklist(email, reason, opts) do
              :ok -> acc + 1
              _ -> acc
            end

          _ ->
            acc
        end
      end)

    {:ok, imported_count}
  rescue
    _ -> {:error, "Invalid CSV format"}
  end

  defp parse_csv_line(line) do
    parts = String.split(line, ",") |> Enum.map(&String.trim/1)

    case parts do
      [email, reason] ->
        {:ok, email, reason, nil}

      [email, reason, ""] ->
        {:ok, email, reason, nil}

      [email, reason, expires_str] ->
        case Date.from_iso8601(expires_str) do
          {:ok, date} -> {:ok, email, reason, DateTime.new!(date, ~T[23:59:59])}
          _ -> {:ok, email, reason, nil}
        end

      _ ->
        {:error, "Invalid line format"}
    end
  end

  defp pagination_range(current_page, total_pages) do
    start_page = max(1, current_page - 2)
    end_page = min(total_pages, current_page + 2)
    Enum.to_list(start_page..end_page)
  end
end
