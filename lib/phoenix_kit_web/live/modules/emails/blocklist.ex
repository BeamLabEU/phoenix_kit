defmodule PhoenixKitWeb.Live.Modules.Emails.Blocklist do
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

  This LiveView is mounted at `{prefix}/admin/emails/blocklist` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-blocklist", PhoenixKitWeb.Live.Modules.Emails.EmailBlocklistLive, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Emails
  alias PhoenixKit.Emails.RateLimiter
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
  def mount(_params, _session, socket) do
    # Check if email system is enabled
    if Emails.enabled?() do
      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Schedule periodic refresh
      if connected?(socket) do
        Process.send_after(self(), :refresh_blocklist, @refresh_interval)
      end

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/emails/blocklist"))
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
       |> put_flash(:error, "Email is not enabled")
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
  def handle_event("filter_search", %{"search" => search_term}, socket) do
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

  defp load_blocklist_data(socket) do
    filters = build_filters(socket.assigns)

    # Load blocked emails using RateLimiter API
    blocked_emails = load_blocked_emails(filters)
    total_blocked = count_blocked_emails(filters)
    statistics = load_blocklist_statistics()

    # Calculate total pages for pagination
    total_pages = ceil(total_blocked / socket.assigns.per_page)

    socket
    |> assign(:blocked_emails, blocked_emails)
    |> assign(:total_blocked, total_blocked)
    |> assign(:total_pages, total_pages)
    |> assign(:statistics, statistics)
    |> assign(:loading, false)
  end

  defp build_filters(assigns) do
    opts = %{}

    opts =
      if assigns.search_term && assigns.search_term != "" do
        Map.put(opts, :search, assigns.search_term)
      else
        opts
      end

    opts =
      if assigns.reason_filter && assigns.reason_filter != "" do
        Map.put(opts, :reason, assigns.reason_filter)
      else
        opts
      end

    opts =
      if assigns.status_filter == "expired" do
        Map.put(opts, :include_expired, true)
      else
        opts
      end

    # Pagination
    offset = (assigns.page - 1) * assigns.per_page

    opts
    |> Map.put(:limit, assigns.per_page)
    |> Map.put(:offset, offset)
    |> Map.put(:order_by, :inserted_at)
    |> Map.put(:order_dir, :desc)
  end

  defp load_blocked_emails(filters) do
    RateLimiter.list_blocklist(filters)
  end

  defp count_blocked_emails(filters) do
    # Remove pagination params for count
    filters
    |> Map.delete(:limit)
    |> Map.delete(:offset)
    |> RateLimiter.count_blocklist()
  end

  defp load_blocklist_statistics do
    RateLimiter.get_blocklist_stats()
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
end
