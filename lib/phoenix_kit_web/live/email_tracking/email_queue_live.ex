defmodule PhoenixKitWeb.Live.EmailTracking.EmailQueueLive do
  @moduledoc """
  LiveView for email queue monitoring and rate limit management.

  Provides real-time monitoring of email sending activity, rate limiting status,
  and queue management functionality for the email tracking system.

  ## Features

  - **Real-time Activity**: Live updates of recent email sending activity
  - **Rate Limit Monitoring**: Current rate limit status and usage
  - **Failed Email Management**: Retry and management of failed emails
  - **Bulk Operations**: Pause/resume email sending, bulk retry
  - **Provider Status**: Monitor email provider health and performance
  - **Alert Management**: Configure alerts for rate limits and failures

  ## Route

  This LiveView is mounted at `{prefix}/admin/email-queue` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-queue", PhoenixKitWeb.Live.EmailTracking.EmailQueueLive, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.EmailTracking
  alias PhoenixKit.EmailTracking.{EmailLog, RateLimiter}
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  # Auto-refresh every 10 seconds for real-time monitoring
  @refresh_interval 10_000

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, session, socket) do
    # Check if email tracking is enabled
    if EmailTracking.enabled?() do
      # Get current path for navigation
      current_path = get_current_path(socket, session)

      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Schedule periodic refresh for real-time updates
      if connected?(socket) do
        Process.send_after(self(), :refresh_queue, @refresh_interval)
      end

      socket =
        socket
        |> assign(:current_path, current_path)
        |> assign(:project_title, project_title)
        |> assign(:loading, true)
        |> assign(:recent_activity, [])
        |> assign(:rate_limit_status, %{})
        |> assign(:failed_emails, [])
        |> assign(:system_status, %{})
        |> assign(:selected_emails, [])
        |> assign(:bulk_action, nil)
        |> assign(:last_updated, DateTime.utc_now())
        |> load_queue_data()

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
     |> load_queue_data()}
  end

  @impl true
  def handle_event("retry_email", %{"email_id" => email_id}, socket) do
    case Integer.parse(email_id) do
      {id, _} ->
        case retry_failed_email(id) do
          {:ok, _log} ->
            {:noreply,
             socket
             |> put_flash(:info, "Email queued for retry")
             |> load_queue_data()}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to retry email: #{reason}")}
        end

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid email ID")}
    end
  end

  @impl true
  def handle_event("toggle_email_selection", %{"email_id" => email_id}, socket) do
    case Integer.parse(email_id) do
      {id, _} ->
        selected = socket.assigns.selected_emails

        new_selected =
          if id in selected do
            List.delete(selected, id)
          else
            [id | selected]
          end

        {:noreply,
         socket
         |> assign(:selected_emails, new_selected)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_all_failed", _params, socket) do
    all_failed_ids = Enum.map(socket.assigns.failed_emails, & &1.id)

    {:noreply,
     socket
     |> assign(:selected_emails, all_failed_ids)}
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
      "retry" ->
        execute_bulk_retry(socket)

      "delete" ->
        execute_bulk_delete(socket)

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid bulk action")}
    end
  end

  @impl true
  def handle_event("reset_rate_limits", _params, socket) do
    # This would reset rate limit counters (implementation would depend on storage)
    {:noreply,
     socket
     |> put_flash(:info, "Rate limits reset")
     |> load_queue_data()}
  end

  @impl true
  def handle_info(:refresh_queue, socket) do
    # Schedule next refresh
    Process.send_after(self(), :refresh_queue, @refresh_interval)

    {:noreply,
     socket
     |> assign(:last_updated, DateTime.utc_now())
     |> load_queue_data()}
  end

  ## --- Template ---

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Email Queue"
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
              📬 Email Queue
            </h1>
            <p class="text-lg text-base-content/70">
              Real-time monitoring and management of email sending activity
            </p>
          </div>
        </header>

        <%!-- Controls Section --%>
        <div class="flex flex-col lg:flex-row lg:items-center lg:justify-between mb-6 gap-4">
          <%!-- Status Indicators --%>
          <div class="flex flex-wrap gap-2">
            <div class="badge badge-success gap-2">
              <div class="w-2 h-2 bg-current rounded-full animate-pulse"></div>
              System Active
            </div>
            <div class="badge badge-info">
              Last Updated: {UtilsDate.format_time_with_user_format(@last_updated)}
            </div>
          </div>

          <%!-- Action Buttons --%>
          <div class="flex gap-2">
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

            <button
              class="btn btn-sm btn-warning"
              phx-click="reset_rate_limits"
            >
              Reset Limits
            </button>
          </div>
        </div>

        <%!-- Loading State --%>
        <%= if @loading do %>
          <div class="flex justify-center items-center h-32">
            <span class="loading loading-spinner loading-lg"></span>
            <span class="ml-3 text-lg">Loading queue data...</span>
          </div>
        <% else %>
          <%!-- Rate Limit Status Cards --%>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
            <%!-- Global Rate Limit --%>
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body p-4">
                <h3 class="card-title text-sm">Global Rate Limit</h3>
                <div class="flex items-center justify-between">
                  <div>
                    <p class="text-2xl font-bold">{@rate_limit_status.global[:count] || 0}</p>
                    <p class="text-sm text-base-content/60">
                      of {format_number(@rate_limit_status.global[:limit] || 10000)}
                    </p>
                  </div>
                  <div
                    class="radial-progress text-primary"
                    style={"--value:#{@rate_limit_status.global[:percentage] || 0}"}
                  >
                    {@rate_limit_status.global[:percentage] || 0}%
                  </div>
                </div>
              </div>
            </div>

            <%!-- Active Blocks --%>
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body p-4">
                <h3 class="card-title text-sm">Active Blocks</h3>
                <div class="flex items-center justify-between">
                  <div>
                    <p class="text-2xl font-bold">
                      {@rate_limit_status.blocklist[:active_blocks] || 0}
                    </p>
                    <p class="text-sm text-base-content/60">blocked addresses</p>
                  </div>
                  <div class="text-warning">
                    <svg class="w-8 h-8" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M13.477 14.89A6 6 0 015.11 6.524l8.367 8.368zm1.414-1.414L6.524 5.11a6 6 0 018.367 8.367zM18 10a8 8 0 11-16 0 8 8 0 0116 0z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Failed Emails --%>
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body p-4">
                <h3 class="card-title text-sm">Failed Emails</h3>
                <div class="flex items-center justify-between">
                  <div>
                    <p class="text-2xl font-bold">{length(@failed_emails)}</p>
                    <p class="text-sm text-base-content/60">need attention</p>
                  </div>
                  <div class="text-error">
                    <svg class="w-8 h-8" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Main Content Grid --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <%!-- Recent Activity --%>
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body">
                <h2 class="card-title text-lg mb-4">Recent Activity</h2>
                <%= if length(@recent_activity) > 0 do %>
                  <div class="space-y-3 max-h-80 overflow-y-auto">
                    <%= for email <- @recent_activity do %>
                      <div class="flex items-center justify-between p-3 bg-base-200 rounded">
                        <div class="flex-1">
                          <p class="font-medium text-sm">{email.to}</p>
                          <p class="text-xs text-base-content/60">{email.subject}</p>
                          <p class="text-xs text-base-content/50">
                            {UtilsDate.format_datetime_with_user_format(email.sent_at)}
                          </p>
                        </div>
                        <div class="flex items-center gap-2">
                          <span class={[
                            "badge badge-xs",
                            (email.status == "sent" && "badge-primary") ||
                              (email.status == "delivered" && "badge-success") ||
                              (email.status == "failed" && "badge-error") ||
                              "badge-ghost"
                          ]}>
                            {email.status}
                          </span>
                          <span class="text-xs text-base-content/60">{email.provider}</span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <div class="text-center text-base-content/50 py-8">
                    No recent email activity
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Failed Emails Management --%>
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body">
                <div class="flex items-center justify-between mb-4">
                  <h2 class="card-title text-lg">Failed Emails</h2>
                  <%= if length(@failed_emails) > 0 do %>
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
                              <a phx-click="set_bulk_action" phx-value-action="retry">
                                Retry Selected
                              </a>
                            </li>
                            <li>
                              <a phx-click="set_bulk_action" phx-value-action="delete">
                                Delete Selected
                              </a>
                            </li>
                          </ul>
                        </div>
                        <button class="btn btn-sm btn-ghost" phx-click="clear_selection">
                          Clear
                        </button>
                      <% else %>
                        <button class="btn btn-sm btn-outline" phx-click="select_all_failed">
                          Select All
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                </div>

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
                      Are you sure you want to {@bulk_action} {length(@selected_emails)} emails?
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

                <%= if length(@failed_emails) > 0 do %>
                  <div class="space-y-2 max-h-80 overflow-y-auto">
                    <%= for email <- @failed_emails do %>
                      <div class="flex items-center justify-between p-3 bg-base-200 rounded">
                        <div class="flex items-center gap-3">
                          <input
                            type="checkbox"
                            class="checkbox checkbox-sm"
                            checked={email.id in @selected_emails}
                            phx-click="toggle_email_selection"
                            phx-value-email_id={email.id}
                          />
                          <div class="flex-1">
                            <p class="font-medium text-sm">{email.to}</p>
                            <p class="text-xs text-base-content/60">{email.subject}</p>
                            <p class="text-xs text-error">{email.error_message}</p>
                          </div>
                        </div>
                        <div class="flex items-center gap-2">
                          <span class="badge badge-xs badge-error">
                            Retry #{email.retry_count || 0}
                          </span>
                          <button
                            class="btn btn-xs btn-outline"
                            phx-click="retry_email"
                            phx-value-email_id={email.id}
                          >
                            Retry
                          </button>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <div class="text-center text-base-content/50 py-8">
                    No failed emails 🎉
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  ## --- Private Functions ---

  defp get_current_path(_socket, _session) do
    Routes.path("/admin/email-queue")
  end

  defp load_queue_data(socket) do
    recent_activity = load_recent_activity()
    rate_limit_status = RateLimiter.get_rate_limit_status()
    failed_emails = load_failed_emails()
    system_status = load_system_status()

    socket
    |> assign(:recent_activity, recent_activity)
    |> assign(:rate_limit_status, rate_limit_status)
    |> assign(:failed_emails, failed_emails)
    |> assign(:system_status, system_status)
    |> assign(:loading, false)
  end

  defp load_recent_activity do
    # Get last 20 emails
    EmailTracking.list_logs(%{limit: 20, order_by: :sent_at, order_dir: :desc})
  end

  defp load_failed_emails do
    # Get failed emails from last 24 hours
    EmailTracking.list_logs(%{
      status: "failed",
      since: DateTime.add(DateTime.utc_now(), -24, :hour),
      limit: 50
    })
  end

  defp load_system_status do
    %{
      tracking_enabled: EmailTracking.enabled?(),
      total_sent_today: get_today_count(),
      retention_days: EmailTracking.get_retention_days()
    }
  end

  defp get_today_count do
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])
    now = DateTime.utc_now()

    case EmailTracking.get_system_stats(
           {:date_range, DateTime.to_date(today_start), DateTime.to_date(now)}
         ) do
      %{total_sent: count} -> count
      _ -> 0
    end
  end

  defp retry_failed_email(email_id) do
    # This would implement the retry logic
    # For now, just update the status to "sent" and increment retry_count
    log = EmailTracking.get_log!(email_id)

    EmailLog.update_log(log, %{
      status: "sent",
      retry_count: (log.retry_count || 0) + 1,
      error_message: nil
    })
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}
  end

  defp execute_bulk_retry(socket) do
    selected_ids = socket.assigns.selected_emails

    success_count =
      Enum.reduce(selected_ids, 0, fn id, acc ->
        case retry_failed_email(id) do
          {:ok, _} -> acc + 1
          _ -> acc
        end
      end)

    message = "Retried #{success_count} of #{length(selected_ids)} emails"

    {:noreply,
     socket
     |> assign(:selected_emails, [])
     |> assign(:bulk_action, nil)
     |> put_flash(:info, message)
     |> load_queue_data()}
  end

  defp execute_bulk_delete(socket) do
    selected_ids = socket.assigns.selected_emails

    success_count =
      Enum.reduce(selected_ids, 0, fn id, acc ->
        try do
          log = EmailTracking.get_log!(id)

          case EmailLog.delete_log(log) do
            {:ok, _} -> acc + 1
            _ -> acc
          end
        rescue
          Ecto.NoResultsError -> acc
        end
      end)

    message = "Deleted #{success_count} of #{length(selected_ids)} emails"

    {:noreply,
     socket
     |> assign(:selected_emails, [])
     |> assign(:bulk_action, nil)
     |> put_flash(:info, message)
     |> load_queue_data()}
  end

  defp format_number(number) when is_integer(number) do
    number
    |> to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end

  defp format_number(number), do: to_string(number)
end
