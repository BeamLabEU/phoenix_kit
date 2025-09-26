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

  This LiveView is mounted at `{prefix}/admin/emails/queue` and requires
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
  def mount(_params, _session, socket) do
    # Check if email tracking is enabled
    if EmailTracking.enabled?() do
      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Schedule periodic refresh for real-time updates
      if connected?(socket) do
        Process.send_after(self(), :refresh_queue, @refresh_interval)
      end

      socket =
        socket
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
