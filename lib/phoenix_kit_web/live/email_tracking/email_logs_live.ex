defmodule PhoenixKitWeb.Live.EmailTracking.EmailLogsLive do
  @moduledoc """
  LiveView for displaying and managing email logs in PhoenixKit admin panel.

  Provides comprehensive email tracking interface with filtering, searching,
  and detailed analytics for sent emails.

  ## Features

  - **Real-time Log List**: Live updates of email logs
  - **Advanced Filtering**: By status, date range, recipient, campaign, template
  - **Search Functionality**: Search across recipients, subjects, campaigns
  - **Pagination**: Handle large volumes of email logs
  - **Export**: CSV export functionality
  - **Quick Actions**: Resend, view details, mark as reviewed
  - **Statistics Summary**: Key metrics at the top of the page

  ## Route

  This LiveView is mounted at `/phoenix_kit/admin/email-logs` and requires
  appropriate admin permissions.

  ## Usage

      # In your Phoenix router
      live "/email-logs", PhoenixKitWeb.Live.EmailTracking.EmailLogsLive, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  import PhoenixKitWeb.CoreComponents

  alias PhoenixKit.EmailTracking
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  @default_per_page 25
  @max_per_page 100

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, session, socket) do
    # Check if email tracking is enabled
    if EmailTracking.enabled?() do
      # Get current path for navigation
      current_path = get_current_path(socket, session)

      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      socket =
        socket
        |> assign(:page_title, "Email Logs")
        |> assign(:current_path, current_path)
        |> assign(:project_title, project_title)
        |> assign(:logs, [])
        |> assign(:total_count, 0)
        |> assign(:stats, %{})
        |> assign(:loading, true)
        |> assign_filter_defaults()
        |> assign_pagination_defaults()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Email tracking is not enabled")
       |> push_navigate(to: "/phoenix_kit/admin/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_email_logs()
      |> load_stats()

    {:noreply, socket}
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("filter", params, socket) do
    # Handle both search and filter parameters
    combined_params = %{}

    # Extract search parameters
    combined_params =
      case Map.get(params, "search") do
        %{"query" => query} -> Map.put(combined_params, "search", String.trim(query || ""))
        _ -> combined_params
      end

    # Extract filter parameters
    combined_params =
      case Map.get(params, "filter") do
        filter_params when is_map(filter_params) -> Map.merge(combined_params, filter_params)
        _ -> combined_params
      end

    # Reset to first page when filtering
    combined_params = Map.put(combined_params, "page", "1")

    # Build new URL parameters
    new_params = build_url_params(socket.assigns, combined_params)

    {:noreply,
     socket
     |> push_patch(to: "/phoenix_kit/admin/email-logs?#{new_params}")}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> push_patch(to: "/phoenix_kit/admin/email-logs")}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    # Generate CSV export in background
    send(self(), {:export_csv, socket.assigns.filters})

    {:noreply,
     socket
     |> put_flash(:info, "CSV export is being generated. Download will start shortly.")}
  end

  @impl true
  def handle_event("view_details", %{"id" => log_id}, socket) do
    {:noreply,
     socket
     |> push_navigate(to: "/phoenix_kit/admin/email-logs/#{log_id}")}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_email_logs()
     |> load_stats()}
  end

  ## --- Info Handlers ---

  @impl true
  def handle_info({:export_csv, filters}, socket) do
    csv_data = generate_csv_export(filters)
    filename = "email_logs_#{Date.utc_today()}.csv"

    {:noreply,
     socket
     |> push_event("download", %{
       filename: filename,
       content: csv_data,
       mime_type: "text/csv"
     })}
  rescue
    error ->
      {:noreply,
       socket
       |> put_flash(:error, "Failed to generate CSV export: #{Exception.message(error)}")}
  end

  ## --- Template ---

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Email Logs"
      current_path={@current_path}
      project_title={@project_title}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <%!-- Back Button (Left aligned) --%>
          <.link
            navigate="/phoenix_kit/admin/dashboard"
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0 -mb-12"
          >
            <.icon_arrow_left /> Back to Dashboard
          </.link>

          <%!-- Title Section --%>
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">Email Logs</h1>
            <p class="text-lg text-base-content">Monitor and track all outgoing emails</p>
          </div>
        </header>

        <%!-- Action Buttons --%>
        <div class="flex justify-end gap-2 mb-6">
          <.button phx-click="export_csv" class="btn btn-outline btn-sm">
            <.icon name="hero-arrow-down-tray" class="w-4 h-4 mr-1" /> Export CSV
          </.button>

          <.button phx-click="refresh" class="btn btn-outline btn-sm">
            <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> Refresh
          </.button>
        </div>

        <%!-- Statistics Summary --%>
        <div class="stats shadow mb-6">
          <div class="stat">
            <div class="stat-title">Total Sent</div>
            <div class="stat-value text-primary">{@stats[:total_sent] || 0}</div>
            <div class="stat-desc">Last 30 days</div>
          </div>

          <div class="stat">
            <div class="stat-title">Delivered</div>
            <div class="stat-value text-success">{@stats[:delivered] || 0}</div>
            <div class="stat-desc">{@stats[:delivery_rate] || 0}% rate</div>
          </div>

          <div class="stat">
            <div class="stat-title">Bounced</div>
            <div class="stat-value text-error">{@stats[:bounced] || 0}</div>
            <div class="stat-desc">{@stats[:bounce_rate] || 0}% rate</div>
          </div>

          <div class="stat">
            <div class="stat-title">Opened</div>
            <div class="stat-value text-info">{@stats[:opened] || 0}</div>
            <div class="stat-desc">{@stats[:open_rate] || 0}% rate</div>
          </div>
        </div>

        <%!-- Filters & Search --%>
        <div class="card bg-base-100 shadow-sm mb-6">
          <div class="card-body">
            <.form for={%{}} phx-change="filter" phx-submit="filter" class="space-y-4">
              <%!-- Search Bar --%>
              <div class="form-control">
                <div class="input-group">
                  <input
                    type="text"
                    name="search[query]"
                    value={@filters.search}
                    placeholder="Search by recipient, subject, or campaign..."
                    class="input input-bordered flex-1"
                  />
                  <button type="submit" class="btn btn-primary">
                    <.icon name="hero-magnifying-glass" class="w-4 h-4" />
                  </button>
                </div>
              </div>

              <%!-- Filter Row --%>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
                <%!-- Status Filter --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Status</span>
                  </label>
                  <select name="filter[status]" class="select select-bordered">
                    <option value="">All Statuses</option>
                    <option value="sent" selected={@filters.status == "sent"}>Sent</option>
                    <option value="delivered" selected={@filters.status == "delivered"}>
                      Delivered
                    </option>
                    <option value="bounced" selected={@filters.status == "bounced"}>Bounced</option>
                    <option value="opened" selected={@filters.status == "opened"}>Opened</option>
                    <option value="clicked" selected={@filters.status == "clicked"}>Clicked</option>
                    <option value="failed" selected={@filters.status == "failed"}>Failed</option>
                  </select>
                </div>

                <%!-- Message Tags Filter --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Message Type</span>
                  </label>
                  <select name="filter[message_tag]" class="select select-bordered">
                    <option value="">All Types</option>
                    <option value="authentication" selected={@filters.message_tag == "authentication"}>
                      Authentication
                    </option>
                    <option value="registration" selected={@filters.message_tag == "registration"}>
                      Registration
                    </option>
                    <option value="marketing" selected={@filters.message_tag == "marketing"}>
                      Marketing
                    </option>
                    <option value="notification" selected={@filters.message_tag == "notification"}>
                      Notification
                    </option>
                    <option value="transactional" selected={@filters.message_tag == "transactional"}>
                      Transactional
                    </option>
                  </select>
                </div>

                <%!-- Date Range --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">From Date</span>
                  </label>
                  <input
                    type="date"
                    name="filter[from_date]"
                    value={@filters.from_date}
                    class="input input-bordered"
                  />
                </div>

                <div class="form-control">
                  <label class="label">
                    <span class="label-text">To Date</span>
                  </label>
                  <input
                    type="date"
                    name="filter[to_date]"
                    value={@filters.to_date}
                    class="input input-bordered"
                  />
                </div>
              </div>

              <%!-- Action Buttons --%>
              <div class="flex gap-2">
                <button type="submit" class="btn btn-primary btn-sm">Apply Filters</button>
                <button type="button" phx-click="clear_filters" class="btn btn-ghost btn-sm">
                  Clear
                </button>
              </div>
            </.form>
          </div>
        </div>

        <%!-- Email Logs Table --%>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body p-0">
            <%= if @loading do %>
              <div class="flex justify-center items-center h-32">
                <span class="loading loading-spinner loading-md"></span>
                <span class="ml-2">Loading email logs...</span>
              </div>
            <% else %>
              <div class="w-full">
                <table class="table table-hover w-full">
                  <thead>
                    <tr>
                      <th class="w-1/4">Email</th>
                      <th class="w-1/4">Subject</th>
                      <th class="w-1/8">Status</th>
                      <th class="w-1/6">Details</th>
                      <th class="w-1/8">Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for log <- @logs do %>
                      <tr class="hover">
                        <%!-- Email Column --%>
                        <td>
                          <div class="space-y-1">
                            <div class="font-medium text-sm">{log.to}</div>
                            <%= if log.user_id do %>
                              <div class="badge badge-ghost badge-xs">User #{log.user_id}</div>
                            <% end %>
                          </div>
                        </td>

                        <%!-- Subject Column --%>
                        <td>
                          <div class="space-y-1">
                            <div class="text-sm truncate" title={log.subject}>
                              {log.subject || "(no subject)"}
                            </div>
                            <%= if log.template_name do %>
                              <div class="badge badge-outline badge-xs">
                                {log.template_name}
                              </div>
                            <% end %>
                          </div>
                        </td>

                        <%!-- Status Column --%>
                        <td>
                          <div class="space-y-1">
                            <div class={status_badge_class(log.status)}>
                              {log.status}
                            </div>
                            <%= if log.error_message do %>
                              <div class="text-xs text-error truncate" title={log.error_message}>
                                Error
                              </div>
                            <% end %>
                          </div>
                        </td>

                        <%!-- Details Column --%>
                        <td>
                          <div class="space-y-1 text-xs">
                            <div class="flex items-center gap-1">
                              <%= if get_message_tag(log.message_tags) do %>
                                <div class="badge badge-secondary badge-xs">
                                  {get_message_tag(log.message_tags)}
                                </div>
                              <% else %>
                                <div class="badge badge-ghost badge-xs">no tag</div>
                              <% end %>
                              <%= if log.campaign_id do %>
                                <div class="badge badge-primary badge-xs">{log.campaign_id}</div>
                              <% end %>
                            </div>
                            <div class="text-base-content/70">
                              {UtilsDate.format_datetime_with_user_format(log.sent_at)}
                            </div>
                            <%= if log.delivered_at do %>
                              <div class="text-success">
                                ✓ {UtilsDate.format_datetime_with_user_format(log.delivered_at)}
                              </div>
                            <% end %>
                          </div>
                        </td>

                        <%!-- Actions Column --%>
                        <td>
                          <button
                            phx-click="view_details"
                            phx-value-id={log.id}
                            class="btn btn-xs btn-outline btn-primary"
                          >
                            <.icon name="hero-eye" class="w-3 h-3 mr-1" /> View
                          </button>
                        </td>
                      </tr>
                    <% end %>

                    <%= if length(@logs) == 0 and not @loading do %>
                      <tr>
                        <td colspan="5" class="text-center py-8 text-base-content/60">
                          No email logs found matching your criteria
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>

              <%!-- Pagination --%>
              <%= if @total_count > @per_page do %>
                <div class="border-t bg-base-200 px-4 py-3 flex items-center justify-between">
                  <div class="text-sm text-base-content/70">
                    Showing {(@page - 1) * @per_page + 1} to {min(@page * @per_page, @total_count)} of {@total_count} results
                  </div>

                  <div class="btn-group">
                    <%= if @page > 1 do %>
                      <.link patch={build_page_url(@page - 1, assigns)} class="btn btn-sm">
                        « Prev
                      </.link>
                    <% end %>

                    <%= for page_num <- pagination_pages(@page, @total_pages) do %>
                      <.link
                        patch={build_page_url(page_num, assigns)}
                        class={pagination_class(page_num, @page)}
                      >
                        {page_num}
                      </.link>
                    <% end %>

                    <%= if @page < @total_pages do %>
                      <.link patch={build_page_url(@page + 1, assigns)} class="btn btn-sm">
                        Next »
                      </.link>
                    <% end %>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  ## --- Private Helper Functions ---

  # Apply default filter values
  defp assign_filter_defaults(socket) do
    filters = %{
      search: "",
      status: "",
      message_tag: "",
      campaign_id: "",
      from_date: "",
      to_date: ""
    }

    assign(socket, :filters, filters)
  end

  # Apply default pagination values
  defp assign_pagination_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, @default_per_page)
    |> assign(:total_pages, 0)
  end

  # Apply URL parameters to socket assigns
  defp apply_params(socket, params) do
    filters = %{
      search: params["search"] || "",
      status: params["status"] || "",
      message_tag: params["message_tag"] || "",
      campaign_id: params["campaign_id"] || "",
      from_date: params["from_date"] || "",
      to_date: params["to_date"] || ""
    }

    page = String.to_integer(params["page"] || "1")
    per_page = min(String.to_integer(params["per_page"] || "#{@default_per_page}"), @max_per_page)

    socket
    |> assign(:filters, filters)
    |> assign(:page, page)
    |> assign(:per_page, per_page)
  end

  # Load email logs based on current filters and pagination
  defp load_email_logs(socket) do
    %{filters: filters, page: page, per_page: per_page} = socket.assigns

    # Build filters for EmailLog query
    query_filters = build_query_filters(filters, page, per_page)

    logs = EmailTracking.list_logs(query_filters)

    # Get total count for pagination (efficient count without loading all records)
    total_count =
      EmailTracking.count_logs(build_query_filters(filters, 1, 1) |> Map.drop([:limit, :offset]))

    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:logs, logs)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:loading, false)
  end

  # Load summary statistics
  defp load_stats(socket) do
    stats = EmailTracking.get_system_stats(:last_30_days)

    assign(socket, :stats, stats)
  end

  # Build query filters from form filters
  defp build_query_filters(filters, page, per_page) do
    query_filters = %{
      limit: per_page,
      offset: (page - 1) * per_page
    }

    # Add non-empty filters
    query_filters =
      filters
      |> Enum.reduce(query_filters, fn
        {:search, search}, acc when search != "" ->
          # Search in recipient, subject, and campaign fields
          Map.put(acc, :search, search)

        {:status, status}, acc when status != "" ->
          Map.put(acc, :status, status)

        {:message_tag, message_tag}, acc when message_tag != "" ->
          Map.put(acc, :message_tag, message_tag)

        {:campaign_id, campaign_id}, acc when campaign_id != "" ->
          Map.put(acc, :campaign_id, campaign_id)

        {:from_date, from_date}, acc when from_date != "" ->
          case Date.from_iso8601(from_date) do
            {:ok, date} -> Map.put(acc, :from_date, DateTime.new!(date, ~T[00:00:00]))
            _ -> acc
          end

        {:to_date, to_date}, acc when to_date != "" ->
          case Date.from_iso8601(to_date) do
            {:ok, date} -> Map.put(acc, :to_date, DateTime.new!(date, ~T[23:59:59]))
            _ -> acc
          end

        _, acc ->
          acc
      end)

    query_filters
  end

  # Build URL parameters from current state
  defp build_url_params(assigns, additional_params) do
    base_params = %{
      "search" => assigns.filters.search,
      "status" => assigns.filters.status,
      "message_tag" => assigns.filters.message_tag,
      "campaign_id" => assigns.filters.campaign_id,
      "from_date" => assigns.filters.from_date,
      "to_date" => assigns.filters.to_date,
      "page" => assigns.page,
      "per_page" => assigns.per_page
    }

    Map.merge(base_params, additional_params)
    |> Enum.reject(fn {_key, value} -> value == "" or is_nil(value) end)
    |> Map.new()
    |> URI.encode_query()
  end

  # Generate CSV export data
  defp generate_csv_export(filters) do
    # Load all matching logs (without pagination)
    query_filters = build_query_filters(filters, 1, 1) |> Map.drop([:limit, :offset])

    logs = EmailTracking.list_logs(query_filters)

    # CSV headers
    headers = [
      "ID",
      "Message ID",
      "To",
      "From",
      "Subject",
      "Status",
      "Message Type",
      "Provider",
      "Sent At",
      "Delivered At",
      "Campaign",
      "Template",
      "Error Message"
    ]

    # CSV rows
    rows =
      Enum.map(logs, fn log ->
        [
          log.id,
          log.message_id,
          log.to,
          log.from,
          log.subject || "",
          log.status,
          get_message_tag(log.message_tags) || "",
          log.provider,
          log.sent_at |> DateTime.to_iso8601(),
          log.delivered_at |> format_datetime_for_csv(),
          log.campaign_id || "",
          log.template_name || "",
          log.error_message || ""
        ]
      end)

    # Generate CSV string
    [headers | rows]
    |> Enum.map_join("\n", &Enum.join(&1, ","))
  end

  # Helper functions for template
  defp status_badge_class(status) do
    case status do
      "sent" -> "badge badge-info badge-sm"
      "delivered" -> "badge badge-success badge-sm"
      "bounced" -> "badge badge-error badge-sm"
      "opened" -> "badge badge-primary badge-sm"
      "clicked" -> "badge badge-secondary badge-sm"
      "failed" -> "badge badge-error badge-sm"
      _ -> "badge badge-ghost badge-sm"
    end
  end

  defp pagination_pages(current_page, total_pages) do
    start_page = max(1, current_page - 2)
    end_page = min(total_pages, current_page + 2)

    start_page..end_page
  end

  defp pagination_class(page_num, current_page) do
    if page_num == current_page do
      "btn btn-sm btn-active"
    else
      "btn btn-sm"
    end
  end

  defp build_page_url(page, assigns) do
    params = build_url_params(assigns, %{"page" => page})
    "/phoenix_kit/admin/email-logs?#{params}"
  end

  defp format_datetime_for_csv(nil), do: ""
  defp format_datetime_for_csv(datetime), do: DateTime.to_iso8601(datetime)

  defp get_current_path(_socket, _session) do
    # For EmailLogsLive, always return email logs path
    Routes.path("/admin/email-logs")
  end

  # Extract email_type from message_tags
  defp get_message_tag(message_tags) when is_map(message_tags) do
    Map.get(message_tags, "email_type")
  end

  defp get_message_tag(_), do: nil
end
